"""The refresh agent runs a DEPLOYED engine, never the tree the operator is editing.

`com.ronanwood.substrate-refresh` exec'd the working tree every 900 seconds, and on 2026-08-03 an
uncommitted v8->v9 schema bump reached all six live scopes inside one tick. `b334da4` guarded that
specific shape and named what it left open: "no separation between code being edited and code
running against real data". `tools/substrate-deploy` publishes an export of one commit to
`~/.substrate/engine`; `tools/deployment.py` proves it file-by-file; `tools/substrate-refresh`
refuses the whole tick and records `engine_unverified` when the proof fails.

WHAT IS ACTUALLY EXECUTED HERE. All of it — the deploy tool, the verifier and the agent are run as
subprocesses. Two things make that safe to do in a test suite:

  * a throwaway `$HOME`, so the deployment record, the manifest, the lock, the log and
    `refresh.json` all land in the sandbox. Pointing any of them at the real ones would have a test
    run degrade the live freshness signal for six scopes.
  * a stub `uv` and a stub `~/.local/bin/substrate` that log their argv and exit 0. Every engine
    invocation therefore becomes an OBSERVATION rather than a compose — which is also what lets
    these tests assert the thing that matters most: WHICH binary the agent reached for, and which
    paths it passed it.

The agent is never allowed to reach a real vault: `data_root` is a sandbox directory, and the
assertions below check that no call names a path outside it.
"""

from __future__ import annotations

import hashlib
import importlib.util
import json
import os
import shlex
import subprocess
import sys
import tempfile
from pathlib import Path

_REPO = Path(__file__).resolve().parent.parent
_TOOLS = _REPO / "tools"
_AGENT = _TOOLS / "substrate-refresh"
_DEPLOY = _TOOLS / "substrate-deploy"
_SHIM = _TOOLS / "substrate-refresh.shim"
_SCOPES = ("prism", "scripta", "cbre", "research", "school", "clovis")


def _load_deployment():
    """`tools/` is not a package, and it is not going to become one for this. Loaded by path so
    the module under test is the file that ships next to the shell scripts that call it."""
    spec = importlib.util.spec_from_file_location("_substrate_deployment", _TOOLS / "deployment.py")
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


deployment = _load_deployment()


# ---------------------------------------------------------------- sandbox scaffolding

