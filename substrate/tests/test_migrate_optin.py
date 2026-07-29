"""A command that only reads must not migrate, and migration must be ASKED for.

Migration is drop-and-rebuild on a `user_version` mismatch, so merely opening an index destroys
it. SIX call sites opened `out/substrate.db` — the eval fixture, six schema versions behind — with
the default `migrate=True`, which made `substrate eval` and `substrate embed --db
out/substrate.db` each destroy the most protected artifact in the project on their first
invocation. `refuse_if_rebuilt` ran AFTER the open, so it could report the destruction and never
prevent it.

Six, not the five originally enumerated. The sixth is `tools/embedder-sweep.sh`, which reads one
integer out of the fixture from inside a `python -c` heredoc — invisible to a `--include="*.py"`
grep, and wrapped in `2>/dev/null`, so it destroyed the fixture in silence one line after `embed`
had correctly refused to. Counting call sites by grepping one language is the same class of
instrument error as measuring vault migration by filename.

SEVEN production sites migrate in total; the seventh is `compose`, which is not in that list only
because its `--db` defaults elsewhere. It still migrates unflagged, deliberately — see
`test_compose_migrates_and_repopulates_in_the_same_run` for the property that earns the exemption
and now holds it.

**Every assertion here is about the DATA, not the exit code.** A test that only checked for a
non-zero exit would pass against a version that dropped the index and *then* refused, which is
precisely the bug: the old code did return non-zero. `_chunks` is read through a separate
connection after the command, so what is asserted is that the rows are still there.

`test_migrate_flag_actually_rebuilds` is what stops this suite being tautological. A `--migrate`
that refused everything would satisfy every other test in this file while removing the one path
that is allowed to rebuild — the same defect as the A17 fixture in PRINCIPLES.md that passed with
the fix and without it.

Runnable with plain `python tests/test_migrate_optin.py`; discovered by pytest if added.
"""

from __future__ import annotations

import contextlib
import io
import json
import sqlite3
import sys
import urllib.parse
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import cli  # noqa: E402
from substrate.eval.runner import run as eval_run  # noqa: E402
from substrate.models import Chunk, Document  # noqa: E402
from substrate.store import schema  # noqa: E402
from substrate.store.index_store import IndexStore, SchemaMismatch  # noqa: E402

# One version behind whatever ships. Derived, not hardcoded: a literal would silently become a
# no-op the day SCHEMA_VERSION passed it, and the test would keep passing against an index that
# needed no migration at all.
_REPO = Path(__file__).resolve().parent.parent
_STALE = schema.SCHEMA_VERSION - 1


def _stale_index(n: int = 3) -> str:
    """An index holding `n` documents, stamped with an older schema version.

    The rows are real — written through the current schema, then the version stamp is moved
    backwards. That is the state on disk that matters: content a migration would destroy.
    """
    db = str(Path(tempfile.mkdtemp()) / "index.db")
    with IndexStore(db) as s:
        for i in range(n):
            doc_id = f"d{i}"
            text = f"replication lag body number {i}"
            doc = Document(doc_id=doc_id, source_path=f"/{doc_id}.md", source_sha256="s" * 8,
                           source_pages=1, document_class="reference-frozen", title=doc_id,
                           status="active")
            ch = Chunk(chunk_id=f"{doc_id}#c0", doc_id=doc_id, kind="passage", text=text,
                       path=["Root", doc_id], level=2, n_chars=len(text),
                       document_class="reference-frozen")
            s.upsert(doc, [ch], markdown_path=f"/{doc_id}.md", markdown_mtime=0.0,
                     markdown_sha256="m" * 8)
    con = sqlite3.connect(db)
    con.execute(f"PRAGMA user_version={_STALE}")
    con.commit()
    con.close()
    return db


def _chunks(db: str) -> int:
    """Row count read OUT OF BAND — a fresh connection, no engine code, no migration.

    Reading this through `IndexStore` would be the same instrument as the thing under test: a
    migrating open would drop the rows and then report the count of what it had just created.
    """
    con = sqlite3.connect("file:" + urllib.parse.quote(db) + "?mode=ro", uri=True)
    try:
        return con.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
    finally:
        con.close()


