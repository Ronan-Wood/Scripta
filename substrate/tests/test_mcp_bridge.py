"""`--connect`: one shared server for the reads, and `ingest` kept off its socket.

Each stdio client used to spawn a full engine of its own. The bridge replaces that with a process
that builds no stack and forwards reads to the loopback server Scripta hosts. These tests check
the three properties the design rests on:
  * reads really are answered by the shared server;
  * the write never travels over the socket;
  * a closed Scripta is an error the model can read, not a dead tool list.
"""

from __future__ import annotations

import http.server
import io
import json
import socket
import subprocess
import sys
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from substrate import stack  # noqa: E402
from substrate.mcp import bridge, server  # noqa: E402
from test_mcp_server import _NOTE, REPO, _call, _cfg, _fixture, _http_server  # noqa: E402


def _closed_port() -> int:
    s = socket.socket()
    s.bind(("127.0.0.1", 0))
    port = s.getsockname()[1]
    s.close()
    return port


def _bridge(registry: Path, remote) -> server.Config:
    return server.Config(str(registry), None, remote=remote)


def _tools_call(cfg: server.Config, name: str, args: dict, rid: int = 7) -> dict:
    return server.handle({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                          "params": {"name": name, "arguments": args}}, cfg)


class _Recorder:
    """A stand-in for `bridge.Remote` that records what reached the socket."""

    def __init__(self) -> None:
        self.calls: list[str] = []

    def registry_disagreement(self, local) -> None:
        return None

    def __call__(self, rid, name, arguments) -> dict:
        self.calls.append(name)
        return {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text",
                                                                     "text": "{}"}]}}


def _stub(handler_body):
    """A loopback HTTP listener that answers every POST with `handler_body(handler)`."""

    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            self.rfile.read(int(self.headers.get("Content-Length") or 0))
            handler_body(self)

        def log_message(self, *a):
            pass

    httpd = http.server.ThreadingHTTPServer(("127.0.0.1", 0), H)
    httpd.daemon_threads = True
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd


def test_reads_are_answered_by_the_shared_server() -> None:
    _, registry = _fixture()
    base, stop = _http_server(_cfg(registry))
    try:
        port = int(base.rsplit(":", 1)[1])
        cfg = _bridge(registry, bridge.Remote("127.0.0.1", port))
        resp = _tools_call(cfg, "search", {"scope": "demo", "query": "composition"})
        assert resp["id"] == 7
        body = resp["result"]
        assert not body.get("isError"), body
        bridged = json.loads(body["content"][0]["text"])
        direct = _call("search", {"scope": "demo", "query": "composition"}, registry)
        assert bridged["passages"] and bridged["passages"] == direct["passages"]
        assert cfg.stack is None, "the bridge must not have answered from a stack of its own"
    finally:
        stop()


def test_ingest_never_crosses_the_socket() -> None:
    """The control in Doc 3 §3 is that the write is OFF the socket. A forwarded ingest would
    land on a read-only server and be refused, and a server that accepted it would be the
    hole itself. So plan and commit both run in the bridge, against its own PlanBook."""
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    rec = _Recorder()
    cfg = _bridge(registry, rec)
    args = {"scope": "demo", "content": _NOTE, "filename": "d.md"}
    plan = json.loads(_tools_call(cfg, "ingest", args)["result"]["content"][0]["text"])["plan"]
    out = _tools_call(cfg, "ingest", {**args, "confirm_token": plan["confirm_token"]})
    assert not out["result"].get("isError"), out
    assert json.loads(out["result"]["content"][0]["text"])["written"] is True
    assert (root / "demo-vault" / "04-synthesis" / "d.md").exists()
    assert rec.calls == [], f"ingest reached the socket: {rec.calls}"

    _tools_call(cfg, "search", {"scope": "demo", "query": "x"})
    assert rec.calls == ["search"], "every read tool must be forwarded"


def test_ingest_works_while_scripta_is_closed() -> None:
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    cfg = _bridge(registry, bridge.Remote("127.0.0.1", _closed_port()))
    out = _tools_call(cfg, "ingest", {"scope": "demo", "content": _NOTE, "filename": "d.md"})
    assert not out["result"].get("isError"), out


def test_ingest_is_refused_when_the_engine_reads_another_registry() -> None:
    """`search` comes from the engine's registry and `ingest` writes through the bridge's. If the
    two differ, the note lands in a vault the session's reads may never cover."""
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    _, other = _fixture()
    base, stop = _http_server(_cfg(other))
    try:
        port = int(base.rsplit(":", 1)[1])
        cfg = _bridge(registry, bridge.Remote("127.0.0.1", port))
        out = _tools_call(cfg, "ingest", {"scope": "demo", "content": _NOTE, "filename": "d.md"})
        assert out["result"]["isError"] is True
        text = out["result"]["content"][0]["text"]
        assert str(other.resolve()) in text and "refused" in text, text
    finally:
        stop()


