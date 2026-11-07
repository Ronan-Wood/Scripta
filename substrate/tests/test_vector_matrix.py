"""The vector arm's in-memory matrix (`store/vector_matrix.py`) must answer exactly as the scan.

Three properties are pinned, each against the scan the cache replaced:

  * EQUIVALENCE. Over a corpus that exercises every filter `vector_search` takes, the cached path
    returns the scan's hits, in the scan's order, with the scan's scores.
  * STALENESS. Every way the index can change under a held matrix is seen: a commit from another
    connection or from the store's own, a positional `chunk_id` re-embedded in place, vectors
    added or dropped, a rebuild in place, a file replaced by rename, two copies sharing one
    generation, and an uncommitted write on the store's own connection. One call reads one
    snapshot even when a commit lands in the middle of it.
  * FILTERS HOLD ON THIS PATH. Each filter is tested with the best-matching vector belonging to
    a passage that filter must remove, so a cached path that skipped the filter returns it.

`_forbid_scan` proves the cached path answered. Without it, a cache that silently fell back to
the scan on every call would pass every equivalence test here. With it, a stale entry served
returns the old vectors' answer, and the staleness tests fail on content.
"""

from __future__ import annotations

import os
import random
import sqlite3
from pathlib import Path

import pytest

from substrate.models import Chunk, Document
from substrate.retrieve.retriever import DEFAULT_STATUSES
from substrate.store import vector_matrix
from substrate.store.index_store import IndexStore

KEY = "test-embedder#raw"
DIM = 8


@pytest.fixture(autouse=True)
def _empty_cache():
    vector_matrix.clear()
    yield
    vector_matrix.clear()


def _unit(rng: random.Random, width: int = DIM) -> list[float]:
    v = [rng.gauss(0, 1) for _ in range(width)]
    n = sum(x * x for x in v) ** 0.5
    return [x / n for x in v]


def _doc(store: IndexStore, doc_id: str, texts: list[str], *, status: str = "active",
         vault: str | None = "proj", document_class: str = "reference-frozen",
         kinds: list[str] | None = None) -> list[str]:
    doc = Document(doc_id=doc_id, source_path=f"/{doc_id}.md", source_sha256="s" * 8,
                   source_pages=1, document_class=document_class, title=doc_id, status=status,
                   vault=vault)
    chunks = [
        Chunk(chunk_id=f"{doc_id}#c{i:05d}", doc_id=doc_id,
              kind=(kinds[i] if kinds else "passage"), text=t, path=["Root", doc_id], level=2,
              n_chars=len(t), document_class=document_class)
        for i, t in enumerate(texts)
    ]
    store.upsert(doc, chunks, markdown_path=f"/{doc_id}.md", markdown_mtime=0.0,
                 markdown_sha256="m" * 8)
    return [c.chunk_id for c in chunks]


def _corpus(path: str, seed: int = 7) -> dict[str, list[float]]:
    """40 documents across every filter axis, one vector per chunk. Returns chunk_id -> vector."""
    rng = random.Random(seed)
    vecs: dict[str, list[float]] = {}
    with IndexStore(path) as s:
        s.replace_identity([("ent-a", "A", "person", None), ("ent-b", "B", "person", None)])
        for i in range(40):
            ids = _doc(
                s, f"d{i:02d}", [f"passage {i} {j}" for j in range(6)],
                status=["active", "complete", "archived", "superseded"][i % 4],
                vault=["proj", "core", None, "calls"][i % 4 if i % 5 else 2],
                document_class="conversation" if i % 7 == 0 else "reference-frozen",
                kinds=["passage", "passage", "outline", "passage", "passage", "outline"],
            )
            if i % 3 == 0:
                s.set_document_entities(f"d{i:02d}", [("ent-a", "A")])
            if i % 4 == 1:
                s.set_document_entities(f"d{i:02d}", [("ent-b", "B")])
            for cid in ids:
                vecs[cid] = _unit(rng)
        s.store_vectors(list(vecs.items()), KEY)
    return vecs


@pytest.fixture
def db(tmp_path: Path) -> str:
    p = str(tmp_path / "index.db")
    _corpus(p)
    return p


def _forbid_scan(monkeypatch) -> None:
    def refuse(*a, **kw):
        raise AssertionError("the scan ran; the cached path should have answered")
    monkeypatch.setattr(IndexStore, "_vector_scan", refuse)


@pytest.fixture
def scan_forbidden(monkeypatch):
    _forbid_scan(monkeypatch)


def _reader(path: str) -> IndexStore:
    """How the server opens an index: an existing file, read-only. Its identity is known."""
    s = IndexStore(path, migrate=False)
    assert s.file_id is not None
    return s


