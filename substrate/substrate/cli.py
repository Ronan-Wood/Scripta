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

from substrate import classes
from substrate.paths import ARTIFACTS, configure, internal_cache_footprint

# A18 aggregate floor. Markdown ingestion must not silently drop source content end-to-end
# (source → chunks). Measured 0.9998–1.0 across the three reference docs AND a 900-char note; the
# tiny margin is empty "Table of Contents" headings, never a dropped line. This ratio catches
# LARGE/systematic loss; a small categorical drop in a big doc is caught by the per-block
# survival check (uncovered_content_blocks), which is size-independent.
MD_COVERAGE_GATE = 0.99


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
        "extract": doc.confidence,
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
    """Ingest a markdown file → canonical Document → chunks. The vault path.

    No PDF, no Docling, no torch — markdown hands us the structure the PDF path had to recover
    from glyph geometry. Proves the adapter the way cmd_rechunk proves the chunker: markdown in,
    the SAME Document shape out, straight into the existing emit()/chunk() with the PDF path
    untouched. A18 guards against the silent-loss failure this project keeps hitting.
    """
    from substrate.chunk.chunker import chunk
    from substrate.markdown.emit import emit, frontmatter
    from substrate.markdown.reader import (
        content_coverage,
        read_markdown,
        uncovered_content_blocks,
    )

    src = Path(args.md).expanduser()
    if not src.exists():
        print(f"FATAL: no such file: {src}", file=sys.stderr)
        return 2

    out = Path(args.out).expanduser()
    out.mkdir(parents=True, exist_ok=True)

    t0 = time.monotonic()
    print(f"ingesting : {src.name}  (markdown)")

    try:
        doc, body_md, rstats = read_markdown(src, doc_class=args.doc_class)
    except ValueError as e:  # over-size file or non-UTF-8 bytes — refuse cleanly, no traceback
        print(f"\nFATAL: cannot read {src.name}: {e}", file=sys.stderr)
        return 2

    try:
        meta = classes.apply(doc)
    except classes.ClassPolicyError as e:
        print(f"\nFATAL (class policy): {e}", file=sys.stderr)
        return 3

    # repair=False: markdown carries no glyph artifacts, so the PDF-tier hyphen/ligature repair
    # can only mutate clean authored text (measured: 8 words welded on one round-trip).
    body, estats = emit(doc, repair=False)
    chunks, cstats = chunk(doc)

    # A18 — end-to-end source→chunks coverage, the silent-loss guard, measured against the SOURCE
    # (A14's chunk-chars/body-chars ratio can't see a dropped line — it leaves the body too).
    # `captured` is everything the source content should survive INTO: chunk text_with_path (a
    # heading's tokens ride along via the path it became), each fence-language, and every heading
    # block's own text — an empty-section heading forms no chunk (its section is empty), so
    # without this its words would score as "dropped" and falsely refuse a valid outline note.
    # Heading STRUCTURE is A17's job, not A18's. Two checks: the aggregate ratio for large loss,
    # and the per-block survival list for a small categorical drop a big doc's ratio would hide.
    from substrate.models import Kind

    captured = (
        [c.text_with_path for c in chunks]
        + [b.lang for b in doc.blocks if b.lang]
        + [b.text for b in doc.blocks if b.kind is Kind.HEADING]
    )
    src_cov, src_missing = content_coverage(body_md, captured)
    drops = uncovered_content_blocks(doc.blocks, captured)
    if src_cov < MD_COVERAGE_GATE or drops:
        # Refuse rather than write a silently-lossy ingest.
        print(f"\nFATAL (A18 markdown coverage): aggregate {src_cov} (gate {MD_COVERAGE_GATE}); "
              f"{len(drops)} content block(s) dropped {drops[:8]}; missing tokens {src_missing}",
              file=sys.stderr)
        return 3

    (out / "document.md").write_text(frontmatter(doc, {"version_source": None}) + body, "utf-8")
    _write_jsonl(out / "blocks.jsonl", [b.to_json() for b in doc.blocks])
    _write_jsonl(out / "chunks.jsonl", [c.to_json() for c in chunks])

    run = {
        "doc_id": doc.doc_id,
        "source": str(src),
        "source_sha256": doc.source_sha256,
        "pages": doc.source_pages,
        "source_format": "markdown",
        "elapsed_s": round(time.monotonic() - t0, 1),
        "class": meta,
        "extract": {
            "extractor": doc.extractor, "extractor_arm": doc.extractor_arm,
            "layout_model": doc.layout_model,
            "source_coverage": src_cov, "source_coverage_missing": src_missing,
            "content_block_drops": drops, **rstats,
        },
        "emit": estats,
        "chunk": cstats,
        "coverage": round(cstats["sum_chunk_chars"] / max(len(body), 1), 4),
    }
    (out / "run.json").write_text(json.dumps(run, indent=2, ensure_ascii=False), "utf-8")

    print(f"\n  title      : {meta['title']}")
    if meta.get("version"):
        print(f"  version    : {meta['version']}  ({meta.get('version_date')})")
    print(f"  blocks     : {rstats['blocks']}  "
          f"(headings {rstats['headings']} · code {rstats['code']} · "
          f"tables {rstats['tables']} · list {rstats['list_items']})")
    print(f"  body       : {len(body):,} chars")
    print(f"  passages   : {cstats['passages']}  outlines: {cstats['outlines']}")
    print(f"  sizes      : p5={cstats['chars_p5']} p50={cstats['chars_p50']} p95={cstats['chars_p95']}")
    print(f"  well-formed: {cstats['well_formed_pct']}%  (fragments: {cstats['short_fragments']})")
    print(f"  A14 re-emit coverage    : {run['coverage']}")
    print(f"  A18 source→chunk coverage: {src_cov}")
    print(f"  elapsed    : {run['elapsed_s']}s")
    print(f"\nwrote -> {out}")
    return 0


