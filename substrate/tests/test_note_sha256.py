"""`note_sha256`: the index records the note file's own checksum, so freshness sees every edit.

A note that DECLARES its original (a PDF-derived note names the PDF in `source_sha256`) stored that
declared checksum and nothing else. An edit to such a note was invisible: `drift` counted it
`unverifiable`, `expand` returned `stale: null`, and the agent publisher carried the edited note into
a snapshot whose contract is "only the bytes compose indexed". These tests compose a real vault and
fail on main (schema v10) in exactly those ways.

Runnable with plain `python tests/test_note_sha256.py`; discovered by pytest if added.
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import cli, freshness, scopes, vault  # noqa: E402
from substrate.store import schema  # noqa: E402
from substrate.store.index_store import IndexStore  # noqa: E402

_VAULTS = Path(__file__).resolve().parent.parent / "vaults"
_PDF_SHA = "a" * 64

# A declared `doc_id`, as the engine's own emitted notes carry: without one the id is derived from
# the file's checksum, so any edit makes a NEW document and no stale row can survive to be tested.
_DERIVED = f"""---
doc_id: demo-derived-reference
title: A derived reference
status: active
doc_type: reference
domains: [software-dev]
source_sha256: {_PDF_SHA}
---

# A derived reference

Extracted from a PDF the vault does not hold. The declared checksum names that PDF.
"""


def _world() -> tuple[Path, Path, Path, Path, Path]:
    root = Path(tempfile.mkdtemp())
    shutil.copytree(_VAULTS / "demo-vault", root / "demo-vault")
    shutil.copytree(_VAULTS / "demo-core-vault", root / "demo-core-vault")
    note = root / "demo-vault" / "03-references" / "derived.md"
    note.write_text(_DERIVED, encoding="utf-8")
    return root, note, root / "out" / "demo.db", root / "out" / "demo-index", root / "scopes.toml"


def _compose(root: Path, db: Path, ir: Path, reg: Path) -> None:
    default = scopes.engine_home
    scopes.engine_home = lambda: root
    err = io.StringIO()
    try:
        with contextlib.redirect_stdout(io.StringIO()), contextlib.redirect_stderr(err):
            rc = cli.main(["compose", str(root / "demo-vault"), "--db", str(db),
                           "--index-root", str(ir), "--registry", str(reg)])
    finally:
        scopes.engine_home = default
    assert rc == 0, err.getvalue()


def _drift(db: Path, root: Path) -> dict:
    with IndexStore(str(db), migrate=False) as s:
        return freshness.drift(s, [n.path for n in vault.resolve_scope(root / "demo-vault").notes])


def _row(db: Path, note: Path) -> dict:
    with IndexStore(str(db), migrate=False) as s:
        rows = [dict(r) for r in s.db.execute(
            "SELECT source_path, source_sha256, note_sha256 FROM documents")
            if Path(r["source_path"]).resolve() == note.resolve()]
    assert len(rows) == 1, f"{note} is not indexed exactly once"
    return rows[0]


def test_compose_stores_the_note_files_own_checksum_beside_the_declared_one() -> None:
    root, note, db, ir, reg = _world()
    _compose(root, db, ir, reg)
    row = _row(db, note)
    assert row["source_sha256"] == _PDF_SHA, "the declared original keeps its meaning"
    assert row["note_sha256"] == hashlib.sha256(note.read_bytes()).hexdigest()


def test_an_edit_to_a_derived_note_is_changed_not_unverifiable() -> None:
    root, note, db, ir, reg = _world()
    _compose(root, db, ir, reg)
    note.write_text(_DERIVED + "\nA paragraph added after compose.\n", encoding="utf-8")
    d = _drift(db, root)
    assert d["changed"] == [str(note.resolve())], d
    assert d["unverifiable"] == 0, d
    assert d["stale"] is True


def test_a_clean_composed_vault_has_nothing_unverifiable() -> None:
    root, _note, db, ir, reg = _world()
    _compose(root, db, ir, reg)
    d = _drift(db, root)
    assert d["stale"] is False and d["unverifiable"] == 0, d
    assert d["checked"] == len(vault.resolve_scope(root / "demo-vault").notes), d


def test_a_frontmatter_only_edit_clears_after_recompose() -> None:
    """The edit moves no chunk: a declared note's chunks carry the declared checksum. Unless the
    note's own checksum is in reconcile's diff key, recompose reports it `unchanged`, the stored
    `note_sha256` keeps the old value, and drift reads `changed` after every recompose."""
    root, note, db, ir, reg = _world()
    _compose(root, db, ir, reg)
    note.write_text(_DERIVED.replace("domains: [software-dev]\n",
                                     "domains: [software-dev]\ntags: [unindexed]\n"),
                    encoding="utf-8")
    assert _drift(db, root)["changed"] == [str(note.resolve())]
    _compose(root, db, ir, reg)
    d = _drift(db, root)
    assert d["stale"] is False and d["changed"] == [], d
    assert _row(db, note)["note_sha256"] == hashlib.sha256(note.read_bytes()).hexdigest()


def test_run_json_carries_note_sha256() -> None:
    root, note, db, ir, reg = _world()
    _compose(root, db, ir, reg)
    runs = [json.loads(p.read_text("utf-8")) for p in ir.glob("*/run.json")]
    derived = [r for r in runs if Path(r["source"]).name == "derived.md"]
    assert len(derived) == 1
    assert derived[0]["note_sha256"] == hashlib.sha256(note.read_bytes()).hexdigest()
    assert all(r.get("note_sha256") for r in runs), "every composed note records its checksum"


def test_schema_is_v11_and_carries_the_column() -> None:
    assert schema.SCHEMA_VERSION == 11
    root, _note, db, ir, reg = _world()
    _compose(root, db, ir, reg)
    with IndexStore(str(db), migrate=False) as s:
        cols = {r[1] for r in s.db.execute("PRAGMA table_info(documents)")}
    assert "note_sha256" in cols


def test_stale_verdict_compares_the_note_checksum_when_there_is_one() -> None:
    body = _DERIVED.encode("utf-8")
    own = hashlib.sha256(body).hexdigest()
    assert freshness.stale_verdict(body, _PDF_SHA, own) is False
    assert freshness.stale_verdict(body + b"edit", _PDF_SHA, own) is True
    # No note checksum (a row from a pre-v11 run.json): the old rule, which cannot see the edit.
    assert freshness.stale_verdict(body + b"edit", _PDF_SHA, None) is None


def test_a_legacy_run_json_without_note_sha256_is_unverifiable_not_changed() -> None:
    """`substrate index` over an out/ tree written before v11: the field is absent, so the row
    falls back to the declared checksum and is named `unverifiable` rather than guessed at."""
    root, note, db, ir, reg = _world()
    _compose(root, db, ir, reg)
    db2 = _legacy_index(root, ir)
    assert _row(db2, note)["note_sha256"] is None
    d = _drift(db2, root)
    assert d["unverifiable"] == 1 and d["stale"] is False, d



def _composed_doc_id(db: Path, note: Path) -> str:
    with IndexStore(str(db), migrate=False) as s:
        for r in s.db.execute("SELECT doc_id, source_path FROM documents"):
            if Path(r["source_path"]).resolve() == note.resolve():
                return r["doc_id"]
    raise AssertionError(f"{note} is not indexed")


def test_expand_reports_an_edited_derived_note_stale_not_null() -> None:
    from substrate.mcp import server

    root, note, db, ir, reg = _world()
    _compose(root, db, ir, reg)
    doc_id = _composed_doc_id(db, note)
    with IndexStore(str(db), migrate=False) as s:
        assert server._note_text(s, doc_id)["stale"] is False
        note.write_text(_DERIVED + "\nEdited after compose.\n", encoding="utf-8")
        assert server._note_text(s, doc_id)["stale"] is True


def test_the_agent_publisher_leaves_out_an_edited_derived_note() -> None:
    """The snapshot carries only notes whose bytes match what compose indexed. A declared
    checksum made the verdict None for a derived note, and None is falsy, so the edited note was
    carried into a file another user reads."""
    from substrate import agent

    root, note, db, ir, reg = _world()
    _compose(root, db, ir, reg)
    doc_id = _composed_doc_id(db, note)
    roots = {"demo-vault": (root / "demo-vault").resolve(),
             "demo-core-vault": (root / "demo-core-vault").resolve()}
    with IndexStore(str(db), migrate=False) as s:
        rows = agent._doc_rows(s)
    _copies, excluded = agent._read_notes(rows, roots, frozenset())
    assert doc_id not in excluded, "unedited, it is carried"
    note.write_text(_DERIVED + "\nEdited after compose.\n", encoding="utf-8")
    _copies, excluded = agent._read_notes(rows, roots, frozenset())
    assert doc_id in excluded


def _legacy_index(root: Path, ir: Path) -> Path:
    """`substrate index --migrate` over an out/ tree whose run.json predates `note_sha256`."""
    for p in ir.glob("*/run.json"):
        run = json.loads(p.read_text("utf-8"))
        run.pop("note_sha256", None)
        p.write_text(json.dumps(run), "utf-8")
    db = root / "out" / "legacy.db"
    with contextlib.redirect_stdout(io.StringIO()):
        assert cli.main(["index", "--out-root", str(ir), "--db", str(db), "--migrate"]) == 0
    return db


def test_the_agent_publisher_leaves_out_a_derived_note_it_cannot_check() -> None:
    """A row with no `note_sha256` and a declared checksum has verdict None. Carried on a falsy
    verdict, an edited PDF-derived note still reached the snapshot by this route."""
    from substrate import agent

    root, note, _db, ir, reg = _world()
    _compose(root, _db, ir, reg)
    db = _legacy_index(root, ir)
    doc_id = _composed_doc_id(db, note)
    roots = {"demo-vault": (root / "demo-vault").resolve(),
             "demo-core-vault": (root / "demo-core-vault").resolve()}
    with IndexStore(str(db), migrate=False) as s:
        rows = agent._doc_rows(s)
    copies, excluded = agent._read_notes(rows, roots, frozenset())
    assert doc_id in excluded
    assert copies and all(c.stale == 0 for c in copies), "what is carried is a verified match"


def test_a_malformed_note_sha256_in_run_json_falls_back_rather_than_crashing() -> None:
    root, note, _db, ir, reg = _world()
    _compose(root, _db, ir, reg)
    for p in ir.glob("*/run.json"):
        run = json.loads(p.read_text("utf-8"))
        run["note_sha256"] = 123 if "derived" in run["source"] else ["x"]
        p.write_text(json.dumps(run), "utf-8")
    db = root / "out" / "malformed.db"
    with contextlib.redirect_stdout(io.StringIO()):
        assert cli.main(["index", "--out-root", str(ir), "--db", str(db), "--migrate"]) == 0
    assert _row(db, note)["note_sha256"] is None


def test_an_origin_naming_a_file_without_its_checksum_is_refused() -> None:
    from substrate.markdown.ingest import ingest_markdown
    from substrate.models import SourceOrigin

    root = Path(tempfile.mkdtemp())
    src = root / "converted.md"
    src.write_text("# Converted\n\nA body converted from somewhere else.\n", encoding="utf-8")
    origin = SourceOrigin(source_format="docx", path=str(root / "real.docx"), sha256=None)
    try:
        ingest_markdown(src, root / "out", origin=origin)
    except ValueError as e:
        assert "checksum" in str(e)
    else:
        raise AssertionError("an origin path with no checksum must not index an uncheckable row")


def test_recomposing_over_a_pre_v11_out_tree_gives_every_row_its_checksum() -> None:
    """The upgrade path: an index rebuilt from run.json written before the field exists has NULL
    `note_sha256` everywhere. The next compose over that same index root must fill every row, or
    PDF-derived notes stay `unverifiable` and out of agent snapshots for good."""
    root, note, _db, ir, reg = _world()
    _compose(root, _db, ir, reg)
    db = _legacy_index(root, ir)
    with IndexStore(str(db), migrate=False) as s:
        assert s.db.execute("SELECT COUNT(*) FROM documents WHERE note_sha256 IS NOT NULL"
                            ).fetchone()[0] == 0
    _compose(root, db, ir, root / "legacy-scopes.toml")
    with IndexStore(str(db), migrate=False) as s:
        missing = s.db.execute("SELECT COUNT(*) FROM documents WHERE note_sha256 IS NULL"
                               ).fetchone()[0]
    assert missing == 0
    d = _drift(db, root)
    assert d["unverifiable"] == 0 and d["stale"] is False, d

if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print(f"ok  {name}")
