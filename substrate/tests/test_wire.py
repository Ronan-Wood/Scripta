"""The shared socket's wire is versioned, and both ends check it before decoding anything.

Before this, nothing said which reply shape an engine sent, so an app and an engine from
different releases could only find out by mis-decoding. Each test here fails on that server and
client: neither sent nor read `Substrate-Wire`.

Runnable with `python tests/test_wire.py` or under pytest.
"""

from __future__ import annotations

import contextlib
import json
import socket
import sys
import tempfile
import threading
from unittest import mock

import pytest
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import local_socket, wire  # noqa: E402
from substrate.mcp import bridge, server  # noqa: E402
from test_local_socket import _engine as _serve  # noqa: E402

TOOLS_LIST = {"jsonrpc": "2.0", "id": 7, "method": "tools/list"}


@contextlib.contextmanager
def _engine():
    with tempfile.TemporaryDirectory(dir="/tmp") as root, \
            _serve(Path(root) / "engine" / "substrate.sock") as _:
        yield Path(root) / "engine" / "substrate.sock"


def _raw(path: Path, frame: object, headers: dict[str, str], method: str = "POST"):
    """One request with exactly these headers. Returns (status, reply headers, body)."""
    conn = local_socket.UnixHTTPConnection(path, timeout=10)
    try:
        body = json.dumps(frame).encode() if method == "POST" else None
        conn.request(method, "/", body=body, headers=headers)
        resp = conn.getresponse()
        return resp.status, resp, resp.read()
    finally:
        conn.close()


JSON = {"Content-Type": "application/json"}


def test_a_client_that_states_no_version_is_served_as_version_one() -> None:
    """Every client before the header existed (Scripta 0.3.4, an older `--connect`)."""
    with _engine() as path:
        status, resp, body = _raw(path, TOOLS_LIST, JSON)
        assert status == 200, body
        assert "result" in json.loads(body)
        assert resp.getheader(wire.HEADER) == str(wire.VERSION)


def _never_dispatched():
    return mock.patch.object(server, "handle",
                             side_effect=AssertionError("a request in another wire was dispatched"))


def test_a_version_the_engine_does_not_serve_is_refused_under_the_callers_id() -> None:
    with _engine() as path, _never_dispatched():
        status, resp, body = _raw(path, TOOLS_LIST, {**JSON, wire.HEADER: "99"})
        reply = json.loads(body)
        assert status == 200 and reply["id"] == 7, reply
        assert reply["error"]["code"] == wire.MISMATCH
        assert reply["error"]["data"] == {"engine": wire.VERSION, "engine_min": wire.MIN_VERSION}
        assert "99" in reply["error"]["message"]
        assert resp.getheader(wire.HEADER) == str(wire.VERSION)


def test_a_malformed_or_repeated_version_is_refused_not_guessed() -> None:
    with _engine() as path, _never_dispatched():
        for bad in ("abc", "0", "-1", "1.0", "", "1\x0b"):
            _, _, body = _raw(path, TOOLS_LIST, {**JSON, wire.HEADER: bad})
            reply = json.loads(body)
            assert reply.get("error", {}).get("code") == wire.MISMATCH, (bad, reply)
        conn = local_socket.UnixHTTPConnection(path, timeout=10)
        try:
            frame = json.dumps(TOOLS_LIST).encode()
            conn.putrequest("POST", "/")
            for name, value in (("Content-Type", "application/json"),
                                ("Content-Length", str(len(frame))),
                                (wire.HEADER, "1"), (wire.HEADER, "99")):
                conn.putheader(name, value)
            conn.endheaders(frame)
            reply = json.loads(conn.getresponse().read())
        finally:
            conn.close()
        assert reply["error"]["code"] == wire.MISMATCH and "2 times" in reply["error"]["message"]


def test_a_notification_in_another_version_is_neither_answered_nor_run() -> None:
    with _engine() as path, _never_dispatched():
        note = {"jsonrpc": "2.0", "method": "tools/call",
                "params": {"name": "list_scopes", "arguments": {}}}
        status, _, body = _raw(path, note, {**JSON, wire.HEADER: "99"})
        assert (status, body) == (202, b"")


