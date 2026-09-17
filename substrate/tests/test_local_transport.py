"""Model requests stay on this machine by construction, not by a host check alone (GitHub #6).

`net.require_loopback` checks the host a client is built with. That says nothing about where the
request then goes: the stock urllib opener sends it to whatever proxy HTTP_PROXY or the macOS
system settings name, body included, and follows a daemon's redirect anywhere. Both paths are
exercised here against real local servers — a stand-in proxy and a stand-in redirect target, each
recording what reached it — so nothing leaves the machine while the tests run.

Runnable with `python tests/test_local_transport.py` or under pytest.
"""

from __future__ import annotations

import ast
import contextlib
import http.server
import io
import json
import os
import socket
import ssl
import sys
import threading
import urllib.request
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import net  # noqa: E402
from substrate.embed.engine import EmbeddingRefused, OllamaEmbedder  # noqa: E402
from substrate.retrieve.expand import HyDE  # noqa: E402

_PACKAGE = Path(__file__).resolve().parent.parent / "substrate"


@contextlib.contextmanager
def _server(status: int = 200, body: dict | None = None, location: str | None = None,
            host: str = "127.0.0.1"):
    """A loopback HTTP server recording every request it receives as (method, path, body)."""
    seen: list[tuple[str, str, bytes]] = []

    class Handler(http.server.BaseHTTPRequestHandler):
        def _answer(self) -> None:
            length = int(self.headers.get("Content-Length") or 0)
            seen.append((self.command, self.path, self.rfile.read(length)))
            payload = json.dumps({"models": []} if body is None else body).encode()
            self.send_response(status)
            if location:
                self.send_header("Location", location)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)

        do_GET = do_POST = _answer

        def log_message(self, *args) -> None:
            pass

    server_class = http.server.ThreadingHTTPServer
    if ":" in host:
        server_class = type("IPv6Server", (server_class,), {"address_family": socket.AF_INET6})
    httpd = server_class((host, 0), Handler)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    authority = f"[{host}]" if ":" in host else host
    try:
        yield f"http://{authority}:{httpd.server_address[1]}", seen
    finally:
        httpd.shutdown()
        httpd.server_close()


@contextlib.contextmanager
def _proxy_environment(proxy: str):
    """HTTP_PROXY set, and nothing exempting loopback from it — what a corporate shell exports.

    `urllib.request.urlopen` caches its opener, and the proxy settings with it, on first use. It is
    dropped on the way in, or a call site that went back to `urlopen` would pass here on whatever
    an earlier test cached; and on the way out, or later callers would keep this dead proxy."""
    keys = ("http_proxy", "HTTP_PROXY", "https_proxy", "HTTPS_PROXY", "no_proxy", "NO_PROXY")
    saved = {k: os.environ.pop(k, None) for k in keys}
    os.environ["http_proxy"] = os.environ["HTTP_PROXY"] = proxy
    urllib.request.install_opener(None)
    try:
        yield
    finally:
        urllib.request.install_opener(None)
        for k in keys:
            os.environ.pop(k, None)
            if saved[k] is not None:
                os.environ[k] = saved[k]


def test_model_requests_bypass_a_configured_proxy() -> None:
    # The stand-in proxy answers the way the daemon would, so an unguarded client succeeds
    # through it and the failure is the assertion below rather than a missing field.
    answer = {"embeddings": [[1.0, 0.0]], "models": []}
    with _server(body=answer) as (proxy, via_proxy), \
            _server(body={"embeddings": [[1.0, 0.0]]}) as (daemon, direct), \
            _proxy_environment(proxy):
        # The control: in this environment the stock opener DOES route a loopback request through
        # the proxy, so the assertions below cannot pass merely because no proxy was in play.
        urllib.request.build_opener().open(f"{daemon}/api/tags", timeout=10).close()
        assert len(via_proxy) == 1, "the stand-in proxy was not used by the stock opener"
        via_proxy.clear()

        OllamaEmbedder(host=daemon).embed_documents(["the corpus"])
        assert via_proxy == [], f"a model request went through the proxy: {via_proxy}"
        assert [body for _, _, body in direct if b"the corpus" in body], "the daemon was not asked"


def test_a_redirect_is_refused_not_followed() -> None:
    with _server() as (target, reached):
        for code in (301, 302, 303, 307, 308):
            with _server(status=code, location=f"{target}/api/embed") as (daemon, _):
                request = urllib.request.Request(f"{daemon}/api/embed", data=b"the corpus")
                try:
                    net.open_local(request, timeout=10)
                except net.RedirectRefused as e:
                    assert str(code) in e.reason and target in e.reason, e.reason
                    e.close()
                else:
                    raise AssertionError(f"a {code} redirect was followed")
        assert reached == [], f"a redirect reached its target: {reached}"


