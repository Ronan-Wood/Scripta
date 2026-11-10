#!/usr/bin/env python3
"""The engine interpreter's pin — written on purpose, checked by `build-bundled-engine`.

    engine-interpreter-pin.py --write <interpreter-root> <pin-file>
    engine-interpreter-pin.py --check <tree> <interpreter-root> <pin-file>
    engine-interpreter-pin.py --relocate <tree> <interpreter-root>
    engine-interpreter-pin.py --recheck <tree> <interpreter-root> <pin-file>

Exit 0: done — the pin written, the copy matching it, or the copy relocated. 1: refused, and stderr
says why. 2: the check could not run.

WHY THIS EXISTS. The build copies whatever uv-managed CPython it finds into `runtime/`, signs it
with the Developer ID and gives `runtime/bin/python3.14` the allow-jit entitlement. The guards before
it establish WHERE the interpreter is (not a venv, under `uv python dir`); nothing established WHAT
it is. uv's store is a directory any process running as the build user can write, so a modified
interpreter would have shipped notarized.

WHY A MANIFEST AND NOT THE ARCHIVE CHECKSUM. uv keeps no record of the archive it extracted:
`uv python list --only-installed --output-format json` gives `"url": null`, and the install holds
only `BUILD`. A checksum of the archive would also prove nothing about the directory being copied,
which is the thing that can be changed. So the pin names every file of the installed tree with its
sha256 and every symlink with its target, and the check is EXACT: a file that is changed, missing or
added is refused, an added `.pth` in `site-packages` included. So is a mode a byte-for-byte check
cannot see — setuid, setgid, sticky, or writable by group or others — because `cp -p` carries it
into the signed bundle.

BYTECODE IS NOT PINNED, AND THE CHECKED TREE MAY HOLD NONE. The interpreter writes `.pyc` into its
own stdlib as it is used (measured: 532 of them, written over hours after the install), so they
cannot be pinned, and a `.pyc` with a valid header is imported instead of its verified `.py`. `--write`
skips them; both checks refuse any they find, because the build deletes them from its copy before
each check and compiles them once, after `--recheck`, from the sources it has just checked.

THE PIN IS PER INSTALL PATH. uv writes the absolute install prefix into
`lib/python3.*/_sysconfigdata_*.py` and into `libpython3.*.dylib`'s install name, re-signing it ad
hoc, so the same Python installed elsewhere hashes differently. The pin records its prefix and a
different one is refused by name before anything is hashed.

THE COPY IS THEN POINTED AT ITSELF. `_sysconfigdata` is where build tools look for `Python.h`: the
OpenCV source build reads `INCLUDEPY` from it, so a checked copy that still named the store would
compile against headers nobody checked. `--relocate` rewrites the store prefix to the copy's own
path wherever it stands as a whole path in a text file. It refuses if a text file still names the
store, or something in uv's directory or a climb through it (`_in_uv` and `_uv_reference` say
exactly what), if any `_sysconfigdata` was not rewritten, or if a binary other than a dylib names
the store. `--recheck` checks the copy again just before signing, with that one substitution
undone in text files and a text file that names the store again refused, so what `uv sync` and the
import checks left behind is seen. Signing rewrites every Mach-O, so it cannot come later. What it
does not cover: a process those steps left RUNNING, which can change the copy after any check, and
the render check that runs after signing.

RUNS ON `/usr/bin/python3`, NEVER ON THE INTERPRETER IT CHECKS. That is 3.9 here: no 3.10+ syntax at
runtime, no `hashlib.file_digest`.
"""

from __future__ import annotations

import errno
import fcntl
import hashlib
import os
import re
import stat
import sys
import tempfile
from pathlib import Path

PREFIX_KEY = "prefix"
SHOWN = 10
# setuid, setgid, sticky, group- or other-writable: none survives into a tree that ships.
UNSAFE_MODE = stat.S_ISUID | stat.S_ISGID | stat.S_ISVTX | stat.S_IWGRP | stat.S_IWOTH


