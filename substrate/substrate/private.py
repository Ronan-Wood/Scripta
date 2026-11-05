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

`seal_index()` and `exposed_index()` apply the last two to one scope. They draw the line at what the
engine OWNS, because the recursive chmod used to reach anything under whatever `--index-root` passed
`_refuse_index_root`, and a folder holding the index used to be neither sealed nor reported.
"""

from __future__ import annotations

import contextlib
import hashlib
import os
import re
import stat
from collections.abc import Iterable, Iterator
from pathlib import Path
from typing import NamedTuple

from substrate import scopes

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
            line = _tighten(path, st)
            if line:
                failed.append(line)
    return failed


def _tighten(path: Path, st: os.stat_result | OSError) -> str | None:
    """Strip group and other bits from one path, or say why it could not be done."""
    if isinstance(st, OSError):
        return f"{path}: {st.strerror or st}"
    mode = stat.S_IMODE(st.st_mode)
    if not mode & OPEN:
        return None
    try:
        os.chmod(path, mode & ~OPEN, follow_symlinks=not _NOFOLLOW)
    except FileNotFoundError:
        return None  # removed since the walk listed it: nothing left to expose
    except OSError as e:
        return f"{path}: {e.strerror or e}"
    return None


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


# ---------------------------------------------------------------- one scope's index

# The shape of `ingest_dir_name`, kept beside it so the two change together. DOTALL because a note's
# stem may hold a newline, which APFS allows.
_HASH_LEN = 8
INGEST_DIR = re.compile(rf".+__.*__[0-9a-f]{{{_HASH_LEN}}}", re.DOTALL)
# The same shape with the hash in any case. Only a candidate: whether compose's own spelling opens
# such an entry is the volume's to say (`_case_alias`).
_INGEST_DIR_ANY_CASE = re.compile(INGEST_DIR.pattern, re.DOTALL | re.IGNORECASE)

# Everything `ingest_markdown` writes into an ingest directory (markdown/ingest.py).
INGEST_FILES = frozenset({"document.md", "blocks.jsonl", "chunks.jsonl", "run.json"})

# Group or other may create, rename or remove entries.
_WRITABLE = 0o022
_DIR = os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW | os.O_CLOEXEC
_MAX_LINKS = 40
_HOLDER_PASSES = 8

# A path still readable by another uid, and why.
Fail = tuple[str, str]


def ingest_dir_name(vault: str, note: Path) -> str:
    """The directory compose ingests `note` into: vault, filename stem, and a short hash of the
    path, so two same-named notes (each source's `passages/00-*.md`) never share one."""
    digest = hashlib.sha256(str(note).encode()).hexdigest()[:_HASH_LEN]
    return f"{vault}__{note.stem}__{digest}"


def _stat(path: Path) -> os.stat_result | OSError | None:
    """`path`'s own stat, the error that stopped it, or None when there is nothing there."""
    try:
        return os.lstat(path)
    except FileNotFoundError:
        return None
    except OSError as e:
        return e


def _why(e: OSError) -> str:
    return e.strerror or str(e)


def _key(st: os.stat_result) -> tuple[int, int]:
    return st.st_dev, st.st_ino


def _settled_folder(d: Path) -> str | None:
    """Why another uid could rearrange the entries of folder `d`, or None."""
    st = _stat(d)
    if st is None:
        return None
    if why := _movable(d, st):
        return why
    if st.st_mode & _WRITABLE and not _shared(st):
        return f"{d}: other users can write it"
    return None


def _shared(st: os.stat_result) -> bool:
    """A root-owned sticky folder (`/tmp`, `/Users/Shared`): anyone may add a name to it, and
    only a name's owner may move or remove it."""
    return st.st_uid == 0 and bool(st.st_mode & stat.S_ISVTX)


class Resolved(NamedTuple):
    """What `untrusted` found: how far `path` resolved, why another uid could change what it names
    (None when it cannot), and whether all of it exists — which implies `why` is None. Act on
    `path` only when it `exists`."""
    path: Path
    why: str | None = None
    exists: bool = False


def absolute(path: Path | str) -> Path:
    """`path` made absolute WITHOUT collapsing `..` by spelling: `link/..` is the parent of the
    link's target, which is what the kernel and SQLite open, not the folder holding the link."""
    p = Path(path)
    return p if p.is_absolute() else Path(os.getcwd()) / p


def _movable(d: Path, st: os.stat_result | OSError | None) -> str | None:
    """Why another uid could move folder `d` (whose own stat is `st`) itself, or None: a folder is
    moved by its owner."""
    if isinstance(st, OSError):
        return f"{d}: {_why(st)}"
    if st is None or not stat.S_ISDIR(st.st_mode):
        return f"{d}: is not a directory"
    if st.st_uid not in (0, os.geteuid()):
        return f"{d}: owned by another user"
    return None


def untrusted(path: Path | str) -> Resolved:
    """Resolve `path` ONE COMPONENT AT A TIME, following each link by hand, so every folder looked
    into on the way is checked — the folders holding links partway along a chain included.

    Each must be owned by root or this user and writable by nobody else, unless it is a root-owned
    sticky folder (`/tmp`, `/Users/Shared`), where others cannot move this user's entries; each
    link must be owned by root or this user. Whoever fails either can put a tree of their choosing
    at `path` between a check and the chmod that follows it. A caller acts on the resolution this
    returns, never on a fresh one. Mode bits and owners only: an ACL granting another user write is
    not seen.
    """
    uid = os.geteuid()
    parts = list(absolute(path).parts[1:])
    cur, looked_in, links = Path("/"), set(), 0
    while parts:
        name = parts.pop(0)
        if name in ("", "."):
            continue
        if name == "..":
            # Where `..` leads is decided by whoever can MOVE `cur` — its owner, even in a sticky
            # folder — not by whoever can write into it.
            if why := _movable(cur, _stat(cur)):
                return Resolved(Path(cur, name, *parts), why)
            cur = cur.parent
            continue
        if cur not in looked_in:
            if why := _settled_folder(cur):
                return Resolved(Path(cur, name, *parts), why)
            looked_in.add(cur)
        nxt = cur / name
        st = _stat(nxt)
        if st is None:
            return Resolved(Path(nxt, *parts))
        if isinstance(st, OSError):
            return Resolved(Path(nxt, *parts), f"{nxt}: {_why(st)}")
        if not stat.S_ISLNK(st.st_mode):
            cur = nxt
            continue
        if st.st_uid not in (0, uid):
            return Resolved(Path(nxt, *parts), f"{nxt}: a link owned by another user")
        links += 1
        if links > _MAX_LINKS:
            return Resolved(Path(nxt, *parts), f"{path}: too many links")
        try:
            target = Path(os.readlink(nxt))
        except OSError as e:
            return Resolved(Path(nxt, *parts), f"{nxt}: {_why(e)}")
        if target.is_absolute():
            cur, parts = Path("/"), [*target.parts[1:], *parts]
        else:
            parts = [*target.parts, *parts]
    return Resolved(cur, exists=True)


def _tighten_fd(fd: int, label: str) -> Fail | None:
    """`_tighten` through a descriptor, so nothing is resolved by name between check and chmod."""
    try:
        mode = stat.S_IMODE(os.fstat(fd).st_mode)
        if mode & OPEN:
            os.fchmod(fd, mode & ~OPEN)
    except OSError as e:
        return label, _why(e)
    return None


def _open_owned_dir(path: Path | str, *, dir_fd: int | None = None,
                    label: str | None = None) -> int | Fail | None:
    """A descriptor on the real directory at `path`, owned by this user; why not; or None when
    there is nothing there."""
    label = label or str(path)
    try:
        fd = os.open(path, _DIR, dir_fd=dir_fd)
    except FileNotFoundError:
        return None
    except OSError as e:
        return label, _why(e)
    try:
        if os.fstat(fd).st_uid == os.geteuid():
            return fd
        failure: Fail = (label, "owned by another user")
    except OSError as e:
        failure = (label, _why(e))
    os.close(fd)
    return failure


def _seal_dir(path: Path) -> list[Fail]:
    """Seal one folder, not what is in it, when nothing on the way to it is another uid's."""
    r = untrusted(path)
    if r.why:
        return [(str(path), f"not sealed: {r.why}")]
    if not r.exists:
        return []
    fd = _open_owned_dir(r.path, label=str(path))
    if not isinstance(fd, int):
        return [fd] if fd else []
    try:
        return [f] if (f := _tighten_fd(fd, str(path))) else []
    finally:
        os.close(fd)


def _seal_file(path: Path, label: str, dir_fd: int | None = None) -> Fail | None:
    """Seal one regular file of this user's, by name and never through a link.

    By name, not through a descriptor: closing ANY descriptor on a SQLite file drops every POSIX
    lock this process holds on it, a live connection's included. Safe because the caller has
    checked every folder on the way to it.

    A file with another hard link is sealed too, and that closes the other name with it: the mode
    is the file's. Refusing would let anyone who can reach a loose index keep it readable for good
    with one `ln` (macOS lets them). The cost is the reverse case — a name planted while its folder
    was open to others, linking some other file of this user's — and there the chmod can only take
    group and other bits away, from someone who could already have swapped the database itself.
    Ingest files avoid even that: `_seal_ingest` gives them a file of their own (`_relink`)."""
    try:
        st = os.stat(path, dir_fd=dir_fd, follow_symlinks=False)
    except FileNotFoundError:
        return None
    except OSError as e:
        return label, _why(e)
    if stat.S_ISLNK(st.st_mode):
        return None
    if why := _file_refusal(st):
        return label, why
    mode = stat.S_IMODE(st.st_mode)
    if not mode & OPEN:
        return None
    try:
        os.chmod(path, mode & ~OPEN, dir_fd=dir_fd, follow_symlinks=not _NOFOLLOW)
    except FileNotFoundError:
        return None
    except OSError as e:
        return label, _why(e)
    return None


def _file_refusal(st: os.stat_result) -> str | None:
    """Why a family or ingest name that is not a link is not this index's to vouch for, or None.
    Compose and status judge by this one rule."""
    if not stat.S_ISREG(st.st_mode):
        return "not a regular file, so it was not sealed"
    if st.st_uid != os.geteuid():
        return "owned by another user, so it was not sealed"
    return None


def _relink(dir_fd: int, name: str, label: str) -> Fail | None:
    """Give `name` a private file of its own, in place of one it shares with another hard link:
    copy it to a new 0600 file beside it and rename that over it. The other name keeps the old
    file and what it already held; nothing written from now on reaches it, and no mode of a file
    this tree does not decide is changed. Only for ingest files, which compose rewrites anyway —
    never for SQLite's, which a live connection may hold open."""
    tmp = f".{name}.{os.urandom(8).hex()}.tmp"
    try:
        src = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_CLOEXEC, dir_fd=dir_fd)
    except OSError as e:
        return label, _why(e)
    try:
        dst = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW | os.O_CLOEXEC,
                      0o600, dir_fd=dir_fd)
    except OSError as e:
        os.close(src)
        return label, _why(e)
    try:
        while chunk := os.read(src, 1 << 20):
            view = memoryview(chunk)
            while view:
                if not (n := os.write(dst, view)):
                    raise OSError("the copy stopped writing")
                view = view[n:]
        copied, source = os.fstat(dst).st_size, os.fstat(src).st_size
        if copied != source:
            raise OSError(f"copied {copied} of {source} bytes; "
                          "the file changed size during the copy")
        os.fsync(dst)
        os.rename(tmp, name, src_dir_fd=dir_fd, dst_dir_fd=dir_fd)
    except OSError as e:
        try:
            os.unlink(tmp, dir_fd=dir_fd)
        except OSError:
            pass
        return label, _why(e)
    finally:
        os.close(src)
        os.close(dst)
    return None


