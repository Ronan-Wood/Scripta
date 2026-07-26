"""The scope registry refuses rather than resolves to the wrong index.

Doc 3a §3: scope is a parameter and scope resolution failure HARD-FAILS — it must never fall
back to something narrower or adjacent. Every refusal here exists because the alternative is a
well-formed answer from a source set the caller did not choose, which is this project's signature
failure shape wearing yet another hat.

The round-trip tests matter more than they look: the registry is written by a hand-rolled TOML
emitter (stdlib has no writer) and read back by tomllib. An emitter that mangles a path with a
backslash or a quote produces a file that parses to something else, or not at all — and the
symptom would be "that scope does not exist", indistinguishable from never having composed it.

Runnable with plain `python tests/test_scopes.py`; discovered by pytest if added.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import scopes  # noqa: E402


def _tmp() -> Path:
    return Path(tempfile.mkdtemp())


def _registry() -> Path:
    return _tmp() / "scopes.toml"


def _compose(root: Path, name: str) -> tuple[Path, Path, Path]:
    """A vault dir + a db file that exists (resolve refuses one that does not) + an index root."""
    vault = root / f"{name}-vault"
    vault.mkdir(parents=True, exist_ok=True)
    db = root / f"{name}.db"
    db.write_bytes(b"")
    index_root = root / f"{name}-index"
    index_root.mkdir(parents=True, exist_ok=True)
    return vault, db, index_root


# ---------------------------------------------------------------- round trip

def test_record_then_resolve() -> None:
    root, reg = _tmp(), _registry()
    vault, db, ir = _compose(root, "prism")
    scopes.record("prism", vault=vault, db=db, index_root=ir, registry=reg)

    entry = scopes.resolve("prism", reg)
    assert entry.name == "prism"
    assert entry.vault == vault.resolve()
    assert entry.db == db.resolve()
    assert entry.composed, "a recorded scope carries when it was composed"


def test_paths_are_stored_absolute() -> None:
    """An MCP server is launched by a client with an arbitrary working directory. A relative db
    would resolve against the wrong root — missing the index, or finding a different one."""
    root, reg = _tmp(), _registry()
    vault, db, ir = _compose(root, "prism")
    scopes.record("prism", vault=Path(vault), db=Path(db), index_root=ir, registry=reg)
    text = reg.read_text("utf-8")
    for line in text.splitlines():
        if line.startswith(("vault =", "db =", "index_root =")):
            assert ' = "/' in line, f"not absolute: {line}"


def test_awkward_paths_survive_the_round_trip() -> None:
    """A hand-rolled TOML writer that ignores backslashes and quotes emits a file that parses to
    a different path, or fails to parse at all — reported as "no such scope"."""
    root, reg = _tmp(), _registry()
    odd = root / 'a "quoted" dir' / "back\\slash"
    odd.mkdir(parents=True)
    db = odd / "x.db"
    db.write_bytes(b"")
    scopes.record("odd", vault=odd, db=db, index_root=odd, registry=reg)
    assert scopes.resolve("odd", reg).db == db.resolve()


def test_dotted_name_is_not_silently_nested() -> None:
    """A bare TOML key containing a dot NESTS the table. `[scopes.a.b]` is scope 'a' with a child
    'b', not a scope named 'a.b' — the entry would vanish from `load` entirely."""
    root, reg = _tmp(), _registry()
    vault, db, ir = _compose(root, "dotted")
    scopes.record("a.b", vault=vault, db=db, index_root=ir, registry=reg)
    assert set(scopes.load(reg)) == {"a.b"}


def test_multiple_scopes_coexist() -> None:
    root, reg = _tmp(), _registry()
    for n in ("prism", "scripta", "cbre"):
        v, d, i = _compose(root, n)
        scopes.record(n, vault=v, db=d, index_root=i, registry=reg)
    assert set(scopes.load(reg)) == {"prism", "scripta", "cbre"}


def test_recompose_same_vault_updates_in_place() -> None:
    root, reg = _tmp(), _registry()
    vault, db, ir = _compose(root, "prism")
    scopes.record("prism", vault=vault, db=db, index_root=ir, registry=reg)
    db2 = root / "prism-v2.db"
    db2.write_bytes(b"")
    scopes.record("prism", vault=vault, db=db2, index_root=ir, registry=reg)
    assert len(scopes.load(reg)) == 1
    assert scopes.resolve("prism", reg).db == db2.resolve()


# ---------------------------------------------------------------- refusals

def test_concurrent_records_do_not_lose_an_entry() -> None:
    """`record` reads the whole registry, adds one entry and writes it all back. Without a lock
    two composes both read the OLD file and the second's snapshot silently drops the first's
    scope — invisible afterwards, the scope simply is not there. Composing several vaults in a
    shell loop is the obvious way to hit it."""
    import threading

    root, reg = _tmp(), _registry()
    names = [f"s{i}" for i in range(12)]
    prepared = {n: _compose(root, n) for n in names}
    barrier = threading.Barrier(len(names))

    def go(n: str) -> None:
        v, d, i = prepared[n]
        barrier.wait()                      # maximize the overlap on the read-modify-write
        scopes.record(n, vault=v, db=d, index_root=i, registry=reg)

    threads = [threading.Thread(target=go, args=(n,)) for n in names]
    for t in threads:
        t.start()
    for t in threads:
        t.join()

    assert set(scopes.load(reg)) == set(names), sorted(set(names) - set(scopes.load(reg)))


def test_unknown_scope_names_what_exists() -> None:
    root, reg = _tmp(), _registry()
    v, d, i = _compose(root, "prism")
    scopes.record("prism", vault=v, db=d, index_root=i, registry=reg)
    try:
        scopes.resolve("prsim", reg)
    except scopes.ScopeError as e:
        assert "prism" in str(e), e
    else:
        raise AssertionError("a typo'd scope must refuse, not resolve to something adjacent")


def test_missing_index_refuses_rather_than_creating_an_empty_one() -> None:
    """IndexStore would happily create a database at a missing path and answer every query with
    nothing — a genuine no-match and a deleted index are indistinguishable downstream."""
    root, reg = _tmp(), _registry()
    v, d, i = _compose(root, "prism")
    scopes.record("prism", vault=v, db=d, index_root=i, registry=reg)
    d.unlink()
    try:
        scopes.resolve("prism", reg)
    except scopes.ScopeError as e:
        assert "does not exist" in str(e), e
    else:
        raise AssertionError("a registered-but-missing index must refuse")


def test_name_collision_across_vaults_refuses() -> None:
    """Two vaults declaring one manifest name would make the first unreachable and answer its
    queries from the second."""
    root, reg = _tmp(), _registry()
    v1, d1, i1 = _compose(root, "one")
    v2, d2, i2 = _compose(root, "two")
    scopes.record("prism", vault=v1, db=d1, index_root=i1, registry=reg)
    try:
        scopes.record("prism", vault=v2, db=d2, index_root=i2, registry=reg)
    except scopes.ScopeError as e:
        assert str(v1) in str(e) and str(v2) in str(e), e
    else:
        raise AssertionError("repointing a name at a different vault must refuse")
    assert scopes.resolve("prism", reg).vault == v1.resolve(), "the original must survive"


def test_absent_registry_is_empty_not_an_error() -> None:
    """No scope composed yet is a state, not a fault."""
    assert scopes.load(_tmp() / "nothing-here.toml") == {}


def test_malformed_registry_raises_rather_than_reading_empty() -> None:
    """Reporting "no scopes exist" over a file that names several would read as "never composed"."""
    reg = _registry()
    reg.write_text("this is not [ valid toml\n", encoding="utf-8")
    try:
        scopes.load(reg)
    except scopes.ScopeError:
        pass
    else:
        raise AssertionError("a malformed registry must raise, not silently read as empty")


def test_entry_missing_required_keys_raises() -> None:
    reg = _registry()
    reg.write_text('version = 1\n\n[scopes.prism]\ncomposed = "2026-01-01T00:00:00+00:00"\n',
                   encoding="utf-8")
    try:
        scopes.load(reg)
    except scopes.ScopeError as e:
        assert "vault" in str(e) and "db" in str(e), e
    else:
        raise AssertionError("an entry with no vault/db must raise")


# ---------------------------------------------------------------- path selection

def test_env_var_overrides_the_default() -> None:
    import os

    reg = _registry()
    prior = os.environ.get(scopes.ENV_VAR)
    os.environ[scopes.ENV_VAR] = str(reg)
    try:
        assert scopes.registry_path() == reg
        # An explicit argument still wins — a flag beats an inherited environment.
        other = _registry()
        assert scopes.registry_path(other) == other
    finally:
        if prior is None:
            del os.environ[scopes.ENV_VAR]
        else:
            os.environ[scopes.ENV_VAR] = prior


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