def _version(db: str) -> int:
    con = sqlite3.connect("file:" + urllib.parse.quote(db) + "?mode=ro", uri=True)
    try:
        return con.execute("PRAGMA user_version").fetchone()[0]
    finally:
        con.close()


# ---------------------------------------------------------------- the store itself

def test_read_open_refuses_and_keeps_the_rows() -> None:
    db = _stale_index()
    try:
        IndexStore(db, migrate=False)
    except SchemaMismatch as e:
        assert e.found == _STALE, e.found
        assert e.expected == schema.SCHEMA_VERSION, e.expected
    else:
        raise AssertionError("a stale index must refuse a non-migrating open")
    assert _chunks(db) == 3, "the refusal must not have dropped anything"
    assert _version(db) == _STALE, "and must not have restamped the version"


def test_read_open_does_not_create_the_file() -> None:
    """A read must not materialise what it was asked to read.

    `schema.connect` is a plain `sqlite3.connect`, so it made the file before any version could be
    read: a typo'd `--db` left an empty database behind and refused with "has no schema — it was
    never composed", which describes a real-but-uncomposed index. The natural next step from that
    message is `index --migrate --db <typo>`, which builds a genuine index at the wrong path.
    """
    missing = str(Path(tempfile.mkdtemp()) / "typo.db")
    try:
        IndexStore(missing, migrate=False)
    except SchemaMismatch as e:
        assert e.found == -1, f"absence must be distinguishable from an unstamped file: {e.found}"
    else:
        raise AssertionError("a read open of a missing database must refuse")
    assert not Path(missing).exists(), "the refused read created the file anyway"


def test_migrating_open_does_destroy_it() -> None:
    """The control. This is what every read path used to do, stated as an expectation so the
    danger is legible rather than implied — and so a future change that made migration lossless
    would surface here instead of quietly invalidating the rest of this file."""
    db = _stale_index()
    with IndexStore(db, migrate=True) as s:
        assert s.rebuilt is True
    assert _chunks(db) == 0, "migration is drop-and-rebuild; this is why it must be opt-in"


# ---------------------------------------------------------------- the read commands

def test_eval_runner_refuses_without_dropping() -> None:
    db = _stale_index()
    gold = Path(tempfile.mkdtemp()) / "gold.json"
    gold.write_text('{"cases": []}', encoding="utf-8")
    try:
        eval_run(db, gold)
    except SchemaMismatch:
        pass
    else:
        raise AssertionError("eval must refuse a version-mismatched index")
    assert _chunks(db) == 3, "eval only reads; it must not have rebuilt the index empty"


def test_embed_refuses_without_dropping() -> None:
    """`embed` WRITES vectors, but it cannot write chunks — so against a mismatched index it is a
    read path. The old failure was not an error: the migrating open dropped every chunk and the
    command then reported "index already fully embedded", because zero chunks are missing zero
    vectors. Success, on an index it had just emptied.

    CHECK THE INSTRUMENT. `rc == 2` is also what a missing Ollama returns, and that path used to
    exit before the store was ever opened — so `rc == 2` plus surviving chunks was exactly what a
    machine with the daemon down produced whether or not the guard existed. Asserting those two
    alone gave a test that passes without running the code it names.

    So the daemon is forced UNREACHABLE here rather than assumed present. That makes the test
    hermetic — it no longer goes red on a machine with no Ollama, which for a suite whose own
    handoff calls Ollama "the unowned dependency" is the difference between a signal and noise —
    and it turns the test into the pin for the ordering: the schema verdict is decidable from the
    arguments alone, so it must be reached without a live daemon. If the probe ever moves back in
    front of the open, this fails on the `"not available"` assertion.
    """
    db = _stale_index()
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        rc = cli.main(["embed", "--db", db, "--cache", str(Path(tempfile.mkdtemp()) / "vc.db"),
                       "--host", "http://127.0.0.1:9"])   # reserved discard port: never listening
    msg = err.getvalue()
    assert "not available" not in msg, (
        "embed reported the daemon instead of the schema, so the availability probe runs before "
        f"the store is opened — it sends the operator to fix Ollama for an index fault. Got: {msg!r}")
    assert rc == 2, rc
    assert "schema" in msg.lower(), f"expected the SCHEMA refusal, got: {msg!r}"
    assert _chunks(db) == 3, "embed must not have dropped the chunks it could not rebuild"


