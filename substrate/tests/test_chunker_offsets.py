"""Regression tests for chunk.chunker split-prose offsets.

Runnable with `python tests/test_chunker_offsets.py` or under pytest.

Pins H4: an oversized prose paragraph split into sentence pieces must give each piece its OWN
disjoint char_start/char_end (the bug handed every piece the WHOLE paragraph's span), the pieces
must reconstruct the unit byte-for-byte (`chunk.text == body[char_start:char_end]`) and sum to
its length, and a runt tail absorbed back must stay byte-exact — even when the source has the
multi-space sentence gaps a PDF extractor commonly leaves.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import substrate.chunk.chunker as ck  # noqa: E402
from substrate.chunk.chunker import _pack_section, _split_prose  # noqa: E402
from substrate.chunk.sections import Section, Unit  # noqa: E402
from substrate.models import Block, Document, Kind  # noqa: E402

_DOC = Document(doc_id="d", source_path="/x", source_sha256="a", source_pages=1,
                document_class="reference-frozen")


def _pack(unit: Unit, target: int, mx: int, mn: int) -> list:
    saved = (ck.TARGET, ck.MAX, ck.MIN)
    ck.TARGET, ck.MAX, ck.MIN = target, mx, mn
    try:
        return _pack_section(_DOC, Section(path=["Ch", "Sec"], level=2, units=[unit]), 0)[0]
    finally:
        ck.TARGET, ck.MAX, ck.MIN = saved


def _text_unit(text: str, start: int = 0) -> Unit:
    b = Block(id="b1", kind=Kind.TEXT, text=text)
    b.char_start, b.char_end = start, start + len(text)   # TEXT renders verbatim: span == len
    return Unit([b])


def test_split_prose_spans_tile_text() -> None:
    text = "First sentence here. " * 20
    spans = _split_prose(text, 100)
    assert spans[0][0] == 0 and spans[-1][1] == len(text)
    for (s0, e0), (s1, e1) in zip(spans, spans[1:]):
        assert e0 == s1 and e0 > s0                       # contiguous, non-empty, no overlap


def test_single_over_limit_sentence_emitted_whole() -> None:
    text = "Onelongsentencewithnobreaks" * 10
    assert _split_prose(text, 50) == [(0, len(text))]


def test_pieces_are_byte_exact_disjoint_and_cover_the_unit() -> None:
    body = "This is sentence alpha here.  This is sentence beta now.  " * 10   # double spaces
    chunks = _pack(_text_unit(body), 100, 200, 40)
    assert len(chunks) >= 2
    assert len({(c.char_start, c.char_end) for c in chunks}) == len(chunks)    # distinct (the bug)
    for c in chunks:
        assert c.text == body[c.char_start:c.char_end]                        # byte-exact slice
        assert c.char_end - c.char_start == len(c.text)                       # span == n_chars
    assert chunks[0].char_start == 0 and chunks[-1].char_end == len(body)
    for a, b in zip(chunks, chunks[1:]):
        assert a.char_end == b.char_start                                     # contiguous tiling
    assert sum(len(c.text) for c in chunks) == len(body)                      # coverage exact


def test_runt_absorption_stays_byte_exact() -> None:
    body = "Sentence alpha here now today.  " * 16
    chunks = _pack(_text_unit(body), 150, 300, 140)                           # forces a runt merge
    for c in chunks:
        assert c.text == body[c.char_start:c.char_end]                        # merge stays exact
        assert "\n\n" not in c.text                                          # no injected break
        assert len(c.block_ids) == len(set(c.block_ids))                      # ids deduped


def test_list_item_splits_without_oversize() -> None:
    """A LIST_ITEM's markup offsets shift the unit; it must still split into disjoint,
    non-oversize pieces (not be emitted whole and trip the A13 'no oversized prose' gate)."""
    text = "This is sentence alpha here. " * 30
    b = Block(id="b2", kind=Kind.LIST_ITEM, text=text)
    b.char_start, b.char_end = 1000, 1000 + len(text) + 2                     # "- " markup
    chunks = _pack(Unit([b]), 100, 200, 40)
    assert len(chunks) >= 2
    assert not any(c.oversize for c in chunks)
    for a, b_ in zip(chunks, chunks[1:]):
        assert a.char_end <= b_.char_start                                    # disjoint


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
