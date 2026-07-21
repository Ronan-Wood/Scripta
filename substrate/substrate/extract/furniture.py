"""Furniture validation — verify Docling's PAGE_HEADER/PAGE_FOOTER labels before honoring them.

Docling classifies running headers/footers as furniture and drops them from the exported
body. On DDIA that is excellent: it catches all 29 footers including the parity-dependent
recto section titles that defeat a frequency detector.

But it also FALSE-POSITIVES. Measured on the Go spec (2026-07-20), a document with no
running furniture at all, Docling labelled three blocks as furniture — one of them a full
sentence of body text:

    "produces the same slice as allocating an array and slicing it,
     so these two expressions are equivalent"      (present in PDF p8, absent from output)

Silent deletion is a worse failure class than the noise it prevents. So a furniture label
is treated as a CLAIM to be corroborated, not an instruction.

Direction-of-error principle: when uncertain we RE-ADMIT. A stray footer left in the body
is visible noise that a human spots in the review packet; a deleted sentence is invisible
and unrecoverable. We bias hard toward keeping text.
"""

from __future__ import annotations

import re
from collections import defaultdict
from dataclasses import dataclass, field

# Real running furniture is short. The measured false positive was ~100 chars.
MAX_FURNITURE_CHARS = 90

# Real running furniture repeats across pages; misclassifications appear once.
# Calibrated on the full 673-page DDIA run (2026-07-21): 690 furniture blocks / 81 distinct
# forms. At 2 this honors 671 (97%) and recovers 19, which is the knee of the sweep.
MIN_DISTINCT_PAGES = 2

# Captions are content the chunker binds to its code block or figure. Docling labelled
# several as furniture on DDIA ("Example 3-12. ... expressed in Datalog"), and each appears
# on exactly one page, so repetition alone can never rescue them. Structural rule wins.
CAPTION = re.compile(r"^\s*(example|figure|table)\s+\d+[-.]\d+[.:]", re.IGNORECASE)

_SENTENCE_END = re.compile(r"[.!?]['\"”’]?$")
_WS = re.compile(r"\s+")
_DIGITS = re.compile(r"\d+")


@dataclass
class Verdict:
    honored: list = field(default_factory=list)
    readmitted: list = field(default_factory=list)
    reasons: dict = field(default_factory=dict)
    groups: dict = field(default_factory=dict)

    def summary(self) -> str:
        return (
            f"furniture: {len(self.honored)} honored, "
            f"{len(self.readmitted)} re-admitted to body"
        )


_PAGENO_LEAD = re.compile(r"^\s*[\divxlcIVXLC]+\s*[|—–-]\s*")
_PAGENO_TRAIL = re.compile(r"\s*[|—–-]\s*[\divxlcIVXLC]+\s*$")


def normalize(text: str) -> str:
    """Collapse page-varying detail so the same footer on different pages matches.

    The page number must be STRIPPED, not merely digit-masked. DDIA's footer alternates
    'Graph-Like Data Models' / 'Graph-Like Data Models | 97' / '98 | Chapter 3: ...'.
    Masking digits still leaves three distinct keys, so their pages never pool and a real
    running footer looks like a one-off.
    """
    t = _WS.sub(" ", text.strip())
    t = _PAGENO_LEAD.sub("", t)
    t = _PAGENO_TRAIL.sub("", t)
    return _DIGITS.sub("#", t.casefold())


def _is_bare_page_number(text: str) -> bool:
    return bool(re.fullmatch(r"[\s|—–-]*[\divxlcIVXLC]+[\s|—–-]*", text.strip()))


def validate(
    blocks,
    *,
    max_chars: int = MAX_FURNITURE_CHARS,
    min_pages: int = MIN_DISTINCT_PAGES,
) -> Verdict:
    """Split furniture-labelled blocks into genuinely-furniture vs wrongly-labelled.

    `blocks` is any sequence of objects/dicts exposing `text` and `page`.
    """

    def get(b, k):
        return b.get(k) if isinstance(b, dict) else getattr(b, k, None)

    pages_by_key: dict[str, set] = defaultdict(set)
    for b in blocks:
        pages_by_key[normalize(get(b, "text") or "")].add(get(b, "page"))

    v = Verdict(groups={k: sorted(p for p in ps if p is not None) for k, ps in pages_by_key.items()})

    for b in blocks:
        text = (get(b, "text") or "").strip()
        key = normalize(text)
        repeats = len(pages_by_key[key])
        why = []

        # A caption is never furniture, however it was labelled or how rarely it recurs.
        if CAPTION.match(text):
            v.readmitted.append(b)
            v.reasons[id(b)] = "caption — content, not furniture"
            continue

        # A bare page number is furniture even if it somehow looks odd otherwise.
        if _is_bare_page_number(text):
            v.honored.append(b)
            v.reasons[id(b)] = "page-number"
            continue

        if len(text) > max_chars:
            why.append(f"too long ({len(text)}>{max_chars})")
        if _SENTENCE_END.search(text):
            why.append("ends as a sentence")
        if repeats < min_pages:
            why.append(f"appears on {repeats} page(s) < {min_pages}")

        if why:
            v.readmitted.append(b)
            v.reasons[id(b)] = "; ".join(why)
        else:
            v.honored.append(b)
            v.reasons[id(b)] = f"repeats on {repeats} pages"

    return v
