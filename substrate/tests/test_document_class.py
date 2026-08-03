"""`document_class` absence — the axis that had no way to say "undeclared".

The three classes in `classes.POLICIES` describe INGESTED SOURCES: a published edition, a living
spec, a captured conversation. A hand-written vault note is none of them, and the vocabulary had no
value for that, so the markdown reader defaulted an absent `class:` to `reference-frozen`. Measured
2026-07-30 over the operator's seven vaults: 83 of 684 notes declare a class. The other ~88% were
labelled "a published edition that will not change" — including design decisions, how-tos and
session notes — and commit a711267 put that label on the wire, where the client draws it as a spine
axis a reader believes.

`confidence` is the template and the fix is its absence half: `classes.UNCLASSIFIED_CLASS`.

What is pinned here, each property being one way the fix could be undone silently:

  * absence resolves to `unclassified` AT THE GATE, not in the reader — so a declared value and an
    absent one stay distinguishable all the way to the store and the wire.
  * a DECLARED `reference-frozen` still stores `reference-frozen`. The three notes in the real
    corpus that declare it must not be swept up by the relabel.
  * `unclassified` is storable but NEVER declarable, exactly as `unjudged` is not.
  * it is NOT withheld from default retrieval. Withholding on absence would empty the default set
    for most of the corpus while every A-series assertion stayed green.
  * it carries reference-frozen's CHUNK GEOMETRY verbatim, so the recompose this change forces is a
    relabel and not a re-chunk — different geometry would move every chunk_id and expand_ref.
  * it round-trips through emitted markdown AS ABSENCE, so a §3b regeneration cycle cannot launder
    an undeclared note into a declared one.

Runnable with plain `python tests/test_document_class.py`.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import classes  # noqa: E402
from substrate.classes import (  # noqa: E402
    DECLARABLE_CLASSES,
    EXCLUDED_CLASSES,
    POLICIES,
    UNCLASSIFIED_CLASS,
    ClassPolicyError,
)
from substrate.markdown.emit import frontmatter  # noqa: E402
from substrate.markdown.ingest import ingest_markdown  # noqa: E402
from substrate.markdown.reader import read_markdown  # noqa: E402
from substrate.models import Block, Document, Kind  # noqa: E402
from substrate.store.index_store import IndexStore  # noqa: E402
from substrate.store.reconcile import reconcile  # noqa: E402

BODY = "A body sentence with real words in it. " * 8


def _doc(document_class: str, doc_id: str = "d1") -> Document:
    return Document(
        doc_id=doc_id, source_path="x.md", source_sha256="0" * 64, source_pages=1,
        document_class=document_class, blocks=[Block(id="b0", kind=Kind.HEADING, text="H", level=1)],
        title="H", status="active", doc_type="reference",
    )


def _note(tmp: Path, name: str, extra: dict[str, str]) -> Path:
    fm = {"status": "active", "doc_type": "reference", **extra}
    p = tmp / name
    p.write_text("---\n" + "\n".join(f"{k}: {v}" for k, v in fm.items())
                 + "\n---\n\n# Heading\n\n" + BODY)
    return p


# ---------------------------------------------------------------- the vocabulary


def test_the_absence_marker_is_a_policy_key_but_not_declarable() -> None:
    """Both halves matter and they pull in opposite directions.

    It must BE in POLICIES — `apply` and the chunker look a policy up by name, so a class without
    one cannot be gated or chunked. It must not be DECLARABLE — same reason `unjudged` is not: a
    note carrying it would assert that nobody classified it, which writing it contradicts.
    """
    assert UNCLASSIFIED_CLASS in POLICIES, (
        "the POLICIES key is a string LITERAL so the Swift contract gate can parse it out of this "
        "file; this is what pins it to the constant every other module imports")
    assert POLICIES[UNCLASSIFIED_CLASS].name == UNCLASSIFIED_CLASS
    assert UNCLASSIFIED_CLASS not in DECLARABLE_CLASSES
    assert DECLARABLE_CLASSES == frozenset(POLICIES) - {UNCLASSIFIED_CLASS}
    assert DECLARABLE_CLASSES, "there must still be classes an author can actually write"


def test_absence_resolves_to_the_marker_at_the_gate() -> None:
    for absent in ("", None):
        doc = _doc(absent)  # type: ignore[arg-type]
        assert classes.apply(doc)["document_class"] == UNCLASSIFIED_CLASS
        assert doc.document_class == UNCLASSIFIED_CLASS, (
            "apply must MUTATE the document: the chunker reads its policy off this field and the "
            "store denormalizes it onto every chunk")


def test_declaring_the_absence_marker_is_refused() -> None:
    try:
        classes.apply(_doc(UNCLASSIFIED_CLASS))
    except ClassPolicyError as e:
        assert UNCLASSIFIED_CLASS in str(e) and "cannot be declared" in str(e), e
    else:
        raise AssertionError(
            "declaring `class: unclassified` was accepted — the absence marker would then satisfy "
            "any future write gate with the value that means 'not classified'")


def test_a_declared_reference_frozen_survives_the_relabel() -> None:
    """THE REGRESSION THIS FILE EXISTS FOR, and the one no other row can catch.

    Every other class test declares a value the old default was not, so a restored
    `or "reference-frozen"` in the reader leaves them all green while relabelling the corpus again.
    Three notes in the operator's real vaults DECLARE reference-frozen; they must come out of the
    pipeline as declared, and an undeclared note beside them must not.
    """
    tmp = Path(tempfile.mkdtemp())
    declared, _b, _s = read_markdown(_note(tmp, "declared.md", {"class": "reference-frozen"}))
    absent, _b2, _s2 = read_markdown(_note(tmp, "absent.md", {}))
    assert declared.document_class == "reference-frozen"
    assert absent.document_class == "", "the reader must not invent a class"

    assert classes.apply(declared)["document_class"] == "reference-frozen"
    assert classes.apply(absent)["document_class"] == UNCLASSIFIED_CLASS
    assert declared.document_class != absent.document_class, (
        "a declared reference-frozen and an undeclared note are one value again — this is the "
        "defect, and it composes fully green")


# ---------------------------------------------------------------- what the class carries


def test_the_marker_carries_reference_frozens_chunk_geometry_verbatim() -> None:
    """Class DRIVES chunking. Different geometry would re-chunk the undeclared majority on the
    recompose this vocabulary change forces — new chunk_ids, every stored `expand_ref` dead, every
    embedding invalidated. A relabel must relabel and nothing else."""
    assert POLICIES[UNCLASSIFIED_CLASS].chunk == POLICIES["reference-frozen"].chunk


def test_the_marker_carries_the_same_required_fields_as_today() -> None:
    """The contract these notes are held to must not move in either direction: a note that ingests
    today must still ingest, and one that is refused today must still be refused."""
    assert (POLICIES[UNCLASSIFIED_CLASS].required_fields
            == POLICIES["reference-frozen"].required_fields)
    assert POLICIES[UNCLASSIFIED_CLASS].requires_version is False


def test_a_note_that_cannot_identify_itself_is_still_refused() -> None:
    """The required-field gate is unchanged, exercised rather than merely compared. A document with
    no title and no heading to derive one from fails the same way it did under the old default."""
    doc = Document(doc_id="d", source_path="x.md", source_sha256="0" * 64, source_pages=1,
                   document_class="", blocks=[], status="active", doc_type="reference")
    try:
        classes.apply(doc)
    except ClassPolicyError as e:
        assert "title" in str(e), e
    else:
        raise AssertionError("an untitled unclassified document was accepted")


# ---------------------------------------------------------------- retrieval semantics


def test_the_marker_is_not_withheld_from_default_retrieval() -> None:
    """Absence of a label is evidence about the LABEL, not about the note. Withholding it would
    empty the default retrieval set for most of the corpus — silently, because `sources_excluded`
    would still read true and every A-series assertion would still pass."""
    assert UNCLASSIFIED_CLASS not in EXCLUDED_CLASSES
    assert EXCLUDED_CLASSES == frozenset({"conversation"})


def test_an_unclassified_note_is_retrieved_and_says_so() -> None:
    """End to end against the store: the passage comes back on a default query AND carries the word.

    Not withheld and marked-as-undeclared are two different claims, and the second is the one the
    defect destroyed — a passage that arrives unmarked is indistinguishable from a settled one.
    """
    from substrate.render import passage as render_passage

    tmp = Path(tempfile.mkdtemp())
    ingest_markdown(_note(tmp, "n.md", {"doc_id": "bare-note"}), tmp / "out" / "n",
                    require_status=True)
    with IndexStore(str(tmp / "i.db")) as s:
        reconcile(s, tmp / "out")
        row = s.db.execute("SELECT document_class FROM documents WHERE doc_id=?",
                           ("bare-note",)).fetchone()
        assert row[0] == UNCLASSIFIED_CLASS, row[0]
        chunk_class = s.db.execute("SELECT document_class FROM chunks WHERE doc_id=? LIMIT 1",
                                   ("bare-note",)).fetchone()[0]
        assert chunk_class == UNCLASSIFIED_CLASS, (
            f"the denormalized chunk class diverged from its document: {chunk_class!r}")

        hits = s.search("body sentence words", k=5)
        assert any(h.doc_id == "bare-note" for h in hits), (
            "an unclassified note was withheld from default retrieval — that is ~88% of the corpus")
        hit = next(h for h in hits if h.doc_id == "bare-note")
        assert render_passage(hit, scope="t")["document_class"] == UNCLASSIFIED_CLASS, (
            "the wire dropped the absence marker, so the client cannot tell an undeclared note "
            "from a declared one — which is the whole defect, one layer further out")


# ---------------------------------------------------------------- round-trip


def test_the_marker_is_never_written_into_emitted_markdown() -> None:
    """§3b makes re-ingestion a designed operation, so the engine must not launder its own artifact.

    Writing `document_class: unclassified` would turn "declared nothing" into a declaration — which
    `apply` then refuses on the way back in, so the round-trip would not merely lie, it would fail.
    """
    doc = _doc("")
    classes.apply(doc)
    assert doc.document_class == UNCLASSIFIED_CLASS
    emitted = frontmatter(doc)
    assert "document_class" not in emitted, emitted

    declared = _doc("conversation")
    classes.apply(declared)
    assert "document_class: conversation" in frontmatter(declared), (
        "a REAL class must still be written, or re-ingestion silently unclassifies it")


def test_absence_round_trips_through_the_engines_own_markdown() -> None:
    """Read → apply → emit → read again. The absence must still be an absence at the far end."""
    tmp = Path(tempfile.mkdtemp())
    doc, _b, _s = read_markdown(_note(tmp, "rt.md", {"doc_id": "round-trip"}))
    classes.apply(doc)

    out = tmp / "emitted.md"
    out.write_text(frontmatter(doc) + "\n# Heading\n\n" + BODY)
    again, _b2, _s2 = read_markdown(out)
    assert again.document_class == "", (
        f"the emitted artifact declared a class the note never did: {again.document_class!r}")
    assert classes.apply(again)["document_class"] == UNCLASSIFIED_CLASS


def test_a_run_json_with_no_class_reconciles_to_the_marker_not_to_a_real_one() -> None:
    """The fallback in `reconcile`, which no ordinary ingest reaches: `apply` writes the key into
    every run.json it produces. Defaulting a classless artifact to `reference-frozen` would be a
    second copy of the reader bug, one layer further from the evidence."""
    import json as _json

    tmp = Path(tempfile.mkdtemp())
    ingest_markdown(_note(tmp, "legacy.md", {"doc_id": "legacy-note"}), tmp / "out" / "n",
                    require_status=True)
    run_path = tmp / "out" / "n" / "run.json"
    run = _json.loads(run_path.read_text())
    run["class"].pop("document_class")
    run_path.write_text(_json.dumps(run))

    with IndexStore(str(tmp / "i.db")) as s:
        reconcile(s, tmp / "out")
        stored = s.db.execute("SELECT document_class FROM documents WHERE doc_id=?",
                              ("legacy-note",)).fetchone()[0]
        assert stored == UNCLASSIFIED_CLASS, stored


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