class Refused(Exception):
    """The tree does not match the pin."""


class Broken(Exception):
    """The check could not run: the pin or the tree cannot be read, or cannot be checked as given."""


def _is_binary(data: bytes) -> bool:
    # ONE rule, used by `--relocate` to choose what it rewrites and by `--recheck` to choose what it
    # undoes: if they disagreed, a clean copy would be refused.
    return b"\0" in data


# The file build tools read headers from, at the top of the stdlib: `python3.14`, or `python3.14t`
# for a free-threaded build.
SYSCONFIG = re.compile(r"lib/python3\.\d+t?/_sysconfigdata_[^/]*\.py")

# `(copy path, store prefix, store names)`: what `--relocate` substituted, and how to see it undone.
Relocation = tuple[bytes, bytes, tuple[bytes, ...]]


def _store_names(prefix: str) -> tuple[bytes, ...]:
    """The store's own directory name (`cpython-3.14.7-macos-aarch64-none`) and uv's minor-version
    link beside it (`cpython-3.14-macos-aarch64-none`), which anyone who can write the store can
    repoint. `prefix` is already resolved: every caller resolves the store ONCE, so its names, its
    path and uv's directory cannot come from a store swapped between two lookups. Lower-cased,
    because macOS volumes are case-insensitive — ASCII case only; the names are ASCII, and a
    non-ASCII case-fold spelling is left to the hashes like any other.

    WHAT THE NAME TEST CATCHES, and no more: every spelling uv writes, which goes through one of the
    two names whatever symlinked directory lies above them, and the exact pinned prefix — the one
    spelling `--recheck`'s hash cannot see once the relocation is undone. A spelling through some
    other link is not caught by it. On `--relocate` that is safe because `--check` has just made
    every file exactly what uv wrote, and `relocate`'s look at uv's directory adds the spellings
    that go through it; on `--recheck` any other spelling changes a hash the check refuses. A name
    not in uv's shape gives no minor-version link to look for, so a spelling through it could not
    be seen: a broken check."""
    name = os.path.basename(prefix)
    minor, n = re.subn(r"^(cpython-\d+\.\d+)\.\d+(?:(?:a|b|rc)\d+)?(?=[+-])", r"\1", name)
    if n != 1:
        raise Broken(f"{name} is not the name uv gives a CPython install (cpython-X.Y.Z-...)")
    return tuple(sorted({name.lower().encode(), minor.lower().encode()}))


def _names_store(data: bytes, names: tuple[bytes, ...]) -> bool:
    lowered = data.lower()
    return any(name in lowered for name in names)


def _relocation(tree: Path, prefix: str) -> Relocation:
    """The `Relocation` for `tree` against the store at the resolved `prefix`. Refusing a copy whose
    own path holds a store name, or that sits inside uv's directory or is shaped like something in
    it: every relocated file would then read as naming the store or that directory, a tampering that
    never happened."""
    copy, names = os.path.realpath(tree).encode(), _store_names(prefix)
    if _names_store(copy, names):
        raise Broken(f"the copy at {copy.decode()} has the store's name in its own path")
    # Both sides lowered as BYTES, so a non-ASCII capital above uv's directory cannot make them
    # differ; and by its shape too, for a copy under some other `.../uv/python/<uv-shaped entry>/`.
    uv_dir = os.path.join(os.path.dirname(prefix), "").encode().lower()
    if (copy.lower() + b"/").startswith(uv_dir) or _in_uv(_uv_reference(prefix.encode()), copy):
        raise Broken(f"the copy at {copy.decode()} is inside uv's directory, or looks it")
    return copy, prefix.encode(), names


