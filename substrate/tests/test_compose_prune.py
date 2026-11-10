"""A deleted note's ingest folder is removed by the next compose, and nothing else is.

A compose without `--clean` used to leave a deleted note's folder, so `assert_composed` refused
the scope and every refresh pass after the deletion recorded `compose_failed`. Compose now prunes
exactly those folders (`substrate/prune.py`), refuses to prune a vault that looks missing rather
than emptied by hand, and still refuses a folder it cannot attribute.
"""

from __future__ import annotations

import shutil
import sqlite3
import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

from substrate import refresh  # noqa: E402

DEMO = ROOT / "vaults"
NOTE = Path("04-synthesis") / "engine-boundary-current.md"
DOC_ID = "engine-boundary-current"


@pytest.fixture
def composed(tmp_path: Path) -> dict:
    """The demo vaults copied out, registered and composed once by a refresh pass."""
    vaults = tmp_path / "vaults"
    shutil.copytree(DEMO / "demo-vault", vaults / "demo-vault")
    shutil.copytree(DEMO / "demo-core-vault", vaults / "demo-core-vault")
    demo = {"vault": vaults / "demo-vault", "core": vaults / "demo-core-vault",
            "registry": tmp_path / "scopes.toml", "db": tmp_path / "index" / "demo.db",
            "index_root": tmp_path / "index" / "demo", "aside": tmp_path / "aside"}
    reg = subprocess.run([sys.executable, "-m", "substrate.cli", "register", str(demo["vault"]),
                          "--index-root", str(demo["index_root"]), "--db", str(demo["db"]),
                          "--registry", str(demo["registry"])],
                         cwd=ROOT, capture_output=True, text=True, timeout=300)
    assert reg.returncode == 0, reg.stderr
    [first] = refresh.run_pass(demo["registry"], log=lambda _: None)
    assert first.outcome in ("refreshed", "embed_failed"), first
    demo["aside"].mkdir()
    return demo


def _pass(demo: dict) -> tuple[refresh.ScopeResult, str]:
    said: list[str] = []
    [result] = refresh.run_pass(demo["registry"], log=said.append)
    return result, "\n".join(said)


def _folders(demo: dict) -> dict[str, bytes]:
    """Every file under the index root, by its path there, with its bytes."""
    return {str(p.relative_to(demo["index_root"])): p.read_bytes()
            for p in sorted(demo["index_root"].rglob("*")) if p.is_file()}


def _vault_files(root: Path) -> dict[str, bytes]:
    return {str(p.relative_to(root)): p.read_bytes() for p in sorted(root.rglob("*")) if p.is_file()}


def _indexed(demo: dict) -> set[str]:
    with sqlite3.connect(demo["db"]) as db:
        return {r[0] for r in db.execute("SELECT doc_id FROM documents")}


def _folder_of(demo: dict, stem: str) -> Path:
    [folder] = [p for p in demo["index_root"].iterdir() if p.name.startswith(f"demo-vault__{stem}__")]
    return folder


def test_a_deleted_note_is_pruned_and_stops_answering(composed) -> None:
    demo = composed
    folder = _folder_of(demo, NOTE.stem)
    assert DOC_ID in _indexed(demo)
    shutil.move(demo["vault"] / NOTE, demo["aside"] / NOTE.name)
    vault_before = _vault_files(demo["vault"]), _vault_files(demo["core"])

    result, said = _pass(demo)

    assert result.outcome in ("refreshed", "embed_failed"), result
    assert not folder.exists()
    assert DOC_ID not in _indexed(demo)
    line = f"pruned: demo-vault/{NOTE.as_posix()}  (note deleted; removed {folder.name})"
    assert line in result.detail and line in said, said
    assert (_vault_files(demo["vault"]), _vault_files(demo["core"])) == vault_before


def test_a_finder_file_in_the_folder_does_not_stop_the_prune(composed) -> None:
    demo = composed
    folder = _folder_of(demo, NOTE.stem)
    (folder / ".DS_Store").write_bytes(b"\0")
    shutil.move(demo["vault"] / NOTE, demo["aside"] / NOTE.name)
    result, _ = _pass(demo)
    assert result.outcome in ("refreshed", "embed_failed"), result
    assert not folder.exists()


def test_a_vault_root_gone_missing_refuses_the_pass_and_prunes_nothing(composed) -> None:
    demo = composed
    before, indexed = _folders(demo), _indexed(demo)
    shutil.move(demo["core"], demo["aside"] / "demo-core-vault")

    result, _ = _pass(demo)

    assert result.outcome == "compose_failed", result
    assert _folders(demo) == before and _indexed(demo) == indexed


