"""Section-kind classification and retrieval weighting.

Measured: the query "teaching a system right from wrong by letting it learn from examples"
returned the paper's **References** section at rank 1. That is not a semantic gap — it is a
lexical pathology. A references list carries enormous vocabulary diversity (author names,
paper titles, venues across a whole field), so it holds a weak lexical match against almost
any vague query, and BM25's length normalization does not undo that. References sections act
as ATTRACTORS.

This matters beyond one bad result: if an embedder is added while this is live, vectors get
credit for fixing a structural ranking bug and there is no clean read on whether they earned
their place. Fix the structure first, then measure semantics.

Weighting rather than exclusion — a reference list is a legitimate answer to "what did they
cite about X", just never the best answer to a conceptual question.
"""

from __future__ import annotations

import re

BODY = "body"
REFERENCES = "references"
GLOSSARY = "glossary"
APPENDIX = "appendix"
FRONTMATTER = "frontmatter"

_PATTERNS: list[tuple[str, re.Pattern]] = [
    (REFERENCES, re.compile(r"\b(references?|bibliograph|further reading|works cited)\b", re.I)),
    (GLOSSARY, re.compile(r"\b(glossary|terminology)\b", re.I)),
    (APPENDIX, re.compile(r"\bappendix\b", re.I)),
    (
        FRONTMATTER,
        re.compile(
            r"\b(preface|foreword|acknowledgment|acknowledgement|about the author|"
            r"colophon|revision history|copyright)\b",
            re.I,
        ),
    ),
]

# Multiplies the bm25 score. SQLite's bm25() is NEGATIVE with more-negative meaning better,
# so a factor < 1 moves a hit TOWARD zero and therefore down the ranking.
WEIGHTS: dict[str, float] = {
    BODY: 1.0,
    APPENDIX: 0.85,
    GLOSSARY: 0.75,
    FRONTMATTER: 0.60,
    REFERENCES: 0.35,
}


def classify(path_str: str | None) -> str:
    """Derive section kind from the structural path. Deterministic, no model."""
    if not path_str:
        return BODY
    for kind, pattern in _PATTERNS:
        if pattern.search(path_str):
            return kind
    return BODY


def weight_sql(column: str = "c.section_kind") -> str:
    """CASE expression multiplying bm25 by the section weight."""
    arms = " ".join(f"WHEN '{k}' THEN {v}" for k, v in WEIGHTS.items() if k != BODY)
    return f"(CASE {column} {arms} ELSE 1.0 END)"