def _engine_owns(home: Path, folder: Path) -> bool:
    """Whether `folder` is the engine's to seal: `home` or inside it, compared as files.

    Never when `home` is a link, not a directory of this user's, or the operator's home folder or
    above it: a `~/.substrate` linked into OneDrive or at `~` would hand over the folders there.
    """
    st = _stat(home)
    if (not isinstance(st, os.stat_result) or not stat.S_ISDIR(st.st_mode)
            or st.st_uid != os.geteuid()):
        return False
    user = Path.home()
    if scopes._same_path(home, user) or scopes.is_within(user, home):
        return False
    return scopes._same_path(folder, home) or scopes.is_within(folder, home)


def _holders(db: Path, index_root: Path | None) -> list[tuple[Path, os.stat_result | OSError]]:
    """The real folders the db and the tree sit in, each once (compared as files: an APFS case
    variant is the same folder), with their own stat or the error that stopped it.

    Each is resolved AS A FOLDER, not through the db's resolution: that one fails exactly at a
    holder others can write, which is the holder this exists to seal. So only the folders above it
    must be trusted. Candidates are the folder of the name as written and the folder of what it
    resolves to (as far as it resolves); each is accepted only if its own resolution is trusted. A
    folder others can write further up is not a holder: the db's or root's rule reports it. A db
    not created yet still has one; a root that does not exist has none, since there is no tree yet
    whose names it could list; and the index root is never one — it decides a db inside it by its
    own rule.
    """
    # The root, only as a TRUSTED resolution names it: a path another uid steers would let them
    # choose which folder is left out.
    root_key, root_path = None, None
    if index_root is not None and (rr := untrusted(index_root)).exists:
        root_path = rr.path
        if isinstance(rst := _stat(rr.path), os.stat_result):
            root_key = _key(rst)
    out: list[tuple[Path, os.stat_result | OSError]] = []
    named = [(db, False), *([(index_root, True)] if index_root is not None else [])]
    for p, is_root in named:
        if is_root and _stat(absolute(p)) is None:
            continue
        for folder in (absolute(p).parent, untrusted(p).path.parent):
            r = untrusted(folder)
            if r.why or not r.exists:
                continue
            st = _stat(r.path)
            if (st is None or r.path == root_path
                    or (isinstance(st, os.stat_result)
                        and (not stat.S_ISDIR(st.st_mode) or _key(st) == root_key))
                    or any(q == r.path or _same(st, o) for q, o in out)):
                continue
            out.append((r.path, st))
    return out


