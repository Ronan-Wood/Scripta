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


def _vault_dir(path: Path, name: str = "v") -> Path:
    """A directory a registered scope can name. It carries a manifest: without one, the --clean
    guard cannot know what that scope inherits and refuses for THAT reason, which would mask
    whatever a test meant to exercise."""
    path.mkdir(parents=True, exist_ok=True)
    (path / ".substrate.toml").write_text(f'name = "{name}"\ninherits = []\n', encoding="utf-8")
    return path


def _compose(root: Path, name: str) -> tuple[Path, Path, Path]:
    """A vault dir + a db file that exists (resolve refuses one that does not) + an index root."""
    vault = _vault_dir(root / f"{name}-vault", name)
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


def test_indexes_within_names_what_removing_a_directory_would_take() -> None:
    root, reg = _tmp(), _registry()
    v1, d1, i1 = _compose(root, "one")
    scopes.record("prism", vault=v1, db=d1, index_root=i1, registry=reg)

    held = {path.name for _, path in scopes.indexes_within(root, reg)}
    assert held == {d1.name, i1.name}, held
    assert scopes.indexes_within(i1, reg) == [], "a scope's own tree AT the root is not inside it"
    assert scopes.indexes_within(v1, reg) == []

    link = root / "linked"
    link.symlink_to(root)
    assert scopes.indexes_within(link, reg), "a symlink to the directory holds the same indexes"
    upper = root.with_name(root.name.upper())
    if upper.exists():  # a volume that ignores case
        assert scopes.indexes_within(upper, reg), "OUT-VAULT holds out-vault's indexes"

    d1.unlink()
    assert {p.name for _, p in scopes.indexes_within(root, reg)} == held, (
        "a registered db that is gone still names a path removing the directory would take")


def test_indexes_within_sees_a_registered_tree_behind_a_symlink() -> None:
    """A tree moved elsewhere and linked back resolves outside the root, but `rmtree` removes the
    link, and the scope then no longer resolves."""
    root, reg = _tmp(), _registry()
    tree = root / "other-index"
    tree.mkdir()
    scopes.record("other", vault=_tmp(), db=_tmp() / "other.db", index_root=tree, registry=reg)
    moved = _tmp() / "moved-index"
    tree.rename(moved)
    tree.symlink_to(moved)
    assert scopes.indexes_within(root, reg), "the registered tree is reached through root"


def test_clean_refuses_an_index_root_holding_another_scopes_index() -> None:
    """#23: every scope's db and ingest tree sit side by side and neither looks authored, so an
    --index-root one directory too high was removed whole, with exit 0."""
    root, reg = _tmp(), _registry()
    shared = root / "out-vault"
    other_vault, db, tree = root / "other-vault", shared / "other.db", shared / "other-index"
    other_vault.mkdir()
    tree.mkdir(parents=True)
    (tree / "document.md").write_text("generated", encoding="utf-8")
    db.write_bytes(b"")
    scopes.record("other", vault=other_vault, db=db, index_root=tree, registry=reg)

    spellings = [shared]
    if shared.with_name(shared.name.upper()).exists():  # a volume that ignores case
        spellings.append(shared.with_name(shared.name.upper()))
    for spelling in spellings:
        rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "own.db"),
                               "--index-root", str(spelling), "--clean", "--registry", str(reg))
        assert rc == 2, (spelling, rc, err)
        assert "'other'" in err, err
        assert db.is_file() and (tree / "document.md").is_file(), (
            f"--clean {spelling} removed another scope's index")


def test_clean_refuses_an_index_root_holding_its_own_db() -> None:
    root, reg = _tmp(), _registry()
    idx = root / "idx"
    idx.mkdir()
    own = idx / "demo.db"
    own.write_bytes(b"the database this compose would write")
    rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(own), "--index-root", str(idx),
                           "--clean", "--registry", str(reg))
    assert rc == 2, (rc, err)
    assert "own --db" in err, err
    assert own.read_bytes() == b"the database this compose would write", "--clean removed --db"


def test_clean_refuses_an_index_root_holding_a_symlink_to_its_own_db() -> None:
    """The link resolves outside the root, but `rmtree` removes it: compose then built a fresh,
    unvectored db in its place and repointed the registry at it."""
    root, reg = _tmp(), _registry()
    idx = root / "idx"
    idx.mkdir()
    real = root / "outside.db"
    real.write_bytes(b"the vectored index")
    (idx / "demo.db").symlink_to(real)
    rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(idx / "demo.db"),
                           "--index-root", str(idx), "--clean", "--registry", str(reg))
    assert rc == 2, (rc, err)
    assert (idx / "demo.db").is_symlink(), "--clean removed the link to the db"
    assert real.read_bytes() == b"the vectored index"


