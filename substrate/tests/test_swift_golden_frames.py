"""The SubstrateKit golden frames, captured from the demo vaults rather than from anyone's real ones.

`Core/Tests/SubstrateKitTests/Fixtures/` holds the bytes the app's decoders are tested against. They
must be what the engine really sends — a fixture written from the same reading of `render.py` that
produced the decoder would agree with it by construction — and, because the repo is public, they
must hold nothing but the synthetic demo vaults. This test produces them the only way that
satisfies both: it copies `vaults/demo-vault` (which inherits `vaults/demo-core-vault`) into a
temporary workspace, composes it into a registry of its own holding the one scope `demo`, runs one
refresh pass over it (`refresh.run_pass`, its compose and embed run in this process), and sends
`server.handle` the requests in `CALLS` on a read-only `Config` — what `main()` builds for every
transport the app reaches. Each frame is serialized as the HTTP transport writes a body.

Set SUBSTRATE_CAPTURE_SWIFT_FIXTURES=1 to rewrite the frames. Without it, this test compares their
SHAPE (every key, and which values are null) with what the engine emits now, and scans the
committed bytes for this machine's paths — the same contract as the `agent-*` frames in
`test_agent_mode.py`, through the same helpers (`_swift_fixtures`).

THREE THINGS ARE STOOD IN, ALL MECHANICALLY:

  * The workspace's path becomes `/demo-substrate` (`STAND_IN`), by plain string replacement over
    the serialized frame, so the repo never carries this machine's temp layout.
  * The workspace folder is set to 0755 after the copy, and everything the capture creates is made
    under a umask of 022, so `status.exposed` names the workspace whatever the host's umask is: the
    engine reports a folder holding an index that other users can list, and without the two that
    report would depend on who ran the capture.
  * No local model server answers. `net._OPENER` — the one opener every model request goes through
    (`net.open_local`) — is replaced by one that refuses every connection, so the frames describe a
    host whose daemon is down whether or not this machine's is. `stack.build` still runs and probes
    all three arms; each probe meets a refused connection and is reported unreachable, and the
    pass's embed fails, so the refresh records `embed_failed`.

Nothing the capture runs reaches the operator's engine folder: the vector cache
(`stack.DEFAULT_CACHE`, which `embed` reads when given no `--cache`) and `scopes.engine_home` are
redirected into the temporary folder, beside the blob store `conftest.py` already isolates.
"""

from __future__ import annotations

import contextlib
import io
import json
import os
import shutil
import subprocess
import sys
import traceback
import urllib.error
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT))
sys.path.insert(0, str(Path(__file__).resolve().parent))

import _swift_fixtures as fx  # noqa: E402

from substrate import cli, net, refresh, scopes, stack  # noqa: E402
from substrate.embed import engine as embed_engine  # noqa: E402
from substrate.mcp import server  # noqa: E402

DEMO_VAULTS = ROOT / "vaults"
STAND_IN = "/demo-substrate"
# `test_agent_mode.SNAPSHOT_DIR_STAND_IN`, spelled here rather than imported so collecting this test
# never imports that module's fixtures.
AGENT_STAND_IN = "/agent-snapshots"
SCOPE = "demo"

# (fixture, JSON-RPC id, method, params). The ids are the ones `TransportTests` expects.
CALLS: list[tuple[str, int, str, dict]] = [
    ("search.frame.json", 1, "tools/call",
     {"name": "search", "arguments": {"scope": SCOPE, "query": "which engine powers the app"}}),
    ("search-sources.frame.json", 1, "tools/call",
     {"name": "search", "arguments": {
         "scope": SCOPE, "query": "what was said on the call about the engine boundary",
         "include_sources": True}}),
    ("status.frame.json", 1, "tools/call", {"name": "status", "arguments": {"scope": SCOPE}}),
    ("list_scopes.frame.json", 1, "tools/call", {"name": "list_scopes", "arguments": {}}),
    ("expand.frame.json", 1, "tools/call",
     {"name": "expand", "arguments": {"expand_ref": f"{SCOPE}/engine-boundary-current#c00000",
                                      "mode": "note"}}),
    ("documents.frame.json", 1, "tools/call",
     {"name": "documents", "arguments": {"scope": SCOPE, "limit": 3}}),
    ("tool-fault.frame.json", 7, "tools/call",
     {"name": "status", "arguments": {"scope": "no-such-scope"}}),
    ("rpc-error.frame.json", 8, "nope/nope", {}),
]
# A tool fault's sentence and a JSON-RPC error name no path by design.
NO_PATH = {"tool-fault.frame.json", "rpc-error.frame.json"}


