"""`substrate register`: a scope recorded PENDING its first compose, for the engine to compose.

A client attached to an engine it did not start writes notes and leaves the indexing to that
engine (plan §9.4). A new scope reaches the engine through the registry, without a compose here,
and is pending until the engine's next refresh pass composes it. Pending is told apart from a
scope whose index was deleted, everywhere a client sees it.
"""

from __future__ import annotations

import json
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from substrate import introspect, refresh, scopes, stack  # noqa: E402
from substrate.mcp import server  # noqa: E402

DEMO = ROOT / "vaults"


@pytest.fixture
def demo(tmp_path: Path) -> dict:
    """The demo vaults copied out, and where a registration would put their index."""
    shutil.copytree(DEMO / "demo-vault", tmp_path / "vaults" / "demo-vault")
    shutil.copytree(DEMO / "demo-core-vault", tmp_path / "vaults" / "demo-core-vault")
    return {"vault": tmp_path / "vaults" / "demo-vault", "registry": tmp_path / "scopes.toml",
            "db": tmp_path / "index" / "demo.db", "index_root": tmp_path / "index" / "demo"}


def _cli(*args: str, registry: Path) -> subprocess.CompletedProcess:
    return subprocess.run([sys.executable, "-m", "substrate.cli", *args, "--registry", str(registry)],
                          cwd=ROOT, capture_output=True, text=True, timeout=300)


def _register(demo: dict) -> subprocess.CompletedProcess:
    return _cli("register", str(demo["vault"]), "--index-root", str(demo["index_root"]),
                "--db", str(demo["db"]), registry=demo["registry"])


def test_register_records_the_scope_pending_and_composes_nothing(demo) -> None:
    run = _register(demo)
    assert run.returncode == 0, run.stderr
    assert f"scope: 'demo' registered in {demo['registry']}" in run.stdout
    assert "pending its first pass" in run.stdout
    entry = scopes.load(demo["registry"])["demo"]
    assert entry.composed == "" and not demo["db"].exists()
    [row] = introspect.scopes_payload(str(demo["registry"]))["scopes"]
    assert row["pending"] is True and row["composed"] is None and row["index_present"] is False


def test_a_pending_scope_is_refused_by_search_as_pending(demo) -> None:
    assert _register(demo).returncode == 0
    with pytest.raises(scopes.ScopeError, match="pending its first pass"):
        scopes.resolve("demo", demo["registry"])
    cfg = server.Config(str(demo["registry"]), stack.Stack(), read_only=True)
    reply = server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                           "params": {"name": "search",
                                      "arguments": {"scope": "demo", "query": "engine"}}}, cfg)
    text = reply["result"]["content"][0]["text"]
    assert reply["result"].get("isError") is True and "pending its first pass" in text, text


def test_a_second_register_is_a_no_op(demo) -> None:
    assert _register(demo).returncode == 0
    before = demo["registry"].read_bytes()
    again = _register(demo)
    assert again.returncode == 0 and "nothing changed" in again.stdout, again.stdout
    assert demo["registry"].read_bytes() == before


def test_the_engines_next_pass_composes_a_pending_scope(demo) -> None:
    assert _register(demo).returncode == 0
    results = refresh.run_pass(demo["registry"], log=lambda _: None)
    assert [r.scope for r in results] == ["demo"]
    assert results[0].outcome in ("refreshed", "embed_failed"), results
    entry = scopes.load(demo["registry"])["demo"]
    assert entry.composed and demo["db"].is_file()
    assert scopes.resolve("demo", demo["registry"]).db == entry.db
    [row] = introspect.scopes_payload(str(demo["registry"]))["scopes"]
    assert row["pending"] is False and row["composed"] == entry.composed


def test_a_register_with_other_paths_moves_nothing(demo, tmp_path) -> None:
    """A client derives the paths it passes, and may derive them differently next time: the scope
    keeps the index the engine already built, and stays composed."""
    assert _register(demo).returncode == 0
    refresh.run_pass(demo["registry"], log=lambda _: None)
    before = demo["registry"].read_bytes()
    again = _cli("register", str(demo["vault"]), "--index-root", str(tmp_path / "elsewhere"),
                 "--db", str(tmp_path / "elsewhere.db"), registry=demo["registry"])
    assert again.returncode == 0 and "nothing changed" in again.stdout, again.stdout
    assert demo["registry"].read_bytes() == before
    [row] = introspect.scopes_payload(str(demo["registry"]))["scopes"]
    assert row["pending"] is False and row["index_present"] is True


