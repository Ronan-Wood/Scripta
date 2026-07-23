"""Packing units into retrievable chunks, plus section-level outline records.

Sizes: TARGET 1400 chars, MAX 2600, overlap 0.

Overlap is deliberately zero. Disjoint chunks make the markdown exactly reconstructible
(assertion A14: the chunk lengths must sum to the body), which is the property that lets us
prove nothing was lost. Overlap is a RETRIEVAL knob and belongs in Phase 3 as neighbour
expansion — `prev_id`/`next_id` are set here so that costs one hop, not a re-index.

Two levels are emitted:
  passage — leaf text, what a specific question retrieves.
  outline — one per heading at level <= 3: path, lede, child headings, and any verbatim
            Summary subsection. This answers "what is chapter 3 about?" EXTRACTIVELY, with
            no model in the ingestion path. If these read as useless, the fix is a separate
            offline cached summarization stage, not an LLM call in here.
"""

from __future__ import annotations

import re

from substrate.chunk.sections import Section, Unit, leaf_sections
from substrate.models import Block, Chunk, Document

TARGET = 1400
MAX = 2600
MIN = 400
# Validated against three real orientation queries on DDIA (2026-07-21). At 3 the layer is
# chapter-grain only (21 records, 1.3/chapter) and answers "which chapter covers this". At 5
# it reaches NAMED SUBSECTIONS — "Serializability > Serializable Snapshot Isolation" rather
# than just "Serializability" — with materially better BM25 separation, while staying 4.5:1
# against passages and structurally distinct from them (path + lede + children + summary).
OUTLINE_MAX_LEVEL = 5
LEDE_CHARS = 420

_SENTENCE_END = re.compile(r"(?<=[.!?])\s+(?=[A-Z(\"'])")


def _split_prose(text: str, limit: int) -> list[tuple[int, int]]:
    """Split oversized prose on sentence boundaries into contiguous (start, end) spans.

    Spans, not strings: each piece is a byte-exact slice `text[start:end]`, so the pieces tile
    the unit's offset range DISJOINTLY and map back to the emitted body — which is what keeps
    char_start/char_end load-bearing. (Handing every piece the whole unit's offsets made them
    all claim the entire paragraph.) A single sentence longer than `limit` is emitted whole
    rather than shredded.
    """
    # Sentence starts: 0, plus the char after each inter-sentence whitespace run. Each sentence
    # then spans [starts[i], ends[i]) and the sentences tile `text` with no gaps or overlap.
    starts = [0] + [m.end() for m in _SENTENCE_END.finditer(text)]
    ends = starts[1:] + [len(text)]

    spans: list[tuple[int, int]] = []
    p_start = 0
    for s, e in zip(starts, ends):
        # Close the current piece before the sentence that would push it over the limit; a piece
        # already holding one over-limit sentence is emitted whole (we never split within one).
        if s > p_start and (e - p_start) > limit:
            spans.append((p_start, s))
            p_start = s
    spans.append((p_start, len(text)))
    return spans


def _mk(
    doc: Document, section: Section, units: list[Unit], text: str, seq: int, oversize: bool,
    *, char_start: int | None = None, char_end: int | None = None,
) -> Chunk:
    pages = [u.pages for u in units]
    starts = [p[0] for p in pages if p[0] is not None]
    ends = [p[1] for p in pages if p[1] is not None]
    return Chunk(
        chunk_id=f"{doc.doc_id}#c{seq:05d}",
        doc_id=doc.doc_id,
        kind="passage",
        text=text,
        path=list(section.path),
        level=section.level,
        block_ids=[i for u in units for i in u.ids],
        # Explicit overrides let a split-prose piece carry its OWN slice; otherwise the chunk
        # spans all its units.
        char_start=char_start if char_start is not None
        else min((u.char_start for u in units if u.char_start >= 0), default=-1),
        char_end=char_end if char_end is not None
        else max((u.char_end for u in units if u.char_end >= 0), default=-1),
        page_start=min(starts) if starts else None,
        page_end=max(ends) if ends else None,
        n_chars=len(text),
        oversize=oversize,
        document_class=doc.document_class,
        version=doc.version,
        source_sha256=doc.source_sha256,
        page_label_offset=doc.page_label_offset,
    )


