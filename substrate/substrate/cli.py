"""substrate — ingest reference documents into markdown + chunks.

    ingest  --pdf X --doc-class reference-frozen --out DIR
    verify  DIR

Ingestion is deterministic for a pinned extractor: no model generates text anywhere in this
path. Outputs are files; the blast radius is a directory.
"""

from __future__ import annotations

import argparse
import json
import sys
import time
from pathlib import Path

from substrate import classes, render, scopes
from substrate.paths import ARTIFACTS, configure, internal_cache_footprint


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text(
        "\n".join(json.dumps(r, ensure_ascii=False, sort_keys=True) for r in rows) + "\n",
        encoding="utf-8",
    )


def cmd_ingest(args: argparse.Namespace) -> int:
    configure()
    from substrate.chunk.chunker import chunk
    from substrate.extract.docling_arm import DoclingExtractor
    from substrate.markdown.emit import emit, frontmatter

    pdf = Path(args.pdf).expanduser()
    if not pdf.exists():
        print(f"FATAL: no such file: {pdf}", file=sys.stderr)
        return 2

    out = Path(args.out).expanduser()
    out.mkdir(parents=True, exist_ok=True)

    pages = None
    if args.pages:
        a, b = args.pages.split("-")
        pages = (int(a), int(b))

    t0 = time.monotonic()
    print(f"artifacts : {ARTIFACTS}")
    print(f"ingesting : {pdf.name}  class={args.doc_class}")

    extractor = DoclingExtractor(batch_pages=args.batch)
    doc = extractor.extract(pdf, args.doc_class, pages=pages)

    try:
        meta = classes.apply(doc)
    except classes.ClassPolicyError as e:
        print(f"\nFATAL (class policy): {e}", file=sys.stderr)
        return 3

    body, estats = emit(doc)
    chunks, cstats = chunk(doc)

    (out / "document.md").write_text(frontmatter(doc, {"version_source": None}) + body, "utf-8")
    # EVERY block, including furniture we dropped and contents we excluded (char_start=-1).
    # Retaining them is what makes the drop auditable — a silently discarded block cannot be
    # distinguished from one that was never extracted.
    _write_jsonl(out / "blocks.jsonl", [b.to_json() for b in doc.blocks])
    _write_jsonl(out / "chunks.jsonl", [c.to_json() for c in chunks])

    run = {
        "doc_id": doc.doc_id,
        "source": str(pdf),
        "source_sha256": doc.source_sha256,
        "pages": doc.source_pages,
        "elapsed_s": round(time.monotonic() - t0, 1),
        "class": meta,
        "extract": doc.extract_confidence,
        "emit": estats,
        "chunk": cstats,
        "coverage": round(cstats["sum_chunk_chars"] / max(len(body), 1), 4),
        "internal_cache": internal_cache_footprint(),
    }
    (out / "run.json").write_text(json.dumps(run, indent=2, ensure_ascii=False), "utf-8")

    print(f"\n  title      : {meta['title']}")
    if meta.get("version"):
        print(f"  version    : {meta['version']}  ({meta.get('version_date')})")
    print(f"  body       : {len(body):,} chars")
    print(f"  passages   : {cstats['passages']}  outlines: {cstats['outlines']}")
    print(f"  sizes      : p5={cstats['chars_p5']} p50={cstats['chars_p50']} p95={cstats['chars_p95']}")
    print(f"  well-formed: {cstats['well_formed_pct']}%  (fragments: {cstats['short_fragments']})")
    print(f"  coverage   : {run['coverage']}")
    print(f"  elapsed    : {run['elapsed_s']}s")
    print(f"  internal   : {run['internal_cache']}")
    print(f"\nwrote -> {out}")
    return 0


def cmd_ingest_md(args: argparse.Namespace) -> int:
    """Ingest a markdown file → canonical Document → chunks. The single-file vault path.

    A thin wrapper over ``markdown.ingest.ingest_markdown`` (the one shared body, used by the
    manifest-composition path too). Standalone ingest is LENIENT on status — an absent status
    defaults to 'active' (the existing corpus predates the field); an invalid status or a
    superseded note with no link is still refused. The strict path is `compose` (require_status).
    """
    from substrate.markdown.ingest import CoverageError, ingest_markdown
    from substrate.spine import SpineError

    src = Path(args.md).expanduser()
    if not src.exists():
        print(f"FATAL: no such file: {src}", file=sys.stderr)
        return 2

    out = Path(args.out).expanduser()
    print(f"ingesting : {src.name}  (markdown)")

    try:
        # Standalone ingest carries no composition provenance — vault/tier are set only by the
        # `compose` path (from the resolved manifest), which calls ingest_markdown() directly.
        r = ingest_markdown(src, out, doc_class=args.doc_class, require_status=False)
    except ValueError as e:  # over-size file or non-UTF-8 bytes — refuse cleanly, no traceback
        print(f"\nFATAL: cannot read {src.name}: {e}", file=sys.stderr)
        return 2
    except classes.ClassPolicyError as e:
        print(f"\nFATAL (class policy): {e}", file=sys.stderr)
        return 3
    except SpineError as e:
        print(f"\nFATAL (spine): {e}", file=sys.stderr)
        return 3
    except CoverageError as e:
        print(f"\nFATAL (A18): {e}", file=sys.stderr)
        return 3

    run, rstats, cstats = r.run, r.run["extract"], r.run["chunk"]
    print(f"\n  title      : {r.title}")
    if run["class"].get("version"):
        print(f"  version    : {run['class']['version']}  ({run['class'].get('version_date')})")
    print(f"  status     : {r.status}  ·  doc_type {r.doc_type}"
          + f"  ·  confidence {r.confidence}"
          + (f"  ·  domains {r.domains}" if r.domains else "")
          + (f"  ·  supersedes {run['spine']['supersedes']}" if run["spine"]["supersedes"] else "")
          + (f"  ·  superseded_by {run['spine']['superseded_by']}"
             if run["spine"]["superseded_by"] else ""))
    print(f"  blocks     : {rstats['blocks']}  "
          f"(headings {rstats['headings']} · code {rstats['code']} · "
          f"tables {rstats['tables']} · list {rstats['list_items']})")
    print(f"  body       : {r.body_chars:,} chars")
    print(f"  passages   : {cstats['passages']}  outlines: {cstats['outlines']}")
    print(f"  sizes      : p5={cstats['chars_p5']} p50={cstats['chars_p50']} p95={cstats['chars_p95']}")
    print(f"  well-formed: {cstats['well_formed_pct']}%  (fragments: {cstats['short_fragments']})")
    print(f"  A14 re-emit coverage    : {run['coverage']}")
    print(f"  A18 source→chunk coverage: {r.source_coverage}")
    print(f"  elapsed    : {run['elapsed_s']}s")
    print(f"\nwrote -> {out}")
    return 0