def _same(a: object, b: object) -> bool:
    return (isinstance(a, os.stat_result) and isinstance(b, os.stat_result)
            and _key(a) == _key(b))


def _family(db: Path) -> tuple[list[Resolved], list[Path]]:
    """(the database and its side files beside `--db` as written and beside what it resolves to,
    each resolved and checked on its own; the side files that are links).

    SQLite may keep side files by either spelling of a symlinked `--db`. Each is acted on through
    the resolution that was checked. Only the database itself may be a link (compose writes
    through one); a side file that is one is never followed, and is reported without holding the
    rest back — SQLite does not make them and refuses to open one, so it is a stray, not a spelling
    another uid controls."""
    written = absolute(db)
    resolved = untrusted(db).path
    members: dict[Path, Resolved] = {}
    links: list[Path] = []
    for n in [*sqlite_family(written), *sqlite_family(resolved)]:
        st = _stat(n)
        if (n not in (written, resolved) and isinstance(st, os.stat_result)
                and stat.S_ISLNK(st.st_mode)):
            if n not in links:
                links.append(n)
            continue
        r = untrusted(n)
        members.setdefault(r.path, r)
    return list(members.values()), links


class Family(NamedTuple):
    """How the root recognises this scope's own database files: by file, from trusted
    resolutions, and by name, when the folder holding `--db` as written is the root itself."""
    keys: set[tuple[int, int]]
    names: set[str]


