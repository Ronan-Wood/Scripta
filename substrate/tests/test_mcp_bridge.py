"""`--connect`: one shared server for the reads, and `ingest` kept off its socket.

Each stdio client used to spawn a full engine of its own. The bridge replaces that with a process
that builds no stack and forwards reads to the server Scripta hosts on a Unix socket. These tests
check the four properties the design rests on:
  * reads really are answered by the shared server;
  * the write never travels over the socket;
  * a closed Scripta is an error the model can read, not a dead tool list;
  * a listener that is not this user's engine is sent nothing, and nothing it says is relayed.
"""

from __future__ import annotations

import http.server
import io
import json
import os
import socketserver
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))
sys.path.insert(0, str(Path(__file__).resolve().parent))

from substrate import local_socket, stack  # noqa: E402
from substrate.mcp import bridge, server  # noqa: E402
from test_local_socket import OTHER_UID, _engine, _patched, _socket_dir  # noqa: E402
from test_mcp_server import _NOTE, REPO, _call, _cfg, _fixture  # noqa: E402


def _no_engine() -> Path:
    """A socket path in a private directory, with nothing bound: Scripta closed."""
    return Path(tempfile.mkdtemp(dir="/tmp")) / "substrate.sock"


def _bridge(registry: Path, remote) -> server.Config:
    return server.Config(str(registry), None, remote=remote)


