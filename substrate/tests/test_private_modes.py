"""Nothing the engine writes is readable by another uid on the machine.

`~` on macOS is 0750 group staff and every local account is in staff, so an index left 0644 in a
0755 directory is a scope's whole text for any other user, with no engine in the way. Verified
2026-10-31 against every registered scope. These tests run each writer under the umask the
operator's shell actually has (022), so a writer that forgets the engine's umask fails here the way
it failed on disk.

Runnable with plain `python tests/test_private_modes.py`; discovered by pytest if added.
"""

from __future__ import annotations

import contextlib
import io
import os
import stat
import sys
import tempfile
from collections.abc import Iterator
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import cli, introspect, private, scopes, stack  # noqa: E402
from substrate.embed.cache import VectorCache  # noqa: E402
from substrate.mcp import server  # noqa: E402
from substrate.store.index_store import IndexStore  # noqa: E402

_DEMO_VAULT = Path(__file__).resolve().parent.parent / "vaults" / "demo-vault"


@contextlib.contextmanager
def _umask(mask: int) -> Iterator[None]:
    previous = os.umask(mask)
    try:
        yield
    finally:
        os.umask(previous)


def _current_umask() -> int:
    mask = os.umask(0)
    os.umask(mask)
    return mask


def _loose(*roots: Path) -> list[str]:
    """Every path under `roots` with a group or other bit, spelled with its mode."""
    out = []
    for root in roots:
        walk = [root] + (sorted(root.rglob("*")) if root.is_dir() else [])
        for p in walk:
            if p.is_symlink() or not p.exists():
                continue
            mode = stat.S_IMODE(os.lstat(p).st_mode)
            if mode & 0o077:
                out.append(f"{oct(mode)} {p}")
    return out


def _index(db: Path, ir: Path) -> list[Path]:
    """Everything one composed scope's text lives in."""
    return [*private.sqlite_family(db), ir]


def _mode(p: Path) -> int:
    return stat.S_IMODE(os.lstat(p).st_mode)


def _compose(root: Path, reg: Path | None = None, ir: Path | None = None,
             home: Path | None = None) -> tuple[int, str, Path, Path, Path]:
    """Compose the demo vault under umask 022, with `home` (default `root`) standing in for
    `~/.substrate`, the folder the engine owns."""
    db = root / "out" / "demo.db"
    ir = ir if ir is not None else root / "out" / "demo-index"
    reg = reg if reg is not None else root / "scopes.toml"
    err = io.StringIO()
    default = scopes.engine_home
    scopes.engine_home = lambda: home if home is not None else root
    try:
        with _umask(0o022), contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(err):
            rc = cli.main(["compose", str(_DEMO_VAULT), "--db", str(db), "--index-root", str(ir),
                           "--registry", str(reg)])
    finally:
        scopes.engine_home = default
    return rc, err.getvalue(), db, ir, reg


def _loosen(*roots: Path) -> None:
    """What every index built before this fix looks like on disk."""
    for root in roots:
        if root.is_dir():
            for p in [root, *root.rglob("*")]:
                p.chmod(0o755 if p.is_dir() else 0o644)
        elif root.exists():
            root.chmod(0o644)


# ---------------------------------------------------------------- compose

def test_compose_writes_a_private_index() -> None:
    root = Path(tempfile.mkdtemp())
    rc, err, db, ir, _ = _compose(root)
    assert rc == 0, (rc, err)
    assert db.is_file() and any(ir.iterdir()), "the compose must have written an index"
    loose = _loose(*_index(db, ir), db.parent)
    assert not loose, f"another uid can read the composed index: {loose[:5]}"


def test_compose_seals_an_index_built_before_the_umask() -> None:
    """SQLite reopens an existing database at its old mode, and compose overwrites ingest files in
    place. So an index first built at 0644 stays 0644 under any umask unless compose seals it."""
    root = Path(tempfile.mkdtemp())
    rc, err, db, ir, _ = _compose(root)
    assert rc == 0, (rc, err)
    _loosen(*_index(db, ir))
    assert _loose(db, ir), "the fixture must start loose"

    rc, err, db, ir, _ = _compose(root)
    assert rc == 0, (rc, err)
    loose = _loose(*_index(db, ir))
    assert not loose, f"a recompose left the old index readable: {loose[:5]}"


def test_a_refused_compose_still_seals_the_index() -> None:
    """Every refusal in compose comes after the ingest tree has been rewritten. A scope that keeps
    failing compose would otherwise leak each new edit through its old 0644 files."""
    import shutil

    root = Path(tempfile.mkdtemp())
    shutil.copytree(_DEMO_VAULT, root / "demo-vault")
    shutil.copytree(_DEMO_VAULT.parent / "demo-core-vault", root / "demo-core-vault")
    db, ir, reg = root / "out" / "demo.db", root / "out" / "demo-index", root / "scopes.toml"
    argv = ["compose", str(root / "demo-vault"), "--db", str(db), "--index-root", str(ir),
            "--registry", str(reg)]

    def compose() -> int:
        with _umask(0o022), contextlib.redirect_stdout(io.StringIO()), \
                contextlib.redirect_stderr(io.StringIO()):
            return cli.main(argv)

    assert compose() == 0
    _loosen(*_index(db, ir))
    (root / "demo-vault" / "no-status.md").write_text("# No status\n\nA note with no spine.\n")
    assert compose() == 3, "the fixture must make compose refuse"
    loose = _loose(*_index(db, ir))
    assert not loose, f"a refused compose left the index readable: {loose[:5]}"


# ---------------------------------------------------------------- the folder holding the index

def test_compose_seals_the_folder_holding_the_index() -> None:
    """The databases were 0600 inside a 0755 folder, so any other user could list every scope's
    name. `~/.substrate` is the engine's, so a folder inside it is sealed."""
    root = Path(tempfile.mkdtemp())
    rc, err, db, _, _ = _compose(root)
    assert rc == 0, (rc, err)
    db.parent.chmod(0o755)
    rc, err, db, _, _ = _compose(root)
    assert rc == 0, (rc, err)
    assert _mode(db.parent) == 0o700, f"the folder holding the index is {oct(_mode(db.parent))}"


def test_compose_leaves_a_folder_outside_the_engines_alone_and_says_so() -> None:
    """`--db ~/x.db` must not `chmod 700 ~`. Outside `~/.substrate` the holder is not the engine's
    to change, and a compose that leaves it listable says so. The registry sitting beside it does
    not make it the engine's: `--registry ~/Documents/scopes.toml` would then hand over all of
    `~/Documents`."""
    root, home = Path(tempfile.mkdtemp()), Path(tempfile.mkdtemp())
    rc, err, db, _, _ = _compose(root, home=home)
    assert rc == 0, (rc, err)
    db.parent.chmod(0o755)
    rc, err, db, _, _ = _compose(root, home=home)
    assert rc == 0, (rc, err)
    assert _mode(db.parent) == 0o755, "a folder outside the engine's was changed"
    assert os.path.realpath(db.parent) in err and "chmod go-rwx" in err, err


def test_status_and_the_server_report_a_listable_holding_folder() -> None:
    root = Path(tempfile.mkdtemp())
    rc, err, db, _, reg = _compose(root)
    assert rc == 0, (rc, err)
    db.parent.chmod(0o755)
    entry = scopes.resolve("demo", reg)
    with IndexStore(db) as s:
        exposed = introspect.status_payload(s, entry, stack=stack.Stack(),
                                            registry=str(reg))["exposed"]
    assert exposed == [os.path.realpath(db.parent)], exposed

    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        server.warn_exposed(str(reg))
    assert os.path.realpath(db.parent) in err.getvalue(), err.getvalue()
    assert _mode(db.parent) == 0o755, "the reader warns; it must not repair"


# ---------------------------------------------------------------- only what the engine wrote