def _filters(i: int) -> dict:
    """A deterministic spread over every filter `vector_search` takes, alone and combined."""
    opts: list[dict] = [
        {},
        {"kind": "passage"},
        {"kind": "outline"},
        {"statuses": DEFAULT_STATUSES},
        {"statuses": frozenset()},
        {"statuses": frozenset({"archived"})},
        {"include_sources": True},
        {"document_class": "conversation"},
        {"doc_id": "d03"},
        {"vaults": frozenset({"proj"})},
        {"vaults": frozenset()},
        {"withheld_vaults": frozenset({"core"})},
        {"vaults": frozenset({"proj", "core"}), "withheld_vaults": frozenset({"core"})},
        {"entity": "ent-a"},
        {"entity": "nobody"},
        {"kind": "passage", "statuses": DEFAULT_STATUSES, "withheld_vaults": frozenset({"calls"}),
         "entity": "ent-b"},
    ]
    return opts[i % len(opts)]


def _key(hits) -> list[tuple[str, float]]:
    return [(h.chunk_id, h.score) for h in hits]


def _scan_then_cached(s: IndexStore, q: list[float], k: int, **f) -> tuple[list, list]:
    """(the scan's hits, the cached path's hits) for one call, each path FORCED: the cache is
    switched off for the first and the scan forbidden for the second."""
    with pytest.MonkeyPatch.context() as mp:
        mp.setattr(IndexStore, "_vector_search_cached", lambda *a, **kw: None)
        expected = s.vector_search(q, KEY, k=k, **f)
    with pytest.MonkeyPatch.context() as mp:
        _forbid_scan(mp)
        got = s.vector_search(q, KEY, k=k, **f)
    return expected, got


def _wide_corpus(path: str, rng: random.Random, *, docs: int = 30, per_doc: int = 10) -> None:
    """1024 wide, as the operator's embedder is, and every third document archived."""
    with IndexStore(path) as w:
        for i in range(docs):
            ids = _doc(w, f"w{i:02d}", [f"t{j}" for j in range(per_doc)],
                       status="archived" if i % 3 == 0 else "active")
            w.store_vectors([(cid, _unit(rng, 1024)) for cid in ids], KEY)


# ---------------------------------------------------------------- equivalence


def test_cached_path_returns_the_scans_hits(db: str) -> None:
    """Hits, order and scores, across every filter and several k, against the scan itself."""
    rng = random.Random(11)
    with _reader(db) as s:
        for i in range(64):
            f, k = _filters(i), [1, 3, 10, 500][i % 4]
            expected, got = _scan_then_cached(s, _unit(rng), k, **f)
            assert _key(got) == _key(expected), (i, f, k)
            assert got == expected, (i, f, k)


def test_cached_path_answers_through_the_public_call(db: str, scan_forbidden) -> None:
    with _reader(db) as s:
        hits = s.vector_search(_unit(random.Random(1)), KEY, k=5, kind="passage",
                               statuses=DEFAULT_STATUSES)
    assert len(hits) == 5
    assert all(h.kind == "passage" and h.status in DEFAULT_STATUSES for h in hits)


def test_one_matrix_serves_every_store_on_the_file(db: str) -> None:
    """The server opens and closes a store per call, so a cache scoped to a store is no cache."""
    q = _unit(random.Random(2))
    with _reader(db) as s:
        s.vector_search(q, KEY, k=3)
    first = vector_matrix._ENTRIES[(os.path.realpath(db), KEY, DIM, False)]
    with _reader(db) as s:
        s.vector_search(q, KEY, k=3)
    assert vector_matrix._ENTRIES[(os.path.realpath(db), KEY, DIM, False)] is first


# ---------------------------------------------------------------- filters hold here


def _plant_best(path: str, doc_id: str, q: list[float], **doc_kw) -> str:
    """A new document whose one passage IS the query vector, so it outranks everything."""
    with IndexStore(path) as w:
        (cid,) = _doc(w, doc_id, ["the planted best match"], **doc_kw)
        w.store_vectors([(cid, q)], KEY)
    return cid


@pytest.mark.parametrize("doc_kw, call_kw", [
    ({"status": "archived"}, {"statuses": DEFAULT_STATUSES}),
    ({"vault": "core"}, {"withheld_vaults": frozenset({"core"})}),
    ({"vault": "calls"}, {"vaults": frozenset({"proj"})}),
    ({"document_class": "conversation"}, {}),
    ({"kinds": ["outline"]}, {"kind": "passage"}),
], ids=["status", "withheld-vault", "vault", "class-exclusion", "kind"])
def test_a_filter_removes_the_best_match_on_the_cached_path(db: str, scan_forbidden,
                                                            doc_kw, call_kw) -> None:
    q = _unit(random.Random(3))
    best = _plant_best(db, "zz-best", q, **doc_kw)
    with _reader(db) as s:
        unfiltered = s.vector_search(q, KEY, k=3, include_sources=True)
        filtered = s.vector_search(q, KEY, k=3, **call_kw)
    assert unfiltered[0].chunk_id == best, "the planted vector must win when nothing filters it"
    assert best not in [h.chunk_id for h in filtered]


