"""The engine refreshes its own scopes, with no host app, under one lock compose and embed take.

Before this, the schedule lived in Scripta (`SubstrateRefresh.swift`): an index was refreshed only
while the app was open, and the only lock was an in-process flag, so a `compose` from a terminal was
serialized against nothing. Each test here fails on that engine: it had no `substrate refresh`, no
`substrate serve`, and a `compose` that took no lock.

Runnable with `python tests/test_refresh_pass.py` or under pytest.
"""

from __future__ import annotations

import contextlib
import json
import os
import shutil
import signal
import subprocess
import sys
import tempfile
import threading
import time
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from substrate import cli, local_socket, refresh, refresh_state, scopes, spine  # noqa: E402

DEMO = ROOT / "vaults" / "demo-vault"

# The note formats every server states beside what kind of server it is (`spine`).
_RANGES = {"notes_version": spine.NOTES_VERSION, "notes_min_version": spine.NOTES_MIN_VERSION}


@contextlib.contextmanager
def _quiet():
    import io

    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(io.StringIO()):
        yield


def _workspace() -> tuple[Path, Path]:
    """A copy of the demo vault pair, and a registry of its own beside it."""
    root = Path(tempfile.mkdtemp(dir="/tmp"))
    shutil.copytree(DEMO, root / "demo")
    shutil.copytree(DEMO.parent / "demo-core-vault", root / "demo-core-vault")
    return root, root / "scopes.toml"


def _compose(root: Path, registry: Path, *extra: str) -> int:
    with _quiet():
        return cli.main(["compose", str(root / "demo"), "--index-root", str(root / "demo-index"),
                         "--db", str(root / "demo.db"), "--registry", str(registry), *extra])


# ---------------------------------------------------------------- the lock

def test_a_second_holder_declines_when_it_may_not_wait() -> None:
    _, registry = _workspace()
    with refresh.vaults_lock(registry, wait=0):
        try:
            with refresh.vaults_lock(registry, wait=0):
                raise AssertionError("two holders at once")
        except refresh.Declined as e:
            assert str(refresh.lock_path(registry)) in str(e)
    with refresh.vaults_lock(registry, wait=0):
        pass


def test_a_waiting_holder_gets_the_lock_once_it_is_released() -> None:
    _, registry = _workspace()
    held = threading.Event()
    release = threading.Event()

    def _hold() -> None:
        with refresh.vaults_lock(registry, wait=0):
            held.set()
            release.wait(5)

    t = threading.Thread(target=_hold)
    t.start()
    assert held.wait(5)
    threading.Timer(0.3, release.set).start()
    started = time.monotonic()
    with refresh.vaults_lock(registry, wait=5):
        assert time.monotonic() - started >= 0.2
    t.join(5)


def test_compose_takes_the_lock_and_declines_writing_nothing() -> None:
    """The app's composes, the loop's and a terminal's are now serialized against each other."""
    root, registry = _workspace()
    with refresh.vaults_lock(registry, wait=0):
        assert _compose(root, registry, "--no-wait") == refresh.EX_DECLINED
    assert not (root / "demo.db").exists(), "a declined compose wrote an index"
    assert not registry.exists(), "a declined compose registered a scope"
    assert _compose(root, registry) == 0


def test_embed_takes_the_same_lock() -> None:
    _, registry = _workspace()
    with refresh.vaults_lock(registry, wait=0), _quiet():
        rc = cli.main(["embed", "--db", "/nonexistent/x.db", "--registry", str(registry),
                       "--no-wait"])
    assert rc == refresh.EX_DECLINED


# ---------------------------------------------------------------- one pass

class _Fake:
    """Answers compose and embed with chosen exit statuses, and remembers what it was asked."""

    def __init__(self, compose: int, embed: int = 0) -> None:
        self.codes = {"compose": compose, "embed": embed}
        self.calls: list[list[str]] = []

    def __call__(self, argv, env):
        self.calls.append(argv)
        self.env = env
        verb = argv[argv.index("-m") + 2]
        return subprocess.CompletedProcess(argv, self.codes[verb], "", f"{verb} said why\n")