def test_compose_into_a_shared_folder_seals_only_its_own_notes() -> None:
    """The recursive seal ran on whatever `--index-root` passed `_refuse_index_root`, and a plain
    compose into an existing folder that is not a vault passes it. Every file the operator kept
    there went 0600, and the folder 0700."""
    root = Path(tempfile.mkdtemp())
    shared = root / "shared"
    (shared / "photos").mkdir(parents=True)
    (root / "out").mkdir(mode=0o700)  # compose does not create `--db`'s folder on this path
    (shared / "photos" / "a.jpg").write_text("")
    (shared / "readme.txt").write_text("")
    with _umask(0o022):
        for p in (shared, shared / "photos"):
            p.chmod(0o755)
        for p in (shared / "readme.txt", shared / "photos" / "a.jpg"):
            p.chmod(0o644)

    rc, err, _, ir, _ = _compose(root, ir=shared)
    assert rc == 0, (rc, err)
    theirs = {"photos", "readme.txt"}
    _loosen(*(p for p in ir.iterdir() if p.name not in theirs))
    rc, err, _, ir, _ = _compose(root, ir=shared)
    assert rc == 0, (rc, err)

    assert _mode(shared / "readme.txt") == 0o644, "a file compose did not write was changed"
    assert _mode(shared / "photos") == 0o755 and _mode(shared / "photos" / "a.jpg") == 0o644
    assert _mode(shared) == 0o755, "a folder holding other files is not the engine's to seal"
    ingest = [p for p in ir.iterdir() if p.name not in theirs]
    assert ingest and not _loose(*ingest), _loose(*ingest)[:5]
    assert os.path.realpath(shared) in err, f"the compose must name the root it left: {err!r}"


def test_the_ingest_pattern_matches_every_name_compose_can_build() -> None:
    """`INGEST_DIR` decides what is sealed; `ingest_dir_name` is what compose names a directory.
    A name the pattern misses would be left at whatever mode it was found."""
    for vault, note in [("v", Path("/a/b/note.md")), ("my-vault", Path("/x/__.md")),
                        ("v__w", Path("/x/a__b.md")), ("v", Path("/x/.hidden.md")),
                        ("v", Path("/x/two\nlines.md"))]:
        name = private.ingest_dir_name(vault, note)
        assert private.INGEST_DIR.fullmatch(name), name


def test_the_ingest_pattern_is_what_compose_writes() -> None:
    """`INGEST_DIR` decides what is sealed. A directory compose writes that it does not match
    would be left at whatever mode it was found."""
    root = Path(tempfile.mkdtemp())
    rc, err, _, ir, _ = _compose(root)
    assert rc == 0, (rc, err)
    names = [p.name for p in ir.iterdir()]
    assert names, "the compose must have written ingest directories"
    stray = [n for n in names if not private.INGEST_DIR.fullmatch(n)]
    assert not stray, f"compose wrote directories the seal would skip: {stray}"


def test_a_link_in_the_index_root_is_never_followed() -> None:
    """A link named like an ingest directory points at something that is not the tree's."""
    base = Path(tempfile.mkdtemp())
    outside = base / "elsewhere"
    outside.mkdir()
    (outside / "note.md").write_text("")
    (outside / "note.md").chmod(0o644)
    outside.chmod(0o755)
    ir = base / "home" / "demo-index"
    ir.mkdir(parents=True)
    ir.chmod(0o700)
    (ir / "v__n__0123abcd").symlink_to(outside)

    failed = private.seal_index(base / "home" / "demo.db", ir, home=base / "home")
    assert _mode(outside) == 0o755 and _mode(outside / "note.md") == 0o644, "the link was followed"
    assert any("v__n__0123abcd" in line and "a link" in line for line in failed), (
        "compose would write a note through it, so it must be reported", failed)


def _ingest_dir(root: Path, name: str = "v__n__0123abcd") -> Path:
    d = root / name
    d.mkdir(parents=True)
    (d / "document.md").write_text("text")
    d.chmod(0o755)
    (d / "document.md").chmod(0o644)
    return d


def test_a_db_inside_its_index_root_is_the_engines_own() -> None:
    """`_refuse_index_root` allows `--db` inside `--index-root`. The db is not a stranger's file,
    so a root holding only it and ingest directories is the engine's tree wherever it is."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    _ingest_dir(ir)
    db = ir / "x.db"
    db.write_text("")
    ir.chmod(0o755)
    failed = private.seal_index(db, ir, home=Path(tempfile.mkdtemp()))
    assert failed == [] and _mode(ir) == 0o700, (failed, oct(_mode(ir)))
    assert private.exposed_index(db, ir) == []


def test_a_root_that_holds_the_db_and_other_files_is_not_sealed_inside_home() -> None:
    """The root's own rule decides the root, even when it also holds the db and sits in `home`."""
    home = Path(tempfile.mkdtemp())
    ir = home / "idx"
    _ingest_dir(ir)
    (ir / "x.db").write_text("")
    (ir / "readme.txt").write_text("")
    ir.chmod(0o755)
    failed = private.seal_index(ir / "x.db", ir, home=home)
    assert _mode(ir) == 0o755, "a folder holding the operator's files was sealed"
    assert any("did not write" in line for line in failed), failed
    assert private.exposed_index(ir / "x.db", ir) == [str(ir)], "one folder, listed once"


def test_an_empty_ingest_directory_is_the_engines() -> None:
    """ingest makes the directory before it writes, and a note refused in between leaves it empty.
    That must not make the whole root someone else's."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    _ingest_dir(ir)
    (ir / "v__refused__89abcdef").mkdir()
    ir.chmod(0o755)
    failed = private.seal_index(base / "x.db", ir, home=base)
    assert failed == [] and _mode(ir) == 0o700, (failed, oct(_mode(ir)))


def test_a_folder_named_like_an_ingest_directory_is_not_one() -> None:
    """`photos__2024__20240101` matches the name. Holding files ingest never writes, it is the
    operator's."""
    base = Path(tempfile.mkdtemp())
    ir = base / "shared"
    _ingest_dir(ir)
    theirs = ir / "photos__2024__20240101"
    theirs.mkdir()
    (theirs / "a.jpg").write_text("")
    theirs.chmod(0o755)
    (theirs / "a.jpg").chmod(0o644)
    private.seal_index(base / "x.db", ir, home=base)
    assert _mode(theirs) == 0o755 and _mode(theirs / "a.jpg") == 0o644
    assert not _loose(ir / "v__n__0123abcd"), "the real ingest directory must still be sealed"


def test_a_root_others_can_write_is_not_walked() -> None:
    """Whoever can write the root can swap an ingest directory for a link between the listing and
    the chmod, and `chmod -R` would follow it to wherever it points."""
    base = Path(tempfile.mkdtemp())
    ir = base / "shared"
    mine = _ingest_dir(ir)
    (ir / "readme.txt").write_text("")
    ir.chmod(0o777)
    failed = private.seal_index(base / "x.db", ir, home=base)
    assert _mode(mine) == 0o755, "a tree another uid can rewrite was walked"
    assert any("other users can write it" in line for line in failed), failed


def test_a_root_whose_folder_others_can_write_is_not_walked() -> None:
    """Whoever can write the folder holding the root can rename the root away and put a link in
    its place between the listing and the chmod."""
    base = Path(tempfile.mkdtemp())
    holder = base / "open"
    ir = holder / "idx"
    mine = _ingest_dir(ir)
    ir.chmod(0o700)
    holder.chmod(0o777)
    failed = private.seal_index(base / "x.db", ir, home=Path(tempfile.mkdtemp()))
    assert _mode(mine) == 0o755, "a tree whose root another uid can swap was walked"
    assert any("other users can write it" in line for line in failed), failed


