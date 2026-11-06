"""The shared engine answers only this user, and its clients trust only this user's engine.

Loopback TCP let any macOS user on the machine query every scope, and let any process that bound
127.0.0.1:8765 while Scripta was closed be sent every query. Its answers then reached the model as
vault content. Each test here fails on that transport: a TCP listener has no directory to check
and no peer uid to read.

Another uid cannot be produced without root, so the uid checks are exercised by making
`local_socket.peer_uid` (or `os.geteuid`) report one. That is the function both ends consult.

Runnable with `python tests/test_local_socket.py` or under pytest.
"""

from __future__ import annotations

import contextlib
import errno
import json
import os
import socket
import sys
import tempfile
import threading
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import local_socket, stack  # noqa: E402
from substrate.mcp import server  # noqa: E402

TOOLS_LIST = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}).encode()
OTHER_UID = os.geteuid() + 1


@contextlib.contextmanager
def _patched(obj, name, value):
    real = getattr(obj, name)
    setattr(obj, name, value)
    try:
        yield
    finally:
        setattr(obj, name, real)


@contextlib.contextmanager
def _socket_dir(mode: int = 0o700):
    """A fresh directory for a socket, under /tmp: the pytest tmpdir under /var/folders can push a
    socket path past the 103-byte limit."""
    with tempfile.TemporaryDirectory(dir="/tmp") as root:
        d = Path(root) / "engine"
        d.mkdir(mode=0o700)
        os.chmod(d, mode)
        yield d


@contextlib.contextmanager
def _engine(path: Path, cfg: server.Config | None = None):
    """`serve_unix` on `path` in a thread. Yields the server; stops it and joins on exit."""
    cfg = cfg or server.Config(None, stack.build(lexical_only=True))
    box: dict = {}
    ready = threading.Event()

    def _ready(httpd) -> None:
        box["httpd"] = httpd
        ready.set()

    th = threading.Thread(target=server.serve_unix, args=(cfg, path), kwargs={"ready": _ready},
                          daemon=True)
    th.start()
    assert ready.wait(10), "serve_unix never bound"
    try:
        yield box["httpd"]
    finally:
        box["httpd"].shutdown()
        th.join(10)
        assert not th.is_alive(), "serve_unix never returned"


@contextlib.contextmanager
def _recording_listener(path: Path):
    """A bare AF_UNIX listener that records every byte a client sends it, standing in for a
    squatter."""
    seen = bytearray()
    accepted = threading.Event()
    lsock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    lsock.bind(str(path))
    lsock.listen()

    def _run() -> None:
        try:
            conn, _ = lsock.accept()
        except OSError:
            return
        accepted.set()
        with conn:
            conn.settimeout(2)
            try:
                while chunk := conn.recv(65536):
                    seen.extend(chunk)
            except OSError:
                pass

    th = threading.Thread(target=_run, daemon=True)
    th.start()
    try:
        yield seen, accepted
    finally:
        lsock.close()
        th.join(5)


def _second_start(path: Path) -> int:
    """`serve_unix` on a path another engine should hold. Returns its exit code. If it binds
    instead, that is the bug, and this fails rather than serving forever."""
    box: dict = {}
    bound = threading.Event()

    def _ready(httpd) -> None:
        box["httpd"] = httpd
        bound.set()

    cfg = server.Config(None, stack.build(lexical_only=True))
    th = threading.Thread(target=lambda: box.update(code=server.serve_unix(cfg, path,
                                                                            ready=_ready)),
                          daemon=True)
    th.start()
    th.join(10)
    if bound.is_set():
        box["httpd"].shutdown()
        th.join(10)
        raise AssertionError(f"a second engine bound {path} while another held it")
    assert not th.is_alive(), "the second start neither bound nor returned"
    return box["code"]


def _tools(status_body: tuple[int, bytes]) -> list[str]:
    status, body = status_body
    assert status == 200, (status, body)
    return [t["name"] for t in json.loads(body)["result"]["tools"]]


def test_a_socket_engine_answers_this_user_and_cleans_up_after_itself() -> None:
    with _socket_dir() as d:
        path = d / "substrate.sock"
        with _engine(path):
            assert oct(os.stat(path).st_mode & 0o777) == "0o600"
            names = _tools(local_socket.post(path, TOOLS_LIST, timeout=10))
            assert "search" in names
            # The socket is shared like `--http`, so `ingest` comes off it in the same way.
            assert "ingest" not in names
        assert not path.exists(), "a stopped engine left its socket behind"


def test_the_engine_creates_its_directory_private() -> None:
    with tempfile.TemporaryDirectory(dir="/tmp") as root:
        path = Path(root) / "engine" / "substrate.sock"
        with _engine(path):
            assert oct(os.stat(path.parent).st_mode & 0o777) == "0o700"


