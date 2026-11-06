"""The originals behind derived notes, in an engine-managed, content-addressed store.

Doc 2 §3b keeps raw by default because the pipeline improves and markdown is lossy, but until this
store raw was only "somewhere": `source_path` records where a file sat at ingest, and Scripta deletes
its staging run after promote. This store is the somewhere. The design is `source-blob-store-proposal`
in the scripta vault; the points it leaves to the implementation are settled here and named where
they are.

| aspect | here |
|---|---|
| layout | `<root>/sha256/<ab>/<checksum>`, one fan-out level. `<root>/tmp/` stages writes; `<root>/tombstones/<checksum>` records a `forget`; `<root>/.lock` serializes writers |
| key | SHA-256 of the original's bytes, the same value a derived note declares as `source_sha256` |
| contents | bytes only. Name, media type and origin live in the note's frontmatter |
| privacy | every directory 0700, every blob 0400, created explicitly (`~/.substrate` is 0755, so nothing is inherited); every store entry owned by this user and carrying no extended ACL, since an inherited ACE grants what the mode bits deny |
| location | `[blobs] path` in `~/.substrate/config.toml`, else `~/.substrate/blobs`. NOT `scopes.toml`, which every compose regenerates and whose header calls it safe to delete — a setting there would be erased, and deleting the file would silently point the store elsewhere |
| sync folders | refused, by folder identity and by the file-provider and iCloud Desktop & Documents markers rather than by spelling. A store a sync client reaches uploads plaintext originals, and can evict a blob into a hang |

One word per state, and it is the proposal's wire vocabulary: `stored`, `missing`, `discarded` (a
`forget` tombstone). A blob is never served without its checksum being re-verified (`verified`).
Nothing here deletes a blob except `forget`, which tombstones it first, and `remove`, which only
`substrate blobs gc` calls, plan-then-confirm, under the store's exclusive lock.
"""

from __future__ import annotations

import contextlib
import ctypes
import ctypes.util
import errno
import fcntl
import hashlib
import json
import os
import secrets
import stat
import sys
import tomllib
from collections.abc import Iterator
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

from substrate import private, scopes
from substrate.extract.base import sha256_file
from substrate.markdown.reader import _SHA256 as CHECKSUM

CONFIG_NAME = "config.toml"
_DIR_MODE = 0o700
_BLOB_MODE = 0o400
# Written into a store when the engine creates or takes over its folder. It, not the presence of a
# `tmp/` that any project folder may have, is what makes an existing folder a store.
MARKER = ".substrate-blob-store"
LEDGER = "vaults.seen"
_LAYOUT = frozenset({"sha256", "tmp", "tombstones", ".lock", MARKER, LEDGER})
# What Finder writes into any folder it shows. Neither makes a folder someone else's, and refusing
# over one would stop every ingest the first time the operator looked inside the store.
_FINDER = frozenset({".DS_Store", ".localized", "Icon\r"})
# Set on a folder a file provider (OneDrive, Dropbox, iCloud Drive) owns, and on ~/Desktop and
# ~/Documents when iCloud "Desktop & Documents Folders" syncs them in place.
_SYNC_XATTRS = ("com.apple.file-provider-domain-id", "com.apple.icloud.desktop")


class BlobError(Exception):
    """The store could not do what was asked. Nothing partial is left visible."""


class StoreConfigError(BlobError):
    """The store's location cannot be used."""


class BlobCorrupt(BlobError):
    """A stored blob's bytes no longer hash to its name. It is never served."""


def config_path() -> Path:
    """The engine's own settings file. Read, never written: the operator owns it."""
    return scopes.engine_home() / CONFIG_NAME


def default_root() -> Path:
    return scopes.engine_home() / "blobs"


# ---------------------------------------------------------------- macOS metadata, via libc

_LIBC = ctypes.CDLL(ctypes.util.find_library("c"), use_errno=True) if sys.platform == "darwin" \
    else None
if _LIBC is not None:
    _LIBC.getxattr.restype = ctypes.c_ssize_t
    _LIBC.getxattr.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_void_p, ctypes.c_size_t,
                               ctypes.c_uint32, ctypes.c_int]
    _LIBC.acl_get_fd_np.restype = ctypes.c_void_p
    _LIBC.acl_get_fd_np.argtypes = [ctypes.c_int, ctypes.c_int]
    _LIBC.acl_get_entry.argtypes = [ctypes.c_void_p, ctypes.c_int, ctypes.POINTER(ctypes.c_void_p)]
    _LIBC.acl_free.argtypes = [ctypes.c_void_p]