def test_clean_refuses_an_index_root_inside_another_scopes_tree() -> None:
    """The refusal looked only downward, so a directory INSIDE another scope's ingest tree was
    removed — part of that tree — and this scope's ingest dirs were written in its place."""
    root, reg = _tmp(), _registry()
    other_vault, tree = _vault_dir(root / "other-vault", "other"), root / "other-index"
    note = tree / "other-vault__note__abcd1234"
    note.mkdir(parents=True)
    (note / "document.md").write_text("generated", encoding="utf-8")
    scopes.record("other", vault=other_vault, db=root / "other.db", index_root=tree, registry=reg)

    rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "own.db"),
                           "--index-root", str(note), "--clean", "--registry", str(reg))
    assert rc == 2, (rc, err)
    assert "ingest tree of scope 'other'" in err, err
    assert (note / "document.md").is_file(), "--clean removed part of another scope's ingest tree"


def test_a_registered_tree_holding_other_indexes_does_not_block_their_clean() -> None:
    """A scope registered with an ingest tree one level too high holds its siblings' indexes.
    Counting that as a tree would refuse every sibling's own --clean for good."""
    root, reg = _tmp(), _registry()
    db, tree = root / "out-vault" / "demo.db", root / "out-vault" / "demo-index"
    argv = (str(_DEMO_VAULT), "--db", str(db), "--index-root", str(tree), "--registry", str(reg))
    rc, err = _compose_cli(*argv)
    assert rc == 0, (rc, err)
    broad_vault = _vault_dir(root / "broad-vault", "broad")
    scopes.record("broad", vault=broad_vault, db=root / "broad.db",
                  index_root=root / "out-vault", registry=reg)

    rc, err = _compose_cli(*argv, "--clean")
    assert rc == 0, (rc, err)


def test_clean_refuses_a_symlinked_index_root() -> None:
    """`rmtree` will not remove a link, and every check had already passed on its target, so
    --clean ended in a traceback."""
    root, reg = _tmp(), _registry()
    real = root / "real-index"
    (real / "kept").mkdir(parents=True)
    # The looping link can only fail on Python 3.10-3.12, where resolve() raised on a loop.
    for name, target in (("linked-index", real), ("dangling-index", root / "gone"),
                         ("looping-index", root / "looping-index")):
        link = root / name
        link.symlink_to(target)
        rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "own.db"),
                               "--index-root", str(link), "--clean", "--registry", str(reg))
        assert rc == 2, (name, rc, err)
        assert "symlink" in err, err
        assert link.is_symlink()
    assert (real / "kept").is_dir()


def test_compose_expands_a_literal_tilde_in_db() -> None:
    """zsh passes `--db=~/x.db` through literally. The guards and the registry expanded it and
    SQLite did not, so one file was checked and registered and another was written."""
    home, work, reg = _tmp(), _tmp(), _registry()
    (work / "~").mkdir()  # without it the old code crashed; with it, it wrote the wrong file
    saved_home, saved_cwd = os.environ.get("HOME"), os.getcwd()
    os.environ["HOME"] = str(home)
    os.chdir(work)
    try:
        rc, err = _compose_cli(str(_DEMO_VAULT), "--db=~/demo.db",
                               "--index-root", str(work / "idx"), "--registry", str(reg))
    finally:
        os.chdir(saved_cwd)
        if saved_home is None:
            os.environ.pop("HOME", None)
        else:
            os.environ["HOME"] = saved_home
    assert rc == 0, (rc, err)
    assert (home / "demo.db").is_file(), "the database was not written where ~ points"
    assert not (work / "~" / "demo.db").exists(), "the database was written under ./~"
    assert scopes.resolve("demo", reg).db == (home / "demo.db").resolve()


def test_a_tree_stays_protected_whatever_else_is_registered_inside_it() -> None:
    """A registered path inside a tree — another scope's nested tree, or a stale db — once turned
    that tree's protection off, and a note directory of it was removed."""
    for inside in ("tree", "db"):
        root, reg = _tmp(), _registry()
        tree = root / "a-index"
        note = tree / "a-vault__note__abcd1234"
        note.mkdir(parents=True)
        (note / "document.md").write_text("generated", encoding="utf-8")
        for name in ("a-vault", "c-vault"):
            _vault_dir(root / name, name)
        scopes.record("a", vault=root / "a-vault", db=root / "a.db", index_root=tree, registry=reg)
        nested = {"tree": {"db": root / "c.db", "index_root": tree / "c"},
                  "db": {"db": tree / "stale.db", "index_root": root / "c-index"}}[inside]
        scopes.record("c", vault=root / "c-vault", registry=reg, **nested)

        rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "d.db"),
                               "--index-root", str(note), "--clean", "--registry", str(reg))
        assert rc == 2, (inside, rc, err)
        assert "ingest tree of scope 'a'" in err, (inside, err)
        assert (note / "document.md").is_file(), f"removed with a {inside} registered inside"


