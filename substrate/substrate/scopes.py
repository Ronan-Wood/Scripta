"""The scope registry — a scope name to the vault it composes and the index it composed into.

Doc 3a §3 makes scope a PARAMETER: one server serves every scope and the caller names the one it
wants. The manifest (Doc 2 §2) already answers which VAULTS a scope composes. Nothing answered
where that scope's composed INDEX lives — `compose` took it as a flag, and the mapping survived
only as prose in a handoff document. This module is that mapping as data, so both adapters read
one definition rather than each inventing a filename convention.

**Written by `compose`, on success.** So "what scopes exist" means "what has actually been
composed", and a scope cannot be named before its index is built. That is the honest failure
direction: a registry that could name an unbuilt index would hand a caller a scope that answers
every query with nothing, which is indistinguishable from a scope whose content does not cover
the question.

**Machine-local and disposable.** It points at index databases — the layer Doc 2 §5 says to keep
off cloud-sync and rebuild per machine. Deleting it loses nothing that recomposing does not
rewrite, which is why it lives beside the user's other machine state rather than in a vault.

**Paths are stored absolute.** An MCP server is launched by a client whose working directory is
arbitrary, so a relative `db` would resolve against the wrong root — missing the index, or worse,
finding a different one. `vault._resolve_inherit` applies the same rule to inheritance for the
same reason: composition must not depend on where the process happens to be standing.
"""

from __future__ import annotations

import os
import re
import tempfile
import tomllib
from contextlib import contextmanager
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path

try:
    import fcntl
except ImportError:  # non-POSIX; the lock degrades, the write does not
    fcntl = None

DEFAULT_REGISTRY = Path.home() / ".substrate" / "scopes.toml"
ENV_VAR = "SUBSTRATE_REGISTRY"

# A TOML bare key. Anything else is written as a quoted key — a scope name is the manifest's
# `name`, which Doc 2 does not constrain, and an unquoted dot would silently NEST the table
# rather than name it.
_BARE_KEY = re.compile(r"[A-Za-z0-9_-]+")


class ScopeError(RuntimeError):
    """A scope is not registered, its registry is malformed, or its index has gone missing."""


@contextmanager
def _exclusive(registry: Path):
    """Hold an exclusive lock across a whole read-modify-write of the registry.

    `record` reads the file, adds one entry, and writes the WHOLE thing back. An atomic replace
    makes each write all-or-nothing but does nothing about two composes interleaving: both read
    the old registry, both write a full snapshot, and the second silently drops the first's scope.
    Composing several vaults in a shell loop is the obvious way to hit it, and the loss is
    invisible — the scope simply is not there later.

    The lock file is separate from the registry because the registry is replaced by rename, which
    would drop a lock held on the old inode. `fcntl` is POSIX; where it is absent the write still
    happens (a missing lock must not stop a single-process compose from registering) and the
    concurrent case degrades to the behaviour described above.
    """
    lock_path = registry.parent / f".{registry.name}.lock"
    if fcntl is None:
        yield
        return
    with open(lock_path, "w") as fh:
        fcntl.flock(fh, fcntl.LOCK_EX)
        try:
            yield
        finally:
            fcntl.flock(fh, fcntl.LOCK_UN)


@dataclass(frozen=True)
class ScopeEntry:
    """One composed scope. `vault` is the project vault composed; `db` the index it composed into;
    `index_root` the disposable per-note ingest tree; `composed` when that happened."""

    name: str
    vault: Path
    db: Path
    index_root: Path | None    # None when the registry entry predates the field
    composed: str


def registry_path(explicit: str | Path | None = None) -> Path:
    """Where the registry lives: an explicit path, else $SUBSTRATE_REGISTRY, else the default.

    The env var exists so a client launch config and a test can each point at their own registry
    without a flag — an MCP server is started by a client that may not let the user pass one.
    """
    if explicit is not None:
        return Path(explicit).expanduser()
    env = os.environ.get(ENV_VAR)
    if env:
        return Path(env).expanduser()
    return DEFAULT_REGISTRY


def _quote(value: str) -> str:
    """A TOML basic string. Backslash first (it is the escape character), then the quote, then
    anything unprintable — a path may legally contain all three, and a hand-rolled writer that
    ignores them produces a file that will not parse back."""
    out = value.replace("\\", "\\\\").replace('"', '\\"')
    out = "".join(c if c >= " " and c != "\x7f" else f"\\u{ord(c):04x}" for c in out)
    return f'"{out}"'


def _key(name: str) -> str:
    return name if _BARE_KEY.fullmatch(name) else _quote(name)


