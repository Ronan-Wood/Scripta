"""Markdown → canonical Document. The vault-ingestion arm.

The PDF path recovers structure from glyph geometry; markdown HANDS us the structure, so this
reader honours it directly — ``#`` levels, ``` fences, ``-`` lists, ``|`` tables — and never
re-runs detection. It produces the same Document/Block shape DoclingExtractor produces, so
emit(), chunk(), the store and retrieval all run UNCHANGED: the reader's only job is
markdown-text → list[Block]; the existing emitter fills char offsets and renders the body.

Stdlib only; no Docling, no torch. That is the point — a project vault must ingest on a fresh
download with nothing installed.

Supported markdown subset (the vault format + the engine's own emitted markdown): ATX headings
(``#``…``######`` with optional space-preceded closing hashes), fenced code (``` / ~~~, with an
info-string language), ``-``/``*``/``+`` and ordered list items (one block each), GitHub pipe
tables, paragraphs, and ``<!-- page:N -->`` anchors. NOT structurally recognised (they degrade to
paragraphs/flat items, content preserved but hierarchy lost): setext headings, 4-space indented
code, borderless tables, nested lists, wrapped list-item continuations. The engine's emit avoids
all of those, so round-trip is unaffected; hand-authored notes using them still ingest without
content loss (A18), they just lose the extra structure.

The one non-obvious guard is A18 (`content_coverage` + `uncovered_content_blocks`). Re-emit
coverage (chunk chars / body chars, A14) CANNOT see a stage that silently drops a source line:
the dropped text never enters the body either, so numerator and denominator shrink together and
coverage stays ~1.0. So A18 measures against the SOURCE file instead. Two complementary checks:
the aggregate token ratio catches large/systematic loss; the per-block survival check catches a
single dropped content block at ANY doc size (a small categorical drop a large doc's ratio would
hide). Heading/path STRUCTURE integrity is A17's job, not A18's.
"""

from __future__ import annotations

import hashlib
import re
from collections import Counter
from pathlib import Path

from substrate.extract.base import doc_id_for  # stdlib-only; no Docling/torch pulled in
from substrate.models import Block, Document, Kind

_FRONTMATTER = re.compile(r"\A---\n(.*?)\n---\n?", re.DOTALL)
_PAGE = re.compile(r"^<!--\s*page:(\d+)\s*-->\s*$")
_PAGE_ANCHOR = re.compile(r"<!--\s*page:\d+\s*-->")  # linear; strips anchors for coverage
# Loose ATX match — closing-hash trimming is done in Python (a regex that trims it backtracks
# super-quadratically on a line ending in a long whitespace run: a crafted heading hangs ingest).
_HEADING = re.compile(r"^(#{1,6})\s+(.*)$")
# Fence-language excludes control bytes so a crafted info-string can't land a C0 byte in
# document.md / blocks.jsonl (emit renders lang verbatim; the normalize invariant strips C0).
_FENCE = re.compile(r"^([`~]{3,})\s*([^\s`~\x00-\x1f\x7f]*)")
_LIST = re.compile(r"^\s{0,3}(?:[-*+]|\d+[.)])\s+\S")
_LIST_MARKER = re.compile(r"^\s{0,3}(?:[-*+]|\d+[.)])\s+")
_TABLE = re.compile(r"^\s{0,3}\|.*\|\s*$")
# Content-tokens: Unicode word runs (letters in ANY script, and multi-digit numbers), length ≥ 2,
# underscore excluded. Letters keep a dropped CJK / Cyrillic / accented paragraph visible; digits
# keep a dropped numeric table / list ("| 12 | 34 |", "- 42") visible — a letters-only class was
# blind to both. Single characters are dropped, so a bare list-marker digit (1.–9.) is not a
# phantom token; page-anchor numbers are stripped before tokenising.
_TOKEN = re.compile(r"[^\W_]{2,}", re.UNICODE)
_INT = re.compile(r"-?[0-9]+")

_I64 = 2**63 - 1
_MAX_MD_BYTES = 64 * 1024 * 1024  # refuse a pathological file rather than OOM
_DOC_ID = re.compile(r"[a-z0-9][a-z0-9._-]{0,63}")  # accepted frontmatter doc_id shape
_SHA256 = re.compile(r"[0-9a-f]{64}")               # accepted frontmatter source_sha256 shape


def _bounded_int(v: str, lo: int, hi: int) -> int | None:
    """ASCII-only, range-checked int, else None. `str.isdigit()` is NOT a sound int() guard: it
    is True for superscripts (int() then raises) and for a 40-digit bignum (int() succeeds, then
    OverflowError at SQLite-insert time aborts the whole reconcile). Both refuse cleanly here."""
    v = v.strip()
    if not _INT.fullmatch(v):
        return None
    n = int(v)
    return n if lo <= n <= hi else None