def test_a_note_directory_registered_as_a_tree_claims_nothing() -> None:
    """The narrower "tree" must not claim the wider one: a row naming a note directory of another
    scope's tree once turned that tree's protection off, and the note was removed in its name.

    The row is planted by hand because the two-step reproduction no longer runs — step one, the
    plain compose into that note directory, is refused now. The row itself is still reachable: the
    registry is a hand-editable file, and it holds rows written before that refusal existed.
    """
    root, reg = _tmp(), _registry()
    tree = root / "a-index"
    note = tree / "a-vault__note__abcd1234"
    note.mkdir(parents=True)
    (note / "document.md").write_text("generated", encoding="utf-8")
    _vault_dir(root / "a-vault", "a")
    scopes.record("a", vault=root / "a-vault", db=root / "a.db", index_root=tree, registry=reg)
    scopes.record("c", vault=_DEMO_VAULT, db=root / "d.db", index_root=note, registry=reg)

    rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "d.db"), "--index-root", str(note),
                           "--registry", str(reg), "--clean")
    assert rc == 2, (rc, err)
    assert "ingest tree of scope 'a'" in err, err
    assert (note / "document.md").is_file(), "--clean removed another scope's note"


def test_a_plain_compose_is_checked_where_a_clean_would_be() -> None:
    """The checks ran under --clean alone, so a plain compose wrote its ingest tree into whatever
    it was handed and REGISTERED it — which is how a registry comes to name a tree inside a vault,
    and how a scope ends up registered over its siblings' indexes with its own --clean refused
    from then on. Four shapes, none of them deleting anything, all of them refused."""
    import shutil

    root, reg = _tmp(), _registry()
    # A COPY of the demo vault, so a guard that fails writes its ingest tree into a temp directory
    # rather than into the repo's fixture.
    mine, mine_core = root / "mine" / "demo", root / "mine" / "demo-core-vault"
    shutil.copytree(_DEMO_VAULT, mine)
    shutil.copytree(_DEMO_VAULT.parent / "demo-core-vault", mine_core)
    (mine_core / "attachments").mkdir(exist_ok=True)

    shared = root / "out-vault"
    other_vault = _vault_dir(root / "other-vault", "other")
    db, tree = shared / "other.db", shared / "other-index"
    note = tree / "other-vault__note__abcd1234"
    note.mkdir(parents=True)
    (note / "document.md").write_text("gen", encoding="utf-8")
    db.write_bytes(b"")
    scopes.record("other", vault=other_vault, db=db, index_root=tree, registry=reg)
    # An inherited vault carries no manifest of its own, so only the registry names it.
    inherited = root / "other-core-vault"
    (inherited / "attachments").mkdir(parents=True)
    (inherited / "attachments" / "spec.pdf").write_bytes(b"not regenerable")
    (other_vault / ".substrate.toml").write_text(
        'name = "other"\ninherits = ["other-core-vault"]\n', encoding="utf-8")

    targets = [
        ("inside a vault this scope inherits", mine_core / "attachments"),
        ("inside a registered scope's inherited vault", inherited / "attachments"),
        ("over another scope's db and tree", shared),
        ("inside another scope's ingest tree", note),
    ]
    for i, (what, target) in enumerate(targets):
        before = reg.read_text(encoding="utf-8")
        rc, err = _compose_cli(str(mine), "--db", str(root / f"d{i}.db"),
                               "--index-root", str(target), "--registry", str(reg))
        assert rc == 2, (what, rc, err)
        assert "FATAL (--index-root)" in err, (what, err)
        assert "delete" not in err, f"{what} was refused as a deletion: {err}"
        assert reg.read_text(encoding="utf-8") == before, f"{what} was registered anyway"
        assert not list(target.glob("*__*__*")), f"{what} took an ingest tree"
        assert not (root / f"d{i}.db").exists(), f"{what} wrote a database"
    assert (inherited / "attachments" / "spec.pdf").is_file()
    assert (note / "document.md").is_file()