def load(registry: str | Path | None = None) -> dict[str, ScopeEntry]:
    """Every registered scope, by name. An absent registry is an empty one, not an error — no
    scope has been composed yet, which is a state, not a fault.

    A malformed or structurally-wrong registry DOES raise: silently treating it as empty would
    report "no scopes exist" over a file that names several, and the caller would conclude the
    vaults were never composed.
    """
    path = registry_path(registry)
    if not path.is_file():
        return {}
    try:
        data = tomllib.loads(path.read_text("utf-8"))
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as e:
        raise ScopeError(f"cannot read scope registry {path}: {e}") from e

    scopes = data.get("scopes", {})
    if not isinstance(scopes, dict):
        raise ScopeError(f"{path}: 'scopes' must be a table of scope entries.")

    out: dict[str, ScopeEntry] = {}
    for name, row in scopes.items():
        if not isinstance(row, dict):
            raise ScopeError(f"{path}: scope {name!r} is not a table.")
        missing = [k for k in ("vault", "db") if not isinstance(row.get(k), str)]
        if missing:
            raise ScopeError(f"{path}: scope {name!r} is missing {missing}.")
        out[name] = ScopeEntry(
            name=name,
            vault=Path(row["vault"]),
            db=Path(row["db"]),
            # An ABSENT index_root stays None. Defaulting it to Path("") stringifies as "." and
            # the ingest hint then told the user to write the disposable index tree into whatever
            # directory they happened to be standing in.
            index_root=Path(row["index_root"]) if row.get("index_root") else None,
            # Coerced, not assumed: a TOML datetime is valid TOML and what a hand-edit naturally
            # produces, and a non-str here breaks json.dumps for every list_scopes and status.
            composed=str(row.get("composed", "") or ""),
        )
    return out


def record(
    name: str,
    *,
    vault: Path,
    db: Path,
    index_root: Path,
    registry: str | Path | None = None,
) -> Path:
    """Register (or refresh) one scope. Returns the registry path written.

    Refuses to repoint an existing name at a DIFFERENT vault. Two vaults declaring one manifest
    name would otherwise make the first silently unreachable and send its queries to the second —
    a well-formed answer from the wrong source set, which is the failure `resolve_scope` already
    refuses at the doc_id level. Recomposing the same vault (to a new db, or just again) updates.

    The whole read-modify-write is serialized under a lock, and the write itself is atomic. Those
    are two different guarantees for two different failures: the atomic replace stops a crash
    leaving a truncated registry that `load` then reports as malformed for EVERY scope, and the
    lock stops two concurrent composes each writing a full snapshot, where the second silently
    drops the first's entry.
    """
    # A scope name becomes the first segment of every `expand_ref` this scope issues, so a name
    # containing the ref separator produces handles that parse back to a DIFFERENT scope — one
    # that either does not exist or, worse, does. Refused at registration, where the manifest can
    # still be fixed, rather than discovered when a ref fails to round-trip.
    from substrate.render import REF_SEP  # lazy: keeps this module free of the retrieval stack

    if not name or REF_SEP in name or name.strip() != name:
        raise ScopeError(
            f"scope name {name!r} is unusable: it must be non-empty, carry no {REF_SEP!r}, and "
            f"have no leading or trailing whitespace. Fix the vault manifest's `name`."
        )
    path = registry_path(registry)
    vault, db, index_root = (p.expanduser().resolve() for p in (vault, db, index_root))
    path.parent.mkdir(parents=True, exist_ok=True)

    with _exclusive(path):
        return _record_locked(path, name, vault=vault, db=db, index_root=index_root)


def _record_locked(path: Path, name: str, *, vault: Path, db: Path, index_root: Path) -> Path:
    """The read-modify-write itself. Called only with the registry lock held."""
    existing = load(path)
    prior = existing.get(name)
    if prior is not None and prior.vault != vault:
        raise ScopeError(
            f"scope {name!r} is already registered to {prior.vault}, but this compose was of "
            f"{vault}. Two vaults declaring one manifest name would make the first unreachable "
            f"and answer its queries from the second. Rename one vault's `name`, or remove the "
            f"stale entry from {path}."
        )

    existing[name] = ScopeEntry(
        name=name, vault=vault, db=db, index_root=index_root,
        composed=datetime.now(UTC).isoformat(timespec="seconds"),
    )

    lines = [
        "# Composed scopes, written by `substrate compose`.",
        "#",
        "# Machine-local: these point at index databases on THIS machine. Safe to delete —",
        "# recomposing rewrites it. Paths are absolute so a client-launched server resolves",
        "# them regardless of its working directory.",
        "",
        "version = 1",
    ]
    for e in sorted(existing.values(), key=lambda x: x.name):
        lines += [
            "",
            f"[scopes.{_key(e.name)}]",
            f"vault = {_quote(str(e.vault))}",
            f"db = {_quote(str(e.db))}",
            f"index_root = {_quote(str(e.index_root))}",
            f"composed = {_quote(e.composed)}",
        ]
    body = "\n".join(lines) + "\n"

    # A unique staging name, so nothing is shared even if the lock is unavailable (non-POSIX).
    fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".scopes-", suffix=".toml")
    try:
        with os.fdopen(fd, "w", encoding="utf-8") as fh:
            fh.write(body)
        os.replace(tmp_name, path)
    except OSError:
        Path(tmp_name).unlink(missing_ok=True)
        raise
    return path


def resolve(name: str, registry: str | Path | None = None) -> ScopeEntry:
    """One scope by name, or ScopeError. Doc 3a §3: scope resolution failure HARD-FAILS.

    Both refusals name what is available, because the alternative to a loud failure here is a
    caller that quietly queries the wrong index — or an empty one — and reads the result as an
    answer. A registered index that has since been deleted is refused for the same reason: an
    IndexStore would happily create an empty database at that path and answer every query with
    nothing.
    """
    known = load(registry)
    entry = known.get(name)
    if entry is None:
        avail = ", ".join(sorted(known)) or "none — run `substrate compose` first"
        raise ScopeError(f"unknown scope {name!r}. Registered: {avail}.")
    if not entry.db.is_file():
        raise ScopeError(
            f"scope {name!r} is registered to {entry.db}, which does not exist. Recompose it "
            f"rather than query an index that would be created empty."
        )
    return entry