def test_the_walk_uses_a_listing_taken_after_the_root_was_sealed() -> None:
    """A root another uid could write is listed, then sealed. Whatever it swapped in before the
    seal must not be walked. The victim looks exactly like an ingest directory, so only refusing
    the link protects it."""
    base = Path(tempfile.mkdtemp())
    outside = base / "victim"
    outside.mkdir()
    (outside / "document.md").write_text("")
    outside.chmod(0o755)
    (outside / "document.md").chmod(0o644)
    ir = base / "idx"
    swapped = _ingest_dir(ir)
    ir.chmod(0o777)
    root = os.stat(ir)
    chmod, fchmod = os.chmod, os.fchmod

    def swap() -> None:
        if swapped.is_dir() and not swapped.is_symlink():
            import shutil
            shutil.rmtree(swapped)
            swapped.symlink_to(outside)

    def on_chmod(path, mode, **kw):
        if not kw.get("dir_fd") and os.path.realpath(path) == os.path.realpath(ir):
            swap()  # the other uid acts just before the root is sealed
        return chmod(path, mode, **kw)

    def on_fchmod(fd, mode):
        st = os.fstat(fd)
        if (st.st_dev, st.st_ino) == (root.st_dev, root.st_ino):
            swap()
        return fchmod(fd, mode)

    os.chmod, os.fchmod = on_chmod, on_fchmod
    try:
        private.seal_index(base / "x.db", ir, home=base)
    finally:
        os.chmod, os.fchmod = chmod, fchmod
    assert swapped.is_symlink(), "the fixture must actually swap the directory under the seal"
    assert _mode(outside) == 0o755 and _mode(outside / "document.md") == 0o644, (
        "the swapped link was followed")


def test_an_ancestor_others_can_write_stops_the_seal() -> None:
    """Whoever can write any folder above the index can move a tree of their choosing to its path
    between the check and the chmod. Two levels up is as good as one."""
    base = Path(tempfile.mkdtemp())
    ir = base / "open" / "mid" / "idx"
    mine = _ingest_dir(ir)
    ir.chmod(0o700)
    (base / "open" / "mid").chmod(0o700)
    (base / "open").chmod(0o777)
    failed = private.seal_index(base / "open" / "mid" / "x.db", ir, home=Path(tempfile.mkdtemp()))
    assert _mode(mine) == 0o755, "a tree under a folder another uid can write was walked"
    assert any("other users can write it" in line for line in failed), failed


def test_the_folder_holding_a_linked_root_is_checked() -> None:
    """`--index-root` may be a link. Whoever can write the folder holding the LINK can repoint it
    after every check on the target has passed."""
    base = Path(tempfile.mkdtemp())
    real = base / "safe" / "idx"
    mine = _ingest_dir(real)
    real.chmod(0o700)
    (base / "open").mkdir()
    (base / "open" / "idx").symlink_to(real)
    (base / "open").chmod(0o777)
    failed = private.seal_index(base / "safe" / "x.db", base / "open" / "idx",
                                home=Path(tempfile.mkdtemp()))
    assert _mode(mine) == 0o755, "a root reached through a link others can repoint was walked"
    assert any("open" in line and "other users can write it" in line for line in failed), failed


def test_a_db_inside_a_root_this_call_seals_is_sealed_too() -> None:
    """The db's folder used to be judged before the root was sealed, so a db in a writable root of
    the engine's own was left loose by the very call that sealed its folder."""
    home = Path(tempfile.mkdtemp())
    ir = home / "idx"
    _ingest_dir(ir)
    (ir / "x.db").write_text("")
    (ir / "x.db").chmod(0o644)
    ir.chmod(0o777)
    failed = private.seal_index(ir / "x.db", ir, home=home)
    assert failed == [], failed
    assert _mode(ir) == 0o700 and _mode(ir / "x.db") == 0o600


def test_an_empty_folder_shaped_like_an_ingest_directory_is_left_alone() -> None:
    """An empty folder with the shape is neither the engine's nor proof the root is someone
    else's: a refused note leaves one, and so could the operator."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    _ingest_dir(ir)
    empty = ir / "photos__2024__20240101"
    empty.mkdir()
    empty.chmod(0o755)
    private.seal_index(base / "x.db", ir, home=base)
    assert _mode(empty) == 0o755, "an empty folder was chmodded"
    assert _mode(ir) == 0o700, "an empty shaped folder must not keep the root unsealed"


def test_an_engine_home_that_is_the_home_folder_owns_nothing() -> None:
    """A `~/.substrate` that is, or is linked to, `~` would make every folder under `~` the
    engine's."""
    user = Path(tempfile.mkdtemp())
    docs = user / "Documents"
    docs.mkdir()
    docs.chmod(0o755)
    previous = os.environ.get("HOME")
    os.environ["HOME"] = str(user)
    try:
        private.seal_index(docs / "x.db", None, home=user)
        assert _mode(docs) == 0o755, "a folder under the operator's home was sealed"
        linked = Path(tempfile.mkdtemp()) / ".substrate"
        linked.symlink_to(user)
        assert not private._engine_owns(linked, docs), "a linked engine home owned the folder"
    finally:
        if previous is None:
            del os.environ["HOME"]
        else:
            os.environ["HOME"] = previous


def test_a_db_whose_folder_others_can_write_is_not_sealed() -> None:
    """Whoever can write the db's folder can swap the db for a link, and the seal follows a root."""
    base = Path(tempfile.mkdtemp())
    folder = base / "open"
    folder.mkdir()
    (folder / "x.db").write_text("")
    (folder / "x.db").chmod(0o644)
    folder.chmod(0o777)
    failed = private.seal_index(folder / "x.db", None, home=Path(tempfile.mkdtemp()))
    assert _mode(folder / "x.db") == 0o644, "a db another uid could have swapped was chmodded"
    assert any("other users can write it" in line and "x.db" in line for line in failed), failed


def test_a_folder_that_cannot_be_checked_is_reported() -> None:
    """What cannot be checked is not reported as safe."""
    if os.geteuid() == 0:
        return
    base = Path(tempfile.mkdtemp())
    (base / "shut" / "out").mkdir(parents=True)
    (base / "shut").chmod(0o600)
    try:
        db = base / "shut" / "out" / "x.db"
        folder = str(Path(os.path.realpath(base)) / "shut" / "out")
        failed = private.seal_index(db, None, home=Path(tempfile.mkdtemp()))
        assert any(f"{folder}: Permission denied" in line for line in failed), failed
        assert str(db) in private.exposed_index(db, None), "an unverifiable folder is not safe"
    finally:
        (base / "shut").chmod(0o700)


def test_every_folder_in_a_chain_of_links_is_checked() -> None:
    """`idx -> open/hop -> safe/idx`: the folder holding the middle link is on neither the written
    nor the resolved path, and whoever can write it can repoint the chain."""
    base = Path(tempfile.mkdtemp())
    real = base / "safe" / "idx"
    mine = _ingest_dir(real)
    real.chmod(0o700)
    (base / "open").mkdir()
    (base / "open" / "hop").symlink_to(real)
    (base / "open").chmod(0o777)
    (base / "links").mkdir()
    (base / "links" / "idx").symlink_to(base / "open" / "hop")
    failed = private.seal_index(base / "safe" / "x.db", base / "links" / "idx",
                                home=Path(tempfile.mkdtemp()))
    assert _mode(mine) == 0o755, "a root reached through a link others can repoint was walked"
    assert any("open: other users can write it" in line for line in failed), failed