# ---------------------------------------------------------------- the write command

def test_cmd_eval_vector_guards_refuse_without_dropping() -> None:
    """`cmd_eval`'s TWO vector guards, exercised through the CLI. Nothing covered them.

    This is the command the whole guard was written for — `substrate eval` against
    `out/substrate.db` — and reverting both guards to migrating opens left every other test in
    both new files green while a v2 fixture copy went 1811 chunks -> 0. `eval_run()` is called
    directly by the sibling test, so the two guards ABOVE it, which open the database themselves
    before the runner ever does, were reachable only through `cmd_eval` and were never reached.

    The embedder is stubbed available rather than depended upon: the guards are gated behind
    `if embedder is not None`, so on a machine with no Ollama they are skipped entirely and the
    test would pass having executed nothing.
    """
    from substrate.embed import engine

    db = _stale_index()
    tmp = Path(tempfile.mkdtemp())
    gold = tmp / "gold.json"
    gold.write_text(json.dumps({"cases": []}), encoding="utf-8")

    original = engine.OllamaEmbedder.available
    engine.OllamaEmbedder.available = lambda self: True
    try:
        err = io.StringIO()
        with contextlib.redirect_stderr(err), contextlib.redirect_stdout(io.StringIO()):
            rc = cli.main(["eval", "--db", db, "--gold", str(gold),
                           "--baseline", str(tmp / "none.json"), "--no-hyde", "--no-rerank"])
    finally:
        engine.OllamaEmbedder.available = original

    assert rc == 2, rc
    assert "schema" in err.getvalue().lower(), err.getvalue()
    assert _chunks(db) == 3, "the eval vector guard dropped the index it was counting vectors in"


def test_foreign_database_is_never_adopted() -> None:
    """Bootstrap must not write substrate's schema into somebody else's database.

    `_nothing_to_destroy` used to answer "nothing" for any file without a `chunks` table, so
    `index --db <any sqlite file>` stamped it v8 and added our tables. The live instance is
    `out/vector-cache.db` — 200 MB, content-addressed, the one store the code calls NOT
    disposable — reachable by a `--db`/`--cache` mix-up, since `embed` and `eval` take both.
    """
    tmp = Path(tempfile.mkdtemp())
    db = str(tmp / "foreign.db")
    con = sqlite3.connect(db)
    con.execute("CREATE TABLE precious(x)")
    con.executemany("INSERT INTO precious VALUES(?)", [(1,), (2,), (3,)])
    con.commit()
    con.close()

    rc = cli.main(["index", "--db", db, "--out-root", str(tmp)])
    assert rc == 2, "a database holding foreign tables must not be bootstrapped into"
    assert _version(db) == 0, "and must not be restamped"
    con = sqlite3.connect(db)
    assert con.execute("SELECT COUNT(*) FROM precious").fetchone()[0] == 3
    con.close()


def test_documents_without_chunks_are_not_dropped() -> None:
    """`DROP` removes four tables; the emptiness check used to look at one.

    A real index carrying documents but no chunks yet — mid-ingest, or a vault of notes that all
    failed to chunk — reported "nothing to destroy" and lost every document, with rc 0.
    """
    tmp = Path(tempfile.mkdtemp())
    db = str(tmp / "docsonly.db")
    with IndexStore(db) as s:
        s.upsert(Document(doc_id="d0", source_path="/d0.md", source_sha256="s" * 8, source_pages=1,
                          document_class="reference-frozen", title="d0", status="active"), [],
                 markdown_path="/d0.md", markdown_mtime=0.0, markdown_sha256="m" * 8)
    con = sqlite3.connect(db)
    con.execute("PRAGMA user_version=0")
    con.commit()
    con.close()

    rc = cli.main(["index", "--db", db, "--out-root", str(tmp)])
    assert rc == 2, "documents behind a zero version stamp must not be dropped"
    con = sqlite3.connect(db)
    assert con.execute("SELECT COUNT(*) FROM documents").fetchone()[0] == 1
    con.close()


