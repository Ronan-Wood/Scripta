r"""Regression test for LIKE-metacharacter escaping in structural-path matching (index_store).

Runnable with `python tests/test_like_escape.py` or under pytest.

Pins the low finding: `passages_under()` / `_match()` build a LIKE pattern from a caller-supplied
structural path (`<path> > %`). A heading can carry `_` or `%` (a snake_case term, a "100%" title);
used raw those are SQL wildcards, so `passages_under("Chapter A_B")` over-matches a sibling
"Chapter AXB". The path is now escaped with `ESCAPE '\'`, so `_`/`%` match literally. Both call
sites route the path through the same `_like_escape` helper; passages_under (a plain SELECT) is the
behavioural probe here — _match adds an FTS MATCH but uses the identical escaped LIKE construct.
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.store.index_store import IndexStore, _like_escape  # noqa: E402
from substrate.store.reconcile import reconcile  # noqa: E402


def _chunk(chunk_id: str, path: list[str], text: str, seq: int) -> dict:
    return {
        "chunk_id": chunk_id, "doc_id": "doc1", "kind": "passage", "text": text,
        "path": path, "level": len(path), "block_ids": ["b1"],
        "char_start": seq * 1000, "char_end": seq * 1000 + len(text),
        "page_start": 1, "page_end": 1, "n_chars": len(text),
        "part_index": None, "part_count": None, "oversize": False,
        "prev_id": None, "next_id": None, "document_class": "reference-frozen",
        "version": None, "source_sha256": "abc", "page_label_offset": None,
    }


def _build(chunks: list[dict]) -> str:
    """Reconcile a one-doc out/ dir holding `chunks` into a fresh temp index; return the db path."""
    out = Path(tempfile.mkdtemp()) / "out" / "doc1"
    out.mkdir(parents=True, exist_ok=True)
    (out / "document.md").write_text("# My Doc\n\nbody\n")
    (out / "chunks.jsonl").write_text("\n".join(json.dumps(c) for c in chunks) + "\n")
    (out / "run.json").write_text(json.dumps({
        "doc_id": "doc1", "source": "/x.pdf", "source_sha256": "abc", "pages": 9,
        "class": {"document_class": "reference-frozen", "title": "My Doc",
                  "version": None, "version_date": None},
        "extract": {"extractor": "docling"}, "coverage": 0.97, "elapsed_s": 1.0,
    }))
    db = str(Path(tempfile.mkdtemp()) / "index.db")
    with IndexStore(db) as s:
        reconcile(s, out.parent)
    return db


def test_like_escape_neutralizes_metacharacters() -> None:
    assert _like_escape("A_B") == r"A\_B"
    assert _like_escape("50%") == r"50\%"
    assert _like_escape("a\\b") == "a\\\\b"                # backslash escaped first (it IS the ESCAPE)
    assert _like_escape("plain path") == "plain path"     # no metacharacters → unchanged


def test_passages_under_underscore_does_not_overmatch() -> None:
    db = _build([
        _chunk("doc1#a", ["Chapter A_B", "Intro"], "under A underscore B", 0),
        _chunk("doc1#b", ["Chapter AXB", "Intro"], "under A X B", 1),
    ])
    with IndexStore(db) as s:
        hits = s.passages_under("doc1", "Chapter A_B")
    ids = {h.chunk_id for h in hits}
    assert ids == {"doc1#a"}, f"`_` wildcarded into the sibling 'Chapter AXB': {ids}"
    # Pin the storage assumption: reconcile keeps `_` literally in path_str (else this tests nothing).
    assert any(h.path_str == "Chapter A_B > Intro" for h in hits)


def test_passages_under_percent_does_not_overmatch() -> None:
    db = _build([
        _chunk("doc1#a", ["Chapter 50%", "Intro"], "literal percent", 0),
        _chunk("doc1#b", ["Chapter 50 done", "Intro"], "different chapter", 1),
    ])
    with IndexStore(db) as s:
        ids = {h.chunk_id for h in s.passages_under("doc1", "Chapter 50%")}
    assert ids == {"doc1#a"}, f"`%` wildcarded into 'Chapter 50 done': {ids}"


def test_match_path_prefix_underscore_does_not_overmatch() -> None:
    # The OTHER fixed site: _match() (the FTS path) applies the same escaped LIKE to path_prefix.
    # Both chunks share an FTS term so the MATCH returns both; only the path_prefix filter separates
    # them, so a wildcarding `_` would wrongly keep the sibling.
    db = _build([
        _chunk("doc1#a", ["Chapter A_B", "Intro"], "shared widget term", 0),
        _chunk("doc1#b", ["Chapter AXB", "Intro"], "shared widget term", 1),
    ])
    with IndexStore(db) as s:
        # Control: unfiltered, the FTS MATCH returns BOTH — so the path_prefix filter (not a
        # non-matching query) is what must exclude the sibling; guards against a vacuous pass.
        assert {h.chunk_id for h in s._match("widget")} == {"doc1#a", "doc1#b"}
        ids = {h.chunk_id for h in s._match("widget", path_prefix="Chapter A_B")}
    assert ids == {"doc1#a"}, f"_match `_` wildcarded into the sibling 'Chapter AXB': {ids}"


def test_passages_under_plain_prefix_still_matches() -> None:
    # The common (metacharacter-free) case must be unchanged: the child is still returned, and only
    # the child — escaping must not suppress a legitimate prefix match.
    db = _build([
        _chunk("doc1#a", ["Chapter One", "Intro"], "child passage", 0),
        _chunk("doc1#b", ["Chapter Two", "Intro"], "other chapter", 1),
    ])
    with IndexStore(db) as s:
        ids = {h.chunk_id for h in s.passages_under("doc1", "Chapter One")}
    assert ids == {"doc1#a"}


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