def test_entity_filter_holds_on_the_cached_path(db: str, scan_forbidden) -> None:
    q = _unit(random.Random(4))
    best = _plant_best(db, "zz-best", q)
    with _reader(db) as s:
        assert s.vector_search(q, KEY, k=1)[0].chunk_id == best
        hits = s.vector_search(q, KEY, k=50, entity="ent-a")
    assert hits and best not in [h.chunk_id for h in hits]
    with _reader(db) as s:
        a_docs = {r[0] for r in s.db.execute(
            "SELECT doc_id FROM document_entities WHERE entity_id='ent-a'")}
    assert {h.doc_id for h in hits} <= a_docs


def test_other_spaces_are_never_ranked(db: str, scan_forbidden) -> None:
    """Another model's vectors, and a wrong-dim vector under THIS model, are invisible."""
    q = _unit(random.Random(5))
    with IndexStore(db) as w:
        (cid,) = _doc(w, "zz-wrongdim", ["wrong dim"])
        w.store_vectors([(cid, q + [0.0])], KEY)          # DIM + 1 under this model
        (oid,) = _doc(w, "zz-othermodel", ["other model"])
        w.store_vectors([(oid, q)], "other#raw")
    with _reader(db) as s:
        ids = [h.chunk_id for h in s.vector_search(q, KEY, k=1000, include_sources=True)]
    assert cid not in ids and oid not in ids


# ---------------------------------------------------------------- staleness


def test_a_commit_from_another_connection_is_seen(db: str, monkeypatch) -> None:
    q = _unit(random.Random(6))
    with _reader(db) as s:
        before = s.vector_search(q, KEY, k=1)[0].chunk_id
    best = _plant_best(db, "zz-new", q)
    assert best != before
    _forbid_scan(monkeypatch)
    with _reader(db) as s:
        assert s.vector_search(q, KEY, k=1)[0].chunk_id == best


def test_a_positional_chunk_id_re_embedded_in_place_is_seen(db: str, monkeypatch) -> None:
    """`chunk_id` is `{doc_id}#c{seq}`: a re-chunked note keeps its ids and changes its vectors.
    Nothing about the id set or the row count moves; only the generation's `n` does."""
    q = _unit(random.Random(8))
    with _reader(db) as s:
        top = s.vector_search(q, KEY, k=1)[0].chunk_id
        last = s.vector_search([-x for x in q], KEY, k=1)[0].chunk_id
    with IndexStore(db) as w:
        n = w.db.execute("SELECT COUNT(*) FROM chunk_vectors").fetchone()[0]
        w.store_vectors([(last, q)], KEY)
        w.store_vectors([(top, [-x for x in q])], KEY)
        assert w.db.execute("SELECT COUNT(*) FROM chunk_vectors").fetchone()[0] == n
    _forbid_scan(monkeypatch)
    with _reader(db) as s:
        assert s.vector_search(q, KEY, k=1)[0].chunk_id == last


def test_embedding_a_chunk_that_had_no_vector_is_seen(db: str, monkeypatch) -> None:
    """What `embed` does after a compose: fill vectors for chunks that have none."""
    q = _unit(random.Random(19))
    with IndexStore(db) as w:
        (cid,) = _doc(w, "zz-unembedded", ["composed, not yet embedded"])
    with _reader(db) as s:
        assert cid not in [h.chunk_id for h in s.vector_search(q, KEY, k=1000)]
    with IndexStore(db) as w:
        w.store_vectors([(cid, q)], KEY)
    _forbid_scan(monkeypatch)
    with _reader(db) as s:
        assert s.vector_search(q, KEY, k=1)[0].chunk_id == cid


def test_dropped_vectors_are_never_returned(db: str, monkeypatch) -> None:
    """`embed` under a new model drops the old space. A matrix of the old space must go with it."""
    q = _unit(random.Random(20))
    with _reader(db) as s:
        assert s.vector_search(q, KEY, k=5)
    with IndexStore(db) as w:
        assert w.drop_vectors("new-embedder#raw") > 0
    _forbid_scan(monkeypatch)
    with _reader(db) as s:
        assert s.vector_search(q, KEY, k=5) == []


def test_a_commit_from_the_stores_own_connection_is_seen(db: str, monkeypatch) -> None:
    q = _unit(random.Random(9))
    with IndexStore(db) as s:
        assert s.file_id is not None
        s.vector_search(q, KEY, k=1)
        (cid,) = _doc(s, "zz-own", ["own connection"])
        s.store_vectors([(cid, q)], KEY)
        _forbid_scan(monkeypatch)
        assert s.vector_search(q, KEY, k=1)[0].chunk_id == cid


