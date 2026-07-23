"""Soft-hyphen calibration and repair.

Why this exists even though Docling handles layout: the soft hyphen is a ToUnicode
mapping artifact, not a layout question, so no layout model fixes it. Measured on DDIA
pp118-140 (2026-07-20): 29 hyphenation points in the source, 28 of which Docling emits
as `determin ! istic` — the glyph SURVIVES, spaced out. The spaced form is worse than
the raw one because it defeats the obvious `[a-z]![a-z]` check and reads as punctuation.

The glyph is DISCOVERED by voting, never assumed: it is `!` in DDIA (byte-verified
0x21) but is `-`, U+00AD or U+2010 in other producers.
"""

from __future__ import annotations

import re
from dataclasses import dataclass, field

# Every character seen acting as a soft hyphen across real PDF producers.
CANDIDATES = ("­", "‐", "‑", "!", "¬", "-", "/", "?")

# Left parts that legitimately keep their hyphen when the glyph is a real '-'.
KEEP_HYPHEN_PREFIXES = frozenset(
    "self non pre post re co anti multi well so semi sub inter intra cross over under".split()
)

_FENCE = re.compile(r"```.*?```", re.DOTALL)


@dataclass
class Calibration:
    glyph: str | None
    joins: int = 0
    votes: dict[str, int] = field(default_factory=dict)
    rejected: dict[str, int] = field(default_factory=dict)

    @property
    def confident(self) -> bool:
        return self.glyph is not None


def _mask_code(text: str) -> tuple[str, list[str]]:
    """Replace fenced blocks with placeholders so no rule can touch code."""
    blocks: list[str] = []

    def grab(m: re.Match[str]) -> str:
        blocks.append(m.group(0))
        return f"\x00FENCE{len(blocks) - 1}\x00"

    return _FENCE.sub(grab, text), blocks


def _unmask_code(text: str, blocks: list[str]) -> str:
    for i, b in enumerate(blocks):
        text = text.replace(f"\x00FENCE{i}\x00", b)
    return text


def _words(body: str) -> set[str]:
    return {w.casefold() for w in re.findall(r"[A-Za-z]{3,}", body)}


def _fragment_score(body: str, vocab: set[str], glyph: str, sample: int = 300) -> tuple[float, int]:
    """How often does joining across this glyph produce a REAL word?

    This is the discriminator that raw frequency cannot provide. A soft hyphen splits one
    word, so the joined form exists elsewhere in the document (`representa`+`tion` ->
    "representation"). A real hyphen joins two whole words, so the concatenation does not
    (`read`+`optimized` -> "readoptimized" appears nowhere).

    Without this, `-` wins on a 673-page book purely by out-numbering the true glyph, and
    743 legitimate compounds get silently welded together.
    """
    pairs = re.findall(rf"([a-z]{{2,}})\s*{re.escape(glyph)}\s*([a-z]{{2,}})", body)
    if not pairs:
        return 0.0, 0
    hits = sum(1 for left, right in pairs[:sample] if (left + right).casefold() in vocab)
    return hits / min(len(pairs), sample), len(pairs)


def calibrate(
    text: str, min_votes: int = 8, floor: float = 0.25, separation: float = 2.0
) -> Calibration:
    """Discover which character is acting as the soft hyphen.

    Selection is by FRAGMENT VALIDITY, not frequency — see _fragment_score — and is
    RELATIVE rather than absolute. The score scales with corpus size (a small sample has a
    small vocabulary, so joined forms corroborate less often): DDIA scores 0.64 over 673
    pages but only 0.43 over 23. An absolute threshold cannot serve both. The separation
    from the runner-up is stable at either size (3.9x and 25x), so that is the test.
    """
    body, _ = _mask_code(text)
    vocab = _words(body)

    scores: dict[str, tuple[float, int]] = {}
    for ch in CANDIDATES:
        scores[ch] = _fragment_score(body, vocab, ch)

    ranked = sorted(
        ((ch, s, n) for ch, (s, n) in scores.items() if n >= min_votes),
        key=lambda r: -r[1],
    )
    best, votes = None, 0
    if ranked:
        top_ch, top_score, top_n = ranked[0]
        runner = ranked[1][1] if len(ranked) > 1 else 0.0
        if top_score >= floor and top_score >= separation * max(runner, 1e-6):
            best, votes = top_ch, top_n

    return Calibration(
        glyph=best,
        joins=votes,
        votes={c: n for c, (s, n) in scores.items() if n},
        rejected={c: round(s, 3) for c, (s, n) in scores.items() if n},
    )


def _compound_kept(left: str, right: str, doc: str) -> bool:
    """For a real '-', decide whether the hyphen is part of the word."""
    if right[:1].isupper():
        return True
    if left.lower() in KEEP_HYPHEN_PREFIXES:
        return True
    # If the hyphenated form appears elsewhere in the document, it is a real compound.
    return len(re.findall(rf"\b{re.escape(left)}-{re.escape(right)}\b", doc)) >= 2


def dehyphenate(text: str, cal: Calibration) -> tuple[str, dict]:
    """Rejoin fragments split by the calibrated glyph. Returns (text, stats)."""
    if not cal.confident:
        return text, {"glyph": None, "joined": 0, "kept_hyphen": 0, "samples": []}

    body, blocks = _mask_code(text)
    glyph = cal.glyph
    joined = kept = 0
    samples: list[str] = []

    pattern = re.compile(rf"([A-Za-z]{{2,}})\s*{re.escape(glyph)}\s*([a-z]{{2,}})")

    def repair(m: re.Match[str]) -> str:
        nonlocal joined, kept
        left, right = m.group(1), m.group(2)
        # A real '-' can be a genuine compound; '!' and U+00AD never are.
        if glyph == "-" and _compound_kept(left, right, body):
            kept += 1
            return f"{left}-{right}"
        joined += 1
        if len(samples) < 40:
            samples.append(f"{m.group(0)}  ->  {left}{right}")
        return f"{left}{right}"

    body = pattern.sub(repair, body)
    out = _unmask_code(body, blocks)
    return out, {
        "glyph": glyph,
        "joined": joined,
        "kept_hyphen": kept,
        "samples": samples,
    }


def residue(text: str) -> int:
    """A1 assertion: hyphen artifacts left in the final markdown.

    Matches the SPACED form too — that is what Docling actually emits, and the
    unspaced-only regex returns a false clean.
    """
    body, _ = _mask_code(text)
    return len(re.findall(r"[a-z]\s*[!­‐‑]\s*[a-z]", body))
