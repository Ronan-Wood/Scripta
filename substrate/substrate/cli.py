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

    checks.append(("A14 coverage >= 0.95", run["coverage"] >= 0.95, f"{run['coverage']}"))
    checks.append(("A14 paths present", run["chunk"]["path_depth_ge2_pct"] >= 60, f"{run['chunk']['path_depth_ge2_pct']}%"))

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

    with IndexStore(args.db) as store:
        hits = store.search(
            args.text, k=args.k, kind=args.kind, document_class=args.doc_class
        )
        if not hits:
            print("  (no results)")
            return 0
        for h in hits:
            print(f"\n  [{h.kind}] {h.citation}")
            body = " ".join(h.text.split())
            print(f"    {body[:args.chars]}{'…' if len(body) > args.chars else ''}")
            if args.expand and h.kind == "passage":
                out = store.outline_for(h.chunk_id)
                if out:
                    print(f"    ↳ orientation: {out.path_str}")
    return 0


def cmd_eval(args: argparse.Namespace) -> int:
    from substrate.eval.runner import report, run

    gold_path = Path(args.gold).expanduser()
    baseline_path = Path(args.baseline).expanduser()
    baseline = json.loads(baseline_path.read_text("utf-8")) if baseline_path.exists() else None

    summary, gold = run(args.db, gold_path, k=args.k, route=not args.no_route)
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

    ver = sub.add_parser("verify")
    ver.add_argument("dir")
    ver.set_defaults(func=cmd_verify)

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
    qry.set_defaults(func=cmd_query)

    ev = sub.add_parser("eval")
    ev.add_argument("--db", default="out/substrate.db")
    ev.add_argument("--gold", default="eval/gold.json")
    ev.add_argument("--baseline", default="eval/.baseline.json")
    ev.add_argument("--k", type=int, default=5)
    ev.add_argument("--update-baseline", action="store_true")
    ev.add_argument("--no-route", action="store_true", help="disable outline routing (A/B)")
    ev.set_defaults(func=cmd_eval)

    rev = sub.add_parser("review")
    rev.add_argument("dir")
    rev.add_argument("--sample", type=int, default=15)
    rev.add_argument("--seed", type=int, default=7)
    rev.set_defaults(func=cmd_review)

    args = ap.parse_args(argv)
    return args.func(args)


if __name__ == "__main__":
    raise SystemExit(main())