def test_an_uncommitted_write_on_the_store_scans(db: str) -> None:
    """Another connection cannot see this transaction, so the matrix cannot either."""
    q = _unit(random.Random(10))
    with IndexStore(db) as s:
        s.vector_search(q, KEY, k=1)
        target = s.vector_search([-x for x in q], KEY, k=1)[0].chunk_id
        s.db.execute("BEGIN")
        s.db.execute("UPDATE chunk_vectors SET vector=? WHERE chunk_id=?",
                     (_pack(q), target))
        try:
            assert s.vector_search(q, KEY, k=1)[0].chunk_id == target
        finally:
            s.db.execute("ROLLBACK")


def test_one_call_reads_one_snapshot(db: str, monkeypatch) -> None:
    """A commit landing after the generation is read belongs to the NEXT query. It re-embeds X to
    be the best match and archives the current best, Y, in one transaction:

      * the old state answers Y, and the new state answers X;
      * a call that mixed them, old vectors under the new filters, would answer some third
        passage: Y filtered out, and X still on its old vector.
    """
    q = _unit(random.Random(12))
    live = DEFAULT_STATUSES
    with _reader(db) as s:
        top = s.vector_search(q, KEY, k=5, statuses=live)
    y, x = top[0].chunk_id, top[4].chunk_id
    real_lookup = vector_matrix.lookup
    state: dict = {}

    def lookup_then_commit(*a, **kw):
        m = real_lookup(*a, **kw)
        if not state:
            with IndexStore(db) as w:
                w.db.execute("BEGIN")
                w.db.execute("UPDATE chunk_vectors SET vector = ? WHERE chunk_id = ?",
                             (_pack(q), x))
                w.db.execute("UPDATE chunks SET status = 'archived' WHERE chunk_id = ?", (y,))
                w.db.execute("COMMIT")
            state["done"] = True
        return m

    monkeypatch.setattr(vector_matrix, "lookup", lookup_then_commit)
    _forbid_scan(monkeypatch)
    with _reader(db) as s:
        assert s.vector_search(q, KEY, k=1, statuses=live)[0].chunk_id == y
        assert s.vector_search(q, KEY, k=1, statuses=live)[0].chunk_id == x


def test_a_matrix_read_on_a_miss_is_the_snapshot_the_call_sees(db: str, monkeypatch) -> None:
    """The cold-cache half of the snapshot rule. The same X/Y commit lands after the generation is
    read and BEFORE the vectors are, on a miss. Read on another snapshot, the new vectors would be
    kept under the old generation: this call would mix states and the next would trust it."""
    q = _unit(random.Random(30))
    live = DEFAULT_STATUSES
    with _reader(db) as s:
        top = s.vector_search(q, KEY, k=5, statuses=live)
    y, x = top[0].chunk_id, top[4].chunk_id
    vector_matrix.clear()
    real_vectors = IndexStore._vectors
    state: dict = {}

    def commit_then_read(self, *a, **kw):
        if not state:
            with IndexStore(db) as w:
                w.db.execute("BEGIN")
                w.db.execute("UPDATE chunk_vectors SET vector = ? WHERE chunk_id = ?",
                             (_pack(q), x))
                w.db.execute("UPDATE chunks SET status = 'archived' WHERE chunk_id = ?", (y,))
                w.db.execute("COMMIT")
            state["done"] = True
        return real_vectors(self, *a, **kw)

    monkeypatch.setattr(IndexStore, "_vectors", commit_then_read)
    _forbid_scan(monkeypatch)
    with _reader(db) as s:
        assert s.vector_search(q, KEY, k=1, statuses=live)[0].chunk_id == y
        assert s.vector_search(q, KEY, k=1, statuses=live)[0].chunk_id == x


def test_a_file_replaced_by_rename_is_seen(tmp_path: Path, monkeypatch) -> None:
    """An agent snapshot is replaced by `os.replace`. A different file, read afresh."""
    a, b = str(tmp_path / "a.db"), str(tmp_path / "b.db")
    _corpus(a, seed=1)
    _corpus(b, seed=2)
    q = _unit(random.Random(13))
    with IndexStore(b, migrate=False) as ref:
        expected = _key(ref._vector_scan(q, KEY, 3, [], []))
    with _reader(a) as s:
        assert _key(s.vector_search(q, KEY, k=3)) != expected
    os.replace(b, a)
    _forbid_scan(monkeypatch)
    with _reader(a) as s:
        assert _key(s.vector_search(q, KEY, k=3)) == expected


