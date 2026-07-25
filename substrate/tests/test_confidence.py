"""The confidence spine axis (Doc 2 §6b) — settledness, independent of status.

`status` answers "is this note live?"; `confidence` answers "why should I believe it?". The pair a
single axis cannot express is `active` + `proposed`: a design that is current and was never built.
Before this field, that note retrieved reading as settled — WRITING.md rule 6 ("preserve confidence
markers") with no carrier past the note body, which is the Boundary Principle's own failure shape
applied to the vault layer.

What is pinned here:

  * absence is `unstated` — a REAL, stored, surfaced value on every path, never a NULL and never
    coerced to something confident. This is the property that makes the axis honest; a default of
    `verified` (or a silently-dropped field) would BE the laundering it exists to stop.
  * confidence is OPTIONAL everywhere — deliberately not gated on require_status, unlike doc_type,
    because forcing a value per note during migration produces guessed markers.
  * an unknown value is refused on every path, including a certainty word like `high` — the axis
    that the source vaults actually wrote, and the one this field is NOT.
  * status and confidence are genuinely independent: every (status, confidence) pair is legal.
  * A23 catches an invalid value and chunk↔document drift on the stored rows.

Runnable with plain `python tests/test_confidence.py`.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.markdown.ingest import ingest_markdown  # noqa: E402
from substrate.markdown.reader import read_markdown  # noqa: E402
from substrate.models import Chunk, Document  # noqa: E402
from substrate.spine import (  # noqa: E402
    CONFIDENCES,
    STORED_CONFIDENCES,
    UNSTATED_CONFIDENCE,
    SpineError,
    validate_confidence,
)
from substrate.store.index_store import ConfidenceError, IndexStore  # noqa: E402


def _doc(confidence: str | None, doc_id: str = "d1") -> Document:
    return Document(doc_id=doc_id, source_path="x.md", source_sha256="0" * 64,
                    source_pages=1, document_class="reference-frozen", blocks=[],
                    status="active", doc_type="reference", confidence=confidence)


def _note(tmp: Path, name: str, front: str) -> Path:
    p = tmp / name
    p.write_text(f"---\n{front}\n---\n\n# {name[:-3]}\n\nA body with several real sentences in it. " * 3)
    return p


# ---------------------------------------------------------------- the vocabulary


def test_every_declared_value_validates() -> None:
    for c in sorted(CONFIDENCES):
        assert validate_confidence(_doc(c)) == c


def test_absent_becomes_unstated_not_something_confident() -> None:
    """The load-bearing default. Absence must never acquire a settledness the note never claimed."""
    for absent in (None, ""):
        assert validate_confidence(_doc(absent)) == UNSTATED_CONFIDENCE
    assert UNSTATED_CONFIDENCE not in CONFIDENCES, "unstated is storable but never declarable-with-meaning"
    assert UNSTATED_CONFIDENCE in STORED_CONFIDENCES


def test_certainty_words_are_refused() -> None:
    """`confidence: high` is what the real source vault writes — a CERTAINTY scale, a different
    axis. Carrying it would put a value on every chunk that no reader or filter can act on."""
    for bad in ("high", "medium", "low", "very high"):
        try:
            validate_confidence(_doc(bad))
        except SpineError as e:
            assert "settled" in str(e).lower(), e
        else:
            raise AssertionError(f"expected SpineError for confidence={bad!r}")


def test_unknown_value_refused() -> None:
    for bad in ("ratified", "provisional", "PROPOSED", "true"):
        try:
            validate_confidence(_doc(bad))
        except SpineError:
            pass
        else:
            raise AssertionError(f"expected SpineError for confidence={bad!r}")


# ---------------------------------------------------------------- independence from status


def test_status_and_confidence_are_independent_axes() -> None:
    """Every pair is legal — most importantly (active, proposed), the pair that motivated the
    field. A rule that coupled them would re-collapse the axes."""
    from substrate.spine import STATUSES, validate_status
    for st in sorted(STATUSES):
        for cf in sorted(CONFIDENCES):
            d = _doc(cf)
            d.status = st
            d.superseded_by = "other" if st == "superseded" else None
            assert validate_status(d, require_present=True) == st
            assert validate_confidence(d) == cf


# ---------------------------------------------------------------- the ingest paths


def test_confidence_is_optional_on_the_strict_vault_path() -> None:
    """Unlike doc_type, an absent confidence must NOT fail the strict path: forcing a value per
    note during migration produces guessed markers, which are worse than absent ones."""
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp, "a.md", "status: active\ndoc_type: reference")
    r = ingest_markdown(note, tmp / "out", require_status=True)
    assert r.confidence == UNSTATED_CONFIDENCE, r.confidence
    assert r.run["spine"]["confidence"] == UNSTATED_CONFIDENCE


def test_declared_confidence_survives_ingest_into_the_run_spine() -> None:
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp, "b.md", "status: active\ndoc_type: decision\nconfidence: proposed")
    r = ingest_markdown(note, tmp / "out", require_status=True)
    assert r.confidence == "proposed"
    assert r.run["spine"]["confidence"] == "proposed"


def test_reader_parses_confidence_without_deciding_strictness() -> None:
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp, "c.md", "status: active\ndoc_type: reference\nconfidence: verified")
    doc, _body, _stats = read_markdown(note)
    assert doc.confidence == "verified"
    absent, _b, _s = read_markdown(_note(tmp, "d.md", "status: active\ndoc_type: reference"))
    assert absent.confidence is None, "the reader must not invent a value; the gate does that"


def test_bad_confidence_refuses_the_ingest() -> None:
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp, "e.md", "status: active\ndoc_type: reference\nconfidence: high")
    try:
        ingest_markdown(note, tmp / "out", require_status=True)
    except SpineError:
        pass
    else:
        raise AssertionError("expected SpineError for a certainty word on the settledness axis")


# ---------------------------------------------------------------- A23, over stored rows


def _seed(store: IndexStore, doc_id: str, confidence: str | None) -> None:
    d = _doc(confidence, doc_id=doc_id)
    c = Chunk(chunk_id=f"{doc_id}#c1", doc_id=doc_id, kind="passage", text="body text here",
              path=[doc_id], page_start=1, page_end=1)
    store.upsert(d, [c], markdown_path="x.md", markdown_mtime=0.0, markdown_sha256="0" * 64)


def _db() -> str:
    return str(Path(tempfile.mkdtemp()) / "i.db")


def test_a23_passes_and_counts_a_clean_corpus() -> None:
    with IndexStore(_db()) as s:
        _seed(s, "a", "proposed")
        _seed(s, "b", None)          # → unstated
        _seed(s, "c", "verified")
        rep = s.assert_confidence_valid()
        assert rep["by_confidence"] == {"proposed": 1, "unstated": 1, "verified": 1}, rep


def test_a23_refuses_an_unknown_stored_value() -> None:
    with IndexStore(_db()) as s:
        _seed(s, "a", "proposed")
        s.db.execute("UPDATE documents SET confidence='high' WHERE doc_id='a'")
        s.db.execute("UPDATE chunks SET confidence='high' WHERE doc_id='a'")
        s.db.commit()
        try:
            s.assert_confidence_valid()
        except ConfidenceError:
            return
        raise AssertionError("expected ConfidenceError for a stored value outside the vocabulary")


def test_a23_refuses_chunk_document_drift() -> None:
    """A drifted chunk would state a settledness its note never claimed — the exact failure."""
    with IndexStore(_db()) as s:
        _seed(s, "a", "proposed")
        s.db.execute("UPDATE chunks SET confidence='verified' WHERE doc_id='a'")
        s.db.commit()
        try:
            s.assert_confidence_valid()
        except ConfidenceError as e:
            assert "drift" in str(e).lower() or "never claimed" in str(e).lower(), e
            return
        raise AssertionError("expected ConfidenceError for chunk↔document drift")


def test_chunks_confidence_cannot_be_null() -> None:
    """The NOT NULL constraint, not the NOT IN query, is what rules out a NULL — SQL
    `NULL NOT IN (…)` is NULL, not true, so the query alone would not see one."""
    import sqlite3
    with IndexStore(_db()) as s:
        _seed(s, "a", "proposed")
        try:
            s.db.execute("UPDATE chunks SET confidence=NULL WHERE doc_id='a'")
        except sqlite3.IntegrityError:
            return
        raise AssertionError("chunks.confidence must be NOT NULL")


def test_confidence_reaches_the_hit() -> None:
    """The whole point: it must cross the boundary onto the retrieved passage."""
    with IndexStore(_db()) as s:
        _seed(s, "a", "proposed")
        hits = s.search("body text here", k=1)
        assert hits, "expected a hit"
        assert hits[0].confidence == "proposed", hits[0].confidence


# ---------------------------------------------------------------- the round trip


def test_emitted_markdown_round_trips_both_new_axes() -> None:
    """§3b makes re-ingestion a DESIGNED operation (index regenerates from markdown, markdown from
    raw), so an axis missing from emit's frontmatter is laundered on every regeneration cycle — by
    the engine, on its own artifact. A proposed decision must not return as an unstated reference."""
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp, "r.md", "status: active\ndoc_type: decision\nconfidence: proposed")
    first = ingest_markdown(note, tmp / "out1", require_status=True)
    assert (first.status, first.doc_type, first.confidence) == ("active", "decision", "proposed")

    emitted = tmp / "out1" / "document.md"
    doc, _b, _s = read_markdown(emitted)
    assert doc.doc_type == "decision", f"emit dropped doc_type: {doc.doc_type!r}"
    assert doc.confidence == "proposed", f"emit dropped confidence: {doc.confidence!r}"

    second = ingest_markdown(emitted, tmp / "out2", require_status=True)
    assert (second.status, second.doc_type, second.confidence) == ("active", "decision", "proposed"), (
        f"round trip laundered the spine: {second.status}/{second.doc_type}/{second.confidence}")


def test_absent_confidence_stays_absent_through_the_round_trip() -> None:
    """`unstated` must NOT be written into the emitted frontmatter: the reader has to keep "the note
    said nothing" distinguishable from "the note said unstated", or absence becomes a declaration."""
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp, "s.md", "status: active\ndoc_type: reference")
    ingest_markdown(note, tmp / "out1", require_status=True)
    emitted = (tmp / "out1" / "document.md").read_text()
    assert "confidence:" not in emitted, f"emit invented a confidence line:\n{emitted[:300]}"
    doc, _b, _s = read_markdown(tmp / "out1" / "document.md")
    assert doc.confidence is None


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