def test_ingest_proceeds_when_the_engine_reads_the_same_registry() -> None:
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    base, stop = _http_server(_cfg(registry))
    try:
        port = int(base.rsplit(":", 1)[1])
        cfg = _bridge(registry, bridge.Remote("127.0.0.1", port))
        args = {"scope": "demo", "content": _NOTE, "filename": "d.md"}
        out = _tools_call(cfg, "ingest", args)
        assert not out["result"].get("isError"), out
        assert json.loads(out["result"]["content"][0]["text"])["plan"]["confirm_token"]
    finally:
        stop()


def test_the_bridge_lists_every_tool_without_reaching_the_server() -> None:
    """A client reads the tool list once, at connect time. If the bridge needed the server for
    that, opening a session before Scripta would leave the session with no substrate tools."""
    _, registry = _fixture()
    rec = _Recorder()
    cfg = _bridge(registry, rec)
    init = server.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize"}, cfg)
    assert init["result"]["serverInfo"]["name"] == "substrate"
    listed = server.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, cfg)
    names = {t["name"] for t in listed["result"]["tools"]}
    assert {"search", "expand", "status", "documents", "list_scopes", "ingest"} <= names, names
    assert rec.calls == []


def test_local_refusals_happen_before_forwarding() -> None:
    _, registry = _fixture()
    rec = _Recorder()
    cfg = _bridge(registry, rec)
    assert "error" in _tools_call(cfg, "no_such_tool", {})
    ro = server.Config(str(registry), None, read_only=True, remote=rec)
    assert _tools_call(ro, "ingest", {"scope": "demo"})["result"]["isError"]
    assert rec.calls == []


def test_a_closed_scripta_is_a_readable_tool_error() -> None:
    _, registry = _fixture()
    cfg = _bridge(registry, bridge.Remote("127.0.0.1", _closed_port()))
    resp = _tools_call(cfg, "search", {"scope": "demo", "query": "x"})
    assert resp["id"] == 7
    body = resp["result"]
    assert body["isError"] is True
    text = body["content"][0]["text"]
    assert "Open Scripta" in text and "ingest" in text, text


def test_a_null_id_refusal_comes_back_under_the_callers_id() -> None:
    """The server's pre-read refusals (the 503 at its connection ceiling, the guards' 4xx)
    carry `id: null`. Relayed as they are, the client's call would never resolve."""
    def answer(h):
        out = json.dumps({"jsonrpc": "2.0", "id": None,
                          "error": {"code": -32603, "message": "at its ceiling"}}).encode()
        h.send_response(503)
        h.send_header("Content-Type", "application/json")
        h.send_header("Content-Length", str(len(out)))
        h.end_headers()
        h.wfile.write(out)

    httpd = _stub(answer)
    try:
        r = bridge.Remote("127.0.0.1", httpd.server_address[1])(41, "search", {})
        assert r["id"] == 41 and r["error"]["message"] == "at its ceiling", r
    finally:
        httpd.shutdown()


def test_a_stranger_on_the_port_is_named_not_relayed() -> None:
    def answer(h):
        out = b"<html>hello</html>"
        h.send_response(200)
        h.send_header("Content-Type", "text/html")
        h.send_header("Content-Length", str(len(out)))
        h.end_headers()
        h.wfile.write(out)

    httpd = _stub(answer)
    try:
        r = bridge.Remote("127.0.0.1", httpd.server_address[1])(3, "search", {})
        assert r["id"] == 3 and r["result"]["isError"] is True
        assert "not a JSON-RPC response" in r["result"]["content"][0]["text"]
    finally:
        httpd.shutdown()


def test_a_hung_server_is_bounded() -> None:
    gate = threading.Event()

    def answer(h):
        gate.wait(5)

    httpd = _stub(answer)
    try:
        t0 = time.monotonic()
        r = bridge.Remote("127.0.0.1", httpd.server_address[1], timeout=0.3)(4, "search", {})
        assert time.monotonic() - t0 < 3
        assert r["result"]["isError"] is True and "did not answer" in \
            r["result"]["content"][0]["text"]
    finally:
        gate.set()
        httpd.shutdown()


def test_main_connect_builds_no_stack_and_keeps_ingest() -> None:
    _, registry = _fixture()
    seen: dict = {}

    def _capture(cfg, *a, **kw):
        seen["cfg"] = cfg
        return 0

    def _refuse(**kw):
        raise AssertionError("--connect built a retrieval stack")

    real = server.serve, stack.build
    server.serve, stack.build = _capture, _refuse
    try:
        assert server.main(["--connect", "--registry", str(registry)]) == 0
        cfg = seen["cfg"]
        assert cfg.stack is None and cfg.read_only is False
        assert (cfg.remote.host, cfg.remote.port) == ("127.0.0.1", 8765)

        assert server.main(["--connect", "127.0.0.1:9999", "--read-only",
                            "--registry", str(registry)]) == 0
        assert seen["cfg"].read_only is True and seen["cfg"].remote.port == 9999
    finally:
        server.serve, stack.build = real