_ACL_TYPE_EXTENDED = 0x00000100
_ACL_FIRST_ENTRY = 0
_ENOATTR = 93


def _has_xattr(path: Path, name: str) -> bool:
    """Raises OSError when the attribute cannot be read at all (EPERM under TCC)."""
    if _LIBC is not None:
        n = _LIBC.getxattr(os.fsencode(path), name.encode(), None, 0, 0, 0)
        if n >= 0:
            return True
        err = ctypes.get_errno()
        if err in (_ENOATTR, errno.ENOTSUP):
            return False
        raise OSError(err, os.strerror(err), str(path))
    if hasattr(os, "getxattr"):
        try:
            os.getxattr(path, name)
        except OSError as e:
            if e.errno in (errno.ENODATA, errno.ENOTSUP, getattr(errno, "ENOATTR", -1)):
                return False
            raise
        return True
    return False


def _has_acl(fd: int) -> bool:
    """Whether the open file carries an extended ACL with at least one entry. Mode bits say 0400;
    an inherited `everyone allow read` entry says otherwise, and `stat` never shows it."""
    if _LIBC is None:
        return False
    acl = _LIBC.acl_get_fd_np(fd, _ACL_TYPE_EXTENDED)
    if not acl:
        return False
    try:
        entry = ctypes.c_void_p()
        return _LIBC.acl_get_entry(acl, _ACL_FIRST_ENTRY, ctypes.byref(entry)) == 0
    finally:
        _LIBC.acl_free(acl)


# ---------------------------------------------------------------- location

def _sync_roots() -> set[tuple[int, int]]:
    """The folders sync clients upload from, by IDENTITY: APFS is case-insensitive, so a spelling
    comparison passes `~/library/cloudstorage/...` straight through."""
    home = Path.home()
    candidates = [home / "Library" / "CloudStorage", home / "Library" / "Mobile Documents"]
    with contextlib.suppress(OSError):
        candidates += [p for p in home.iterdir() if p.name.lower().startswith("onedrive")]
    out = set()
    for p in candidates:
        with contextlib.suppress(OSError):
            st = os.stat(p)
            out.add((st.st_dev, st.st_ino))
    return out


def _refuse_sync_folder(path: Path) -> None:
    roots = _sync_roots()
    real = Path(os.path.realpath(path))
    for folder in (real, *real.parents):
        try:
            st = os.stat(folder)
            synced = (st.st_dev, st.st_ino) in roots or any(
                _has_xattr(folder, name) for name in _SYNC_XATTRS)
        except FileNotFoundError:
            continue
        except OSError as e:
            raise StoreConfigError(
                f"the blob store {path} is under {folder}, which cannot be inspected "
                f"({e.strerror or e}), so whether a sync client uploads it cannot be ruled out. "
                f"Choose another folder in {config_path()}.") from e
        if synced:
            raise StoreConfigError(
                f"the blob store {path} is inside {folder}, which a sync client uploads. The store "
                "holds the plaintext originals behind your notes, and plaintext stays on your "
                "Macs; a sync client can also evict a blob, turning a read into a download or a "
                f"hang. Choose a local folder in {config_path()}.")


def root() -> Path:
    """Where the store lives: `[blobs] path` from `config.toml`, else the default. Raises
    StoreConfigError for a setting that cannot be used — never falls back to the default, which
    would make every blob in the configured store read as missing."""
    cfg = config_path()
    try:
        data = tomllib.loads(cfg.read_text("utf-8"))
    except FileNotFoundError:
        path = default_root()
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as e:
        raise StoreConfigError(f"cannot read {cfg}: {e}") from e
    else:
        section = data.get("blobs", {})
        if not isinstance(section, dict):
            raise StoreConfigError(f"{cfg}: [blobs] must be a table.")
        value = section.get("path")
        if value is None:
            path = default_root()
        elif not isinstance(value, str) or not value.strip():
            raise StoreConfigError(f"{cfg}: [blobs] path must be a non-empty string.")
        else:
            path = Path(os.path.expanduser(value))
            if not path.is_absolute():
                raise StoreConfigError(
                    f"{cfg}: [blobs] path {value!r} is relative. It would name a different folder "
                    "from every working directory; write it absolute or starting with `~`.")
    _refuse_sync_folder(path)
    return path


# ---------------------------------------------------------------- store entries

def is_checksum(value: object) -> bool:
    return isinstance(value, str) and CHECKSUM.fullmatch(value) is not None


def _need_checksum(checksum: str) -> None:
    if not is_checksum(checksum):
        raise BlobError(f"{checksum!r} is not a SHA-256 checksum (64 lowercase hex characters).")


