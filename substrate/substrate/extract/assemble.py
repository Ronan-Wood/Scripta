"""The document-level half of PDF extraction, shared by every PDF reader.

A reader turns pages into `Block`s. Everything that needs the WHOLE document happens here, once, in
the same order for each reader: furniture adjudication, because repetition is a document-level
signal; heading levels, because the ladder comes from glyph height across the document; and contents
detection, because it matches text against the document's own heading vocabulary. Two readers each
carrying this sequence would be two places for its ordering constraints to drift apart.
"""

from __future__ import annotations

from pathlib import Path

from substrate.extract import headings, toc
from substrate.extract.base import doc_id_for, sha256_file
from substrate.extract.furniture import validate
from substrate.models import LABEL_MAP, Block, Document, Kind


def assemble(
    pdf: Path,
    doc_class: str,
    blocks: list[Block],
    *,
    total_pages: int,
    pages_processed: int,
    seconds: float,
    extractor: str,
    extractor_arm: str,
    layout_model: str,
    stats: dict | None = None,
) -> Document:
    """Adjudicate furniture, infer heading levels, mark contents, and build the Document."""
    # Adjudicate furniture across the WHOLE document — repetition is a document-level
    # signal, so this cannot run per batch.
    #
    # A re-admitted block gets back the kind its LABEL names. docling's furniture labels map to
    # FURNITURE, so theirs become TEXT exactly as before; the text-layer reader claims a block by
    # position and labels it with what it would otherwise be, so a chapter title that happens to sit
    # near the top edge comes back a heading rather than a paragraph.
    claimed = [b for b in blocks if b.furniture_claimed]
    verdict = validate(claimed)
    honored = {id(b) for b in verdict.honored}
    for b in claimed:
        if id(b) in honored:
            b.furniture_honored = True
        else:
            b.readmit_reason = verdict.reasons.get(id(b), "")
            if b.kind is Kind.FURNITURE:
                restored = LABEL_MAP.get(b.label, Kind.TEXT)
                b.kind = Kind.TEXT if restored is Kind.FURNITURE else restored

    # Heading levels are INFERRED — docling reports every heading as level 1 with a
    # flat parent tree, so the hierarchy has to come from glyph geometry.
    # Verify docling's DOCUMENT_INDEX claim before acting on it — it mislabels
    # chapter-opening pages, which silently corrupts every downstream path.
    reclaimed = headings.reclaim_titles(blocks)

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
        source_pages=total_pages,
        document_class=doc_class,
        blocks=blocks,
        extractor=extractor,
        extractor_arm=extractor_arm,
        layout_model=layout_model,
    )
    doc.extract_confidence.update(
        {
            "blocks": len(blocks),
            "pages_processed": pages_processed,
            "seconds": round(seconds, 1),
            "seconds_per_page": round(seconds / max(pages_processed, 1), 3),
            "furniture_claimed": len(claimed),
            "furniture_honored": len(verdict.honored),
            "furniture_readmitted": len(verdict.readmitted),
            "titles_reclaimed_from_index": reclaimed,
            "toc_blocks_marked": toc_report.blocks_marked,
            "toc_by_label": toc_report.by_label,
            "toc_by_structure": toc_report.by_structure,
            "toc_coverage": toc_report.coverage,
            "heading_tiers": ladder.tiers,
            "heading_tier_counts": {str(k): v for k, v in ladder.counts.items()},
            **{f"headings_{k}": v for k, v in hstats.items()},
            **(stats or {}),
        }
    )
    return doc