def _uv_reference(prefix: bytes) -> re.Pattern[bytes]:
    """Something IN uv's directory, by that directory's last two components (`/uv/python/`), so it
    is seen however the part above it is spelt — through a symlink, say. Followed by one of three:
    an install (`cpython-`, `pypy-`, ...), a dot entry (`.temp`, `..`), or any entry that a `..`
    then climbs out of. The third is there so that collapsing `entry/..` in `_in_uv` cannot erase a
    step through uv's directory: through an entry that is a symlink, the climb lands wherever it
    points. A `..` at the end, or followed by anything outside `[a-z0-9._~@+-]` once lower-cased, is
    read as a climb, so `..data`, `..Data` and `...` are names — and a rare name such as `..$x` is
    refused, which is the safe side.

    WHAT IT DOES NOT COVER: a plain `uv/python/<entry>/...` whose entry is neither uv-shaped nor
    climbed out of. Matching every entry would refuse a broad directory's ordinary mentions
    (`/usr/local/lib`) as tampering; such a reference in the copy is uv's own, pinned content."""
    parts = [p for p in os.path.dirname(prefix).lower().split(b"/") if p]
    if len(parts) < 2:
        raise Broken(f"uv's directory {os.path.dirname(prefix).decode()} is too short to be told apart")
    tail = b"/" + b"/".join(parts[-2:]) + b"/"
    # `_in_uv` steps per token, split at quotes and whitespace: a tail holding one could never be
    # seen whole inside a token once a `seg/..` before it had been collapsed.
    if re.search(rb"[\s'\"]", tail):
        raise Broken(f"uv's directory {os.path.dirname(prefix).decode()} has a space or quote in its last two parts")
    return re.compile(re.escape(tail) + rb"(?:[a-z]+-\d|\.|[^/'\"\s]+/\.\.(?![a-z0-9._~@+-]))")


_TOKEN = re.compile(rb"[^'\"\s]+")
_PAIR = re.compile(rb"/(?!\.\./)[^/'\"\s]+/\.\./")


def _in_uv(uv_ref: re.Pattern[bytes], data: bytes) -> bool:
    """Whether `data` names something in uv's directory, at ANY step of collapsing it. `//` and `/./`
    are collapsed first, being the same directory to the filesystem. Then `seg/..`, ONE pair per
    step, leftmost first, checking after each: that catches `uv/x/../python/...`. Leftmost first is
    the order a path resolves in, so each step leaves everything to its right as written and a
    reference is seen with what follows it. Collapsing every pair at once would not do, nor would
    checking only the end: collapsing `seg/..` is not what the filesystem does when `seg` is a
    symlink — uv's minor-version links are — and a later step can collapse away the entry that made
    an earlier one a reference: `uv/x/../python/<link>/../y` is `uv/python/<link>/../y` one step
    in, and `uv/python/y`, which no follower marks, the next.

    Stepped per path token — a run between quotes and whitespace. Neither a `seg/..` nor the tail
    `_uv_reference` looks for crosses one (it refuses a tail that could), so this is the same as
    stepping the whole text, at a cost bounded by each token rather than the file. WHAT IT DOES NOT
    COVER: a `seg` holding a space or quote is never collapsed, so `uv/a b/../python/...` is not
    seen. Such a spelling in the copy is uv's own, pinned content, like the rest of what this reads."""
    light = re.sub(rb"/(?:\./)+", b"/", re.sub(rb"/{2,}", b"/", data.lower()))
    if uv_ref.search(light):
        return True
    for token in _TOKEN.findall(light):
        if b"/../" not in token:
            continue
        while True:
            collapsed = _PAIR.sub(b"/", token, count=1)
            if collapsed == token:
                break
            token = collapsed
            if uv_ref.search(token):
                return True
    return False


def _digest(path: Path, relocated: Relocation | None) -> tuple[str, bool]:
    """`(sha256, names the store)`. With `relocated`, for `--recheck`, a TEXT file is hashed with
    `--relocate`'s substitution undone, and reports whether it names the store again, which matters
    only for the pinned prefix (see `_store_names`). A binary is hashed as it is, because
    `--relocate` never rewrites one."""
    if relocated is None:
        h = hashlib.sha256()
        with path.open("rb") as f:
            for block in iter(lambda: f.read(1 << 20), b""):
                h.update(block)
        return h.hexdigest(), False
    # Whole-file, because the substitution can straddle a block boundary. The largest file is the
    # 18 MB interpreter, read once.
    data = path.read_bytes()
    if _is_binary(data):
        return hashlib.sha256(data).hexdigest(), False
    copy, store, names = relocated
    return hashlib.sha256(data.replace(copy, store)).hexdigest(), _names_store(data, names)