def blob_path(store: Path, checksum: str) -> Path:
    _need_checksum(checksum)
    return store / "sha256" / checksum[:2] / checksum


def tombstone_path(store: Path, checksum: str) -> Path:
    _need_checksum(checksum)
    return store / "tombstones" / checksum


def _private_entry(path: Path, fd: int, st: os.stat_result) -> None:
    if st.st_uid != os.geteuid():
        raise BlobError(f"{path} is in the blob store but is owned by another user.")
    if _has_acl(fd):
        raise BlobError(f"{path} carries an extended ACL, which can grant other users what its "
                        "mode bits deny. Remove it (`chmod -N`) or choose another store folder.")


def _ensure_dir(path: Path) -> None:
    """A store directory: 0700, owned by this user, no ACL. A symlink is refused: a link inside the
    store would let a write land wherever it points."""
    with contextlib.suppress(FileExistsError):
        os.mkdir(path, _DIR_MODE)
    try:
        fd = os.open(path, os.O_RDONLY | os.O_NOFOLLOW | os.O_DIRECTORY)
    except OSError as e:
        if e.errno in (errno.ENOTDIR, errno.ELOOP):
            raise BlobError(f"{path} is in the blob store but is not a directory.") from e
        raise
    try:
        st = os.fstat(fd)
        _private_entry(path, fd, st)
        if stat.S_IMODE(st.st_mode) != _DIR_MODE:
            os.fchmod(fd, _DIR_MODE)
    finally:
        os.close(fd)


def _open_store(store: Path) -> None:
    """Make `store` usable, or refuse it.

    Its ancestors must not be movable by another user (`private.untrusted`), or the store could be
    swapped between this check and the write. A folder that ALREADY EXISTS is taken over only if
    it is empty or already a store: `path = "~"` must not chmod the home folder 0700 and adopt it.
    Once it holds the store's own entries it is a store, whatever else Finder leaves in it.
    """
    resolved = private.untrusted(store)
    if resolved.why:
        raise StoreConfigError(f"the blob store {store} cannot be trusted: {resolved.why}")
    try:
        names = set(os.listdir(store))
    except FileNotFoundError:
        missing, p = [], store
        while not p.exists():
            missing.append(p)
            p = p.parent
        for d in reversed(missing):
            _ensure_dir(d)
        names = set()
    except NotADirectoryError as e:
        raise StoreConfigError(f"the blob store {store} is not a directory.") from e
    if MARKER not in names and names - _FINDER:
        raise StoreConfigError(
            f"{store} already holds other files ({', '.join(sorted(names - _FINDER)[:3])}…) and "
            "is not a blob store, so it will not be made into one. Name an empty or new folder.")
    _ensure_dir(store)
    if MARKER not in names:
        # EXCL: two ingests initialising one store both see it empty; the second must not try to
        # open the first's 0400 marker for writing.
        with contextlib.suppress(FileExistsError):
            os.close(os.open(store / MARKER, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW,
                             _BLOB_MODE))


def _ensure(store: Path, *parts: str) -> Path:
    _open_store(store)
    for part in parts:
        store = store / part
        _ensure_dir(store)
    return store


@contextlib.contextmanager
def locked(store: Path, *, exclusive: bool) -> Iterator[None]:
    """Writers share the lock; `forget` and `gc` hold it alone. Without it a `forget` landing
    between `put`'s tombstone check and its rename left the forgotten bytes stored under a
    tombstone, and a `gc` sweep could remove a blob a concurrent ingest had just found present."""
    _open_store(store)
    fd = os.open(store / ".lock", os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600)
    try:
        fcntl.flock(fd, fcntl.LOCK_EX if exclusive else fcntl.LOCK_SH)
        yield
    finally:
        os.close(fd)


def _regular_sha256(path: Path) -> str | None:
    """The checksum of `path` if it is a regular file, read through the descriptor that was checked:
    opened non-blocking and unfollowed, so a FIFO or link swapped in cannot hang the reader."""
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK | os.O_NOFOLLOW)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            return None
        h = hashlib.sha256()
        while block := os.read(fd, 1 << 20):
            h.update(block)
        return h.hexdigest()
    finally:
        os.close(fd)


def _fsync_dir(path: Path) -> None:
    fd = os.open(path, os.O_RDONLY)
    try:
        os.fsync(fd)
    finally:
        os.close(fd)


def _is_blob(path: Path) -> bool:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return False
    if not stat.S_ISREG(st.st_mode):
        raise BlobError(f"{path} is in the blob store but is not a regular file.")
    return True