def test_a_shaped_folder_holding_only_hidden_files_is_left_alone() -> None:
    """Finder writes `.DS_Store` into any folder it opens, so an operator's folder that happens to
    have the shape loses nothing by being looked at."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    _ingest_dir(ir)
    theirs = ir / "photos__2024__20240101"
    theirs.mkdir()
    (theirs / ".DS_Store").write_text("")
    theirs.chmod(0o755)
    private.seal_index(base / "x.db", ir, home=base)
    assert _mode(theirs) == 0o755, "a folder holding no ingest file was chmodded"


def test_a_case_variant_db_is_still_the_engines() -> None:
    """APFS ignores case: `--db idx/Demo.db` IS `idx/demo.db`, and must not make the root a
    stranger's."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    _ingest_dir(ir)
    (ir / "demo.db").write_text("")
    if not (ir / "Demo.db").exists():
        return  # a case-sensitive volume: there is no variant to test
    ir.chmod(0o755)
    failed = private.seal_index(ir / "Demo.db", ir, home=base)
    assert failed == [] and _mode(ir) == 0o700, (failed, oct(_mode(ir)))


def test_a_path_with_a_colon_is_one_path_per_line() -> None:
    """A transcript title can put `: ` in a note's stem. Splitting reasons off at the first `: `
    merged two files into one line under a cut-short path."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    d = _ingest_dir(ir, "v__Meeting: Q3__0123abcd")
    (d / "run.json").write_text("{}")
    (d / "run.json").chmod(0o644)
    real_chmod = os.chmod

    def refuse(path, mode, **kw):
        if os.fspath(path) in ("document.md", "run.json"):
            raise PermissionError(1, "Operation not permitted")
        return real_chmod(path, mode, **kw)

    os.chmod = refuse
    try:
        failed = private.seal_index(base / "x.db", ir, home=base)
    finally:
        os.chmod = real_chmod
    lines = [line for line in failed if "Meeting: Q3" in line]
    assert len(lines) == 2, failed
    assert all(line.startswith(str(Path(os.path.realpath(d)))) for line in lines), lines


def test_a_hard_linked_ingest_file_gets_a_file_of_its_own() -> None:
    """macOS lets any user who can reach a file hard-link it. Refusing to touch a linked file let
    them keep an index readable for good; chmodding through it could reach a file of the
    operator's they planted the link to. The name is given a private file instead, and nothing
    written from now on reaches the other name."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    d = _ingest_dir(ir)
    elsewhere = base / "elsewhere"
    elsewhere.mkdir()
    os.link(d / "document.md", elsewhere / "kept.md")
    assert private.seal_index(base / "x.db", ir, home=base) == []
    assert os.stat(d / "document.md").st_nlink == 1 and _mode(d / "document.md") == 0o600
    assert (d / "document.md").read_text() == "text", "the content must survive the relink"
    assert _mode(elsewhere / "kept.md") == 0o644, "the other name's file was changed"
    (d / "document.md").write_text("new")
    assert (elsewhere / "kept.md").read_text() == "text", "a later write reached the other name"


def test_a_stray_file_in_an_ingest_directory_is_reported() -> None:
    """A directory with the shape and a file ingest never writes is left alone, and says so."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    d = _ingest_dir(ir)
    (d / "notes.txt").write_text("")
    failed = private.seal_index(base / "x.db", ir, home=base)
    assert _mode(d / "document.md") == 0o644
    assert any(str(Path(os.path.realpath(d))) in line and "not an ingest directory" in line
               for line in failed), failed


def test_the_database_is_sealed_without_being_opened() -> None:
    """Closing any descriptor on a SQLite file drops every POSIX lock this process holds on it,
    a live connection's included."""
    base = Path(tempfile.mkdtemp())
    db = base / "x.db"
    for p in private.sqlite_family(db)[:3]:
        p.write_text("")
        p.chmod(0o644)
    opened: list[str] = []
    real_open = os.open

    def watch(path, *a, **kw):
        opened.append(os.fspath(path))
        return real_open(path, *a, **kw)

    os.open = watch
    try:
        assert private.seal_index(db, None, home=base) == []
    finally:
        os.open = real_open
    family = {os.path.realpath(p) for p in private.sqlite_family(db)}
    assert not family & {os.path.realpath(p) for p in opened}, opened
    assert not _loose(*private.sqlite_family(db)[:3])


def test_status_reports_an_index_another_uid_could_replace() -> None:
    """A folder above the index that others can write lets them swap in their own. `seal_index`
    refuses there; the reader must not call the same scope clean."""
    base = Path(tempfile.mkdtemp())
    ir = base / "open" / "index" / "x"
    _ingest_dir(ir)
    private.seal_index(base / "open" / "index" / "x.db", ir, home=base)
    (base / "open").chmod(0o777)
    exposed = private.exposed_index(base / "open" / "index" / "x.db", ir)
    assert str(ir) in exposed, exposed


def test_dot_dot_after_a_link_is_the_kernels_not_the_spellings() -> None:
    """`a/L/../x.db` with `L -> b/c` is `b/x.db` to the kernel and to SQLite. Collapsing `..` by
    spelling sealed and judged `a/x.db` instead, and called the real, loose db clean."""
    base = Path(tempfile.mkdtemp())
    (base / "b" / "c").mkdir(parents=True)
    (base / "a").mkdir()
    (base / "a" / "L").symlink_to(base / "b" / "c")
    real, decoy = base / "b" / "x.db", base / "a" / "x.db"
    for f in (real, decoy):
        f.write_text("")
        f.chmod(0o644)
    db = base / "a" / "L" / ".." / "x.db"
    assert os.path.realpath(real) in private.exposed_index(db, None), (
        private.exposed_index(db, None))
    private.seal_index(db, None, home=base)
    assert _mode(real) == 0o600, "the db the kernel opens was not sealed"
    assert _mode(decoy) == 0o644, "a file of the same name beside the link was sealed instead"


def test_a_root_reached_through_dot_dot_after_a_link_is_sealed() -> None:
    base = Path(tempfile.mkdtemp())
    (base / "b" / "c").mkdir(parents=True)
    (base / "a").mkdir()
    (base / "a" / "L").symlink_to(base / "b" / "c")
    real = base / "b" / "idx"
    _ingest_dir(real)
    real.chmod(0o755)
    private.seal_index(base / "b" / "x.db", base / "a" / "L" / ".." / "idx", home=base)
    assert _mode(real) == 0o700 and not _loose(real / "v__n__0123abcd")


def test_a_file_removed_mid_check_is_not_exposed() -> None:
    """A compose in another process removes entries under a concurrent `status`. What vanished
    between a listing and its stat exposes nothing; calling it loose calls a sealed scope exposed,
    and one vanished file must not make a whole ingest directory unreadable."""
    base = Path(tempfile.mkdtemp())
    d = _ingest_dir(base / "idx")
    fd = os.open(base / "idx", os.O_RDONLY | os.O_DIRECTORY)
    try:
        assert private._loose_at(fd, "gone") is False
        real_listdir = os.listdir
        os.listdir = lambda p=".": [*real_listdir(p), "gone"] if not isinstance(p, str) else (
            real_listdir(p))
        try:
            held = private._held(fd, d.name)
        finally:
            os.listdir = real_listdir
        assert held is not None and [n for n, _ in held] == ["document.md"], held
    finally:
        os.close(fd)