def test_two_copies_with_equal_generations_are_told_apart(tmp_path: Path, monkeypatch) -> None:
    """The agent-snapshot shape. Both copies are `VACUUM INTO` the same index, so they share its
    epoch; each then removes one vector, so their `n` is equal too, and their vectors are not.
    Swapped in at one path in turn, only the file's identity tells the two apart."""
    live, a, b, served = (str(tmp_path / f"{n}.db") for n in ("live", "a", "b", "served"))
    _corpus(live)
    q = _unit(random.Random(26))
    best = _plant_best(live, "zz-best", q)
    with IndexStore(live, migrate=False) as s:
        runner_up = s.vector_search(q, KEY, k=2)[1].chunk_id
        s.db.execute("VACUUM INTO ?", (a,))
        s.db.execute("VACUUM INTO ?", (b,))
    with IndexStore(a) as w:
        w.db.execute("DELETE FROM chunk_vectors WHERE chunk_id = ?", (runner_up,))
    with IndexStore(b) as w:
        w.db.execute("DELETE FROM chunk_vectors WHERE chunk_id = ?", (best,))
    gens = [sqlite3.connect(p).execute("SELECT epoch, n FROM vector_generation").fetchone()
            for p in (a, b)]
    assert gens[0] == gens[1], "the premise: two different states under one generation"
    _forbid_scan(monkeypatch)
    os.replace(a, served)
    with _reader(served) as s:
        assert s.vector_search(q, KEY, k=1)[0].chunk_id == best
    os.replace(b, served)
    with _reader(served) as s:
        assert s.vector_search(q, KEY, k=1)[0].chunk_id == runner_up


def test_a_rebuilt_index_cannot_repeat_an_old_generation(tmp_path: Path, monkeypatch) -> None:
    """A schema migration drops and rebuilds every table IN the same file, and `n` restarts.
    Forcing `n` back to its old value must leave the epoch able to say, on its own, that the
    vectors are not the ones the held matrix was read from. Two other facts would also catch this
    rebuild, so both are held still here: the schema cookie (the rebuild moves it), and the file's
    identity (on Linux its ctime moves with the write; on macOS birth time does not)."""
    from substrate.store import index_store

    real_id = index_store._file_id
    monkeypatch.setattr(index_store, "_file_id",
                        lambda path: real_id(path) and real_id(path)[:2] + (0,))
    real_gen = IndexStore._vector_generation
    monkeypatch.setattr(IndexStore, "_vector_generation",
                        lambda self: (g := real_gen(self)) and (g[0], g[1], 0))
    p = str(tmp_path / "r.db")
    _corpus(p, seed=27)
    q = _unit(random.Random(28))
    with _reader(p) as s:
        s.vector_search(q, KEY, k=1)
        old_n = s.db.execute("SELECT n FROM vector_generation").fetchone()[0]
        fid = s.file_id
    with IndexStore(p) as w:
        w.db.execute("PRAGMA user_version=1")
    with IndexStore(p) as w:
        assert w.rebuilt
        (cid,) = _doc(w, "rebuilt", ["after the rebuild"])
        w.store_vectors([(cid, q)], KEY)
        w.db.execute("UPDATE vector_generation SET n = ?", (old_n,))
    _forbid_scan(monkeypatch)
    with _reader(p) as s:
        assert s.file_id == fid, "the premise: an identity the rebuild does not move"
        assert [h.chunk_id for h in s.vector_search(q, KEY, k=3)] == [cid]


class _NoBirthTime:
    """An `os.stat` result as Linux gives it: everything but `st_birthtime`."""

    def __init__(self, st: os.stat_result) -> None:
        self._st = st

    def __getattr__(self, name: str):
        if name == "st_birthtime":
            raise AttributeError(name)
        return getattr(self._st, name)


def _past_a_clock_tick() -> None:
    """Linux stamps ctime from a coarse clock, a few ms per tick, so two writes inside one tick
    share a ctime. A test that needs the next write to move it waits one out first."""
    import time

    time.sleep(0.05)


@pytest.fixture
def no_birth_time(monkeypatch):
    """Linux's stat on any platform, so the fallback is tested where the suite runs, not only on
    the CI job that has it natively."""
    real = os.stat
    monkeypatch.setattr(os, "stat", lambda *a, **kw: _NoBirthTime(real(*a, **kw)))


def test_the_file_identity_is_birth_time_where_there_is_one_and_ctime_elsewhere(
        db: str, no_birth_time) -> None:
    from substrate.store import index_store

    st = os.stat(db)
    assert index_store._file_id(db) == (st.st_dev, st.st_ino, st.st_ctime_ns)


