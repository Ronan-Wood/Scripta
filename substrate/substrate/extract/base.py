"""Extractor protocol — the swappable seam.

Docling is the primary arm; the PyMuPDF heuristic stack is retained as a comparator so the
extractor choice stays empirical. Both must produce `Document`/`Block` and nothing else.
"""

from __future__ import annotations

import hashlib
import re
from pathlib import Path
from typing import Protocol

from substrate.models import Document

# The list markers an extractor recognises, and STRIPS: a `Block` of kind LIST_ITEM holds its text
# without its marker, because `markdown/emit.py` renders one as `- {text}` and `markdown/reader.py`
# strips it on the way in. A reader that keeps the marker emits `- - item`, and that body is what
# chunks are cut from. Wider than the markdown reader's rule, because a PDF or a recognized page
# carries typographic bullets and lettered clauses that markdown has no syntax for.
LIST_MARKER = re.compile(
    r"^\s*(?:[\u2022\u25cf\u25e6\u25aa\u2013*+-]"
    r"|\((?:\d{1,3}|[a-z]|[ivx]{1,5})\)"
    r"|(?:\d{1,3}|[A-Za-z])[.)])\s+"
)


class Extractor(Protocol):
    name: str

    def extract(self, pdf: Path, doc_class: str, *, pages: tuple[int, int] | None = None) -> Document:
        ...


def sha256_file(path: Path, chunk: int = 1 << 20) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while block := fh.read(chunk):
            h.update(block)
    return h.hexdigest()


def doc_id_from(stem: str, sha256: str) -> str:
    """The id SHAPE, for a caller that already knows the fingerprint.

    Split out of `doc_id_for` rather than copied: a second place that builds this string is a second
    place for the slug rule to drift, and only one of the two would get the next fix. The caller with
    a fingerprint in hand is the converted-document path, where re-reading the source to recompute
    a sha it just wrote into `SourceOrigin` would be both wasteful and a hard dependency on the file
    still being there.
    """
    s = "".join(c if c.isalnum() else "-" for c in stem.lower())
    s = "-".join(filter(None, s.split("-")))[:48]
    return f"{s}-{sha256[:8]}"


def doc_id_for(path: Path) -> str:
    """Stable, human-readable id derived from the filename plus a content fingerprint."""
    return doc_id_from(path.stem, sha256_file(path))