def test_a_scope_is_never_refused_in_its_own_name() -> None:
    """Running the registry checks on a plain compose made a scope refuse ITSELF: its own db or its
    own previously-registered tree, sitting under the root it was composing into, counted as "an
    index this root holds". Nothing was being deleted, and there was no way out — the refusal reads
    the registry row, and only a compose that can still run rewrites it.

    Both shapes, then the two things the exemption must NOT loosen: another scope's row inside the
    root still refuses, and --clean still counts the scope's own rows, because rmtree takes them.
    """
    root, reg = _tmp(), _registry()
    idx = root / "idx"
    argv = (str(_DEMO_VAULT), "--db", str(idx / "demo.db"), "--index-root", str(idx),
            "--registry", str(reg))
    for again in ("first", "again"):
        rc, err = _compose_cli(*argv)
        assert rc == 0, ("its own --db under its own index root", again, rc, err)

    # --db OUTSIDE the root throughout. With it inside, the "holds this compose's own --db"
    # refusal returns before `indexes_within` is ever reached, and the --clean assertion below
    # would pass on a check that has nothing to do with the exemption it claims to pin.
    #
    # A FRESH REGISTRY PER VERB, because `record` REPLACES this scope's row: after the plain
    # compose at the wider root there is no longer anything of demo's registered inside it, so
    # running both in sequence would prove nothing about what --clean counts.
    for verb in ("plain", "--clean"):
        root, reg = _tmp(), _registry()
        index, db = root / "index", root / "demo.db"
        rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(db),
                               "--index-root", str(index / "demo"), "--registry", str(reg))
        assert rc == 0, (verb, rc, err)
        wider = (str(_DEMO_VAULT), "--db", str(db), "--index-root", str(index),
                 "--registry", str(reg))
        if verb == "plain":
            rc, err = _compose_cli(*wider)
            assert rc == 0, ("its own registered tree under the root it moved to", rc, err)
        else:
            # The removal really would take the tree registered inside, and that row is its own.
            rc, err = _compose_cli(*wider, "--clean")
            assert rc == 2, ("--clean stopped counting the scope's own rows", rc, err)
            assert "holds the index of scope 'demo'" in err, ("refused elsewhere", err)

    # And another scope's row inside the root is refused as before, exemption or not.
    other = _vault_dir(root / "other-vault", "other")
    scopes.record("other", vault=other, db=index / "other.db", index_root=index / "other",
                  registry=reg)
    rc, err = _compose_cli(*wider)
    assert rc == 2, ("the exemption dropped another scope's rows too", rc, err)
    assert "'other'" in err, err


def test_a_plain_compose_still_builds_where_an_index_belongs() -> None:
    """The control for the refusals above: the paths the app and the refresh loop actually use —
    a directory that does not exist yet, then the scope's own registered tree — must still compose
    with and without --clean, beside another scope registered as a sibling."""
    root, reg = _tmp(), _registry()
    shared = root / "out-vault"
    # THE OPERATOR'S ACTUAL LAYOUT: every scope's db and `<name>-index` tree inside ONE directory.
    # This used to build `other` via `_compose(root, ...)`, which put it in the PARENT of `shared`
    # — nothing registered was anywhere near `shared/demo-index`, so the control passed trivially
    # and the one shape most likely to be broken by widening `indexes_within`/`trees_around` to
    # plain composes went untested.
    other_vault = _vault_dir(root / "other-vault", "other")
    other_db, other_tree = shared / "other.db", shared / "other-index"
    other_tree.mkdir(parents=True)
    other_db.write_bytes(b"")
    scopes.record("other", vault=other_vault, db=other_db, index_root=other_tree, registry=reg)
    argv = (str(_DEMO_VAULT), "--db", str(shared / "demo.db"),
            "--index-root", str(shared / "demo-index"), "--registry", str(reg))
    # First into a directory that does not exist, then over the tree it just registered, then the
    # same again with --clean: the three states the app and the refresh loop cycle through.
    for label, extra in (("first", []), ("recompose", []), ("recompose --clean", ["--clean"])):
        rc, err = _compose_cli(*argv, *extra)
        assert rc == 0, (label, rc, err)
    assert scopes.resolve("demo", reg).index_root == (shared / "demo-index").resolve()


