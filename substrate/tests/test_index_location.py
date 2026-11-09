"""Where a scope's index lives when nobody says: the engine's own folder, the same for every caller.

`compose` and `register` used to default to `out-vault/` in the working directory, so each client
chose its own location (Scripta: its own folder). Given no `--db` or `--index-root`, a scope the
registry already has keeps its place, and a new one goes to `~/.substrate/index/<scope>`.
`--default-location` rebuilds a scope there from scratch, leaving its old index untouched.
"""

from __future__ import annotations

import contextlib
import io
import shutil
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from substrate import cli, scopes  # noqa: E402

DEMO = ROOT / "vaults"


@pytest.fixture
def demo(tmp_path: Path) -> dict:
    shutil.copytree(DEMO / "demo-vault", tmp_path / "vaults" / "demo-vault")
    shutil.copytree(DEMO / "demo-core-vault", tmp_path / "vaults" / "demo-core-vault")
    return {"vault": tmp_path / "vaults" / "demo-vault", "registry": tmp_path / "scopes.toml",
            "tmp": tmp_path}


def _run(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        try:
            rc = cli.main(list(argv))
        except SystemExit as e:
            rc = e.code
    return rc, out.getvalue(), err.getvalue()


def _compose(demo: dict, *flags: str) -> tuple[int, str, str]:
    return _run("compose", str(demo["vault"]), "--registry", str(demo["registry"]), *flags)


def _files(root: Path) -> dict[str, bytes]:
    return {str(p.relative_to(root)): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}


def test_a_new_scope_is_composed_in_the_engines_folder(demo) -> None:
    rc, _, err = _compose(demo)
    assert rc == 0, err
    db, index_root = scopes.default_index("demo")
    assert db.parent == scopes.index_home() and db.name == "demo.db" and index_root.name == "demo"
    assert db.is_file() and any(index_root.iterdir())
    entry = scopes.load(demo["registry"])["demo"]
    assert (entry.db, entry.index_root) == (scopes.real_path(db), scopes.real_path(index_root))


def test_a_registered_scope_keeps_its_place(demo) -> None:
    """A compose never moves an index nobody asked to move."""
    db, index_root = demo["tmp"] / "placed" / "demo.db", demo["tmp"] / "placed" / "demo"
    assert _compose(demo, "--db", str(db), "--index-root", str(index_root))[0] == 0
    rc, _, err = _compose(demo)
    assert rc == 0, err
    entry = scopes.load(demo["registry"])["demo"]
    assert entry.db == scopes.real_path(db)
    assert not scopes.default_index("demo")[0].exists()


def test_default_location_rebuilds_there_and_leaves_the_old_index(demo) -> None:
    old_db, old_root = demo["tmp"] / "old" / "demo.db", demo["tmp"] / "old" / "demo"
    assert _compose(demo, "--db", str(old_db), "--index-root", str(old_root))[0] == 0
    before = _files(old_db.parent)
    vault_before = _files(demo["vault"])

    rc, out, err = _compose(demo, "--default-location")

    assert rc == 0, err
    db, index_root = scopes.default_index("demo")
    entry = scopes.load(demo["registry"])["demo"]
    assert (entry.db, entry.index_root) == (scopes.real_path(db), scopes.real_path(index_root))
    assert entry.composed
    assert db.is_file() and f"db: {db}" in out
    assert _files(old_db.parent) == before, "the old index was touched"
    assert _files(demo["vault"]) == vault_before, "a vault note was touched"


def test_half_a_location_is_refused(demo) -> None:
    for flags in (("--db", str(demo["tmp"] / "x.db")), ("--index-root", str(demo["tmp"] / "x"))):
        rc, _, err = _compose(demo, *flags)
        assert rc == 2 and "--db and --index-root together, or neither" in err, err
    assert not demo["registry"].exists()


def test_default_location_with_a_location_is_refused(demo) -> None:
    rc, _, err = _compose(demo, "--default-location", "--db", str(demo["tmp"] / "x.db"),
                          "--index-root", str(demo["tmp"] / "x"))
    assert rc == 2 and "two places for one index" in err, err


@pytest.mark.parametrize("name", [".", "..", ".hidden", "a/b", "a\\b", "a\0b", "demo.db",
                                  "demo.db-wal", "-x", "a b", "Team Notes"])
def test_a_name_that_is_not_plain_gets_a_plain_folder_of_its_own(name) -> None:
    """One folder holds every db and tree, so a dot could make one scope's tree another's database
    or its SQLite side file, and `..` or `/` would leave the folder."""
    db, index_root = scopes.default_index(name)
    assert index_root.parent == scopes.index_home() and db.parent == scopes.index_home()
    folder = index_root.name
    assert folder != name and "." not in folder and not folder.startswith("-")
    assert db.name == f"{folder}.db"
    assert scopes.default_index(name) == (db, index_root), "not stable"


def test_names_that_make_the_same_plain_parts_get_two_folders() -> None:
    assert scopes.default_index("a.b")[1] != scopes.default_index("a b")[1]
    assert scopes.default_index("demo.db")[1] != scopes.default_index("demo")[1]


@pytest.mark.parametrize("name", ["demo", "demo-2", "a_b", "café", "cafe\u0301"])
def test_a_plain_name_is_its_own_folder(name) -> None:
    db, index_root = scopes.default_index(name)
    assert index_root == scopes.index_home() / scopes.index_folder_name(name)
    assert index_root.name in (name, "café")


@pytest.mark.parametrize("twin", ["Demo", "DEMO", "de\u0301mo"])
def test_a_case_or_unicode_twin_of_a_registered_name_is_refused(twin) -> None:
    taken = ["démo" if "\u0301" in twin else "demo"]
    with pytest.raises(scopes.ScopeError, match="only by case or Unicode form"):
        scopes.default_index(twin, taken=taken)


def test_a_name_another_vault_holds_is_refused_before_anything_is_written(demo) -> None:
    """Building first and refusing at registration left that vault's notes in the owner's place."""
    assert _compose(demo)[0] == 0
    other = demo["tmp"] / "other" / "demo-vault"
    shutil.copytree(demo["vault"], other)
    shutil.copytree(demo["vault"].parent / "demo-core-vault", other.parent / "demo-core-vault")
    (other / "02-areas" / "only-here.md").write_text(
        "---\nstatus: active\ndoc_type: reference\n---\n# Only here\n\nA note no owner has.\n")
    db, index_root = scopes.default_index("demo")
    before = _files(index_root.parent)
    rc, _, err = _run("compose", str(other), "--registry", str(demo["registry"]))
    assert rc == 2 and "already registered to" in err and "Nothing was written" in err, err
    assert _files(index_root.parent) == before


def test_a_renamed_manifest_keeps_its_vaults_index(demo) -> None:
    placed_db, placed_root = demo["tmp"] / "placed" / "demo.db", demo["tmp"] / "placed" / "demo"
    assert _compose(demo, "--db", str(placed_db), "--index-root", str(placed_root))[0] == 0
    manifest = demo["vault"] / ".substrate.toml"
    manifest.write_text(manifest.read_text().replace('name = "demo"', 'name = "renamed"'))
    rc, _, err = _compose(demo)
    assert rc == 0, err
    assert scopes.load(demo["registry"])["renamed"].db == scopes.real_path(placed_db)
    assert not scopes.default_index("renamed")[0].exists()


def test_register_leaves_a_new_scope_pending_in_the_engines_folder(demo) -> None:
    rc, _, err = _run("register", str(demo["vault"]), "--registry", str(demo["registry"]))
    assert rc == 0, err
    entry = scopes.load(demo["registry"])["demo"]
    assert entry.pending and entry.db == scopes.real_path(scopes.default_index("demo")[0])


def test_embed_takes_a_scope_not_a_path(demo) -> None:
    assert _compose(demo)[0] == 0
    rc, _, err = _run("embed", "--scope", "demo", "--db", str(demo["tmp"] / "x.db"),
                      "--registry", str(demo["registry"]))
    assert rc == 2 and "name two different indexes" in err, err
    rc, _, err = _run("embed", "--scope", "nope", "--registry", str(demo["registry"]))
    assert rc == 2 and "unknown scope 'nope'" in err, err


def test_a_name_registration_would_refuse_builds_nothing(demo) -> None:
    manifest = demo["vault"] / ".substrate.toml"
    manifest.write_text(manifest.read_text().replace('name = "demo"', 'name = "demo "'))
    rc, _, err = _compose(demo)
    assert rc == 2 and "unusable" in err, err
    assert not scopes.index_home().exists() or not any(scopes.index_home().iterdir())


def test_a_missing_vault_elsewhere_does_not_stop_a_new_scope_in_the_engines_folder(demo) -> None:
    """While a registered vault cannot be read, no new index root may be created anywhere it could
    be. The engine's own folder, holding only indexes, is not such a place."""
    gone = demo["tmp"] / "gone" / "demo-vault"
    shutil.copytree(demo["vault"], gone)
    shutil.copytree(demo["vault"].parent / "demo-core-vault", gone.parent / "demo-core-vault")
    manifest = gone / ".substrate.toml"
    manifest.write_text(manifest.read_text().replace('name = "demo"', 'name = "gone"'))
    assert _run("compose", str(gone), "--registry", str(demo["registry"]))[0] == 0
    shutil.move(gone.parent, demo["tmp"] / "moved-away")

    rc, _, err = _compose(demo)
    assert rc == 0, err
    assert scopes.load(demo["registry"])["demo"].db == scopes.real_path(
        scopes.default_index("demo")[0])
    # Anywhere else, the refusal stands.
    other = demo["tmp"] / "other-place"
    rc, _, err = _compose(demo, "--db", str(other / "x.db"), "--index-root", str(other / "x"))
    assert rc == 2 and "cannot be known" in err, err


def test_default_location_refuses_a_vault_registered_under_its_old_name(demo) -> None:
    old_db, old_root = demo["tmp"] / "old" / "demo.db", demo["tmp"] / "old" / "demo"
    assert _compose(demo, "--db", str(old_db), "--index-root", str(old_root))[0] == 0
    manifest = demo["vault"] / ".substrate.toml"
    manifest.write_text(manifest.read_text().replace('name = "demo"', 'name = "renamed"'))
    before = demo["registry"].read_bytes()
    rc, _, err = _compose(demo, "--default-location")
    assert rc == 2 and "registered as 'demo'" in err and "Nothing was written" in err, err
    assert demo["registry"].read_bytes() == before