def test_without_birth_time_reads_hit_until_a_write_open(db: str, no_birth_time,
                                                         monkeypatch) -> None:
    """What the cache does on Linux. Reads with no write between them share one matrix. A
    write-open moves ctime even when it changes nothing (a no-op compose re-stamps the schema
    version), so the next read loads the matrix again, and answers the same."""
    q = _unit(random.Random(32))
    key = (os.path.realpath(db), KEY, DIM, False)
    _forbid_scan(monkeypatch)
    with _reader(db) as s:
        first = _key(s.vector_search(q, KEY, k=5))
    held = vector_matrix._ENTRIES[key]
    with _reader(db) as s:
        assert _key(s.vector_search(q, KEY, k=5)) == first
        generation = s._vector_generation()
    assert vector_matrix._ENTRIES[key] is held, "no write between them: the same matrix"
    ctime = os.stat(db).st_ctime_ns
    _past_a_clock_tick()
    IndexStore(db).close()                       # what every refresh pass's compose does
    assert os.stat(db).st_ctime_ns != ctime, "the premise: the write-open moved ctime"
    with _reader(db) as s:
        assert s._vector_generation() == generation, "the premise: only the identity moved"
        assert _key(s.vector_search(q, KEY, k=5)) == first
    assert vector_matrix._ENTRIES[key] is not held, "ctime moved: read again"


def test_with_the_identity_held_still_a_commit_is_still_seen(db: str, monkeypatch) -> None:
    """On Linux a ctime that does not move (same tick, or a write still in the WAL) leaves the
    generation as the only witness of an in-place change. It must suffice on its own."""
    from substrate.store import index_store

    real_id = index_store._file_id
    monkeypatch.setattr(index_store, "_file_id",
                        lambda path: real_id(path) and real_id(path)[:2] + (0,))
    q = _unit(random.Random(35))
    with _reader(db) as s:
        before = s.vector_search(q, KEY, k=1)[0].chunk_id
        fid = s.file_id
    best = _plant_best(db, "zz-held-still", q)
    assert best != before
    _forbid_scan(monkeypatch)
    with _reader(db) as s:
        assert s.file_id == fid, "the premise: the identity did not move"
        assert s.vector_search(q, KEY, k=1)[0].chunk_id == best


def test_without_birth_time_a_rebuild_in_place_is_still_seen(tmp_path: Path, no_birth_time,
                                                            monkeypatch) -> None:
    """The rebuild the epoch test pins the identity for, with the identity Linux really has: it
    moves with the write, so the rebuild is caught twice over."""
    p = str(tmp_path / "r.db")
    _corpus(p, seed=33)
    q = _unit(random.Random(34))
    with _reader(p) as s:
        s.vector_search(q, KEY, k=1)
        fid = s.file_id
    _past_a_clock_tick()
    with IndexStore(p) as w:
        w.db.execute("PRAGMA user_version=1")
    with IndexStore(p) as w:
        assert w.rebuilt
        (cid,) = _doc(w, "rebuilt", ["after the rebuild"])
        w.store_vectors([(cid, q)], KEY)
    _forbid_scan(monkeypatch)
    with _reader(p) as s:
        assert s.file_id != fid
        assert [h.chunk_id for h in s.vector_search(q, KEY, k=3)] == [cid]


def _pre_trigger_ddl() -> tuple[str, str]:
    """(DDL, DROP) as an engine from before `vector_generation` had them."""
    import re

    from substrate.store import schema

    ddl = re.sub(r"CREATE TABLE IF NOT EXISTS vector_generation.*?END;\s*CREATE TRIGGER.*?END;"
                 r"\s*CREATE TRIGGER.*?END;", "", schema.DDL, flags=re.S)
    assert "vector_generation" not in ddl and "CREATE TRIGGER IF NOT EXISTS chunk_vectors" not in ddl
    return ddl, schema.DROP.replace("DROP TABLE IF EXISTS vector_generation;", "")


def test_an_older_engines_rebuild_never_serves_the_old_matrix(tmp_path: Path, monkeypatch) -> None:
    """Reproduced in review. The deployed v10 pin migrates the file, then a v11 engine from before
    the triggers migrates it back and embeds. Neither DROP removes `vector_generation`, so the old
    (epoch, n) survives on the same file, and the rebuilt `chunk_vectors` has no triggers to move
    it. A held matrix at that pair must not be served, then or after the triggers come back."""
    from substrate.store import schema

    p = str(tmp_path / "x.db")
    q = [1.0] + [0.0] * (DIM - 1)
    with IndexStore(p) as w:
        (a,) = _doc(w, "a", ["a"])
        (b,) = _doc(w, "b", ["b"])
        w.store_vectors([(a, q), (b, [0.0, 1.0] + [0.0] * (DIM - 2))], KEY)
    with _reader(p) as s:
        assert [h.chunk_id for h in s.vector_search(q, KEY, k=2)] == [a, b]
    old_ddl, old_drop = _pre_trigger_ddl()
    for version in (10, 11):
        con = sqlite3.connect(p, isolation_level=None)
        con.executescript(old_drop)
        con.executescript(old_ddl)
        con.execute(f"PRAGMA user_version={version}")
        con.close()
    monkeypatch.setattr(schema, "DDL", old_ddl)
    with IndexStore(p) as w:                     # the old engine composes and embeds
        _doc(w, "a", ["a"])
        _doc(w, "b", ["b"])
        w.store_vectors([(a, [0.0, 0.0, 1.0] + [0.0] * (DIM - 3)), (b, q)], KEY)
    monkeypatch.undo()
    with _reader(p) as s:
        assert [h.chunk_id for h in s.vector_search(q, KEY, k=2)] == [b, a]
    IndexStore(p).close()                        # this engine's next write-open restores them
    _forbid_scan(monkeypatch)
    with _reader(p) as s:
        assert [h.chunk_id for h in s.vector_search(q, KEY, k=2)] == [b, a]