def test_a_plain_compose_does_not_write_into_a_vault_a_broken_chain_orphaned() -> None:
    """The unknowable-chain branch is the ONLY check that sees an inherited vault whose owner no
    longer resolves — such a vault carries no manifest, so the manifest check is blind to it, and
    `registered_vaults` names it nowhere. Gating it on `--clean` let a plain compose write ingest
    directories into the operator's attachments folder and register the vault as its index root.

    Gating it additionally on "the directory already exists" still let it through, because a
    compose CREATES the path it is handed: `--index-root <that vault>/anything` produced the same
    nine directories, and an empty directory there did too. All three shapes are refused now, and
    the only exemption left is a directory that IS an ingest tree.
    """
    root, reg = _tmp(), _registry()
    # Demo's own tree, built while the registry is still clean — the exemption is about shape, so
    # it has to be a real tree to prove anything.
    mine_tree = root / "mine-index"
    argv = (str(_DEMO_VAULT), "--db", str(root / "mine.db"), "--index-root", str(mine_tree),
            "--registry", str(reg))
    rc, err = _compose_cli(*argv)
    assert rc == 0, (rc, err)

    other_vault = _vault_dir(root / "other-vault", "other")
    inherited = root / "other-core-vault"
    kept = inherited / "attachments" / "spec.pdf"
    kept.parent.mkdir(parents=True)
    kept.write_bytes(b"not regenerable")
    (other_vault / ".substrate.toml").write_text(
        'name = "other"\ninherits = ["other-core-vault"]\n', encoding="utf-8")
    scopes.record("other", vault=other_vault, db=root / "other.db",
                  index_root=root / "other-index", registry=reg)
    (other_vault / ".substrate.toml").write_text('name = "other\n', encoding="utf-8")

    vaults, unknown = scopes.registered_vaults(reg)
    assert [n for n, _ in unknown] == ["other"], (vaults, unknown)
    assert not any(_p.name == "other-core-vault" for _, _p in vaults), (
        "the fixture no longer orphans the inherited vault, so nothing here is exercised")

    empty = inherited / "empty-dir"
    empty.mkdir()
    shapes = {
        "an existing directory in the orphaned vault": kept.parent,
        "a path in it that does not exist yet": inherited / "new-subdir",
        "an EMPTY directory in it": empty,
        # The stated cost of the rule: no new index root anywhere while a manifest is unreadable.
        "a fresh directory with nothing to do with it": root / "fresh-index",
    }
    for what, target in shapes.items():
        before = reg.read_text(encoding="utf-8")
        rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "d.db"),
                               "--index-root", str(target), "--registry", str(reg))
        assert rc == 2, (what, rc, err)
        assert "'other'" in err, (what, err)
        # A compose that removes nothing must not be refused in the language of removal — and this
        # branch was the one that still said "delete" after every other message was converted.
        assert "delete" not in err, f"{what} was refused as a deletion: {err}"
        assert reg.read_text(encoding="utf-8") == before, f"{what} was registered anyway"
        assert not (target.exists() and list(target.glob("*__*__*"))), (
            f"{what} took an ingest tree")
    assert sorted(p.name for p in kept.parent.iterdir()) == ["spec.pdf"]
    assert sorted(p.name for p in empty.iterdir()) == []
    assert not (inherited / "new-subdir").exists(), "the refusal created the directory anyway"

    # THE ONE EXEMPTION, still live: a directory that already IS an ingest tree, either verb.
    for extra in ([], ["--clean"]):
        rc, err = _compose_cli(*argv, *extra)
        assert rc == 0, ("an existing ingest tree was refused", extra, rc, err)


def test_a_refusal_over_a_half_written_tree_names_the_directory_to_fix() -> None:
    """An interrupted compose leaves one directory with a `document.md` and no `run.json`, which
    makes the whole root "not an ingest tree" — so with any manifest elsewhere unreadable, that
    scope stops composing. Recoverable in seconds IF the refusal says which directory; otherwise
    it sends the operator through hundreds of them."""
    root, reg = _tmp(), _registry()
    tree = root / "demo-index"
    argv = (str(_DEMO_VAULT), "--db", str(root / "demo.db"), "--index-root", str(tree),
            "--registry", str(reg))
    rc, err = _compose_cli(*argv)
    assert rc == 0, (rc, err)
    half = next(c for c in tree.iterdir() if c.is_dir())
    (half / "run.json").unlink()

    b_vault = _vault_dir(root / "b-vault", "b")
    (b_vault / ".substrate.toml").write_text('name = "b\n', encoding="utf-8")
    scopes.record("b", vault=b_vault, db=root / "b.db", index_root=root / "b-index", registry=reg)

    for extra in ([], ["--clean"]):
        rc, err = _compose_cli(*argv, *extra)
        assert rc == 2, (extra, rc, err)
        assert half.name in err and "run.json" in err, (
            f"the refusal does not name the directory to fix: {err}")


def test_only_the_row_this_compose_replaces_is_exempt() -> None:
    """The own-row exemption dropped rows by VAULT for one revision, which waved through the stale
    row a manifest rename leaves behind — `record` keys by NAME and nothing deletes the old one.
    The compose then registered at a root that stale row refused every --clean over: the same wedge
    the exemption exists to remove, one rename away."""
    root, reg = _tmp(), _registry()
    shared = root / "shared"
    (shared / "old-index").mkdir(parents=True)
    (shared / "old.db").write_bytes(b"")
    scopes.record("demo-old", vault=_DEMO_VAULT, db=shared / "old.db",
                  index_root=shared / "old-index", registry=reg)

    rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "new.db"),
                           "--index-root", str(shared), "--registry", str(reg))
    assert rc == 2, ("a stale row for the same vault under an older name was exempted", rc, err)
    assert "'demo-old'" in err and str(scopes.registry_path(reg)) in err, err
    assert "demo" not in scopes.load(reg), "the compose registered over the stale row"