def _family_in_root(members: list[Resolved], db: Path, root: Path) -> Family:
    """`Family` for the root at `root`. By file only from TRUSTED resolutions — an untrusted one
    follows a path another uid steers, and would let them choose which entry is skipped. By name
    when `--db`'s folder, resolved as a folder, is the root: then the names are the root's own
    entries, read through its descriptor, and a db in a root others can still write is recognised
    before that root is sealed."""
    keys = {_key(st) for r in members if r.exists
            if isinstance(st := _stat(r.path), os.stat_result)}
    folder = untrusted(absolute(db).parent)
    same = (folder.exists and isinstance(a := _stat(folder.path), os.stat_result)
            and isinstance(b := _stat(root), os.stat_result) and _key(a) == _key(b))
    names = {n.name for n in sqlite_family(absolute(db))} if same else set()
    return Family(keys, names)


class Listing(NamedTuple):
    """What `_classify` found in one folder. `planted` are entries with an ingest directory's name
    that are not a directory of this user's — a link, or another user's: compose would write a
    note's files into whatever such a name leads to, so they are reported whatever the root's
    mode."""
    ingest: list[str]
    shaped: list[str]
    own: bool
    error: OSError | None
    planted: list[str]


def _classify(fd: int, family: Family) -> Listing:
    """The ingest directories in the folder open on `fd`, the folders shaped like one that are
    not, whether it holds nothing but the engine's files, and the error that stopped the listing.

    An ingest directory is a real directory of this user's with `ingest_dir_name`'s shape whose
    entries are regular files, at least one of them in `INGEST_FILES` and every other one hidden.
    One holding no ingest file at all — empty, or only a `.DS_Store` — is neither the engine's nor
    a stranger's: a note refused after ingest made its directory leaves one, and so could a folder
    of the operator's that happens to have the shape. The engine's files are those, this scope's
    database family (its own link too, when `--db` is one), and hidden files. A link is never an
    ingest directory. A listed entry is the family's only when it is a file or link of this user's
    whose (dev, ino) is one of the family's keys, or one of its names looked up through `fd` —
    exact whether or not the volume ignores case.
    """
    uid = os.geteuid()
    try:
        names = sorted(os.listdir(fd))
    except OSError as e:
        return Listing([], [], False, e, [])
    own_keys = set(family.keys)
    for n in family.names:
        try:
            own_keys.add(_key(os.stat(n, dir_fd=fd, follow_symlinks=False)))
        except OSError:
            continue
    ingest: list[str] = []
    shaped: list[str] = []
    planted: list[str] = []
    own = True
    for name in names:
        try:
            st = os.stat(name, dir_fd=fd, follow_symlinks=False)
        except FileNotFoundError:
            continue
        except OSError:
            own = False
            continue
        if ((name.startswith(".") and stat.S_ISREG(st.st_mode))
                or (st.st_uid == uid and (stat.S_ISREG(st.st_mode) or stat.S_ISLNK(st.st_mode))
                    and _key(st) in own_keys)):
            continue
        exact = bool(INGEST_DIR.fullmatch(name))
        alias = not exact and _case_alias(fd, name, st)
        named = exact or alias
        if not (stat.S_ISDIR(st.st_mode) and st.st_uid == uid and named):
            own = False
            if named and (stat.S_ISLNK(st.st_mode) or st.st_uid != uid):
                planted.append(name)
            continue
        if alias:
            # This user's folder, opened by compose only through the volume ignoring case: never
            # the engine's own (so never sealed as an ingest directory), but what compose would
            # write into, so judged as shaped — reported when its mode or what it holds is unsafe.
            own = False
            shaped.append(name)
            continue
        held = _held(fd, name)
        # This user's regular files only: compose's next write into a planted one of someone
        # else's would put the note's text in their file.
        files_only = held is not None and not any(_file_refusal(st) for _, st in held)
        if files_only and all(n in INGEST_FILES or n.startswith(".") for n, _ in held):
            if any(n in INGEST_FILES for n, _ in held):
                ingest.append(name)
            continue
        own = False
        shaped.append(name)
    return Listing(ingest, shaped, own, None, planted)