def _parse_frontmatter(text: str) -> tuple[dict[str, str], str]:
    """Split leading YAML frontmatter (the emit() format) from the body. Round-tripping the
    engine's own markdown recovers the ORIGINAL doc_id/sha/version, so re-ingesting it keeps
    the same chunk_ids and reconcile sees the same document rather than a new one.

    A leading ``---`` is only frontmatter if EVERY non-blank line in the block is ``key: value``
    shaped. Otherwise it is an ordinary thematic break (a note opening with a divider), and
    treating it as frontmatter would silently swallow the prose between the two rules — a
    dropped-content bug the A18 check, which runs on the post-frontmatter body, could not see.
    """
    m = _FRONTMATTER.match(text)
    if not m:
        return {}, text
    fields: dict[str, str] = {}
    for line in m.group(1).splitlines():
        if not line.strip():
            continue
        if ":" not in line:
            return {}, text  # a prose line → this is a thematic break, not frontmatter
        k, _, v = line.partition(":")
        v = v.strip()
        if len(v) >= 2 and v[0] == v[-1] == '"':
            v = v[1:-1]
        fields[k.strip()] = v
    return fields, text[m.end():]


def _is_close_fence(line: str, ch: str, n: int) -> bool:
    """A closing fence is a line of ONLY the same fence char (≥ opening length), nothing else —
    NOT any line that merely starts with it. `startswith` closed on an inner ```python and split
    a code block that contained a nested fenced example."""
    s = line.strip()
    return len(s) >= n and set(s) == {ch}


def _blocks(md: str) -> list[Block]:
    """Parse markdown into blocks by its explicit syntax. Every non-blank source line routes
    into exactly one block — paragraphs are the catch-all, so nothing falls through silently
    (A18 proves it)."""
    blocks: list[Block] = []
    n = 0
    page: int | None = None
    para: list[str] = []
    table: list[str] = []
    lines = md.splitlines()

    def bid() -> str:
        nonlocal n
        n += 1
        return f"b{n:06d}"

    def flush_para() -> None:
        nonlocal para
        if para:
            blocks.append(Block(id=bid(), kind=Kind.TEXT, text=" ".join(para).strip(), page=page))
            para = []

    def flush_table() -> None:
        nonlocal table
        if table:
            blocks.append(Block(id=bid(), kind=Kind.TABLE, text="\n".join(table), page=page))
            table = []

    i = 0
    while i < len(lines):
        line = lines[i]

        pm = _PAGE.match(line)
        if pm:
            flush_para(); flush_table()
            # Range-check like every other numeric field: an unbounded int() here would let a
            # crafted <!-- page:99…9 --> set source_pages (= max anchors) to a bignum that
            # OverflowErrors at SQLite-insert time. A malformed anchor is ignored (page unchanged);
            # the line is still consumed (it is a comment, never content).
            p = _bounded_int(pm.group(1), 1, _I64)
            if p is not None:
                page = p
            i += 1
            continue

        fm = _FENCE.match(line)
        if fm:
            flush_para(); flush_table()
            fence, lang = fm.group(1), (fm.group(2) or None)
            body: list[str] = []
            i += 1
            while i < len(lines) and not _is_close_fence(lines[i], fence[0], len(fence)):
                body.append(lines[i])
                i += 1
            i += 1  # consume the closing fence (or run off the end on an unterminated block)
            blocks.append(Block(id=bid(), kind=Kind.CODE, text="\n".join(body), page=page, lang=lang))
            continue

        hm = _HEADING.match(line)
        if hm:
            flush_para(); flush_table()
            blocks.append(Block(id=bid(), kind=Kind.HEADING, text=_atx_text(hm.group(2)),
                                page=page, level=len(hm.group(1))))
            i += 1
            continue

        if _TABLE.match(line):
            flush_para()
            table.append(line.strip())
            i += 1
            continue
        flush_table()

        if not line.strip():
            flush_para()
            i += 1
            continue

        if _LIST.match(line):
            flush_para()
            blocks.append(Block(id=bid(), kind=Kind.LIST_ITEM,
                                text=_LIST_MARKER.sub("", line).strip(), page=page))
            i += 1
            continue

        para.append(line.strip())
        i += 1

    flush_para(); flush_table()
    return blocks


def _atx_text(text: str) -> str:
    """Heading text with an ATX closing-hash run removed — but only when preceded by whitespace,
    per CommonMark, so a ``## C#`` / ``## F#`` heading keeps its trailing ``#``."""
    text = text.rstrip()
    if text.endswith("#"):
        stripped = text.rstrip("#")
        if not stripped or stripped[-1].isspace():
            text = stripped.rstrip()
    return text