class _NothingListening:
    """The opener of a host with no model daemon: every connection is refused, exactly as
    `urllib` reports a closed port."""

    def open(self, request, timeout=None):  # noqa: ARG002 — the opener's signature
        raise urllib.error.URLError(ConnectionRefusedError(61, "Connection refused"))


@contextlib.contextmanager
def _environ(env: dict[str, object]):
    """`os.environ` as exactly `env` for the duration, then as it was: what a child started with
    `Popen(env=env)` sees, and nothing it sets outlives it.

    Values are coerced the way `Popen` coerces them (`os.fspath`, so a `Path` is accepted) and a
    `None` is refused by name. All of it happens inside the `try`, so a value that cannot be set
    still restores the snapshot instead of leaving `os.environ` empty for the rest of the run."""
    saved = dict(os.environ)
    try:
        none = sorted(k for k, v in env.items() if v is None)
        if none:
            raise TypeError(f"child env values must not be None: {', '.join(none)}")
        coerced = {k: os.fspath(v) for k, v in env.items()}
        os.environ.clear()
        os.environ.update(coerced)
        yield
    finally:
        os.environ.clear()
        os.environ.update(saved)


def _exit_code(code: object) -> int:
    """`SystemExit`'s code as CPython turns it into a process status: None is 0, an int is itself,
    anything else is printed and is 1."""
    if code is None:
        return 0
    return code if isinstance(code, int) else 1


class _Child:
    """`refresh.run_pass`'s runner (`refresh.Runner`), run in this process: the same
    `substrate.cli` argv and env the pass builds, so the pass's own logic decides the outcome — and
    this suite's isolation (blob store, vector cache, engine home, no model daemon) reaches the
    child, which a real subprocess would escape.

    It answers as `refresh._run` does — a `CompletedProcess` with returncode, stdout and stderr —
    and fails as a child would: an uncaught exception is a returncode of 1 with the traceback on
    stderr, never an exception raised into the pass. Each such crash is ALSO kept in `crashes`, so
    the fixture can tell a crash from the one failure it expects (an unreachable daemon).

    `isolation` is every env var the fixture set, with its value. A child handed an env without
    them would run against the host's registry, so that refuses before anything runs. That refusal,
    and an env `_environ` cannot set, are crashes like any other: recorded, and rc 1 — nothing this
    wrapper meets is raised into the pass."""

    def __init__(self, isolation: dict[str, str]):
        self.isolation = isolation
        self.crashes: list[str] = []

    def __call__(self, argv: list[str], env: dict[str, object]) -> subprocess.CompletedProcess[str]:
        out, err = io.StringIO(), io.StringIO()
        try:
            args = argv[argv.index("substrate.cli") + 1:]
            lost = {k: env.get(k) for k, v in self.isolation.items()
                    if env.get(k) is None or os.fspath(env[k]) != v}
            if lost:
                raise AssertionError(f"the child env drops or changes the capture's isolation: "
                                     f"{lost}")
            with _environ(env), contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
                try:
                    code = cli.main(args)
                except SystemExit as e:
                    if e.code is not None and not isinstance(e.code, int):
                        print(e.code, file=sys.stderr)
                    code = _exit_code(e.code)
        except Exception:  # noqa: BLE001 — a child's crash is its exit status, not the pass's
            trace = traceback.format_exc()
            self.crashes.append(f"{' '.join(map(str, argv[-8:]))}: {trace}")
            err.write(trace)
            code = 1
        return subprocess.CompletedProcess(argv, _exit_code(code), out.getvalue(),
                                           err.getvalue())


@pytest.fixture
def _umask():
    """Every file the capture creates — the workspace, `demo.db`, the ingest tree, the registry —
    made under one umask, so what `exposed` reads off them is not whoever ran the capture's."""
    previous = os.umask(0o022)
    try:
        yield
    finally:
        os.umask(previous)