def test_a_loose_directory_is_refused_by_the_engine_and_by_a_client() -> None:
    with _socket_dir(0o755) as d:
        path = d / "substrate.sock"
        cfg = server.Config(None, stack.build(lexical_only=True))
        assert server.serve_unix(cfg, path) == 2
        assert not path.exists()
        # Refused, not repaired: while it was loose another user could have planted the socket.
        assert oct(os.stat(d).st_mode & 0o777) == "0o755"

        # A client refuses to connect at all. The listener is bound directly, as a squatter would.
        with _recording_listener(path) as (seen, accepted):
            try:
                local_socket.post(path, TOOLS_LIST, timeout=5)
                raise AssertionError("a client trusted a socket in a 755 directory")
            except local_socket.UntrustedSocket as e:
                assert "must be 700" in str(e)
            assert not accepted.wait(0.5)
        assert not seen


def test_a_symlinked_directory_is_refused_not_followed() -> None:
    with _socket_dir() as real:
        link = real.parent / "link"
        link.symlink_to(real, target_is_directory=True)
        try:
            local_socket.check_directory(link)
            raise AssertionError("a symlinked socket directory was followed")
        except local_socket.UntrustedSocket as e:
            assert "symlink" in str(e)


def test_a_directory_owned_by_another_user_is_refused() -> None:
    with _socket_dir() as d, _patched(os, "geteuid", lambda: OTHER_UID):
        try:
            local_socket.check_directory(d)
            raise AssertionError("a directory owned by another uid was trusted")
        except local_socket.UntrustedSocket as e:
            assert "owned by uid" in str(e)


def test_a_client_refuses_a_listener_of_another_uid_before_writing_anything() -> None:
    """The squatter case. The directory passes, so only the peer check stands between the query
    and whoever is listening, and it must refuse before the first byte."""
    with _socket_dir() as d:
        path = d / "substrate.sock"
        with _recording_listener(path) as (seen, accepted), \
                _patched(local_socket, "peer_uid", lambda sock: OTHER_UID):
            try:
                local_socket.post(path, TOOLS_LIST, timeout=5)
                raise AssertionError("a client sent its query to another uid's listener")
            except local_socket.UntrustedSocket as e:
                assert f"uid {OTHER_UID}" in str(e)
            assert accepted.wait(5), "the client never connected, so the peer check never ran"
        assert bytes(seen) == b"", f"the client wrote {bytes(seen)!r} to an untrusted listener"


def _assert_another_uid_is_dropped_unanswered(*, after_the_drop: bool) -> None:
    """Send `tools/list` to the engine as another uid; nothing may answer it or reach the dispatcher.

    The engine drops such a caller at accept, so the drop can land before the request is written
    (EPIPE on the send, or on macOS rarely ENOTCONN) or while the reply is read (ECONNRESET). Each
    is the engine refusing. The read still runs after a failed send, so a reply written before the
    close would be seen. `after_the_drop` waits for the close before sending, forcing the EPIPE
    order."""
    with _socket_dir() as d:
        path = d / "substrate.sock"
        handled: list = []
        real_handle = server.handle

        def _spy(msg, cfg):
            handled.append(msg)
            return real_handle(msg, cfg)

        with _engine(path), _patched(server, "handle", _spy), \
                _patched(local_socket, "peer_uid", lambda sock: OTHER_UID):
            with socket.socket(socket.AF_UNIX, socket.SOCK_STREAM) as raw:
                raw.settimeout(5)
                raw.connect(str(path))
                if after_the_drop:
                    try:
                        early = raw.recv(1, socket.MSG_PEEK)
                    except TimeoutError:
                        raise AssertionError("the engine kept another uid's connection open") from None
                    assert early == b"", "the engine answered before the request"
                try:
                    raw.sendall(b"POST / HTTP/1.1\r\nHost: localhost\r\n"
                                b"Content-Type: application/json\r\n"
                                b"Content-Length: " + str(len(TOOLS_LIST)).encode() + b"\r\n\r\n"
                                + TOOLS_LIST)
                except OSError as e:
                    if e.errno not in (errno.EPIPE, errno.ENOTCONN):
                        raise
                try:
                    reply = raw.recv(65536)
                except ConnectionResetError:
                    reply = b""
    assert reply == b"", f"another uid was answered: {reply!r}"
    assert handled == [], "another uid's request reached the dispatcher"


def test_the_engine_drops_a_caller_of_another_uid_unanswered() -> None:
    _assert_another_uid_is_dropped_unanswered(after_the_drop=False)


def test_a_drop_that_lands_before_the_request_still_reads_as_unanswered() -> None:
    """Forces the order the unforced test reaches only by chance. Only the peek can fail here: the
    request is never delivered, so the answer and dispatch proof rests on the test above."""
    _assert_another_uid_is_dropped_unanswered(after_the_drop=True)


def test_a_stale_socket_is_replaced_and_a_live_one_is_not() -> None:
    with _socket_dir() as d:
        path = d / "substrate.sock"
        # A crashed engine's leftover: bound, never listening, closed.
        stale = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
        stale.bind(str(path))
        stale.close()
        with _engine(path):
            assert _tools(local_socket.post(path, TOOLS_LIST, timeout=10))
            # A second engine on the same path refuses rather than stealing it.
            assert _second_start(path) == 2
            assert _tools(local_socket.post(path, TOOLS_LIST, timeout=10))