def test_a_batch_in_another_version_is_refused_member_by_member() -> None:
    with _engine() as path, _never_dispatched():
        batch = [{**TOOLS_LIST, "id": 1}, {"jsonrpc": "2.0", "method": "tools/list"},
                 {**TOOLS_LIST, "id": 2}]
        _, _, body = _raw(path, batch, {**JSON, wire.HEADER: "99"})
        replies = json.loads(body)
        assert [r["id"] for r in replies] == [1, 2], replies
        assert all(r["error"]["code"] == wire.MISMATCH for r in replies)
        only_notes = [{"jsonrpc": "2.0", "method": "tools/list"}]
        status, _, body = _raw(path, only_notes, {**JSON, wire.HEADER: "99"})
        assert (status, body) == (202, b"")


def test_a_refusal_before_dispatch_still_says_which_wire_the_engine_speaks() -> None:
    with _engine() as path:
        status, resp, _ = _raw(path, None, {}, method="GET")
        assert status == 405
        assert resp.getheader(wire.HEADER) == str(wire.VERSION)


def test_the_connection_ceilings_503_says_which_wire_the_engine_speaks() -> None:
    """The one reply written as fixed bytes on the accept thread, outside the handler. Without the
    header, a client of another release would read a busy engine as a wire mismatch."""
    httpd = server._BoundedThreadingHTTPServer(("127.0.0.1", 0), server._Handler)
    try:
        head = httpd._busy_response.split(b"\r\n\r\n")[0].decode()
    finally:
        httpd.server_close()
    assert f"\r\n{wire.HEADER}: {wire.VERSION}\r\n" in head + "\r\n", head


@contextlib.contextmanager
def _canned(headers: str, body: bytes = b'{"jsonrpc":"2.0","id":1,"result":{}}'):
    """A listener that records the request and answers with these response headers."""
    with tempfile.TemporaryDirectory(dir="/tmp") as root:
        d = Path(root) / "engine"
        d.mkdir(mode=0o700)
        path = d / "substrate.sock"
        lsock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        lsock.bind(str(path))
        lsock.listen()
        seen = bytearray()

        def _run() -> None:
            conn, _ = lsock.accept()
            with conn:
                conn.settimeout(5)
                while b"\r\n\r\n" not in seen:
                    chunk = conn.recv(65536)
                    if not chunk:
                        return
                    seen.extend(chunk)
                head, _, rest = bytes(seen).partition(b"\r\n\r\n")
                length = next(int(line.split(b":")[1]) for line in head.split(b"\r\n")
                              if line.lower().startswith(b"content-length"))
                while len(rest) < length:
                    chunk = conn.recv(65536)
                    if not chunk:
                        return
                    rest += chunk
                conn.sendall(b"HTTP/1.1 200 OK\r\nContent-Type: application/json\r\n"
                             + headers.encode() + f"Content-Length: {len(body)}\r\n\r\n".encode()
                             + body)

        th = threading.Thread(target=_run, daemon=True)
        th.start()
        try:
            yield path, seen
        finally:
            lsock.close()
            th.join(5)


def test_the_client_states_its_version() -> None:
    with _canned(f"{wire.HEADER}: 1\r\n") as (path, seen):
        local_socket.post(path, b"{}", timeout=5)
        assert f"\r\n{wire.HEADER}: {wire.VERSION}\r\n".encode() in bytes(seen), bytes(seen)


def test_an_engine_that_states_no_version_is_read_as_version_one() -> None:
    """Every engine before the header existed."""
    with _canned("") as (path, _):
        status, _ = local_socket.post(path, b"{}", timeout=5)
        assert status == 200


def test_a_reply_in_a_version_the_client_does_not_read_is_refused_before_decoding() -> None:
    """Unreadable, or from an engine older than this client: an engine that served this client
    states its own version or a newer one."""
    with mock.patch.object(wire, "VERSION", 3):
        for stated in ("2", "nope", ""):
            with _canned(f"{wire.HEADER}: {stated}\r\n") as (path, _):
                try:
                    local_socket.post(path, b"{}", timeout=5)
                except wire.WireMismatch as e:
                    assert stated in str(e), e
                else:
                    raise AssertionError(f"a reply stating wire {stated!r} was handed on")