def _case_alias(fd: int, name: str, st: os.stat_result) -> bool:
    """Whether `name` has an ingest directory's shape only with the hash in another case (never
    for the exact shape) AND is an entry compose would open all the same: the lower-case spelling compose uses names
    this very entry, true on a volume that ignores case and false on one that does not. A lookup
    that fails for any reason but absence counts as yes: what cannot be ruled out is judged."""
    if INGEST_DIR.fullmatch(name) or not _INGEST_DIR_ANY_CASE.fullmatch(name):
        return False
    try:
        st2 = os.stat(_lower_hash(name), dir_fd=fd, follow_symlinks=False)
    except FileNotFoundError:
        return False
    except OSError:
        return True
    return _key(st2) == _key(st)


def _lower_hash(name: str) -> str:
    return name[:-_HASH_LEN] + name[-_HASH_LEN:].lower()


def _held(fd: int, name: str) -> list[tuple[str, os.stat_result]] | None:
    """Each entry of directory `name` in `fd`, by its own stat, or None if it cannot be read."""
    try:
        child = os.open(name, _DIR, dir_fd=fd)
    except FileNotFoundError:
        return []  # removed since the listing: nothing there to judge
    except OSError:
        return None
    try:
        out = []
        for e in os.listdir(child):
            try:
                out.append((e, os.stat(e, dir_fd=child, follow_symlinks=False)))
            except FileNotFoundError:
                continue  # removed since the listing: nothing there to judge
        return out
    except OSError:
        return None
    finally:
        os.close(child)