def _registered(root: Path, registry: Path) -> None:
    assert _compose(root, registry) == 0


def _recorded(registry: Path, scope: str = "demo") -> str | None:
    return refresh_state.report(scope, registry).get("outcome")


def test_the_outcomes_are_the_apps() -> None:
    cases = [(0, 0, "refreshed"), (0, 1, "embed_failed"), (3, 0, "compose_failed")]
    for compose, embed, expected in cases:
        root, registry = _workspace()
        _registered(root, registry)
        fake = _Fake(compose, embed)
        [result] = refresh.run_pass(registry, runner=fake, log=lambda _l: None)
        assert (result.outcome, result.recorded) == (expected, True), (compose, embed, result)
        assert _recorded(registry) == expected
        # Compose declines rather than waiting; the embed after it waits a long while.
        assert "--no-wait" in fake.calls[0]
        if compose == 0:
            embed_argv = fake.calls[1]
            assert embed_argv[embed_argv.index("-m") + 2] == "embed"
            # The same registry as the compose, so both take the same lock.
            assert embed_argv[embed_argv.index("--registry") + 1] == \
                fake.calls[0][fake.calls[0].index("--registry") + 1]
            assert embed_argv[embed_argv.index("--wait") + 1] == str(refresh.EMBED_WAIT)
        else:
            assert len(fake.calls) == 1, "an embed ran after a failed compose"


def test_a_declined_compose_records_nothing() -> None:
    """It did not run, so it has nothing to say, and must not overwrite a live verdict."""
    root, registry = _workspace()
    _registered(root, registry)
    refresh_state.record("demo", "refreshed", registry=registry)
    [result] = refresh.run_pass(registry, runner=_Fake(refresh.EX_DECLINED),
                                log=lambda _l: None)
    assert result.outcome is None and not result.recorded
    assert _recorded(registry) == "refreshed"


def test_a_scope_whose_row_names_no_index_root_is_frozen_not_guessed() -> None:
    root, registry = _workspace()
    _registered(root, registry)
    text = registry.read_text("utf-8")
    registry.write_text("\n".join(ln for ln in text.splitlines()
                                  if not ln.startswith("index_root")) + "\n", encoding="utf-8")
    fake = _Fake(0)
    [result] = refresh.run_pass(registry, runner=fake, log=lambda _l: None)
    assert result.outcome == "compose_failed" and not fake.calls, "an index was composed somewhere"


def test_a_real_pass_composes_from_the_registrys_own_paths() -> None:
    """The subprocesses, for real: the compose reads the row's vault, db and index root."""
    root, registry = _workspace()
    _registered(root, registry)
    before = (root / "demo.db").stat().st_mtime_ns
    with _quiet():
        rc = cli.main(["refresh", "--registry", str(registry)])
    assert rc == 0
    # Embed needs a local model server, which CI does not have; either way the compose ran.
    assert _recorded(registry) in ("refreshed", "embed_failed"), _recorded(registry)
    assert (root / "demo.db").stat().st_mtime_ns > before, "the pass did not rewrite the index"


def test_refresh_refuses_a_scope_that_is_not_registered_before_running_anything() -> None:
    root, registry = _workspace()
    _registered(root, registry)
    with _quiet():
        assert cli.main(["refresh", "--registry", str(registry), "--scope", "nope"]) == 2
    fake = _Fake(0)
    try:
        refresh.run_pass(registry, ["demo", "nope"], runner=fake, log=lambda _l: None)
    except scopes.ScopeError as e:
        assert "nope" in str(e)
    else:
        raise AssertionError("an unregistered scope was accepted")
    assert not fake.calls, "the valid scope was composed before the refusal"