def test_status_reports_a_loose_folder_compose_would_name() -> None:
    """Compose names a shaped folder holding stray files as unsealed; the reader must not call
    the same scope clean."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    d = _ingest_dir(ir)
    (d / "notes.txt").write_text("")
    ir.chmod(0o700)
    assert str(ir) in private.exposed_index(base / "x.db", ir)


def test_one_folder_in_two_spellings_is_one_holder() -> None:
    """APFS ignores case: `Holder/x.db` and `holder/idx` hold the same folder."""
    base = Path(tempfile.mkdtemp())
    holder = base / "holder"
    (holder / "idx").mkdir(parents=True)
    if not (base / "Holder").exists():
        return  # a case-sensitive volume: there is no variant to test
    holder.chmod(0o755)
    (base / "Holder" / "x.db").write_text("")
    out = private.exposed_index(base / "Holder" / "x.db", holder / "idx")
    folders = [p for p in out if Path(p).name.lower() == "holder"]
    assert len(folders) == 1, out


def test_the_folder_a_db_will_be_created_in_is_sealed_first() -> None:
    """Compose seals before SQLite creates the db, so on a scope's first compose the db does not
    exist yet. The folder it is about to be created in was checked, and is sealed."""
    home = Path(tempfile.mkdtemp())
    dbs = home / "dbs"
    dbs.mkdir()
    dbs.chmod(0o755)
    assert private.seal_index(dbs / "x.db", None, home=home) == []
    assert _mode(dbs) == 0o700, "the folder the db is about to be created in was left open"


def test_dot_dot_out_of_another_users_folder_is_checked() -> None:
    """In a sticky folder (`/tmp`, `/Users/Shared`) the owner of an entry may still move it, so
    `theirs/..` leads wherever they choose."""
    base = Path(tempfile.mkdtemp(dir="/tmp"))
    real_euid = os.geteuid
    os.geteuid = lambda: real_euid() + 1  # makes `base`, ours, read as another user's
    try:
        assert private.untrusted(base / "x").why, "a folder of another user's was looked into"
        assert private.untrusted(base / ".." / "x").why, "`..` out of it went unchecked"
    finally:
        os.geteuid = real_euid


def test_a_side_file_that_is_a_link_is_not_followed() -> None:
    """SQLite never makes `-wal` a link. One that is points somewhere this index does not own."""
    base = Path(tempfile.mkdtemp())
    victim = base / "victim.txt"
    victim.write_text("")
    victim.chmod(0o644)
    (base / "x.db").write_text("")
    (base / "x.db-wal").symlink_to(victim)
    private.seal_index(base / "x.db", None, home=base)
    assert _mode(victim) == 0o644, "a side-file link was followed"


def test_one_untrusted_spelling_seals_none_of_the_family() -> None:
    """`--db safe/x.db -> open/real.db` with `open` writable by others: whoever can write `open`
    decides what the db is, so its side files beside the link are not sealed either."""
    base = Path(tempfile.mkdtemp())
    (base / "open").mkdir()
    (base / "open" / "real.db").write_text("")
    (base / "safe").mkdir()
    (base / "safe" / "x.db").symlink_to(base / "open" / "real.db")
    wal = base / "safe" / "x.db-wal"
    wal.write_text("")
    wal.chmod(0o644)
    (base / "open").chmod(0o777)
    failed = private.seal_index(base / "safe" / "x.db", None, home=Path(tempfile.mkdtemp()))
    assert _mode(wal) == 0o644, "part of a family with an untrusted spelling was sealed"
    assert any("other users can write it" in line for line in failed), failed


def test_a_leading_tilde_is_not_expanded() -> None:
    """`~` is the shell's. A path that reaches the engine with one is a folder named `~`, as it is
    to `open` and to SQLite."""
    assert private.untrusted("~/x").path == Path(os.getcwd()) / "~" / "x"


def test_a_side_file_that_is_a_link_is_reported_and_holds_nothing_back() -> None:
    """A stray link at `x.db-wal` is not a spelling another uid controls; letting it block the db
    would keep the db readable for as long as the link stayed."""
    base = Path(tempfile.mkdtemp())
    victim = base / "victim.txt"
    victim.write_text("")
    victim.chmod(0o644)
    (base / "x.db").write_text("")
    (base / "x.db").chmod(0o644)
    (base / "x.db-wal").symlink_to(victim)
    failed = private.seal_index(base / "x.db", None, home=base)
    assert any("a side file that is a link" in line for line in failed), failed
    assert _mode(base / "x.db") == 0o600 and _mode(victim) == 0o644
    assert str(base / "x.db") in private.exposed_index(base / "x.db", None)


def test_a_vanished_ingest_directory_is_not_exposed() -> None:
    base = Path(tempfile.mkdtemp())
    _ingest_dir(base / "idx")
    fd = os.open(base / "idx", os.O_RDONLY | os.O_DIRECTORY)
    try:
        assert private._ingest_loose(fd, "v__gone__0123abcd") is False
    finally:
        os.close(fd)


def test_dot_dot_out_of_a_folder_others_can_write_is_allowed() -> None:
    """Writing into a folder does not move it: `..` out of it leads where its owner left it."""
    base = Path(tempfile.mkdtemp())
    (base / "open").mkdir()
    (base / "open").chmod(0o777)
    assert private.untrusted(base / "open" / "..").why is None


def test_a_missing_root_makes_no_holder() -> None:
    """No tree exists yet whose names its folder could list."""
    base = Path(tempfile.mkdtemp())
    db = base / "safe" / "x.db"
    db.parent.mkdir()
    db.write_text("")
    db.parent.chmod(0o700)
    (base / "loose").mkdir()
    (base / "loose").chmod(0o755)
    out = private.exposed_index(db, base / "loose" / "idx")
    assert os.path.realpath(base / "loose") not in out, out


def test_a_root_in_a_folder_this_call_seals_is_sealed_in_the_same_call() -> None:
    """The root's folder was group-writable until the holder step sealed it. Judged before that,
    the root read as untrusted and stayed loose until the next compose."""
    home = Path(tempfile.mkdtemp())
    hold = home / "index"
    ir = hold / "x"
    _ingest_dir(ir)
    ir.chmod(0o755)
    hold.chmod(0o775)
    failed = private.seal_index(hold / "x.db", ir, home=home)
    assert failed == [], failed
    assert _mode(hold) == 0o700 and _mode(ir) == 0o700


def test_a_database_linked_from_elsewhere_is_sealed_and_so_is_the_other_name() -> None:
    """Anyone who can reach a loose db can `ln` it into a folder of their own (macOS lets them).
    Refusing to seal a multiply-linked file kept the index readable through that name for good,
    and SQLite kept writing every new page into it."""
    home = Path(tempfile.mkdtemp())
    (home / "x.db").write_text("")
    (home / "x.db").chmod(0o644)
    theirs = Path(tempfile.mkdtemp()) / "kept.db"
    os.link(home / "x.db", theirs)
    for _ in range(2):
        assert private.seal_index(home / "x.db", None, home=home) == []
    assert _mode(home / "x.db") == 0o600 and _mode(theirs) == 0o600


def test_a_planted_link_only_ever_loses_bits() -> None:
    """The reverse case: while the db's folder was open, someone planted `x.db-journal` as a link
    to another file of this user's (the agent's 0640 snapshot). Sealing takes its group and other
    bits — it can never add any — and the snapshot is rewritten at 0640 on its next publish."""
    home = Path(tempfile.mkdtemp())
    hold = home / "scripta"
    hold.mkdir()
    (hold / "x.db").write_text("")
    snapshot = Path(tempfile.mkdtemp()) / "atlas.snapshot.db"
    snapshot.write_text("")
    snapshot.chmod(0o640)
    os.link(snapshot, hold / "x.db-journal")
    hold.chmod(0o777)
    private.seal_index(hold / "x.db", None, home=home)
    assert _mode(snapshot) & ~0o640 == 0, "a planted link gained bits"
    assert _mode(hold) == 0o700 and _mode(hold / "x.db") == 0o600


def test_a_holder_beneath_an_open_holder_is_sealed_in_the_same_call() -> None:
    home = Path(tempfile.mkdtemp())
    scripta = home / "scripta"
    (scripta / "sub").mkdir(parents=True)
    _ingest_dir(scripta / "idx")
    (scripta / "sub").chmod(0o755)
    (scripta / "idx").chmod(0o700)
    scripta.chmod(0o777)
    private.seal_index(scripta / "sub" / "x.db", scripta / "idx", home=home)
    assert _mode(scripta) == 0o700 and _mode(scripta / "sub") == 0o700


def test_a_linked_db_into_an_open_folder_converges() -> None:
    """`y.db -> real/y.db` with `real` writable by others, all under the engine's folder: every
    run reported it and none sealed `real`."""
    home = Path(tempfile.mkdtemp())
    real = home / "real"
    real.mkdir()
    (real / "y.db").write_text("")
    (real / "y.db").chmod(0o644)
    (home / "y.db").symlink_to(real / "y.db")
    real.chmod(0o777)
    private.seal_index(home / "y.db", None, home=home)
    assert private.seal_index(home / "y.db", None, home=home) == []
    assert _mode(real) == 0o700 and _mode(real / "y.db") == 0o600


def test_a_linked_db_whose_target_is_not_created_yet_has_a_holder() -> None:
    home = Path(tempfile.mkdtemp())
    target = home / "dbs"
    target.mkdir()
    target.chmod(0o755)
    (home / "x.db").symlink_to(target / "x.db")
    assert private.seal_index(home / "x.db", None, home=home) == []
    assert _mode(target) == 0o700, "the folder SQLite is about to create the db in was left open"


def test_a_steered_index_root_cannot_hide_a_holder() -> None:
    """`--index-root open/idx` with `open` writable by others and `idx` a link to the db's folder:
    the root's identity came from that link, so the db's folder was dropped from the holders —
    never sealed, never reported."""
    home = Path(tempfile.mkdtemp())
    (home / "x.db").write_text("")
    home.chmod(0o755)
    w = Path(tempfile.mkdtemp())
    (w / "idx").symlink_to(home)
    w.chmod(0o777)
    private.seal_index(home / "x.db", w / "idx", home=home)
    assert _mode(home) == 0o700, "the db's folder was hidden behind a steered root"


def test_an_entry_named_like_the_db_is_the_engines_only_if_it_is_the_db() -> None:
    """A folder planted as `x.db-journal` while the root was open is not the db's side file."""
    home = Path(tempfile.mkdtemp())
    ir = home / "idx"
    _ingest_dir(ir)
    (ir / "x.db").write_text("")
    (ir / "x.db-journal").mkdir()
    ir.chmod(0o755)
    failed = private.seal_index(ir / "x.db", ir, home=home)
    assert _mode(ir) == 0o755, "a root holding a stranger's entry was sealed as the engine's own"
    assert any("did not write" in line for line in failed), failed


