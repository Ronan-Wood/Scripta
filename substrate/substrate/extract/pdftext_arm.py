"""The PDF reader that needs nothing installed: the PDF's own text layer, read with pdfium.

Most PDFs carry their text as text, and pdfium reads it exactly, with the size and font of every
character. That recovers what the chunker needs: headings from type size and weight, list items from
their markers, and running headers and footers from their position, which `furniture.validate` then
corroborates by repetition exactly as it checks docling's labels. A page with no text layer, a scan,
goes to Apple's on-device recognizer (`apple_arm`). No model weights are involved at any step, so a Mac
with nothing installed reads PDFs.

docling with its layout and table models stays the higher-fidelity reader, chosen when the operator
names a models folder. What this reader does not recover, stated rather than left to be found:

  * TABLES arrive as their text, line by line, not as markdown tables.
  * A HEADING SET IN BODY TYPE, the same size and not bold, reads as a paragraph. docling finds some
    of those from the page image.
  * COLUMNS are read in pdfium's text order, which follows the content stream: usually column by
    column, not always.
  * A MIXED PDF, some pages text and some scanned, compares type sizes on text pages with recognized
    line boxes on scanned ones, converted at a measured ratio, so one heading style can still land on
    two levels.

Measured 2026-09-15 against docling with its models, on the same Mac (this reader / docling):

    | PDF           | pages | headings                | furniture dropped | extraction    |
    |---------------|-------|-------------------------|-------------------|---------------|
    | sample report | 3     | the same 10, same levels | the same 6        | 0.1 s / 8.8 s |
    | macOS license | 16    | 35 / 35, 34 in common    | 0 / 0             | 0.3 s / 2.7 s |

docling also rendered the report's 3 tables as markdown tables. On a scanned copy of the report,
Apple's recognizer found the title and the 3 section headings but none of the 13 pt subsections, in
1.8 s.
"""

from __future__ import annotations

import ctypes
import re
import time
from collections import Counter
from dataclasses import dataclass
from pathlib import Path

from substrate.extract import apple_arm
from substrate.extract.assemble import assemble
from substrate.extract.base import LIST_MARKER
from substrate.models import Block, Document, Kind

# A page whose text layer holds fewer word characters than this, and which carries an image, is read
# as a scan. Scanned PDFs often keep a few stray characters in their text layer, a stamped page number
# or an OCR fragment, so zero would miss them; a real page of text has hundreds.
MIN_TEXT_CHARS = 20

# Running headers and footers sit in the top and bottom strips of a page and are short. A block there
# is only CLAIMED as furniture: `furniture.validate` honours the claim when the text repeats across
# pages and re-admits it otherwise.
EDGE_SHARE = 0.06
MAX_EDGE_CHARS = 80

# A heading is short, and set larger than the body or bold where the body is not. BOLD_SHARE counts
# the line's characters, so a bold defined term inside a sentence does not make its line a heading:
# measured on the macOS license, a majority rule promoted a body line carrying two bold terms.
HEADING_SIZE_FACTOR = 1.15
BOLD_SHARE = 0.9
MAX_SHORT_CHARS = 60
MAX_HEADING_CHARS = 120
MAX_HEADING_LINES = 2

# A line continues the paragraph above it when it has the same style and starts less than this share
# of its type size below that paragraph's last line.
PARAGRAPH_GAP = 0.8

# Apple's recognizer measures a line's box, which is taller than its type: about 1.2 times the size,
# measured 2026-09-15 on a scan of the sample report, where 16 pt read 19.3 and 13 pt read 15.8.
# Dividing it out keeps a scanned page's headings on the same ladder as a text page's in a mixed PDF;
# without it a 16 pt section on page 1 and the same style scanned on page 2 landed two levels apart.
LINE_BOX_PER_POINT = 1.2

SOFT_HYPHEN = "­"

_BOLD_FONT = re.compile(r"bold|black|heavy|semibold|demi", re.IGNORECASE)
_WORD = re.compile(r"\w")
_SPACE = re.compile(r"\s+")
_LABEL = {Kind.HEADING: "section_header", Kind.LIST_ITEM: "list_item", Kind.TABLE: "table",
          Kind.TEXT: "text"}


class PdfReadError(RuntimeError):
    """The PDF could not be read. An input problem: nothing is indexed."""


