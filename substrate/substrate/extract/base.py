"""Extractor protocol — the swappable seam.

Docling is the primary arm; the PyMuPDF heuristic stack is retained as a comparator so the
extractor choice stays empirical. Both must produce `Document`/`Block` and nothing else.
"""

from __future__ import annotations

import hashlib
from pathlib import Path
from typing import Protocol

from substrate.models import Document


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


def doc_id_for(path: Path) -> str:
    """Stable, human-readable id derived from the filename plus a content fingerprint."""
    stem = "".join(c if c.isalnum() else "-" for c in path.stem.lower())
    stem = "-".join(filter(None, stem.split("-")))[:48]
    return f"{stem}-{sha256_file(path)[:8]}"