@pytest.fixture
def demo(tmp_path, monkeypatch, _umask):
    """The demo vault pair, composed and refreshed once into a registry of its own."""
    work = tmp_path / "work"
    shutil.copytree(DEMO_VAULTS / "demo-vault", work / "vaults" / "demo-vault")
    shutil.copytree(DEMO_VAULTS / "demo-core-vault", work / "vaults" / "demo-core-vault")
    # The folder holding the index is a holder `exposed` judges, and it may predate `_umask` (the
    # tmp folder pytest made). Fixed here so the frame says the same thing on every machine.
    work.chmod(0o755)
    registry = work / "scopes.toml"
    monkeypatch.setenv(scopes.ENV_VAR, str(registry))
    monkeypatch.setattr(net, "_OPENER", _NothingListening())
    # `embed` with no `--cache` opens `stack.DEFAULT_CACHE` (read at call time in `cmd_embed`),
    # which is the operator's; a failed probe is all that kept it closed. Neither may be reached.
    monkeypatch.setattr(stack, "DEFAULT_CACHE", tmp_path / "vector-cache.db")
    monkeypatch.setattr(scopes, "engine_home", lambda: tmp_path / "engine-home")

    child = _Child({scopes.ENV_VAR: str(registry)})
    rc = child(["substrate.cli", "compose", str(work / "vaults" / "demo-vault"),
                "--index-root", str(work / "demo-index"), "--db", str(work / "demo.db"),
                "--registry", str(registry)], dict(os.environ))
    assert rc.returncode == 0, rc.stderr
    [result] = refresh.run_pass(registry, runner=child, log=lambda _line: None)
    # A crash in any child — compose or embed — is an exit status of 1 to the pass, and embed's
    # would record `embed_failed` exactly as an unreachable daemon does. So crashes are counted
    # apart, and the refusal itself is read below: an unreachable daemon is the only way here.
    assert not child.crashes, "a child crashed during the capture:\n" + "\n".join(child.crashes)
    # The one outcome a host with no model daemon earns. Anything else is a capture of the wrong
    # state, and stops here.
    assert result.recorded and result.outcome == "embed_failed", result
    # And it was the daemon: embed's own refusal names the default address it could not reach.
    assert result.detail is not None, result
    assert f"not available at {embed_engine.DEFAULT_HOST}" in result.detail, result.detail

    retrieval = stack.build(cache_path=tmp_path / "vector-cache.db")
    assert len(retrieval.unavailable) == 3, retrieval.unavailable
    return work, server.Config(str(registry), retrieval, read_only=True)


def _frames(cfg: server.Config) -> dict[str, dict]:
    return {name: server.handle({"jsonrpc": "2.0", "id": rid, "method": method, "params": params},
                                cfg)
            for name, rid, method, params in CALLS}


def _payload_of(body: str):
    """The part of a frame the app decodes: the tool's payload, a tool fault's sentence, or a
    JSON-RPC error object."""
    frame = json.loads(body)
    if "error" in frame:
        return frame["error"]
    text = frame["result"]["content"][0]["text"]
    return text if frame["result"].get("isError") else json.loads(text)


def _serialize(frame: dict, work: Path) -> str:
    """The bytes the HTTP transport writes (`_Handler.do_POST`), with the workspace stood in.

    Both spellings of the workspace are replaced: macOS hands pytest a `/var/...` temp folder whose
    resolved form is `/private/var/...`, and the engine resolves some paths and not others."""
    body = json.dumps(frame, ensure_ascii=False)
    for spelling in sorted({str(work.resolve()), str(work)}, key=len, reverse=True):
        body = body.replace(spelling, STAND_IN)
    return body


def test_the_swift_golden_frames_are_what_the_engine_sends_over_the_demo_vaults(demo):
    work, cfg = demo
    frames = _frames(cfg)
    bodies = {name: _serialize(frame, work) for name, frame in frames.items()}
    if fx.capturing():
        fx.check_before_write(bodies, payload_of=_payload_of, stand_in=STAND_IN,
                              local=(work.parent, ROOT.parent), no_path=NO_PATH)
        fx.write_all(bodies)
    for name, body in bodies.items():
        fx.assert_matches(name, _payload_of(body), payload_of=_payload_of, stand_in=STAND_IN,
                          require_paths=name not in NO_PATH, expected_id=frames[name]["id"])
    # Every file in the folder, including the ones no capture writes (`http-415-refusal.body.json`),
    # against both captures' stand-ins: this one's and agent mode's.
    fx.assert_clean_folder((STAND_IN, AGENT_STAND_IN))