def test_clients_report_a_redirect_without_retrying_it() -> None:
    """The embedder bisects a failed batch and then shrinks each input. A refusal is not about
    size, so retrying it only repeats the request and ends on a misleading message. The last
    three locations are ones urllib turns away by itself before a redirect hook runs — the last
    one by raising ValueError. A 302, because urllib follows that for a POST and not a 307."""
    with _server() as (target, reached):
        for location in (f"{target}/api/embed", "file:///etc/hosts", None, "http://[bad"):
            with _server(status=302, location=location) as (daemon, asked):
                try:
                    OllamaEmbedder(host=daemon).embed_documents(["a", "b", "c", "d"])
                except EmbeddingRefused as e:
                    assert "redirect" in str(e), e
                else:
                    raise AssertionError(f"the embedder accepted a redirect to {location}")
                assert len(asked) == 1, f"a refused request was sent {len(asked)} times"

                assert HyDE(host=daemon).expand("the query") == "the query", "HyDE must fall open"
        assert reached == [], f"a redirect reached its target: {reached}"


def test_a_host_changed_after_construction_is_refused() -> None:
    """The constructor's check says nothing about a value assigned later. 0.0.0.0 is not a
    loopback name, and connecting to it fails fast, so a missing check cannot hang this test. The
    tab is one urlsplit deletes, which used to escape as an InvalidURL rather than a refusal."""
    for host in ("http://0.0.0.0:9", "http://local\thost:9"):
        embedder = OllamaEmbedder()
        embedder.host = host
        try:
            embedder.embed_documents(["the corpus"])
        except EmbeddingRefused as e:
            assert "loopback" in str(e), e
        else:
            raise AssertionError(f"a request was sent to {host!r}")


def test_open_local_refuses_before_opening_anything() -> None:
    for url in ("http://0.0.0.0:9/", "file://localhost/etc/hosts", "ftp://127.0.0.1:9/",
                "http://127.0.0.1@0.0.0.0:9/"):
        try:
            net.open_local(url, timeout=1)
        except net.EgressRefused:
            continue
        raise AssertionError(f"{url} was opened")


def test_a_port_that_is_not_a_number_is_refused() -> None:
    """`.hostname` stops at the first colon and http.client splits host from port at the last, so
    these read as loopback and dialled the DNS name `127.0.0.1:x.invalid`. Connections are
    recorded here, never made."""
    dialled: list[tuple] = []

    def record(address, *args, **kwargs):
        dialled.append(address)
        raise OSError("recorded, not connected")

    real, socket.create_connection = socket.create_connection, record
    try:
        for url in ("http://127.0.0.1:x.invalid:80/", "http://localhost:x.invalid:80/",
                    "http://[::1]:x.invalid:80/", "http://127.0.0.1:11434:80/"):
            try:
                net.open_local(url, timeout=1)
            except net.EgressRefused:
                continue
            except OSError:
                pass
            raise AssertionError(f"{url} was dialled as {dialled}")
    finally:
        socket.create_connection = real
    assert dialled == [], dialled


class _PeerSocket:
    """A connected socket reporting `peer` as its far end, and recording what is written to it.
    Answers like a daemon, so a request that is NOT refused completes rather than hangs."""

    def __init__(self, peer: str | Exception) -> None:
        self.peer, self.sent, self.closed = peer, [], False

    def getpeername(self):
        if isinstance(self.peer, Exception):
            raise self.peer
        return (self.peer, 11434)

    def setsockopt(self, *args) -> None:
        pass

    def sendall(self, data) -> None:
        self.sent.append(bytes(data))

    def makefile(self, *args, **kwargs):
        return io.BytesIO(b"HTTP/1.1 200 OK\r\nContent-Length: 2\r\n\r\n{}")

    def close(self) -> None:
        self.closed = True


@contextlib.contextmanager
def _connections_report(peer: str | Exception):
    """Every connection opened in the block is a `_PeerSocket` reporting `peer`, and every TLS
    wrap is recorded rather than performed. No connection is made."""
    opened: list[_PeerSocket] = []
    wrapped: list[object] = []

    def connect(address, *args, **kwargs):
        opened.append(_PeerSocket(peer))
        return opened[-1]

    def wrap(context, sock, *args, **kwargs):
        wrapped.append(sock)
        raise OSError("recorded, not wrapped")

    real_connect, socket.create_connection = socket.create_connection, connect
    real_wrap, ssl.SSLContext.wrap_socket = ssl.SSLContext.wrap_socket, wrap
    try:
        yield opened, wrapped
    finally:
        socket.create_connection = real_connect
        ssl.SSLContext.wrap_socket = real_wrap