def _empty(vault: Path, aside: Path) -> None:
    """Every note of `vault` moved aside; its manifest, a `.toml`, stays."""
    for note in list(vault.rglob("*.md")):
        target = aside / vault.name / note.relative_to(vault)
        target.parent.mkdir(parents=True, exist_ok=True)
        shutil.move(note, target)


def test_a_marked_vault_with_its_last_note_removed_is_pruned_to_zero(composed) -> None:
    """Its manifest says it is still a vault, emptied rather than unmounted."""
    demo = composed
    project = {p.name for p in demo["index_root"].iterdir() if p.name.startswith("demo-vault__")}
    assert project and (demo["vault"] / ".substrate.toml").is_file()
    _empty(demo["vault"], demo["aside"])

    result, said = _pass(demo)

    assert result.outcome in ("refreshed", "embed_failed"), result
    assert not project & {p.name for p in demo["index_root"].iterdir()}
    assert DOC_ID not in _indexed(demo)
    line = f"pruned: vault 'demo-vault' now composes 0 notes; removed {len(project)} ingest folder(s)"
    assert line in result.detail and line in said, said


def test_a_vault_without_its_marker_that_composed_zero_notes_refuses(composed) -> None:
    """A root vault carries no manifest, so an empty one cannot be told from a folder whose sync
    or mount left it empty: it is refused, and nothing is pruned."""
    demo = composed
    before, indexed = _folders(demo), _indexed(demo)
    assert not (demo["core"] / ".substrate.toml").exists()
    _empty(demo["core"], demo["aside"])

    result, _ = _pass(demo)

    assert result.outcome == "compose_failed", result
    assert "FATAL (prune)" in result.detail and "'demo-core-vault'" in result.detail, result.detail
    assert "composed zero notes this run" in result.detail, result.detail
    assert "carries no .substrate.toml" in result.detail, result.detail
    assert _folders(demo) == before and _indexed(demo) == indexed


@pytest.mark.parametrize("unattributable", ["renamed", "extra file"])
def test_a_folder_that_cannot_be_attributed_is_still_refused(composed, unattributable) -> None:
    demo = composed
    folder = _folder_of(demo, NOTE.stem)
    if unattributable == "renamed":
        # Not the name compose gives the note its run.json names.
        planted = folder.with_name(folder.name[:-8] + "00000000")
        folder.rename(planted)
    else:
        planted = folder
        (planted / "notes.txt").write_text("not ingest output\n")
    shutil.move(demo["vault"] / NOTE, demo["aside"] / NOTE.name)

    result, _ = _pass(demo)

    assert result.outcome == "compose_failed", result
    assert "did not ingest" in result.detail, result.detail
    assert planted.is_dir() and "pruned:" not in result.detail


def test_a_note_that_cannot_be_read_is_not_pruned(composed) -> None:
    """Unreadable is not deleted: discovery skips a folder it cannot read without a word, so its
    notes' folders are kept and the scope is refused, loudly, as before."""
    demo = composed
    folder = _folder_of(demo, NOTE.stem)
    locked = demo["vault"] / NOTE.parent
    locked.chmod(0)
    try:
        result, _ = _pass(demo)
    finally:
        locked.chmod(0o755)
    assert result.outcome == "compose_failed", result
    assert folder.is_dir() and "pruned:" not in result.detail
    assert DOC_ID in _indexed(demo)


def test_a_note_renamed_by_case_alone_is_pruned(composed) -> None:
    """On a volume that folds case the old spelling still resolves; its folder lists only the new."""
    demo = composed
    folder = _folder_of(demo, NOTE.stem)
    note = demo["vault"] / NOTE
    note.rename(note.with_name(NOTE.name.upper().replace(".MD", ".md")))
    result, _ = _pass(demo)
    assert result.outcome in ("refreshed", "embed_failed"), result
    assert not folder.exists() and f"removed {folder.name}" in result.detail


def test_removal_does_not_follow_a_folder_swapped_for_a_link(tmp_path) -> None:
    from substrate import prune

    target = tmp_path / "a-vault-folder"
    target.mkdir()
    (target / "document.md").write_text("a human wrote this\n")
    link = tmp_path / "index" / "v__note__deadbeef"
    link.parent.mkdir()
    link.symlink_to(target)
    with pytest.raises(OSError):
        prune.remove([prune.Stale("v", Path("note.md"), link)], lambda _: None)
    assert (target / "document.md").read_text() == "a human wrote this\n"