def test_an_index_without_its_triggers_scans(db: str) -> None:
    """With any trigger gone, `n` is not known to have moved with every write, so it is no key."""
    con = sqlite3.connect(db)
    con.execute("DROP TRIGGER chunk_vectors_gen_ad")
    con.close()
    q = _unit(random.Random(31))
    with _reader(db) as s:
        expected = _key(s._vector_scan(q, KEY, 5, [], []))
        assert _key(s.vector_search(q, KEY, k=5, include_sources=True)) == expected
    assert not vector_matrix._ENTRIES


def test_an_immutable_read_is_never_served_to_a_normal_open(db: str, monkeypatch) -> None:
    """An immutable open takes no locks and ignores the WAL, so what it read is kept apart from
    what a normal open reads, even at one file and one generation."""
    q = _unit(random.Random(24))
    with IndexStore(db, migrate=False) as s:
        s.checkpoint()
    with IndexStore(db, migrate=False, immutable=True) as s:
        s.vector_search(q, KEY, k=1)
    with _reader(db) as s:
        s.vector_search(q, KEY, k=1)
    assert {k[3] for k in vector_matrix._ENTRIES} == {True, False}
    best = _plant_best(db, "zz-after-immutable", q)
    _forbid_scan(monkeypatch)
    with _reader(db) as s:
        assert s.vector_search(q, KEY, k=1)[0].chunk_id == best


def test_an_index_from_before_the_generation_scans_until_composed(db: str, monkeypatch) -> None:
    """A v11 file composed before `vector_generation` existed has none, so it scans. The next
    write-open (what `compose` does) adds the table and triggers in place, and it caches."""
    con = sqlite3.connect(db)
    con.executescript("DROP TABLE vector_generation; DROP TRIGGER chunk_vectors_gen_ai; "
                      "DROP TRIGGER chunk_vectors_gen_au; DROP TRIGGER chunk_vectors_gen_ad;")
    con.close()
    q = _unit(random.Random(29))
    with _reader(db) as s:
        expected = _key(s.vector_search(q, KEY, k=3))
    assert not vector_matrix._ENTRIES
    IndexStore(db).close()
    _forbid_scan(monkeypatch)
    with _reader(db) as s:
        assert _key(s.vector_search(q, KEY, k=3)) == expected
    assert vector_matrix._ENTRIES


def test_an_immutable_store_is_cached(db: str, scan_forbidden) -> None:
    with IndexStore(db, migrate=False) as s:
        s.checkpoint()
    with IndexStore(db, migrate=False, immutable=True) as s:
        assert s.file_id is not None
        assert s.vector_search(_unit(random.Random(14)), KEY, k=2)


def test_a_store_with_no_known_identity_scans(tmp_path: Path, scan_forbidden) -> None:
    """A file this open CREATED has no before-stat, so which file it reads is unproven."""
    with IndexStore(str(tmp_path / "new.db")) as s:
        assert s.file_id is None
        with pytest.raises(AssertionError, match="the scan ran"):
            s.vector_search([1.0] * DIM, KEY, k=1)


@pytest.mark.parametrize("filters", [
    {"statuses": DEFAULT_STATUSES},          # ~200 of 300 rows
    {"doc_id": "w04"},                       # 10 rows: where the BLAS product disagreed
    {"doc_id": "w07", "statuses": DEFAULT_STATUSES},
], ids=["most-rows", "one-doc", "one-doc-filtered"])
def test_scores_are_the_scans_to_the_bit_at_real_width(tmp_path: Path, filters) -> None:
    """At 1024 wide, `mat @ q` scored a row differently depending on how many rows were in the
    product and where the row sat, so a 10-row `doc_id` set disagreed with the whole matrix. Both
    paths score through `vector_matrix.cosines`, which reads each row alone."""
    p = str(tmp_path / "w.db")
    rng = random.Random(18)
    _wide_corpus(p, rng)
    with _reader(p) as s:
        for _ in range(8):
            expected, got = _scan_then_cached(s, _unit(rng, 1024), 300, **filters)
            assert expected and [h.score for h in got] == [h.score for h in expected]
            assert _key(got) == _key(expected)