def test_a_socket_connected_off_loopback_is_sent_nothing() -> None:
    """The URL rules judge a spelling. Here `localhost` resolves somewhere else: the socket reports
    a non-loopback peer, and not a byte may be written to it — no request, and for https no TLS
    handshake either."""
    for scheme in ("http", "https"):
        with _connections_report("192.0.2.1") as (opened, wrapped):
            request = urllib.request.Request(f"{scheme}://localhost:11434/api/embed",
                                             data=b"the corpus")
            try:
                net.open_local(request, timeout=1)
            except net.EgressRefused as e:
                assert "192.0.2.1" in str(e.reason), e
            else:
                raise AssertionError(f"a {scheme} request was written to a non-loopback peer")
        assert len(opened) == 1 and opened[0].sent == [] and opened[0].closed, vars(opened[0])
        assert wrapped == [], f"a TLS handshake began with a non-loopback peer over {scheme}"


def test_a_socket_whose_peer_cannot_be_read_is_closed() -> None:
    """A daemon that resets right after the handshake makes `getpeername()` itself fail. The
    request still fails, and the socket must not be left for the garbage collector."""
    with _connections_report(OSError(22, "Invalid argument")) as (opened, _):
        try:
            net.open_local("http://127.0.0.1:11434/api/tags", timeout=1)
        except OSError:
            pass
        else:
            raise AssertionError("a socket with no readable peer was used")
    assert len(opened) == 1 and opened[0].sent == [] and opened[0].closed, vars(opened[0])


def test_loopback_peers_are_told_apart() -> None:
    for peer in ("127.0.0.1", "127.8.9.10", "::1", "::ffff:127.0.0.1"):
        assert net._is_loopback_peer(peer), peer
    for peer in ("192.0.2.1", "10.0.0.5", "0.0.0.0", "::ffff:192.0.2.1", "fe80::1%en0",
                 "not-an-ip"):
        assert not net._is_loopback_peer(peer), peer


def test_an_ipv6_loopback_daemon_is_reached() -> None:
    """The peer check reads a 4-tuple from an IPv6 socket; a real one must still pass."""
    try:
        probe = socket.socket(socket.AF_INET6, socket.SOCK_STREAM)
        probe.bind(("::1", 0))
        probe.close()
    except OSError:
        return  # no IPv6 loopback on this machine
    with _server(host="::1") as (daemon, seen):
        net.open_local(f"{daemon}/api/tags", timeout=10).close()
    assert len(seen) == 1, seen


def test_no_model_request_bypasses_the_shared_transport() -> None:
    """A call site reaching for `urlopen`, a hand-built opener or another HTTP client would bring
    the proxy and the redirects back without a sound. Only `net.py` opens connections. Parsed
    rather than grepped, so an aliased import (`from urllib.request import urlopen as fetch`) is
    caught too."""
    openers = {"urlopen", "build_opener", "OpenerDirector", "HTTPConnection", "HTTPSConnection",
               "create_connection"}
    clients = {"requests", "httpx", "urllib3", "aiohttp"}
    offenders = []
    for path in sorted(_PACKAGE.rglob("*.py")):
        if path == _PACKAGE / "net.py":
            continue
        for node in ast.walk(ast.parse(path.read_text(encoding="utf-8"))):
            if isinstance(node, ast.Import):
                hit = any(a.name.split(".")[0] in clients for a in node.names)
            elif isinstance(node, ast.ImportFrom):
                hit = ((node.module or "").split(".")[0] in clients
                       or any(a.name in openers for a in node.names))
            elif isinstance(node, ast.Attribute):
                hit = node.attr in openers
            elif isinstance(node, ast.Name):
                hit = node.id in openers
            else:
                hit = False
            if hit:
                offenders.append(f"{path.relative_to(_PACKAGE.parent)}:{node.lineno}")
    assert offenders == [], offenders


if __name__ == "__main__":
    _tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    _failed = 0
    for _t in _tests:
        try:
            _t()
            print(f"  PASS  {_t.__name__}")
        except Exception as e:  # noqa: BLE001
            _failed += 1
            print(f"  FAIL  {_t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(_tests) - _failed}/{len(_tests)} passed")
    raise SystemExit(1 if _failed else 0)