def test_bootstrap_creates_missing_parent_directories() -> None:
    """The fresh-checkout case the bootstrap branch exists for. `out/` is gitignored, so it is
    absent, and `sqlite3.connect` raises rather than creating it — which made bootstrap work only
    where it was already going to. The earlier test passed `mkdtemp()`, an existing directory, so
    it asserted rc == 0 for a scenario it never reproduced."""
    tmp = Path(tempfile.mkdtemp())
    db = str(tmp / "out" / "nested" / "substrate.db")
    assert not (tmp / "out").exists()
    rc = cli.main(["index", "--db", db, "--out-root", str(tmp)])
    assert rc == 0, rc
    assert _version(db) == schema.SCHEMA_VERSION


def test_bootstrap_does_not_announce_a_drop() -> None:
    """`schema.migrate` reports `rebuilt=True` for version 0 too, so creating an index printed
    "schema version changed -> index dropped and rebuilt from markdown" over a file that never
    held anything. That line has to be believed on the run where something really was dropped."""
    tmp = Path(tempfile.mkdtemp())
    out = io.StringIO()
    with contextlib.redirect_stdout(out):
        rc = cli.main(["index", "--db", str(tmp / "new.db"), "--out-root", str(tmp)])
    assert rc == 0, rc
    assert "dropped and rebuilt" not in out.getvalue(), out.getvalue()


def test_rebuild_clears_a_current_version_index() -> None:
    """The other half of `--rebuild`, which nothing exercised.

    `test_rebuild_does_not_imply_migrate` runs against a STALE index, so `cmd_index` returns
    before `args.rebuild` is ever read — deleting `store.clear()` outright left it green. This one
    runs against a current-version index, where `--rebuild` is the only thing that can empty it.
    """
    tmp = Path(tempfile.mkdtemp())
    db = str(tmp / "current.db")
    with IndexStore(db) as s:
        doc = Document(doc_id="d0", source_path="/d0.md", source_sha256="s" * 8, source_pages=1,
                       document_class="reference-frozen", title="d0", status="active")
        ch = Chunk(chunk_id="d0#c0", doc_id="d0", kind="passage", text="body",
                   path=["Root", "d0"], level=2, n_chars=4, document_class="reference-frozen")
        s.upsert(doc, [ch], markdown_path="/d0.md", markdown_mtime=0.0, markdown_sha256="m" * 8)
    assert _chunks(db) == 1

    rc = cli.main(["index", "--rebuild", "--db", db, "--out-root", str(tmp)])
    assert rc == 0, rc
    assert _chunks(db) == 0, "--rebuild must actually clear the index"


def test_compose_migrates_and_repopulates_in_the_same_run() -> None:
    """`compose` is the SEVENTH migrating site, and the only one still migrating without a flag.

    That exemption rests on a property, not on trust: it re-ingests every note before it opens the
    store, so a migration it triggers is refilled in the same run and its database is disposable by
    construction. Nothing pinned that. If `compose` ever stopped repopulating — an early return, a
    reordering that opens the store first — the exemption would silently become the bug this whole
    change exists to remove, and `index`'s comment justifying it would be quietly false.

    Composed into a throwaway registry so the live scope registry is untouched.
    """
    tmp = Path(tempfile.mkdtemp())
    db = str(tmp / "composed.db")
    args = ["compose", str(_REPO / "vaults" / "demo-vault"),
            "--index-root", str(tmp / "idx"), "--db", db,
            "--registry", str(tmp / "scopes.toml")]

    with contextlib.redirect_stdout(io.StringIO()):
        assert cli.main(args) == 0, "baseline compose must succeed"
    seeded = _chunks(db)
    assert seeded > 0, "the fixture vault composed to an empty index"

    # Stamp it backwards, then compose again: this is the migrating open, unflagged.
    con = sqlite3.connect(db)
    con.execute(f"PRAGMA user_version={_STALE}")
    con.commit()
    con.close()

    with contextlib.redirect_stdout(io.StringIO()):
        assert cli.main(args) == 0, "compose must migrate without a flag"
    assert _version(db) == schema.SCHEMA_VERSION
    assert _chunks(db) == seeded, (
        "compose migrated but did not refill — the exemption that lets it skip `--migrate` is "
        "exactly that it repopulates in the same run")


