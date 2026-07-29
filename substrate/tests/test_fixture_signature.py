"""The eval fixture's content signature must stay RECOMPUTABLE.

Its predecessor was not. `4a4f765c9ad75dc9` guarded `out/substrate.db` in three readouts and in
SESSION-HANDOFF's "EVAL MUST NOT MOVE", and its derivation was written down nowhere —
MIGRATION-VOCABULARY.md records seventeen plausible constructions over `(chunk_id,
text_with_path)` reproducing none of it. An invariant nobody can recompute is an unchecked claim,
which this project already knows is worse than silence: the next reader trusts it instead of
testing it, and it silently stops meaning anything the first time the corpus moves.

So these assert the PROPERTIES the construction is chosen for, not a magic constant. A constant
pinned here would be the same defect one level down — it would tell you the number changed,
never which property broke.

Every test that names a state builds that state for real: the schema-invariance and never-engine-
code tests stamp the version backwards (the house idiom, `test_migrate_optin.py:_stale_index`),
and the sidecar test holds a writer open. An earlier draft of this file wrote 64 zero bytes into
`-wal` and called it an un-checkpointed log; that exercised `st_size > 0` and nothing else, and
would have passed identically had the guard been pure superstition.

Runnable with plain `python tests/test_fixture_signature.py`.
"""

from __future__ import annotations

import atexit
import importlib.util
import shutil
import sqlite3
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.models import Chunk, Document  # noqa: E402
from substrate.store import schema  # noqa: E402
from substrate.store.index_store import IndexStore, SchemaMismatch  # noqa: E402

_spec = importlib.util.spec_from_file_location(
    "fixture_signature", Path(__file__).resolve().parent.parent / "tools" / "fixture-signature.py"
)
fixture_signature = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(fixture_signature)
signature = fixture_signature.signature

# Each refusal has its OWN type, and every test below catches the SPECIFIC one it names. Catching
# the base class let any of five unrelated refusals satisfy a test named for one of them — most
# damagingly the delimiter test, the sole guard on injectivity, which a stray sidecar would have
# satisfied without the delimiter check ever running.
SignatureRefused = fixture_signature.SignatureRefused
MissingFile = fixture_signature.MissingFile
HotSidecar = fixture_signature.HotSidecar
EmptyCorpus = fixture_signature.EmptyCorpus
ForeignShape = fixture_signature.ForeignShape
UnframeableField = fixture_signature.UnframeableField

_STALE = schema.SCHEMA_VERSION - 1
_TMP: list[str] = []
atexit.register(lambda: [shutil.rmtree(d, ignore_errors=True) for d in _TMP])


def _db(name: str = "index.db") -> str:
    d = tempfile.mkdtemp()
    _TMP.append(d)
    return str(Path(d) / name)


def _seed(store: IndexStore, chunks: list[tuple[str, list[str], str]]) -> None:
    """chunks: (chunk_id, path, text). Documents are grouped by the chunk_id's doc part."""
    by_doc: dict[str, list[tuple[str, list[str], str]]] = {}
    for cid, path, text in chunks:
        by_doc.setdefault(cid.split("#")[0], []).append((cid, path, text))
    for doc_id, items in by_doc.items():
        doc = Document(doc_id=doc_id, source_path=f"/{doc_id}.md", source_sha256="s" * 8,
                       source_pages=1, document_class="reference-frozen", title=doc_id,
                       status="active")
        chs = [Chunk(chunk_id=cid, doc_id=doc_id, kind="passage", text=text, path=path,
                     level=len(path), n_chars=len(text), document_class="reference-frozen")
               for cid, path, text in items]
        store.upsert(doc, chs, markdown_path=f"/{doc_id}.md", markdown_mtime=0.0,
                     markdown_sha256="m" * 8)


_BASE = [("a#c0", ["Root", "A"], "alpha body text"),
         ("b#c0", ["Root", "B"], "beta body text"),
         ("c#c0", ["Root", "C"], "gamma body text")]


def _build(chunks=_BASE, name: str = "index.db") -> str:
    p = _db(name)
    with IndexStore(p) as s:
        _seed(s, chunks)
    return p


def _sig(chunks) -> str:
    return signature(_build(chunks))[0]


def _stamp(db: str, version: int) -> None:
    con = sqlite3.connect(db)
    con.execute(f"PRAGMA user_version={version}")
    con.commit()
    con.close()