def _held_and_whole(path: Path, checksum: str) -> bool:
    """Held and verified. Its mtime is refreshed, because `gc` spares a blob seen recently: a
    re-ingest that finds its original present is about to promote a note naming it. A blob that
    cannot be read or touched counts as not whole, so the verified copy replaces it."""
    try:
        if not (_is_blob(path) and sha256_file(path) == checksum):
            return False
        os.utime(path)
    except OSError:
        return False
    return True


def _write_all(fd: int, data: bytes) -> None:
    view = memoryview(data)
    while view:
        view = view[os.write(fd, view):]


@dataclass(frozen=True)
class Put:
    checksum: str
    outcome: str        # `stored` now · `present`, already held and verified · `discarded`
    path: Path


def put(src: Path, *, expected: str | None = None, store: Path | None = None) -> Put:
    """Copy `src` into the store under its checksum. Idempotent.

    Copied to `tmp/`, fsynced, re-checksummed from disk, then renamed into place, so a blob under
    its final name is always whole and always what its name says. `expected`, when given, is the
    checksum the caller already recorded for this file: a copy that hashes to anything else means
    the file changed in between, and storing it would file the wrong bytes under the note's name.

    A tombstoned checksum is not stored: `forget` is the operator saying never again, and ingest
    re-adding it silently would undo that.
    """
    store = store or root()
    with locked(store, exclusive=False):
        if expected is not None:
            _need_checksum(expected)
            if tombstone_path(store, expected).exists():
                return Put(expected, "discarded", blob_path(store, expected))
            if _held_and_whole(dest := blob_path(store, expected), expected):
                return Put(expected, "present", dest)
        tmp = _ensure(store, "tmp") / f".{secrets.token_hex(8)}"
        try:
            fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, _BLOB_MODE)
            try:
                _private_entry(tmp, fd, os.fstat(fd))
                with open(src, "rb") as fh:
                    while block := fh.read(1 << 20):
                        _write_all(fd, block)
                os.fsync(fd)
            finally:
                os.close(fd)
            checksum = sha256_file(tmp)
            if expected is not None and checksum != expected:
                raise BlobError(f"{src} hashes to {checksum}, not the {expected} recorded for it: "
                                "the file changed while it was being read. Nothing was stored.")
            if tombstone_path(store, checksum).exists():
                return Put(checksum, "discarded", blob_path(store, checksum))
            dest = blob_path(store, checksum)
            if _held_and_whole(dest, checksum):
                return Put(checksum, "present", dest)
            # Absent, or present and corrupt: the verified copy takes its place.
            _ensure(store, "sha256", checksum[:2])
            os.rename(tmp, dest)
            _fsync_dir(dest.parent)
            return Put(checksum, "stored", dest)
        finally:
            tmp.unlink(missing_ok=True)


def state(checksum: str, *, store: Path | None = None) -> str:
    """`stored`, `discarded` or `missing`. A stat, never a read, so it cannot report `corrupt` —
    only `verified` can, because only it reads the bytes."""
    store = store or root()
    if tombstone_path(store, checksum).exists():
        return "discarded"
    return "stored" if _is_blob(blob_path(store, checksum)) else "missing"


def verified(checksum: str, *, store: Path | None = None) -> Path:
    """The blob's path, after its bytes are re-hashed and match its name. Raises BlobCorrupt on a
    mismatch and BlobError when it is not held."""
    path = blob_path(store or root(), checksum)
    if not _is_blob(path):
        raise BlobError(f"no blob {checksum} in the store.")
    if sha256_file(path) != checksum:
        raise BlobCorrupt(f"blob {checksum} no longer hashes to its name. It is not served.")
    return path


def forget(checksum: str, *, store: Path | None = None) -> bool:
    """Delete one blob, and any interrupted copy of it in `tmp/`, and tombstone it so ingest will
    not silently re-add it. Returns whether a blob was held. The tombstone is written FIRST: a
    crash between the two leaves a tombstoned blob, which the next `forget` finishes, never a
    deleted blob that ingest would quietly bring back."""
    store = store or root()
    stone = tombstone_path(store, checksum)
    with locked(store, exclusive=True):
        _ensure(store, "tombstones")
        try:
            fd = os.open(stone, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, _BLOB_MODE)
        except FileExistsError:
            pass
        else:
            try:
                _write_all(fd, f"forgotten = {datetime.now(UTC).isoformat(timespec='seconds')}\n"
                       .encode("ascii"))
                os.fsync(fd)
            finally:
                os.close(fd)
            _fsync_dir(stone.parent)
        # Exclusive, so no `put` is mid-copy: whatever `tmp/` holds was left by a crash. Regular
        # files only: opening a FIFO planted there would hang while every ingest waits on the lock.
        for leftover in leftovers(store):
            with contextlib.suppress(OSError):
                if _regular_sha256(leftover) == checksum:
                    leftover.unlink()
        return remove(checksum, store=store)