def test_a_claimant_is_judged_where_it_really_is() -> None:
    """A registered tree spelled `~/…` in a hand-edited registry, or swapped for a link to the tree
    it sits in, still exempted the wider tree, and a note of it was removed. The claimant is the
    composing scope itself, which is what gets past the equal-path guard."""
    for how in ("tilde", "link"):
        home, reg = _tmp(), _registry()
        tree = home / "a-index"
        note = tree / "a-vault__note__abcd1234"
        note.mkdir(parents=True)
        (note / "document.md").write_text("generated", encoding="utf-8")
        _vault_dir(home / "a-vault", "a")
        scopes.record("a", vault=home / "a-vault", db=home / "a.db", index_root=tree,
                      registry=reg)
        if how == "tilde":
            scopes.record("c", vault=_DEMO_VAULT, db=home / "c.db", index_root=note,
                          registry=reg)
            written = f'index_root = "{note.resolve()}"'
            by_hand = 'index_root = "~/a-index/a-vault__note__abcd1234"'
            reg.write_text(reg.read_text(encoding="utf-8").replace(written, by_hand),
                           encoding="utf-8")
            assert "~/a-index" in reg.read_text(encoding="utf-8")
        else:
            spare = tree / "zzz"
            spare.mkdir()
            scopes.record("c", vault=_DEMO_VAULT, db=home / "c.db", index_root=spare,
                          registry=reg)
            spare.rmdir()
            spare.symlink_to(tree)

        saved = os.environ.get("HOME")
        os.environ["HOME"] = str(home)
        try:
            rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(home / "d.db"),
                                   "--index-root", str(note), "--clean", "--registry", str(reg))
        finally:
            if saved is None:
                os.environ.pop("HOME", None)
            else:
                os.environ["HOME"] = saved
        assert rc == 2, (how, rc, err)
        assert "ingest tree of scope 'a'" in err, (how, err)
        assert (note / "document.md").is_file(), f"a claimant spelled by {how} removed the note"


def test_a_path_that_names_nothing_is_refused_before_any_write() -> None:
    """An unknown `~user` was kept as written: compose removed its index root and ingested every
    note before the database failed to open, and a registry spelled that way read as empty."""
    root, reg = _tmp(), _registry()
    idx = root / "idx"
    (idx / "old").mkdir(parents=True)
    for flag, value in (("--db", "~nosuchuser_zz/x.db"), ("--db", ""),
                        ("--index-root", "~nosuchuser_zz/idx"),
                        ("--registry", "~nosuchuser_zz/scopes.toml"), ("--registry", "")):
        argv = {"--db": str(root / "d.db"), "--index-root": str(idx), "--registry": str(reg)}
        argv[flag] = value
        rc, err = _compose_cli(str(_DEMO_VAULT), "--clean",
                               *[x for pair in argv.items() for x in pair])
        assert rc == 2, (flag, value, rc, err)
        assert (idx / "old").is_dir(), f"--clean ran before {flag} {value!r} was refused"
    try:
        scopes.load("~nosuchuser_zz/scopes.toml")
    except scopes.ScopeError:
        pass
    else:
        raise AssertionError("a registry under an unknown home read as empty")


def test_an_unknowable_chain_refuses_every_target_but_an_ingest_tree() -> None:
    """One scope whose inherited vaults cannot be known must not stop every other scope's --clean:
    the app recomposes a workspace after EVERY recording, and that failure is only logged. What is
    exempt is a directory that IS an ingest tree — every child an ingest directory — because no
    vault can be hiding in one. A registry row saying "this is my tree" is not enough: the rows
    written before `_refuse_index_root` ran on every compose name whatever --index-root was handed
    to one, and the registry is a hand-editable file besides."""
    import shutil

    for breakage in ("a manifest that does not parse", "a manifest that is gone"):
        root, reg = _tmp(), _registry()
        tree = root / "demo-index"
        argv = (str(_DEMO_VAULT), "--db", str(root / "demo.db"), "--index-root", str(tree),
                "--registry", str(reg))
        rc, err = _compose_cli(*argv)
        assert rc == 0, (rc, err)

        b_vault = _vault_dir(root / "b-vault", "b")
        manifest = b_vault / ".substrate.toml"
        if breakage == "a manifest that does not parse":
            manifest.write_text('name = "b\n', encoding="utf-8")
        else:
            manifest.unlink()
        scopes.record("b", vault=b_vault, db=root / "b.db", index_root=root / "b-index",
                      registry=reg)

        rc, err = _compose_cli(*argv, "--clean")
        assert rc == 0, (breakage, "an ingest tree", rc, err)

        # Still a tree with a `.DS_Store` in it, which any directory Finder opened has.
        (tree / ".DS_Store").write_bytes(b"\x00\x00")
        rc, err = _compose_cli(*argv, "--clean")
        assert rc == 0, (breakage, "a tree with a .DS_Store", rc, err)

        # NOT a tree once something that is not an ingest directory is in it — at either depth.
        note = next(c for c in tree.iterdir() if c.is_dir())
        for where, hidden in (("beside the notes", tree / "media-vault" / "attachments"),
                              ("inside a note", note / "media-vault" / "attachments")):
            hidden.mkdir(parents=True)
            kept = hidden / "contract.pdf"
            kept.write_bytes(b"not regenerable")
            rc, err = _compose_cli(*argv, "--clean")
            assert rc == 2, (breakage, where, rc, err)
            assert "'b'" in err, err
            assert kept.is_file(), f"--clean removed a vault {where}"
            shutil.rmtree(hidden.parent)

        elsewhere = root / "elsewhere"
        (elsewhere / "kept").mkdir(parents=True)
        (elsewhere / "kept" / "notes.txt").write_bytes(b"x")
        rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "demo.db"),
                               "--index-root", str(elsewhere), "--clean", "--registry", str(reg))
        assert rc == 2, (breakage, "another target", rc, err)
        assert "'b'" in err, err
        assert (elsewhere / "kept").is_dir(), "--clean ran while a chain was unknowable"