def test_signature_is_deterministic() -> None:
    assert _sig(_BASE) == _sig(_BASE)


def test_insertion_order_does_not_change_it() -> None:
    """ORDER BY chunk_id, not rowid — otherwise a reindex that touched nothing would 'move' the
    fixture and the signal would be pure noise."""
    assert _sig(_BASE) == _sig(list(reversed(_BASE)))


def test_edited_text_changes_it() -> None:
    edited = [(_BASE[0][0], _BASE[0][1], "alpha body text CHANGED"), *_BASE[1:]]
    assert _sig(edited) != _sig(_BASE), "a text edit must move the signature"


def test_changed_path_changes_it() -> None:
    """The ATTRIBUTION half. A chunk whose text is right and whose structural path names the wrong
    section is the Phase-0 failure the gold set exists to catch, so it cannot be invisible here."""
    moved = [(_BASE[0][0], ["Root", "WRONG"], _BASE[0][2]), *_BASE[1:]]
    assert _sig(moved) != _sig(_BASE), "a path change must move the signature"


def test_added_and_removed_chunks_change_it() -> None:
    assert _sig(_BASE[:2]) != _sig(_BASE), "a lost chunk must move the signature"
    assert _sig([*_BASE, ("d#c0", ["Root", "D"], "delta body")]) != _sig(_BASE)


def test_vectors_do_not_change_it() -> None:
    """Embeddings are a pure function of the text and are keyed on its sha elsewhere. If they moved
    the signature, restoring 1811 vectors from the content-addressed cache — which is what makes a
    rebuild lossless — would read as the fixture having changed.

    Each open is closed before measuring: `immutable=1` ignores the WAL, so a signature taken while
    a writer is open would cover only checkpointed rows.
    """
    p = _build()
    before = signature(p)[0]
    with IndexStore(p) as s:
        s.store_vectors([("a#c0", b"\x00" * 8)], "some-model#raw")
    assert signature(p)[0] == before


def test_version_stamp_is_not_hashed() -> None:
    """The WEAK half of schema invariance, named honestly.

    This can only fail if someone hashes `PRAGMA user_version` — a header field no SELECT can
    reach — so it cannot catch the widened-SELECT regression, and an earlier draft of this file
    claimed it did. The real guard is `test_only_the_three_v1_columns_are_hashed` below; this one
    exists so that a stale stamp is shown not to perturb the value, which is what lets the tool
    read `out/substrate.db.v2-frozen-…` at all.
    """
    p = _build()
    at_current = signature(p)[0]
    _stamp(p, _STALE)
    assert signature(p)[0] == at_current, "the version stamp must not reach the signature"


def test_only_the_three_v1_columns_are_hashed() -> None:
    """The stronger half of schema invariance: a table carrying ONLY the three hashed columns must
    produce the same value as the full current schema over the same rows.

    Stamping the version backwards (above) proves the STAMP does not reach the hash; it would not
    catch someone widening the SELECT to `status` or `confidence`, which exist at v8 and not at v2
    and would therefore break the v2-frozen comparison while every other test stayed green. This
    catches exactly that, because those columns are absent here.
    """
    p = _db("v2-shaped.db")
    con = sqlite3.connect(p)
    con.execute("CREATE TABLE chunks(chunk_id TEXT PRIMARY KEY, path_str TEXT, text TEXT)")
    con.executemany(
        "INSERT INTO chunks (chunk_id, path_str, text) VALUES (?,?,?)",
        [(cid, " > ".join(path), text) for cid, path, text in _BASE],
    )
    con.commit()
    con.close()
    assert signature(p)[0] == _sig(_BASE), (
        "a minimal v1-shaped chunks table must sign identically to the current schema — if it "
        "does not, the hash is reading a column that did not exist at v2"
    )


def test_foreign_column_types_are_refused_not_crashed() -> None:
    """SQLite is dynamically typed, so any foreign table shape lands in the hashing loop. A bare
    `AttributeError: 'int' object has no attribute 'encode'` is not an answer to "is this the right
    kind of file?" — and it is not an `sqlite3.Error`, so it would escape the CLI handler as a
    traceback alongside every other failure printing a clean line."""
    cases = [
        ("integer chunk_id", "7, 'Root > A', 'body'"),
        ("blob text", "'a#c0', 'Root > A', X'00ff'"),
        ("null path_str", "'a#c0', NULL, 'body'"),
        ("null text", "'a#c0', 'Root > A', NULL"),
    ]
    for why, values in cases:
        p = _db("foreign.db")
        con = sqlite3.connect(p)
        con.execute("CREATE TABLE chunks(chunk_id, path_str, text)")
        con.execute(f"INSERT INTO chunks VALUES ({values})")
        con.commit()
        con.close()
        try:
            signature(p)
        except ForeignShape:
            continue
        raise AssertionError(f"expected ForeignShape for {why}")