def test_a_relative_registry_reaches_the_children_absolute() -> None:
    """The children run in the engine's root. A relative path would name another registry there,
    one every compose guard would then pass against."""
    root, registry = _workspace()
    _registered(root, registry)
    fake = _Fake(0)
    here = os.getcwd()
    os.chdir(root)
    try:
        refresh.run_pass("scopes.toml", runner=fake, log=lambda _l: None)
    finally:
        os.chdir(here)
    compose = fake.calls[0]
    given = Path(compose[compose.index("--registry") + 1])
    assert given.is_absolute() and given.resolve() == registry.resolve(), given
    assert Path(fake.env[scopes.ENV_VAR]).is_absolute()


def test_the_lock_refuses_a_file_that_is_not_a_regular_one() -> None:
    """A FIFO, or a file another account planted where the lock goes, would make every holder
    fail or wait forever."""
    _, registry = _workspace()
    os.mkfifo(refresh.lock_path(registry))
    try:
        with refresh.vaults_lock(registry, wait=0):
            raise AssertionError("locked on a FIFO")
    except PermissionError as e:
        assert "not a regular file" in str(e)


def test_compose_with_a_registry_that_names_nothing_is_refused_cleanly() -> None:
    root, _ = _workspace()
    with _quiet():
        assert cli.main(["compose", str(root / "demo"), "--index-root", str(root / "i"),
                         "--db", str(root / "d.db"), "--registry", "~nosuchuser_zz/s.toml"]) == 2


def test_a_pass_that_is_stopped_records_nothing_for_the_scope_it_was_on() -> None:
    """A clean shutdown ends the running compose. Reading its signal exit as a failure would write
    a freeze for a healthy scope every time the server stops."""
    root, registry = _workspace()
    _registered(root, registry)
    refresh_state.record("demo", "refreshed", registry=registry)
    stopping = threading.Event()

    class _Killed(_Fake):
        def __call__(self, argv, env):
            stopping.set()
            self.calls.append(argv)
            return subprocess.CompletedProcess(argv, -signal.SIGTERM, "", "")

    results = refresh.run_pass(registry, runner=_Killed(0), log=lambda _l: None,
                               stopping=stopping)
    assert [(r.outcome, r.recorded) for r in results] == [(None, False)]
    assert _recorded(registry) == "refreshed", "the shutdown recorded a verdict"


def test_a_stopped_pass_starts_no_further_scope() -> None:
    root, registry = _workspace()
    _registered(root, registry)
    stopping = threading.Event()
    stopping.set()
    fake = _Fake(0)
    assert refresh.run_pass(registry, runner=fake, log=lambda _l: None, stopping=stopping) == []
    assert not fake.calls


def test_a_child_that_crashes_while_the_server_runs_on_is_a_failure() -> None:
    """A segfault or an OOM kill is not a shutdown. Read as one, a scope that crashes every pass
    would keep its last healthy verdict forever, and stop every scope after it."""
    for code in (-signal.SIGSEGV, -signal.SIGKILL):
        root, registry = _workspace()
        _registered(root, registry)

        class _Crash(_Fake):
            def __call__(self, argv, env, code=code):
                self.calls.append(argv)
                return subprocess.CompletedProcess(argv, code, "", "crashed")

        import substrate.refresh as r

        grace, r._STOP_GRACE = r._STOP_GRACE, 0.05
        try:
            [result] = refresh.run_pass(registry, runner=_Crash(0), log=lambda _l: None,
                                        stopping=threading.Event())
        finally:
            r._STOP_GRACE = grace
        assert (result.outcome, result.recorded) == ("compose_failed", True), (code, result)


def test_a_declined_compose_does_not_wait_out_the_shutdown_grace() -> None:
    root, registry = _workspace()
    _registered(root, registry)
    started = time.monotonic()
    refresh.run_pass(registry, runner=_Fake(refresh.EX_DECLINED), log=lambda _l: None,
                     stopping=threading.Event())
    assert time.monotonic() - started < 1.0


def test_a_server_that_stopped_lets_children_start_again_in_the_same_process() -> None:
    """The failed-bind path ends the server too; a later pass in the same process must still run."""
    refresh.begin_closing()
    refresh.end_closing()
    proc = refresh._run([sys.executable, "-c", "print('ran')"], dict(os.environ))
    assert proc.returncode == 0 and proc.stdout.strip() == "ran", proc