def _pack_section(doc: Document, section: Section, seq: int) -> tuple[list[Chunk], int]:
    """Greedily pack a section's units, never crossing the section boundary."""
    chunks: list[Chunk] = []
    buf: list[Unit] = []
    size = 0

    def flush(oversize: bool = False) -> None:
        nonlocal buf, size, seq
        if not buf:
            return
        text = "\n\n".join(u.text for u in buf if u.text).strip()
        if text:
            chunks.append(_mk(doc, section, buf, text, seq, oversize))
            seq += 1
        buf, size = [], 0

    for unit in section.units:
        # An atomic unit larger than MAX is emitted WHOLE. A shredded code listing or table
        # is worse than a large chunk: neither half is executable or readable.
        if unit.atomic and unit.n_chars > MAX:
            flush()
            buf = [unit]
            flush(oversize=True)
            continue

        # Oversized prose splits on sentence boundaries into CONTIGUOUS slices, each piece with
        # its OWN offsets, so the pieces tile the unit's span DISJOINTLY instead of every one
        # claiming the whole paragraph. The slice keeps its inter-sentence whitespace (it is NOT
        # stripped) so a piece equals `body[char_start:char_end]` byte-for-byte and the pieces sum
        # to the unit's length — coverage stays exact. (A LIST_ITEM/CAPTION unit's offsets already
        # include its "- " / "*...*" markup; that pre-existing shift is orthogonal and unchanged
        # here, but the pieces are still disjoint.)
        if not unit.atomic and unit.n_chars > MAX:
            flush()
            base = unit.char_start
            for p_start, p_end in _split_prose(unit.text, TARGET):
                piece = unit.text[p_start:p_end]
                if not piece.strip():
                    continue
                chunks.append(
                    _mk(doc, section, [unit], piece, seq, len(piece) > MAX,
                        char_start=base + p_start, char_end=base + p_end)
                )
                seq += 1
            continue

        if buf and size + unit.n_chars + 2 > MAX:
            flush()
        buf.append(unit)
        size += unit.n_chars + 2
        if size >= TARGET:
            flush()

    flush()
    chunks = _absorb_runts(chunks)

    if len(chunks) > 1:
        for i, c in enumerate(chunks):
            c.part_index, c.part_count = i + 1, len(chunks)
    else:
        for c in chunks:
            c.part_index = c.part_count = None
    return chunks, seq


def _absorb_runts(chunks: list[Chunk]) -> list[Chunk]:
    """Fold an undersized tail back into its predecessor.

    Packing to TARGET can leave a runt: a 1,500-char section becomes 1,400 + 100, and that
    100-char tail is a fragment with no standalone meaning. Merging is safe here and ONLY
    here because both pieces come from the SAME section, so the merged chunk's path is
    unchanged. (Merging across sections would hand text a path that is not its own.)
    """
    if len(chunks) < 2:
        return chunks

    out = [chunks[0]]
    for c in chunks[1:]:
        prev = out[-1]
        if c.n_chars < MIN and prev.n_chars + c.n_chars + 2 <= MAX and not (prev.oversize or c.oversize):
            # Split-prose siblings of ONE paragraph share block_ids and are char-contiguous —
            # their separating whitespace is already the trailing edge of prev — so they
            # concatenate with NO separator and the merged text still equals its char span
            # exactly. Genuinely separate units keep the "\n\n" the emitted body has between them.
            sep = "" if set(prev.block_ids) & set(c.block_ids) else "\n\n"
            prev.text = f"{prev.text}{sep}{c.text}"
            prev.n_chars = len(prev.text)
            prev.block_ids = list(dict.fromkeys(prev.block_ids + c.block_ids))
            prev.char_end = max(prev.char_end, c.char_end)
            if c.page_end is not None:
                prev.page_end = max(prev.page_end or c.page_end, c.page_end)
        else:
            out.append(c)
    return out


