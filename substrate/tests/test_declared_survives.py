"""Declared values must survive parsing — the third failure shape.

The A-series validates values it RECEIVES. A value dropped upstream of the validator is
indistinguishable from a value never declared: the declaration and the default produce identical
downstream state, so every assertion passes on a corpus that is silently wrong.

Observed: six migrated conversations declared `class: conversation` — the spelling Doc 2 §3 uses and
`vault._source_meta` already maps — and the note reader honoured only `document_class:`. All six
fell through to the `reference-frozen` default and composed FULLY GREEN (A21, A22, A23 all passing).
The failure mode was not "conversations missing" but "conversations retrieved by default forever",
which is the exact opposite of what declaring the class was for, and looks completely normal.

The defense is narrow and cheap, and it is NOT "is the value valid" (spine.validate_* covers that):
**for every field where absence has a meaningful default, assert a declared value reaches the store
unchanged.** Note this is the mirror of the emit round-trip tests in test_confidence.py — that fix
was the EMITTER dropping declared values, this is the READER dropping them. Same defect, opposite
ends of the pipeline, and neither test implies the other.

Runnable with plain `python tests/test_declared_survives.py`.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.markdown.ingest import ingest_markdown  # noqa: E402
from substrate.markdown.reader import read_markdown  # noqa: E402
from substrate.store.index_store import IndexStore  # noqa: E402
from substrate.store.reconcile import reconcile  # noqa: E402

# (frontmatter key, declared value, Document attribute, a DIFFERENT default it must not become)
# Every row is a field whose absence has a meaningful default — which is exactly the set where a
# silent drop is invisible.
DECLARED = [
    ("status",         "complete",           "status",         "active"),
    ("doc_type",       "decision",           "doc_type",       "reference"),
    ("confidence",     "verified",           "confidence",     "unjudged"),
    ("document_class", "conversation",       "document_class", ""),
    ("class",          "conversation",       "document_class", ""),
    # The one class a note can declare that is ALSO what the old default invented. Nothing else in
    # this table can catch a regression to `or "reference-frozen"` in the reader: every other row
    # declares a value the default is not, so a restored default leaves them green while silently
    # relabelling the 91% again. A declared `reference-frozen` must survive as declared — see
    # `test_a_declared_reference_frozen_is_not_confused_with_an_absent_one`.
    ("class",          "reference-frozen",   "document_class", ""),
    ("title",          "A Declared Title",   "title",          None),
    ("doc_id",         "declared-doc-id",    "doc_id",         None),
    # §3b raw provenance. Doc 2 calls this system-contract, and it is the field this whole test
    # file exists to protect: a source ingested without its pointer has a silently-lost
    # regeneration path, indistinguishable from a source whose raw was deliberately discarded.
    ("raw",            "ddia-2e.pdf",        "raw",            None),
    ("raw_location",   "user-defined",       "raw_location",   None),
]

_SHA = "241254d3950e2a07e066bfa6471c40ec9bc24425085dacfe959d7f008fbe0452"


def _note(tmp: Path, name: str, extra: dict[str, str]) -> Path:
    fm = {"status": "active", "doc_type": "reference", **extra}
    p = tmp / name
    p.write_text("---\n" + "\n".join(f"{k}: {v}" for k, v in fm.items())
                 + "\n---\n\n# Heading\n\n" + "A body sentence with real words in it. " * 8)
    return p


def test_each_declared_field_reaches_the_document() -> None:
    """The reader must not silently drop a declared key. One field per note, so a drop cannot be
    masked by another field happening to carry the same value."""
    tmp = Path(tempfile.mkdtemp())
    for i, (key, value, attr, default) in enumerate(DECLARED):
        note = _note(tmp, f"n{i}.md", {key: value})
        doc, _body, _stats = read_markdown(note)
        got = getattr(doc, attr)
        assert got == value, (
            f"declared `{key}: {value}` did not reach Document.{attr} — got {got!r}. "
            f"{'It fell through to the default.' if got == default else ''} "
            "A declared value that is dropped upstream is invisible to every A-series assertion.")


def test_declared_values_reach_the_store_unchanged() -> None:
    """End to end: frontmatter → reader → ingest → run.json → reconcile → store. The drop that
    started this was between the first two steps, but any stage could swallow one."""
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp, "full.md", {
        "doc_id": "round-trip-note", "title": "Round Trip",
        "status": "complete", "doc_type": "decision", "confidence": "verified",
    })
    ingest_markdown(note, tmp / "out" / "n", require_status=True)
    with IndexStore(str(tmp / "i.db")) as s:
        reconcile(s, tmp / "out")
        row = s.db.execute(
            "SELECT status, doc_type, confidence, title FROM documents WHERE doc_id=?",
            ("round-trip-note",)).fetchone()
        assert row is not None, "the declared doc_id never reached the store"
        assert tuple(row) == ("complete", "decision", "verified", "Round Trip"), tuple(row)
        chunk = s.db.execute(
            "SELECT status, doc_type, confidence FROM chunks WHERE doc_id=? LIMIT 1",
            ("round-trip-note",)).fetchone()
        assert tuple(chunk) == ("complete", "decision", "verified"), (
            f"denormalized chunk spine diverged from the declaration: {tuple(chunk)}")


def test_the_class_alias_that_caused_this() -> None:
    """Doc 2 §3 writes `class:`; the reader originally honoured only `document_class:`. Both must
    work, or the vault format means different things in different files and the unread spelling
    defaults silently."""
    tmp = Path(tempfile.mkdtemp())
    for key in ("class", "document_class"):
        doc, _b, _s = read_markdown(_note(tmp, f"{key}.md", {key: "conversation"}))
        assert doc.document_class == "conversation", (
            f"`{key}: conversation` was dropped — it became {doc.document_class!r}, which is "
            "retrieved by DEFAULT, so the failure is silent inclusion rather than absence")


def test_an_undeclared_field_still_takes_its_default() -> None:
    """The guard must not accidentally require declaration — absence is legal and meaningful.

    Both axes resolve at the GATE and not in the reader, which is the property that keeps "declared"
    and "absent" separable: the reader leaves confidence None and the class empty, `spine` and
    `classes` decide what each becomes.
    """
    tmp = Path(tempfile.mkdtemp())
    doc, _b, _s = read_markdown(_note(tmp, "bare.md", {}))
    assert doc.confidence is None, "the reader must not invent a confidence"
    assert doc.document_class == "", "the reader must not invent a document_class"
    r = ingest_markdown(_note(tmp, "bare2.md", {}), tmp / "out2", require_status=True)
    assert r.confidence == "unjudged", "absence must resolve to unjudged at the gate, not earlier"
    assert r.run["class"]["document_class"] == "unclassified", (
        "an undeclared class must resolve to the absence marker at the class gate — "
        f"got {r.run['class']['document_class']!r}")


def test_every_meta_key_the_vault_maps_is_read_by_the_reader() -> None:
    """The two parsers must agree on vocabulary. `vault._source_meta` reads a source's `_meta.md`;
    `reader` reads a note's own frontmatter. A key one honours and the other ignores is the alias
    drift that produced the original bug — this pins the intersection so it cannot reopen."""
    import re
    root = Path(__file__).resolve().parent.parent / "substrate"
    reader_keys = set(re.findall(r'front\.get\("([a-z_]+)"', (root / "markdown/reader.py").read_text()))
    vault_keys = set(re.findall(r'front\.get\("([a-z_]+)"\)', (root / "vault.py").read_text()))
    missing = vault_keys - reader_keys
    assert not missing, (
        f"`_source_meta` maps {sorted(missing)} but the note reader ignores them — a note declaring "
        "one of those keys in its own frontmatter would silently take the default")


def test_raw_pointer_survives_to_the_store() -> None:
    """§3b provenance must reach the store, not merely parse. Nothing reads it yet — recording is
    what has a deadline, because every source ingested without a pointer loses its regeneration
    path silently."""
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp, "raw.md", {
        "doc_id": "raw-carrier", "title": "Carrier",
        "raw": "ddia-2e.pdf", "raw_sha256": _SHA, "raw_location": "user-defined",
    })
    ingest_markdown(note, tmp / "out" / "n", require_status=True)
    with IndexStore(str(tmp / "i.db")) as s:
        reconcile(s, tmp / "out")
        row = s.db.execute(
            "SELECT raw, raw_sha256, raw_location FROM documents WHERE doc_id=?",
            ("raw-carrier",)).fetchone()
        assert tuple(row) == ("ddia-2e.pdf", _SHA, "user-defined"), tuple(row)


def test_a_malformed_raw_digest_is_dropped_not_carried() -> None:
    """A pointer that cannot identify the file it names is worse than an absent one — it reads as
    provenance while being unusable. Same discipline as `unstated`: absent beats fabricated."""
    tmp = Path(tempfile.mkdtemp())
    doc, _b, _s = read_markdown(_note(tmp, "bad.md", {
        "raw": "ddia-2e.pdf", "raw_sha256": "not-a-real-digest"}))
    assert doc.raw == "ddia-2e.pdf", "the artifact name is still useful and must survive"
    assert doc.raw_sha256 is None, "a malformed digest must not be carried as if it were provenance"


def test_a_multi_valued_supersession_survives_the_whole_pipeline() -> None:
    """v8: `supersedes` is list-valued, and every stage has to carry ALL of it.

    This is the third law aimed at the field that motivated the bump. `substrate-topology` replaced
    two notes and could not say so, so the pair was recorded in prose — and the failure a scalar
    would reintroduce is not a crash but a QUIET TRUNCATION: one link survives, the payload is
    well-formed, and the note reads as having replaced exactly one thing. Asserting the whole list
    at both ends is the only check that can tell those apart.
    """
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp, "multi.md", {
        "doc_id": "live-note", "supersedes": "[dead-one, dead-two, dead-three]",
    })
    doc, _b, _s = read_markdown(note)
    assert doc.supersedes == ["dead-one", "dead-two", "dead-three"], doc.supersedes

    ingest_markdown(note, tmp / "out" / "n", require_status=True)
    with IndexStore(str(tmp / "i.db")) as s:
        reconcile(s, tmp / "out")
        hit = s.chunk(s.db.execute(
            "SELECT chunk_id FROM chunks WHERE doc_id=? LIMIT 1", ("live-note",)).fetchone()[0])
        assert hit.supersedes == ["dead-one", "dead-two", "dead-three"], (
            f"the supersession list was truncated on the way to a Hit: {hit.supersedes}")


def test_a_pre_v8_scalar_supersedes_still_reads() -> None:
    """Two notes in `scripta-vault` declare a bare `supersedes: old-note` (plus one in the repo's
    `demo-vault` fixture), and nobody is going to rewrite them — so the scalar form has to keep
    meaning what it always meant, a one-entry list, rather than becoming a parse failure."""
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp, "scalar.md", {"doc_id": "live-note", "supersedes": "dead-one"})
    doc, _b, _s = read_markdown(note)
    assert doc.supersedes == ["dead-one"], doc.supersedes


def test_a_malformed_supersession_entry_is_dropped_not_carried() -> None:
    """Per-element validation, mirroring the malformed-`raw_sha256` rule directly above: a link
    that cannot identify the note it names reads as provenance while being unusable. The LEGAL
    entries beside it must survive — dropping the whole list because one entry was bad would lose
    real supersession history to a typo."""
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp, "mixed.md", {
        "doc_id": "live-note",
        "supersedes": "[dead-one, Not A Doc Id, [[wikilink]], dead-two, dead-one]",
    })
    doc, _b, _s = read_markdown(note)
    assert doc.supersedes == ["dead-one", "dead-two"], doc.supersedes


def test_supersession_round_trips_through_emitted_markdown() -> None:
    """§3b makes re-ingestion a designed operation, so the emitter has to write the list back in
    the form the reader reads. A shape that only survives one direction is laundered on every
    regeneration cycle — by the engine, on its own artifact."""
    from substrate.markdown.emit import frontmatter

    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp, "rt.md", {"doc_id": "live-note", "supersedes": "[dead-one, dead-two]"})
    doc, _b, _s = read_markdown(note)

    emitted = tmp / "emitted.md"
    emitted.write_text(frontmatter(doc) + "\n# Heading\n\n" + "Body words repeated. " * 8)
    again, _b2, _s2 = read_markdown(emitted)
    # The literal is asserted as well as the agreement. Comparing only the two sides — both
    # produced by the same reader — stays green in any world where the reader is symmetrically
    # wrong, and truncating `doc_id_list` to one entry was verified to leave this test passing.
    assert again.supersedes == ["dead-one", "dead-two"] == doc.supersedes, (
        f"emit/read disagree: wrote {doc.supersedes}, read back {again.supersedes}")


def test_no_write_boundary_can_put_an_exploded_link_on_disk() -> None:
    """All three write boundaries, given the shape that breaks them.

    `Document.supersedes` is annotated `list[str]` and nothing enforces that at runtime, so the
    question is what each writer does when handed the pre-v8 scalar. `emit` is the one that
    matters most and was the last to be fixed: it writes into the OPERATOR'S VAULT, and
    `supersedes: [o, l, d, -, n, o, t, e]` is not merely wrong, it is durable — every fragment is
    a legal single-character doc_id, so it reads back clean forever instead of being refused.
    """
    import json as _json

    from substrate.markdown.emit import frontmatter
    from substrate.models import Document

    scalar = Document(doc_id="live-note", source_path="p", source_sha256="a" * 64, source_pages=1,
                      document_class="reference-frozen", status="active", doc_type="reference",
                      supersedes="dead-one")

    # 1. the vault-markdown boundary
    line = [ln for ln in frontmatter(scalar).splitlines() if ln.startswith("supersedes")]
    assert line == ["supersedes: [dead-one]"], line

    # 2. the store boundary
    tmp = Path(tempfile.mkdtemp())
    from substrate.models import Chunk
    with IndexStore(str(tmp / "i.db")) as s:
        s.upsert(scalar, [Chunk(chunk_id="live-note#c0", doc_id="live-note", kind="passage",
                                text="w " * 40, path=["T"], level=1, n_chars=80,
                                document_class="reference-frozen")],
                 markdown_path="m", markdown_mtime=0.0, markdown_sha256="d" * 64)
        stored = s.db.execute("SELECT supersedes FROM documents").fetchone()[0]
        assert _json.loads(stored) == ["dead-one"], stored
        # 3. and back out through the read path, which does not trust the column either.
        hit = s.chunk("live-note#c0")
        assert hit.supersedes == ["dead-one"], hit.supersedes

        # The read guard needs a value the WRITE guard cannot produce, or it is unfalsifiable:
        # upsert always stores a proper array, so nothing else can exercise it. A v7 row reaching
        # a v8 read is refused by the schema gate two modules away — this asserts the property
        # locally instead of inheriting it. `json.loads` returns an int here, not a list, and
        # every consumer below (`list(...)`, `','.join(...)`) assumes a sequence.
        s.db.execute("UPDATE documents SET supersedes='123' WHERE doc_id='live-note'")
        assert s.chunk("live-note#c0").supersedes == [], "a non-array column reached a consumer"


def test_a_pre_v8_run_json_reconciles_without_exploding_into_characters() -> None:
    """The v7-artifact path, which no other test reaches.

    `run.json` is a PERSISTED artifact; ones written before v8 are on disk in `out-vault/` right
    now, holding `"supersedes": "model-engine-design"` as a bare string. Every other supersedes
    test goes through `ingest_markdown`, which writes a v8 run.json, so they exercise the list
    branch and never the string one.

    This asserts the CONTRACT — a v7 scalar reconciles to a one-entry list — not which guard
    delivers it. Two do, at different entry points: `reconcile` normalises the legacy artifact so
    the `Document` it builds is correctly typed, and `IndexStore.upsert` normalises every writer,
    including a caller that constructs a `Document` by hand. So removing either one alone leaves
    this green; removing both turns it red. Stated plainly because a test docstring claiming to
    isolate a line it cannot isolate is worse than one that says what it actually covers.
    """
    import json as _json

    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp, "legacy.md", {"doc_id": "live-note"})
    ingest_markdown(note, tmp / "out" / "n", require_status=True)

    run_path = tmp / "out" / "n" / "run.json"
    run = _json.loads(run_path.read_text())
    run["spine"]["supersedes"] = "dead-one"          # the v7 shape, exactly as it sits on disk
    run_path.write_text(_json.dumps(run))

    with IndexStore(str(tmp / "i.db")) as s:
        reconcile(s, tmp / "out")
        stored = s.db.execute(
            "SELECT supersedes FROM documents WHERE doc_id=?", ("live-note",)).fetchone()[0]
        assert _json.loads(stored) == ["dead-one"], (
            f"a v7 scalar reconciled to {stored!r} — one link per character is well-formed at "
            f"every layer below and wrong at all of them")


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