def test_clean_refuses_what_it_cannot_remove() -> None:
    """A half-deleted index root under a traceback is the shape every refusal here avoids."""
    root, reg = _tmp(), _registry()
    tree = root / "idx"
    locked = tree / "locked"
    (locked / "inner").mkdir(parents=True)
    locked.chmod(0o500)
    try:
        if os.access(locked, os.W_OK):
            return  # running as root; nothing to prove
        rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "d.db"),
                               "--index-root", str(tree), "--clean", "--registry", str(reg))
        assert rc == 2, (rc, err)
        assert "could not remove" in err, err
    finally:
        locked.chmod(0o700)


def test_a_claimant_below_a_note_claims_nothing() -> None:
    """A note directory's own subdirectory is part of that note, so a claimant registered there
    must not exempt the tree around it. A `document.md` that is a dangling symlink still marks the
    note: unknown is not a licence to delete."""
    for how in ("a file", "a dangling symlink"):
        root, reg = _tmp(), _registry()
        tree = root / "a-index"
        note = tree / "a-vault__note__abcd1234"
        (note / "sub").mkdir(parents=True)
        if how == "a file":
            (note / "document.md").write_text("generated", encoding="utf-8")
        else:
            (note / "document.md").symlink_to(note / "gone.md")
        _vault_dir(root / "a-vault", "a")
        scopes.record("a", vault=root / "a-vault", db=root / "a.db", index_root=tree,
                      registry=reg)
        scopes.record("c", vault=_DEMO_VAULT, db=root / "c.db", index_root=note / "sub",
                      registry=reg)

        rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "c.db"),
                               "--index-root", str(note / "sub"), "--clean", "--registry", str(reg))
        assert rc == 2, (how, rc, err)
        assert "ingest tree of scope 'a'" in err, (how, err)
        assert (note / "sub").is_dir(), f"--clean removed part of a note marked by {how}"


def test_a_directory_that_cannot_be_looked_into_counts_as_a_note() -> None:
    """Unknown is not a licence to delete. `exists()` reports an unreadable directory as absent on
    some Python versions and raises on others, so the check stats it."""
    root = _tmp()
    tree = root / "a-index"
    locked = tree / "locked"
    (locked / "claim").mkdir(parents=True)
    locked.chmod(0)
    try:
        if os.access(locked, os.X_OK):
            return  # running as root; nothing to prove
        assert scopes._in_a_note(locked / "claim", tree) is True
    finally:
        locked.chmod(0o755)


def test_a_registry_path_that_cannot_be_read_as_a_path_is_reported_not_raised() -> None:
    """A hand-edited registry can hold anything. A NUL in a path raised straight out of the guard
    — on every compose, not only a --clean, because the #4 guard compares the same paths."""
    root = _tmp()
    for field in ("vault", "db", "index_root"):
        reg = _registry()
        rows = {"vault": "/tmp/v", "db": "/tmp/x.db", "index_root": "/tmp/i"}
        rows[field] = "/tmp/a\\u0000b"
        reg.write_text("version = 1\n\n[scopes.odd]\n"
                       + "".join(f'{k} = "{v}"\n' for k, v in rows.items()), encoding="utf-8")
        vaults, unknown = scopes.registered_vaults(reg)
        assert [n for n, _ in unknown] == ["odd"], (field, vaults, unknown)

        idx = root / f"idx-{field}"
        (idx / "kept").mkdir(parents=True)          # not an ingest tree, so not exempt
        (idx / "kept" / "notes.txt").write_bytes(b"x")
        rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / f"{field}.db"),
                               "--index-root", str(idx), "--clean", "--registry", str(reg))
        assert rc == 2, (field, rc, err)
        assert "FATAL" in err, (field, err)