def test_register_does_not_wait_behind_a_pass(demo) -> None:
    """It writes only the registry, so a pass holding the vaults lock does not hold it up."""
    with refresh.vaults_lock(demo["registry"], wait=0):
        run = _register(demo)
    assert run.returncode == 0, run.stderr
    assert scopes.load(demo["registry"])["demo"].composed == ""


def test_a_pending_scope_is_refused_whatever_is_at_its_db(demo) -> None:
    """A file at the db path is not this scope's index until a compose of it has run."""
    assert _register(demo).returncode == 0
    demo["db"].parent.mkdir(parents=True, exist_ok=True)
    demo["db"].write_bytes(b"")
    with pytest.raises(scopes.ScopeError, match="pending its first pass"):
        scopes.resolve("demo", demo["registry"])


def test_a_pending_scope_whose_pass_failed_says_so_not_pending(demo) -> None:
    """Waiting for a pass that has run and refused would wait for nothing."""
    from substrate import refresh_state

    assert _register(demo).returncode == 0
    refresh_state.record("demo", "compose_failed", registry=demo["registry"])
    with pytest.raises(scopes.ScopeError, match="could not compose it") as refused:
        scopes.resolve("demo", demo["registry"])
    assert "pending its first pass" not in str(refused.value)


def test_register_refuses_another_scopes_index(demo, tmp_path) -> None:
    assert _register(demo).returncode == 0
    other = tmp_path / "other" / "other-vault"
    shutil.copytree(demo["vault"], other)
    shutil.copytree(demo["vault"].parent / "demo-core-vault", other.parent / "demo-core-vault")
    manifest = other / ".substrate.toml"
    manifest.write_text(manifest.read_text().replace('name = "demo"', 'name = "other"'))
    before = demo["registry"].read_bytes()
    run = _cli("register", str(other), "--index-root", str(tmp_path / "index" / "other"),
               "--db", str(demo["db"]), registry=demo["registry"])
    assert run.returncode == 1 and "is the index of scope 'demo'" in run.stderr, run.stderr
    assert demo["registry"].read_bytes() == before


def test_register_refuses_an_index_root_inside_a_vault(demo) -> None:
    run = _cli("register", str(demo["vault"]), "--index-root", str(demo["vault"] / "idx"),
               "--db", str(demo["db"]), registry=demo["registry"])
    assert run.returncode == 2 and "FATAL (--index-root)" in run.stderr, run.stderr
    assert not demo["registry"].exists() or "demo" not in scopes.load(demo["registry"])


def test_register_never_marks_a_composed_scope_pending(demo) -> None:
    assert _register(demo).returncode == 0
    refresh.run_pass(demo["registry"], log=lambda _: None)
    composed = scopes.load(demo["registry"])["demo"].composed
    assert composed
    assert "nothing changed" in _register(demo).stdout
    assert scopes.load(demo["registry"])["demo"].composed == composed


def test_a_composed_scope_whose_index_went_missing_still_says_recompose(demo) -> None:
    """Not pending: it was composed, and its index has since gone."""
    assert _register(demo).returncode == 0
    refresh.run_pass(demo["registry"], log=lambda _: None)
    demo["db"].unlink()
    with pytest.raises(scopes.ScopeError, match="Recompose it") as refused:
        scopes.resolve("demo", demo["registry"])
    assert "pending" not in str(refused.value)
    [row] = introspect.scopes_payload(str(demo["registry"]))["scopes"]
    assert row["pending"] is False and row["index_present"] is False


def test_register_refuses_a_name_another_vault_holds(demo, tmp_path) -> None:
    assert _register(demo).returncode == 0
    other = tmp_path / "other" / "demo-vault"
    shutil.copytree(demo["vault"], other)
    shutil.copytree(demo["vault"].parent / "demo-core-vault", other.parent / "demo-core-vault")
    run = _cli("register", str(other), "--index-root", str(demo["index_root"]), "--db",
               str(demo["db"]), registry=demo["registry"])
    assert run.returncode == 1 and "already registered to" in run.stderr, run.stderr
    assert json.dumps(str(scopes.load(demo["registry"])["demo"].vault)) == json.dumps(
        str(scopes.real_path(demo["vault"])))
