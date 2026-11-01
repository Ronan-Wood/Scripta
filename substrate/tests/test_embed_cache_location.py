"""`embed`'s vector cache must not land in the working directory.

Scripta's bundled shims `cd` to the engine root — `Scripta.app/Contents/Resources/substrate-engine`
— before exec'ing, and the app runs `embed --db <scope.db>` with no `--cache` after every compose:
each Library action and every background refresh pass. `--cache` defaulted to the RELATIVE
`out/vector-cache.db`, so that embed wrote `substrate-engine/out/vector-cache.db` inside the signed
bundle. Measured 2026-11-01 on a Distribution build: `codesign --verify --deep --strict` then failed
with a file added; where /Applications is not user-writable the embed failed instead and the scope
was left without vectors; and the changed tree can stop a Sparkle delta applying.

The default is now `stack.DEFAULT_CACHE`, the per-user path the engine already defines. These tests stand in for the shim: cwd is a scratch "engine root", and the constant is
pointed at a scratch home so nothing touches the real `~/.substrate`. On the old default the first
test finds `out/` under the engine root and the second raises PermissionError — the two ways the
bug showed up.

Runnable with plain `python tests/test_embed_cache_location.py`; discovered by pytest if added.
"""

from __future__ import annotations

import contextlib
import io
import os
import sqlite3
import stat
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import cli, stack  # noqa: E402
from substrate.embed import engine  # noqa: E402
from substrate.models import Chunk, Document  # noqa: E402
from substrate.store.index_store import IndexStore  # noqa: E402


def _index(where: Path) -> str:
    db = str(where / "scope.db")
    with IndexStore(db) as s:
        text = "replication lag body"
        doc = Document(doc_id="d0", source_path="/d0.md", source_sha256="s" * 8, source_pages=1,
                       document_class="reference-frozen", title="d0", status="active")
        ch = Chunk(chunk_id="d0#c0", doc_id="d0", kind="passage", text=text, path=["Root", "d0"],
                   level=2, n_chars=len(text), document_class="reference-frozen")
        s.upsert(doc, [ch], markdown_path="/d0.md", markdown_mtime=0.0, markdown_sha256="m" * 8)
    return db


@contextlib.contextmanager
def _as_the_bundled_shim(engine_root: Path, home: Path):
    """cwd = the engine root, an embedder that answers without a daemon, and the per-user cache
    redirected into `home`. Every one of these is restored, so a failure cannot leak into the next
    test."""
    saved = (os.getcwd(), stack.DEFAULT_CACHE,
             engine.OllamaEmbedder.available, engine.OllamaEmbedder.embed_documents)
    os.chdir(engine_root)
    stack.DEFAULT_CACHE = home / ".substrate" / "vector-cache.db"
    engine.OllamaEmbedder.available = lambda self: True
    engine.OllamaEmbedder.embed_documents = lambda self, texts: [[0.5, 0.25] for _ in texts]
    try:
        with contextlib.redirect_stdout(io.StringIO()):
            yield stack.DEFAULT_CACHE
    finally:
        os.chdir(saved[0])
        (stack.DEFAULT_CACHE, engine.OllamaEmbedder.available,
         engine.OllamaEmbedder.embed_documents) = saved[1:]


def _cached_vectors(path: Path) -> int:
    con = sqlite3.connect(path)
    try:
        return con.execute("SELECT COUNT(*) FROM vectors").fetchone()[0]
    finally:
        con.close()


def test_embed_without_cache_writes_nothing_under_the_working_directory() -> None:
    tmp = Path(tempfile.mkdtemp())
    engine_root, home = tmp / "substrate-engine", tmp / "home"
    engine_root.mkdir()
    db = _index(tmp)

    with _as_the_bundled_shim(engine_root, home) as cache:
        rc = cli.main(["embed", "--db", db])

    assert rc == 0, rc
    assert list(engine_root.iterdir()) == [], (
        f"embed wrote into the engine root: {sorted(p.name for p in engine_root.rglob('*'))}")
    # The vectors went SOMEWHERE durable — a fix that dropped the cache would also leave the root
    # empty, and would re-embed the whole corpus on every compose.
    assert cache.exists(), "the default cache is not stack.DEFAULT_CACHE"
    assert _cached_vectors(cache) == 1


def test_embed_without_cache_succeeds_when_the_engine_root_is_read_only() -> None:
    """/Applications is not user-writable for a standard user, so neither is the bundle. The old
    default raised PermissionError there, and the scope was served with no vectors at all.

    Skipped as root, which ignores the mode bits: there it would pass on the old default too."""
    if os.geteuid() == 0:
        return
    tmp = Path(tempfile.mkdtemp())
    engine_root, home = tmp / "substrate-engine", tmp / "home"
    engine_root.mkdir()
    db = _index(tmp)
    engine_root.chmod(stat.S_IRUSR | stat.S_IXUSR)
    try:
        with _as_the_bundled_shim(engine_root, home) as cache:
            rc = cli.main(["embed", "--db", db])
    finally:
        engine_root.chmod(stat.S_IRWXU)

    assert rc == 0, rc
    assert _cached_vectors(cache) == 1


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
