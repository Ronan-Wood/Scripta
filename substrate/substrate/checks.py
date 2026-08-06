"""The per-document assertion set, and how a failure is classified.

This is assertion POLICY, not command plumbing: which checks run over an ingested note, which
source formats each applies to, and — in `_QUALITY_CHECKS` — which failures merely report rather
than refuse a whole composed vault. It lived in `cli.py` only because `verify` was its first
caller; `compose` is now the one that matters, and PRINCIPLES.md's second law is specifically
about what happens when this set becomes a gate. A policy that decides whether real content is
refused should not be reachable only through an argument parser.

`verify` (one dir, CI) and `compose` (the gate) are the callers; nothing here prints or exits.
"""

from __future__ import annotations

import json
from pathlib import Path


# Quality-class per-note checks: they describe chunk SHAPE, not content loss or corruption. A
# short split remainder or an oversized prose paragraph makes a note read worse; nothing is
# missing and no path is wrong (A18 is the loss gate, A17 the corruption gate). `compose` reports
# these per note instead of refusing the scope, because faithfully-migrated real content
# legitimately produces both — a 2,500-char judge-panel paragraph the chunker will not split
# mid-sentence, and the short remainder such a split leaves. Everything NOT named here refuses, so
# an assertion added later fails closed until someone deliberately classifies it.
_QUALITY_CHECKS: frozenset[str] = frozenset({"A13-fragments", "A13-oversize-prose"})


def partition_check_failures(
    ingest_dirs: list[tuple[Path, Path]],
) -> tuple[list[tuple[Path, str, str]], list[tuple[Path, str, str]]]:
    """Run the per-document checks over every ingested note and split the failures two ways.

    Returns `(fatal, warned)`. A failure is a warning only if its check id is in _QUALITY_CHECKS;
    everything else is fatal, so an assertion added later fails closed until someone classifies it.
    """
    fatal: list[tuple[Path, str, str]] = []
    warned: list[tuple[Path, str, str]] = []
    for note_path, out_dir in ingest_dirs:
        for cid, name, ok, detail in document_checks(out_dir):
            if ok:
                continue
            (warned if cid in _QUALITY_CHECKS else fatal).append((note_path, name, detail))
    return fatal, warned