def test_a_reply_from_a_newer_engine_is_read() -> None:
    """THE RANGE, from the client's side. The engine answered, so this client is inside its range,
    and every change since this client's version is one it can ignore."""
    for stated in (str(wire.VERSION), str(wire.VERSION + 1), str(wire.VERSION + 7)):
        with _canned(f"{wire.HEADER}: {stated}\r\n") as (path, _):
            status, _ = local_socket.post(path, b"{}", timeout=5)
            assert status == 200, stated


@pytest.mark.parametrize(("lowest", "highest", "client", "served", "says"), [
    (1, 3, "1", True, None), (1, 3, "2", True, None), (1, 3, "3", True, None),
    (2, 3, "1", False, "update the client"), (1, 3, "4", False, "update the engine"),
    (2, 2, "3", False, "serves substrate wire 2 and"), (1, 3, "4", False, "serves substrate wire 1 to 3"),
])
def test_the_engine_serves_every_client_in_its_declared_range(lowest, highest, client, served,
                                                              says) -> None:
    """THE RANGE, from the engine's side: `MIN_VERSION` to `VERSION`, and nothing outside it."""
    with mock.patch.object(wire, "MIN_VERSION", lowest), mock.patch.object(wire, "VERSION", highest):
        why = wire.unserved([client])
    assert (why is None) == served, why
    if says:
        assert says in why and client in why, why


def test_the_bridge_says_the_two_releases_do_not_share_a_format() -> None:
    with mock.patch.object(wire, "VERSION", 3), _canned(f"{wire.HEADER}: 2\r\n") as (path, _):
        reply = bridge.Remote(path)(3, "search", {"scope": "demo", "query": "x"})
    assert reply["id"] == 3 and reply["result"]["isError"] is True
    text = reply["result"]["content"][0]["text"]
    assert "speaks substrate wire 2" in text and "ingest" in text, text


def test_the_engines_refusal_of_this_client_reads_the_same_as_an_unread_reply() -> None:
    """The same fact from the other side: an engine that will not serve this client's version."""
    refusal = json.dumps(wire.refusal({"id": 1}, "this engine speaks substrate wire 2 and the "
                                                 "client speaks 1")).encode()
    with _canned(f"{wire.HEADER}: 1\r\n", body=refusal) as (path, _):
        reply = bridge.Remote(path)(5, "search", {"scope": "demo", "query": "x"})
    assert reply["id"] == 5 and reply["result"]["isError"] is True, reply
    text = reply["result"]["content"][0]["text"]
    assert "speaks substrate wire 2" in text and "do not share a reply format" in text, text


def test_an_engine_of_another_release_does_not_block_a_local_write() -> None:
    """Deliberate: its registry cannot be read, so it is unknown, and unknown is not a
    disagreement (`Remote.registry_disagreement`). Every read in that session already fails
    loudly, so no search is silently narrowed."""
    with _canned(f"{wire.HEADER}: 2\r\n") as (path, _):
        assert bridge.Remote(path).registry_disagreement(Path("/tmp/any.toml")) is None


def test_wire_declared_reads_only_a_plain_positive_integer() -> None:
    assert wire.declared(None) == wire.UNSTATED == 1
    assert wire.declared(" 3\t") == 3
    for bad in ("", "x", "0", "+1", "1e2", "٣", "1\x0b", "\x1c1", "1234567890", "9" * 5000):
        try:
            wire.declared(bad)
        except ValueError:
            pass
        else:
            raise AssertionError(f"{bad!r} read as a version")


def test_a_malformed_value_is_not_echoed_back_whole() -> None:
    try:
        wire.declared("x" * 5000)
    except ValueError as e:
        assert len(str(e)) < 100, len(str(e))
    else:
        raise AssertionError("5000 x's read as a version")


if __name__ == "__main__":
    for _name, _fn in sorted(globals().items()):
        if _name.startswith("test_") and callable(_fn):
            _fn()
            print(f"ok  {_name}")
