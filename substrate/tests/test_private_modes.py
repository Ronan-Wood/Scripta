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


def _compose(root: Path) -> tuple[int, str, Path, Path, Path]:
    db, ir, reg = root / "out" / "demo.db", root / "out" / "demo-index", root / "scopes.toml"
    err = io.StringIO()
    with _umask(0o022), contextlib.redirect_stdout(io.StringIO()), \
            contextlib.redirect_stderr(err):
        rc = cli.main(["compose", str(_DEMO_VAULT), "--db", str(db), "--index-root", str(ir),
                       "--registry", str(reg)])
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
    loose = _loose(*private.index_paths(db, ir), db.parent)
    assert not loose, f"another uid can read the composed index: {loose[:5]}"


def test_compose_seals_an_index_built_before_the_umask() -> None:
    """SQLite reopens an existing database at its old mode, and compose overwrites ingest files in
    place. So an index first built at 0644 stays 0644 under any umask unless compose seals it."""
    root = Path(tempfile.mkdtemp())
    rc, err, db, ir, _ = _compose(root)
    assert rc == 0, (rc, err)
    _loosen(*private.index_paths(db, ir))
    assert _loose(db, ir), "the fixture must start loose"

    rc, err, db, ir, _ = _compose(root)
    assert rc == 0, (rc, err)
    loose = _loose(*private.index_paths(db, ir))
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
    _loosen(*private.index_paths(db, ir))
    (root / "demo-vault" / "no-status.md").write_text("# No status\n\nA note with no spine.\n")
    assert compose() == 3, "the fixture must make compose refuse"
    loose = _loose(*private.index_paths(db, ir))
    assert not loose, f"a refused compose left the index readable: {loose[:5]}"


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
