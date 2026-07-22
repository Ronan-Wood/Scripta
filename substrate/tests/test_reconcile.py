"""Regression tests for store.reconcile — the index-from-disk sync.

Runnable with plain `python tests/test_reconcile.py` (no pytest required) and discovered by
pytest if it is ever added. Each test builds an isolated temp out/ dir + SQLite DB.

These pin the two bugs the 2026-07-22 audit found in reconcile:
  * H2 — the diff key must cover chunks.jsonl + run.json's class block, NOT the markdown alone,
    so a `rechunk` (new chunks.jsonl, byte-identical document.md) re-indexes instead of no-op'ing.
  * the removal sweep must key on doc_id (like the diff-check), so a renamed out/ dir or a
    deleted dup-doc_id twin is not reported `unchanged` and silently deleted in the same pass.
"""

from __future__ import annotations

import json
import shutil
import sys
import tempfile
from pathlib import Path

# The package is not installed (`[tool.uv] package = false`), so put the project root on the
# path — makes this runnable both as a plain script and under pytest, from any working dir.
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.store.index_store import IndexStore  # noqa: E402
from substrate.store.reconcile import reconcile  # noqa: E402


def _chunk(text: str, *, doc_id: str = "doc1") -> dict:
    return {
        "chunk_id": f"{doc_id}#c0", "doc_id": doc_id, "kind": "passage", "text": text,
        "path": ["Root", "Section"], "level": 2, "block_ids": ["b1"],
        "char_start": 0, "char_end": len(text), "page_start": 1, "page_end": 1,
        "n_chars": len(text), "part_index": None, "part_count": None, "oversize": False,
        "prev_id": None, "next_id": None, "document_class": "reference-frozen",
        "version": None, "source_sha256": "abc", "page_label_offset": None,
    }


def _write(d: Path, text: str = "orig", *, title: str = "My Doc", doc_id: str = "doc1",
           elapsed: float = 1.0) -> None:
    """Write one ingested output directory (document.md never changes across calls here)."""
    d.mkdir(parents=True, exist_ok=True)
    (d / "document.md").write_text("# My Doc\n\nbody\n")
    (d / "chunks.jsonl").write_text(json.dumps(_chunk(text, doc_id=doc_id)) + "\n")
    (d / "run.json").write_text(json.dumps({
        "doc_id": doc_id, "source": "/x.pdf", "source_sha256": "abc", "pages": 9,
        "class": {"document_class": "reference-frozen", "title": title,
                  "version": None, "version_date": None},
        "extract": {"extractor": "docling"}, "coverage": 0.97, "elapsed_s": elapsed,
    }))


def _fresh() -> tuple[Path, str]:
    tmp = Path(tempfile.mkdtemp())
    return tmp / "out", str(tmp / "index.db")


def test_add_then_unchanged() -> None:
    out, db = _fresh()
    _write(out / "doc1")
    with IndexStore(db) as s:
        assert reconcile(s, out).added == ["doc1"]
    with IndexStore(db) as s:
        assert reconcile(s, out).unchanged == ["doc1"]


def test_rechunk_reindexes() -> None:
    """A rechunk rewrites chunks.jsonl while document.md is byte-identical — must re-index."""
    out, db = _fresh()
    _write(out / "doc1", "before")
    with IndexStore(db) as s:
        reconcile(s, out)
    _write(out / "doc1", "after rechunk")            # same document.md, new chunk text
    with IndexStore(db) as s:
        rep = reconcile(s, out)
        assert rep.updated == ["doc1"] and rep.unchanged == []
        assert "after rechunk" in s.chunk("doc1#c0").text


def test_reclassification_reindexes() -> None:
    """A hand-edit to run.json's class block (e.g. fixing a title) must re-index."""
    out, db = _fresh()
    _write(out / "doc1", "x", title="Old")
    with IndexStore(db) as s:
        reconcile(s, out)
    _write(out / "doc1", "x", title="New")           # same md + chunks, new class title
    with IndexStore(db) as s:
        assert reconcile(s, out).updated == ["doc1"]
        assert s.documents()[0]["title"] == "New"


def test_timing_fields_excluded() -> None:
    """run.json timing fields (elapsed_s) must not trigger a spurious re-index."""
    out, db = _fresh()
    _write(out / "doc1", "x", elapsed=1.0)
    with IndexStore(db) as s:
        reconcile(s, out)
    _write(out / "doc1", "x", elapsed=999.0)          # only elapsed_s changed
    with IndexStore(db) as s:
        assert reconcile(s, out).unchanged == ["doc1"]


def test_renamed_dir_is_not_deleted() -> None:
    """Renaming an out/ dir (same doc_id, identical content) must NOT drop the doc."""
    out, db = _fresh()
    _write(out / "dirA", "x")
    with IndexStore(db) as s:
        reconcile(s, out)
    shutil.move(str(out / "dirA"), str(out / "dirB"))
    with IndexStore(db) as s:
        rep = reconcile(s, out)
        assert rep.removed == [] and rep.unchanged == ["doc1"]
        assert len(s.documents()) == 1 and s.chunk("doc1#c0") is not None


def test_dup_doc_id_twin_survives_when_one_deleted() -> None:
    """Two dirs share a doc_id; deleting one must not sweep the surviving twin."""
    out, db = _fresh()
    _write(out / "dirA", "x")
    _write(out / "dirB", "x")                          # same doc_id, identical content
    with IndexStore(db) as s:
        reconcile(s, out)
    shutil.rmtree(out / "dirA")
    with IndexStore(db) as s:
        rep = reconcile(s, out)
        assert rep.removed == []
        assert len(s.documents()) == 1 and s.chunk("doc1#c0") is not None


def test_removed_from_disk_is_removed() -> None:
    """A doc whose out/ dir is gone must be removed from the index and its stage_ledger."""
    out, db = _fresh()
    _write(out / "doc1", "x")
    with IndexStore(db) as s:
        reconcile(s, out)
    shutil.rmtree(out / "doc1")
    with IndexStore(db) as s:
        rep = reconcile(s, out)
        assert rep.removed == ["doc1"]
        assert len(s.documents()) == 0
        assert s.db.execute("SELECT COUNT(*) FROM stage_ledger").fetchone()[0] == 0


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