def test_a_short_write_never_replaces_an_ingest_file() -> None:
    base = Path(tempfile.mkdtemp())
    d = _ingest_dir(base / "idx")
    (d / "document.md").write_text("x" * 5000)
    os.link(d / "document.md", base / "other.md")
    real_write = os.write
    os.write = lambda fd, data: real_write(fd, bytes(data)[: max(1, len(data) // 2)])
    try:
        private.seal_index(base / "x.db", base / "idx", home=base)
    finally:
        os.write = real_write
    assert (d / "document.md").read_text() == "x" * 5000


def test_a_symlinked_publish_folder_is_refused_as_one() -> None:
    from substrate import agent
    base = Path(tempfile.mkdtemp())
    (base / "pub").symlink_to(base / "missing")
    try:
        agent._trusted_dir(base / "pub")
    except agent.AgentError as e:
        assert "must be a real directory" in str(e), str(e)
    else:
        raise AssertionError("a dangling link was accepted as a publish folder")


def test_a_hidden_hard_link_in_an_ingest_directory_is_not_chmodded_through() -> None:
    """`.DS_Store` planted as a hard link to another file of this user's, while the directory was
    open: the directory still counts as an ingest directory, so its name is relinked, not
    chmodded through."""
    base = Path(tempfile.mkdtemp())
    d = _ingest_dir(base / "idx")
    outside = Path(tempfile.mkdtemp()) / "theirs.txt"
    outside.write_text("")
    outside.chmod(0o644)
    os.link(outside, d / ".DS_Store")
    private.seal_index(base / "x.db", base / "idx", home=base)
    assert _mode(outside) == 0o644, "a hidden hard link was chmodded through"
    assert os.stat(d / ".DS_Store").st_nlink == 1


def test_a_closed_folder_holding_a_link_at_an_ingest_name_is_reported() -> None:
    """compose writes `document.md` by name, through whatever is there. A link planted there while
    the folder was open takes every note's text, and the folder's own mode says nothing about it."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    _ingest_dir(ir)
    d = ir / "v__planted__89abcdef"
    d.mkdir()
    (d / "document.md").symlink_to(Path(tempfile.mkdtemp()) / "theirs.txt")
    d.chmod(0o700)
    failed = private.seal_index(base / "x.db", ir, home=base)
    assert any("v__planted__89abcdef" in line and "document.md" in line
               and "not a closed file" in line for line in failed), failed
    assert str(ir) in private.exposed_index(base / "x.db", ir)


def test_status_agrees_with_compose_on_a_family_name_that_is_not_a_file() -> None:
    home = Path(tempfile.mkdtemp())
    (home / "x.db").write_text("")
    (home / "x.db-wal").mkdir(mode=0o700)
    failed = private.seal_index(home / "x.db", None, home=home)
    assert any("x.db-wal" in line for line in failed), failed
    assert str(home / "x.db") in private.exposed_index(home / "x.db", None)


def test_a_link_named_like_an_ingest_directory_is_reported_in_a_closed_root() -> None:
    """While the root was open, someone made `<vault>__<stem>__<hash>` a link to a folder of their
    own. compose's `mkdir(exist_ok=True)` accepts it and writes the note into their folder; once the
    root is closed nothing else would say so."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    _ingest_dir(ir)
    (ir / "v__note__89abcdef").symlink_to(Path(tempfile.mkdtemp()))
    ir.chmod(0o700)
    failed = private.seal_index(base / "x.db", ir, home=base)
    assert any("v__note__89abcdef" in line for line in failed), failed
    assert str(ir) in private.exposed_index(base / "x.db", ir)


def test_a_hard_link_at_an_ingest_name_in_a_shaped_folder_is_reported() -> None:
    """`document.md` planted as a hard link to a closed file of the operator's, with a second name
    so the folder is not an ingest directory: every mode is closed, and compose would overwrite the
    operator's file with a note."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    _ingest_dir(ir)
    d = ir / "v__other__89abcdef"
    d.mkdir()
    victim = Path(tempfile.mkdtemp()) / "secret.txt"
    victim.write_text("")
    victim.chmod(0o600)
    os.link(victim, d / "document.md")
    (d / "notes.txt").write_text("")
    (d / "notes.txt").chmod(0o600)
    d.chmod(0o700)
    ir.chmod(0o700)
    failed = private.seal_index(base / "x.db", ir, home=base)
    assert any("v__other__89abcdef" in line and "document.md" in line for line in failed), failed
    assert str(ir) in private.exposed_index(base / "x.db", ir)


def test_a_holder_pass_that_settles_late_is_not_called_unsettled() -> None:
    """The holder loop is capped. Reaching the cap is not by itself proof the folders kept
    changing: only a listing that still has something new is."""
    base = Path(tempfile.mkdtemp())
    folders = [base / f"h{i}" for i in range(private._HOLDER_PASSES)]
    for f in folders:
        f.mkdir()
    calls = {"n": 0}
    real = private._holders

    def growing(db, index_root, *, settles=True):
        calls["n"] += 1
        upto = min(calls["n"], len(folders)) if settles else calls["n"]
        return [(f, os.lstat(f)) for f in folders[:upto]] + (
            [] if settles else [(base / f"extra{calls['n']}", os.lstat(base))])

    for settles in (True, False):
        calls["n"] = 0
        private._holders = lambda db, ir, s=settles: growing(db, ir, settles=s)
        try:
            failed = private.seal_index(base / "x.db", None, home=Path(tempfile.mkdtemp()))
        finally:
            private._holders = real
        kept = any("kept changing" in line for line in failed)
        assert kept is (not settles), (settles, failed)


def test_planted_names_in_another_case_are_found() -> None:
    """On a volume that ignores case, compose's `document.md` opens `Document.md`, and its
    `v__note__89abcdef` opens `v__note__89ABCDEF`."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    _ingest_dir(ir)
    d = ir / "v__other__89abcdef"
    d.mkdir()
    (d / "Document.md").symlink_to(Path(tempfile.mkdtemp()) / "theirs.txt")
    d.chmod(0o700)
    (ir / "v__note__89ABCDEF").symlink_to(Path(tempfile.mkdtemp()))
    ir.chmod(0o700)
    failed = private.seal_index(base / "x.db", ir, home=base)
    if (d / "document.md").is_symlink():  # the volume ignores case: compose opens both
        assert any("v__other__89abcdef" in line for line in failed), failed
        assert any("v__note__89ABCDEF" in line for line in failed), failed
    else:  # it does not: compose opens neither, and neither is reported as planted
        assert not any("v__note__89ABCDEF" in line and "named like" in line for line in failed)


def test_a_folder_compose_opens_only_through_case_is_judged() -> None:
    """`v__n__89ABCDEF` of this user's is where compose writes `v__n__89abcdef` on a volume that
    ignores case. It was never looked at: not exactly the shape, and not a link or a stranger's."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    _ingest_dir(ir)
    d = ir / "v__n__89ABCDEF"
    d.mkdir()
    (d / "document.md").symlink_to(Path(tempfile.mkdtemp()) / "theirs.txt")
    ir.chmod(0o700)
    if not (ir / "v__n__89abcdef").exists():
        return  # a case-sensitive volume: compose would not open it
    failed = private.seal_index(base / "x.db", ir, home=base)
    assert any("v__n__89ABCDEF" in line for line in failed), failed
    assert str(ir) in private.exposed_index(base / "x.db", ir)


def test_a_planted_name_starting_with_a_dot_is_reported() -> None:
    """A vault named `.notes` makes compose's names `.notes__<stem>__<hash>`."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    _ingest_dir(ir)
    (ir / ".notes__n__0123abce").symlink_to(Path(tempfile.mkdtemp()))
    ir.chmod(0o700)
    failed = private.seal_index(base / "x.db", ir, home=base)
    assert any(".notes__n__0123abce" in line for line in failed), failed


def test_a_file_of_the_operators_named_like_an_ingest_directory_is_not_planted() -> None:
    """compose's `mkdir` fails on a file; it cannot write a note through one."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    _ingest_dir(ir)
    (ir / "report__draft__20241105").write_text("")
    (ir / "report__draft__20241105").chmod(0o600)
    ir.chmod(0o700)
    failed = private.seal_index(base / "x.db", ir, home=base)
    assert not any("named like an ingest directory" in line for line in failed), failed


def test_a_relink_that_comes_up_short_keeps_the_original() -> None:
    base = Path(tempfile.mkdtemp())
    d = _ingest_dir(base / "idx")
    (d / "document.md").write_text("y" * 5000)
    os.link(d / "document.md", base / "other.md")
    real_read = os.read
    calls = {"n": 0}

    def short(fd, n):
        calls["n"] += 1
        return real_read(fd, 100) if calls["n"] == 1 else b""

    os.read = short
    try:
        failed = private.seal_index(base / "x.db", base / "idx", home=base)
    finally:
        os.read = real_read
    assert (d / "document.md").read_text() == "y" * 5000
    assert any("changed size during the copy" in line for line in failed), failed


def test_status_reports_a_hard_linked_ingest_file_seal_would_relink() -> None:
    """Between composes, status must not vouch for what the next seal would act on."""
    base = Path(tempfile.mkdtemp())
    d = _ingest_dir(base / "idx")
    private.seal_index(base / "x.db", base / "idx", home=base)
    os.link(d / "document.md", base / "other.md")
    assert str(base / "idx") in private.exposed_index(base / "x.db", base / "idx")


def test_a_folder_compose_opens_only_through_case_is_never_an_ingest_directory() -> None:
    """Only compose's own spelling is the engine's: `v__n__89ABCDEF` is judged as shaped and never
    sealed as an ingest directory. Clean, it is not an exposure and seal and status both say
    nothing; with a loose file at an ingest name, both report it and nothing is changed."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    _ingest_dir(ir)
    d = ir / "v__n__89ABCDEF"
    d.mkdir()
    (d / "document.md").write_text("")
    (d / "document.md").chmod(0o600)
    d.chmod(0o700)
    if not (ir / "v__n__89abcdef").exists():
        return  # a case-sensitive volume: compose would not open it
    private.seal_index(base / "x.db", ir, home=base)
    ir.chmod(0o700)  # it holds a folder that is not the engine's, so the root is the operator's
    fd = os.open(ir, os.O_RDONLY | os.O_DIRECTORY)
    try:
        listing = private._classify(fd, private.Family(set(), set()))
    finally:
        os.close(fd)
    assert "v__n__89ABCDEF" in listing.shaped and "v__n__89ABCDEF" not in listing.ingest
    assert listing.own is False
    failed = private.seal_index(base / "x.db", ir, home=base)
    assert not any("v__n__89ABCDEF" in line for line in failed), failed
    assert private.exposed_index(base / "x.db", ir) == [], "seal and status must agree"
    (d / "document.md").chmod(0o644)
    failed = private.seal_index(base / "x.db", ir, home=base)
    assert any("v__n__89ABCDEF" in line and "as v__n__89abcdef" in line and "rename it" in line
               for line in failed), failed
    assert str(ir) in private.exposed_index(base / "x.db", ir)
    assert _mode(d / "document.md") == 0o644, "sealed as if it were an ingest directory"


def test_a_case_lookup_that_fails_is_reported_not_trusted() -> None:
    """Whether compose would open `v__n__89ABCDEF` is asked of the volume; when the asking fails for
    any reason but absence, the link is reported rather than assumed harmless."""
    base = Path(tempfile.mkdtemp())
    ir = base / "idx"
    _ingest_dir(ir)
    (ir / "v__n__89ABCDEF").symlink_to(Path(tempfile.mkdtemp()))
    ir.chmod(0o700)
    real = os.stat

    def refuse(path, *a, **kw):
        if os.fspath(path) == "v__n__89abcdef":
            raise PermissionError(13, "Permission denied")
        return real(path, *a, **kw)

    os.stat = refuse
    try:
        failed = private.seal_index(base / "x.db", ir, home=base)
    finally:
        os.stat = real
    assert any("v__n__89ABCDEF" in line for line in failed), failed


# ---------------------------------------------------------------- the other CLI writers

def test_refresh_record_creates_a_private_registry_dir() -> None:
    reg = Path(tempfile.mkdtemp()) / "fresh" / "scopes.toml"
    with _umask(0o022), contextlib.redirect_stdout(io.StringIO()):
        rc = cli.main(["refresh-record", "--scope", "demo", "--outcome", "unchanged",
                       "--registry", str(reg)])
    assert rc == 0
    loose = _loose(reg.parent)
    assert not loose, f"the registry directory is readable by other users: {loose}"


def test_ingest_out_is_private() -> None:
    """`ingest --out` is the app's staging tree: each run holds a document's full text."""
    out = Path(tempfile.mkdtemp()) / "staging" / "run"
    note = next(_DEMO_VAULT.rglob("*.md"))
    with _umask(0o022), contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(io.StringIO()):
        rc = cli.main(["ingest", str(note), "--out", str(out)])
    assert rc == 0, rc
    assert out.is_dir() and any(out.iterdir()), "the ingest must have written its artefacts"
    loose = _loose(out.parent)
    assert not loose, f"another uid can read the ingest: {loose[:5]}"


def test_cli_main_puts_the_umask_back() -> None:
    """The umask is process-wide. `main` driven in-process must not leave it changed."""
    reg = Path(tempfile.mkdtemp()) / "scopes.toml"
    with _umask(0o022), contextlib.redirect_stdout(io.StringIO()):
        cli.main(["refresh-record", "--scope", "demo", "--outcome", "unchanged",
                  "--registry", str(reg)])
        assert _current_umask() == 0o022


# ---------------------------------------------------------------- the server

def test_server_runs_under_the_private_umask_and_names_a_loose_scope() -> None:
    root = Path(tempfile.mkdtemp())
    rc, err, db, ir, reg = _compose(root)
    assert rc == 0, (rc, err)
    _loosen(db)

    seen: list[int] = []
    original = server.serve
    server.serve = lambda cfg: seen.append(_current_umask()) or 0
    err = io.StringIO()
    try:
        with _umask(0o022), contextlib.redirect_stderr(err):
            assert server.main(["--lexical-only", "--registry", str(reg)]) == 0
            assert _current_umask() == 0o022, "main must put the umask back"
    finally:
        server.serve = original

    assert seen == [0o077], f"the server served under umask {[oct(m) for m in seen]}"
    assert "'demo'" in err.getvalue() and str(db) in err.getvalue(), (
        f"startup must name the loose scope and path; stderr was {err.getvalue()!r}")
    assert _loose(db), "the reader warns; it must not repair"


def test_server_is_silent_about_a_sealed_scope() -> None:
    root = Path(tempfile.mkdtemp())
    rc, err, _, _, reg = _compose(root)
    assert rc == 0, (rc, err)
    original = server.serve
    server.serve = lambda cfg: 0
    err = io.StringIO()
    try:
        with contextlib.redirect_stderr(err):
            server.main(["--lexical-only", "--registry", str(reg)])
    finally:
        server.serve = original
    assert "readable by other users" not in err.getvalue(), err.getvalue()


def test_status_lists_exposed_paths() -> None:
    root = Path(tempfile.mkdtemp())
    rc, err, db, ir, reg = _compose(root)
    assert rc == 0, (rc, err)
    entry = scopes.resolve("demo", reg)

    def exposed() -> list[str]:
        with IndexStore(db) as s:
            return introspect.status_payload(s, entry, stack=stack.Stack(),
                                             registry=str(reg))["exposed"]

    assert exposed() == [], "a freshly composed scope must report nothing exposed"
    (ir / next(p.name for p in ir.iterdir())).chmod(0o755)
    assert exposed() == [str(entry.index_root)], (
        "a single loose directory inside the tree must surface as its tree")


# ---------------------------------------------------------------- the vector cache

def test_vector_cache_seals_a_cache_created_loose() -> None:
    """The `expansions` table is HyDE text from the operator's queries."""
    path = Path(tempfile.mkdtemp()) / "vector-cache.db"
    with _umask(0o022):
        VectorCache(path).db.close()
        _loosen(*private.sqlite_family(path))
        assert _loose(path), "the fixture must start loose"
        VectorCache(path).db.close()
    loose = _loose(*private.sqlite_family(path))
    assert not loose, f"the cache is readable by other users: {loose}"


# ---------------------------------------------------------------- seal / exposed themselves

def test_seal_only_strips_group_and_other_bits() -> None:
    root = Path(tempfile.mkdtemp())
    script, note = root / "run.sh", root / "note.md"
    script.write_text("")
    note.write_text("")
    script.chmod(0o755)
    note.chmod(0o640)
    assert private.seal([root]) == []
    assert stat.S_IMODE(script.stat().st_mode) == 0o700, "the owner's own bits are not touched"
    assert stat.S_IMODE(note.stat().st_mode) == 0o600


def test_seal_and_exposed_never_follow_a_symlink() -> None:
    """An index tree holding a link to something else must not chmod, or report, the target."""
    base = Path(tempfile.mkdtemp())
    outside = base / "outside.md"
    outside.write_text("")
    outside.chmod(0o644)
    tree = base / "index"
    (tree / "sub").mkdir(parents=True)
    tree.chmod(0o700)
    (tree / "sub").chmod(0o700)
    (tree / "link").symlink_to(outside)
    (tree / "sub" / "dirlink").symlink_to(base)

    assert private.exposed([tree]) == []
    assert private.seal([tree]) == []
    assert stat.S_IMODE(outside.stat().st_mode) == 0o644, "the link's target is not the tree's"
    assert private.exposed([base / "link-root"]) == [], "a missing root is not exposed"


def test_a_symlinked_root_is_its_target() -> None:
    """compose writes through a symlinked `--index-root`, so the target IS the index. Skipping it
    reported a loose index as clean."""
    base = Path(tempfile.mkdtemp())
    real = base / "real"
    real.mkdir()
    (real / "x.md").write_text("")
    (real / "x.md").chmod(0o644)
    real.chmod(0o755)
    link = base / "idx"
    link.symlink_to(real)

    assert private.exposed([link]) == [str(link)]
    assert private.seal([link]) == []
    assert not _loose(real), _loose(real)
    assert private.exposed([link]) == []


def test_an_unreadable_directory_is_reported_not_raised() -> None:
    """These walks run at server startup, in every `status`, and in compose. An entry that cannot
    be read must cost a warning, and must not read as safe."""
    if os.geteuid() == 0:
        return  # root reads anything
    tree = Path(tempfile.mkdtemp())
    shut = tree / "shut"
    (shut / "inner").mkdir(parents=True)
    shut.chmod(0o600)  # owner may not traverse; nothing inside can be checked
    try:
        assert private.exposed([tree]) == [str(tree)], "an unverifiable tree is not a safe one"
        failed = private.seal([tree])
        assert any("shut" in line for line in failed), failed
    finally:
        shut.chmod(0o700)


def test_a_directory_removed_mid_walk_is_not_exposed() -> None:
    """A compose rewriting the tree under a concurrent `status` removes entries mid-walk. A path
    that vanished between its parent's listing and the walk reaching it exposes nothing, and
    reporting it would call a sealed scope exposed."""
    # Real path: the walk runs on the resolved root, and macOS's temp dir sits behind /var -> /private.
    tree = Path(os.path.realpath(tempfile.mkdtemp()))
    gone = tree / "gone"
    gone.mkdir(mode=0o700)
    original = os.scandir
    fired: list[Path] = []

    def vanishing(path=".", *a, **kw):
        if Path(path) == gone:
            fired.append(gone)
            raise FileNotFoundError(2, "No such file or directory", str(path))
        return original(path, *a, **kw)

    os.scandir = vanishing
    try:
        assert private.exposed([tree]) == []
        assert fired, "the fixture must actually remove the directory under the walk"
        assert private.seal([tree]) == []
    finally:
        os.scandir = original


def test_a_file_removed_before_its_chmod_is_not_a_failure() -> None:
    tree = Path(tempfile.mkdtemp())
    (tree / "f").write_text("")
    (tree / "f").chmod(0o644)
    original = os.chmod

    def vanished(path, mode, **kw):
        raise FileNotFoundError(2, "No such file or directory", str(path))

    os.chmod = vanished
    try:
        assert private.seal([tree]) == []
    finally:
        os.chmod = original


def test_seal_reports_what_it_could_not_tighten() -> None:
    if os.geteuid() == 0:
        return  # root can chmod anything
    tree = Path(tempfile.mkdtemp())
    victim = tree / "f"
    victim.write_text("")
    victim.chmod(0o644)
    original = os.chmod

    def refuse(path, mode, **kw):
        raise PermissionError(1, "Operation not permitted")

    os.chmod = refuse
    try:
        failed = private.seal([tree])
    finally:
        os.chmod = original
    assert failed and any(str(victim) in line for line in failed), failed


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print(f"ok  {name}")