def _seal_ingest(fd: int, name: str, label: Path) -> list[Fail]:
    """Seal one ingest directory and the files in it. The directory is opened without following
    a link and sealed first, and each file is chmodded relative to it, so nothing inside the tree
    is resolved by name. A file that shares its inode with another name is given one of its own
    (`_relink`) rather than chmodded through the other."""
    child = _open_owned_dir(name, dir_fd=fd, label=str(label))
    if not isinstance(child, int):
        return [child] if child else []
    fails: list[Fail] = []
    try:
        if f := _tighten_fd(child, str(label)):
            return [f]
        for e in os.listdir(child):
            try:
                st = os.stat(e, dir_fd=child, follow_symlinks=False)
            except FileNotFoundError:
                continue
            except OSError as err:
                fails.append((str(label / e), _why(err)))
                continue
            if not stat.S_ISREG(st.st_mode):
                fails.append((str(label / e), "a link or not a file, in an ingest directory: "
                                              "compose would write through it"))
            elif st.st_nlink > 1 and st.st_uid == os.geteuid():
                if f := _relink(child, e, str(label / e)):
                    fails.append(f)
            elif f := _seal_file(Path(e), str(label / e), dir_fd=child):
                fails.append(f)
    except OSError as e:
        fails.append((str(label), _why(e)))
    finally:
        os.close(child)
    return fails


def _seal_family(db: Path, members: list[Resolved], links: list[Path]) -> list[Fail]:
    """All of the family or none of it: one untrusted spelling means another uid may decide what
    the others name too. A side file that is a link is reported and does not hold the rest back."""
    fails: list[Fail] = [(str(n), "a side file that is a link, so it was not followed")
                         for n in links]
    if whys := list(dict.fromkeys(r.why for r in members if r.why)):
        return fails + [(str(db), f"not sealed: {why}") for why in whys]
    return fails + [f for r in members if r.exists and (f := _seal_file(r.path, str(r.path)))]


