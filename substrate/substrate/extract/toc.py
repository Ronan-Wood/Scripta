"""Table-of-contents detection.

Docling's `DOCUMENT_INDEX` label fires on DDIA (18 regions over the TOC and back index) but
NOT on the Go spec, where the entire contents list arrives as an ordinary `text` block —
a run-on of ~100 section names that would otherwise enter the substrate as prose and
generate phantom retrieval hits for every section title in the document.

The signal used here is structural rather than positional: a TOC is, by definition, a list
of the document's own headings. So a block whose text is largely a concatenation of strings
that appear as headings elsewhere IS a contents list, whatever it was labelled and wherever
it sits. That generalizes to back-indexes and per-part contents pages, which a "page 1-2"
rule would miss.
"""

from __future__ import annotations

import re
from dataclasses import dataclass

from substrate.models import Block, Kind

MIN_HEADING_HITS = 5      # fewer than this is a paragraph that happens to name sections
MIN_COVERAGE = 0.45       # fraction of the block's characters explained by heading names
MIN_CHARS = 200           # short blocks are never contents lists
CONTENTS_HEADING = re.compile(r"^\s*(table of )?contents\s*$", re.IGNORECASE)


@dataclass
class TocReport:
    blocks_marked: int = 0
    by_label: int = 0
    by_structure: int = 0
    coverage: list[float] = None

    def __post_init__(self):
        if self.coverage is None:
            self.coverage = []


def _heading_vocab(blocks: list[Block]) -> list[str]:
    seen: set[str] = set()
    out: list[str] = []
    for b in blocks:
        if b.kind is Kind.HEADING:
            t = b.text.strip()
            if len(t) >= 4 and t.casefold() not in seen:
                seen.add(t.casefold())
                out.append(t)
    return out


def _coverage(text: str, vocab: list[str]) -> tuple[int, float]:
    """How much of this block is accounted for by heading names?"""
    hay = text.casefold()
    hits = 0
    covered = 0
    for h in vocab:
        needle = h.casefold()
        if needle in hay:
            hits += 1
            covered += len(needle)
    return hits, (covered / max(len(text), 1))


MAX_TOC_PAGES = 12        # DDIA's contents runs pp11-17; beyond this we are lost, not reading
PROSE_CHARS = 150
_SENTENCE = re.compile(r"[.!?][\"')\]]?\s*$")


def _is_prose(b: Block) -> bool:
    """Real body text: long enough AND sentence-terminated. Contents entries are neither."""
    return len(b.text) >= PROSE_CHARS and bool(_SENTENCE.search(b.text.strip()))


# A back-of-book index is a dense run of "term, page[, page]" with no sentences. DDIA's
# leaked in as a 2,669-char prose block ("column families (Bigtable), 82, 140 ...") that
# no sentence splitter could break up, because it contains no sentences. It is also
# worthless to retrieve: the page numbers point into a book the reader does not have open.
_PAGE_REF = re.compile(r",\s*\d{1,4}(?:-\d{1,4})?\b")
_SENTENCE_ANY = re.compile(r"[.!?]\s+[A-Z]")
INDEX_REFS_MIN = 8
INDEX_REF_DENSITY = 1 / 90  # references per character


def _looks_like_index(b: Block) -> bool:
    text = b.text
    if len(text) < MIN_CHARS:
        return False
    refs = len(_PAGE_REF.findall(text))
    if refs < INDEX_REFS_MIN or refs / len(text) < INDEX_REF_DENSITY:
        return False
    # Real prose citing many page numbers still reads as sentences; an index never does.
    return len(_SENTENCE_ANY.findall(text)) <= 1


def mark(blocks: list[Block]) -> TocReport:
    """Reclassify contents-list blocks as INDEX so emission skips them.

    Two complementary rules, because a contents list arrives in two shapes:
      * ONE run-on block of concatenated section names (Go spec) -> structural coverage.
      * MANY short blocks, one per entry (also Go spec, after reflow) -> region tracking.
    The second is invisible to a length-gated structural test, which is why both exist.
    """
    rep = TocReport()
    vocab = _heading_vocab(blocks)

    in_region = False
    region_start_page: int | None = None

    for b in blocks:
        if b.kind is Kind.INDEX:  # docling's own DOCUMENT_INDEX label
            rep.by_label += 1
            rep.blocks_marked += 1
            continue

        if b.kind is Kind.HEADING:
            if CONTENTS_HEADING.match(b.text):
                in_region, region_start_page = True, b.page
            continue  # headings themselves are handled by the left-edge rule

        if in_region:
            # Leave the region on the first real paragraph, or if we have run too far.
            too_far = (
                region_start_page is not None
                and b.page is not None
                and b.page - region_start_page > MAX_TOC_PAGES
            )
            if _is_prose(b) or too_far:
                in_region = False
            elif b.kind in (Kind.TEXT, Kind.LIST_ITEM):
                b.kind = Kind.INDEX
                rep.by_structure += 1
                rep.blocks_marked += 1
                continue

        if b.kind not in (Kind.TEXT, Kind.LIST_ITEM) or len(b.text) < MIN_CHARS:
            continue

        if _looks_like_index(b):
            b.kind = Kind.INDEX
            rep.by_structure += 1
            rep.blocks_marked += 1
            continue

        hits, cov = _coverage(b.text, vocab)
        if hits >= MIN_HEADING_HITS and cov >= MIN_COVERAGE:
            b.kind = Kind.INDEX
            rep.by_structure += 1
            rep.blocks_marked += 1
            rep.coverage.append(round(cov, 3))

    return rep


def contents_pages(blocks: list[Block]) -> set[int]:
    """Pages carrying a 'Table of Contents' heading — used to steady the heading ladder."""
    return {
        b.page
        for b in blocks
        if b.kind is Kind.HEADING and b.page and CONTENTS_HEADING.match(b.text)
    }
