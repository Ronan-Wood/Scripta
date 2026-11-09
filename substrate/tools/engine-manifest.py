#!/usr/bin/env python3
"""Write `engine-manifest.json` at an engine root: what the engine there is and what a client may
run.

    engine-manifest.py <engine-root> [--commit <sha>]

A client used to work this out by looking for the engine's source files (`substrate/refresh.py`
meant `substrate serve` refreshes). That ties every client to this tree's layout. With the
manifest, the engine states it, and is free to rename its files.

    {"version": "0.1.0", "commit": "<sha>" or null, "wire": 1,
     "features": ["serve", "refresh", "connect-unix"]}

- `version`: `[project] version` in the root's `pyproject.toml`.
- `commit`: the commit whose engine tree this root is, or null when it is no commit's: a bundle
  built from an edited tree.
- `wire`: `VERSION` in the root's `substrate/wire.py`, the wire its socket speaks.
- `features`: what a client may run here, by name. A client ignores a name it does not know.
  - `serve`: `substrate-mcp --socket PATH` answers on the socket.
  - `refresh`: `substrate serve --socket PATH` answers on it and keeps every scope current.
  - `connect-unix`: `substrate-mcp --connect PATH` bridges stdio to that socket.

Run by `tools/build-bundled-engine` on the tree it ships, and by `tools/substrate-deploy` on the
commit it exports. The deploy runs that commit's own copy of this file, so an older commit states
only what it has, and a commit from before this file states nothing.

READ, NOT IMPORTED, and stdlib only on Python 3.9: the bundle build runs this with
`/usr/bin/python3`, beside an interpreter it has not finished checking. A value it cannot read in
the one plain form below is refused rather than guessed.
"""

from __future__ import annotations

import json
import os
import re
import sys
from pathlib import Path

NAME = "engine-manifest.json"
FEATURES = ("serve", "refresh", "connect-unix")

_TABLE = re.compile(r"^\s*\[\s*([^\]]+?)\s*\]\s*(#.*)?$")
_VERSION = re.compile(r'^version\s*=\s*"([^"\\]+)"\s*(#.*)?$')
_WIRE = re.compile(r"^VERSION = ([1-9][0-9]*)\s*(#.*)?$")
_COMMIT = re.compile(r"[0-9a-f]{40}|[0-9a-f]{64}")


class Refused(Exception):
    pass


def _lines(path: Path) -> list[str]:
    try:
        return path.read_text(encoding="utf-8").splitlines()
    except (OSError, UnicodeDecodeError) as e:
        raise Refused(f"cannot read {path}: {e}") from e


def project_version(root: Path) -> str:
    """`[project] version`, written as one plain double-quoted string."""
    table, found = None, []
    for line in _lines(root / "pyproject.toml"):
        header = _TABLE.match(line)
        if header:
            table = header.group(1)
        elif table == "project" and re.match(r"\s*version\s*=", line):
            m = _VERSION.match(line.strip())
            if not m:
                raise Refused(f"pyproject.toml's version is not one plain string: {line.strip()!r}")
            found.append(m.group(1))
    if len(found) != 1:
        raise Refused(f"pyproject.toml has {len(found)} [project] versions, not one")
    return found[0]


def wire_version(root: Path) -> int:
    """`VERSION = <n>` in `substrate/wire.py`, at the start of a line, exactly once."""
    found = [int(m.group(1)) for m in map(_WIRE.match, _lines(root / "substrate" / "wire.py")) if m]
    if len(found) != 1:
        raise Refused(f"substrate/wire.py has {len(found)} plain `VERSION = <n>` lines, not one")
    return found[0]


def manifest(root: Path, commit: str | None) -> dict:
    if commit is not None and not _COMMIT.fullmatch(commit):
        raise Refused(f"{commit!r} is not a full commit id")
    return {"version": project_version(root), "commit": commit, "wire": wire_version(root),
            "features": list(FEATURES)}


def write(root: Path, commit: str | None) -> Path:
    """Written in place: both callers write into a stage no client reads until it is moved."""
    path = root / NAME
    path.write_text(json.dumps(manifest(root, commit), indent=2) + "\n", encoding="utf-8")
    os.chmod(path, 0o644)
    return path


def main(argv: list[str]) -> int:
    args, commit = list(argv), None
    if "--commit" in args:
        at = args.index("--commit")
        if at + 1 >= len(args):
            print("engine-manifest: --commit needs a commit id", file=sys.stderr)
            return 2
        commit = args[at + 1] or None
        del args[at:at + 2]
    if len(args) != 1 or args[0].startswith("-"):
        print("usage: engine-manifest.py <engine-root> [--commit <sha>]", file=sys.stderr)
        return 2
    root = Path(args[0])
    if not root.is_dir():
        print(f"engine-manifest: {root} is not a directory", file=sys.stderr)
        return 2
    try:
        write(root, commit)
    except Refused as e:
        print(f"engine-manifest: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv[1:]))