def test_no_child_starts_once_the_children_are_being_ended() -> None:
    try:
        refresh.terminate_children(grace=0)
        proc = refresh._run([sys.executable, "-c", "print('ran')"], dict(os.environ))
        assert proc.returncode < 0 and proc.stdout == "", proc
    finally:
        refresh._closing.clear()


def test_isolated_mode_reaches_the_children_as_its_parts() -> None:
    from unittest import mock

    with mock.patch.object(subprocess, "_args_from_interpreter_flags",
                           return_value=["-I", "-B", "-P"]):
        assert refresh._interpreter_flags() == ["-E", "-s", "-B"]


def test_serve_on_a_socket_already_served_refuses_without_a_traceback() -> None:
    """The state before Scripta moves onto `serve`: its engine holds the default socket."""
    from substrate import stack
    from substrate.mcp import server

    root, registry = _workspace()
    _registered(root, registry)
    sock = root / "run" / "substrate.sock"
    cfg = server.Config(str(registry), stack.Stack(), read_only=True)
    ready = threading.Event()
    box: dict = {}
    th = threading.Thread(target=server.serve_unix, args=(cfg, sock),
                          kwargs={"ready": lambda h: (box.update(h=h), ready.set())}, daemon=True)
    th.start()
    assert ready.wait(10)
    try:
        with _quiet():
            rc = cli.main(["serve", "--socket", str(sock), "--registry", str(registry),
                           "--lexical-only"])
        assert rc != 0
    finally:
        box["h"].shutdown()
        th.join(10)
    # And the failed start left this process able to run a pass.
    fake_ok = refresh._run([sys.executable, "-c", "print('ran')"], dict(os.environ))
    assert fake_ok.returncode == 0, fake_ok


def test_serve_refuses_to_refresh_as_a_client() -> None:
    with _quiet():
        assert cli.main(["serve", "--connect"]) == 2


def test_compose_refuses_a_wait_that_is_not_seconds() -> None:
    root, registry = _workspace()
    for wait in ("nan", "inf", "-1"):
        try:
            with _quiet():
                cli.main(["compose", str(root / "demo"), "--registry", str(registry),
                          "--wait", wait])
        except SystemExit as e:
            assert e.code == 2, wait
        else:
            raise AssertionError(f"--wait {wait} was accepted")


def test_the_loop_runs_a_pass_at_once_and_stops_when_told() -> None:
    root, registry = _workspace()
    _registered(root, registry)
    fake = _Fake(0, 0)
    loop = refresh.Loop(registry, every=3600, runner=fake, log=lambda _l: None)
    loop.start()
    deadline = time.monotonic() + 10
    while _recorded(registry) != "refreshed" and time.monotonic() < deadline:
        time.sleep(0.05)
    assert _recorded(registry) == "refreshed"
    loop.stop.set()
    loop.join(5)
    assert not loop.is_alive()


# ---------------------------------------------------------------- serve

def test_serve_runs_on_its_own_and_refreshes() -> None:
    """The headless engine: no host app, one process, serving the socket and refreshing."""
    root, registry = _workspace()
    _registered(root, registry)
    sock = root / "run" / "substrate.sock"
    proc = subprocess.Popen(
        [sys.executable, "-m", "substrate.cli", "serve", "--socket", str(sock),
         "--registry", str(registry), "--every", "3600", "--lexical-only"],
        cwd=ROOT, stdout=subprocess.DEVNULL, stderr=subprocess.PIPE, text=True,
        start_new_session=True)
    try:
        frame = json.dumps({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                            "params": {"name": "list_scopes", "arguments": {}}}).encode()
        payload = None
        deadline = time.monotonic() + 60
        while time.monotonic() < deadline:
            try:
                _, body = local_socket.post(sock, frame, timeout=5)
                payload = json.loads(json.loads(body)["result"]["content"][0]["text"])
                break
            except OSError:
                time.sleep(0.2)
        assert payload is not None, "serve never answered"
        assert payload["server"] == {"read_only": True, "agent_mode": False,
                                     "refresh_every": 3600.0, "refresh_requests": True,
                                     **_RANGES}, payload["server"]
        while _recorded(registry) is None and time.monotonic() < deadline:
            time.sleep(0.2)
        assert _recorded(registry) in ("refreshed", "embed_failed"), _recorded(registry)
        # A SIGTERM to the server alone, as a supervisor sends it, ends it cleanly: the socket is
        # given back and nothing of its process group is left running.
        os.kill(proc.pid, signal.SIGTERM)
        assert proc.wait(30) == 0, proc.stderr.read()
        assert not sock.exists(), "a stopped serve left its socket behind"
        try:
            os.killpg(proc.pid, 0)
        except ProcessLookupError:
            pass
        else:
            raise AssertionError("a child of serve outlived it")
    finally:
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
            proc.wait(15)


