"""Phase 0 probe — does Docling's layout model actually solve our three measured problems?

The spec bets on label classification replacing four hand-rolled subsystems. This tests
that bet directly, on the real files, before anything else is built:

  Q1  DDIA parity-dependent recto/verso footers  -> classified PAGE_FOOTER?
  Q2  Go spec bare-line headings, ZERO outline   -> classified SECTION_HEADER?
  Q3  Go spec 2-col TOC leaking into body        -> classified DOCUMENT_INDEX?
  Q4  Does the '!' soft hyphen survive extraction? (it should — that stays ours to fix)

Run twice and diff the dump for A15 (determinism), the one result that can still
disqualify Docling.
"""

from __future__ import annotations

import argparse
import json
import re
import sys
from collections import Counter
from pathlib import Path

sys.path.insert(0, str(Path(__file__).parent))
from substrate.paths import ARTIFACTS, configure, internal_cache_footprint  # noqa: E402

configure()  # MUST run before docling is imported — HF reads cache env at import time

from importlib.metadata import version as _pkg_version  # noqa: E402

from docling.datamodel.base_models import InputFormat  # noqa: E402
from docling.datamodel.pipeline_options import PdfPipelineOptions  # noqa: E402
from docling.document_converter import DocumentConverter, PdfFormatOption  # noqa: E402


def all_content_layers():
    """Include FURNITURE — the whole point is seeing whether footers were classified as such."""
    try:
        from docling_core.types.doc.labels import ContentLayer
    except ImportError:
        try:
            from docling_core.types.doc import ContentLayer
        except ImportError:
            return None
    return set(ContentLayer)


def build_converter() -> DocumentConverter:
    opts = PdfPipelineOptions(artifacts_path=str(ARTIFACTS))
    opts.do_ocr = False          # both inputs have real text layers
    opts.do_table_structure = True
    return DocumentConverter(
        format_options={InputFormat.PDF: PdfFormatOption(pipeline_options=opts)}
    )


def iter_items(doc):
    layers = all_content_layers()
    if layers is not None:
        try:
            yield from doc.iterate_items(included_content_layers=layers)
            return
        except TypeError:
            pass  # older signature
    yield from doc.iterate_items()


def probe(pdf: Path, pages: tuple[int, int], out: Path) -> dict:
    conv = build_converter()
    try:
        result = conv.convert(str(pdf), page_range=pages)
    except TypeError:
        print("  ! page_range unsupported on this version — converting whole doc")
        result = conv.convert(str(pdf))

    doc = result.document
    labels, layers, rows = Counter(), Counter(), []

    for item, _level in iter_items(doc):
        label = str(getattr(item, "label", "?"))
        layer = str(getattr(item, "content_layer", "?"))
        text = (getattr(item, "text", "") or "").strip()
        page = None
        prov = getattr(item, "prov", None)
        if prov:
            page = getattr(prov[0], "page_no", None)

        labels[label] += 1
        layers[layer] += 1
        rows.append({"label": label, "layer": layer, "page": page, "text": text[:160]})

    out.write_text(
        "\n".join(json.dumps(r, ensure_ascii=False, sort_keys=True) for r in rows),
        encoding="utf-8",
    )

    md = doc.export_to_markdown()
    out.with_suffix(".md").write_text(md, encoding="utf-8")

    # Furniture gets FULL text, untruncated — this is the evidence the furniture
    # validator is designed against. False positives are long; 160 chars hides them.
    furniture = [r for r in rows if "FURNITURE" in r["layer"].upper()]
    for f, item in zip(
        furniture,
        [i for i, _ in iter_items(doc) if "FURNITURE" in str(getattr(i, "content_layer", "")).upper()],
        strict=False,
    ):
        f["text_full"] = (getattr(item, "text", "") or "").strip()
    out.with_suffix(".furniture.jsonl").write_text(
        "\n".join(json.dumps(r, ensure_ascii=False, sort_keys=True) for r in furniture),
        encoding="utf-8",
    )
    return {
        "labels": labels,
        "layers": layers,
        "rows": rows,
        "markdown": md,
        "n_items": len(rows),
    }


def report(name: str, res: dict) -> None:
    print(f"\n{'=' * 70}\n{name}\n{'=' * 70}")
    print(f"items: {res['n_items']}")
    print("\n-- label histogram --")
    for label, n in res["labels"].most_common():
        print(f"  {n:>5}  {label}")
    print("\n-- content_layer histogram --")
    for layer, n in res["layers"].most_common():
        print(f"  {n:>5}  {layer}")

    def sample(pred, title, limit=8):
        hits = [r for r in res["rows"] if pred(r)]
        print(f"\n-- {title}: {len(hits)} --")
        for r in hits[:limit]:
            print(f"  p{r['page']}  [{r['layer']}]  {r['text'][:100]!r}")

    sample(lambda r: "page_footer" in r["label"].lower(), "PAGE_FOOTER (Q1)")
    sample(lambda r: "page_header" in r["label"].lower(), "PAGE_HEADER (Q1)")
    sample(lambda r: "section_header" in r["label"].lower(), "SECTION_HEADER (Q2)", limit=12)
    sample(lambda r: "document_index" in r["label"].lower(), "DOCUMENT_INDEX (Q3)")

    # Q4 — the soft hyphen is ours to fix regardless of extractor; confirm it survives.
    md = res["markdown"]
    bang = re.findall(r"[a-z]![a-z]{2,}", md)
    print(f"\n-- Q4 soft-hyphen artifacts in exported markdown: {len(bang)} --")
    for m in bang[:10]:
        print(f"  {m!r}")


def main() -> None:
    ap = argparse.ArgumentParser()
    ap.add_argument("--pdf", required=True)
    ap.add_argument("--pages", default="1-40")
    ap.add_argument("--out", required=True)
    ap.add_argument("--name", default="")
    a = ap.parse_args()

    start, end = (int(x) for x in a.pages.split("-"))
    pdf = Path(a.pdf).expanduser()
    out = Path(a.out)
    out.parent.mkdir(parents=True, exist_ok=True)

    print(f"docling {_pkg_version('docling')}  artifacts={ARTIFACTS}")
    print(f"reading {pdf.name} pages {start}-{end}")

    res = probe(pdf, (start, end), out)
    report(a.name or pdf.name, res)
    print(f"\ndump -> {out}")
    print(f"internal cache: {internal_cache_footprint()}")


if __name__ == "__main__":
    main()