def content_coverage(body_md: str, captured: list[str]) -> tuple[float, list[str]]:
    """Fraction of the SOURCE's word-tokens that survive into `captured`.

    Against the source file, not the re-emitted body — a stage that dropped a line loses its
    tokens HERE even though re-emit coverage (A14) would stay ~1.0 (the drop shrinks numerator
    and denominator together). Multiset diff, so a dropped paragraph is caught even when its
    words recur elsewhere: the recurrence keeps them present but the COUNT falls short.

    `captured` is every text that should hold the source's content — the caller passes chunk
    `text_with_path`, each fence-language, and heading block texts (see cmd_ingest_md). Page
    anchors are stripped (a linear, bounded strip — never an unterminated-comment scan).
    """
    src = Counter(_TOKEN.findall(_PAGE_ANCHOR.sub("", body_md)))
    got: Counter[str] = Counter()
    for t in captured:
        got.update(_TOKEN.findall(t))
    missing = src - got
    total = sum(src.values())
    cov = 1.0 - sum(missing.values()) / max(total, 1)
    return round(cov, 4), [t for t, _ in missing.most_common(8)]


def uncovered_content_blocks(
    blocks: list[Block], captured: list[str], min_survival: float = 0.5
) -> list[str]:
    """Per-block backstop the aggregate ratio misses: a single dropped content block (paragraph,
    list item, code, table) is flagged at ANY doc size, where a large doc's global ratio would
    hide a small categorical drop. Returns the ids of blocks that mostly vanished.

    HEADING blocks are excluded — a heading with content survives as a path, an empty-section
    heading is intentionally dropped by the chunker, and heading STRUCTURE is A17's job. INDEX
    blocks are excluded (never chunked). Presence-based (not multiset): a block flagged only if
    it has a token found NOWHERE in the output. The residual blind spot — dropping a block whose
    every token verbatim recurs elsewhere — is not a content loss (that text stays retrievable
    via the surviving copy), so presence is the right test, not a weaker one.
    """
    cap: Counter[str] = Counter()
    for t in captured:
        cap.update(_TOKEN.findall(t))
    bad: list[str] = []
    for b in blocks:
        if b.kind in (Kind.HEADING, Kind.INDEX):
            continue
        toks = _TOKEN.findall(b.text)
        if not toks:
            continue
        survived = sum(1 for t in toks if cap[t] > 0)
        if survived < len(toks) * min_survival:
            bad.append(b.id)
    return bad


def read_markdown(path: Path, doc_class: str | None = None) -> tuple[Document, str, dict]:
    """Read a markdown file into a canonical Document. Returns (doc, body_md, reader_stats).

    body_md (source minus frontmatter) is handed back so the ingest pipeline can run the A18
    end-to-end coverage checks against it after chunking — the reader itself is a pure parser.
    Raises ValueError on an over-size file or non-UTF-8 bytes (cmd_ingest_md turns these into a
    clean FATAL rather than an unhandled traceback).
    """
    data = path.read_bytes()
    if len(data) > _MAX_MD_BYTES:
        raise ValueError(f"{path} is {len(data)} bytes (> {_MAX_MD_BYTES} cap)")
    try:
        raw = data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise ValueError(f"{path} is not valid UTF-8: {e}") from e
    # Normalize line endings so the LF-anchored frontmatter regex (and everything after) works on
    # CRLF / CR files; otherwise a Windows-authored note's frontmatter is silently unrecognised
    # and its doc_id/version/sha never recovered. Not content — coverage tokens are unaffected.
    raw = raw.replace("\r\n", "\n").replace("\r", "\n")
    sha = hashlib.sha256(data).hexdigest()

    front, body_md = _parse_frontmatter(raw)
    blocks = _blocks(body_md)
    anchors = [b.page for b in blocks if b.page is not None]

    # Frontmatter doc_id / source_sha256 are trusted only if they have the expected shape;
    # otherwise derived. reconcile keys the whole index on doc_id (delete-then-insert) and records
    # source_sha256 as provenance, so an arbitrary crafted value is a spoof / collision surface.
    fid = front.get("doc_id", "")
    fsha = front.get("source_sha256", "")
    doc = Document(
        doc_id=fid if _DOC_ID.fullmatch(fid) else doc_id_for(path),
        source_path=str(path),
        source_sha256=fsha if _SHA256.fullmatch(fsha) else sha,
        source_pages=_bounded_int(front.get("source_pages", ""), 1, _I64)
        or (max(anchors) if anchors else 1),
        document_class=doc_class or front.get("document_class") or "reference-frozen",
        blocks=blocks,
        title=front.get("title"),
        version=front.get("version"),
        version_date=front.get("version_date"),
        page_label_offset=_bounded_int(front.get("page_label_offset", ""), -_I64, _I64),
        extractor="markdown-reader/0.1.0",
        extractor_arm="markdown",
        layout_model="",
    )

    stats = {
        "blocks": len(blocks),
        "headings": sum(1 for b in blocks if b.kind is Kind.HEADING),
        "code": sum(1 for b in blocks if b.kind is Kind.CODE),
        "tables": sum(1 for b in blocks if b.kind is Kind.TABLE),
        "list_items": sum(1 for b in blocks if b.kind is Kind.LIST_ITEM),
    }
    return doc, body_md, stats
