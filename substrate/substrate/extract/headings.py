"""Heading-level inference — the hierarchy Docling does not provide.

Measured 2026-07-21: Docling detects headings well (66 in the Go spec, which has no embedded
outline at all) but reports EVERY one as `level=1` with `parent='#/body'`. The document tree
is flat. Since every chunk must carry a chapter -> section -> subsection path, the level has
to be inferred, and glyph height from `prov.bbox` is the signal that survives.

Measured ladders:
    Go spec  19.3pt x1 (title) | 12.0 x10 (sections) | 9.7 x39 (subsections)
    DDIA     49.7pt x1 (chapter) | 20.1 x5 | 16.8 x8 | 12.3 x6

Two contaminants ride along and are removed here, not downstream:
  * TOC entries — separable by left edge (Go spec: 177 vs body 44).
  * Captions labelled as headings ("Example 3-2. ..." at 12.7pt in DDIA).
"""

from __future__ import annotations

from collections import Counter
from dataclasses import dataclass, field

from substrate.extract.furniture import CAPTION
from substrate.models import Block, Kind

MAX_LEVEL = 6
# RELATIVE, not absolute: 0.6pt is 5% of a 12pt subsection but 1% of a 50pt chapter title,
# so a fixed tolerance under-merges small styles and over-merges large ones. Measured on
# DDIA, an absolute 0.6pt left 12.1/12.3/12.7pt as separate tiers — one visual style spread
# across three rungs.
CLUSTER_REL_TOL = 0.04
RARE_STYLE_MAX = 1     # a height seen once is usually a stray, not a tier


@dataclass
class Ladder:
    tiers: list[float] = field(default_factory=list)   # descending height
    counts: dict[float, int] = field(default_factory=dict)
    demoted_captions: int = 0
    excluded_toc: int = 0
    dominant_height: float = 0.0   # height of the most populous tier = ordinary body heading

    def raw_tier(self, height: float | None) -> int:
        """Index of the nearest tier — before compression onto consecutive levels."""
        if height is None or not self.tiers:
            return len(self.tiers)
        best = min(self.tiers, key=lambda t: abs(t - height))
        return self.tiers.index(best)

    def level_for(self, height: float | None) -> int:
        return min(self.raw_tier(height) + 1, MAX_LEVEL)


def _cluster(heights: list[float], rel_tol: float = CLUSTER_REL_TOL) -> list[float]:
    """Merge near-identical glyph heights into tiers, largest first."""
    tiers: list[float] = []
    for h in sorted(set(heights), reverse=True):
        if not tiers or (tiers[-1] - h) > rel_tol * tiers[-1]:
            tiers.append(h)
    return tiers


def _dominant_left(blocks: list[Block]) -> float | None:
    lefts = [b.left for b in blocks if b.left is not None]
    return Counter(lefts).most_common(1)[0][0] if lefts else None


# A heading off the body column is only a contents entry if it is ALSO small.
#
# This guard exists because its absence was catastrophic and silent. DDIA sets chapter
# titles decoratively on the opening page, with left edges scattered from 105 to 357, so a
# pure left-edge rule deleted 11 of 14 chapter titles as "TOC". Every machine gate stayed
# green — coverage, depth, zero fragments — while the chapter element of the path was wrong
# for most of the book: page 328 (Transactions) was labelled "CHAPTER 2 Defining
# Nonfunctional Requirements". Only a real retrieval query exposed it.
#
# The discriminator: contents entries are the SMALLEST text in a narrow column; chapter
# titles are the LARGEST glyphs in the document.
OFF_COLUMN_PT = 60
SMALL_FACTOR = 1.25


def _off_column(b: Block, body_left: float | None, dominant_height: float) -> bool:
    if body_left is None or b.left is None:
        return False
    if abs(b.left - body_left) <= OFF_COLUMN_PT:
        return False
    if b.height is None or not dominant_height:
        return True
    return b.height <= dominant_height * SMALL_FACTOR


RECLAIM_FACTOR = 1.5
RECLAIM_MAX_CHARS = 120


def reclaim_titles(blocks: list[Block]) -> int:
    """Promote large-glyph INDEX blocks back to headings.

    Docling labels DDIA's chapter-opening pages `DOCUMENT_INDEX`, so 11 of 14 chapter
    titles arrived as Kind.INDEX and were dropped before any heading logic ran. The chapter
    element of every path was then stale for hundreds of pages — page 328 (Transactions)
    carried "CHAPTER 2 Defining Nonfunctional Requirements" — with all machine gates green.

    This is the furniture lesson generalized: a label is a claim to verify, not an
    instruction. A real contents list or back index is DENSE SMALL text; a chapter title is
    among the largest glyphs in the document and occupies one short line.
    """
    heights = Counter(
        b.height for b in blocks if b.kind is Kind.HEADING and b.height is not None
    )
    if not heights:
        return 0
    dominant = heights.most_common(1)[0][0]

    reclaimed = 0
    for b in blocks:
        if b.kind is not Kind.INDEX or b.height is None:
            continue
        if b.height >= dominant * RECLAIM_FACTOR and len(b.text) <= RECLAIM_MAX_CHARS:
            b.kind = Kind.HEADING
            reclaimed += 1
    return reclaimed