def test_a_burst_of_callers_is_answered_not_refused() -> None:
    """A full listen backlog on AF_UNIX refuses at once, and every client reads that refusal as
    "no engine". With socketserver's default backlog of 5, 40 concurrent callers to a healthy
    engine lost about a quarter of their calls that way. Each must get an answer: a 200, or the
    readable 503 at the connection ceiling."""
    import time as _time

    real_handle = server.handle

    def _slow(msg, cfg):
        _time.sleep(0.05)
        return real_handle(msg, cfg)

    results: list = []
    lock = threading.Lock()

    def _caller() -> None:
        try:
            status, _ = local_socket.post(path, TOOLS_LIST, timeout=30)
            out = status
        except OSError as e:
            out = e
        with lock:
            results.append(out)

    with _socket_dir() as d, _patched(server, "handle", _slow):
        path = d / "substrate.sock"
        with _engine(path):
            callers = [threading.Thread(target=_caller) for _ in range(40)]
            for t in callers:
                t.start()
            for t in callers:
                t.join(60)
    refused = [r for r in results if not isinstance(r, int)]
    assert len(results) == 40 and not refused, f"{len(refused)} of 40 refused: {refused[:3]}"
    assert set(results) <= {200, 503}, results


def test_a_second_engine_leaves_a_busy_live_one_alone() -> None:
    """A live engine whose backlog is full refuses connections, just as a crashed one's leftover
    does. Judged by a probe, the second engine unlinked the live one's path and orphaned it."""
    with _socket_dir() as d:
        path = d / "substrate.sock"
        with _engine(path):
            def _refused(self, address):
                raise ConnectionRefusedError("backlog full")

            with _patched(socket.socket, "connect", _refused):
                assert _second_start(path) == 2
            assert path.exists(), "the live engine's socket was removed"
            assert _tools(local_socket.post(path, TOOLS_LIST, timeout=10))


def test_two_engines_starting_together_cannot_orphan_one() -> None:
    """The interleaving no probe can see: the first engine has claimed the path and removed the
    leftover, and has not yet bound. The second must not judge the path at all."""
    with _socket_dir() as d:
        path = d / "substrate.sock"
        first = local_socket.claim(path)
        try:
            # What the second engine would find mid-start: a socket file nothing accepts on.
            leftover = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
            leftover.bind(str(path))
            leftover.close()
            try:
                local_socket.claim(path)
                raise AssertionError("a second engine claimed a path the first one holds")
            except OSError as e:
                assert "already serving" in str(e)
            assert path.exists(), "the second engine removed the first one's path"
        finally:
            os.close(first)
        # Released, the path is claimable again, and the leftover is cleared.
        os.close(local_socket.claim(path))
        assert not path.exists()


def test_a_stopped_engine_gives_the_path_back() -> None:
    with _socket_dir() as d:
        path = d / "substrate.sock"
        with _engine(path):
            pass
        with _engine(path):
            assert _tools(local_socket.post(path, TOOLS_LIST, timeout=10))


def test_a_file_that_is_not_a_socket_is_left_alone() -> None:
    with _socket_dir() as d:
        path = d / "substrate.sock"
        path.write_text("not a socket")
        cfg = server.Config(None, stack.build(lexical_only=True))
        assert server.serve_unix(cfg, path) == 2
        assert path.read_text() == "not a socket"


def test_no_engine_is_a_refused_connection_not_an_untrusted_one() -> None:
    """The ordinary state while Scripta is closed. It must read as "start it", not as an attack."""
    with _socket_dir() as d:
        try:
            local_socket.post(d / "substrate.sock", TOOLS_LIST, timeout=5)
            raise AssertionError("expected no engine")
        except FileNotFoundError:
            pass
    try:
        local_socket.post(Path("/nonexistent-substrate-dir/s.sock"), TOOLS_LIST, timeout=5)
        raise AssertionError("expected no engine")
    except FileNotFoundError:
        pass


def test_peer_uid_reads_this_user_off_a_real_socket() -> None:
    a, b = socket.socketpair(socket.AF_UNIX, socket.SOCK_STREAM)
    with a, b:
        assert local_socket.peer_uid(a) == os.geteuid()
        assert local_socket.peer_uid(b) == os.geteuid()


def test_an_overlong_path_is_refused_before_the_stack_is_built() -> None:
    long = "/tmp/" + "x" * 120 + "/substrate.sock"

    def _boom(**_kw):
        raise AssertionError("the stack was built for a socket path that cannot be bound")

    with _patched(stack, "build", _boom):
        assert server.main(["--socket", long]) == 2


def test_socket_and_http_together_are_refused() -> None:
    with _patched(stack, "build", lambda **_kw: (_ for _ in ()).throw(AssertionError("built"))):
        assert server.main(["--socket", "/tmp/s.sock", "--http"]) == 2


if __name__ == "__main__":
    for _name, _fn in sorted(globals().items()):
        if _name.startswith("test_") and callable(_fn):
            _fn()
            print(f"ok  {_name}")