@dataclass
class _Line:
    text: str
    left: float
    top: float
    bottom: float
    size: float
    bold: bool
    # False when pdfium measured none of this line's characters. The TEXT is still the document's,
    # so it is kept; everything read off geometry — the heading ladder, the furniture strip, the
    # paragraph gap — has nothing to work with and must not guess.
    measured: bool = True


@dataclass
class _Run:
    """Consecutive lines of one style on one page: a paragraph, a heading or a list item."""

    text: str
    page: int
    left: float
    top: float
    bottom: float
    size: float
    bold: bool
    lines: int = 1
    kind: Kind = Kind.TEXT
    edge: bool = False
    measured: bool = True

    @property
    def rule(self) -> bool:
        """A line of dashes or underscores: a separator, never a heading or part of a paragraph."""
        return not _WORD.search(self.text)


def _page_lines(page) -> tuple[list[_Line], int]:
    """One page's lines in pdfium's text order, and how many word characters its text layer holds."""
    import pypdfium2.raw as raw

    height = page.get_height()
    textpage = page.get_textpage()
    try:
        handle = textpage.raw
        left, right, bottom, top = (ctypes.c_double() for _ in range(4))
        matrix = raw.FS_MATRIX()
        name = ctypes.create_string_buffer(256)
        flags = ctypes.c_int()
        lines: list[_Line] = []
        chars: list[str] = []
        styles: list[tuple[float, bool]] = []
        box = [float("inf"), float("inf"), float("-inf")]  # left, top, bottom
        words = 0

        def end_line() -> None:
            text = _SPACE.sub(" ", "".join(chars)).strip()
            if text and styles:
                size = Counter(s for s, _ in styles).most_common(1)[0][0]
                bold = sum(1 for _, b in styles if b) >= BOLD_SHARE * len(styles)
                lines.append(_Line(text, box[0], box[1], box[2], size, bold))
            elif text:
                # Text pdfium could not place. Dropping it would lose content silently, which is the
                # one thing this engine refuses to do; it is carried with no geometry instead.
                lines.append(_Line(text, 0.0, 0.0, 0.0, 0.0, False, measured=False))
            chars.clear()
            styles.clear()
            box[:] = [float("inf"), float("inf"), float("-inf")]

        for i in range(raw.FPDFText_CountChars(handle)):
            code = raw.FPDFText_GetUnicode(handle, i)
            if code in (10, 13):
                end_line()
                continue
            if code == 2:  # pdfium's mark for a hyphen that splits a word across two lines
                chars.append(SOFT_HYPHEN)
                continue
            if code in (0, 0xFFFE, 0xFFFF):
                continue
            ch = chr(code)
            chars.append(ch)
            if ch.isspace():
                continue
            if _WORD.match(ch):
                words += 1
            # A character pdfium cannot measure is KEPT AS TEXT and left out of the geometry. The
            # out-parameters are reused across the loop, so reading them after a failed call folds the
            # previous character's box and size into this line — and those decide furniture claims
            # and heading tiers.
            if not raw.FPDFText_GetCharBox(handle, i, left, right, bottom, top):
                continue
            if not raw.FPDFText_GetMatrix(handle, i, ctypes.byref(matrix)):
                continue
            # The size is in text space and the matrix scales it onto the page. Measured on the macOS
            # license: every character reports 1.0, and its matrix carries the real 10 pt.
            scale = abs(matrix.a * matrix.d - matrix.b * matrix.c) ** 0.5 or 1.0
            size = round(raw.FPDFText_GetFontSize(handle, i) * scale, 1)
            n = raw.FPDFText_GetFontInfo(handle, i, name, len(name), ctypes.byref(flags))
            font = name.value.decode("latin-1") if 0 < n <= len(name) else ""
            bold = raw.FPDFText_GetFontWeight(handle, i) >= 600 or bool(_BOLD_FONT.search(font))
            styles.append((size, bold))
            box[0] = min(box[0], left.value)
            box[1] = min(box[1], height - top.value)
            box[2] = max(box[2], height - bottom.value)
        end_line()
        return lines, words
    finally:
        textpage.close()