def document_checks(out: Path) -> list[tuple[str, str, bool, str]]:
    """The per-DOCUMENT assertion set over one ingested directory.

    Shared by `verify` (one dir, exit non-zero on any failure) and `compose` (every note in the
    composed scope). Each entry is `(check_id, display name, ok, detail)`. The id is stable and the
    display name is not — A14's name changes with the source format — so a caller classifying a
    failure matches the id, never the label.

    APPLICABILITY is per ingest ARM, and is a separate question from severity. A1/A1b hunt for
    EXTRACTION artifacts and are emitted for the PDF path only: `residue` matches
    `[a-z]\\s*[!­‐‑]\\s*[a-z]` because Docling renders DDIA's soft hyphen as `!`, so on authored
    markdown it counts ordinary exclamations — three "word! word" occurrences in one migrated note
    would otherwise refuse an entire composed vault with a message about hyphens. A18/A19 are
    markdown-only for the mirror-image reason. Neither is a quality-vs-loss call, so neither belongs
    in _QUALITY_CHECKS; conditional emission is how this module already expresses N/A.
    """
    from substrate.text.hyphens import residue
    from substrate.text.normalize import ligature_residue

    body = (out / "document.md").read_text("utf-8")
    run = json.loads((out / "run.json").read_text("utf-8"))
    chunks = [json.loads(x) for x in (out / "chunks.jsonl").read_text("utf-8").splitlines() if x]

    passages = [c for c in chunks if c["kind"] == "passage"]
    # Applicability follows the ARM that ran, not the format the file started as. A DOCX is
    # converted to markdown and then ingested by the markdown arm end to end, so it gets A18/A19
    # (which measure exactly what that arm does) and not A1/A1b (which hunt PDF text-layer glyph
    # artifacts and, on authored prose, count ordinary exclamation marks as hyphen residue).
    # `source_format` is the fallback for run.json files written before `ingest_arm` existed — for
    # those the two questions had the same answer, because markdown was the only markdown-arm input.
    # `or`, not a `.get` default: a run.json carrying `"ingest_arm": null` HAS the key, so the
    # default never applied and a markdown run fell through to the PDF assertion set — A1/A1b
    # counting ordinary exclamation marks as hyphen residue, and A18, the loss gate that arm is
    # actually measured by, silently not emitted at all.
    is_md = (run.get("ingest_arm")
             or ("markdown" if run.get("source_format") == "markdown" else "")) == "markdown"
    checks: list[tuple[str, str, bool, str]] = []

    if not is_md:
        checks.append(("A1-hyphen", "A1  hyphen residue", residue(body) <= 2,
                       f"{residue(body)} left"))
        checks.append(
            ("A1b-ligature", "A1b ligature residue", ligature_residue(body) == 0,
             f"{ligature_residue(body)} left")
        )
    checks.append(("A12-version", "A12 version captured", not (run["class"]["document_class"] == "reference-versioned" and not run["class"]["version"]), str(run["class"].get("version"))))
    checks.append(("A13-fragments", "A13 no fragments", run["chunk"]["short_fragments"] == 0, f"{run['chunk']['short_fragments']}"))
    # An oversized chunk is only a defect when it is PROSE. Prose always has sentence
    # boundaries to split on; a table or code listing does not, and splitting one leaves
    # both halves useless. Counting raw oversize instead made a 78-passage paper fail on
    # the same absolute count (2 tables) that a 1,152-passage book passed.
    oversize_prose = [
        c
        for c in passages
        if c.get("oversize") and "```" not in c["text"] and c["text"].count("|") <= 6
    ]
    checks.append(
        (
            "A13-oversize-prose",
            "A13 no oversized prose",
            not oversize_prose,
            f"{len(oversize_prose)} prose / {run['chunk']['oversize']} total (rest are tables/code, kept whole)",
        )
    )
    # A17 catches STALE ANCESTORS — the failure that every other assertion missed.
    # When 11 of 14 DDIA chapter titles were being discarded, the heading stack held a stale
    # chapter for hundreds of pages: page 328 (Transactions) carried "CHAPTER 2 Defining
    # Nonfunctional Requirements". Coverage, depth and fragments were all green, because the
    # paths were well-FORMED and merely wrong. Only a real query exposed it. A top-level
    # element spanning an implausible share of the document is the signature.
    spans: dict[str, list[int]] = {}
    for c in passages:
        if len(c["path"]) >= 2 and c.get("page_start"):
            spans.setdefault(c["path"][1], []).append(c["page_start"])
    worst, worst_share = None, 0.0
    for name, pages_seen in spans.items():
        share = (max(pages_seen) - min(pages_seen) + 1) / max(run["pages"], 1)
        if share > worst_share:
            worst, worst_share = name, share
    # A17's denominator is `run["pages"]`, which for markdown is the max `<!-- page:N -->` anchor
    # in the SLICE, not the source book's page count — so a faithful Chapter-1 slice (anchors 2–9)
    # computes an implausible "share of pages" and would refuse the whole scope, while the same
    # slice taken from page 280 passes only because the denominator is inflated. It is a book-scale
    # extraction heuristic ("11 of 14 DDIA chapter titles"), and a hand-authored slice does not
    # carry the page count the ratio assumes. Report-only for markdown, gated for the PDF path
    # where the denominator is real — the same split A14 already makes, for the same reason.
    a17 = worst_share <= 0.30 or len(spans) <= 2
    name17 = "A17 stale ancestor (report-only, md)" if is_md and not a17 else "A17 no stale ancestor"
    checks.append(
        (
            "A17-stale-ancestor",
            name17,
            a17 or is_md,
            f"widest top-level element spans {worst_share:.0%} of pages ({str(worst)[:34]})",
        )
    )

    # A14 re-emit coverage (chunk chars / body chars) is a book-SCALE proxy: markup and uncounted
    # outline records are ~4% of a large doc but a large fraction of a small note, so a valid
    # 900-char markdown note scores ~0.89 with nothing lost. For markdown A18 (below) is the
    # exact, size-independent loss gate that supersedes it, so the A14 row is report-only and
    # LABELLED as such — a bare "PASS" beside a sub-0.95 number reads as a weakened gate. The PDF
    # path keeps A14 gated (its born-digital books always clear 0.95).
    # Both A14 rows are book-scale structural heuristics that a valid markdown note can miss with
    # nothing wrong: a small note's markup dominates the coverage ratio, and a deliberately FLAT
    # note (only top-level headings) has no depth-≥2 paths. For the PDF path both catch real
    # extraction failures (glyph-geometry can flatten the heading tree), so they stay gated there;
    # for markdown headings are explicit, so these can only false-reject — report-only, and A18 +
    # A17 carry the real content/structure guarantees. (`is_md` is computed once, at the top.)
    a14 = run["coverage"] >= 0.95
    name14 = "A14 coverage (report-only, md)" if is_md and not a14 else "A14 coverage >= 0.95"
    checks.append(("A14-coverage", name14, a14 or is_md, f"{run['coverage']}"))
    a14p = run["chunk"]["path_depth_ge2_pct"] >= 60
    name14p = "A14 paths (report-only, md)" if is_md and not a14p else "A14 paths present"
    checks.append(("A14-paths", name14p, a14p or is_md, f"{run['chunk']['path_depth_ge2_pct']}%"))

    # A18 — markdown ingestion only. End-to-end source→chunks coverage: A14 above compares chunk
    # chars to the re-emitted BODY, so a stage that dropped a source line passes it (the line is
    # absent from both sides). A18 compares against the SOURCE file. Two parts, both must hold:
    # the aggregate token ratio (large loss) and zero dropped content blocks (a small categorical
    # drop a big doc's ratio would hide). Heading/path STRUCTURE is A17's job, not A18's.
    if is_md:
        from substrate.markdown.ingest import MD_COVERAGE_GATE
        ex = run.get("extract", {})
        cov = ex.get("source_coverage")
        drops = ex.get("content_block_drops", [])
        checks.append(
            ("A18-md-coverage", "A18 md source coverage",
             cov is not None and cov >= MD_COVERAGE_GATE and not drops,
             f"{cov} · {len(drops)} block(s) dropped {drops[:5]} · missing "
             f"{ex.get('source_coverage_missing')}")
        )

        # A19 — the note's spine status is one the engine can act on. A status outside the four is
        # silently excluded by the default retrieval filter (it is not in the included set), and a
        # superseded note with no supersession link is a dead fact with no path to the live one.
        # Per-DOC here (verify runs on one ingested dir); the cross-doc partition is A20 (compose).
        # Only asserted when a spine block is present: a markdown ingest dir written before this
        # feature has none, and a status is not "invalid" merely for predating the field — a
        # re-ingest writes the block. New ingests always emit one, so this only spares stale dirs.
        if "spine" in run:
            from substrate.spine import DOC_TYPES, STATUSES
            sp = run["spine"]
            st = sp.get("status")
            superseded_ok = st != "superseded" or bool(sp.get("superseded_by"))
            checks.append(
                ("A19-spine-status", "A19 spine status valid",
                 st in STATUSES and superseded_ok,
                 f"{st}"
                 + ("" if superseded_ok else " · superseded with no superseded_by")
                 + (f" · domains {sp.get('domains')}" if sp.get("domains") else "")),
            )
            # doc_type (§6a) joins the per-doc spine check when present. A spine block written before
            # doc_type existed has none — N/A, not invalid, the same leniency A19 gives a pre-spine
            # dir; a re-ingest writes one. The cross-doc facet (validity + denorm) is A21 at compose.
            if "doc_type" in sp:
                dt = sp.get("doc_type")
                checks.append(("A19-spine-doc-type", "A19 spine doc_type valid",
                               dt in DOC_TYPES, f"{dt}"))
            # confidence joins the per-doc spine check on the same terms. A spine block written
            # before the axis existed has none — N/A, not invalid.
            if "confidence" in sp:
                from substrate.spine import STORED_CONFIDENCES
                cf = sp.get("confidence")
                checks.append(("A19-spine-confidence", "A19 spine confidence valid",
                               cf in STORED_CONFIDENCES, f"{cf}"))

    return checks