def test_main_connect_refuses_what_it_cannot_honour() -> None:
    real_err = sys.stderr
    sys.stderr = io.StringIO()
    try:
        assert server.main(["--connect", "10.0.0.5:8765"]) == 2
        assert "loopback" in sys.stderr.getvalue()
        assert server.main(["--connect", "--http"]) == 2
    finally:
        sys.stderr = real_err


def test_main_connect_refuses_agent_mode() -> None:
    """Agent mode narrows a server to snapshots, read-only. Under `--connect` it would be dropped
    without a word, and the client would get every scope the shared server holds plus `ingest`."""
    real_serve, real_err = server.serve, sys.stderr
    server.serve = lambda cfg: 0
    sys.stderr = io.StringIO()
    try:
        for extra in (["--agent-mode", "--scopes", "atlas", "--snapshot-dir", "/nonexistent"],
                      ["--scopes", "atlas"], ["--snapshot-dir", "/nonexistent"]):
            assert server.main(["--connect", *extra]) == 2, extra
        assert "--agent-mode" in sys.stderr.getvalue()
    finally:
        server.serve, sys.stderr = real_serve, real_err


def test_main_connect_says_which_flags_it_ignores() -> None:
    """The dev shim passes `--rerank-model cross`. Under --connect the shared server's reranker
    answers, so silently accepting the flag would read as a configuration that is not in force."""
    _, registry = _fixture()
    real_serve, real_err = server.serve, sys.stderr
    server.serve, sys.stderr = (lambda cfg, *a, **kw: 0), io.StringIO()
    try:
        assert server.main(["--connect", "--rerank-model", "cross",
                            "--registry", str(registry)]) == 0
        err = sys.stderr.getvalue()
    finally:
        server.serve, sys.stderr = real_serve, real_err
    assert "ignoring --rerank-model" in err, err


def test_the_bridge_process_exits_when_its_client_goes() -> None:
    """End of stdin is how a stdio client says it has gone. A bridge that outlived it would just
    be the pile-up again, one level down."""
    proc = subprocess.run(
        [sys.executable, "-m", "substrate.mcp.server", "--connect",
         f"127.0.0.1:{_closed_port()}"],
        input=json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}) + "\n",
        capture_output=True, text=True, cwd=REPO, timeout=30)
    assert proc.returncode == 0, proc.stderr
    names = {t["name"] for t in json.loads(proc.stdout)["result"]["tools"]}
    assert "ingest" in names


def test_the_registry_is_asked_again_on_every_write() -> None:
    """The engine restarts without touching its clients, and can come back on another registry. An
    agreement remembered from before the restart would wave that write through."""
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    reported = {"registry": str(registry)}

    def answer(h):
        text = json.dumps({"scopes": [], "registry": reported["registry"]})
        out = json.dumps({"jsonrpc": "2.0", "id": 0, "result": {
            "content": [{"type": "text", "text": text}]}}).encode()
        h.send_response(200)
        h.send_header("Content-Type", "application/json")
        h.send_header("Content-Length", str(len(out)))
        h.end_headers()
        h.wfile.write(out)

    httpd = _stub(answer)
    try:
        cfg = _bridge(registry, bridge.Remote("127.0.0.1", httpd.server_address[1]))
        args = {"scope": "demo", "content": _NOTE, "filename": "d.md"}
        assert not _tools_call(cfg, "ingest", args)["result"].get("isError")
        reported["registry"] = "/somewhere/else/scopes.toml"
        assert _tools_call(cfg, "ingest", args)["result"]["isError"] is True
    finally:
        httpd.shutdown()


def test_a_lone_surrogate_is_forwarded_not_fatal() -> None:
    """Legal JSON (`"\\ud800"`) that UTF-8 cannot encode. It used to raise out of the forward."""
    _, registry = _fixture()
    base, stop = _http_server(_cfg(registry))
    try:
        port = int(base.rsplit(":", 1)[1])
        cfg = _bridge(registry, bridge.Remote("127.0.0.1", port))
        resp = _tools_call(cfg, "search", {"scope": "demo", "query": "composition \ud800"})
        assert resp["id"] == 7 and "result" in resp, resp
    finally:
        stop()


def test_a_fault_in_the_forward_is_a_tool_fault() -> None:
    """Anything the forward raises comes back as an isError result under the caller's id, the
    same as a fault inside a tool, rather than escaping the dispatcher."""
    class _Broken(_Recorder):
        def __call__(self, rid, name, arguments):
            raise RuntimeError("forward blew up")

        def registry_disagreement(self, local):
            raise RuntimeError("check blew up")

    _, registry = _fixture()
    cfg = _bridge(registry, _Broken())
    for tool, args in (("search", {"scope": "demo", "query": "x"}),
                       ("ingest", {"scope": "demo", "content": _NOTE, "filename": "d.md"})):
        resp = _tools_call(cfg, tool, args)
        assert resp["id"] == 7 and resp["result"]["isError"] is True, resp
        assert "blew up" in resp["result"]["content"][0]["text"]
