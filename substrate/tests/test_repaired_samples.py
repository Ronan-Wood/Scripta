"""Regression test: dehyphenation repair samples cross the boundary into emit() stats / run.json.

Runnable with `python tests/test_repaired_samples.py` or under pytest.

Pins the Boundary-Principle fix behind the review's "Repaired words" section. dehyphenate() records
each reassembled word (`orig -> joined`) in a `samples` list, but _repair_blocks used to keep only
the counts and drop the samples — so review.py fell back to grepping long words and mislabelled them
"Repaired words". _repair_blocks now accumulates the samples (bounded at 40) and emit() threads them
into its stats as `repaired_samples`, so run["emit"]["repaired_samples"] carries the ACTUAL words the
repair joined instead of a length proxy.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.markdown.emit import _repair_blocks, emit  # noqa: E402
from substrate.models import Block, Document, Kind  # noqa: E402
from substrate.text.hyphens import Calibration  # noqa: E402


def _block(text: str, i: int = 0) -> Block:
    return Block(id=f"b{i}", kind=Kind.TEXT, text=text)


def _doc(*texts: str) -> Document:
    return Document(
        doc_id="d", source_path="/x.pdf", source_sha256="s", source_pages=1,
        document_class="reference-frozen",
        blocks=[_block(t, i) for i, t in enumerate(texts)],
    )


def test_repair_blocks_carries_reassembled_words() -> None:
    # `!` always joins (no compound-keep, unlike `-`), so a fixed Calibration is deterministic.
    stats = _repair_blocks(
        [_block("informa!tion follows", 0), _block("recon!struct it", 1)],
        Calibration(glyph="!"),
    )
    joined = stats["repaired_samples"]
    assert stats["hyphens"] == 2
    assert all("->" in s for s in joined)                      # `orig -> joined` shape preserved
    assert any(s.endswith("information") for s in joined)      # the real reassembled word, not length
    assert any(s.endswith("reconstruct") for s in joined)


def test_repair_samples_bounded_at_40() -> None:
    # Three blocks x 20 joins = 60 candidates; the count is exact but the run.json payload is capped.
    blocks = [_block("aa!bb " * 20, i) for i in range(3)]
    stats = _repair_blocks(blocks, Calibration(glyph="!"))
    assert stats["hyphens"] == 60                              # every join counted...
    assert len(stats["repaired_samples"]) == 40                # ...but the carried sample is bounded


def test_emit_exposes_repaired_samples_in_both_modes() -> None:
    # emit() must always surface the key so run.json / review.py can read it uniformly. The markdown
    # path applies no glyph repair, so it is deterministically empty.
    _, pdf_stats = emit(_doc("informa!tion here"))            # PDF path (repair=True)
    assert "repaired_samples" in pdf_stats
    _, md_stats = emit(_doc("informa!tion here"), repair=False)
    assert md_stats["repaired_samples"] == []


if __name__ == "__main__":
    _tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    _failed = 0
    for _t in _tests:
        try:
            _t()
            print(f"  PASS  {_t.__name__}")
        except Exception as e:  # noqa: BLE001
            _failed += 1
            print(f"  FAIL  {_t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(_tests) - _failed}/{len(_tests)} passed")
    raise SystemExit(1 if _failed else 0)