def _is_bytecode(rel: str) -> bool:
    return rel.endswith(".pyc") or "__pycache__" in rel.split("/")


def _shown(rels: list[str]) -> str:
    more = f" (+{len(rels) - SHOWN} more)" if len(rels) > SHOWN else ""
    return ", ".join(rels[:SHOWN]) + more


def _unreadable(error: OSError) -> None:
    # `os.walk` drops a directory it cannot list unless told otherwise, and a check that has not read
    # a directory has not checked it — on `--recheck`, which allows missing files, it would pass.
    raise Broken(f"cannot read {error.filename}: {error.strerror}")


def _spellable(rel: str) -> bool:
    # The pin is ASCII, one entry per line, tab-separated: a name with a control character or a
    # non-ASCII one would be written into a pin that every later check reads as broken.
    return all(32 <= ord(c) < 127 for c in rel)


def scan(root: Path, *, checking: bool, relocated: Relocation | None = None) -> dict[str, tuple[str, str]]:
    """`{relative path: (kind, value)}` for every file ("f", sha256) and symlink ("l", target).

    `checking` is False for `--write`, which reads uv's store, and True for both checks, which read
    a copy the build has just cleaned. Bytecode is skipped when writing and refused when checking. A
    name or link target no pin can spell is a broken `--write`, and a refusal when checking: no pin
    names it, so it was added. `relocated` is for `--recheck`, as `_digest` says. Directories are
    not entries, but their modes are checked, the root's included; symlinks are never followed, so a
    symlinked directory is one entry and its contents are not walked.
    """
    root_mode = root.lstat().st_mode
    if not stat.S_ISDIR(root_mode):
        raise Broken(f"{root} is not a directory")
    entries: dict[str, tuple[str, str]] = {}
    found: list[str] = []
    unsafe: list[str] = [f". ({stat.filemode(root_mode)})"] if root_mode & UNSAFE_MODE else []
    names_store: list[str] = []
    unspellable: list[str] = []
    for dirpath, dirnames, filenames in os.walk(root, onerror=_unreadable, followlinks=False):
        base = Path(dirpath)
        for name in dirnames + filenames:
            path = base / name
            rel = path.relative_to(root).as_posix()
            if not _spellable(rel):
                if not checking:
                    raise Broken(f"a path the pin cannot spell: {rel!r}")
                unspellable.append(repr(rel))
                if name in dirnames:
                    dirnames.remove(name)  # one entry for it, not one per thing inside
                continue
            mode = path.lstat().st_mode
            if _is_bytecode(rel):
                if checking:
                    found.append(rel)
                if name in dirnames:
                    dirnames.remove(name)
                continue
            if stat.S_ISLNK(mode):
                target = os.readlink(path)
                if not _spellable(target):
                    if not checking:
                        raise Broken(f"a link target the pin cannot spell: {rel} -> {target!r}")
                    unspellable.append(f"{rel} -> {target!r}")
                entries[rel] = ("l", target)
                continue
            if mode & UNSAFE_MODE:
                unsafe.append(f"{rel} ({stat.filemode(mode)})")
            if stat.S_ISREG(mode):
                digest, again = _digest(path, relocated)
                entries[rel] = ("f", digest)
                if again:
                    names_store.append(rel)
            elif not stat.S_ISDIR(mode):
                raise Refused(f"{rel} is neither a file, a directory nor a symlink")
    if unspellable:
        raise Refused(
            f"{len(unspellable)} names in the copy no pin can spell, so none describes them: "
            + _shown(sorted(unspellable))
        )
    if found:
        raise Refused(
            f"{len(found)} bytecode entries are in the checked tree, which must hold none "
            f"(the build deletes them before checking): " + _shown(sorted(found))
        )
    if unsafe:
        raise Refused(
            f"{len(unsafe)} entries are setuid, setgid, sticky or writable by group or others, and "
            "would ship that way: " + _shown(sorted(unsafe))
        )
    if names_store:
        raise Refused(
            f"{len(names_store)} files of the copy name the uv store again after --relocate pointed them "
            "at the copy, so build tools could have read the store: " + _shown(sorted(names_store))
        )
    return entries