def test_identical_vectors_score_identically_at_real_width(tmp_path: Path) -> None:
    """Identical text embeds to identical vectors. Under `mat @ q` two such rows nine apart could
    score differently, so the chunk_id tie rule never got to apply. Twelve copies, both paths."""
    p = str(tmp_path / "t.db")
    rng = random.Random(23)
    v = _unit(rng, 1024)
    with IndexStore(p) as w:
        ids = [cid for d in range(12) for cid in _doc(w, f"t{11 - d:02d}", ["same text"])]
        w.store_vectors([(cid, v) for cid in ids], KEY)
        for d in range(5):
            (other,) = _doc(w, f"u{d}", ["different"])
            w.store_vectors([(other, _unit(rng, 1024))], KEY)
    with _reader(p) as s:
        expected, got = _scan_then_cached(s, v, 6)     # the copies are the top 12; 6 get in
    assert len({h.score for h in got}) == 1
    assert [h.chunk_id for h in got] == [f"t{d:02d}#c00000" for d in range(6)]
    assert _key(got) == _key(expected)


# ---------------------------------------------------------------- ranking


def test_exact_ties_rank_by_chunk_id_on_both_paths(tmp_path: Path) -> None:
    """Identical text embeds to identical vectors. `argsort` put such ties in an order nobody
    chose; both paths now break them by chunk_id, including who gets the last slot."""
    p = str(tmp_path / "t.db")
    rng = random.Random(15)
    q = _unit(rng)
    with IndexStore(p) as w:
        ids = []
        for d in ("m", "c", "x", "a"):
            ids += _doc(w, d, ["same text"])
        w.store_vectors([(cid, q) for cid in ids], KEY)
        (other,) = _doc(w, "z", ["different"])
        w.store_vectors([(other, _unit(rng))], KEY)
    with _reader(p) as s:
        cached = [h.chunk_id for h in s.vector_search(q, KEY, k=3)]
        scanned = [h.chunk_id for h in s._vector_scan(q, KEY, 3, [], [])]
    assert cached == scanned == ["a#c00000", "c#c00000", "m#c00000"]


def test_k_larger_than_the_candidates_returns_them_all(db: str, scan_forbidden) -> None:
    with _reader(db) as s:
        hits = s.vector_search(_unit(random.Random(16)), KEY, k=10_000, doc_id="d01")
    assert len(hits) == 6


def test_k_zero_returns_nothing(db: str, scan_forbidden) -> None:
    with _reader(db) as s:
        assert s.vector_search(_unit(random.Random(17)), KEY, k=0) == []


# ---------------------------------------------------------------- bounds


def test_the_cache_holds_at_most_max_entries(tmp_path: Path, monkeypatch) -> None:
    monkeypatch.setattr(vector_matrix, "MAX_ENTRIES", 2)
    paths = [str(tmp_path / f"{i}.db") for i in range(3)]
    for p in paths:
        _corpus(p)
    for p in paths:
        with _reader(p) as s:
            s.vector_search([1.0] + [0.0] * (DIM - 1), KEY, k=1)
    held = {k[0] for k in vector_matrix._ENTRIES}
    assert held == {os.path.realpath(p) for p in paths[1:]}


# ---------------------------------------------------------------- the generation (`vector_generation`)


def _gen(path: str) -> tuple[str, int]:
    return tuple(sqlite3.connect(path).execute("SELECT epoch, n FROM vector_generation").fetchone())


@pytest.mark.parametrize("write", [
    lambda w, c: w.store_vectors([(c, [1.0] + [0.0] * (DIM - 1))], KEY),       # INSERT OR REPLACE
    lambda w, c: w.db.execute("UPDATE chunk_vectors SET dim = dim WHERE chunk_id = ?", (c,)),
    lambda w, c: w.db.execute("DELETE FROM chunk_vectors WHERE chunk_id = ?", (c,)),
    lambda w, c: w.drop_vectors("another#raw"),
    lambda w, c: w.remove(c.split("#")[0]),                                     # a note removed
], ids=["replace", "update", "delete", "drop-model", "remove-doc"])
def test_every_write_to_the_vectors_moves_the_generation(db: str, write) -> None:
    epoch, n = _gen(db)
    with IndexStore(db) as w:
        write(w, "d05#c00000")
    assert _gen(db)[0] == epoch and _gen(db)[1] > n


def test_each_index_draws_its_own_epoch(tmp_path: Path) -> None:
    a, b = str(tmp_path / "a.db"), str(tmp_path / "b.db")
    for p in (a, b):
        IndexStore(p).close()
    assert _gen(a)[0] != _gen(b)[0]
    assert _gen(a)[1] == _gen(b)[1] == 0


def _pack(v: list[float]) -> bytes:
    import struct
    return struct.pack(f"{len(v)}f", *v)