def test_a_looping_link_above_the_index_root_is_refused() -> None:
    """`exists()` is False for a path under a looping link, so the --clean checks never run: this
    covers the mkdir refusal below them, which used to raise."""
    root, reg = _tmp(), _registry()
    loop = root / "loop"
    loop.symlink_to(loop)
    rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "d.db"),
                           "--index-root", str(loop / "child"), "--clean", "--registry", str(reg))
    assert rc == 2, (rc, err)
    assert "--index-root" in err, err


def test_a_chain_that_no_longer_resolves_still_protects_what_it_names() -> None:
    """A registered scope whose manifest names a vault that is gone cannot be composed, but the
    vaults of its chain that DO exist must stay protected — the inherited ones carry no manifest
    for any other check to find."""
    import shutil

    breakages = {
        "a missing inherited vault": ('inherits = ["demo-core-vault"]',
                                      'inherits = ["demo-core-vault", "gone-vault"]'),
        "an unrelated bad key": ('reference_domains = ["software-dev", "distributed-systems"]',
                                 'reference_domains = ["Bad Tag!"]'),
        "a non-string entry": ('inherits = ["demo-core-vault"]',
                               'inherits = [5, "demo-core-vault"]'),
        "a manifest that does not parse": ('name = "demo"', 'name = "demo'),
    }
    for label, (old, new) in breakages.items():
        root, reg = _tmp(), _registry()
        b_vault, b_core = root / "b" / "demo", root / "b" / "demo-core-vault"
        shutil.copytree(_DEMO_VAULT, b_vault)
        shutil.copytree(_DEMO_VAULT.parent / "demo-core-vault", b_core)
        manifest = b_vault / ".substrate.toml"
        text = manifest.read_text(encoding="utf-8")
        assert old in text, f"the fixture manifest changed; {label} is no longer exercised"
        manifest.write_text(text.replace(old, new), encoding="utf-8")
        scopes.record("b", vault=b_vault, db=root / "b.db", index_root=root / "b-index",
                      registry=reg)
        kept = b_core / "attachments" / "spec.pdf"
        kept.parent.mkdir()
        kept.write_bytes(b"not regenerable")

        rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "d.db"),
                               "--index-root", str(kept.parent), "--clean", "--registry", str(reg))
        assert rc == 2, (label, rc, err)
        assert "'b'" in err, (label, err)
        assert kept.is_file(), f"--clean removed an inherited vault after {label}"


def test_path_comparisons_never_raise() -> None:
    """A guard that crashes on the input it judges refuses nothing: an unknown `~user` made
    `Path.expanduser` raise, and a looping link made `Path.resolve` raise before Python 3.13."""
    root = _tmp()
    loop = root / "loop"
    loop.symlink_to(loop)
    for odd in (Path("~nosuchuser_zz/x.db"), loop):
        assert scopes.is_within(odd, root) in (True, False)
        assert scopes._same_path(odd, root) is False
        assert scopes.nested(odd, root / "elsewhere") is False


def test_a_scope_can_clean_inside_its_own_overbroad_tree() -> None:
    """The likely aftermath of #23's typo, with one scope: its tree registered one level too high.
    Its own --clean back into the right place must not be refused in its own name."""
    root, reg = _tmp(), _registry()
    (root / "out-vault" / "index").mkdir(parents=True)
    scopes.record("demo", vault=_DEMO_VAULT, db=root / "demo.db",
                  index_root=root / "out-vault", registry=reg)
    rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "demo.db"),
                           "--index-root", str(root / "out-vault" / "index"), "--clean",
                           "--registry", str(reg))
    assert rc == 0, (rc, err)


def test_clean_refuses_a_directory_inside_another_scopes_vault() -> None:
    """Only the composing scope's own vaults were checked, so a directory with nothing authored in
    it inside another registered scope's vault — or a vault that scope inherits, which carries no
    manifest — was removed."""
    import shutil

    root, reg = _tmp(), _registry()
    a_vault, a_core = root / "a" / "demo", root / "a" / "demo-core-vault"
    shutil.copytree(_DEMO_VAULT, a_vault)
    shutil.copytree(_DEMO_VAULT.parent / "demo-core-vault", a_core)
    scopes.record("a", vault=a_vault, db=root / "a.db", index_root=root / "a-index",
                  registry=reg)
    for kept in (a_vault / "assets" / "diagram.png", a_core / "attachments" / "spec.pdf"):
        kept.parent.mkdir()
        kept.write_bytes(b"not regenerable")
        rc, err = _compose_cli(str(_DEMO_VAULT), "--db", str(root / "d.db"),
                               "--index-root", str(kept.parent), "--clean", "--registry", str(reg))
        assert rc == 2, (kept, rc, err)
        assert kept.is_file(), f"--clean removed {kept}"


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