def render(prefix: str, entries: dict[str, tuple[str, str]], python: str, build: str) -> str:
    lines = [
        "# The engine interpreter, file by file. Written by tools/engine-interpreter-pin.py --write and",
        "# checked by tools/build-bundled-engine; re-pin only as the engine's RELEASING.md describes.",
        f"# python {python}, python-build-standalone {build}",
        f"{PREFIX_KEY}\t{prefix}",
    ]
    lines += [f"{kind}\t{value}\t{rel}" for rel, (kind, value) in sorted(entries.items())]
    return "\n".join(lines) + "\n"


def parse(text: str) -> tuple[str, dict[str, tuple[str, str]]]:
    prefix = None
    entries: dict[str, tuple[str, str]] = {}
    for n, line in enumerate(text.split("\n"), 1):
        # A checkout that converted line endings; no name in a pin can hold a `\r`.
        if line.endswith("\r"):
            line = line[:-1]
        if not line or line.startswith("#"):
            continue
        fields = line.split("\t")
        if len(fields) == 2 and fields[0] == PREFIX_KEY and prefix is None:
            prefix = fields[1]
        elif len(fields) == 3 and fields[0] in ("f", "l") and fields[2] not in entries:
            kind, value, rel = fields
            if kind == "f" and (len(value) != 64 or value.strip("0123456789abcdef")):
                raise Broken(f"pin line {n}: not a sha256")
            entries[rel] = (kind, value)
        else:
            raise Broken(f"pin line {n} is not 'prefix<TAB>path' or '<f|l><TAB>value<TAB>path', or repeats one")
    if prefix is None:
        raise Broken("the pin names no prefix")
    if not entries:
        raise Broken("the pin names no files")
    return prefix, entries


def _read_pin(pin: Path) -> tuple[str, dict[str, tuple[str, str]]]:
    try:
        return parse(pin.read_bytes().decode("ascii"))
    except OSError as e:
        raise Broken(f"cannot read the pin {pin}: {e}") from e
    except UnicodeDecodeError as e:
        raise Broken(f"the pin {pin} is not ASCII: {e}") from e


def _python_version(root: Path) -> str:
    for header in sorted(root.glob("include/python3.*/patchlevel.h")):
        for line in header.read_text().splitlines():
            if line.startswith("#define PY_VERSION ") and '"' in line:
                return line.split('"')[1]
    raise Broken(f"{root} has no include/python3.*/patchlevel.h to read a version from")


def write(root: Path, pin: Path) -> None:
    root = Path(os.path.realpath(root))
    if not (root / "bin").is_dir() or (root / "pyvenv.cfg").exists():
        raise Broken(f"{root} is not a standalone interpreter")
    build_file = root / "BUILD"
    build = build_file.read_text().strip() if build_file.is_file() else "unknown"
    if not _spellable(str(root)):
        raise Broken(f"{root!r} cannot be spelt in an ASCII pin")
    entries = scan(root, checking=False)
    # ENCODED BEFORE ANYTHING IS OPENED, and renamed into place: `write_text` truncates the pin it
    # replaces and only then finds out a field cannot be encoded.
    try:
        body = render(str(root), entries, _python_version(root), build).encode("ascii")
    except UnicodeEncodeError as e:
        raise Broken(f"the pin for {root} cannot be written in ASCII: {e}") from e
    # `mkstemp`: a fresh name, created exclusively, so nothing already at it — a symlink — is written
    # through, and its mode set on the descriptor rather than by name. Removed on any failure, so
    # nothing is left beside the pin for `git add` to find.
    fd, staged = tempfile.mkstemp(dir=str(pin.parent), prefix=pin.name + ".", suffix=".tmp")
    try:
        try:
            os.fchmod(fd, 0o644)
            view = memoryview(body)
            while view:
                view = view[os.write(fd, view):]
            _sync(fd)
        finally:
            os.close(fd)
        os.replace(staged, pin)
    except BaseException:
        if os.path.lexists(staged):
            os.unlink(staged)
        raise
    # THE DIRECTORY TOO, or the rename can be lost and leave the old pin. BEST EFFORT, after the
    # rename: the pin is already in place, so a filesystem that refuses to sync a directory must not
    # report a write that happened as one that failed. A re-pin is reviewed in git either way.
    try:
        dir_fd = os.open(str(pin.parent), os.O_RDONLY)
        try:
            _sync(dir_fd)
        finally:
            os.close(dir_fd)
    except OSError as e:
        print(f"engine-interpreter-pin: warning: the pin is written, but its directory did not sync: {e}",
              file=sys.stderr)
    print(f"pinned {len(entries)} entries of {root} into {pin}")


