"""Drift detection is honest about what it can and cannot see.

`index_version` converts silent omission into DETECTABLE omission and no further — detection is
not freshness, and a consumer with nothing to compare against cannot detect anything. This is the
comparison, and its two failure modes are opposite:

  * crying wolf on a clean vault, which trains its reader to ignore it (a real bug: the index and
    the walk produce paths through different code, and on macOS `/var` vs `/private/var` alone
    reported every note as simultaneously added AND removed);
  * reporting `stale: false` over a note it never actually checked, which is the overstated
    completeness this project keeps retracting.

`test_clean_vault_reports_no_drift` and `test_declared_digest_is_counted_unverifiable_not_fresh`
are those two, in that order.

Runnable with plain `python tests/test_freshness.py`; discovered by pytest if added.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import freshness  # noqa: E402
from substrate.models import Chunk, Document  # noqa: E402
from substrate.store.index_store import IndexStore  # noqa: E402

BODY = "Composition resolves the manifest and indexes the union."


def _vault() -> Path:
    root = Path(tempfile.mkdtemp()) / "demo-vault"
    root.mkdir(parents=True)
    return root


def _note(vault: Path, name: str, *, declared_sha: str | None = None) -> Path:
    front = f"---\nsource_sha256: {declared_sha}\n---\n\n" if declared_sha else ""
    p = vault / f"{name}.md"
    p.write_text(f"{front}# {name}\n\n{BODY}\n", encoding="utf-8")
    return p


def _index(paths: list[Path]) -> IndexStore:
    """An index whose documents point at those notes, digested the way the reader would."""
    store = IndexStore(str(Path(tempfile.mkdtemp()) / "index.db"))
    for p in paths:
        sha, _ = freshness._effective_sha(p)
        doc = Document(doc_id=p.stem, source_path=str(p), source_sha256=sha, source_pages=1,
                       document_class="reference-frozen", title=p.stem, status="active")
        ch = Chunk(chunk_id=f"{p.stem}#c0", doc_id=p.stem, kind="passage", text=BODY,
                   path=[p.stem], level=1, n_chars=len(BODY),
                   document_class="reference-frozen")
        # markdown_path is the DERIVED artifact — deliberately somewhere else, so a check that
        # reads it instead of source_path fails these tests rather than passing them.
        store.upsert(doc, [ch], markdown_path=f"/derived/{p.stem}/document.md",
                     markdown_mtime=0.0, markdown_sha256="d" * 64)
    return store


def test_clean_vault_reports_no_drift() -> None:
    v = _vault()
    notes = [_note(v, "a"), _note(v, "b")]
    with _index(notes) as s:
        d = freshness.drift(s, notes)
    assert d["stale"] is False, d
    assert d["checked"] == 2 and d["changed"] == [] and d["added"] == [] and d["removed"] == []


def test_unresolved_paths_do_not_read_as_added_and_removed() -> None:
    """The regression: the index stores whatever path ingest was handed and the walk produces
    whatever rglob yields. Compared unnormalized, one note appears in BOTH lists."""
    v = _vault()
    note = _note(v, "a")
    with _index([note]) as s:
        # A symlinked route to the same file — the shape macOS produces for every temp dir.
        link_dir = Path(tempfile.mkdtemp()) / "linked"
        link_dir.symlink_to(v)
        d = freshness.drift(s, [link_dir / "a.md"])
    assert d["added"] == [] and d["removed"] == [], d
    assert d["stale"] is False


def test_edited_note_is_changed() -> None:
    v = _vault()
    note = _note(v, "a")
    with _index([note]) as s:
        note.write_text("# a\n\nrewritten entirely\n", encoding="utf-8")
        d = freshness.drift(s, [note])
    assert d["stale"] is True
    assert d["changed"] == [str(note.resolve())]


def test_unindexed_note_is_added() -> None:
    """The case a caller most needs: a note the scope composes that the index does not hold looks
    exactly like a question the corpus cannot answer."""
    v = _vault()
    indexed = _note(v, "a")
    with _index([indexed]) as s:
        fresh = _note(v, "b")
        d = freshness.drift(s, [indexed, fresh])
    assert d["added"] == [str(fresh.resolve())]
    assert d["stale"] is True


def test_deleted_note_is_removed() -> None:
    v = _vault()
    note = _note(v, "a")
    with _index([note]) as s:
        d = freshness.drift(s, [])
    assert d["removed"] == [str(note.resolve())]
    assert d["stale"] is True


def test_declared_digest_is_counted_unverifiable_not_fresh() -> None:
    """A PDF-derived passage stores the PDF's digest (Doc 2 §3b), so a body edit leaves it
    unchanged. Counting it as verified would overstate what `stale: false` means."""
    v = _vault()
    note = _note(v, "a", declared_sha="b" * 64)
    with _index([note]) as s:
        note.write_text(f"---\nsource_sha256: {'b' * 64}\n---\n\n# a\n\nEDITED\n",
                        encoding="utf-8")
        d = freshness.drift(s, [note])
    assert d["unverifiable"] == 1, d
    assert d["checked"] == 0
    assert d["changed"] == [], "a declared digest cannot witness a body edit — do not claim it did"
    assert d["stale"] is False, "and do not claim staleness it cannot see either"


def test_unreadable_note_gets_its_own_bucket() -> None:
    """Indexed, composed, and unreadable now: neither fresh nor missing, so it is not silently
    counted as either."""
    v = _vault()
    note = _note(v, "a")
    with _index([note]) as s:
        note.chmod(0o000)
        try:
            d = freshness.drift(s, [note])
        finally:
            note.chmod(0o644)
    assert d["unreadable"] == [str(note.resolve())], d
    assert d["checked"] == 0
    # `stale` stays false — nothing was found to DIFFER — but `checkable` says the sweep was
    # incomplete. Reporting only the first is an affirmative all-clear over notes never examined.
    assert d["stale"] is False
    assert d["checkable"] is False


def test_a_clean_vault_is_checkable() -> None:
    """`checkable` must mean something; always-false is the same defect as always-true."""
    v = _vault()
    notes = [_note(v, "a")]
    with _index(notes) as s:
        assert freshness.drift(s, notes)["checkable"] is True


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