def _runs(lines: list[_Line], page: int) -> list[_Run]:
    runs: list[_Run] = []
    for line in lines:
        prev = runs[-1] if runs else None
        if (
            prev is not None
            and prev.measured
            and line.measured
            and not prev.rule
            and _WORD.search(line.text)
            and prev.size == line.size
            and prev.bold == line.bold
            and -2 < line.top - prev.bottom < line.size * PARAGRAPH_GAP
            and not LIST_MARKER.match(line.text)
        ):
            joined = prev.text[:-1] if prev.text.endswith(SOFT_HYPHEN) else prev.text + " "
            prev.text = joined + line.text
            prev.bottom = max(prev.bottom, line.bottom)
            prev.lines += 1
        else:
            runs.append(_Run(line.text, page, line.left, line.top, line.bottom, line.size,
                             line.bold, measured=line.measured))
    return runs


def _classify(runs: list[_Run], heights: dict[int, float]) -> tuple[float, bool]:
    """Set each run's kind and edge claim against the document's body style, which it returns."""
    weight: Counter = Counter()
    for run in runs:
        weight[(run.size, run.bold)] += len(run.text)
    if not weight:
        return 0.0, False
    body_size, body_bold = weight.most_common(1)[0][0]
    previous: _Run | None = None
    for run in runs:
        if not run.measured:
            # No geometry, so no claim: not furniture, not a heading, just text in reading order.
            run.kind = Kind.TEXT
            previous = run
            continue
        height = heights[run.page]
        run.edge = len(run.text) <= MAX_EDGE_CHARS and (
            run.top < height * EDGE_SHARE or run.bottom > height * (1 - EDGE_SHARE)
        )
        short = (run.lines == 1 and len(run.text) <= MAX_SHORT_CHARS) or (
            run.lines <= MAX_HEADING_LINES
            and len(run.text) <= MAX_HEADING_CHARS
            and not run.text.endswith((".", ",", ";"))
        )
        larger = run.size >= body_size * HEADING_SIZE_FACTOR
        bolder = run.bold and not body_bold and run.size >= body_size * 0.95
        # Tight under an unfinished sentence in the same type size, a line continues that sentence
        # whatever its weight: measured on the macOS license, a body line made entirely of bold
        # defined terms read as a heading between the two halves of its own sentence. Only a real
        # sentence counts above it. A heading, a separator rule or a running header does not, and
        # neither does smaller type: without those exceptions the sample report lost its title, which
        # sits just under its running header.
        continues = (
            previous is not None
            and previous.page == run.page
            and previous.kind is not Kind.HEADING
            and not previous.rule
            and not previous.edge
            and abs(previous.size - run.size) <= run.size * 0.05
            and -2 < run.top - previous.bottom < run.size * PARAGRAPH_GAP
            and not previous.text.endswith((".", ":", "!", "?"))
        )
        if run.rule:
            run.kind = Kind.TEXT
        elif short and (larger or bolder) and not continues:
            run.kind = Kind.HEADING
        elif (marker := LIST_MARKER.match(run.text)) and run.text[marker.end():].strip():
            # THE MARKER IS DROPPED. `markdown/emit.py` renders a list item as `- {text}` and
            # `markdown/reader.py` strips it on the way in, so a reader that keeps it emits `- - item`
            # into the body every chunk is cut from.
            run.kind = Kind.LIST_ITEM
            run.text = run.text[marker.end():].strip()
        else:
            run.kind = Kind.TEXT
        previous = run
    return body_size, body_bold


def _scanned_runs(data: dict) -> list[_Run]:
    """Apple's reading of the scanned pages, in the same shape as the text layer's runs."""
    body = apple_arm.body_line_height(data)
    runs: list[_Run] = []
    for page in data["pages"]:
        number = int(page["page"])
        height = float(page.get("height") or 0.0)
        for block in page.get("blocks", ()):
            text = str(block.get("text", "")).strip()
            if not text:
                continue
            kind = block.get("kind")
            line_height = block.get("line_height")
            line_height = float(line_height) if isinstance(line_height, (int, float)) else 0.0
            top = float(block.get("top") or 0.0)
            run = _Run(text if kind == "table" else _SPACE.sub(" ", text), number,
                       float(block.get("left") or 0.0), top, top + line_height,
                       round(line_height / LINE_BOX_PER_POINT, 1), False)
            if kind == "table":
                run.kind = Kind.TABLE
            elif kind == "list_item":
                run.kind = Kind.LIST_ITEM
                run.text = LIST_MARKER.sub("", run.text).strip() or run.text
            elif apple_arm.is_heading(block, body):
                run.kind = Kind.HEADING
            run.edge = kind != "table" and height > 0 and len(run.text) <= MAX_EDGE_CHARS and (
                top < height * EDGE_SHARE or run.bottom > height * (1 - EDGE_SHARE)
            )
            runs.append(run)
    return runs


