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

import os
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


def test_a_name_carrying_the_ref_separator_refuses() -> None:
    """A scope name is the first segment of every expand_ref it issues, so one containing the
    separator produces handles that parse back to a DIFFERENT scope."""
    root, reg = _tmp(), _registry()
    v, d, i = _compose(root, "x")
    for bad in ("cbre/2026", " prism", "prism ", ""):
        try:
            scopes.record(bad, vault=v, db=d, index_root=i, registry=reg)
        except scopes.ScopeError:
            continue
        raise AssertionError(f"{bad!r} must not be registrable")


def test_an_entry_without_index_root_stays_none() -> None:
    """Defaulting it to Path("") stringifies as "." — the ingest hint then told the user to write
    the disposable index tree into whatever directory they were standing in."""
    reg = _registry()
    reg.write_text('version = 1\n\n[scopes.old]\nvault = "/v"\ndb = "/d.db"\n', encoding="utf-8")
    assert scopes.load(reg)["old"].index_root is None


def test_a_toml_datetime_composed_does_not_break_serialization() -> None:
    """A bare datetime is valid TOML and what a hand-edit naturally produces; a non-str here broke
    json.dumps for every list_scopes and status call."""
    import json

    reg = _registry()
    reg.write_text('version = 1\n\n[scopes.old]\nvault = "/v"\ndb = "/d.db"\n'
                   "composed = 2026-07-26T09:00:00Z\n", encoding="utf-8")
    entry = scopes.load(reg)["old"]
    assert isinstance(entry.composed, str)
    json.dumps({"composed": entry.composed})


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


def test_a_registry_that_cannot_be_opened_raises_rather_than_reading_empty() -> None:
    """Only an absent file is empty. `is_file()` answered False for a registry it could not stat,
    so an unreadable one read as "no scopes" and the compose guard had nothing to check."""
    as_directory = _registry()
    as_directory.mkdir()
    unreadable = _tmp() / "locked"
    unreadable.mkdir()
    (unreadable / "scopes.toml").write_text("version = 1\n", encoding="utf-8")
    unreadable.chmod(0)
    try:
        for reg in (as_directory, unreadable / "scopes.toml"):
            if reg.parent == unreadable and os.access(unreadable, os.X_OK):
                continue  # root reads it anyway; nothing to prove
            try:
                scopes.load(reg)
            except scopes.ScopeError:
                continue
            raise AssertionError(f"{reg} could not be read and must raise, not read as empty")
    finally:
        unreadable.chmod(0o755)


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


# ---------------------------------------------------------------- another scope's index

_DEMO_VAULT = Path(__file__).resolve().parent.parent / "vaults" / "demo-vault"


def _compose_cli(*argv: str) -> tuple[int, str]:
    import contextlib
    import io

    from substrate import cli

    err = io.StringIO()
    with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
        rc = cli.main(["compose", *argv])
    return rc, err.getvalue()


def test_foreign_owner_matches_either_index_path() -> None:
    root, reg = _tmp(), _registry()
    v1, d1, i1 = _compose(root, "one")
    v2, d2, i2 = _compose(root, "two")
    scopes.record("prism", vault=v1, db=d1, index_root=i1, registry=reg)

    assert scopes.foreign_owner(vault=v2, db=d1, index_root=i2, registry=reg).name == "prism"
    assert scopes.foreign_owner(vault=v2, db=d2, index_root=i1, registry=reg).name == "prism"
    assert scopes.foreign_owner(vault=v2, db=d2, index_root=i2, registry=reg) is None


def test_foreign_owner_lets_a_vault_recompose_its_own_index() -> None:
    """Every refresh recomposes a scope into the index it already has."""
    root, reg = _tmp(), _registry()
    v1, d1, i1 = _compose(root, "one")
    scopes.record("prism", vault=v1, db=d1, index_root=i1, registry=reg)
    assert scopes.foreign_owner(vault=v1, db=d1, index_root=i1, registry=reg) is None


def test_foreign_owner_sees_through_a_symlink() -> None:
    """The registry stores resolved paths; `~/OneDrive` is a symlink into CloudStorage."""
    root, reg = _tmp(), _registry()
    v1, d1, i1 = _compose(root, "one")
    v2, _, i2 = _compose(root, "two")
    scopes.record("prism", vault=v1, db=d1, index_root=i1, registry=reg)
    link = root / "linked"
    link.symlink_to(root)
    owner = scopes.foreign_owner(vault=v2, db=link / d1.name, index_root=i2, registry=reg)
    assert owner is not None and owner.name == "prism"


