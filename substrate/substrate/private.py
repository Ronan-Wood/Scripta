"""What the engine writes is readable by the operator's uid and no other.

`~` on macOS is 0750 group staff, and every local account is in staff. So a 0644 index inside a
0755 directory under `~` is readable by any other user on the machine — `sqlite3 acme.db 'select
text from chunks'` with no engine in the way. That undoes whatever the engine's transport and an
agent account's scope restriction check, because neither is in the path.

Three pieces, because no one of them is enough:

  * `restricted()` — the umask every entry point runs under, so whatever the process creates is
    0600 or 0700.
  * `seal()` — for what a writer already owns. A umask never reaches an existing file: SQLite
    reopens a database at its old mode and gives `-wal`/`-shm` the database's mode, and compose
    overwrites each note's ingest files in place. Without this, an index first built under 0644
    stays 0644 for as long as it exists.
  * `exposed()` — what a READER reports and does not repair. A loose index is a leak that has
    already happened; refusing to serve it would not undo the leak, only stop answering until the
    next compose, which is what seals it.
"""

from __future__ import annotations

import contextlib
import os
import stat
from collections.abc import Iterable, Iterator
from pathlib import Path

# Group and other, every bit. Execute counts too: on a directory it is traversal.
OPEN = 0o077

# macOS has lchmod; Linux, where CI runs the suite, may not. The walk below never hands a symlink to
# chmod, so following is only reachable through a link swapped in between the lstat and the chmod.
_NOFOLLOW = os.chmod in os.supports_follow_symlinks


@contextlib.contextmanager
def restricted() -> Iterator[None]:
    """Run the body under umask 077. The previous mask comes back on exit, which matters only to a
    caller that is not a whole process — a test driving `main()` in-process."""
    previous = os.umask(OPEN)
    try:
        yield
    finally:
        os.umask(previous)


def sqlite_family(db: Path) -> list[Path]:
    """The database and the side files SQLite keeps beside it, each of which holds pages of it."""
    return [db, *(db.with_name(db.name + s) for s in ("-wal", "-shm", "-journal"))]


def index_paths(db: Path, index_root: Path | None) -> list[Path]:
    """Everything one composed scope's text lives in."""
    return sqlite_family(db) + ([index_root] if index_root is not None else [])


def _entries(root: Path) -> Iterator[tuple[Path, os.stat_result | OSError]]:
    """`root` and, for a directory, everything under it, each with its stat or the error that
    stopped one.

    The ROOT is followed: compose writes through a symlinked `--index-root` or `--db`, so the
    target is the index and skipping it would report a loose index as clean. Links INSIDE the tree
    are never followed and never yielded: a link's own mode protects nothing, and what it points at
    is not this tree's.

    An error is yielded, never raised. These walks run in a server's startup, in every `status`,
    and in compose; an unreadable directory must cost a warning, not the engine. A path that
    VANISHED is not an error: a compose rewriting the tree under a concurrent `status` removes
    entries mid-walk, and reporting those would call a sealed scope exposed.
    """
    target = Path(os.path.realpath(root))
    try:
        st = os.stat(target)
    except FileNotFoundError:
        return
    except OSError as e:
        yield target, e
        return
    yield target, st
    if not stat.S_ISDIR(st.st_mode):
        return
    errors: list[OSError] = []

    def record(e: OSError) -> None:
        if not isinstance(e, FileNotFoundError):
            errors.append(e)

    for dirpath, dirnames, filenames in os.walk(target, followlinks=False, onerror=record):
        for name in (*dirnames, *filenames):
            path = Path(dirpath, name)
            try:
                st = os.lstat(path)
            except FileNotFoundError:
                continue
            except OSError as e:
                yield path, e
                continue
            if not stat.S_ISLNK(st.st_mode):
                yield path, st
        while errors:
            e = errors.pop()
            yield Path(e.filename or dirpath), e
    for e in errors:
        yield Path(e.filename or target), e


def seal(roots: Iterable[Path]) -> list[str]:
    """Strip group and other bits from each root and everything under it. Only ever tightens.

    Returns one line per path that could not be checked or tightened. A failure is the caller's to
    report and not to hide: an index left readable after a run that said nothing would be the leak
    this module exists to close, with a green run over it.
    """
    failed: list[str] = []
    for root in roots:
        for path, st in _entries(root):
            if isinstance(st, OSError):
                failed.append(f"{path}: {st.strerror or st}")
                continue
            mode = stat.S_IMODE(st.st_mode)
            if not mode & OPEN:
                continue
            try:
                os.chmod(path, mode & ~OPEN, follow_symlinks=not _NOFOLLOW)
            except FileNotFoundError:
                continue  # removed since the walk listed it: nothing left to expose
            except OSError as e:
                failed.append(f"{path}: {e.strerror or e}")
    return failed


def _loose(st: os.stat_result | OSError) -> bool:
    # What cannot be checked is not reported as safe.
    return isinstance(st, OSError) or bool(stat.S_IMODE(st.st_mode) & OPEN)


def exposed(roots: Iterable[Path]) -> list[str]:
    """Each root that is, or holds, anything another uid could read, list or traverse — or that
    could not be fully checked, since an unverified index is not a safe one.

    Reported by root rather than by file: a scope composed before this module existed has every
    one of its thousands of ingest files loose, and the actionable fact is which tree to seal.
    """
    return [str(root) for root in roots if any(_loose(st) for _, st in _entries(root))]
