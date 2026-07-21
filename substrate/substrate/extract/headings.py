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

from collections import Counter, defaultdict
from dataclasses import dataclass, field

from substrate.extract.furniture import CAPTION
from substrate.models import Block, Kind

MAX_LEVEL = 6
CLUSTER_TOL = 0.6      # pt; glyph heights of one style vary slightly
RARE_STYLE_MAX = 1     # a height seen once is usually a stray, not a tier


@dataclass
class Ladder:
    tiers: list[float] = field(default_factory=list)   # descending height
    counts: dict[float, int] = field(default_factory=dict)
    demoted_captions: int = 0
    excluded_toc: int = 0

    def level_for(self, height: float | None) -> int:
        if height is None or not self.tiers:
            return MAX_LEVEL
        best = min(self.tiers, key=lambda t: abs(t - height))
        return min(self.tiers.index(best) + 1, MAX_LEVEL)


def _cluster(heights: list[float], tol: float = CLUSTER_TOL) -> list[float]:
    """Merge near-identical glyph heights into tiers, largest first."""
    tiers: list[float] = []
    for h in sorted(set(heights), reverse=True):
        if not tiers or abs(tiers[-1] - h) > tol:
            tiers.append(h)
    return tiers


def _dominant_left(blocks: list[Block]) -> float | None:
    lefts = [b.left for b in blocks if b.left is not None]
    return Counter(lefts).most_common(1)[0][0] if lefts else None


def build(blocks: list[Block], *, toc_pages: set[int] | None = None) -> Ladder:
    """Derive the height ladder from heading blocks, after removing contaminants."""
    headings = [b for b in blocks if b.kind is Kind.HEADING]
    body_left = _dominant_left(headings)

    usable: list[Block] = []
    ladder = Ladder()

    for b in headings:
        if CAPTION.match(b.text):
            ladder.demoted_captions += 1
            continue
        # A heading indented far from the dominant column is a TOC entry, not a heading.
        if body_left is not None and b.left is not None and abs(b.left - body_left) > 60:
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
    return ladder


def assign(blocks: list[Block], ladder: Ladder) -> dict:
    """Set `level` on heading blocks; demote contaminants to their true kind."""
    body_left = _dominant_left([b for b in blocks if b.kind is Kind.HEADING])
    stats = {"assigned": 0, "captions_demoted": 0, "toc_excluded": 0, "repaired": 0}
    prev = 0

    for b in blocks:
        if b.kind is not Kind.HEADING:
            continue

        if CAPTION.match(b.text):
            b.kind, b.level = Kind.CAPTION, None
            stats["captions_demoted"] += 1
            continue

        if body_left is not None and b.left is not None and abs(b.left - body_left) > 60:
            b.kind, b.level = Kind.INDEX, None
            stats["toc_excluded"] += 1
            continue

        lvl = ladder.level_for(b.height)
        # Monotonicity: a heading may not jump more than one level deeper than its
        # predecessor, or the path grows rungs that never existed (# -> ### becomes # -> ##).
        if prev and lvl > prev + 1:
            lvl = prev + 1
            stats["repaired"] += 1
        b.level = lvl
        prev = lvl
        stats["assigned"] += 1

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
