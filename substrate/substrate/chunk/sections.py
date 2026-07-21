"""Section grouping and atomic units.

Chunking happens over the emitted MARKDOWN, never the PDF, and never across a section
boundary — a passage that spans two sections has a path that is true for neither half.

An "atomic unit" is a run of blocks that must not be split under any circumstance:
a fenced code listing, a table, and — critically — a caption bound to the thing it
captions. DDIA's captions carry the meaning ("Example 3-4. A subset of the data in
Figure 3-6, represented as a Cypher query"); a code listing separated from its caption is
retrievable only by someone who already knows what it is.
"""

from __future__ import annotations

from dataclasses import dataclass, field

from substrate.models import Block, Kind

BINDS_TO_CAPTION = (Kind.CODE, Kind.TABLE, Kind.FIGURE)


@dataclass
class Unit:
    """One or more blocks that must travel together."""

    blocks: list[Block] = field(default_factory=list)
    atomic: bool = False

    @property
    def text(self) -> str:
        return "\n\n".join(b.text for b in self.blocks if b.text)

    @property
    def n_chars(self) -> int:
        return len(self.text)

    @property
    def char_start(self) -> int:
        return min((b.char_start for b in self.blocks if b.char_start >= 0), default=-1)

    @property
    def char_end(self) -> int:
        return max((b.char_end for b in self.blocks if b.char_end >= 0), default=-1)

    @property
    def pages(self) -> tuple[int | None, int | None]:
        ps = [b.page for b in self.blocks if b.page is not None]
        return (min(ps), max(ps)) if ps else (None, None)

    @property
    def ids(self) -> list[str]:
        return [b.id for b in self.blocks]


@dataclass
class Section:
    """A leaf section: one heading path plus the content directly under it."""

    path: list[str]
    level: int
    units: list[Unit] = field(default_factory=list)
    heading_block: Block | None = None

    @property
    def n_chars(self) -> int:
        return sum(u.n_chars for u in self.units) + 2 * max(len(self.units) - 1, 0)

    @property
    def chapter(self) -> str:
        return self.path[0] if self.path else ""


def _renderable(blocks: list[Block]) -> list[Block]:
    return [
        b
        for b in blocks
        if b.kind is not Kind.INDEX and not b.dropped and b.text.strip() and b.char_start >= 0
    ]


def build_units(blocks: list[Block]) -> list[Unit]:
    """Group blocks into units, binding captions to the figure/table/code they describe."""
    units: list[Unit] = []
    i = 0
    while i < len(blocks):
        b = blocks[i]

        if b.kind is Kind.CAPTION and i + 1 < len(blocks) and blocks[i + 1].kind in BINDS_TO_CAPTION:
            units.append(Unit([b, blocks[i + 1]], atomic=True))
            i += 2
            continue

        if b.kind in BINDS_TO_CAPTION:
            # Caption may trail instead of lead.
            if i + 1 < len(blocks) and blocks[i + 1].kind is Kind.CAPTION:
                units.append(Unit([b, blocks[i + 1]], atomic=True))
                i += 2
                continue
            units.append(Unit([b], atomic=True))
            i += 1
            continue

        units.append(Unit([b], atomic=False))
        i += 1
    return units


def leaf_sections(blocks: list[Block]) -> list[Section]:
    """Split the document into leaf sections carrying their full heading path."""
    usable = _renderable(blocks)
    sections: list[Section] = []
    stack: dict[int, str] = {}
    current: Section | None = None
    pending: list[Block] = []

    def flush() -> None:
        nonlocal pending, current
        if current is not None:
            current.units = build_units(pending)
            if current.units or current.heading_block is not None:
                sections.append(current)
        pending = []

    for b in usable:
        if b.kind is Kind.HEADING and b.level:
            flush()
            stack = {k: v for k, v in stack.items() if k < b.level}
            stack[b.level] = b.text
            current = Section(
                path=[stack[k] for k in sorted(stack)], level=b.level, heading_block=b
            )
        else:
            if current is None:
                current = Section(path=[], level=0)
            pending.append(b)

    flush()
    return [s for s in sections if s.units]