def _outline_records(doc: Document, sections: list[Section], seq: int) -> tuple[list[Chunk], int]:
    """One orientation record per heading at level <= OUTLINE_MAX_LEVEL."""
    out: list[Chunk] = []
    for i, section in enumerate(sections):
        if not section.path or section.level > OUTLINE_MAX_LEVEL:
            continue

        lede = ""
        for u in section.units:
            if not u.atomic and u.text:
                lede = u.text[:LEDE_CHARS]
                break

        children = [
            s.path[-1]
            for s in sections[i + 1 :]
            if len(s.path) == len(section.path) + 1
            and s.path[: len(section.path)] == section.path
        ]
        # Stop at the next sibling: everything after belongs to a different branch.
        summary = ""
        for s in sections[i + 1 :]:
            if len(s.path) <= len(section.path):
                break
            if s.path[-1].strip().lower() == "summary":
                summary = "\n\n".join(u.text for u in s.units)[:1200]
                break

        parts = [" > ".join(section.path)]
        if lede:
            parts.append(lede)
        if children:
            parts.append("Contains: " + "; ".join(dict.fromkeys(children)))
        if summary:
            parts.append("Summary:\n" + summary)

        hb: Block | None = section.heading_block
        out.append(
            Chunk(
                chunk_id=f"{doc.doc_id}#o{seq:05d}",
                doc_id=doc.doc_id,
                kind="outline",
                text="\n\n".join(parts),
                path=list(section.path),
                level=section.level,
                block_ids=[hb.id] if hb else [],
                char_start=hb.char_start if hb else -1,
                char_end=hb.char_end if hb else -1,
                page_start=hb.page if hb else None,
                page_end=hb.page if hb else None,
                n_chars=sum(len(p) for p in parts),
                document_class=doc.document_class,
                version=doc.version,
                source_sha256=doc.source_sha256,
                page_label_offset=doc.page_label_offset,
            )
        )
        seq += 1
    return out, seq


def chunk(doc: Document, override: tuple[int, int, int] | None = None) -> tuple[list[Chunk], dict]:
    # Geometry is class-driven. Module-level TARGET/MAX/MIN remain the defaults for any
    # class that does not override them.
    global TARGET, MAX, MIN
    from substrate.classes import POLICIES

    pol = POLICIES.get(doc.document_class)
    saved = (TARGET, MAX, MIN)
    if override is not None:
        TARGET, MAX, MIN = override
    elif pol is not None:
        TARGET, MAX, MIN = pol.chunk.target, pol.chunk.max_chars, pol.chunk.min_chars
    try:
        return _chunk(doc)
    finally:
        TARGET, MAX, MIN = saved


def _chunk(doc: Document) -> tuple[list[Chunk], dict]:
    sections = leaf_sections(doc.blocks)

    passages: list[Chunk] = []
    seq = 0
    for section in sections:
        made, seq = _pack_section(doc, section, seq)
        passages.extend(made)

    # Neighbour links are within the document, in reading order.
    for i, c in enumerate(passages):
        c.prev_id = passages[i - 1].chunk_id if i else None
        c.next_id = passages[i + 1].chunk_id if i + 1 < len(passages) else None

    outlines, _ = _outline_records(doc, sections, 0)

    sizes = sorted(c.n_chars for c in passages) or [0]

    def pct(p: float) -> int:
        return sizes[min(int(len(sizes) * p), len(sizes) - 1)]

    in_band = sum(1 for n in sizes if MIN <= n <= MAX)
    deep = sum(1 for c in passages if len(c.path) >= 2)

    # A short chunk is only a defect if it is a FRAGMENT. A section that is genuinely 192
    # chars long ("Semicolons" in the Go spec) should produce a 192-char chunk carrying its
    # true path — padding it by merging a neighbour in would give that text a path that is
    # not its own, which is the failure structural chunking exists to prevent.
    short = [c for c in passages if c.n_chars < MIN]
    short_complete = [c for c in short if c.part_count is None]
    fragments = [c for c in short if c.part_count is not None]

    stats = {
        "sections": len(sections),
        "passages": len(passages),
        "outlines": len(outlines),
        "chars_p5": pct(0.05),
        "chars_p50": pct(0.50),
        "chars_p95": pct(0.95),
        "in_band_pct": round(100 * in_band / max(len(sizes), 1), 1),
        "short_complete": len(short_complete),
        "short_fragments": len(fragments),
        "well_formed_pct": round(
            100 * (len(passages) - len(fragments)) / max(len(passages), 1), 1
        ),
        "path_depth_ge2_pct": round(100 * deep / max(len(passages), 1), 1),
        "max_path_depth": max((len(c.path) for c in passages), default=0),
        "oversize": sum(1 for c in passages if c.oversize),
        "sum_chunk_chars": sum(c.n_chars for c in passages),
    }
    return passages + outlines, stats
