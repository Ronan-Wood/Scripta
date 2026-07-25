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
    ("confidence",     "verified",           "confidence",     "unstated"),
    ("document_class", "conversation",       "document_class", "reference-frozen"),
    ("class",          "conversation",       "document_class", "reference-frozen"),
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
    """The guard must not accidentally require declaration — absence is legal and meaningful."""
    tmp = Path(tempfile.mkdtemp())
    doc, _b, _s = read_markdown(_note(tmp, "bare.md", {}))
    assert doc.confidence is None, "the reader must not invent a confidence"
    assert doc.document_class == "reference-frozen"
    r = ingest_markdown(_note(tmp, "bare2.md", {}), tmp / "out2", require_status=True)
    assert r.confidence == "unstated", "absence must resolve to unstated at the gate, not earlier"


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