def _stub(path: Path, log: Path, label: str) -> None:
    """A binary that records how it was called and succeeds. The agent's whole job is choosing
    which one of these to invoke and with what, so the log IS the assertion surface."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\nprintf '%s %s\\n' {} \"$*\" >> {}\nexit 0\n".format(
        shlex.quote(label), shlex.quote(str(log))), encoding="utf-8")
    path.chmod(0o755)


def _sandbox() -> Path:
    """A throwaway HOME with the two stub binaries and a data root, ready for a deployment."""
    home = Path(tempfile.mkdtemp()) / "home"
    (home / ".substrate").mkdir(parents=True)
    (home / "data").mkdir()
    (home / "stub").mkdir()
    log = home / "calls.log"
    _stub(home / ".local" / "bin" / "substrate", log, "WRAPPER")
    _stub(home / "stub" / "uv", log, "UV")
    return home


def _calls(home: Path) -> list[str]:
    log = home / "calls.log"
    return log.read_text("utf-8").splitlines() if log.is_file() else []


def _fake_engine(home: Path, name: str = "engine") -> Path:
    """The minimum a deployment must contain to be one — `deployment.REQUIRED_PATHS`."""
    engine = home / ".substrate" / name
    (engine / "substrate").mkdir(parents=True)
    (engine / "substrate" / "cli.py").write_text("print('engine')\n", encoding="utf-8")
    (engine / "pyproject.toml").write_text("[project]\n", encoding="utf-8")
    (engine / "uv.lock").write_text("lock\n", encoding="utf-8")
    return engine


def _write_record(home: Path, engine: Path, **overrides) -> Path:
    """Manifest + record for `engine`, written the way `substrate-deploy` writes them."""
    manifest = home / ".substrate" / "engine.manifest"
    manifest.write_text("\n".join(deployment.manifest_lines(engine)) + "\n", encoding="utf-8")
    record = {
        "version": 1,
        "commit": "0" * 40,
        "deployed_at": "2026-08-03T00:00:00+00:00",
        "engine_root": str(engine),
        "source_repo": str(_REPO),
        "data_root": str(home / "data"),
        "uv": str(home / "stub" / "uv"),
        "manifest": str(manifest),
        "signature": hashlib.sha256(manifest.read_bytes()).hexdigest(),
    }
    record.update(overrides)
    path = home / ".substrate" / "engine.json"
    path.write_text(json.dumps(record, indent=2) + "\n", encoding="utf-8")
    return path


def _verify(record: Path) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, str(_TOOLS / "deployment.py"), "--verify", str(record)],
                          capture_output=True, text=True)


def _run(argv: list[str], home: Path, extra_path: str | None = None) -> subprocess.CompletedProcess:
    env = {**os.environ, "HOME": str(home)}
    if extra_path:
        env["PATH"] = extra_path + os.pathsep + env.get("PATH", "")
    return subprocess.run(argv, env=env, capture_output=True, text=True)


def _log(home: Path) -> str:
    p = home / "Library" / "Logs" / "substrate-refresh.log"
    return p.read_text("utf-8") if p.is_file() else ""


def _recorded(home: Path) -> list[str]:
    """The outcomes the agent actually wrote, as seen from the other side of the boundary."""
    out = []
    for line in _calls(home):
        if "refresh-record" in line and "--outcome" in line:
            parts = line.split()
            out.append(parts[parts.index("--outcome") + 1])
    return out


# ---------------------------------------------------------------- the separation invariant

def test_a_deployment_inside_the_source_repo_is_refused() -> None:
    """The one check that can fail while every hash matches.

    A record whose `engine_root` is the tree being edited describes a verifiable, self-consistent,
    completely pointless deployment — it is the 2026-08-03 configuration with a verification step
    in front of it, which is worse than no verification step because it reports clean.

    The fixture is a COMPLETE, correctly-signed engine that happens to sit inside its own source
    repo, so the separation check is the only thing that can refuse it. Aiming the record at a
    directory that merely exists inside the repo would have this test pass on a hash mismatch and
    stay green with the invariant deleted.
    """
    home = _sandbox()
    source = home / "pretend-repo"
    engine = source / "engine"
    (engine / "substrate").mkdir(parents=True)
    (engine / "substrate" / "cli.py").write_text("print('engine')\n", encoding="utf-8")
    (engine / "pyproject.toml").write_text("[project]\n", encoding="utf-8")
    (engine / "uv.lock").write_text("lock\n", encoding="utf-8")
    record = _write_record(home, engine, source_repo=str(source))
    r = _verify(record)
    assert r.returncode == 1, r.stdout
    assert "inside the source repo" in r.stderr, r.stderr


def test_a_git_checkout_is_not_a_deployment() -> None:
    """One indirection further down. A worktree or clone would verify perfectly and then be moved
    to another commit by anything that runs `git checkout` with it as cwd — which makes the pin a
    suggestion. A deployment is an EXPORT, and `git archive` output has no `.git`."""
    home = _sandbox()
    engine = _fake_engine(home)
    (engine / ".git").mkdir()
    r = _verify(_write_record(home, engine))
    assert r.returncode == 1
    assert "git checkout" in r.stderr, r.stderr


def test_a_deployment_that_was_edited_after_the_fact_is_refused() -> None:
    """Verification re-hashes every listed file, so it holds against a clobbered, half-written or
    hand-patched deployment — not only against one that was never made."""
    home = _sandbox()
    engine = _fake_engine(home)
    record = _write_record(home, engine)
    assert _verify(record).returncode == 0, "the fixture must verify before it is broken"

    (engine / "substrate" / "cli.py").write_text("print('not what was deployed')\n",
                                                 encoding="utf-8")
    r = _verify(record)
    assert r.returncode == 1
    assert "substrate/cli.py: changed since deployment" in r.stderr, r.stderr


def test_a_deleted_file_is_refused_rather_than_ignored() -> None:
    """A missing file must not read as a file that matches. `git archive` writes every one of them;
    an absent module is a half-deleted deployment, and Python would happily import around it."""
    home = _sandbox()
    engine = _fake_engine(home)
    record = _write_record(home, engine)
    (engine / "uv.lock").unlink()
    r = _verify(record)
    assert r.returncode == 1
    assert "uv.lock: missing" in r.stderr, r.stderr


def test_swapping_the_manifest_alone_is_refused() -> None:
    """The record carries a signature over the manifest, so the two cannot be replaced separately.
    Without it, editing a file and re-listing it in the manifest would verify."""
    home = _sandbox()
    engine = _fake_engine(home)
    record = _write_record(home, engine)
    (engine / "substrate" / "cli.py").write_text("print('swapped')\n", encoding="utf-8")
    manifest = home / ".substrate" / "engine.manifest"
    manifest.write_text("\n".join(deployment.manifest_lines(engine)) + "\n", encoding="utf-8")
    r = _verify(record)
    assert r.returncode == 1
    assert "does not match the signature" in r.stderr, r.stderr


def test_a_manifest_that_covers_no_engine_is_refused() -> None:
    """A record aimed at some unrelated directory is refused with THAT reason, not with a hash
    mismatch that reads like corruption."""
    home = _sandbox()
    engine = home / ".substrate" / "not-an-engine"
    engine.mkdir(parents=True)
    (engine / "README").write_text("hello\n", encoding="utf-8")
    r = _verify(_write_record(home, engine))
    assert r.returncode == 1
    assert "does not describe a" in r.stderr, r.stderr


def test_nothing_deployed_says_so_rather_than_reporting_an_errno() -> None:
    """The bootstrap case. "Nothing is deployed" and "the deployment is broken" want different
    first moves from the reader, and a FileNotFoundError on a path they have never heard of reads
    as the second."""
    home = _sandbox()
    r = _verify(home / ".substrate" / "engine.json")
    assert r.returncode == 1
    assert "nothing is deployed" in r.stderr, r.stderr


def test_a_symlink_in_a_deployment_is_refused_at_sign_time() -> None:
    """A followed symlink hashes its target, so a deployed tree could verify while the bytes that
    actually get imported live somewhere nobody recorded — this mechanism's own hazard, one
    indirection down. This repo has none; the refusal makes adding one a deploy-time error."""
    home = _sandbox()
    engine = _fake_engine(home)
    (engine / "substrate" / "sneaky.py").symlink_to(_REPO / "substrate" / "cli.py")
    try:
        deployment.manifest_lines(engine)
    except deployment.Refused as e:
        assert "symlink" in str(e)
    else:
        raise AssertionError("a symlink in a deployment was signed as if it were a file")


# ---------------------------------------------------------------- the agent's refusal

def test_the_agent_refuses_and_records_when_nothing_is_deployed() -> None:
    """LOUD AND RECORDED, which is the whole contract for a failure in this job.

    A refusal nobody can see is worse than the hazard it prevents: all six scopes would hold the
    `frozen: false` from whenever the deployment last worked, ageing quietly, with the agent
    apparently running fine. So this asserts three things at once — non-zero exit, a log line
    naming the remedy, and `engine_unverified` written for EVERY scope.
    """
    home = _sandbox()
    r = _run([str(_AGENT)], home)
    assert r.returncode == 1, f"a tick that cannot verify its engine must exit non-zero: {r}"

    log = _log(home)
    assert "DEPLOYMENT UNVERIFIED" in log, log
    assert "nothing is deployed" in log, log
    assert "substrate-deploy" in log, "the log must name the action that fixes this"

    assert _recorded(home) == ["engine_unverified"], _calls(home)
    call = [c for c in _calls(home) if "refresh-record" in c][0]
    for scope in _SCOPES:
        assert f"--scope {scope}" in call, f"{scope} was left holding its last healthy verdict"


def test_the_agent_refuses_and_records_when_the_deployed_engine_was_edited() -> None:
    """The same refusal from the other direction: a deployment that exists and no longer matches.
    This is the state a half-finished `cp -r`, a clobbered directory or a hand-patch leaves."""
    home = _sandbox()
    engine = _fake_engine(home)
    _write_record(home, engine)
    (engine / "substrate" / "cli.py").write_text("print('edited')\n", encoding="utf-8")

    r = _run([str(_AGENT)], home)
    assert r.returncode == 1
    assert "changed since deployment" in _log(home), _log(home)
    assert _recorded(home) == ["engine_unverified"]


def test_a_refused_tick_composes_nothing_and_leaves_no_lock() -> None:
    """The refusal has to be total and it has to be repeatable. A tick that refused but left the
    lock behind would make the NEXT tick take it over an hour later, and one that refused after
    composing would be the incident with extra logging."""
    home = _sandbox()
    r = _run([str(_AGENT)], home)
    assert r.returncode == 1
    assert not [c for c in _calls(home) if " compose " in c or " embed " in c], _calls(home)
    assert not (home / ".substrate" / "refresh.lock").exists(), "the lock outlived the refusal"
    # `list(...)`, because `Path.glob` returns a generator and a bare generator is always truthy —
    # an assertion that can only pass is the same defect as a docstring nobody implemented.
    assert not list((home / "data").glob("*.db")), "a refused tick wrote an index"


def test_the_agent_reaches_the_deployed_engine_and_nothing_else() -> None:
    """The headline property, observed at the only place it is visible: which binary got called.

    Every engine invocation must go through the pinned `uv` in the deployed tree, and every path it
    is handed must come from the deployment record. `~/.local/bin/substrate` — the wrapper that
    execs the working tree — is the thing this design stopped trusting, and it is reached for
    exactly one job: recording that the deployment could not be verified. It verifies here, so it
    must not be reached at all.

    This runs the real agent to completion, and what it does depends on whether the embedding
    daemon happens to be up on the machine running the suite: with it down the agent records
    `skipped`, with it up the agent composes through the stubs. BOTH are asserted the same way,
    because the claim under test is not what it did but what it did it WITH.
    """
    home = _sandbox()
    engine = _fake_engine(home)
    _write_record(home, engine)

    r = _run([str(_AGENT)], home)
    assert r.returncode == 0, f"a verified deployment must not refuse: {r.stderr}\n{_log(home)}"

    calls = _calls(home)
    assert calls, "the agent verified a deployment and then invoked no engine at all"
    for call in calls:
        assert call.startswith("UV "), (
            f"the agent went around the pinned engine: {call!r}. `~/.local/bin/substrate` execs "
            "the working tree, which is the separation this whole mechanism exists to create.")
        assert str(_REPO / "out-vault") not in call, (
            f"a call named the operator's real index root from a sandboxed test: {call!r}")
    for call in calls:
        for flag in ("--db", "--index-root"):
            if flag in call:
                target = call.split(flag, 1)[1].split()[0]
                assert target.startswith(str(home / "data")), (
                    f"{flag} {target} is outside the recorded data_root")


# ---------------------------------------------------------------- deploy, end to end

def _git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), *args], capture_output=True, text=True,
                          check=True).stdout.strip()


def test_deploying_ships_the_commit_and_not_the_working_tree() -> None:
    """THE INCIDENT, inverted, and the reason a deploy step exists at all.

    On 2026-08-03 an uncommitted edit reached six live scopes because the scheduler exec'd the
    working tree. Here the tree is dirtied with a change that would be catastrophic if it shipped,
    and the deployment must contain the COMMITTED bytes.

    Run against a throwaway repo rather than this one, because the assertion needs a working tree
    that differs from HEAD in a known way and this suite does not get to dirty the operator's.
    """
    root = Path(tempfile.mkdtemp())
    repo, home = root / "repo", root / "home"
    (repo / "substrate").mkdir(parents=True)
    (repo / "tools").mkdir()
    (repo / "out-vault").mkdir()
    (home / ".substrate").mkdir(parents=True)
    (home / "stub").mkdir()
    _stub(home / "stub" / "uv", home / "calls.log", "UV")
    (repo / "substrate" / "cli.py").write_text("SCHEMA_VERSION = 8\n", encoding="utf-8")
    (repo / "pyproject.toml").write_text("[project]\n", encoding="utf-8")
    (repo / "uv.lock").write_text("lock\n", encoding="utf-8")
    # `substrate-deploy` derives its repo from its own location, so the copy under test has to live
    # inside the throwaway one — with the verifier it calls beside it, exactly as they ship.
    for tool in ("substrate-deploy", "deployment.py"):
        dst = repo / "tools" / tool
        dst.write_bytes((_TOOLS / tool).read_bytes())
        dst.chmod(0o755)

    _git(repo, "init", "-q")
    _git(repo, "add", "-A")
    _git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "v8")

    # The 2026-08-03 shape: an uncommitted schema bump sitting in the tree.
    (repo / "substrate" / "cli.py").write_text("SCHEMA_VERSION = 9\n", encoding="utf-8")

    r = _run([str(repo / "tools" / "substrate-deploy")], home, extra_path=str(home / "stub"))
    assert r.returncode == 0, r.stderr

    deployed = (home / ".substrate" / "engine" / "substrate" / "cli.py").read_text("utf-8")
    assert deployed == "SCHEMA_VERSION = 8\n", (
        "the deployment shipped the working tree; the whole point is that it ships a commit")
    assert "NOT deployed" in r.stdout, "a dirty tree must be REPORTED, so the pin is never a surprise"


def test_a_real_deployment_of_this_repo_verifies_immediately() -> None:
    """End to end over the actual engine: export HEAD, sign 128 files, verify them back.

    The unit fixtures above are four files; this is the real tree, which is where the framing
    assumptions (paths with spaces, nested directories, an empty file) actually get exercised.
    A stub `uv` stands in for the environment build — `uv sync` needs the network and this test
    does not, and what is under test is the export and its proof, not uv.
    """
    home = _sandbox()
    r = _run([str(_DEPLOY), "--data-root", str(home / "data")], home,
             extra_path=str(home / "stub"))
    assert r.returncode == 0, r.stderr

    record = json.loads((home / ".substrate" / "engine.json").read_text("utf-8"))
    assert record["commit"] == _git(_REPO, "rev-parse", "HEAD")
    assert record["data_root"] == str(home / "data")
    assert record["source_repo"] == str(_REPO)
    engine = Path(record["engine_root"])
    assert not str(engine).startswith(str(_REPO)), "the deployment landed inside the source repo"
    assert (engine / "substrate" / "cli.py").is_file()

    assert _verify(home / ".substrate" / "engine.json").returncode == 0, "a fresh deploy must verify"
    assert "UV sync --frozen --quiet" in _calls(home), (
        "the environment must be built at deploy time, not inside the 900-second job")


def test_show_reports_a_broken_deployment_rather_than_a_commit() -> None:
    """`--show` is the operator's read-out and it has to answer the question they are asking, which
    after a refusal is "why". A version that printed the recorded commit and exited 0 would confirm
    a deployment that the agent is refusing every fifteen minutes."""
    home = _sandbox()
    engine = _fake_engine(home)
    _write_record(home, engine)
    (engine / "pyproject.toml").write_text("[project]\n# edited\n", encoding="utf-8")
    r = _run([str(_DEPLOY), "--show"], home, extra_path=str(home / "stub"))
    assert r.returncode == 1, r.stdout
    assert "does NOT verify" in r.stdout, r.stdout
    assert "changed since deployment" in r.stderr, r.stderr


# ---------------------------------------------------------------- the shim

def test_deploy_names_the_shim_install_when_launchd_still_starts_the_repo_agent() -> None:
    """The second half of the change has to be discoverable, and it has to be discoverable HERE.

    Installing `tools/substrate-refresh.shim` is what pins the agent shell as well as the engine,
    and it is an operator action on a file no session may touch. The agent deliberately does not
    log it — an install where launchd still starts the repo agent produces that condition on every
    tick, and a standing condition in an event log is the noise this job's quiet-by-default policy
    exists to prevent. So it surfaces once, in the read-out a human asked for.
    """
    home = _sandbox()
    _write_record(home, _fake_engine(home))
    r = _run([str(_DEPLOY), "--show"], home, extra_path=str(home / "stub"))
    assert r.returncode == 0, r.stderr + r.stdout
    assert "substrate-refresh.shim" in r.stdout, r.stdout

    # ...and it stays quiet once the installed shim prefers the deployment.
    shim = home / ".local" / "bin" / "substrate-refresh"
    shim.write_text(_SHIM.read_text("utf-8"), encoding="utf-8")
    shim.chmod(0o755)
    r = _run([str(_DEPLOY), "--show"], home, extra_path=str(home / "stub"))
    assert "substrate-refresh.shim" not in r.stdout, r.stdout


def test_the_shim_prefers_the_deployed_agent() -> None:
    """The order in the shim is the design: the DEPLOYED agent first, so the scheduled path runs
    not just a pinned engine but the pinned shell that decides when to use it. An edit to
    `tools/substrate-refresh` in the working tree must not reach launchd's next tick."""
    home = _sandbox()
    deployed = home / ".substrate" / "engine" / "tools" / "substrate-refresh"
    _stub(deployed, home / "calls.log", "DEPLOYED-AGENT")
    r = _run([str(_SHIM)], home)
    assert r.returncode == 0, r.stderr
    assert any(c.startswith("DEPLOYED-AGENT") for c in _calls(home)), _calls(home)


def test_the_shim_falls_back_so_a_machine_with_no_deployment_still_records() -> None:
    """Without this arm the never-deployed machine fails at `exec`: launchd logs "no such file" to
    a file nobody tails, no scope is recorded, and all six keep serving their last healthy verdict
    while nothing runs — the exact false-healthy silence the refresh record exists to remove.

    The source agent reached this way cannot compose: its first act is to verify the deployment,
    which is what is missing.
    """
    home = _sandbox()
    r = _run([str(_SHIM)], home)
    assert r.returncode == 1, "the fallback must carry the refusal's exit status"
    assert _recorded(home) == ["engine_unverified"], _calls(home)
    assert not [c for c in _calls(home) if " compose " in c], "the fallback composed something"


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