def cmd_verify(args: argparse.Namespace) -> int:
    """Assertions over an ingested directory. Non-zero exit on failure, for CI."""
    from substrate.text.hyphens import residue
    from substrate.text.normalize import ligature_residue

    out = Path(args.dir).expanduser()
    body = (out / "document.md").read_text("utf-8")
    run = json.loads((out / "run.json").read_text("utf-8"))
    chunks = [json.loads(x) for x in (out / "chunks.jsonl").read_text("utf-8").splitlines() if x]

    passages = [c for c in chunks if c["kind"] == "passage"]
    checks: list[tuple[str, bool, str]] = []

    checks.append(("A1  hyphen residue", residue(body) <= 2, f"{residue(body)} left"))
    checks.append(
        ("A1b ligature residue", ligature_residue(body) == 0, f"{ligature_residue(body)} left")
    )
    checks.append(("A12 version captured", not (run["class"]["document_class"] == "reference-versioned" and not run["class"]["version"]), str(run["class"].get("version"))))
    checks.append(("A13 no fragments", run["chunk"]["short_fragments"] == 0, f"{run['chunk']['short_fragments']}"))
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
    checks.append(
        (
            "A17 no stale ancestor",
            worst_share <= 0.30 or len(spans) <= 2,
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
    # A17 carry the real content/structure guarantees.
    is_md = run.get("source_format") == "markdown"
    a14 = run["coverage"] >= 0.95
    name14 = "A14 coverage (report-only, md)" if is_md and not a14 else "A14 coverage >= 0.95"
    checks.append((name14, a14 or is_md, f"{run['coverage']}"))
    a14p = run["chunk"]["path_depth_ge2_pct"] >= 60
    name14p = "A14 paths (report-only, md)" if is_md and not a14p else "A14 paths present"
    checks.append((name14p, a14p or is_md, f"{run['chunk']['path_depth_ge2_pct']}%"))

    # A18 — markdown ingestion only. End-to-end source→chunks coverage: A14 above compares chunk
    # chars to the re-emitted BODY, so a stage that dropped a source line passes it (the line is
    # absent from both sides). A18 compares against the SOURCE file. Two parts, both must hold:
    # the aggregate token ratio (large loss) and zero dropped content blocks (a small categorical
    # drop a big doc's ratio would hide). Heading/path STRUCTURE is A17's job, not A18's.
    if is_md:
        ex = run.get("extract", {})
        cov = ex.get("source_coverage")
        drops = ex.get("content_block_drops", [])
        checks.append(
            ("A18 md source coverage",
             cov is not None and cov >= MD_COVERAGE_GATE and not drops,
             f"{cov} · {len(drops)} block(s) dropped {drops[:5]} · missing "
             f"{ex.get('source_coverage_missing')}")
        )

    width = max(len(n) for n, _, _ in checks)
    failed = 0
    for name, ok, detail in checks:
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
    from substrate.models import Block, Chunk, Document, Kind

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
    from substrate.store.index_store import IndexStore
    from substrate.store.reconcile import reconcile

    root = Path(args.out_root).expanduser()
    with IndexStore(args.db) as store:
        if store.rebuilt:
            print("schema version changed -> index dropped and rebuilt from markdown")
        if args.rebuild:
            store.clear()
            print("cleared index (markdown is the source of truth)")
        rep = reconcile(store, root)
        s = store.stats()

    print(
        f"  added {len(rep.added)} · updated {len(rep.updated)} · "
        f"unchanged {len(rep.unchanged)} · removed {len(rep.removed)}"
    )
    print(f"  {s['documents']} documents · {s['passages']} passages · {s['outlines']} outlines")
    print(f"  db: {args.db} (schema v{s['schema_version']})")
    return 0


def cmd_query(args: argparse.Namespace) -> int:
    from substrate.store.index_store import IndexStore

    from substrate.embed.engine import OllamaEmbedder
    from substrate.retrieve.retriever import retrieve

    cand = OllamaEmbedder()
    embedder = None if args.no_vector else (cand if cand.available() else None)

    with IndexStore(args.db) as store:
        cap = None
        if args.kind == "outline":
            hits = store.search(args.text, k=args.k, kind="outline", document_class=args.doc_class)
            index_version = store.index_version
        else:
            result = retrieve(
                store, args.text, k=args.k, document_class=args.doc_class, embedder=embedder
            )
            hits, cap, index_version = result.passages, result.capability, result.index_version
        if not hits:
            print("  (no results)")
        for h in hits:
            print(f"\n  [{h.kind}] {h.citation}")
            body = " ".join(h.text.split())
            print(f"    {body[:args.chars]}{'…' if len(body) > args.chars else ''}")
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
    from substrate.eval.runner import report, run

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

    summary, gold = run(args.db, gold_path, k=args.k, route=not args.no_route,
                        embedder=embedder, expander=expander, multiquery=mq, reranker=rr)

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

    qry = sub.add_parser("query")
    qry.add_argument("text")
    qry.add_argument("--db", default="out/substrate.db")
    qry.add_argument("--k", type=int, default=5)
    qry.add_argument("--kind", choices=["passage", "outline"], default=None)
    qry.add_argument("--doc-class", default=None)
    qry.add_argument("--chars", type=int, default=200)
    qry.add_argument("--expand", action="store_true")
    qry.add_argument("--no-vector", action="store_true")
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