def test_null_does_not_sign_as_empty_string() -> None:
    """`COALESCE(path_str,'')` folded the two together, so a corpus that NULLed a field signed
    identically to one that emptied it — a silent non-injectivity pointing the opposite way from
    the delimiter one. Measured on the fixture: 0 NULLs and exactly 1 empty path_str, so refusing
    NULL rather than coalescing it leaves the constant untouched."""
    p = _db("empty-path.db")
    con = sqlite3.connect(p)
    con.execute("CREATE TABLE chunks(chunk_id, path_str, text)")
    con.execute("INSERT INTO chunks VALUES ('a#c0', '', 'body')")
    con.commit()
    con.close()
    assert signature(p)[1] == 1, "an empty-string path_str is legitimate and must still sign"


def test_engine_code_could_not_substitute_for_the_immutable_read() -> None:
    """Pins WHY this tool lives outside the package, against a future 'simplification'.

    Neither engine setting works on the artifact this exists to measure. `migrate=True` is
    drop-and-rebuild on a mismatch — it destroys the fixture and then truthfully reports what it
    just built; `migrate=False` refuses to read it at all. Both are demonstrated here on a stale
    stamp, because at the CURRENT version both engine opens are harmless and a test built there
    cannot tell the two worlds apart.
    """
    p = _build()
    expected = signature(p)[0]
    _stamp(p, _STALE)

    store = None
    try:
        store = IndexStore(p, migrate=False)
    except SchemaMismatch:
        pass
    else:
        raise AssertionError("expected the read path to refuse a stale index")
    finally:
        # The constructor raises BEFORE `.close()` would run, so a connection it opened would leak
        # and keep the sidecar alive — at which point the assertions below would be satisfied by a
        # HotSidecar refusal instead of by the destruction they claim to observe.
        if store is not None:
            store.close()

    assert signature(p)[0] == expected, "the tool must read what the engine cannot"

    with IndexStore(p) as s:  # migrate=True: drop-and-rebuild
        assert s.counts_by("tier") is not None
    try:
        signature(p)
    except EmptyCorpus:
        return  # SPECIFICALLY empty — the migrating open dropped the rows, which is the point
    raise AssertionError("a migrating open should have destroyed the rows this tool measures")


def test_reading_does_not_write() -> None:
    """immutable=1 leaves the file and its sidecars alone — including at a version the engine
    would migrate. `mode=ro` would NOT satisfy this: under Python it opens, but it creates the
    `-shm`/`-wal` pair beside the artifact, which is the process state commit a3c63f0 untracked.
    """
    p = _build()
    _stamp(p, _STALE)
    before = Path(p).read_bytes()
    signature(p)
    assert Path(p).read_bytes() == before, "computing the signature must not write to the database"
    for suffix in ("-wal", "-shm", "-journal"):
        assert not Path(p + suffix).exists(), f"signature() created a {suffix} sidecar"


def test_open_writer_undercounts_and_is_refused() -> None:
    """The failure the sidecar refusal exists for, built for real rather than simulated.

    Asserts the PREMISE as well as the refusal: with committed-but-un-checkpointed frames in the
    log, an `immutable=1` read genuinely returns FEWER rows. Without that half, the test would pass
    even if `immutable=1` read the WAL perfectly and the guard were superstition.
    """
    p = _build()
    con = sqlite3.connect(p)
    mode = con.execute("PRAGMA journal_mode=WAL").fetchone()[0]
    if mode != "wal":  # the pragma reports the UNCHANGED mode rather than raising
        con.close()
        raise AssertionError(f"could not put the database in WAL mode (got {mode!r})")
    con.execute("INSERT INTO chunks (chunk_id, doc_id, kind, text, text_with_path, path_str, "
                "level, n_chars, document_class) VALUES ('z#c0','z','passage','zeta',"
                "'Root > Z\nzeta','Root > Z',2,4,'reference-frozen')")
    con.commit()
    try:
        raw = sqlite3.connect(Path(p).resolve().as_uri() + "?immutable=1", uri=True)
        try:
            visible = raw.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        finally:
            raw.close()
        live = con.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        assert visible < live, (
            f"premise broken: immutable read saw {visible}, writer sees {live} — if these agree, "
            "the refusal is guarding nothing"
        )
        try:
            signature(p)
        except HotSidecar:
            return
        raise AssertionError("expected HotSidecar while a writer holds un-checkpointed rows")
    finally:
        con.close()


