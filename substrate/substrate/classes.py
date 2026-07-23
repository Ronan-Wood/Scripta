"""Document classes — the organizing principle, not a filter flag.

Class drives chunking, expiry, trust and required fields. The one hard gate today:
`reference-versioned` ingestion FAILS if no version is captured. A spec passage that cannot
answer "is this the current version?" is worse than absent, because it reads authoritative
while being silently stale — the exact confidence-laundering the model spec forbids.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

from substrate.models import Block, Document, Kind

# Ordered: first match wins. Kept deliberately narrow — a loose pattern that matches a
# copyright year or an ISBN would satisfy the gate while capturing nothing meaningful.
VERSION_PATTERNS: list[re.Pattern] = [
    re.compile(r"\b((?:go|python|java|rust|c\+\+|ecmascript)\s?\d+(?:\.\d+)+)\b", re.I),
    re.compile(r"\bversion[:\s]+((?:v)?\d+(?:\.\d+)+(?:[-\w.]*)?)\b", re.I),
    re.compile(r"\b(?:release|revision)[:\s]+((?:v)?\d+(?:\.\d+)+)\b", re.I),
    re.compile(r"\b(v\d+\.\d+(?:\.\d+)?)\b"),
]

DATE_PATTERNS: list[re.Pattern] = [
    re.compile(r"\(([A-Z][a-z]{2,8}\s+\d{1,2},\s+\d{4})\)"),
    re.compile(r"\b([A-Z][a-z]{2,8}\s+\d{1,2},\s+\d{4})\b"),
    re.compile(r"\b(\d{4}-\d{2}-\d{2})\b"),
]

# How many leading blocks to search. A version statement lives on the title page; scanning
# the whole book would happily match a version number quoted in a code example on page 400.
HEAD_BLOCKS = 40


@dataclass
class ChunkPolicy:
    """Chunk geometry per document class.

    Class drives chunking rather than one global setting because the classes have genuinely
    different shapes. A language spec is dense, clause-structured and largely self-contained
    per section — smaller chunks keep a clause whole and avoid dragging in an unrelated one.
    A textbook is flowing argument where a passage stripped of its surroundings loses the
    thread, so it wants more context per chunk.

    These are close to what the two corpora produced NATURALLY (Go spec p50 996, DDIA p50
    1490) — the policy makes an emergent property explicit and stable rather than imposing
    something new.
    """

    target: int = 1400
    max_chars: int = 2600
    min_chars: int = 400


@dataclass
class ClassPolicy:
    name: str
    requires_version: bool = False
    frozen: bool = True
    description: str = ""
    required_fields: list[str] = field(default_factory=list)
    chunk: ChunkPolicy = field(default_factory=ChunkPolicy)


POLICIES: dict[str, ClassPolicy] = {
    "reference-frozen": ClassPolicy(
        "reference-frozen",
        requires_version=False,
        frozen=True,
        description="A published edition that will not change (textbook).",
        required_fields=["title", "source_sha256"],
        chunk=ChunkPolicy(target=1500, max_chars=2800, min_chars=450),
    ),
    "reference-versioned": ClassPolicy(
        "reference-versioned",
        requires_version=True,
        frozen=False,
        description="A living spec whose passages are only true for a stated version.",
        required_fields=["title", "source_sha256", "version"],
        chunk=ChunkPolicy(target=1000, max_chars=2000, min_chars=300),
    ),
}


class ClassPolicyError(RuntimeError):
    pass


def extract_title(doc: Document) -> str | None:
    """First level-1 heading, else the first heading of any level."""
    heads = [b for b in doc.blocks if b.kind is Kind.HEADING and b.text.strip()]
    for b in heads:
        if b.level == 1:
            return b.text.strip()
    return heads[0].text.strip() if heads else None


def extract_version(blocks: list[Block]) -> tuple[str | None, str | None, str | None]:
    """Return (version, date, source_text) from the document head."""
    for b in blocks[:HEAD_BLOCKS]:
        text = b.text.strip()
        if not text or len(text) > 300:
            continue
        for pat in VERSION_PATTERNS:
            m = pat.search(text)
            if not m:
                continue
            version = m.group(1).strip()
            date = None
            for dpat in DATE_PATTERNS:
                dm = dpat.search(text)
                if dm:
                    date = dm.group(1).strip()
                    break
            return version, date, text
    return None, None, None


def apply(doc: Document) -> dict:
    """Populate class-driven fields and enforce the policy. Raises on violation."""
    policy = POLICIES.get(doc.document_class)
    if policy is None:
        raise ClassPolicyError(
            f"unknown document_class {doc.document_class!r}; known: {sorted(POLICIES)}"
        )

    doc.title = doc.title or extract_title(doc)

    # Re-extract a version from the body only when one was not already supplied (the markdown
    # reader recovers it from frontmatter). The PDF path has doc.version=None here, so it still
    # extracts; round-tripping the engine's own reference-versioned markdown keeps its version
    # instead of failing the required-field gate when the body no longer re-matches.
    if policy.requires_version and not doc.version:
        version, date, src = extract_version(doc.blocks)
        doc.version, doc.version_date, doc.version_source = version, date, src

    missing = [
        f
        for f in policy.required_fields
        if not getattr(doc, f, None) and not getattr(doc, f.replace("source_", "source_"), None)
    ]
    if missing:
        raise ClassPolicyError(
            f"{doc.document_class}: missing required field(s) {missing}. "
            "Refusing to ingest — a passage that cannot state its own version or identity "
            "reads authoritative while being unverifiable."
        )

    return {
        "document_class": policy.name,
        "frozen": policy.frozen,
        "version": doc.version,
        "version_date": doc.version_date,
        "version_source": doc.version_source,
        "title": doc.title,
    }
