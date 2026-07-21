"""Text normalization — the corruptions that survive a perfect layout model.

Both defects here are glyph-mapping artifacts, not layout questions, so no extractor fixes
them. Measured on DDIA (673pp, 2026-07-21):

  soft hyphen  28/29 survive as `determin ! istic`   -> text/hyphens.py
  ligatures    32 orphaned tokens, `Bloom fi lter`   -> here

The ligature case matters more than its count: it corrupts exactly the technical terms
retrieval depends on. A search for "Bloom filter" cannot match "Bloom fi lter", so the
passage is silently unreachable while looking perfectly fine to a reader.
"""

from __future__ import annotations

import re
import unicodedata

# Orphaned ligature tokens always bind to the FOLLOWING fragment:
#   fi + lter -> filter    fl + ow -> flow    fi + rst -> first
# 'ff' is excluded: it is a real abbreviation ("ff." = following) and was measured 0 times.
LIGATURES = ("ffi", "ffl", "fi", "fl")

_LIG = re.compile(rf"(?<![A-Za-z])({'|'.join(LIGATURES)})\s+([a-z]{{1,}})", re.UNICODE)
_C0 = re.compile(r"[\x00-\x08\x0b\x0c\x0e-\x1f\x7f]")
_BLANKS = re.compile(r"\n{3,}")
_FENCE = re.compile(r"```.*?```", re.DOTALL)


def _mask_code(text: str) -> tuple[str, list[str]]:
    blocks: list[str] = []

    def grab(m: re.Match[str]) -> str:
        blocks.append(m.group(0))
        return f"\x00FENCE{len(blocks) - 1}\x00"

    return _FENCE.sub(grab, text), blocks


def _unmask_code(text: str, blocks: list[str]) -> str:
    for i, b in enumerate(blocks):
        text = text.replace(f"\x00FENCE{i}\x00", b)
    return text


def repair_ligatures(text: str) -> tuple[str, dict]:
    """Rejoin ligature tokens that were split off from their word."""
    body, blocks = _mask_code(text)
    samples: list[str] = []
    n = 0

    def fix(m: re.Match[str]) -> str:
        nonlocal n
        n += 1
        joined = m.group(1) + m.group(2)
        if len(samples) < 30:
            samples.append(f"{m.group(0)}  ->  {joined}")
        return joined

    body = _LIG.sub(fix, body)
    return _unmask_code(body, blocks), {"joined": n, "samples": samples}


def ligature_residue(text: str) -> int:
    """Assertion: orphaned ligature tokens left in the final markdown."""
    body, _ = _mask_code(text)
    return len(_LIG.findall(body))


def normalize(text: str) -> str:
    """NFC, drop C0 controls, collapse runs of blank lines. Typography is preserved.

    Curly quotes and dashes stay as the author set them — the markdown is the substrate of
    record and a human reads it. Stripping C0 mirrors ScriptaCore's `stripControlChars`, so
    bytes crossing into SQLite FTS can never truncate at a NUL.
    """
    text = unicodedata.normalize("NFC", text)
    text = _C0.sub("", text)
    text = text.replace(" ", " ")
    return _BLANKS.sub("\n\n", text).strip() + "\n"