def test_stale_generation_wal_is_not_refused() -> None:
    """A non-empty `-wal` whose frames belong to a PREVIOUS generation must not block the read.

    Built from a real WAL rather than a hand-written header, because the hand-written version of
    this test was wrong twice over: it claimed to reproduce "the state a reader leaves behind",
    and a reader in fact leaves a ZERO-byte `-wal` (measured) which `size == 0` already
    short-circuits — so it exercised a state SQLite never produces, using a header SQLite would
    reject anyway for its zeroed checksums.

    The real state is a reset: SQLite bumps the header salts and starts writing at offset 32,
    stranding the older frames. Verified here in both directions — SQLite itself reads straight
    past these frames, and so does the guard.
    """
    p = _build()
    expected = signature(p)[0]
    con = sqlite3.connect(p)
    assert con.execute("PRAGMA journal_mode=WAL").fetchone()[0] == "wal"
    con.execute("INSERT INTO chunks (chunk_id, doc_id, kind, text, text_with_path, path_str, "
                "level, n_chars, document_class) VALUES ('z#c0','z','passage','zeta',"
                "'Root > Z\nzeta','Root > Z',2,4,'reference-frozen')")
    con.commit()
    wal = Path(p + "-wal")
    live = bytearray(wal.read_bytes())
    assert len(live) > 32, "premise: a committed write must leave real frames in the log"
    con.close()  # checkpoints the rows into the main database and removes the log

    live[16:24] = bytes(b ^ 0xFF for b in live[16:24])  # bump the header salt: a stale generation
    wal.write_bytes(bytes(live))
    try:
        # ORDER MATTERS. `signature` reads with immutable=1 and leaves the log alone, but a normal
        # sqlite3 open RESETS a stale WAL and deletes it — so checking the premise first destroyed
        # the very state under test and left this test passing no matter what the guard did.
        # Measured: the sidecar was GONE after the premise open. Assert against the state first.
        assert signature(p)[1] == len(_BASE) + 1, "a stale-generation WAL must not be refused"
        assert signature(p)[0] != expected, "sanity: the checkpointed row is really in the database"
        assert wal.exists() and wal.stat().st_size > 0, "signature() must not have touched the log"

        raw = sqlite3.connect(p)  # destroys the planted state; must come last
        try:
            through_sqlite = raw.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        finally:
            raw.close()
        assert through_sqlite == len(_BASE) + 1, (
            "premise: SQLite must itself ignore these frames, or the guard is right to refuse"
        )
    finally:
        wal.unlink(missing_ok=True)


def test_unparseable_wal_is_refused_not_ignored() -> None:
    """PROVE SAFE, ELSE REFUSE — the property that makes a hand-rolled binary reader acceptable
    here at all. A header this code cannot interpret must fail toward refusal, because the
    alternative is a reader bug quietly deciding an unreadable log is empty, which is precisely the
    silent undercount the sidecar guard exists to prevent."""
    p = _build()
    # The first case is the one that needs the magic check specifically: every other field is
    # plausible and there are no frames, so without it the reader would conclude "empty log, safe"
    # about a file it has no business interpreting. The others are caught by later guards too —
    # kept because the assertion here is the OUTCOME, and defence in depth is the intent.
    plausible = bytearray(32)
    plausible[0:4] = b"\xde\xad\xbe\xef"                # NOT a WAL magic
    plausible[4:8] = (3007000).to_bytes(4, "big")
    plausible[8:12] = (4096).to_bytes(4, "big")         # plausible page size, no frames follow
    for label, blob in (("bad magic, otherwise plausible", bytes(plausible)),
                        ("bad magic and zero page size", b"\xde\xad\xbe\xef" + b"\x00" * 28),
                        ("truncated header", b"\x37\x7f\x06\x82" + b"\x00" * 8)):
        Path(p + "-wal").write_bytes(blob)
        try:
            signature(p)
        except HotSidecar:
            continue
        finally:
            Path(p + "-wal").unlink(missing_ok=True)
        raise AssertionError(f"expected a refusal for a WAL with a {label}")