_UNSUPPORTED = {errno.ENOTSUP, errno.EOPNOTSUPP, errno.EINVAL, errno.ENOTTY, errno.ENOSYS}


def _sync(fd: int) -> None:
    # `fsync` on macOS leaves the data in the drive's cache; `F_FULLFSYNC` is what reaches the disk.
    # Only a filesystem that does not take it falls back to `fsync`; a real failure — EIO — is
    # raised, because `fsync` after it may succeed on data that never reached the disk.
    if hasattr(fcntl, "F_FULLFSYNC"):
        try:
            fcntl.fcntl(fd, fcntl.F_FULLFSYNC)
            return
        except OSError as e:
            if e.errno not in _UNSUPPORTED:
                raise
    os.fsync(fd)


def _compare(tree: Path, root: Path, pin: Path, *, recheck: bool) -> None:
    pinned_prefix, pinned = _read_pin(pin)
    root_s = os.path.realpath(root)
    if pinned_prefix != root_s:
        raise Refused(
            f"the engine interpreter is {root_s}, but {pin.name} was made for {pinned_prefix}. "
            "A Python update, or a uv store somewhere else, needs a new pin; "
            "the engine's RELEASING.md says how"
        )
    relocated = _relocation(tree, root_s) if recheck else None
    actual = scan(tree, checking=True, relocated=relocated)
    changed = sorted(rel for rel in pinned.keys() & actual.keys() if pinned[rel] != actual[rel])
    # MISSING IS ALLOWED ON THE RECHECK, because the slimming step deletes pinned files (the GUI, the
    # installer, the headers) between the two checks. A deletion adds no code to the copy.
    missing = [] if recheck else sorted(pinned.keys() - actual.keys())
    unexpected = sorted(actual.keys() - pinned.keys())
    if changed or missing or unexpected:
        detail = "".join(
            f"\n  {label}: " + _shown(rels)
            for label, rels in (("changed", changed), ("missing", missing), ("unexpected", unexpected))
            if rels
        )
        when = "after the build ran it" if recheck else "before the build ran it"
        raise Refused(
            f"the copy of {root_s} does not match {pin.name} {when}: {len(changed)} changed, "
            f"{len(missing)} missing, {len(unexpected)} unexpected.{detail}\n"
            "If this is a deliberate Python update, re-pin as the engine's RELEASING.md describes. If it "
            "is not, the interpreter was modified after uv installed it: run "
            "`uv python install --reinstall <version>` and build again."
        )


# WHERE A PATH STARTS AND ENDS, as measured on `_sysconfigdata`, the one text file uv writes the
# store into: each of its 29 store paths follows a quote, a space or a tab, and is followed by `/`,
# a quote or whitespace. Nothing else is trusted. A store prefix anywhere else — `/tmp/evil<store>`,
# `-I<store>`, `<store>-debug` — is part of some other path, is left as it is, and is then refused
# for still naming the store. So is one whose path goes on to climb out of the copy once rewritten:
# a `..` component anywhere in it, or the `//` and `/./` a `..` could hide behind.
_PATH_START = (b"'", b'"', b" ", b"\t")
_PATH_END = re.compile(rb"[/'\"\s]")
_PATH_REST = re.compile(rb"[^'\"\s]*")
_LEAVES = re.compile(rb"/\.\.(?:/|$)|//|/\./")


