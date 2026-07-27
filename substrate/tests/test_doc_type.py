"""A21 — doc_type validity + denormalization integrity (Doc 2 §6a).

doc_type is the note-job axis; the vocabulary is `spine.DOC_TYPES`. The seed below restates it as a
literal and `test_valid_doc_types_pass_and_report_counts` asserts the two AGREE, so adding a value
without seeding it fails loudly here rather than going untested. Unlike
status it has no default-retrieval partition — every job is retrievable — so A21 is validity plus
chunk↔document denormalization integrity, not a partition proof. These pin `assert_doc_type_valid`
to catching an unknown value and a drifted chunk, and confirm the job surfaces ON the hit so a
passage states its own job without a second query (the Boundary Principle).

Runnable with plain `python tests/test_doc_type.py`; discovered by pytest if added.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.models import Chunk, Document  # noqa: E402
from substrate.spine import DOC_TYPES, INCLUDED_STATUSES  # noqa: E402
from substrate.store.index_store import DocTypeError, IndexStore  # noqa: E402


def _fresh_db() -> str:
    return str(Path(tempfile.mkdtemp()) / "index.db")


def _put(store: IndexStore, doc_id: str, doc_type: str, text: str) -> None:
    doc = Document(
        doc_id=doc_id, source_path=f"/{doc_id}.md", source_sha256="s" * 8, source_pages=1,
        document_class="reference-frozen", title=doc_id, status="active", doc_type=doc_type,
    )
    ch = Chunk(chunk_id=f"{doc_id}#c0", doc_id=doc_id, kind="passage", text=text,
               path=["Root", doc_id], level=2, n_chars=len(text), document_class="reference-frozen")
    store.upsert(doc, [ch], markdown_path=f"/{doc_id}.md", markdown_mtime=0.0,
                 markdown_sha256="m" * 8)


def _seed(store: IndexStore) -> None:
    # One document per doc_type; every text shares the token 'passage' so one query reaches all.
    _put(store, "d_decision", "decision", "passage delta decision body")
    _put(store, "e_explanation", "explanation", "passage echo explanation body")
    _put(store, "r_reference", "reference", "passage romeo reference body")
    _put(store, "h_howto", "how-to", "passage hotel how-to body")
    _put(store, "g_digest", "digest", "passage golf digest body")


def test_valid_doc_types_pass_and_report_counts() -> None:
    with IndexStore(_fresh_db()) as s:
        _seed(s)
        rep = s.assert_doc_type_valid()
        assert rep["by_doc_type"] == {
            "decision": 1, "explanation": 1, "reference": 1, "how-to": 1, "digest": 1
        }, rep
        # The seed must cover the whole vocabulary, or this file passes while a value goes untested.
        assert set(rep["by_doc_type"]) == DOC_TYPES, (
            f"seed covers {sorted(rep['by_doc_type'])}, DOC_TYPES is {sorted(DOC_TYPES)}"
        )


def test_doc_type_defaults_reference_when_document_declares_none() -> None:
    # A directly-seeded document with no doc_type (the standalone corpus shape) defaults to
    # reference at upsert on BOTH tables, so A21 still passes rather than seeing a NULL.
    with IndexStore(_fresh_db()) as s:
        doc = Document(doc_id="bare", source_path="/bare.md", source_sha256="s", source_pages=1,
                       document_class="reference-frozen", title="bare", status="active")
        ch = Chunk(chunk_id="bare#c0", doc_id="bare", kind="passage", text="bare body",
                   path=["Root", "bare"], level=2, document_class="reference-frozen")
        s.upsert(doc, [ch], markdown_path="/bare.md", markdown_mtime=0.0, markdown_sha256="m")
        rep = s.assert_doc_type_valid()
        assert rep["by_doc_type"] == {"reference": 1}, rep


def test_doc_type_refuses_unknown() -> None:
    # An unknown doc_type is a phantom retrieval axis. Inject one directly, bypassing the
    # ingest-time spine gate, and the audit must refuse it rather than let it answer queries.
    with IndexStore(_fresh_db()) as s:
        _seed(s)
        s.db.execute("UPDATE documents SET doc_type='tutorial' WHERE doc_id='r_reference'")
        s.db.execute("UPDATE chunks SET doc_type='tutorial' WHERE doc_id='r_reference'")
        try:
            s.assert_doc_type_valid()
        except DocTypeError:
            return
        raise AssertionError("expected DocTypeError for an unknown doc_type")


def test_doc_type_refuses_denormalization_drift() -> None:
    # A chunk whose denormalized job disagrees with its document would answer a doc_type query
    # under a job its note does not do. The audit must catch the drift.
    with IndexStore(_fresh_db()) as s:
        _seed(s)
        s.db.execute("UPDATE chunks SET doc_type='reference' WHERE doc_id='d_decision'")
        try:
            s.assert_doc_type_valid()
        except DocTypeError:
            return
        raise AssertionError("expected DocTypeError for chunk/doc doc_type drift")


def test_doc_type_surfaces_on_the_hit() -> None:
    # The Boundary Principle: a retrieved passage states its own job without a second query.
    with IndexStore(_fresh_db()) as s:
        _seed(s)
        hits = s.search("passage", k=10, statuses=INCLUDED_STATUSES)
        by_id = {h.doc_id: h.doc_type for h in hits}
        assert by_id["d_decision"] == "decision", by_id
        assert by_id["h_howto"] == "how-to", by_id


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
