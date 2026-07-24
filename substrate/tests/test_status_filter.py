"""A20 — the default-retrieval status filter excludes EXACTLY archived + superseded.

"Green gates, silent loss" in its status form: a filter that drops one document more (or fewer)
than intended and still returns plausible results. These pin the filter to the Doc-2 §6 partition
and pin `assert_status_partition` to catching a drift the filter itself cannot see (an unknown
status, or a chunk whose denormalized currency disagrees with its note).

Runnable with plain `python tests/test_status_filter.py`; discovered by pytest if added.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.models import Chunk, Document  # noqa: E402
from substrate.spine import EXCLUDED_STATUSES, INCLUDED_STATUSES  # noqa: E402
from substrate.store.index_store import IndexStore, StatusPartitionError  # noqa: E402


def _fresh_db() -> str:
    return str(Path(tempfile.mkdtemp()) / "index.db")


def _put(store: IndexStore, doc_id: str, status: str, text: str) -> None:
    doc = Document(
        doc_id=doc_id, source_path=f"/{doc_id}.md", source_sha256="s" * 8, source_pages=1,
        document_class="reference-frozen", title=doc_id, status=status,
    )
    ch = Chunk(chunk_id=f"{doc_id}#c0", doc_id=doc_id, kind="passage", text=text,
               path=["Root", doc_id], level=2, n_chars=len(text), document_class="reference-frozen")
    store.upsert(doc, [ch], markdown_path=f"/{doc_id}.md", markdown_mtime=0.0,
                 markdown_sha256="m" * 8)


def _seed(store: IndexStore) -> None:
    # One document per status; every text shares the token 'partition' so one query reaches all.
    _put(store, "a_active", "active", "partition alpha active body")
    _put(store, "c_complete", "complete", "partition charlie complete body")
    _put(store, "r_archived", "archived", "partition romeo archived body")
    _put(store, "s_superseded", "superseded", "partition sierra superseded body")


def test_default_set_excludes_archived_and_superseded() -> None:
    with IndexStore(_fresh_db()) as s:
        _seed(s)
        hits = s.search("partition", k=10, statuses=INCLUDED_STATUSES)
        got = {h.doc_id for h in hits}
        assert got == {"a_active", "c_complete"}, got


def test_none_means_unfiltered() -> None:
    with IndexStore(_fresh_db()) as s:
        _seed(s)
        got = {h.doc_id for h in s.search("partition", k=10, statuses=None)}
        assert got == {"a_active", "c_complete", "r_archived", "s_superseded"}, got


def test_include_archived_adds_only_archived() -> None:
    with IndexStore(_fresh_db()) as s:
        _seed(s)
        got = {h.doc_id for h in s.search("partition", k=10,
                                          statuses=INCLUDED_STATUSES | {"archived"})}
        assert got == {"a_active", "c_complete", "r_archived"}, got  # superseded still out


def test_empty_set_matches_nothing_not_everything() -> None:
    # The trap: IN () is a syntax error, and treating an empty set as "no filter" would invert the
    # meaning. An empty set must mean "include nothing".
    with IndexStore(_fresh_db()) as s:
        _seed(s)
        assert s.search("partition", k=10, statuses=frozenset()) == []


def test_partition_holds_and_reports_counts() -> None:
    with IndexStore(_fresh_db()) as s:
        _seed(s)
        rep = s.assert_status_partition()
        assert rep["included_chunks"] == 2 and rep["excluded_chunks"] == 2
        assert rep["total_chunks"] == 4
        assert rep["by_status"] == {"active": 1, "complete": 1, "archived": 1, "superseded": 1}


def test_partition_refuses_unknown_status() -> None:
    # An unknown status is silently excluded by IN (included); the audit must refuse it, not let it
    # vanish. Inject one directly, bypassing the ingest-time spine gate.
    with IndexStore(_fresh_db()) as s:
        _seed(s)
        s.db.execute("UPDATE documents SET status='bogus' WHERE doc_id='a_active'")
        s.db.execute("UPDATE chunks SET status='bogus' WHERE doc_id='a_active'")
        try:
            s.assert_status_partition()
        except StatusPartitionError:
            return
        raise AssertionError("expected StatusPartitionError for an unknown status")


def test_partition_refuses_denormalization_drift() -> None:
    # A chunk whose denormalized status disagrees with its document would leak or hide against a
    # browse of the note. The audit must catch the drift.
    with IndexStore(_fresh_db()) as s:
        _seed(s)
        s.db.execute("UPDATE chunks SET status='active' WHERE doc_id='r_archived'")
        try:
            s.assert_status_partition()
        except StatusPartitionError:
            return
        raise AssertionError("expected StatusPartitionError for chunk/doc status drift")


def test_included_and_excluded_are_complementary() -> None:
    # The two constants must partition the four statuses with no overlap and no gap — the property
    # the SQL filter's "two independent ways" check relies on.
    from substrate.spine import STATUSES
    assert INCLUDED_STATUSES | EXCLUDED_STATUSES == STATUSES
    assert INCLUDED_STATUSES & EXCLUDED_STATUSES == frozenset()


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