def test_version_reports_the_schema_and_wire_this_build_speaks() -> None:
    """What a host compares before using an engine it did not start: its own CLI will write that
    engine's indexes, so their schemas must agree."""
    import io

    from substrate import wire
    from substrate.store import schema

    from substrate import scopes
    from substrate.mcp import server

    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        assert cli.main(["version"]) == 0
    assert json.loads(out.getvalue()) == {
        "schema": schema.SCHEMA_VERSION, "wire": wire.VERSION,
        "registry": str(scopes.registry_path().resolve())}
    # The other half of the comparison: an engine reports its schema as `initialize`'s
    # `serverInfo.version`, to the bare `"params":{}` Scripta sends, which reads it back as
    # `0.<schema>.0`.
    reply = server._dispatch({"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
                             None)
    assert reply["result"]["serverInfo"]["version"] == f"0.{schema.SCHEMA_VERSION}.0", reply


def test_version_says_when_it_cannot_resolve_a_registry() -> None:
    """An empty $SUBSTRATE_REGISTRY names no file. Reported as null, so the host refuses to
    compare rather than comparing against a guess."""
    import io

    saved = os.environ.get("SUBSTRATE_REGISTRY")
    os.environ["SUBSTRATE_REGISTRY"] = " "
    try:
        out = io.StringIO()
        with contextlib.redirect_stdout(out):
            assert cli.main(["version"]) == 0
    finally:
        if saved is None:
            os.environ.pop("SUBSTRATE_REGISTRY", None)
        else:
            os.environ["SUBSTRATE_REGISTRY"] = saved
    assert json.loads(out.getvalue())["registry"] is None


def test_a_plain_server_says_it_refreshes_nothing() -> None:
    from substrate import stack
    from substrate.mcp import server

    _, registry = _workspace()
    registry.write_text("", encoding="utf-8")
    cfg = server.Config(str(registry), stack.Stack(), read_only=True)
    reply = server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                           "params": {"name": "list_scopes", "arguments": {}}}, cfg)
    payload = json.loads(reply["result"]["content"][0]["text"])
    assert payload["server"] == {"read_only": True, "agent_mode": False, "refresh_every": None,
                                 "refresh_requests": False, **_RANGES}


def test_a_refreshing_server_is_refused_off_the_socket_before_any_model_is_probed() -> None:
    from unittest import mock

    from substrate import stack
    from substrate.mcp import server

    with mock.patch.object(stack, "build", side_effect=AssertionError("built a stack")), _quiet():
        assert server.main(["--http"], refresh_every=60) == 2
        assert server.main(["--agent-mode", "--scopes", "a", "--snapshot-dir", "/tmp"],
                           refresh_every=60) == 2


def test_serve_refuses_an_interval_that_is_not_a_positive_finite_number() -> None:
    with _quiet():
        for every in ("0", "-5", "inf", "nan"):
            assert cli.main(["serve", "--every", every]) == 2, every


if __name__ == "__main__":
    for _name, _fn in sorted(globals().items()):
        if _name.startswith("test_") and callable(_fn):
            _fn()
            print(f"ok  {_name}")