def test_salt_matching_frame_is_refused_even_when_inert() -> None:
    """Pins the DELIBERATE OVER-REFUSAL, which is what this test is actually able to demonstrate.

    The frame below has a zero commit field and zero checksums, so SQLite does not replay it —
    measured: a normal open over this exact blob still reads the pre-plant row count. An earlier
    version of this test was named for "replayable frames" and asserted a refusal that is really a
    FALSE refusal, which is the fourth law's shape inside the file that introduced it.

    Refusing it is still correct: matching salts are a superset of SQLite's replay rule, and
    narrowing to the exact rule would mean reimplementing its checksum chain, where a bug fails by
    calling a hot log empty. Genuine hot-WAL coverage lives in
    `test_open_writer_undercounts_and_is_refused`, which uses a real writer.
    """
    p = _build()
    header = bytearray(32)
    header[0:4] = (0x377F0682).to_bytes(4, "big")
    header[4:8] = (3007000).to_bytes(4, "big")
    header[8:12] = (4096).to_bytes(4, "big")
    salt = b"\x01\x02\x03\x04\x05\x06\x07\x08"
    header[16:24] = salt
    frame = bytearray(24)
    frame[0:4] = (1).to_bytes(4, "big")   # page number; commit field at 4:8 left zero
    frame[8:16] = salt                    # matches the header -> refused by this guard
    Path(p + "-wal").write_bytes(bytes(header) + bytes(frame) + b"\x00" * 4096)
    try:
        signature(p)
    except HotSidecar:
        return
    finally:
        Path(p + "-wal").unlink(missing_ok=True)
    raise AssertionError("a salt-matching frame must be refused")


def test_missing_file_refuses_and_does_not_create_it() -> None:
    """`immutable=1` does NOT imply "will not create" — verified: a typo'd path materialises a
    zero-byte database, then reports "no such table: chunks", which reads as a wrong-shaped fixture
    rather than a wrong file. IndexStore carries an explicit guard against the same incident."""
    p = _db("never-created.db")
    try:
        signature(p)
    except MissingFile:
        assert not Path(p).exists(), "refusing to read a missing file must not create it"
        return
    raise AssertionError("expected MissingFile for a path that does not exist")


def test_empty_corpus_is_refused_not_signed() -> None:
    """sha256 of the empty stream is a perfectly well-formed 16-hex value for nothing at all, and
    is shape-indistinguishable from a real signature once the count is dropped from the line."""
    p = _db()
    with IndexStore(p):
        pass
    try:
        signature(p)
    except EmptyCorpus:
        return
    raise AssertionError("expected EmptyCorpus for a chunks table with no rows")


def test_delimiter_bearing_fields_are_refused() -> None:
    """The framing is injective ONLY while no field carries a delimiter, so that is enforced.

    Both collisions are real and were constructed by review: a NUL inside `text`, and a newline
    inside `chunk_id`, each let two different chunk sets serialise to identical bytes — meaning a
    re-chunk would leave the signature unmoved, which is the one thing it must never do. Measured
    on the fixture: 0 of 1811 chunk_ids and path_strs contain a newline, 0 texts contain a NUL.
    """
    for chunks, why in (
        ([("a#c0", ["Root", "A"], "alpha\x00beta")], "NUL in text"),
        ([("a\nb#c0", ["Root", "A"], "alpha")], "newline in chunk_id"),
        ([("a#c0", ["Root", "A\nB"], "alpha")], "newline in path_str"),
    ):
        try:
            signature(_build(chunks))
        except UnframeableField:
            continue
        raise AssertionError(f"expected UnframeableField for {why}")


def test_uri_special_characters_read_the_named_file() -> None:
    """A `#`, `?` or `%` in the path used to be parsed as URI syntax: `…/idx#1.db` opened `…/idx`,
    CREATED it, discarded `immutable=1` (the connection came back WRITABLE) and checked the wrong
    sidecar. Percent-encoding via `Path.as_uri()` is what closes it."""
    for dirname in ("has#hash", "has%percent"):
        d = Path(tempfile.mkdtemp()) / dirname
        d.mkdir()
        p = str(d / "index.db")
        with IndexStore(p) as s:
            _seed(s, _BASE)
        sig, n = signature(p)
        assert n == len(_BASE), f"{dirname}: read {n} chunks, expected {len(_BASE)}"
        assert sig == _sig(_BASE), f"{dirname}: signed a different file"


