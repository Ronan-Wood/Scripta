"""A DEBUG Scripta runs a DEPLOYED engine, never the tree the operator is editing.

The retired `com.ronanwood.substrate-refresh` exec'd the working tree every 900 seconds, and on
2026-08-03 an uncommitted v8->v9 schema bump reached all six live scopes inside one tick. `b334da4`
guarded that specific shape and named what it left open: "no separation between code being edited
and code running against real data". `tools/substrate-deploy` publishes an export of one commit to
`~/.substrate/engine` (`discover()` tier 2), and `tools/deployment.py` proves it file-by-file.

WHAT IS ACTUALLY EXECUTED HERE. The deploy tool and the verifier, as subprocesses, against a
throwaway `$HOME` so the deployment record, the manifest and the vaults lock all land in a sandbox,
and a stub `uv` that logs its argv and exits 0.
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
_DEPLOY = _TOOLS / "substrate-deploy"


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
    """A binary that records how it was called and succeeds, so the log IS the assertion surface."""
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text("#!/bin/sh\nprintf '%s %s\\n' {} \"$*\" >> {}\nexit 0\n".format(
        shlex.quote(label), shlex.quote(str(log))), encoding="utf-8")
    path.chmod(0o755)


def _sandbox() -> Path:
    """A throwaway HOME with a stub `uv` and a data root, ready for a deployment."""
    home = Path(tempfile.mkdtemp()) / "home"
    (home / ".substrate").mkdir(parents=True)
    (home / "data").mkdir()
    (home / "stub").mkdir()
    log = home / "calls.log"
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


def _run(argv: list[str], home: Path, extra_path: str | None = None,
         env: dict[str, str] | None = None) -> subprocess.CompletedProcess:
    full = {**os.environ, "HOME": str(home), **(env or {})}
    if extra_path:
        full["PATH"] = extra_path + os.pathsep + full.get("PATH", "")
    return subprocess.run(argv, env=full, capture_output=True, text=True)


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


# ---------------------------------------------------------------- deploy, end to end

def _git(repo: Path, *args: str) -> str:
    # SIGNING OFF, for scratch repositories only. `commit.gpgsign` is set machine-wide once an
    # operator signs their commits, and these fixtures commit as `t@t` in a throwaway tree: the
    # signer would prompt for authorisation that no test run can answer, and git exits 128. A
    # fixture's commit attests nothing, so there is nothing to lose by not signing it.
    return subprocess.run(["git", "-C", str(repo), "-c", "commit.gpgsign=false", *args],
                          capture_output=True, text=True, check=True).stdout.strip()


def _throwaway_repo() -> tuple[Path, Path]:
    """A one-commit repo holding the deploy tool and its verifier, and a sandbox `$HOME` with a stub
    `uv`. `substrate-deploy` derives its repo from its own location, so the copy under test has to
    live inside the throwaway one, with the verifier beside it, exactly as they ship."""
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
    for tool in ("substrate-deploy", "deployment.py"):
        dst = repo / "tools" / tool
        dst.write_bytes((_TOOLS / tool).read_bytes())
        dst.chmod(0o755)
    _git(repo, "init", "-q")
    _git(repo, "add", "-A")
    _git(repo, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "v8")
    return repo, home


def test_a_deploy_waits_for_the_vaults_lock_and_swaps_nothing_without_it() -> None:
    """The lock every compose, embed and refresh pass takes (`substrate.refresh`). A deploy that
    swapped the engine while a pass composed from it would run half of one engine and half of
    another. It used to take `refresh.lock`, whose only other taker was the retired agent, so it
    guarded against nothing."""
    import fcntl

    repo, home = _throwaway_repo()
    lock = home / ".substrate" / "vaults.lock"
    fd = os.open(lock, os.O_RDWR | os.O_CREAT, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX)
        env_wait = {"SUBSTRATE_DEPLOY_LOCK_WAIT": "1"}
        r = _run([str(repo / "tools" / "substrate-deploy")], home, extra_path=str(home / "stub"),
                 env=env_wait)
        assert r.returncode != 0, "a deploy ran while the vaults lock was held"
        assert "could not take" in r.stderr and "vaults.lock" in r.stderr, r.stderr
        assert not (home / ".substrate" / "engine").exists(), "a deploy swapped the engine anyway"
    finally:
        os.close(fd)
    r = _run([str(repo / "tools" / "substrate-deploy")], home, extra_path=str(home / "stub"))
    assert r.returncode == 0, r.stderr
    assert (home / ".substrate" / "engine" / "substrate" / "cli.py").exists()


def test_the_vaults_lock_is_held_while_the_engine_is_swapped() -> None:
    """Refusing while someone else holds the lock is half of it; the other half is that the deploy
    still holds it after the swap. The stub `uv` runs AFTER the swap (`uv sync` primes the new
    engine) and tries the lock itself, so a deploy that let go of it would log FREE."""
    repo, home = _throwaway_repo()
    probe = home / "stub" / "uv"
    probe.write_text(
        f"#!{sys.executable}\n"
        "import fcntl, os, sys\n"
        "fd = os.open(os.path.expanduser('~/.substrate/vaults.lock'), os.O_RDWR)\n"
        "try:\n"
        "    fcntl.flock(fd, fcntl.LOCK_EX | fcntl.LOCK_NB)\n"
        "    state = 'FREE'\n"
        "except BlockingIOError:\n"
        "    state = 'HELD'\n"
        f"open({str(home / 'calls.log')!r}, 'a').write('UV ' + state + '\\n')\n",
        encoding="utf-8")
    probe.chmod(0o755)
    r = _run([str(repo / "tools" / "substrate-deploy")], home, extra_path=str(home / "stub"))
    assert r.returncode == 0, r.stderr
    assert _calls(home) == ["UV HELD"], _calls(home)
    lock = home / ".substrate" / "vaults.lock"
    assert lock.stat().st_mode & 0o777 == 0o600, oct(lock.stat().st_mode)


def test_a_deploy_will_not_lock_through_a_symlink() -> None:
    """The same rule as `scopes.flocked`: a link at the lock's path could point anywhere this user
    can write, and locking it would neither serialize with the engine nor be safe to create."""
    repo, home = _throwaway_repo()
    elsewhere = home / "elsewhere"
    elsewhere.write_text("", encoding="utf-8")
    (home / ".substrate" / "vaults.lock").symlink_to(elsewhere)
    r = _run([str(repo / "tools" / "substrate-deploy")], home, extra_path=str(home / "stub"))
    assert r.returncode != 0, "a deploy locked through a symlink"
    assert "symbolic link" in r.stderr, r.stderr
    assert not (home / ".substrate" / "engine").exists()


def test_a_deploy_names_an_engine_still_running_the_old_code() -> None:
    """The lock covers the swap, not a `substrate serve` already running from the old tree: it keeps
    the old code in memory and its next pass composes with the new. Named so it gets restarted."""
    repo, home = _throwaway_repo()
    deploy = [str(repo / "tools" / "substrate-deploy")]
    first = _run(deploy, home, extra_path=str(home / "stub"))
    assert first.returncode == 0, first.stderr
    assert "RESTART" not in first.stdout, first.stdout
    engine = home / ".substrate" / "engine"
    fake = subprocess.Popen(
        ["bash", "-c", f'exec -a "{engine}/.venv/bin/python -m substrate.cli serve" sleep 30'])
    try:
        second = _run(deploy, home, extra_path=str(home / "stub"))
        assert second.returncode == 0, second.stderr
        assert "RESTART" in second.stdout and str(fake.pid) in second.stdout, second.stdout
    finally:
        fake.kill()
        fake.wait()


def test_deploying_ships_the_commit_and_not_the_working_tree() -> None:
    """THE INCIDENT, inverted, and the reason a deploy step exists at all.

    On 2026-08-03 an uncommitted edit reached six live scopes because the scheduler exec'd the
    working tree. Here the tree is dirtied with a change that would be catastrophic if it shipped,
    and the deployment must contain the COMMITTED bytes.

    Run against a throwaway repo rather than this one, because the assertion needs a working tree
    that differs from HEAD in a known way and this suite does not get to dirty the operator's.
    """
    repo, home = _throwaway_repo()

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
        "the environment must be built at deploy time, not by the first engine start")


def test_show_reports_a_broken_deployment_rather_than_a_commit() -> None:
    """`--show` is the operator's read-out and it has to answer the question they are asking, which
    after a refusal is "why". A version that printed the recorded commit and exited 0 would confirm
    a deployment that a DEBUG Scripta would refuse to run."""
    home = _sandbox()
    engine = _fake_engine(home)
    _write_record(home, engine)
    (engine / "pyproject.toml").write_text("[project]\n# edited\n", encoding="utf-8")
    r = _run([str(_DEPLOY), "--show"], home, extra_path=str(home / "stub"))
    assert r.returncode == 1, r.stdout
    assert "does NOT verify" in r.stdout, r.stdout
    assert "changed since deployment" in r.stderr, r.stderr



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
