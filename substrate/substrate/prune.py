"""The ingest folders of notes that have been deleted, found and removed by `compose`.

A compose without `--clean` re-ingests every note into its own folder under the index root and
leaves the rest. A deleted note's folder therefore stayed, and `assert_composed` refused the scope
for the stale document it held, so a refresh pass froze the scope until someone ran `--clean` by
hand. Deleting a note is ordinary vault use, so compose now removes those folders itself.

What it removes is narrow, and each condition is checked rather than assumed:

  * **Derived data only.** A folder under the index root, holding only the files ingest writes,
    whose name is the one compose gives the note its `run.json` names (`ingest_dir_name`), that
    note inside one of the scope's vaults, and that note known to be gone: "no such file", never a
    note that cannot be read. Nothing inside a vault is touched.
  * **A missing vault is not a deleted note.** When a vault this would prune is missing or
    unreadable, nothing is pruned and the compose fails, naming the vault: an unmounted drive must
    not empty its index. A vault that composed zero notes is pruned down to zero only while it
    still carries its manifest (`.substrate.toml`, which every project vault has), and that is said
    in its own line; without one (a root vault, which has none) it is refused the same way.
  * **Anything else is left,** so `assert_composed` refuses it as before: a folder that cannot be
    attributed, or the folder of a note that still exists but is no longer composed.

Every removed folder is printed, as it goes, on a line starting `pruned:`, which a refresh pass
carries into its report, whatever the pass then records.
"""

from __future__ import annotations

import contextlib
import json
import os
from collections.abc import Callable, Iterable
from pathlib import Path
from typing import NamedTuple

from substrate import private

# The marker each removed folder's line starts with, in compose's output and a pass's report.
PRUNED = "pruned:"


class PruneError(RuntimeError):
    """A vault whose notes would be pruned is missing, unreadable or empty: nothing was removed."""


class Stale(NamedTuple):
    vault: str
    note: Path        # the deleted note, relative to its vault
    folder: Path      # its ingest folder under the index root


def _source(folder: Path) -> Path | None:
    """The note `folder` was ingested from, when the folder holds only ingest's files (and hidden
    ones, a `.DS_Store` a Finder window left, as `private` allows) and says."""
    try:
        entries = list(os.scandir(folder))
    except OSError:
        return None
    if ("run.json" not in {e.name for e in entries}
            or any(not e.is_file(follow_symlinks=False)
                   or (e.name not in private.INGEST_FILES and not e.name.startswith("."))
                   for e in entries)):
        return None
    try:
        source = json.loads((folder / "run.json").read_text(encoding="utf-8")).get("source")
    except (OSError, ValueError, AttributeError):
        return None
    return Path(source) if isinstance(source, str) and os.path.isabs(source) else None


def stale(index_root: Path, vaults: Iterable, produced: set[str]) -> list[Stale]:
    """Each folder under `index_root`, not among `produced`, that holds a deleted note of one of
    `vaults` (each with `.name` and `.path`)."""
    vaults = list(vaults)
    found: list[Stale] = []
    try:
        children = sorted(os.scandir(index_root), key=lambda e: e.name)
    except OSError:
        return found
    for entry in children:
        if entry.name in produced or not private.INGEST_DIR.fullmatch(entry.name):
            continue
        if not entry.is_dir(follow_symlinks=False):
            continue
        folder = Path(entry.path)
        source = _source(folder)
        if source is None:
            continue
        for v in vaults:
            if (source.is_relative_to(v.path)
                    and entry.name == private.ingest_dir_name(v.name, source)):
                if _deleted(source, v.path):
                    found.append(Stale(v.name, source.relative_to(v.path), folder))
                break
    return found


def _deleted(note: Path, root: Path) -> bool:
    """Whether `note`, inside vault `root`, is known to be gone. Only "no such file" counts: a note
    that cannot be looked at is unknown, and discovery skips a folder it cannot read without a word,
    so every folder from the note up to the vault root must be readable where it exists. A note
    whose spelling changed by case alone is gone too, on a volume that folds case: its old spelling
    still resolves, but its folder lists only the new one."""
    for d in (note.parent, *note.parent.parents):
        try:
            os.lstat(d)
        except FileNotFoundError:
            pass
        except OSError:
            return False
        else:
            if not os.access(d, os.R_OK | os.X_OK):
                return False
        if d == root:
            break
    try:
        os.lstat(note)
    except (FileNotFoundError, NotADirectoryError):
        return True
    except OSError:
        return False
    try:
        return note.name not in os.listdir(note.parent)
    except OSError:
        return False


def refuse_missing(found: list[Stale], vaults: Iterable, composed: dict[str, int]) -> list[str]:
    """Raise PruneError when a vault `found` would prune is missing or unreadable, or composed no
    notes this run without the manifest that marks it a vault (`composed` counts this run's notes by
    vault name). Returns the vaults that are pruned down to zero notes, which their manifest says
    are real vaults emptied rather than an unmounted folder."""
    from substrate.vault import MANIFEST  # lazy: keeps this module free of the manifest reader

    paths = {v.name: v.path for v in vaults}
    emptied: list[str] = []
    for name in sorted({s.vault for s in found}):
        held = sum(1 for s in found if s.vault == name)
        root = paths[name]
        if not root.is_dir():
            why = f"its root {root} is missing"
        elif not os.access(root, os.R_OK | os.X_OK):
            why = f"its root {root} cannot be read"
        elif composed.get(name):
            continue
        elif (root / MANIFEST).is_file():
            emptied.append(name)
            continue
        else:
            why = (f"it composed zero notes this run, where the index holds {held} of its notes, "
                   f"and carries no {MANIFEST} to say it is still a vault rather than an empty "
                   f"folder")
        raise PruneError(
            f"vault {name!r}: {why}. That looks like a vault that is unmounted, unsynced or moved, "
            f"not {held} deleted note(s), so none of its notes were pruned and the index was not "
            f"rebuilt. Bring the vault back and the next compose prunes only the notes it no "
            f"longer has; if it was emptied on purpose, compose once with --clean.")
    return emptied


def emptied_line(vault: str, found: list[Stale]) -> str:
    removed = sum(1 for s in found if s.vault == vault)
    return f"{PRUNED} vault {vault!r} now composes 0 notes; removed {removed} ingest folder(s)"


def remove(found: list[Stale], removed: Callable[[Stale], None]) -> None:
    """Remove each folder, calling `removed` as each one goes: its files one by one, then the
    folder, and nothing else. Through the folder's own descriptor, opened without following a link,
    so a folder swapped for a link after `stale` looked at it is refused rather than followed.
    `run.json` goes last, so a folder a failure leaves half removed can still be attributed."""
    for s in found:
        fd = os.open(s.folder, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW)
        try:
            hidden = [n for n in os.listdir(fd) if n.startswith(".")]
            for name in (*hidden, *sorted(private.INGEST_FILES - {"run.json"}), "run.json"):
                with contextlib.suppress(FileNotFoundError):
                    os.unlink(name, dir_fd=fd)
        finally:
            os.close(fd)
        os.rmdir(s.folder)
        removed(s)


def line(s: Stale) -> str:
    return f"{PRUNED} {s.vault}/{s.note.as_posix()}  (note deleted; removed {s.folder.name})"
