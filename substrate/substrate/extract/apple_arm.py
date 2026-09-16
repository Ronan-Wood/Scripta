"""Apple's on-device document recognizer, driven through `bin/extract-apple`.

The reader for what has no text layer: an image, or a PDF page that is only a picture of text. It
needs no model weights, because Vision ships with macOS 26, so a Mac with nothing installed can import
a scan. docling with its models, when the operator names a folder for them, is the higher-fidelity
reader for the same inputs.

`bin/extract-apple` is compiled from `tools/extract-apple.swift` by `tools/build-bundled-engine`, like
the embedding and reranking arms. It is found beside the package rather than relative to the working
directory, because the CLI is launched from wherever its caller happens to be.
"""

from __future__ import annotations

import errno
import json
import os
import re
import statistics
import subprocess
from pathlib import Path

from substrate.extract.base import LIST_MARKER

BINARY = Path(__file__).resolve().parents[2] / "bin" / "extract-apple"
EXTRACTOR = "apple-vision RecognizeDocumentsRequest"

# A recognized paragraph is a heading when its lines are this much taller than the document's median
# paragraph line, it is short, and it does not end like a sentence. Vision reports line BOXES, not
# type sizes, and a box's height moves with the letters in it, so this is weaker evidence than the
# text layer's. Measured 2026-09-15 on a scan of the sample report: a 24 pt title read 26.3 and a
# 16 pt section 19.3, against 15.8 to 17.5 for body lines, so a 13 pt subsection was not found.
HEADING_FACTOR = 1.15
MAX_HEADING_CHARS = 120
# Vision names the first prominent line a title even when it is a sentence: measured on a sample
# image, a 95-character opening sentence came back as the title. A longer one is read as a paragraph.
MAX_TITLE_CHARS = 80
_SENTENCE_END = re.compile(r"[.!?,;:]['\"”’)]?$")

# Seconds. Measured 2026-09-15: about half a second a page, rendered at twice its point size. The
# allowance is generous because a hung reader is what it bounds, not a slow one.
TIMEOUT_BASE = 60
TIMEOUT_PER_PAGE = 20
TIMEOUT_CEILING = 900

# PAGES ARE READ IN BATCHES, for the reason the docling arm batches: one call for a whole document is
# one subprocess holding the whole document's JSON, with a timeout scaled to the page count. A
# 2,000-page scan would have allowed a single process eleven hours.
BATCH_PAGES = 50


class AppleReaderError(RuntimeError):
    """The reader ran and could not read the input. Carries the reader's own sentence."""


class AppleReaderUnavailable(AppleReaderError):
    """The reader is not in this engine, so nothing was attempted."""


def read(path: Path, *, pages: list[int] | None = None) -> dict:
    """The recognizer's JSON for an image, or for the named pages of a PDF, numbered from 1."""
    if not pages:
        return _read_once(path, None)
    data = _read_once(path, pages[:BATCH_PAGES])
    for start in range(BATCH_PAGES, len(pages), BATCH_PAGES):
        data["pages"] += _read_once(path, pages[start:start + BATCH_PAGES])["pages"]
    return data


def _read_once(path: Path, pages: list[int] | None) -> dict:
    """One run of the reader, over one batch of pages or a whole image."""
    if not (BINARY.is_file() and os.access(BINARY, os.X_OK)):
        raise AppleReaderUnavailable(
            f"Apple's document reader is not in this engine (no {BINARY}). "
            "`tools/build-bundled-engine` compiles it; naming a docling models folder with "
            "--docling-models reads the document without it."
        )
    command = [str(BINARY)]
    if pages:
        command += ["--pages", ",".join(str(p) for p in pages)]
    command.append(str(path))
    timeout = min(TIMEOUT_BASE + TIMEOUT_PER_PAGE * max(len(pages or ()), 1), TIMEOUT_CEILING)
    where = f"page(s) {pages[0]}-{pages[-1]} of {path.name}" if pages else path.name
    try:
        proc = subprocess.run(command, capture_output=True, timeout=timeout, check=False)
    except subprocess.TimeoutExpired as e:
        raise AppleReaderError(
            f"Apple's document reader did not finish {where} within {timeout} seconds"
        ) from e
    except OSError as e:
        # ONLY "not there, or not runnable" means the reader is ABSENT. Anything else — an argument
        # list the kernel refuses, no memory to fork — is a failed read, and reporting it as a missing
        # reader sends the operator to rebuild the engine over a document-sized problem.
        if e.errno in (errno.ENOENT, errno.EACCES, errno.EPERM, errno.ENOEXEC):
            raise AppleReaderUnavailable(f"Apple's document reader could not start: {e}") from e
        raise AppleReaderError(f"Apple's document reader could not run on {where}: {e}") from e
    if proc.returncode != 0:
        reason = proc.stderr.decode("utf-8", "replace").strip()
        raise AppleReaderError(reason or f"Apple's document reader exited with status {proc.returncode}")
    try:
        data = json.loads(proc.stdout)
    except ValueError as e:
        raise AppleReaderError(f"Apple's document reader returned output that is not JSON: {e}") from e
    if not isinstance(data, dict) or not isinstance(data.get("pages"), list):
        raise AppleReaderError("Apple's document reader returned JSON without a list of pages")
    return data

def _height(block: dict) -> float | None:
    value = block.get("line_height")
    return float(value) if isinstance(value, (int, float)) and value > 0 else None


def body_line_height(data: dict) -> float | None:
    """The median line height of the recognized paragraphs, across every page read."""
    heights = [h for page in data["pages"] for block in page.get("blocks", ())
               if block.get("kind") == "text" and (h := _height(block)) is not None]
    return statistics.median(heights) if heights else None


def is_heading(block: dict, body: float | None) -> bool:
    """A short recognized title; a paragraph when short, unpunctuated at its end, and set taller."""
    kind = block.get("kind")
    text = " ".join(str(block.get("text", "")).split())
    if kind == "title":
        return 0 < len(text) <= MAX_TITLE_CHARS
    height = _height(block)
    return (
        kind == "text"
        and body is not None
        and height is not None
        and height >= body * HEADING_FACTOR
        and 0 < len(text) <= MAX_HEADING_CHARS
        and not _SENTENCE_END.search(text)
    )


def to_markdown(data: dict) -> str:
    """The recognized document as markdown, for the converted-document path."""
    body = body_line_height(data)
    parts: list[str] = []
    for page in data["pages"]:
        for block in page.get("blocks", ()):
            text = str(block.get("text", "")).strip()
            if not text:
                continue
            kind = block.get("kind")
            if kind == "table":
                parts.append(text)
            elif kind == "list_item":
                item = " ".join(text.split())
                parts.append("- " + (LIST_MARKER.sub("", item).strip() or item))
            elif is_heading(block, body):
                parts.append(("# " if kind == "title" else "## ") + " ".join(text.split()))
            else:
                parts.append(text)
    return "\n\n".join(parts) + ("\n" if parts else "")