def test_chunk_count_is_reported_not_document_count() -> None:
    """`1811 chunks` is the human-legible half of the EVAL MUST NOT MOVE line — the number an
    operator eyeballs when the hex means nothing to them. With one document per chunk the
    assertion passes identically if `signature` counted documents, so this uses two chunks in one
    document to tell them apart."""
    chunks = [("a#c0", ["Root", "A"], "alpha"),
              ("a#c1", ["Root", "A", "Deeper"], "second chunk, same document"),
              ("b#c0", ["Root", "B"], "beta")]
    assert signature(_build(chunks))[1] == 3, "must count chunks (3), not documents (2)"


def test_persist_journal_is_not_refused() -> None:
    """The same false refusal in rollback-journal form, which had NO working remedy at all.

    A `journal_mode=PERSIST` database keeps its `-journal` after a clean commit with the header
    ZEROED — SQLite's own marker for "nothing to roll back". The first version of this guard
    refused it on size and told the operator to run a WAL checkpoint, which is a verified no-op on
    a rollback journal: it returns (0,-1,-1) and leaves the file byte-identical.
    """
    p = _db("persist.db")
    con = sqlite3.connect(p)
    con.execute("PRAGMA journal_mode=PERSIST")
    con.execute("CREATE TABLE chunks(chunk_id TEXT, path_str TEXT, text TEXT)")
    con.executemany("INSERT INTO chunks VALUES (?,?,?)",
                    [(f"a{i:03d}", "Root > A", f"body {i}") for i in range(200)])
    con.commit()
    con.close()
    journal = Path(p + "-journal")
    assert journal.exists() and journal.stat().st_size > 0, (
        "premise broken: no persistent -journal on this platform, so this test would assert "
        "nothing — a skip reporting as a pass is the defect this file is about"
    )
    assert signature(p)[1] == 200, "an invalidated rollback journal must not be refused"


def test_declared_collation_does_not_move_the_signature() -> None:
    """`ORDER BY chunk_id` alone inherits the COLUMN's declared collation, so a byte-identical
    corpus in a `COLLATE NOCASE` table would sign differently — silently breaking the cross-version
    property, since neither hand-built table in the other tests uses a non-default collation."""
    rows = [("a#c0", "Root > A", "alpha"), ("B#c0", "Root > B", "beta")]  # BINARY: B before a

    def sign_with(collation: str) -> str:
        p = _db(f"coll-{collation}.db")
        con = sqlite3.connect(p)
        con.execute(f"CREATE TABLE chunks(chunk_id TEXT COLLATE {collation}, path_str TEXT, "
                    "text TEXT)")
        con.executemany("INSERT INTO chunks VALUES (?,?,?)", rows)
        con.commit()
        con.close()
        return signature(p)[0]

    assert sign_with("BINARY") == sign_with("NOCASE"), (
        "the signature must not depend on the column's declared collation"
    )


def test_a_writer_committing_after_the_precheck_is_still_caught() -> None:
    """The TOCTOU window: the sidecar is stat'd, then the connection opens and fetches. A writer
    committing in between yields a perfectly well-formed undercount — the guard's own blind spot.
    Made deterministic by committing at the moment the tool opens its connection."""
    p = _build()
    real_connect = sqlite3.connect
    state: dict[str, object] = {}

    def connect_and_race(*args, **kwargs):
        if "writer" not in state:
            w = real_connect(p)
            w.execute("PRAGMA journal_mode=WAL")
            w.execute("INSERT INTO chunks (chunk_id, doc_id, kind, text, text_with_path, "
                      "path_str, level, n_chars, document_class) VALUES ('z#c0','z','passage',"
                      "'zeta','Root > Z\nzeta','Root > Z',2,4,'reference-frozen')")
            w.commit()
            state["writer"] = w  # held open so the -wal survives the rest of the call
        return real_connect(*args, **kwargs)

    # NOTE: `fixture_signature.sqlite3` IS the process-global module, so this patch is visible to
    # everything while it is installed. Safe only because this suite runs serially; a parallel
    # runner would need the tool to take an injectable opener instead.
    fixture_signature.sqlite3.connect = connect_and_race
    try:
        try:
            signature(p)
        except HotSidecar:
            return
        raise AssertionError("a commit inside the check-to-read window must not pass unnoticed")
    finally:
        fixture_signature.sqlite3.connect = real_connect
        writer = state.get("writer")
        if writer is not None:
            writer.close()


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