def _shaped_unsafe(fd: int, name: str) -> str | None:
    """Why a folder shaped like an ingest directory that is not one is unsafe, or None. Judged by
    the folder's own mode and by what compose would open in it under each `INGEST_FILES` name —
    looked up through the folder, so `Document.md` on a volume that ignores case is found — which
    must be a closed regular file of this user's with no other hard link: compose writes by name,
    so a planted file, link or hard link there would take a note's text. What else the folder
    holds is not the engine's to judge."""
    if _loose_at(fd, name):
        return "other users can read it"
    try:
        child = os.open(name, _DIR, dir_fd=fd)
    except FileNotFoundError:
        return None
    except OSError:
        return "it cannot be read"
    try:
        for n in sorted(INGEST_FILES):
            try:
                st = os.stat(n, dir_fd=child, follow_symlinks=False)
            except FileNotFoundError:
                continue
            except OSError:
                return f"its {n} cannot be read"
            if _file_refusal(st) or st.st_nlink > 1 or st.st_mode & OPEN:
                return (f"what compose would open as its {n} is not a closed file of this "
                        "user's alone")
    finally:
        os.close(child)
    return None


def _loose_at(fd: int, name: str) -> bool:
    try:
        return bool(stat.S_IMODE(os.stat(name, dir_fd=fd, follow_symlinks=False).st_mode) & OPEN)
    except FileNotFoundError:
        return False  # removed since the listing: nothing left to expose
    except OSError:
        return True


def _seal_root(index_root: Path, r: Resolved, family: Family) -> list[Fail]:
    """The root folder when it holds nothing but the engine's files, then each ingest directory in
    it. When another uid could write the root, the list walked is read again through the same
    descriptor once it no longer can, so it is not one that uid arranged."""
    if r.why:
        return [(str(index_root), f"not sealed: {r.why}")]
    if not r.exists:
        return []
    target = r.path
    fd = _open_owned_dir(target)
    if not isinstance(fd, int):
        return [fd] if fd else []
    fails: list[Fail] = []
    try:
        listing = _classify(fd, family)
        if listing.error is not None:
            return [(str(target), _why(listing.error))]
        before = os.fstat(fd)
        was_writable = before.st_mode & _WRITABLE
        if listing.own:
            if f := _tighten_fd(fd, str(target)):
                fails.append(f)
        elif stat.S_IMODE(before.st_mode) & OPEN:
            fails.append((str(target), "holds files this engine did not write, so its own mode is "
                                       "left to you"))
        if os.fstat(fd).st_mode & _WRITABLE:
            return [*fails, (str(target), "other users can write it, so the notes in it were not "
                                          "sealed")]
        if was_writable:
            listing = _classify(fd, family)
            if listing.error is not None:
                return [*fails, (str(target), _why(listing.error))]
        for name in listing.ingest:
            fails += _seal_ingest(fd, name, target / name)
        for n in listing.shaped:
            if why := _shaped_unsafe(fd, n):
                fails.append((str(target / n), f"not an ingest directory, and {why}"
                              if INGEST_DIR.fullmatch(n) else
                              f"compose writes a note into it as {_lower_hash(n)}, and {why}: "
                              f"rename it to that spelling"))
        fails += [(str(target / n), "named like an ingest directory but a link or another "
                                    "user's: compose would write a note into it")
                  for n in listing.planted]
    except OSError as e:
        fails.append((str(target), _why(e)))
    finally:
        os.close(fd)
    return fails