def _rewrite(data: bytes, old: bytes, new: bytes) -> bytes:
    out, last, i = [], 0, data.find(old)
    while i != -1:
        j = i + len(old)
        starts = i == 0 or data.endswith(_PATH_START, 0, i)
        ends = j == len(data) or _PATH_END.match(data, j) is not None
        rest = _PATH_REST.match(data, j).group()
        if starts and ends and not _LEAVES.search(rest):
            out += [data[last:i], new]
            last = j
        i = data.find(old, j)
    return b"".join(out) + data[last:]


def relocate(tree: Path, root: Path) -> None:
    """Point every text file of the checked copy that names the store at the copy instead."""
    prefix = os.path.realpath(root)
    new, old, names = _relocation(tree, prefix)
    uv_ref = _uv_reference(old)
    rewritten, sysconfigs, still, refused = [], [], [], []
    for dirpath, _dirnames, filenames in os.walk(tree, onerror=_unreadable, followlinks=False):
        for name in filenames:
            path = Path(dirpath) / name
            if path.is_symlink() or not path.is_file():
                continue
            rel = path.relative_to(tree).as_posix()
            if SYSCONFIG.fullmatch(rel):
                sysconfigs.append(rel)
            data = path.read_bytes()
            if _is_binary(data):
                # A Mach-O's own install name, which nothing loads by. The build's link check refuses
                # any binary that LINKS to a path outside the bundle.
                if _names_store(data, names):
                    still.append(rel)
                continue
            relocated = _rewrite(data, old, new)
            if _names_store(relocated, names) or _in_uv(uv_ref, relocated):
                refused.append(rel)
            elif relocated != data:
                path.write_bytes(relocated)
                rewritten.append(rel)
    if refused:
        raise Refused(
            f"text files name uv's store or its directory other than as {prefix} "
            f"standing as a whole path, so they cannot be pointed at the copy: {_shown(sorted(refused))}"
        )
    unrewritten = sorted(set(sysconfigs) - set(rewritten))
    if not sysconfigs or unrewritten:
        # `_sysconfigdata` is the file build tools read headers from, and uv writes the store into
        # each one: one that does not name the store names some other place they would read.
        raise Refused(
            f"the copy's _sysconfigdata does not name {prefix}, so it cannot be "
            f"pointed at itself: {', '.join(unrewritten) or 'there is none'}"
        )
    foreign = [rel for rel in still if not rel.endswith(".dylib")]
    if foreign:
        raise Refused(f"binaries other than dylibs name the uv store, so build tools could read it: {_shown(foreign)}")
    print(f"  pointed {', '.join(rewritten)} at the copy")


def main(argv: list[str]) -> int:
    try:
        if len(argv) == 3 and argv[0] == "--write":
            write(Path(argv[1]), Path(argv[2]))
        elif len(argv) == 4 and argv[0] in ("--check", "--recheck"):
            _compare(Path(argv[1]), Path(argv[2]), Path(argv[3]), recheck=argv[0] == "--recheck")
        elif len(argv) == 3 and argv[0] == "--relocate":
            relocate(Path(argv[1]), Path(argv[2]))
        else:
            print(__doc__.split("\n\n", 2)[1], file=sys.stderr)
            return 2
    except Refused as e:
        print(f"engine-interpreter-pin: {e}", file=sys.stderr)
        return 1
    # EVERYTHING ELSE IS A BROKEN CHECK, never a refusal. An uncaught exception exits 1, which the
    # build reads as "this interpreter was tampered with" and answers with the wrong remedy.
    except Exception as e:
        print(f"engine-interpreter-pin: the check itself failed: {type(e).__name__}: {e}", file=sys.stderr)
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
