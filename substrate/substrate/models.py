"""Canonical document model — the seam that makes the extractor swappable.

Every extractor arm (Docling primary, PyMuPDF comparator) produces these types. Nothing
downstream — normalization, markdown emission, chunking — imports an extractor. That is
what keeps the extractor choice a contained decision rather than a rewrite.
"""

from __future__ import annotations

from dataclasses import asdict, dataclass, field
from enum import Enum


class Kind(str, Enum):
    """Normalized block kinds. Docling's label vocabulary maps onto these."""

    TEXT = "text"
    HEADING = "heading"
    LIST_ITEM = "list_item"
    CODE = "code"
    TABLE = "table"
    CAPTION = "caption"
    FIGURE = "figure"
    FORMULA = "formula"
    FURNITURE = "furniture"
    INDEX = "index"


# Docling label -> our kind. Anything unmapped falls back to TEXT.
LABEL_MAP = {
    "text": Kind.TEXT,
    "paragraph": Kind.TEXT,
    "section_header": Kind.HEADING,
    "title": Kind.HEADING,
    "list_item": Kind.LIST_ITEM,
    "code": Kind.CODE,
    "table": Kind.TABLE,
    "caption": Kind.CAPTION,
    "picture": Kind.FIGURE,
    "formula": Kind.FORMULA,
    "page_header": Kind.FURNITURE,
    "page_footer": Kind.FURNITURE,
    "footnote": Kind.TEXT,
    "document_index": Kind.INDEX,
}


@dataclass
class Block:
    """One extracted unit, before any normalization or chunking."""

    id: str
    kind: Kind
    text: str
    page: int | None = None
    label: str = ""            # the extractor's raw label, kept for audit
    level: int | None = None   # heading depth — INFERRED, see extract/headings.py
    lang: str | None = None    # code language, when inferable

    # Geometry. Docling reports every heading as level 1 with a flat parent tree, so glyph
    # height is the only available hierarchy signal, and left-edge separates TOC columns.
    height: float | None = None
    left: float | None = None

    # Furniture adjudication — a label is a claim, not an instruction.
    furniture_claimed: bool = False
    furniture_honored: bool = False
    readmit_reason: str = ""

    # Offsets into the emitted markdown body; filled by the emitter.
    char_start: int = -1
    char_end: int = -1

    @property
    def dropped(self) -> bool:
        return self.furniture_honored

    def to_json(self) -> dict:
        d = asdict(self)
        d["kind"] = self.kind.value
        return d


@dataclass
class Document:
    """A whole extracted document plus the provenance/confidence spine."""

    doc_id: str
    source_path: str
    source_sha256: str
    source_pages: int
    document_class: str
    blocks: list[Block] = field(default_factory=list)

    title: str | None = None
    version: str | None = None
    version_date: str | None = None
    version_source: str | None = None
    page_label_offset: int | None = None

    extractor: str = ""
    extractor_arm: str = ""
    layout_model: str = ""
    pipeline_version: str = "substrate-ingest/0.1.0"
    confidence: dict = field(default_factory=dict)

    @property
    def body_blocks(self) -> list[Block]:
        return [b for b in self.blocks if not b.dropped]