def seal_index(db: Path, index_root: Path | None, *, home: Path) -> list[str]:
    """Seal one scope's index, and only what the engine owns of it. `home` is the engine's own
    folder, `~/.substrate`, where the app keeps its indexes.

      * The folder holding the db or the tree: sealed, not recursively, only when `_engine_owns`
        it. Elsewhere it is the operator's (`--db ~/x.db` must not `chmod 700 ~`): reported.
      * The root itself, only when it holds nothing but the engine's files, then each ingest
        directory in it (`_seal_root`).
      * The db family, after the root: a db inside a root this call seals is then sealed too.

    Nothing is changed where `untrusted` names a reason. Returns one line per path still readable
    by another uid, with every reason for it.
    """
    fails: list[Fail] = []
    done: set[Path] = set()
    uid = os.geteuid()
    # Until no new holder appears: sealing one can make a holder beneath it trusted. There are at
    # most four candidates; a pass that keeps finding new ones is reported, not followed.
    for _ in range(_HOLDER_PASSES):
        new = [(h, st) for h, st in _holders(db, index_root) if h not in done]
        if not new:
            break
        for holder, st in new:
            done.add(holder)
            if isinstance(st, OSError):
                fails.append((str(holder), _why(st)))
            elif _engine_owns(home, holder):
                fails += _seal_dir(holder)
            elif st.st_uid not in (0, uid):
                fails.append((str(holder), "the folder holding this index is owned by another "
                                           "user"))
            elif _loose(st):
                fails.append((str(holder), f"the folder holding this index is outside {home}, "
                                           f"so its mode is left to you (`chmod go-rwx` on it)"))
    else:
        if any(h not in done for h, _ in _holders(db, index_root)):
            fails.append((str(db), "the folders holding this index kept changing while they "
                                   "were sealed"))
    if index_root is not None:
        # Resolved after the holders: one this call just sealed was untrusted until it was.
        root = untrusted(index_root)
        fails += _seal_root(index_root, root, _family_in_root(_family(db)[0], db, root.path))
    # Resolved again AFTER the root step, and acted on as resolved here: a db inside a root this
    # call just sealed was untrusted until it was.
    fails += _seal_family(db, *_family(db))
    grouped: dict[str, list[str]] = {}
    for path, why in fails:
        if why not in grouped.setdefault(path, []):
            grouped[path].append(why)
    return [f"{path}: {'; '.join(whys)}" for path, whys in grouped.items()]


def exposed_index(db: Path, index_root: Path | None) -> list[str]:
    """What `seal_index` covers, as `exposed` reports it, plus the folders holding the index
    wherever they are — one another uid can list names every scope in it — and any path
    `untrusted` names a reason for, since another uid could replace what it holds. Files in the
    root that the engine did not write are not judged. Each path is listed once."""
    root = untrusted(index_root) if index_root is not None else None
    members, links = _family(db)
    out = [str(h) for h, st in _holders(db, index_root) if _loose(st)]
    if links or any(r.why for r in members):
        out.append(str(db))
    out += exposed([r.path for r in members if r.exists])
    if any(isinstance(st := _stat(r.path), os.stat_result) and not stat.S_ISLNK(st.st_mode)
           and _file_refusal(st) for r in members if r.exists):
        out.append(str(db))
    if root is not None and _root_exposed(root, _family_in_root(members, db, root.path)):
        out.append(str(index_root))
    return list(dict.fromkeys(out))


def _root_exposed(root: Resolved, family: Family) -> bool:
    """The root, or an ingest directory or one of its files, or a folder shaped like one, is
    readable by another uid — judged as `_seal_root` acts, not recursively — or it cannot be
    checked, or another uid could replace it."""
    if root.why:
        return True
    if not root.exists:
        return False
    st = _stat(root.path)
    if st is None:
        return False
    if _loose(st):
        return True
    fd = _open_owned_dir(root.path)
    if not isinstance(fd, int):
        return fd is not None
    try:
        listing = _classify(fd, family)
        if listing.error is not None:
            return True
        return bool(listing.planted
                    or any(_ingest_loose(fd, name) for name in listing.ingest)
                    or any(_shaped_unsafe(fd, name) for name in listing.shaped))
    finally:
        os.close(fd)


def _ingest_loose(fd: int, name: str) -> bool:
    if _loose_at(fd, name):
        return True
    held = _held(fd, name)
    return held is None or any(stat.S_ISREG(st.st_mode)
                               and (st.st_mode & OPEN or (n in INGEST_FILES and st.st_nlink > 1))
                               for n, st in held)
