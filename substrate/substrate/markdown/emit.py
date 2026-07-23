"""Markdown emission — the substrate of record.

Two properties make this more than a dump:

1. **Offset mapping.** Every block records `char_start`/`char_end` into the emitted body, so
   `blocks.jsonl` lets the document be re-chunked, re-scored, or re-provenanced WITHOUT
   re-parsing the PDF. Re-parsing costs 2.5 minutes and a pinned model; re-chunking should
   cost milliseconds. This is what makes markdown-as-truth practical rather than slogan.

2. **Calibrate globally, repair locally.** Hyphen calibration needs the whole document (the
   glyph is chosen by fragment validity against the document vocabulary), but repairs must
   be applied per block BEFORE assembly — otherwise every repair shifts the offsets of
   everything after it and the mapping silently rots.
"""

from __future__ import annotations

from substrate.models import Block, Document, Kind
from substrate.text.hyphens import Calibration, calibrate, dehyphenate
from substrate.text.normalize import clean_block, repair_ligatures

# Page anchors are HTML comments: invisible when rendered, greppable, and stripped by the
# chunker so they never enter a passage's text.
PAGE_ANCHOR = "<!-- page:{page} -->"


def _render(b: Block) -> str:
    if b.kind is Kind.HEADING and b.level:
        return f"{'#' * min(b.level, 6)} {b.text}"
    if b.kind is Kind.CODE:
        lang = b.lang if b.lang and b.lang != "unknown" else ""
        return f"```{lang}\n{b.text}\n```"
    if b.kind is Kind.LIST_ITEM:
        return f"- {b.text}"
    if b.kind is Kind.TABLE:
        return b.text
    if b.kind is Kind.CAPTION:
        return f"*{b.text}*"
    if b.kind is Kind.FIGURE:
        return f"*{b.text}*" if b.text else ""
    return b.text


def _repair_blocks(blocks: list[Block], cal: Calibration) -> dict:
    """Apply ligature + hyphen repair per block, so offsets computed after are stable."""
    stats = {"ligatures": 0, "hyphens": 0, "kept_hyphen": 0}
    for b in blocks:
        if b.kind in (Kind.CODE, Kind.TABLE):
            b.text = clean_block(b.text)  # control bytes still get stripped
            continue  # but never rewrite code or table CONTENT
        text = clean_block(b.text)
        text, lig = repair_ligatures(text)
        text, hyp = dehyphenate(text, cal)
        b.text = text
        stats["ligatures"] += lig["joined"]
        stats["hyphens"] += hyp["joined"]
        stats["kept_hyphen"] += hyp["kept_hyphen"]
    return stats


def emit(doc: Document, *, repair: bool = True) -> tuple[str, dict]:
    """Render the document body, filling char offsets on every emitted block.

    `repair=False` is the markdown path: markdown carries NO glyph artifacts (soft hyphens,
    split ligatures are ToUnicode-mapping defects of a PDF text layer), so re-running that
    repair on already-clean authored text can only MUTATE it — measured joining 8 real words on
    one reference doc's round-trip. So the markdown arm skips calibration + glyph repair and
    applies only clean_block hygiene (NFC, control-byte strip, nbsp→space), which is
    token-preserving. The PDF path keeps the default and is byte-identical to before.
    """
    body_blocks = [b for b in doc.body_blocks if b.kind is not Kind.INDEX and b.text.strip()]

    if repair:
        # Pass 1 — calibrate against the whole document.
        raw = "\n\n".join(b.text for b in body_blocks)
        cal = calibrate(raw)
        # Pass 2 — repair in place.
        repairs = _repair_blocks(body_blocks, cal)
    else:
        for b in body_blocks:
            b.text = clean_block(b.text)  # hygiene only; never glyph repair on clean markdown
        cal = Calibration(glyph=None)
        repairs = {"ligatures": 0, "hyphens": 0, "kept_hyphen": 0}

    # Pass 3 — assemble, recording offsets against the FINAL text.
    parts: list[str] = []
    cursor = 0
    page = None

    for b in body_blocks:
        if b.page is not None and b.page != page:
            anchor = PAGE_ANCHOR.format(page=b.page)
            parts.append(anchor)
            cursor += len(anchor) + 2
            page = b.page

        rendered = _render(b)
        if not rendered:
            continue
        b.char_start = cursor
        b.char_end = cursor + len(rendered)
        parts.append(rendered)
        cursor += len(rendered) + 2

    # Assembly is already clean (blocks were normalized individually), so the only remaining
    # step is a trailing newline — appended at the END so no block offset can move.
    body = "\n\n".join(parts)
    if not body.endswith("\n"):
        body += "\n"

    stats = {
        "hyphen_glyph": cal.glyph,
        "hyphen_scores": cal.rejected,
        **repairs,
        "blocks_emitted": sum(1 for b in body_blocks if b.char_start >= 0),
        "body_chars": len(body),
    }
    return body, stats


def frontmatter(doc: Document, extra: dict | None = None) -> str:
    """YAML frontmatter carrying the spine.

    Delimiter LINES only and flow lists, matching ScriptaShared/Frontmatter.swift, so the
    Swift side can read these files without a second parser.
    """
    f: dict[str, object] = {
        "app": "substrate",
        "doc_id": doc.doc_id,
        "title": doc.title or doc.doc_id,
        "document_class": doc.document_class,
        "source_path": doc.source_path,
        "source_sha256": doc.source_sha256,
        "source_pages": doc.source_pages,
        "extractor": doc.extractor,
        "extractor_arm": doc.extractor_arm,
        "layout_model": doc.layout_model,
        "pipeline_version": doc.pipeline_version,
    }
    if doc.version:
        f["version"] = doc.version
    if doc.version_date:
        f["version_date"] = doc.version_date
    if doc.page_label_offset is not None:
        f["page_label_offset"] = doc.page_label_offset
    f.update(extra or {})

    lines = ["---"]
    for k, v in f.items():
        if isinstance(v, list):
            lines.append(f"{k}: [{', '.join(str(x) for x in v)}]")
        elif isinstance(v, str) and (":" in v or v.startswith(("[", "{", "#"))):
            lines.append(f'{k}: "{v}"')
        else:
            lines.append(f"{k}: {v}")
    lines.append("---")
    return "\n".join(lines) + "\n\n"
