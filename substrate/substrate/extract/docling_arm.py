"""Docling extractor arm — batched, because whole-document conversion does not scale.

Measured 2026-07-21 on DDIA (673pp): a single convert() call costs 10.80 s/page, while a
100-page batch costs 0.22 s/page at identical work density (10.2 vs 9.8 items/page). That
is a ~46x penalty from state accumulation, not a slow accelerator. So batching is structural
here, not an optimization, and one converter is reused across batches to amortize model load.
"""

from __future__ import annotations

import time
from pathlib import Path

from substrate.extract import headings, toc
from substrate.extract.base import doc_id_for, sha256_file
from substrate.extract.furniture import validate
from substrate.models import LABEL_MAP, Block, Document, Kind
from substrate.paths import ARTIFACTS

BATCH_PAGES = 100


def _converter():
    from docling.datamodel.base_models import InputFormat
    from docling.datamodel.pipeline_options import PdfPipelineOptions
    from docling.document_converter import DocumentConverter, PdfFormatOption

    opts = PdfPipelineOptions(artifacts_path=str(ARTIFACTS))
    opts.do_ocr = False  # both reference inputs carry real text layers
    opts.do_table_structure = True
    return DocumentConverter(
        format_options={InputFormat.PDF: PdfFormatOption(pipeline_options=opts)}
    )


def _content_layers():
    """Include FURNITURE: we adjudicate those labels ourselves rather than let them vanish."""
    try:
        from docling_core.types.doc.labels import ContentLayer
    except ImportError:
        try:
            from docling_core.types.doc import ContentLayer
        except ImportError:
            return None
    return set(ContentLayer)


def _iter(doc):
    layers = _content_layers()
    if layers is not None:
        try:
            yield from doc.iterate_items(included_content_layers=layers)
            return
        except TypeError:
            pass
    yield from doc.iterate_items()


def _page_count(pdf: Path) -> int:
    from docling_core.types.doc import DoclingDocument  # noqa: F401  (ensures deps loaded)
    import pypdfium2 as pdfium

    with pdfium.PdfDocument(str(pdf)) as d:
        return len(d)


def _text_of(item, doc) -> tuple[str, str | None]:
    """Return (text, code_language). Tables render as markdown; everything else is text."""
    label = str(getattr(item, "label", "")).lower()
    if "table" in label:
        for attempt in (lambda: item.export_to_markdown(doc), lambda: item.export_to_markdown()):
            try:
                return attempt(), None
            except Exception:
                continue
        return (getattr(item, "text", "") or ""), None
    text = (getattr(item, "text", "") or "").strip()
    lang = getattr(item, "code_language", None)
    return text, (str(lang) if lang else None)


class DoclingExtractor:
    name = "docling"

    def __init__(self, batch_pages: int = BATCH_PAGES):
        self.batch_pages = batch_pages
        self._conv = None

    @property
    def converter(self):
        if self._conv is None:
            self._conv = _converter()
        return self._conv

    def extract(
        self, pdf: Path, doc_class: str, *, pages: tuple[int, int] | None = None, log=print
    ) -> Document:
        from importlib.metadata import version as pkg_version

        total = _page_count(pdf)
        first, last = pages or (1, total)
        last = min(last, total)

        blocks: list[Block] = []
        n = 0
        t0 = time.monotonic()

        for start in range(first, last + 1, self.batch_pages):
            end = min(start + self.batch_pages - 1, last)
            bt = time.monotonic()
            result = self.converter.convert(str(pdf), page_range=(start, end))
            for item, _lvl in _iter(result.document):
                label = str(getattr(item, "label", "")).lower().split(".")[-1]
                text, lang = _text_of(item, result.document)
                if not text:
                    continue
                prov = getattr(item, "prov", None)
                page = getattr(prov[0], "page_no", None) if prov else None
                height = left = None
                if prov and getattr(prov[0], "bbox", None):
                    bb = prov[0].bbox
                    height, left = round(abs(bb.t - bb.b), 1), round(bb.l, 1)
                layer = str(getattr(item, "content_layer", "")).upper()
                kind = LABEL_MAP.get(label, Kind.TEXT)
                n += 1
                blocks.append(
                    Block(
                        id=f"b{n:06d}",
                        kind=kind,
                        text=text,
                        page=page,
                        label=label,
                        level=None,  # docling reports 1 for everything; inferred later
                        lang=lang,
                        height=height,
                        left=left,
                        furniture_claimed=("FURNITURE" in layer or kind is Kind.FURNITURE),
                    )
                )
            log(
                f"  pages {start:>4}-{end:<4} {time.monotonic() - bt:6.1f}s  "
                f"({len(blocks)} blocks so far)"
            )

        elapsed = time.monotonic() - t0

        # Adjudicate furniture across the WHOLE document — repetition is a document-level
        # signal, so this cannot run per batch.
        claimed = [b for b in blocks if b.furniture_claimed]
        verdict = validate(claimed)
        honored = {id(b) for b in verdict.honored}
        for b in claimed:
            if id(b) in honored:
                b.furniture_honored = True
            else:
                b.readmit_reason = verdict.reasons.get(id(b), "")
                b.kind = Kind.TEXT if b.kind is Kind.FURNITURE else b.kind

        # Heading levels are INFERRED — docling reports every heading as level 1 with a
        # flat parent tree, so the hierarchy has to come from glyph geometry.
        toc_pages = {b.page for b in blocks if b.kind is Kind.INDEX and b.page}
        toc_pages |= toc.contents_pages(blocks)
        ladder = headings.build(blocks, toc_pages=toc_pages)
        hstats = headings.assign(blocks, ladder)

        # Contents lists must be marked AFTER heading levels exist — the detector works by
        # matching a block's text against the document's own heading vocabulary.
        toc_report = toc.mark(blocks)

        doc = Document(
            doc_id=doc_id_for(pdf),
            source_path=str(pdf),
            source_sha256=sha256_file(pdf),
            source_pages=total,
            document_class=doc_class,
            blocks=blocks,
            extractor=f"docling {pkg_version('docling')}",
            extractor_arm=self.name,
            layout_model="docling-layout-heron",
        )
        doc.confidence.update(
            {
                "blocks": len(blocks),
                "pages_processed": last - first + 1,
                "seconds": round(elapsed, 1),
                "seconds_per_page": round(elapsed / max(last - first + 1, 1), 3),
                "furniture_claimed": len(claimed),
                "furniture_honored": len(verdict.honored),
                "furniture_readmitted": len(verdict.readmitted),
                "toc_blocks_marked": toc_report.blocks_marked,
                "toc_by_label": toc_report.by_label,
                "toc_by_structure": toc_report.by_structure,
                "toc_coverage": toc_report.coverage,
                "heading_tiers": ladder.tiers,
                "heading_tier_counts": {str(k): v for k, v in ladder.counts.items()},
                **{f"headings_{k}": v for k, v in hstats.items()},
            }
        )
        return doc