def _tools_call(cfg: server.Config, name: str, args: dict, rid: int = 7) -> dict:
    return server.handle({"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                          "params": {"name": name, "arguments": args}}, cfg)


class _Recorder:
    """A stand-in for `bridge.Remote` that records what reached the socket."""

    def __init__(self) -> None:
        self.calls: list[str] = []

    def registry_disagreement(self, local, *, tool: str = "ingest") -> None:
        return None

    def __call__(self, rid, name, arguments) -> dict:
        self.calls.append(name)
        return {"jsonrpc": "2.0", "id": rid, "result": {"content": [{"type": "text",
                                                                     "text": "{}"}]}}


class _UnixStub(socketserver.ThreadingMixIn, socketserver.UnixStreamServer):
    daemon_threads = True


def _stub(handler_body):
    """An HTTP listener on a fresh private socket that answers every POST with
    `handler_body(handler)`. Returns (server, socket path, the bodies it was sent)."""
    seen: list[bytes] = []

    class H(http.server.BaseHTTPRequestHandler):
        def do_POST(self):  # noqa: N802
            seen.append(self.rfile.read(int(self.headers.get("Content-Length") or 0)))
            handler_body(self)

        def log_message(self, *a):
            pass

    path = Path(tempfile.mkdtemp(dir="/tmp")) / "substrate.sock"
    httpd = _UnixStub(str(path), H)
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    return httpd, path, seen


def test_reads_are_answered_by_the_shared_server() -> None:
    _, registry = _fixture()
    with _socket_dir() as d, _engine(d / "s.sock", _cfg(registry)):
        cfg = _bridge(registry, bridge.Remote(d / "s.sock"))
        resp = _tools_call(cfg, "search", {"scope": "demo", "query": "composition"})
        assert resp["id"] == 7
        body = resp["result"]
        assert not body.get("isError"), body
        bridged = json.loads(body["content"][0]["text"])
        direct = _call("search", {"scope": "demo", "query": "composition"}, registry)
        assert bridged["passages"] and bridged["passages"] == direct["passages"]
        assert cfg.stack is None, "the bridge must not have answered from a stack of its own"


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


def test_amend_never_crosses_the_socket() -> None:
    """`amend` is a write, so the same control applies: plan and commit run in the bridge."""
    from test_mcp_server import _AMENDED, _amend_fixture

    _, registry, note = _amend_fixture()
    rec = _Recorder()
    cfg = _bridge(registry, rec)
    args = {"scope": "demo", "path": "04-synthesis/d.md", "content": _AMENDED}
    plan = json.loads(_tools_call(cfg, "amend", args)["result"]["content"][0]["text"])["plan"]
    out = _tools_call(cfg, "amend", {**args, "confirm_token": plan["confirm_token"]})
    assert not out["result"].get("isError"), out
    assert note.read_text(encoding="utf-8") == _AMENDED
    assert rec.calls == [], f"amend reached the socket: {rec.calls}"


def test_amend_refusal_names_amend_when_the_engine_reads_another_registry() -> None:
    """The refusal used to be a fixed string naming `ingest`. Sent for an `amend`, it would name a
    tool the caller never called."""
    from test_mcp_server import _AMENDED, _amend_fixture

    _, registry, note = _amend_fixture()
    _, other = _fixture()
    with _socket_dir() as d, _engine(d / "s.sock", _cfg(other)):
        cfg = _bridge(registry, bridge.Remote(d / "s.sock"))
        out = _tools_call(cfg, "amend", {"scope": "demo", "path": "04-synthesis/d.md",
                                         "content": _AMENDED})
        text = out["result"]["content"][0]["text"]
        assert out["result"]["isError"] is True
        assert text.startswith("`amend` is refused"), text
    assert note.read_text(encoding="utf-8") != _AMENDED


def test_a_registry_refusal_burns_the_amend_token() -> None:
    """Refused before the handler runs, so the handler's own burn never saw it."""
    from test_mcp_server import _AMENDED, _amend_fixture

    _, registry, note = _amend_fixture()
    _, other = _fixture()
    args = {"scope": "demo", "path": "04-synthesis/d.md", "content": _AMENDED}
    cfg = _bridge(registry, _Recorder())
    token = json.loads(_tools_call(cfg, "amend", args)["result"]["content"][0]["text"])[
        "plan"]["confirm_token"]
    with _socket_dir() as d, _engine(d / "s.sock", _cfg(other)):
        cfg.remote = bridge.Remote(d / "s.sock")
        assert _tools_call(cfg, "amend", {**args, "confirm_token": token})["result"]["isError"]
    cfg.remote = _Recorder()
    out = _tools_call(cfg, "amend", {**args, "confirm_token": token})["result"]
    assert out["isError"] and "not issued" in out["content"][0]["text"], out
    assert note.read_text(encoding="utf-8") != _AMENDED


def test_a_registry_check_that_raises_burns_the_amend_token() -> None:
    """A raise from the check reached only the dispatcher's fault handler, never `_tool_amend`, so
    the token survived for a retry once the check stopped raising (adversary, 2026-11-04)."""
    from test_mcp_server import _AMENDED, _amend_fixture

    class _Raising(_Recorder):
        def registry_disagreement(self, local, *, tool="ingest"):
            raise RuntimeError("check blew up")

    _, registry, note = _amend_fixture()
    args = {"scope": "demo", "path": "04-synthesis/d.md", "content": _AMENDED}
    cfg = _bridge(registry, _Recorder())
    token = json.loads(_tools_call(cfg, "amend", args)["result"]["content"][0]["text"])[
        "plan"]["confirm_token"]
    cfg.remote = _Raising()
    assert _tools_call(cfg, "amend", {**args, "confirm_token": token})["result"]["isError"]
    cfg.remote = _Recorder()
    out = _tools_call(cfg, "amend", {**args, "confirm_token": token})["result"]
    assert out["isError"] and "not issued" in out["content"][0]["text"], out
    assert note.read_text(encoding="utf-8") != _AMENDED


def test_ingest_works_while_scripta_is_closed() -> None:
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    cfg = _bridge(registry, bridge.Remote(_no_engine()))
    out = _tools_call(cfg, "ingest", {"scope": "demo", "content": _NOTE, "filename": "d.md"})
    assert not out["result"].get("isError"), out


def test_ingest_is_refused_when_the_engine_reads_another_registry() -> None:
    """`search` comes from the engine's registry and `ingest` writes through the bridge's. If the
    two differ, the note lands in a vault the session's reads may never cover."""
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    _, other = _fixture()
    with _socket_dir() as d, _engine(d / "s.sock", _cfg(other)):
        cfg = _bridge(registry, bridge.Remote(d / "s.sock"))
        out = _tools_call(cfg, "ingest", {"scope": "demo", "content": _NOTE, "filename": "d.md"})
        assert out["result"]["isError"] is True
        text = out["result"]["content"][0]["text"]
        assert str(other.resolve()) in text and "refused" in text, text


def test_ingest_proceeds_when_the_engine_reads_the_same_registry() -> None:
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    with _socket_dir() as d, _engine(d / "s.sock", _cfg(registry)):
        cfg = _bridge(registry, bridge.Remote(d / "s.sock"))
        args = {"scope": "demo", "content": _NOTE, "filename": "d.md"}
        out = _tools_call(cfg, "ingest", args)
        assert not out["result"].get("isError"), out
        assert json.loads(out["result"]["content"][0]["text"])["plan"]["confirm_token"]


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
    cfg = _bridge(registry, bridge.Remote(_no_engine()))
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

    httpd, path, _ = _stub(answer)
    try:
        r = bridge.Remote(path)(41, "search", {})
        assert r["id"] == 41 and r["error"]["message"] == "at its ceiling", r
    finally:
        httpd.shutdown()


def test_a_stranger_on_the_socket_is_named_not_relayed() -> None:
    def answer(h):
        out = b"<html>hello</html>"
        h.send_response(200)
        h.send_header("Content-Type", "text/html")
        h.send_header("Content-Length", str(len(out)))
        h.end_headers()
        h.wfile.write(out)

    httpd, path, _ = _stub(answer)
    try:
        r = bridge.Remote(path)(3, "search", {})
        assert r["id"] == 3 and r["result"]["isError"] is True
        assert "not a JSON-RPC response" in r["result"]["content"][0]["text"]
    finally:
        httpd.shutdown()


def test_a_hung_server_is_bounded() -> None:
    gate = threading.Event()

    def answer(h):
        gate.wait(5)

    httpd, path, _ = _stub(answer)
    try:
        t0 = time.monotonic()
        r = bridge.Remote(path, timeout=0.3)(4, "search", {})
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
        assert cfg.remote.path == local_socket.default_path()

        assert server.main(["--connect", "/tmp/elsewhere/s.sock", "--read-only",
                            "--registry", str(registry)]) == 0
        assert seen["cfg"].read_only is True
        assert seen["cfg"].remote.path == Path("/tmp/elsewhere/s.sock")
    finally:
        server.serve, stack.build = real


def test_main_connect_refuses_what_it_cannot_honour() -> None:
    real_err = sys.stderr
    sys.stderr = io.StringIO()
    try:
        # TCP is not a transport --connect offers, loopback included: whoever holds the port while
        # Scripta is closed would be sent every query.
        for spec in ("127.0.0.1:8765", "localhost:8765", "10.0.0.5:8765"):
            assert server.main(["--connect", spec]) == 2, spec
        assert "socket path" in sys.stderr.getvalue()
        assert server.main(["--connect", "--http"]) == 2
        assert server.main(["--connect", "--socket"]) == 2
        assert server.main(["--connect", "/tmp/" + "x" * 120 + "/s.sock"]) == 2
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
        [sys.executable, "-m", "substrate.mcp.server", "--connect", str(_no_engine())],
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

    httpd, path, _ = _stub(answer)
    try:
        cfg = _bridge(registry, bridge.Remote(path))
        args = {"scope": "demo", "content": _NOTE, "filename": "d.md"}
        assert not _tools_call(cfg, "ingest", args)["result"].get("isError")
        reported["registry"] = "/somewhere/else/scopes.toml"
        assert _tools_call(cfg, "ingest", args)["result"]["isError"] is True
    finally:
        httpd.shutdown()


def test_a_lone_surrogate_is_forwarded_not_fatal() -> None:
    """Legal JSON (`"\\ud800"`) that UTF-8 cannot encode. It used to raise out of the forward."""
    _, registry = _fixture()
    with _socket_dir() as d, _engine(d / "s.sock", _cfg(registry)):
        cfg = _bridge(registry, bridge.Remote(d / "s.sock"))
        resp = _tools_call(cfg, "search", {"scope": "demo", "query": "composition \ud800"})
        assert resp["id"] == 7 and "result" in resp, resp


def test_a_fault_in_the_forward_is_a_tool_fault() -> None:
    """Anything the forward raises comes back as an isError result under the caller's id, the
    same as a fault inside a tool, rather than escaping the dispatcher."""
    class _Broken(_Recorder):
        def __call__(self, rid, name, arguments):
            raise RuntimeError("forward blew up")

        def registry_disagreement(self, local, *, tool="ingest"):
            raise RuntimeError("check blew up")

    _, registry = _fixture()
    cfg = _bridge(registry, _Broken())
    for tool, args in (("search", {"scope": "demo", "query": "x"}),
                       ("ingest", {"scope": "demo", "content": _NOTE, "filename": "d.md"})):
        resp = _tools_call(cfg, tool, args)
        assert resp["id"] == 7 and resp["result"]["isError"] is True, resp
        assert "blew up" in resp["result"]["content"][0]["text"]


def _registry_answer(registry: str):
    """A stub body that answers every call as `list_scopes` reporting `registry`."""
    def answer(h):
        text = json.dumps({"scopes": [], "registry": registry})
        out = json.dumps({"jsonrpc": "2.0", "id": 0, "result": {
            "content": [{"type": "text", "text": text}]}}).encode()
        h.send_response(200)
        h.send_header("Content-Type", "application/json")
        h.send_header("Content-Length", str(len(out)))
        h.end_headers()
        h.wfile.write(out)
    return answer


def test_a_squatter_of_another_uid_is_sent_no_query() -> None:
    """The case loopback TCP lost: Scripta is closed and someone else holds the address. The query
    names a scope and carries the reader's own words, so the refusal has to come BEFORE the
    write. An answer is then never read, so none can reach the model as vault content."""
    _, registry = _fixture()
    httpd, path, seen = _stub(_registry_answer(str(registry)))
    try:
        cfg = _bridge(registry, bridge.Remote(path))
        with _patched(local_socket, "peer_uid", lambda sock: OTHER_UID):
            resp = _tools_call(cfg, "search", {"scope": "atlas", "query": "the private question"})
        assert resp["id"] == 7 and resp["result"]["isError"] is True, resp
        text = resp["result"]["content"][0]["text"]
        assert "NOT sent" in text and f"uid {OTHER_UID}" in text, text
        assert seen == [], f"the squatter was sent {seen}"
    finally:
        httpd.shutdown()


def test_a_squatter_cannot_vouch_for_a_registry() -> None:
    """A squatter that answers `list_scopes` with a DIFFERENT registry would refuse the write if
    it were believed. It is not even asked: the write goes ahead on this process's own registry,
    exactly as when Scripta is closed, and the squatter sees nothing."""
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    httpd, path, seen = _stub(_registry_answer("/somewhere/else/scopes.toml"))
    try:
        cfg = _bridge(registry, bridge.Remote(path))
        with _patched(local_socket, "peer_uid", lambda sock: OTHER_UID):
            out = _tools_call(cfg, "ingest", {"scope": "demo", "content": _NOTE,
                                              "filename": "d.md"})
        assert not out["result"].get("isError"), out
        assert seen == [], f"the squatter was asked {seen}"
    finally:
        httpd.shutdown()


def test_a_socket_in_a_loose_directory_is_not_trusted() -> None:
    _, registry = _fixture()
    httpd, path, seen = _stub(_registry_answer(str(registry)))
    try:
        os.chmod(path.parent, 0o755)
        resp = _tools_call(_bridge(registry, bridge.Remote(path)), "search",
                           {"scope": "demo", "query": "x"})
        assert resp["result"]["isError"] is True
        assert "must be 700" in resp["result"]["content"][0]["text"]
        assert seen == []
    finally:
        httpd.shutdown()