def remove(checksum: str, *, store: Path) -> bool:
    """Delete one blob WITHOUT a tombstone. The caller holds the exclusive lock: `forget`, or
    `blob_lifecycle.gc_apply` with a plan the operator confirmed, after which a later ingest of the
    same original may store it again."""
    path = blob_path(store, checksum)
    if not _is_blob(path):
        return False
    path.unlink()
    _fsync_dir(path.parent)
    return True


@dataclass(frozen=True)
class Held:
    size: int
    mtime: float        # last stored or last found present by an ingest


def held(store: Path | None = None) -> dict[str, Held]:
    """Every blob the store holds. Entries that are not well-formed blob names are not blobs."""
    store = store or root()
    out: dict[str, Held] = {}
    base = store / "sha256"
    if not base.is_dir():
        return out
    # A concurrent `forget` or `gc` may remove an entry between the listing and its stat; what is
    # gone is simply not held.
    for fan in sorted(base.iterdir()):
        if not fan.is_dir() or fan.is_symlink():
            continue
        with contextlib.suppress(FileNotFoundError):
            for p in sorted(fan.iterdir()):
                if is_checksum(p.name) and p.name[:2] == fan.name:
                    try:
                        st = os.lstat(p)
                    except FileNotFoundError:
                        continue
                    if stat.S_ISREG(st.st_mode):
                        out[p.name] = Held(st.st_size, st.st_mtime)
    return out


def seen_vaults(store: Path) -> set[str]:
    """The vaults earlier complete `gc` scans read. See `blob_lifecycle.gc_plan`. A JSON list, so a
    path holding a newline is one entry."""
    try:
        data = json.loads((store / LEDGER).read_text("utf-8"))
    except FileNotFoundError:
        return set()
    except (OSError, UnicodeDecodeError, ValueError) as e:
        raise BlobError(f"the vault ledger {store / LEDGER} cannot be read ({e}). gc will not run "
                        "without it; restore it, or remove it to start the ledger again.") from e
    if not isinstance(data, list) or not all(isinstance(v, str) for v in data):
        raise BlobError(f"the vault ledger {store / LEDGER} is not a list of paths.")
    return set(data)


def record_vaults(store: Path, vaults: set[str]) -> None:
    """Replace the ledger, atomically. The caller holds the exclusive lock."""
    tmp = _ensure(store, "tmp") / f".{secrets.token_hex(8)}"
    try:
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o600)
        try:
            _write_all(fd, json.dumps(sorted(vaults), indent=1).encode("utf-8"))
            os.fsync(fd)
        finally:
            os.close(fd)
        os.rename(tmp, store / LEDGER)
        _fsync_dir(store)
    finally:
        tmp.unlink(missing_ok=True)


def tombstones(store: Path | None = None) -> set[str]:
    d = (store or root()) / "tombstones"
    return {p.name for p in d.iterdir() if is_checksum(p.name)} if d.is_dir() else set()


def leftovers(store: Path | None = None) -> list[Path]:
    """Staging files a crashed write left behind. Never under a blob's name, so never served."""
    d = (store or root()) / "tmp"
    return sorted(d.iterdir()) if d.is_dir() else []


def exposed(store: Path | None = None) -> list[str]:
    """What another user could read: loose mode bits, a foreign owner or an extended ACL on any
    store entry. Reported, not repaired — every entry is created private, so one that is not was
    changed by hand and the operator should know."""
    store = store or root()
    if not store.exists():
        return []
    out = private.exposed([store])
    for dirpath, dirnames, filenames in os.walk(store):
        for name in (*dirnames, *filenames):
            p = Path(dirpath, name)
            try:
                # NONBLOCK: a FIFO planted in the store must not hang `status` on its open.
                fd = os.open(p, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK)
            except FileNotFoundError:
                continue
            except OSError as e:
                out.append(f"{p}: " + ("a link inside the store, which could redirect a write"
                                       if e.errno == errno.ELOOP else (e.strerror or str(e))))
                continue
            try:
                _private_entry(p, fd, os.fstat(fd))
            except BlobError as e:
                out.append(str(e))
            finally:
                os.close(fd)
    return out
