"""A22 — the per-NOTE assertion sweep on the vault path.

`compose` proves cross-document properties (A-compose, A20, A21). Until A22 the per-DOCUMENT
A-series lived only in `verify`, which the vault path never calls, so a note that `verify` FAILS
could enter a composed index under a wholly green compose. That is this project's signature shape
— a well-formed artefact whose defect is in what it omits about itself — and the real-content
pilot hit it: 1 of 12 real notes failed A13, 0 of 9 synthetic ones did.

Two properties are load-bearing and tested here:

  * `document_checks` carries a STABLE id per check, because A14's display name changes with the
    source format and a caller classifying a failure must never match on the label.
  * the fatal/warning split DEFAULTS TO FATAL — only ids named in _QUALITY_CHECKS warn, so an
    assertion added later fails closed rather than silently joining the report-only tier.

Runnable with plain `python tests/test_compose_assertions.py`.
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import checks as C  # noqa: E402
from substrate.markdown.ingest import ingest_markdown  # noqa: E402


def _note(dir_: Path, name: str, body: str, *, status: str = "active",
          doc_type: str = "explanation") -> Path:
    dir_.mkdir(parents=True, exist_ok=True)
    p = dir_ / name
    p.write_text(
        f"---\nstatus: {status}\ndoc_type: {doc_type}\n---\n\n# {name[:-3]}\n\n{body}\n"
    )
    return p


def _ingest(tmp: Path, note: Path) -> Path:
    out = tmp / "ingest" / note.stem
    ingest_markdown(note, out, require_status=True)
    return out


def test_checks_carry_stable_ids() -> None:
    """Every check is a 4-tuple (id, name, ok, detail) with a non-empty, unique-per-run id."""
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp / "v", "a.md", "A clean note body with several sentences. " * 12)
    checks = C.document_checks(_ingest(tmp, note))
    assert checks, "expected a non-empty check list"
    for entry in checks:
        assert len(entry) == 4, f"expected 4-tuple, got {len(entry)}: {entry}"
        cid, name, ok, detail = entry
        assert isinstance(cid, str) and cid, f"empty check id on {name!r}"
        assert isinstance(ok, bool)
        assert isinstance(detail, str)
    ids = [c[0] for c in checks]
    assert len(ids) == len(set(ids)), f"duplicate check ids: {ids}"


def test_quality_ids_are_real_checks() -> None:
    """_QUALITY_CHECKS must name ids that actually exist, or the split silently stops working."""
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp / "v", "a.md", "Body sentence. " * 40)
    ids = {c[0] for c in C.document_checks(_ingest(tmp, note))}
    missing = C._QUALITY_CHECKS - ids
    assert not missing, f"_QUALITY_CHECKS names ids no check emits: {missing}"


def test_clean_note_produces_no_failures() -> None:
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp / "v", "a.md", "A clean well formed note body. " * 30)
    fatal, warned = C.partition_check_failures([(note, _ingest(tmp, note))])
    assert not fatal, f"clean note produced fatal failures: {fatal}"
    assert not warned, f"clean note produced warnings: {warned}"


def test_quality_failure_warns_and_does_not_refuse() -> None:
    """A13 is quality-class: a short split remainder is reported, never fatal — real migrated
    content legitimately chunks imperfectly, and refusing it would make migration impossible."""
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp / "v", "a.md", "Body. " * 50)
    out = _ingest(tmp, note)
    run = json.loads((out / "run.json").read_text())
    run["chunk"]["short_fragments"] = 1          # what the real 831-line panel note produced
    (out / "run.json").write_text(json.dumps(run))

    fatal, warned = C.partition_check_failures([(note, out)])
    assert not fatal, f"a quality-class failure must not refuse the scope: {fatal}"
    assert len(warned) == 1, f"expected exactly one warning, got {warned}"
    assert "A13" in warned[0][1], warned


def test_loss_class_failure_is_fatal() -> None:
    """A18 is loss-class: a dropped source block refuses the scope. This is the half that must
    never degrade to a warning — it is the silent-content-loss gate."""
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp / "v", "a.md", "Body. " * 50)
    out = _ingest(tmp, note)
    run = json.loads((out / "run.json").read_text())
    run["extract"]["content_block_drops"] = ["b000007"]
    (out / "run.json").write_text(json.dumps(run))

    fatal, warned = C.partition_check_failures([(note, out)])
    assert len(fatal) == 1, f"a dropped content block must be fatal, got fatal={fatal} warned={warned}"
    assert "A18" in fatal[0][1], fatal


def test_unclassified_failure_defaults_to_fatal() -> None:
    """The split fails CLOSED: a check id that nobody classified is fatal, so adding an assertion
    later cannot silently land it in the report-only tier."""
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp / "v", "a.md", "Body. " * 50)
    out = _ingest(tmp, note)
    run = json.loads((out / "run.json").read_text())
    run["class"]["document_class"] = "reference-versioned"   # A12: versioned with no version
    run["class"]["version"] = None
    (out / "run.json").write_text(json.dumps(run))

    fatal, warned = C.partition_check_failures([(note, out)])
    assert any("A12" in n for _, n, _ in fatal), f"A12 is unclassified and must be fatal: {fatal} {warned}"


def test_failures_name_the_note_that_produced_them() -> None:
    """A count alone would be the Boundary Principle violated again — the operator must be able to
    open the offending note without re-running anything."""
    tmp = Path(tempfile.mkdtemp())
    good = _note(tmp / "v", "good.md", "Body. " * 50)
    bad = _note(tmp / "v", "bad.md", "Body. " * 50)
    out_bad = _ingest(tmp, bad)
    run = json.loads((out_bad / "run.json").read_text())
    run["chunk"]["short_fragments"] = 2
    (out_bad / "run.json").write_text(json.dumps(run))

    _fatal, warned = C.partition_check_failures(
        [(good, _ingest(tmp, good)), (bad, out_bad)]
    )
    assert [w[0] for w in warned] == [bad], f"warning must name the offending note: {warned}"


def test_pdf_only_checks_are_not_emitted_for_markdown() -> None:
    """A1/A1b hunt for EXTRACTION artifacts. `residue` matches `[a-z]\\s*[!­‐‑]\\s*[a-z]` because
    Docling renders a soft hyphen as `!`, so on authored markdown it counts ordinary exclamations —
    three "word! word" transitions would otherwise refuse an entire composed vault, with a message
    about hyphens the operator cannot act on."""
    tmp = Path(tempfile.mkdtemp())
    note = _note(tmp / "v", "a.md",
                 "It worked! and then it broke. Ship it! or so we thought. Fixed it! but not really. "
                 * 4)
    from substrate.text.hyphens import residue
    assert residue(note.read_text()) > 2, "fixture must actually trip the PDF-era gate"
    out = _ingest(tmp, note)
    ids = {c[0] for c in C.document_checks(out)}
    assert "A1-hyphen" not in ids and "A1b-ligature" not in ids, ids
    fatal, warned = C.partition_check_failures([(note, out)])
    assert not fatal, f"ordinary markdown punctuation must not refuse the scope: {fatal}"


def test_a17_is_report_only_for_markdown() -> None:
    """A17's denominator is `run["pages"]`, which for markdown is the max page anchor in the SLICE,
    not the source book's page count — so a faithful early-chapter slice computes an implausible
    share and would refuse the whole scope.

    The fixture must actually trip the pre-fix predicate, so each anchored block exceeds the chunk
    target: otherwise the section packs into ONE chunk, every page_start is identical, the span is
    never wide, and the test passes whether or not the fix is present — pinning nothing.
    """
    tmp = Path(tempfile.mkdtemp())
    big = "This is a long authored sentence that carries real content. " * 40
    body = ("<!-- page:2 -->\n\n## Long Section\n\n" + big
            + "\n\n<!-- page:7 -->\n\n" + big
            + "\n\n<!-- page:9 -->\n\n## Short A\n\nx y z.\n\n## Short B\n\nx y z.\n")
    note = _note(tmp / "v", "slice.md", body)
    out = _ingest(tmp, note)

    # Guard: prove the fixture reaches the state A17 objects to, or this test is vacuous.
    run = json.loads((out / "run.json").read_text())
    chunks = [json.loads(x) for x in (out / "chunks.jsonl").read_text().splitlines() if x]
    spans: dict[str, list[int]] = {}
    for c in (c for c in chunks if c["kind"] == "passage"):
        if len(c["path"]) >= 2 and c.get("page_start"):
            spans.setdefault(c["path"][1], []).append(c["page_start"])
    worst = max(((max(v) - min(v) + 1) / max(run["pages"], 1) for v in spans.values()), default=0.0)
    assert worst > 0.30 and len(spans) > 2, (
        f"fixture does not trip the pre-fix predicate (worst={worst:.0%}, {len(spans)} spans) — "
        "the test would pass with or without the fix")

    fatal, _warned = C.partition_check_failures([(note, out)])
    assert not any("A17" in n for _, n, _ in fatal), f"A17 must not refuse a markdown slice: {fatal}"


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