def build(blocks: list[Block], *, toc_pages: set[int] | None = None) -> Ladder:
    """Derive the height ladder from heading blocks, after removing contaminants."""
    headings = [b for b in blocks if b.kind is Kind.HEADING]
    body_left = _dominant_left(headings)

    usable: list[Block] = []
    ladder = Ladder()
    # Provisional: the most common heading height, used to tell "small, off-column" (a
    # contents entry) from "large, off-column" (a decoratively placed chapter title).
    _c = Counter(b.height for b in headings if b.height is not None)
    dominant = _c.most_common(1)[0][0] if _c else 0.0

    for b in headings:
        if CAPTION.match(b.text):
            ladder.demoted_captions += 1
            continue
        # A heading indented far from the dominant column MAY be a TOC entry — but only if
        # it is also small. See _off_column().
        if _off_column(b, body_left, dominant):
            ladder.excluded_toc += 1
            continue
        if toc_pages and b.page in toc_pages:
            ladder.excluded_toc += 1
            continue
        usable.append(b)

    counts = Counter(b.height for b in usable if b.height is not None)
    # Drop singleton heights UNLESS they are the largest (a lone chapter title is real).
    heights = [h for h, n in counts.items() if n > RARE_STYLE_MAX]
    if counts and (not heights or max(counts) not in heights):
        heights.append(max(counts))

    ladder.tiers = _cluster(heights)
    ladder.counts = {h: counts[h] for h in ladder.tiers}
    if counts:
        ladder.dominant_height = counts.most_common(1)[0][0]
    return ladder


def assign(blocks: list[Block], ladder: Ladder) -> dict:
    """Set `level` on heading blocks; demote contaminants to their true kind.

    Level is a pure function of STYLE. An earlier version applied a sequence-dependent
    monotonicity repair (a heading may not jump more than one level below its predecessor),
    which split a single 12.3pt style across L5 and L6 on DDIA — 70 headings against 167 —
    purely on what happened to precede them. `From data warehouse to data lake` and
    `Beyond the data lake` are siblings in the book and landed on different rungs.

    Instead: rank the tiers that are actually USED and map them onto consecutive levels. One
    visual style always yields one level, and unused rungs never inflate depth.
    """
    body_left = _dominant_left([b for b in blocks if b.kind is Kind.HEADING])
    dominant = ladder.dominant_height
    stats = {"assigned": 0, "captions_demoted": 0, "toc_excluded": 0, "tiers_used": 0}

    # Pass 1 — filter contaminants and record each survivor's raw tier.
    survivors: list[tuple[Block, int]] = []
    for b in blocks:
        if b.kind is not Kind.HEADING:
            continue

        if CAPTION.match(b.text):
            b.kind, b.level = Kind.CAPTION, None
            stats["captions_demoted"] += 1
            continue

        if _off_column(b, body_left, dominant):
            b.kind, b.level = Kind.INDEX, None
            stats["toc_excluded"] += 1
            continue

        survivors.append((b, ladder.raw_tier(b.height)))

    # Pass 2 — compress used tiers onto consecutive levels.
    used = sorted({t for _, t in survivors})
    rank = {t: min(i + 1, MAX_LEVEL) for i, t in enumerate(used)}
    for b, tier in survivors:
        b.level = rank[tier]
        stats["assigned"] += 1

    stats["tiers_used"] = len(used)
    return stats


def path_for(blocks: list[Block], index: int) -> list[str]:
    """Structural path (chapter -> section -> subsection) for the block at `index`."""
    stack: dict[int, str] = {}
    for b in blocks[: index + 1]:
        if b.kind is Kind.HEADING and b.level:
            stack = {k: v for k, v in stack.items() if k < b.level}
            stack[b.level] = b.text
    return [stack[k] for k in sorted(stack)]


def outline_levels(pdf_path: str) -> dict[str, int]:
    """Authoritative levels from the PDF's embedded outline, when it has one.

    DDIA ships ~304 real entries; the Go spec ships none. Used to corroborate the ladder,
    never alone — a Quartz re-save can shift destinations.
    """
    try:
        import pypdfium2 as pdfium
    except ImportError:
        return {}
    out: dict[str, int] = {}
    try:
        with pdfium.PdfDocument(pdf_path) as doc:
            for item in doc.get_toc():
                title = (item.title or "").strip()
                if title:
                    out.setdefault(title.casefold(), item.level + 1)
    except Exception:
        return {}
    return out