def _page_list(pages: list[int]) -> str:
    shown = ", ".join(str(p) for p in pages[:10])
    return shown if len(pages) <= 10 else f"{shown} and {len(pages) - 10} more"


class TextLayerExtractor:
    name = "pdf-text"

    def extract(
        self, pdf: Path, doc_class: str, *, pages: tuple[int, int] | None = None, log=print
    ) -> Document:
        from importlib.metadata import version as pkg_version

        import pypdfium2 as pdfium
        import pypdfium2.raw as raw

        t0 = time.monotonic()
        runs: list[_Run] = []
        heights: dict[int, float] = {}
        text_pages: list[int] = []
        scanned: list[int] = []
        blank: list[int] = []
        try:
            document = pdfium.PdfDocument(str(pdf))
        except pdfium.PdfiumError as e:
            raise PdfReadError(
                f"{pdf.name} could not be opened as a PDF ({e}). A password-protected PDF has to be "
                "saved without its password first."
            ) from e
        try:
            total = len(document)
            first, last = pages or (1, total)
            last = min(last, total)
            for number in range(first, last + 1):
                page = document[number - 1]
                try:
                    heights[number] = page.get_height()
                    lines, words = _page_lines(page)
                    objects = raw.FPDFPage_CountObjects(page.raw)
                    has_image = words < MIN_TEXT_CHARS and any(
                        True for _ in page.get_objects(filter=[raw.FPDF_PAGEOBJ_IMAGE])
                    )
                finally:
                    page.close()
                if words >= MIN_TEXT_CHARS or (words > 0 and not has_image):
                    text_pages.append(number)
                    runs += _runs(lines, number)
                elif objects == 0:
                    blank.append(number)
                else:
                    scanned.append(number)
        except pdfium.PdfiumError as e:
            raise PdfReadError(f"{pdf.name} could not be read: {e}") from e
        finally:
            document.close()

        body_size, body_bold = _classify(runs, heights)

        if scanned:
            log(f"  {len(scanned)} page(s) have no text layer; reading them with Apple's recognizer")
            try:
                data = apple_arm.read(pdf, pages=scanned)
            except apple_arm.AppleReaderUnavailable as e:
                # THE ENGINE is incomplete, not the document. Collapsing this into the message below
                # would send the operator to look at their PDF for a build problem.
                raise PdfReadError(
                    f"{pdf.name} has {len(scanned)} page(s) with no text layer, and this engine "
                    f"cannot read them — {e}"
                ) from e
            except apple_arm.AppleReaderError as e:
                raise PdfReadError(
                    f"{pdf.name}: page(s) {_page_list(scanned)} have no text layer, and Apple's "
                    f"recognizer could not read them — {e}"
                ) from e
            runs += _scanned_runs(data)

        # Stable, so each page keeps its own reading order.
        runs.sort(key=lambda r: r.page)
        blocks = [
            Block(
                id=f"b{n:06d}",
                kind=Kind.FURNITURE if run.edge else run.kind,
                text=run.text.replace(SOFT_HYPHEN, "-"),
                page=run.page,
                # The kind this reader would give the block, so a re-admitted furniture claim gets it
                # back (see `assemble`).
                label=_LABEL[run.kind],
                height=run.size or None,
                left=round(run.left, 1),
                furniture_claimed=run.edge,
            )
            for n, run in enumerate(runs, 1)
        ]
        extractor = f"pypdfium2 {pkg_version('pypdfium2')}"
        if scanned:
            extractor += f" + {apple_arm.EXTRACTOR}"
        return assemble(
            pdf,
            doc_class,
            blocks,
            total_pages=total,
            pages_processed=max(last - first + 1, 0),
            seconds=time.monotonic() - t0,
            extractor=extractor,
            extractor_arm=self.name,
            layout_model="",
            stats={
                "text_layer_pages": len(text_pages),
                "scanned_pages": scanned,
                "blank_pages": blank,
                "body_font_pt": body_size,
                "body_bold": body_bold,
            },
        )