# Quality-class per-note checks: they describe chunk SHAPE, not content loss or corruption. A
# short split remainder or an oversized prose paragraph makes a note read worse; nothing is
# missing and no path is wrong (A18 is the loss gate, A17 the corruption gate). `compose` reports
# these per note instead of refusing the scope, because faithfully-migrated real content
# legitimately produces both — a 2,500-char judge-panel paragraph the chunker will not split
# mid-sentence, and the short remainder such a split leaves. Everything NOT named here refuses, so
# an assertion added later fails closed until someone deliberately classifies it.
_QUALITY_CHECKS: frozenset[str] = frozenset({"A13-fragments", "A13-oversize-prose"})


def refuse_if_rebuilt(store, *, repopulates: bool) -> bool:
    """A schema bump drops-and-rebuilds the index on open. Announce it — and on a READ path, refuse.

    Dropping is safe by design (markdown is the source of truth), but only a command that
    repopulates in the same run — `index`, `compose` — ends with an index again. A read path
    (`query`, `embed`, `eval`) opens it, finds it empty, and has no way to refill it, so it would
    answer `(no results)`. That reads as "nothing in your vault matches" when the truth is "your
    index was just deleted": a plausible answer from a silently-emptied source set, which is this
    project's signature failure and precisely what an empty result cannot distinguish itself from.

    Returns True when the caller should abort. Write paths get the notice and carry on.
    """
    if not store.rebuilt:
        return False
    if repopulates:
        print("schema version changed -> index dropped and rebuilt from markdown")
        return False
    print(
        "FATAL: the index schema changed, so the index was dropped and rebuilt EMPTY on open.\n"
        "  This command only reads, so it cannot refill it — and zero results here would be\n"
        "  indistinguishable from a genuine no-match. Re-run `substrate index` (or `compose` for a\n"
        "  vault) to rebuild from markdown, then retry.",
        file=sys.stderr,
    )
    return True


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

    APPLICABILITY is per source format, and is a separate question from severity. A1/A1b hunt for
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
    is_md = run.get("source_format") == "markdown"
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


def cmd_verify(args: argparse.Namespace) -> int:
    """Assertions over an ingested directory. Non-zero exit on failure, for CI."""
    checks = document_checks(Path(args.dir).expanduser())

    width = max(len(n) for _, n, _, _ in checks)
    failed = 0
    for _cid, name, ok, detail in checks:
        if not ok:
            failed += 1
        print(f"  {'PASS' if ok else 'FAIL'}  {name:<{width}}  {detail}")

    print(f"\n{'ALL PASS' if not failed else f'{failed} FAILED'}")
    return 1 if failed else 0


def cmd_review(args: argparse.Namespace) -> int:
    from substrate.report.review import build

    rev = build(Path(args.dir).expanduser(), samples=args.sample, seed=args.seed)
    for f in sorted(rev.iterdir()):
        print(f"  {f.name:<24} {f.stat().st_size:>8,} bytes")
    print(f"\nreview packet -> {rev}")
    print("Start with 00-summary.md; reds are listed first.")
    return 0