def test_index_refuses_without_the_flag() -> None:
    db = _stale_index()
    rc = cli.main(["index", "--db", db, "--out-root", tempfile.mkdtemp()])
    assert rc == 2, rc
    assert _chunks(db) == 3


def test_rebuild_does_not_imply_migrate() -> None:
    """The whole point of a separate flag. `--rebuild` means "discard content I have already
    judged stale"; `--migrate` means "discard it because the SCHEMA moved". If `--rebuild` carried
    migration authority, one parked in a script would silently acquire it at the next bump."""
    db = _stale_index()
    rc = cli.main(["index", "--rebuild", "--db", db, "--out-root", tempfile.mkdtemp()])
    assert rc == 2, rc
    assert _chunks(db) == 3, "--rebuild must not authorise a schema migration"


def test_bootstrap_needs_no_flag() -> None:
    """Creating an index is not migrating one. Requiring `--migrate` here made `index` unable to
    make an index: `out/` is gitignored, so `./run.sh` could not bootstrap on a fresh checkout."""
    db = str(Path(tempfile.mkdtemp()) / "new.db")
    rc = cli.main(["index", "--db", db, "--out-root", tempfile.mkdtemp()])
    assert rc == 0, rc
    assert _version(db) == schema.SCHEMA_VERSION


def test_bootstrap_survives_a_stub_left_by_an_earlier_refusal() -> None:
    """`schema.connect` creates the file BEFORE the version is read, so a refused open leaves a
    schema-less stub. Gating bootstrap on `Path(db).exists()` would therefore work exactly once and
    refuse every retry forever — the file is already there, holding nothing."""
    tmp = Path(tempfile.mkdtemp())
    db = str(tmp / "stub.db")
    sqlite3.connect(db).close()          # the stub, byte-for-byte what a refusal leaves
    assert Path(db).exists() and _version(db) == 0
    rc = cli.main(["index", "--db", db, "--out-root", str(tmp)])
    assert rc == 0, "a schema-less stub must bootstrap, not refuse"


def test_versionless_database_with_content_still_refuses() -> None:
    """The case `found == 0` cannot resolve alone, and the reason bootstrap checks emptiness rather
    than trusting the version stamp. A database carrying rows whose `user_version` never landed
    reads as 0 — identical to a fresh file — and dropping it would lose real content."""
    tmp = Path(tempfile.mkdtemp())
    db = str(tmp / "versionless.db")
    with IndexStore(db) as s:            # real schema, real rows
        doc = Document(doc_id="d0", source_path="/d0.md", source_sha256="s" * 8, source_pages=1,
                       document_class="reference-frozen", title="d0", status="active")
        ch = Chunk(chunk_id="d0#c0", doc_id="d0", kind="passage", text="body",
                   path=["Root", "d0"], level=2, n_chars=4, document_class="reference-frozen")
        s.upsert(doc, [ch], markdown_path="/d0.md", markdown_mtime=0.0, markdown_sha256="m" * 8)
    con = sqlite3.connect(db)
    con.execute("PRAGMA user_version=0")  # the stamp that never landed
    con.commit()
    con.close()

    rc = cli.main(["index", "--db", db, "--out-root", str(tmp)])
    assert rc == 2, "content behind a missing version stamp must not be silently dropped"
    assert _chunks(db) == 1, "and must still be there"


def test_migrate_flag_actually_rebuilds() -> None:
    """The anti-tautology guard: `--migrate` must still WORK. Without this, a `--migrate` that
    refused everything would pass every other test in this file."""
    db = _stale_index()
    src = Path(tempfile.mkdtemp())
    rc = cli.main(["index", "--migrate", "--db", db, "--out-root", str(src)])
    assert rc == 0, rc
    assert _version(db) == schema.SCHEMA_VERSION, "--migrate must restamp the version"
    # Dropped, and repopulated from an EMPTY source root — so 0 is the correct count here and the
    # version stamp above is what proves the migration ran rather than being refused.
    assert _chunks(db) == 0


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