def test_foreign_owner_compares_files_not_spellings() -> None:
    """`resolve()` leaves case alone and the default APFS volume ignores it, so `ONE.DB` is
    `one.db` there. A hardlink is the same file on any filesystem."""
    root, reg = _tmp(), _registry()
    v1, d1, i1 = _compose(root, "one")
    v2, _, i2 = _compose(root, "two")
    scopes.record("prism", vault=v1, db=d1, index_root=i1, registry=reg)

    hard = root / "hard.db"
    os.link(d1, hard)
    assert scopes.foreign_owner(vault=v2, db=hard, index_root=i2, registry=reg).name == "prism"

    upper_db = d1.with_name(d1.name.upper())
    if not upper_db.exists():
        return  # a case-sensitive volume, as on the Linux CI runner
    assert scopes.foreign_owner(vault=v2, db=upper_db, index_root=i2, registry=reg).name == "prism"
    upper_vault = v1.with_name(v1.name.upper())
    assert scopes.foreign_owner(vault=upper_vault, db=d1, index_root=i1, registry=reg) is None, (
        "a scope's own vault, spelled in another case, must still recompose")


def _doc_ids(db: Path) -> list[str]:
    import sqlite3

    con = sqlite3.connect(db)
    try:
        return sorted(row[0] for row in con.execute("SELECT doc_id FROM documents"))
    finally:
        con.close()


def _another_vault_named_demo(root: Path) -> Path:
    """What "Create separately" produced: a second vault declaring the demo vault's name, holding a
    note of its own, so composing it into demo's index changes what that index holds."""
    import shutil

    workspace = root / "workspace"
    shutil.copytree(_DEMO_VAULT, workspace / "demo")
    shutil.copytree(_DEMO_VAULT.parent / "demo-core-vault", workspace / "demo-core-vault")
    for note in (workspace / "demo").rglob("*.md"):
        note.unlink()
    (workspace / "demo" / "call.md").write_text(
        "---\nstatus: active\ndoc_type: reference\n---\n\n# A recorded call\n\n"
        + "The workspace's own content, said on a call. " * 30,
        encoding="utf-8")
    return workspace / "demo"


def test_compose_refuses_a_second_vault_into_a_registered_index() -> None:
    """The app picks a compose's --db by scope NAME, so a vault declaring a registered name was
    built into that scope's index, and only then did registration refuse. The compose exited 0
    with 6 of demo's 9 documents replaced (reproduced 2026-09-16 on the unguarded code)."""
    root, reg = _tmp(), _registry()
    db, ir = root / "demo.db", root / "demo-index"
    rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(db), "--index-root", str(ir),
                           "--registry", str(reg))
    assert rc == 0, (rc, err)
    docs, tree = _doc_ids(db), sorted(p.name for p in ir.iterdir())

    rc, err = _compose_cli(str(_another_vault_named_demo(root)), "--db", str(db),
                           "--index-root", str(ir), "--clean", "--registry", str(reg))
    assert rc == 2, (rc, err)
    assert "'demo'" in err and "rename its manifest `name`" in err, err
    assert _doc_ids(db) == docs, "the other vault's notes replaced demo's"
    assert sorted(p.name for p in ir.iterdir()) == tree, "--clean removed demo's ingest tree"


def test_compose_refuses_to_clean_another_scopes_ingest_tree() -> None:
    """Matched on the path, not the name: `--clean` would remove the tree under any name."""
    root, reg = _tmp(), _registry()
    other, db, ir = _compose(root, "other")
    (ir / "kept").mkdir()
    (ir / "kept" / "document.md").write_text("generated", encoding="utf-8")
    scopes.record("elsewhere", vault=other, db=db, index_root=ir, registry=reg)

    rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "own.db"),
                           "--index-root", str(ir), "--clean", "--registry", str(reg))
    assert rc == 2, (rc, err)
    assert (ir / "kept" / "document.md").is_file(), "--clean removed another scope's ingest tree"
    assert not (root / "own.db").exists()


def test_compose_refuses_when_the_registry_cannot_be_read() -> None:
    root, reg = _tmp(), _registry()
    reg.write_text("this is not [ valid toml\n", encoding="utf-8")
    rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "own.db"),
                           "--index-root", str(root / "own-index"), "--registry", str(reg))
    assert rc == 2, (rc, err)
    assert "nothing was written" in err, err
    assert not (root / "own.db").exists() and not (root / "own-index").exists()


def test_compose_recomposes_its_own_registered_index() -> None:
    """The control: the guard must not refuse the refresh path, a vault into its own index."""
    root, reg = _tmp(), _registry()
    argv = (str(_DEMO_VAULT), "--db", str(root / "demo.db"),
            "--index-root", str(root / "demo-index"), "--registry", str(reg))
    for extra in ([], ["--clean"]):
        rc, err = _compose_cli(*argv, *extra)
        assert rc == 0, (extra, rc, err)
    assert scopes.resolve("demo", reg).db == (root / "demo.db").resolve()


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