def cmd_rechunk(args: argparse.Namespace) -> int:
    """Re-cut chunks from blocks.jsonl WITHOUT re-parsing the PDF.

    This is the property the offset-mapped blocks were built for and it had never been
    exercised: re-extraction costs ~3 minutes and a pinned model, re-chunking should cost
    milliseconds. It is also what makes chunk geometry testable as an eval axis at all —
    a granularity sweep that re-parsed every PDF would cost 20 minutes instead of 2.
    """
    from substrate.chunk.chunker import chunk as _chunk
    from substrate.models import Block, Document, Kind

    out = Path(args.dir).expanduser()
    run = json.loads((out / "run.json").read_text("utf-8"))
    cls = run.get("class", {})

    blocks = []
    for line in (out / "blocks.jsonl").read_text("utf-8").splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        b = Block(id=r["id"], kind=Kind(r["kind"]), text=r["text"], page=r["page"],
                  label=r["label"], level=r["level"], lang=r["lang"],
                  height=r["height"], left=r["left"])
        b.char_start, b.char_end = r["char_start"], r["char_end"]
        b.furniture_claimed, b.furniture_honored = r["furniture_claimed"], r["furniture_honored"]
        blocks.append(b)

    doc = Document(
        doc_id=run["doc_id"], source_path=run["source"], source_sha256=run["source_sha256"],
        source_pages=run["pages"], document_class=cls.get("document_class", "reference-frozen"),
        blocks=blocks, title=cls.get("title"), version=cls.get("version"),
        version_date=cls.get("version_date"),
        extractor=run.get("extract", {}).get("extractor", ""),
        extractor_arm="docling", layout_model="docling-layout-heron",
    )

    override = None
    if args.target:
        override = (args.target, args.max_chars or args.target * 2, args.min_chars or args.target // 3)

    chunks, cstats = _chunk(doc, override=override)
    _write_jsonl(out / "chunks.jsonl", [c.to_json() for c in chunks])

    body_chars = run["emit"]["body_chars"]
    run["chunk"] = cstats
    run["coverage"] = round(cstats["sum_chunk_chars"] / max(body_chars, 1), 4)
    run["chunk_override"] = override
    (out / "run.json").write_text(json.dumps(run, indent=2, ensure_ascii=False), "utf-8")

    print(f"  {out.name}: {cstats['passages']} passages · p50 {cstats['chars_p50']} · "
          f"coverage {run['coverage']} · fragments {cstats['short_fragments']}")
    return 0


def cmd_index(args: argparse.Namespace) -> int:
    from substrate.store.index_store import ConfidenceError, DocTypeError, IndexStore
    from substrate.store.reconcile import reconcile

    root = Path(args.out_root).expanduser()
    with IndexStore(args.db) as store:
        refuse_if_rebuilt(store, repopulates=True)
        if args.rebuild:
            store.clear()
            print("cleared index (markdown is the source of truth)")
        rep = reconcile(store, root)
        s = store.stats()
        # `index` rebuilds from `out/` artifacts rather than from vault notes, so nothing on this
        # path runs the spine gates that `compose` runs at ingest — a hand-edited or stale run.json
        # spine reaches both tables unvalidated. That was tolerable while the axes were only
        # FILTERED on (an unknown status is excluded from retrieval, so it hides itself), but
        # confidence is DISPLAYED: an out-of-vocabulary value prints on every hit as though the
        # note claimed it, which is the laundering the axis exists to prevent. The store-side
        # audits are cheap scans over a small table, so run them here too and make A21/A23's
        # "every indexed value is valid" true of every path, not just of compose.
        try:
            store.assert_doc_type_valid()
            store.assert_confidence_valid()
        except (DocTypeError, ConfidenceError) as e:
            print(f"\nFATAL (doc_type/confidence assertion): {e}", file=sys.stderr)
            return 3

    print(
        f"  added {len(rep.added)} · updated {len(rep.updated)} · "
        f"unchanged {len(rep.unchanged)} · removed {len(rep.removed)}"
    )
    print(f"  {s['documents']} documents · {s['passages']} passages · {s['outlines']} outlines")
    print("  A21/A23 spine axes valid")
    print(f"  db: {args.db} (schema v{s['schema_version']})")
    return 0


def cmd_compose(args: argparse.Namespace) -> int:
    """Resolve a project vault's manifest, ingest the composed note set, index it, and PROVE the
    composition — the inheritance mechanism end to end (Doc 2 §1–2, §6).

    Strict where a single-file ingest is lenient: every note must declare a status and a doc_type
    (require_status=True), and the whole scope is refused if ANY note fails to ingest — a partially
    composed scope is a silently-wrong retrieval set. Confidence stays optional on this path too
    (absent → `unstated`), because a forced settledness marker is a guessed one.

    Five assertions run, so a green run is a proof rather than a hope:

      * **A22**, BEFORE indexing — the per-note sweep over every ingested note. Loss/corruption
        failures refuse the scope; quality failures are reported against the note that produced
        them. Before this existed, `compose` ran none of the per-document A-series at all.
      * after indexing — **A-compose** (inheritance actually composed, no tier silently dropped),
        **A20** (the status filter partitions exactly), **A21** (every doc_type valid, chunk↔doc
        denormalization intact) and **A23** (the same two properties for confidence).
    """
    from substrate import vault as _vault
    from substrate.markdown.ingest import CoverageError, ingest_markdown
    from substrate.spine import SpineError
    from substrate.store.index_store import (
        ConfidenceError,
        DocTypeError,
        IndexStore,
        StatusPartitionError,
    )
    from substrate.store.reconcile import reconcile

    project = Path(args.project_vault).expanduser()
    index_root = Path(args.index_root).expanduser()

    try:
        scope = _vault.resolve_scope(project)
    except _vault.VaultError as e:
        print(f"FATAL (manifest): {e}", file=sys.stderr)
        return 2

    print(f"scope: {scope.project.name}  <-  {[v.name for v in scope.vaults]}")
    print(f"  {len(scope.notes)} notes across {len(scope.vaults)} vault(s)")

    if index_root.exists() and args.clean:
        import shutil
        shutil.rmtree(index_root)
    index_root.mkdir(parents=True, exist_ok=True)

    # Ingest every note. Collect failures rather than aborting on the first, then refuse the WHOLE
    # scope if any failed — a composed index missing notes is exactly the silent-loss shape, so it
    # is never indexed partially. The out-dir name flattens the note's vault-relative path so two
    # notes (even same filename in different sources) never share an ingest dir.
    import hashlib as _hl
    ingested: set[str] = set()
    ingest_dirs: list[tuple[Path, Path]] = []   # (note path, its ingest dir) for the A22 sweep
    failures: list[tuple[Path, str]] = []
    for n in scope.notes:
        # A per-note out dir: vault + filename stem + a short path hash, so two same-named files
        # (e.g. each source's passages/00-*.md) never collide on one ingest directory.
        digest = _hl.sha256(str(n.path).encode()).hexdigest()[:8]
        out_dir = index_root / f"{n.vault}__{n.path.stem}__{digest}"
        try:
            r = ingest_markdown(
                n.path, out_dir, doc_class=n.doc_class, require_status=True,
                override_status=n.override_status, override_doc_type=n.override_doc_type,
                override_confidence=n.override_confidence,
                raw=n.raw, raw_sha256=n.raw_sha256, raw_location=n.raw_location,
                override_version=n.override_version,
                extra_domains=n.extra_domains, vault=n.vault, tier=n.tier,
            )
        except (ValueError, classes.ClassPolicyError, SpineError, CoverageError) as e:
            failures.append((n.path, f"{type(e).__name__}: {e}"))
            continue
        ingested.add(r.doc_id)
        ingest_dirs.append((n.path, out_dir))
        print(f"  [{n.tier}] {n.vault}/{n.path.name}  ->  {r.doc_id}  "
              f"({r.status}/{r.doc_type}/{r.confidence}{', ' + ','.join(r.domains) if r.domains else ''})")

    if failures:
        print(f"\nFATAL: {len(failures)} note(s) failed to ingest — refusing to index a partial "
              "scope:", file=sys.stderr)
        for path, why in failures:
            print(f"    {path}: {why}", file=sys.stderr)
        return 3

    # A22 — the per-NOTE assertion sweep. compose proves cross-document properties (A-compose, A20,
    # A21) and nothing else; until this ran, the per-document A-series lived only in `verify`, which
    # the vault path never calls. So a note that `verify` fails could enter a composed index under a
    # wholly green compose — a well-formed artefact whose defect is in what it omits about itself,
    # which is this project's signature failure. Runs before indexing, so a loss-class failure
    # refuses the scope rather than being discovered after the write.
    #
    # Two tiers, and the DEFAULT IS REFUSE: only the ids in _QUALITY_CHECKS report, everything else
    # is fatal. Quality failures are named per note rather than swallowed — Doc 2 §8 makes migration
    # a supervised job over content the engine does not own, and real notes legitimately chunk
    # imperfectly; refusing those would make faithful migration impossible, while hiding them would
    # rebuild the gap this check exists to close.
    fatal, warned = partition_check_failures(ingest_dirs)

    if fatal:
        print(f"\nFATAL (A22 per-note assertion): {len(fatal)} failure(s) across "
              f"{len({p for p, _, _ in fatal})} note(s) — refusing to index content that does not "
              "pass the per-document gates:", file=sys.stderr)
        for path, name, detail in fatal:
            print(f"    {path}: {name} — {detail}", file=sys.stderr)
        return 3

    with IndexStore(args.db) as store:
        refuse_if_rebuilt(store, repopulates=True)
        rep = reconcile(store, index_root)
        s = store.stats()
        try:
            comp = _vault.assert_composed(store, ingested_doc_ids=ingested)
            part = store.assert_status_partition()
            dtp = store.assert_doc_type_valid()
            cfp = store.assert_confidence_valid()
        except (_vault.VaultError, StatusPartitionError, DocTypeError,
                ConfidenceError) as e:
            print(f"\nFATAL (composition/status/doc_type/confidence assertion): {e}",
                  file=sys.stderr)
            return 3
        index_version = store.index_version

    print(f"\n  indexed: added {len(rep.added)} · updated {len(rep.updated)} · "
          f"unchanged {len(rep.unchanged)} · removed {len(rep.removed)}")
    print(f"  {s['documents']} documents · {s['passages']} passages · {s['outlines']} outlines")
    print(f"  A-compose PASS  by vault {comp['by_vault']} · by tier {comp['by_tier']}")
    print(f"  A20 status PASS  included {part['included_chunks']} · "
          f"excluded {part['excluded_chunks']} · by status {part['by_status']}")
    print(f"  A21 doc_type PASS  by doc_type {dtp['by_doc_type']}")
    print(f"  A23 confidence PASS  by confidence {cfp['by_confidence']}")
    # Never print a bare PASS beside an unreported failure: the label states which gates it covers,
    # and any quality warning is listed with the note that produced it, on its own line.
    if warned:
        print(f"  A22 per-note PASS (loss/corruption gates) · {len(warned)} QUALITY WARNING(S) "
              f"across {len({p for p, _, _ in warned})} of {len(ingest_dirs)} note(s):")
        for path, name, detail in warned:
            print(f"      {path}: {name} — {detail}")
    else:
        print(f"  A22 per-note PASS  {len(ingest_dirs)} note(s) · 0 quality warnings")
    print(f"  db: {args.db} (schema v{s['schema_version']}) · index {index_version}")

    # Register the scope only now — after every gate passed. The registry's contract is that a
    # named scope has a composed index behind it, so recording a refused compose would hand a
    # caller a scope that answers nothing (Doc 3a §3: scope resolution hard-fails rather than
    # returning a plausible narrower result). A registry failure is reported, not fatal: the
    # index IS built, and losing the convenience mapping must not read as losing the compose.
    try:
        reg = scopes.record(scope.name, vault=project, db=Path(args.db), index_root=index_root,
                            registry=args.registry)
        print(f"  scope: {scope.name!r} registered in {reg}")
    except scopes.ScopeError as e:
        print(f"\nWARNING (scope registry): {e}", file=sys.stderr)
        print(f"  scope: {scope.name!r} NOT registered — query with --db {args.db}",
              file=sys.stderr)
    return 0


def _resolve_statuses(args: argparse.Namespace) -> frozenset[str] | None:
    """The status filter for a query, from the flags. Refuses an unknown status rather than
    silently filtering to nothing. None means unfiltered (an explicit administrative scan)."""
    from substrate.retrieve.retriever import DEFAULT_STATUSES
    from substrate.spine import STATUSES

    if getattr(args, "all_status", False):
        return None
    if getattr(args, "status", None):
        chosen = frozenset(s.strip() for s in args.status.split(",") if s.strip())
        if not chosen:
            # e.g. `--status ,,` or `--status " "`: parses to nothing. An empty set means "match
            # nothing" downstream, so accepting it would silently return zero results — refuse it.
            print(f"FATAL: --status {args.status!r} names no statuses; known {sorted(STATUSES)}",
                  file=sys.stderr)
            raise SystemExit(2)
        unknown = chosen - STATUSES
        if unknown:
            print(f"FATAL: unknown status {sorted(unknown)}; known {sorted(STATUSES)}",
                  file=sys.stderr)
            raise SystemExit(2)
        return chosen
    if getattr(args, "include_archived", False):
        return DEFAULT_STATUSES | {"archived"}
    return DEFAULT_STATUSES


def _resolve_db(args: argparse.Namespace) -> str:
    """The index to query: `--scope` through the registry, else `--db`, else the legacy default.

    Passing both is refused rather than resolved by precedence. A caller who names a scope AND a
    db has two different indexes in mind; silently honouring one would answer from a source set
    they did not choose, and the answer would look exactly like the one they wanted.
    """
    name = getattr(args, "scope", None)
    if not name:
        return args.db or "out/substrate.db"
    if args.db is not None:
        print(f"FATAL: --scope {name!r} and --db {args.db!r} name two different indexes. "
              "Pass one.", file=sys.stderr)
        raise SystemExit(2)
    try:
        entry = scopes.resolve(name, args.registry)
    except scopes.ScopeError as e:
        print(f"FATAL (scope): {e}", file=sys.stderr)
        raise SystemExit(2) from e
    return str(entry.db)


def cmd_query(args: argparse.Namespace) -> int:
    from substrate.store.index_store import IndexStore

    from substrate.embed.engine import OllamaEmbedder
    from substrate.retrieve.retriever import retrieve

    from substrate import render, stack as _stack

    # Two wirings. The default is the lean lookup config this command has always run (embedder
    # only, no generator). `--full-stack` builds the SAME arms the MCP server builds, through the
    # same function — that shared builder is what makes Doc 3a §6's CLI/MCP equivalence a real
    # test rather than two hand-wired stacks that agree on the day they were written.
    if args.full_stack:
        st = _stack.build(lexical_only=args.no_vector)
        embedder, expander, reranker = st.embedder, st.expander, st.reranker
        unavailable = st.unavailable
    else:
        cand = OllamaEmbedder()
        embedder = None if args.no_vector else (cand if cand.available() else None)
        expander = reranker = None
        unavailable = ()
    statuses = _resolve_statuses(args)
    db_path = _resolve_db(args)

    if args.json and args.kind == "outline":
        # The JSON envelope carries outline records as a FIELD beside the passages (Doc 2 §7's
        # two-speed shape). An outline-only result would be the same key holding a different
        # thing, which a consumer cannot tell apart from a passage search that matched nothing.
        print("FATAL: --json returns outline records alongside passages; use --outlines N "
              "rather than --kind outline.", file=sys.stderr)
        return 2
    # Human output is unchanged unless asked; --json defaults to the shared count so a bare
    # `query --json` and a bare MCP `search` produce the SAME envelope (Doc 3a §6).
    n_outlines = (args.outlines if args.outlines is not None
                  else (render.OUTLINE_RECORDS if args.json else 0))

    with IndexStore(db_path) as store:
        if refuse_if_rebuilt(store, repopulates=False):
            return 2
        cap = None
        if args.kind == "outline":
            hits = store.search(args.text, k=args.k, kind="outline",
                                document_class=args.doc_class, statuses=statuses,
                                include_sources=args.include_sources)
            index_version = store.index_version
        else:
            result = retrieve(
                store, args.text, k=args.k, document_class=args.doc_class,
                statuses=statuses, embedder=embedder, expander=expander, reranker=reranker,
                include_sources=args.include_sources, with_outlines=n_outlines,
            )
            hits, cap, index_version = result.passages, result.capability, result.index_version
            if args.json:
                # Rendered by the ENGINE, not here. The MCP server calls the same function on the
                # same result, which is what makes Doc 3a §6's equivalence a single equality
                # rather than two hand-written serializers that agree until they do not.
                print(json.dumps(
                    render.search_payload(
                        result, scope=args.scope or db_path, query=args.text,
                        statuses=statuses, include_sources=args.include_sources,
                        doc_type=args.doc_class, chars=args.chars,
                        unavailable=unavailable,
                    ),
                    indent=2, ensure_ascii=False,
                ))
                return 0
        sset = "all" if statuses is None else ",".join(sorted(statuses))
        print(f"  status filter: {sset}"
              + ("" if args.include_sources else "  ·  sources excluded (--include-sources)"))
        if not hits:
            print("  (no results)")
        for h in hits:
            print(f"\n  [{h.kind}] {h.citation}")
            body = " ".join(h.text.split())
            print(f"    {body[:args.chars]}{'…' if len(body) > args.chars else ''}")
            # Spine ON the hit (the Boundary Principle): its currency, its settledness, domain
            # tags, and — when this is a live note that replaced a dead one — the supersession link
            # that surfaces the superseded fact's identity without ever retrieving the superseded
            # note directly. `confidence` is printed ALWAYS, including `unstated`: the whole point
            # of the axis is that a proposal must not read like a settled decision, and a value
            # that disappears when it is inconvenient is prose, not a field.
            meta = [f"status={h.status}", f"doc_type={h.doc_type}",
                    f"confidence={h.confidence}"]
            if h.domains:
                meta.append(f"domains={h.domains}")
            if h.supersedes:
                meta.append(f"supersedes={h.supersedes}")
            print(f"    ↳ {' · '.join(meta)}")
            if args.expand and h.kind == "passage":
                out = store.outline_for(h.chunk_id)
                if out:
                    print(f"    ↳ orientation: {out.path_str}")
        # Surface the capability envelope — which arms actually produced this, the measured tier
        # they imply, and any mid-run fallback — instead of discarding it (the Boundary Principle).
        if cap is not None:
            print(f"\n  capability: embedder={cap.embedder or 'lexical-only'} · "
                  f"hyde={cap.hyde} · rerank={cap.reranker}")
            if cap.expected_mrr is not None:
                q = f"expected mrr: ~{cap.expected_mrr} (measured tier, {cap.cohort})"
            elif cap.fallbacks:
                q = "expected mrr: unmeasured (a wired arm fell back — see below)"
            elif not cap.embedder:
                # No embedder was available (or --no-vector): a lexical-only run, distinct from the
                # embedder-only default below. Say so rather than claim a config it isn't.
                q = "expected mrr: n/a — lexical-only (no vector arm)"
            else:
                # No number because `query` runs embedder-only BY DESIGN (no HyDE/rerank); this is
                # a lean lookup config, not a fault. The measured tiers live on the full stack (eval).
                q = "expected mrr: n/a — query runs embedder-only by design (full stack: eval)"
            print(f"  {q} · index {index_version}")
            if cap.fallbacks:
                print(f"  DEGRADED (arms fell back): {'; '.join(cap.fallbacks)}")
    return 0


def cmd_eval(args: argparse.Namespace) -> int:
    from substrate.eval.runner import GoldError, report, run

    gold_path = Path(args.gold).expanduser()
    baseline_path = Path(args.baseline).expanduser()
    baseline = json.loads(baseline_path.read_text("utf-8")) if baseline_path.exists() else None

    # Hybrid when the embedder is reachable, pure lexical when it is not. Auto-detected
    # rather than flagged, mirroring Scripta's Embedder.isConfigured: the engine should not
    # need a different command line depending on whether a local daemon happens to be up.
    embedder = None
    if not args.no_vector:
        from substrate.embed.engine import OllamaEmbedder

        from substrate.embed.engine import AppleEmbedder

        cand = (AppleEmbedder() if args.embed_model.startswith("apple")
                else OllamaEmbedder(model=args.embed_model, prefix_style=args.embed_style))
        embedder = cand if cand.available() else None
        # GUARD: a vector config with no stored vectors degrades silently to lexical-only and
        # still prints a plausible MRR. That has invalidated three measurements, every time
        # because a key change orphaned the vectors. Refuse to report rather than mislead.
        if embedder is not None:
            from substrate.store.index_store import IndexStore as _IS

            with _IS(args.db) as _s:
                _n = _s.db.execute(
                    "SELECT COUNT(*) FROM chunk_vectors WHERE embed_model=?", (embedder.key,)
                ).fetchone()[0]
                _total = _s.db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
            # COMPLETENESS, not presence. An earlier version checked >0 and would have
            # passed a partially-embedded corpus (256 of 1811 after a timeout), reporting a
            # confident MRR computed on 14% of the data. Presence was attached to the
            # result; completeness was not. Same failure family as PRINCIPLES.md.
            if _n < _total:
                print(f"FATAL: {embedder.key!r} has {_n}/{_total} vectors — "
                      f"{'none' if _n == 0 else 'INCOMPLETE (partial embed?)'}. Run: "
                      f"substrate embed --model {args.embed_model}", file=sys.stderr)
                return 2
            print(f"  vectors : {_n}/{_total} under {embedder.key}")
        # GUARD: a vector config with no vectors silently degrades to lexical-only and
        # reports a plausible number. That has now invalidated three measurements — every
        # time, because a key change orphaned the stored vectors. Refuse to report instead.
        if embedder is not None:
            from substrate.store.index_store import IndexStore as _IS

            with _IS(args.db) as _s:
                _n = _s.db.execute(
                    "SELECT COUNT(*) FROM chunk_vectors WHERE embed_model=?", (embedder.key,)
                ).fetchone()[0]
            if _n == 0:
                print(f"FATAL: no vectors stored for {embedder.key!r}. "
                      f"Run: substrate embed --model {args.embed_model} "
                      f"--embed-style {args.embed_style}", file=sys.stderr)
                return 2
            print(f"  vectors: {_n} under {embedder.key}")
        print(f"  retrieval: {'hybrid (lexical + vector)' if embedder else 'lexical only'}")
    expander = None
    if not args.no_hyde:
        from substrate.retrieve.expand import AppleFMExpander, HyDE, LlamaServerHyDE

        from substrate.embed.cache import VectorCache

        vc = VectorCache(args.cache)
        if args.hyde_model in ("apple", "apple-fm"):
            cand = AppleFMExpander(cache=vc)
        elif args.hyde_model in ("bonsai", "bonsai-27b", "llama-server"):
            cand = LlamaServerHyDE(cache=vc, prompt_id=args.hyde_prompt)
        else:
            cand = HyDE(model=args.hyde_model, cache=vc, prompt_id=args.hyde_prompt)
        expander = cand if cand.available() else None
        print(f"  expansion: {'HyDE via ' + args.hyde_model if expander else 'unavailable'}")

    mq = None
    if args.multi_query:
        from substrate.embed.cache import VectorCache as _VC
        from substrate.retrieve.expand import MultiQuery

        cand = MultiQuery(model=args.hyde_model, n=args.multi_query, cache=_VC(args.cache))
        mq = cand if cand.available() else None
        print(f"  multi-query: {args.multi_query} variants" if mq else "  multi-query: unavailable")

    # --no-gate is meaningful ONLY on a --cross-encoder rerank run. Two misuse cases, both caught
    # HERE (before the rerank block, so --no-rerank cannot skip the check): with a listwise rerank
    # the arm gates unconditionally, so "(gate off)" would mislabel a fully gated run in
    # EXPERIMENTS.md; with --no-rerank there is no gate at all, so the flag is a silent no-op.
    # Fail rather than accept a config where --no-gate does not mean what it says.
    if args.no_gate and (args.no_rerank or not args.cross_encoder):
        print("FATAL: --no-gate applies only to a --cross-encoder rerank run (the listwise arm "
              "gates unconditionally; --no-rerank has no gate). Refusing a config whose --no-gate "
              "would be silently ignored.", file=sys.stderr)
        return 2

    rr = None
    if not args.no_rerank:
        from substrate.embed.cache import VectorCache as _VC2

        if args.rerank_pool < 1:
            print("FATAL: --rerank-pool must be >= 1.", file=sys.stderr)
            return 2

        if args.rerank_model in ("apple", "apple-fm"):
            from substrate.retrieve.rerank import AppleFMReranker

            model = args.rerank_model
            # Apple FM overflows above ~10 candidates (measured), so it keeps its own default
            # unless the pool was set explicitly. Silently handing it 20 returns empty replies
            # and every query falls back to fused order.
            pool = args.rerank_pool if args.rerank_pool != 20 else 10
            cand = AppleFMReranker(pool=pool, cache=_VC2(args.cache))
        elif args.cross_encoder:
            from substrate.retrieve.rerank_cross import DEFAULT_MODEL as _CE
            from substrate.retrieve.rerank_cross import CrossEncoderReranker

            model = args.rerank_model or _CE
            cand = CrossEncoderReranker(model=model, pool=args.rerank_pool,
                                        cache=_VC2(args.cache), gate=not args.no_gate)
        else:
            from substrate.retrieve.rerank import DEFAULT_MODEL as _LW
            from substrate.retrieve.rerank import LLMReranker

            model = args.rerank_model or _LW
            cand = LLMReranker(model=model, pool=args.rerank_pool, cache=_VC2(args.cache))

        # Same discipline as the vector guard above: an arm that cannot run must refuse to
        # report, not silently report the control. A missing reranker still passes every
        # gate — those are computed on the LEXICAL cohort, which the gate mostly skips — so
        # it would exit 0 while semantic MRR quietly drops by the ~0.095 the reranker is worth.
        if not cand.available():
            print(f"FATAL: reranker {model!r} is not available at {cand.host}. "
                  f"Refusing to report an unreranked run under a reranked label.",
                  file=sys.stderr)
            return 2
        rr = cand
        kind = "cross" if args.cross_encoder else "listwise"
        gate_note = " (gate off)" if args.no_gate else ""
        # Print the RESOLVED pool, not the flag. Apple FM silently uses 10 (it overflows at
        # 20), so echoing args.rerank_pool logged "pool=20" over a run that used 10 -- a wrong
        # row in EXPERIMENTS.md, which is the failure mode this project keeps retracting for.
        print(f"  rerank: {kind} {model} pool={cand.pool}{gate_note}")

    try:
        summary, gold = run(args.db, gold_path, k=args.k, route=not args.no_route,
                            embedder=embedder, expander=expander, multiquery=mq, reranker=rr)
    except GoldError as e:
        # A bad gold file — malformed/vacuous cases, bad JSON, or no 'cases' — fails clean here,
        # like every other validation in this CLI, not with a raw traceback. Caught by TYPE, not by
        # bare ValueError: a genuine ValueError from the eval pipeline must not read as a gold bug.
        print(f"FATAL: {e}", file=sys.stderr)
        return 2

    # Refuse a number measured under a degradation its label does not state. retrieve() records
    # every mid-run arm failure — embedder, HyDE, multi-query, or a reranker that fell back to
    # fused order — ON the Trace, which run_case threads onto CaseResult.degraded. The condition
    # travels WITH the case (PRINCIPLES.md), so the eval can refuse AND name which query rather
    # than read a per-arm scalar from the side. These arms share one Ollama daemon, so one
    # hiccup can hit several at once; a single degraded query taints the aggregate.
    degraded = [c for c in summary.cases if c.degraded]
    if degraded:
        for c in degraded[:5]:
            print(f"    {c.id}: {c.degraded}", file=sys.stderr)
        print(f"\nFATAL: {len(degraded)} of {len(summary.cases)} queries degraded mid-run "
              f"(shown above) — measured under a different configuration than the label claims. "
              f"Re-run once the local daemon is stable.", file=sys.stderr)
        return 2

    if getattr(rr, "abstentions", 0):
        print(f"  note: {rr.abstentions} unparseable verdicts abstained "
              "(kept below every yes, same tier as no)")

    ok = report(summary, gold, baseline)

    if ok and args.update_baseline:
        baseline_path.write_text(
            json.dumps(
                {
                    "metrics": summary.metrics,
                    "semantic_mrr": round(
                        sum(
                            1.0 / c.both_rank
                            for c in summary.cases
                            if c.cohort == "semantic" and c.both_rank
                        )
                        / max(sum(1 for c in summary.cases if c.cohort == "semantic"), 1),
                        4,
                    ),
                    "cases": {
                        c.id: {"passed": c.passed, "rank": c.both_rank, "cohort": c.cohort}
                        for c in summary.cases
                    },
                },
                indent=2,
            ),
            encoding="utf-8",
        )
        print(f"  baseline updated -> {baseline_path}")
    return 0 if ok else 1


def cmd_embed(args: argparse.Namespace) -> int:
    from substrate.embed.engine import EmbeddingError, OllamaEmbedder
    from substrate.store.index_store import IndexStore

    from substrate.embed.engine import AppleEmbedder

    eng = (AppleEmbedder() if args.model.startswith("apple")
           else OllamaEmbedder(model=args.model, host=args.host, prefix_style=args.embed_style))
    if not eng.available():
        print(f"FATAL: {args.model!r} not available at {args.host}. "
              "Start `ollama serve` (OLLAMA_MODELS must point at the drive).", file=sys.stderr)
        return 2

    from substrate.embed.cache import VectorCache, content_sha

    t0 = time.monotonic()
    with IndexStore(args.db) as store, VectorCache(args.cache) as cache:
        if refuse_if_rebuilt(store, repopulates=False):
            return 2
        dropped = store.drop_vectors(keeping_model=eng.key)
        if dropped:
            print(f"  dropped {dropped} vectors from other model spaces")

        pending = store.chunks_missing_vectors(eng.key)
        if not pending:
            print("  index already fully embedded")
            return 0

        # Content-addressed lookup FIRST. A chunker change renumbers every chunk_id, so
        # without this the whole corpus re-embeds even when the text is largely unchanged.
        shas = {cid: content_sha(text) for cid, text in pending}
        cached = cache.get_many(sorted(set(shas.values())), eng.key)

        hits = [(cid, cached[shas[cid]]) for cid, _ in pending if shas[cid] in cached]
        misses = [(cid, text) for cid, text in pending if shas[cid] not in cached]
        print(f"  {len(pending)} chunks missing vectors · "
              f"{len(hits)} from cache · {len(misses)} to embed")

        if hits:
            store.store_vectors(hits, eng.key)

        done = 0
        for i in range(0, len(misses), 256):
            batch = misses[i : i + 256]
            try:
                vecs = eng.embed_documents([t for _, t in batch])
            except EmbeddingError as e:
                print(f"FATAL: {e}", file=sys.stderr)
                return 3
            pairs = list(zip(batch, vecs, strict=True))
            store.store_vectors([(cid, v) for (cid, _), v in pairs], eng.key)
            cache.put_many([(shas[cid], v) for (cid, _), v in pairs], eng.key)
            done += len(pairs)
            print(f"    embedded {done}/{len(misses)}", end="\r", flush=True)

        store.checkpoint()
        el = time.monotonic() - t0
        cs = cache.stats()
        print(f"\n  {len(hits)} reused · {done} embedded in {el:.1f}s")
        print(f"  cache: {cs['vectors']} vectors, {cs['bytes'] / 1e6:.1f} MB -> {args.cache}")
    return 0


def main(argv: list[str] | None = None) -> int:
    ap = argparse.ArgumentParser(prog="substrate")
    sub = ap.add_subparsers(dest="cmd", required=True)

    ing = sub.add_parser("ingest")
    ing.add_argument("--pdf", required=True)
    ing.add_argument("--doc-class", required=True, choices=sorted(classes.POLICIES))
    ing.add_argument("--out", required=True)
    ing.add_argument("--pages", default=None, help="e.g. 1-40")
    ing.add_argument("--batch", type=int, default=100)
    ing.set_defaults(func=cmd_ingest)

    ingmd = sub.add_parser("ingest-md")
    ingmd.add_argument("--md", required=True)
    ingmd.add_argument("--doc-class", default=None, choices=sorted(classes.POLICIES),
                       help="overrides frontmatter; defaults to it, else reference-frozen")
    ingmd.add_argument("--out", required=True)
    ingmd.set_defaults(func=cmd_ingest_md)

    ver = sub.add_parser("verify")
    ver.add_argument("dir")
    ver.set_defaults(func=cmd_verify)

    rc = sub.add_parser("rechunk")
    rc.add_argument("dir")
    rc.add_argument("--target", type=int, default=0)
    rc.add_argument("--max-chars", type=int, default=0)
    rc.add_argument("--min-chars", type=int, default=0)
    rc.set_defaults(func=cmd_rechunk)

    idx = sub.add_parser("index")
    idx.add_argument("--out-root", default="out")
    idx.add_argument("--db", default="out/substrate.db")
    idx.add_argument("--rebuild", action="store_true", help="drop the cache and rebuild")
    idx.set_defaults(func=cmd_index)

    comp = sub.add_parser("compose",
                          help="resolve a project vault's manifest, ingest + index the composed "
                               "scope (project + inherited), and assert the composition")
    comp.add_argument("project_vault", help="path to the project vault (holds .substrate.toml)")
    comp.add_argument("--index-root", default="out-vault/index",
                      help="where per-note ingest dirs are written (disposable, kept off cloud-sync)")
    comp.add_argument("--db", default="out-vault/index.db")
    comp.add_argument("--clean", action="store_true",
                      help="remove the index-root first, so a deleted note leaves no stale dir")
    comp.add_argument("--registry", default=None,
                      help=f"scope registry to record into (default ${scopes.ENV_VAR}, else "
                           f"{scopes.DEFAULT_REGISTRY})")
    comp.set_defaults(func=cmd_compose)

    qry = sub.add_parser("query")
    qry.add_argument("--scope", default=None,
                     help="query a composed scope by its manifest name, resolved through the "
                          "registry `compose` writes (alternative to --db)")
    qry.add_argument("--registry", default=None,
                     help=f"scope registry to resolve --scope against (default ${scopes.ENV_VAR}, "
                          f"else {scopes.DEFAULT_REGISTRY})")
    qry.add_argument("--include-sources", action="store_true",
                     help="also retrieve source-class documents (conversations), which are "
                          "excluded by default because a passage from mid-transcript "
                          "misrepresents a document whose confidence varies within it")
    qry.add_argument("text")
    # No default: an explicit --db must be distinguishable from an absent one, or --scope could
    # not refuse the ambiguous "both given" case (_resolve_db applies the legacy default).
    qry.add_argument("--db", default=None)
    qry.add_argument("--k", type=int, default=5)
    qry.add_argument("--kind", choices=["passage", "outline"], default=None)
    qry.add_argument("--doc-class", default=None)
    qry.add_argument("--chars", type=int, default=200)
    qry.add_argument("--expand", action="store_true")
    qry.add_argument("--no-vector", action="store_true")
    qry.add_argument("--full-stack", action="store_true",
                     help="wire HyDE + reranker as well as the embedder — the measured stack the "
                          "MCP server runs. Default is the lean embedder-only lookup config")
    qry.add_argument("--json", action="store_true",
                     help="emit the structured result envelope (the same one the MCP server "
                          "returns) instead of the human read-out")
    qry.add_argument("--outlines", type=int, default=None, metavar="N",
                     help=f"orientation records alongside the passages (Doc 2 §7); default 0 "
                          f"for the human read-out, {render.OUTLINE_RECORDS} under --json")
    # Default retrieval set is active+complete (Doc 2 §6). These broaden it explicitly.
    qry.add_argument("--include-archived", action="store_true",
                     help="add archived to the default active+complete set")
    qry.add_argument("--status", default=None,
                     help="explicit comma-separated status set, e.g. active,archived")
    qry.add_argument("--all-status", action="store_true",
                     help="no status filter — includes superseded (administrative scan)")
    qry.set_defaults(func=cmd_query)

    ev = sub.add_parser("eval")
    ev.add_argument("--db", default="out/substrate.db")
    ev.add_argument("--gold", default="eval/gold.json")
    ev.add_argument("--baseline", default="eval/.baseline.json")
    ev.add_argument("--k", type=int, default=5)
    ev.add_argument("--update-baseline", action="store_true")
    ev.add_argument("--no-route", action="store_true", help="disable outline routing (A/B)")
    ev.add_argument("--no-vector", action="store_true", help="force lexical-only (A/B)")
    ev.add_argument("--embed-model", default="qwen3-embedding:0.6b")
    ev.add_argument("--embed-style", default="auto", choices=["auto","nomic","none","qwen3"])
    ev.add_argument("--no-hyde", action="store_true", help="disable query expansion (A/B)")
    ev.add_argument("--hyde-model", default="qwen2.5:7b")
    ev.add_argument("--hyde-prompt", default="canonical", choices=["canonical", "distinctive"])
    ev.add_argument("--multi-query", type=int, default=0, metavar="N")
    ev.add_argument("--no-rerank", action="store_true")
    ev.add_argument("--rerank-model", default=None,
                    help="default depends on the arm: the listwise model, or the "
                         "cross-encoder under --cross-encoder")
    ev.add_argument("--rerank-pool", type=int, default=20)
    ev.add_argument("--cross-encoder", action="store_true",
                    help="pointwise Qwen3-Reranker instead of the listwise chat model")
    ev.add_argument("--no-gate", action="store_true",
                    help="rerank every query, including lexically-precise ones")
    ev.add_argument("--cache", default="out/vector-cache.db")
    ev.set_defaults(func=cmd_eval)

    emb = sub.add_parser("embed")
    emb.add_argument("--db", default="out/substrate.db")
    emb.add_argument("--model", default="qwen3-embedding:0.6b")
    emb.add_argument("--embed-style", default="auto", choices=["auto","nomic","none","qwen3"])
    emb.add_argument("--host", default="http://127.0.0.1:11434")
    emb.add_argument("--cache", default="out/vector-cache.db",
                     help="durable content-addressed cache; survives index rebuilds")
    emb.set_defaults(func=cmd_embed)

    rev = sub.add_parser("review")
    rev.add_argument("dir")
    rev.add_argument("--sample", type=int, default=15)
    rev.add_argument("--seed", type=int, default=7)
    rev.set_defaults(func=cmd_review)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
