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
class Chunk:
    """A retrievable unit. Two kinds: `passage` (leaf text) and `outline` (orientation).

    The spine is DENORMALIZED onto every chunk on purpose. A retrieved passage must be able
    to answer "is this the current Go spec?" without a join — a passage that cannot state
    its own version reads authoritative while being silently stale.
    """

    chunk_id: str
    doc_id: str
    kind: str  # "passage" | "outline"
    text: str
    path: list[str] = field(default_factory=list)
    level: int = 0

    # Provenance chain: chunk -> blocks -> pages -> the PDF.
    block_ids: list[str] = field(default_factory=list)
    char_start: int = -1
    char_end: int = -1
    page_start: int | None = None
    page_end: int | None = None

    # Packing outcome.
    n_chars: int = 0
    part_index: int | None = None
    part_count: int | None = None
    oversize: bool = False

    # Neighbours, so retrieval can expand without a second query.
    prev_id: str | None = None
    next_id: str | None = None

    # Denormalized spine.
    document_class: str = ""
    version: str | None = None
    source_sha256: str = ""
    page_label_offset: int | None = None

    @property
    def path_str(self) -> str:
        return " > ".join(self.path)

    @property
    def text_with_path(self) -> str:
        """What actually gets indexed. BM25 cannot match a path that is not in the text."""
        return f"{self.path_str}\n\n{self.text}" if self.path else self.text

    def page_label(self, page: int | None) -> int | None:
        if page is None or self.page_label_offset is None:
            return page
        return page - self.page_label_offset

    def to_json(self) -> dict:
        d = asdict(self)
        d["path_str"] = self.path_str
        d["text_with_path"] = self.text_with_path
        d["page_label_start"] = self.page_label(self.page_start)
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

    # Doc-2 spine. `status` drives the default retrieval set (§6): active/complete included,
    # archived/superseded excluded from default retrieval. `superseded_by`/`supersedes` are the
    # supersession link — a superseded note is excluded directly but its link surfaces via the
    # note that replaced it. `domains` is the multi-valued reference-retrieval tag (§3a), carried
    # as a field only — the soft-weighting feature is deferred, so nothing filters or weights on it.
    # `vault`/`tier` are composition provenance: which scoped vault a note came from, set by the
    # manifest-composition path so "did inheritance actually compose" is checkable, not inferred.
    status: str | None = None
    superseded_by: str | None = None
    supersedes: str | None = None
    domains: list[str] = field(default_factory=list)
    vault: str | None = None
    tier: int | None = None

    extractor: str = ""
    extractor_arm: str = ""
    layout_model: str = ""
    pipeline_version: str = "substrate-ingest/0.1.0"
    confidence: dict = field(default_factory=dict)

    @property
    def body_blocks(self) -> list[Block]:
        return [b for b in self.blocks if not b.dropped]
