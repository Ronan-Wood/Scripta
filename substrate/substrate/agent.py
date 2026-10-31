"""Agent mode — a scope served to ANOTHER macOS user, from a copy that user cannot write.

WHY. A second account (`prism-agent`) runs its own agents and should be able to ask the operator's
`prism` scope questions — and nothing else. It cannot reach the operator's home folder, so it cannot
read the registry, the live index, or a single vault note, and it must not be able to: the registry
names every scope, and the vaults hold all of them.

WHY A SNAPSHOT RATHER THAN THE LIVE INDEX. The live index is a WAL-mode SQLite file, and a WAL
reader is not read-only — it creates `-shm`/`-wal` beside the database, so a user who cannot write
that directory cannot open it at all, and one who could would be writing into the operator's index.
So the operator's own engine PUBLISHES: after a refresh of an allowed scope succeeds it writes
`<scope>.snapshot.db` with `VACUUM INTO` into a shared folder, plus a small manifest, and the agent
opens that file `immutable=1` (`IndexStore(immutable=True)`), touching nothing beside it.

THE SNAPSHOT CARRIES WHAT THE AGENT CANNOT FETCH. The index holds passages, not notes — `expand
mode=note` reads the note from the vault — so the publisher adds a `snapshot_notes` table with every
note's text as it stood at publish time. It also strips what would leak the operator's layout
(absolute source paths become vault-relative) and what is not the agent's to see: a vault that
declares a `guard` has its own notes REMOVED, not filtered, because a copy cannot check a heartbeat
and the guard fails closed (`guard.py`).

THE ENFORCEMENT IS SERVER-SIDE. `--scopes` is the whole world in agent mode: any other name gets
the same fixed "scope not available", which names nothing, so the error cannot be used to list what
else exists. A snapshot path is built from an allowed name only — never from a caller's argument —
so there is no path for a `../` to travel into.
"""

from __future__ import annotations

import hashlib
import json
import os
import re
import sqlite3
import stat
import tempfile
import tomllib
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Iterable

from substrate import guard, refresh_state, scopes

SNAPSHOT_SUFFIX = ".snapshot.db"
MANIFEST_SUFFIX = ".snapshot.json"
MANIFEST_VERSION = 1
CONFIG_FILENAME = "agent-publish.toml"

# Older than this and the snapshot says so on every answer. A day: the in-app refresh runs only
# while Scripta is open (substrate/CLAUDE.md), so an older copy means nobody has refreshed, and the
# agent's reader should know that rather than assume it.
DEFAULT_MAX_AGE_SECONDS = 24 * 3600

# Readable by the folder's GROUP, never by every local user. Files created in a directory take its
# group on macOS, so the operator decides who reads the snapshot by owning the folder and setting
# its group — this code never chmods the folder itself.
FILE_MODE = 0o640

# ONE string for every refusal of a name outside `--scopes`, and it names nothing. An error that
# said "unknown scope 'x'; registered: cbre, school, …" is how the registry's own refusal reads,
# and in agent mode that sentence is the leak.
UNAVAILABLE = "scope not available"

# The size bound `expand` and `ingest` put on one note, applied to every note a snapshot copies.
MAX_NOTE_BYTES = 8 * 1024 * 1024

_SCOPE_NAME = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}")

_SNAPSHOT_DDL = """
CREATE TABLE snapshot_meta(key TEXT PRIMARY KEY, value TEXT);
CREATE TABLE snapshot_notes(
    doc_id TEXT PRIMARY KEY,
    -- vault-relative: `<vault>/<path within it>`, never the operator's absolute path.
    path   TEXT NOT NULL,
    text   TEXT NOT NULL,
    -- 0 when the note matched the index at publish time; NULL when it declares a checksum and the
    -- match cannot be judged. A note that had moved on is never here: it is excluded.
    stale  INTEGER
);
"""


class AgentError(RuntimeError):
    """A condition the caller can act on. Messages name only the scope that was asked for."""


def valid_scope_name(name: object) -> bool:
    return isinstance(name, str) and _SCOPE_NAME.fullmatch(name) is not None


def snapshot_paths(directory: Path, scope: str) -> tuple[Path, Path]:
    if not valid_scope_name(scope):
        raise AgentError(UNAVAILABLE)
    return directory / f"{scope}{SNAPSHOT_SUFFIX}", directory / f"{scope}{MANIFEST_SUFFIX}"


def _now() -> datetime:
    return datetime.now(UTC)


def _stamp(t: datetime) -> str:
    return t.isoformat(timespec="seconds")


def _read_manifest(path: Path) -> tuple[dict | None, str | None]:
    """The manifest, or `(None, reason)`. Bounded and fstat'd like the refresh record, because it
    is parsed on every agent call and echoed into the envelope."""
    from substrate.freshness import read_bounded

    if not path.is_file():
        return None, None
    try:
        # NOFOLLOW: the folder is shared, and a manifest planted as a symlink would otherwise have
        # the operator's publisher read a file of the operator's (`annotate` rewrites what it
        # read) into a folder another user can read.
        data = json.loads(read_bounded(path, refresh_state.MAX_STATE_BYTES,
                                       nofollow=True).decode("utf-8"))
    except Exception as e:  # noqa: BLE001 — any unreadable manifest is one state, reported
        return None, f"the snapshot manifest could not be read ({type(e).__name__})"
    if not isinstance(data, dict):
        return None, "the snapshot manifest is not in the expected shape"
    return data, None


def _write_atomic(path: Path, body: bytes) -> None:
    fd, tmp = tempfile.mkstemp(dir=str(path.parent), prefix=f".{path.name}.", suffix=".tmp")
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(body)
        os.chmod(tmp, FILE_MODE)
        os.replace(tmp, path)
    except BaseException:
        Path(tmp).unlink(missing_ok=True)
        raise


# --------------------------------------------------------------------------- publisher (operator)

def _trusted_dir(directory: Path) -> None:
    """Refuse a publish folder another local user could redirect or read into.

    The publisher runs as the OPERATOR and writes into /Users/Shared, which every local user can
    write. So the folder must be a real directory (not a symlink) owned by the operator and not
    writable by anyone else, and every ancestor — as written and as resolved — must be owned by
    root or the operator and, if others can write it, be a root-owned sticky directory like
    /Users/Shared itself. Otherwise whoever created `/Users/Shared/prism-agent` first could swap
    the folder for one whose group they choose, plant a snapshot the agent would serve, or point
    the manifest at an operator-only file.
    """
    uid = os.geteuid()
    path = Path(os.path.abspath(directory))
    try:
        st = os.lstat(path)
    except OSError as e:
        raise AgentError(f"{directory} does not exist. Create it first — who may read a "
                         f"snapshot is decided by that folder's owner and group, so it is never "
                         f"created here.") from e
    if (stat.S_ISLNK(st.st_mode) or not stat.S_ISDIR(st.st_mode) or st.st_uid != uid
            or st.st_mode & 0o022):
        raise AgentError(f"{directory} must be a real directory owned by you and writable by "
                         f"nobody else; refusing to publish into it.")
    for anc in (*path.parents, *Path(os.path.realpath(path)).parents):
        a = os.lstat(anc)
        shared = a.st_uid == 0 and a.st_mode & stat.S_ISVTX
        if a.st_uid not in (0, uid) or (a.st_mode & 0o022 and not stat.S_ISLNK(a.st_mode)
                                        and not shared):
            raise AgentError(f"{anc} is owned or writable by another user, so {directory} "
                             f"could be redirected; refusing to publish into it.")


def load_config(registry: str | Path | None = None) -> dict[str, Path]:
    """`{scope: snapshot dir}` from `agent-publish.toml` beside the registry; `{}` when absent.

        [publish.prism]
        dir = "/Users/Shared/prism-agent/substrate"

    Opt-in by file, like the registry itself: no file, no publishing, and nothing under
    `/Users/Shared` is ever written by a machine that did not ask for it.
    """
    path = scopes.registry_path(registry).parent / CONFIG_FILENAME
    if not path.is_file():
        return {}
    try:
        data = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError) as e:
        raise AgentError(f"cannot read {path}: {e}") from e
    table = data.get("publish", {})
    if not isinstance(table, dict):
        raise AgentError(f"{path}: 'publish' must be a table of scopes.")
    out = {}
    for name, row in table.items():
        if not valid_scope_name(name) or not isinstance(row, dict) \
                or not isinstance(row.get("dir"), str) or not row["dir"].strip():
            raise AgentError(f"{path}: [publish.{name}] needs a valid scope name and a `dir`.")
        out[name] = Path(row["dir"]).expanduser()
    return out


@dataclass(frozen=True)
class Published:
    scope: str
    db: Path
    manifest: Path
    rewrote: bool
    withheld: tuple[str, ...]
    excluded: int = 0


@dataclass(frozen=True)
class _NoteCopy:
    """One note as the snapshot will carry it, read BEFORE the fingerprint is taken so the text
    itself is part of what decides whether the snapshot is current."""

    doc_id: str
    path: str
    text: str
    stale: int | None


def _withheld(scope: str, project_vault: Path) -> frozenset[str]:
    """Fail closed: a declared guard, well-formed or not, withholds the project vault's own notes.
    Both names, because the guard keys on the scope and the index on the vault directory."""
    if guard.declared_guard(project_vault) is None:
        return frozenset()
    return frozenset({scope, project_vault.name})


def _doc_rows(store) -> list[tuple]:
    """The rows the note copies are derived from. Captured ONCE and fingerprinted, so the re-check
    after the copy sees a document that was added, removed, moved to another vault or repointed
    while the notes were being read — `index_version` hashes content, not where it lives."""
    return [tuple(r) for r in store.db.execute(
        "SELECT doc_id, source_path, source_sha256, vault FROM documents ORDER BY doc_id")]


def _read_notes(rows: list[tuple], roots: dict[str, Path],
                withheld: frozenset[str]) -> tuple[list[_NoteCopy], frozenset[str]]:
    """Every note the snapshot will carry, read from the vault — and ONLY from the vault — plus
    the documents to EXCLUDE from the snapshot altogether.

    A document is carried only when its note can be shown to be the bytes compose indexed: the
    path resolves (strictly — it must exist) inside one of the scope's vault roots, it is read at
    that resolved path opened NOFOLLOW, and its checksum still matches the index. Anything else is
    excluded WHOLE, passages and vectors included. Compose indexes a symlinked note THROUGH the
    link, so the chunks can hold an outside file's text; and the link as it stands now — deleted,
    or swapped for an innocent file — says nothing about what compose read through it. Only a
    match against the indexed checksum does, so a note that cannot be matched fails closed. On
    the refresh path compose has just run and everything matches; a note edited since is left
    out until the next refresh. This runs as the operator and the result lands in a file another
    user reads."""
    from substrate.freshness import read_bounded, stale_verdict

    out, excluded = [], set()
    for doc_id, source_path, source_sha256, vault in rows:
        if vault in withheld:
            continue
        try:
            real = Path(source_path).resolve(strict=True)
            if not any(real.is_relative_to(root) for root in roots.values()):
                raise OSError("outside the scope's vaults")
            raw = read_bounded(real, MAX_NOTE_BYTES, nofollow=True)
        except (OSError, RuntimeError):
            excluded.add(doc_id)
            continue
        verdict = stale_verdict(raw, source_sha256)
        if verdict:
            excluded.add(doc_id)
            continue
        out.append(_NoteCopy(doc_id, _relative(source_path, roots, vault),
                             raw.decode("utf-8", errors="replace"),
                             None if verdict is None else 0))
    return out, frozenset(excluded)


def _fingerprint(store, withheld: frozenset[str], excluded: frozenset[str], docs: list[tuple],
                 notes: list[_NoteCopy]) -> str:
    """What the snapshot would be built from. Equal fingerprints mean an identical snapshot, so a
    refresh that changed nothing re-verifies the manifest instead of rewriting 50MB."""
    from substrate.store import schema

    def rows(sql: str) -> list:
        return [list(r) for r in store.db.execute(sql)]

    # Identity is rebuilt by every compose from a file `index_version` does not cover, so a roster
    # edit alone must still republish rather than re-verify the old one. The note copies are in
    # for the same reason: a note unreadable at the last publish, or edited since compose, must
    # not be carried forward under a fresh `verified`.
    sig = json.dumps([
        store.index_version,
        rows("SELECT embed_model, COUNT(*) FROM chunk_vectors GROUP BY embed_model ORDER BY 1"),
        rows("SELECT entity_id, name, kind, gloss FROM entities ORDER BY 1"),
        rows("SELECT doc_id, entity_id, surface FROM document_entities ORDER BY 1, 2, 3"),
        [list(r) for r in docs],
        [[n.doc_id, n.path, hashlib.sha256(n.text.encode()).hexdigest(), n.stale]
         for n in notes],
        sorted(withheld), sorted(excluded), schema.SCHEMA_VERSION, MANIFEST_VERSION,
    ])
    return hashlib.sha256(sig.encode()).hexdigest()


def _relative(source: str, roots: dict[str, Path], vault: str | None) -> str:
    p = Path(source)
    root = roots.get(vault or "")
    if root is not None:
        try:
            return f"{vault}/{p.resolve().relative_to(root).as_posix()}"
        except ValueError:
            pass
    return f"{vault or '?'}/{p.name}"


def _fill(tmp: Path, withheld: frozenset[str], excluded: frozenset[str],
          notes: list[_NoteCopy], meta: dict) -> None:
    """Turn a raw `VACUUM INTO` copy into a snapshot: withhold, add note text, strip paths."""
    from substrate.store.index_store import IndexStore

    store = IndexStore(str(tmp), migrate=False)
    db = store.db
    try:
        # Deleted pages are zeroed, and the whole file is VACUUMed below, so a withheld note's text
        # does not survive in free pages of a file handed to another user.
        db.execute("PRAGMA secure_delete=ON")
        marks = ",".join("?" * len(withheld))
        gone = set(excluded) | {r[0] for r in db.execute(
            f"SELECT doc_id FROM documents WHERE vault IN ({marks})", tuple(withheld))}
        if gone:
            for doc_id in sorted(gone):
                store.remove(doc_id)
            db.execute("INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild')")
        _strip_roster(db)

        # The copy must hold exactly the documents the notes were read for — anything else would
        # keep an operator path, or carry text for a row that is not there. `_publish` refuses a
        # copy taken across a change; this is the last word on it.
        copied = {r[0] for r in db.execute("SELECT doc_id FROM documents")}
        if copied != {n.doc_id for n in notes}:
            raise AgentError("the copied index does not match the notes read for it; not "
                             "published. The next refresh will publish it.")
        db.executescript(_SNAPSHOT_DDL)
        db.execute("BEGIN")
        for n in notes:
            db.execute("INSERT INTO snapshot_notes(doc_id, path, text, stale) VALUES (?,?,?,?)",
                       (n.doc_id, n.path, n.text, n.stale))
            db.execute("UPDATE documents SET source_path=?, markdown_path='', raw_location=NULL "
                       "WHERE doc_id=?", (n.path, n.doc_id))
        db.executemany("INSERT INTO snapshot_meta(key, value) VALUES (?,?)",
                       [(k, str(v)) for k, v in meta.items()])
        db.execute("COMMIT")
        db.execute("PRAGMA wal_checkpoint(TRUNCATE)")
        db.execute("PRAGMA journal_mode=DELETE")
        db.execute("VACUUM")
    finally:
        store.close()


def _withdraw_if_newly_guarded(withheld: frozenset[str], db_path: Path, manifest_path: Path,
                               prior: dict | None) -> bool:
    """Remove a published snapshot built WITHOUT a guard the scope now declares. True if removed.

    Run before anything that can fail, by every path that touches a published scope: a snapshot
    that outlives a newly declared guard serves that vault's notes for as long as the rebuild that
    would strip them keeps failing. No manifest counts as nothing withheld — fail closed."""
    built = prior.get("withheld_vaults") if prior else None
    if withheld <= frozenset(built if isinstance(built, list) else ()) or not db_path.exists():
        return False
    db_path.unlink(missing_ok=True)
    manifest_path.unlink(missing_ok=True)
    return True


def _strip_roster(db) -> None:
    """Reduce the identity roster to what this scope's notes themselves show.

    The roster mirrors a file shared across every scope (`identity.py`), so as compose leaves it,
    it names people from other scopes, carries glosses the notes never state, and MERGES aliases
    — "Ada" in one note and "the Countess" in another resolve to one id, which is a judgement only
    the roster holds. None of that is this scope's to hand over, wherever the roster file lives.

    So the snapshot keeps one entity per distinct SURFACE a remaining note matched: named by that
    surface, no gloss, and an id that is a hash of the surface — so it reveals nothing the name
    does not, merges only what the text itself spells the same way, and stays stable across
    publishes so an `entity` filter keeps working. `kind` stays: it is a category, not a fact about
    the person. Nobody no remaining note mentions survives."""
    rows = db.execute("SELECT d.doc_id, d.surface, e.kind FROM document_entities d "
                      "JOIN entities e ON e.entity_id = d.entity_id").fetchall()

    def opaque(surface: str) -> str:
        return "e-" + hashlib.sha256(surface.casefold().encode()).hexdigest()[:12]

    names: dict[str, str] = {}
    kinds: dict[str, str] = {}
    for _, surface, kind in rows:
        key = opaque(surface)
        names[key] = min(names.get(key, surface), surface)
        if kind is not None:
            kinds[key] = min(kinds.get(key, kind), kind)
    db.execute("BEGIN")
    db.execute("DELETE FROM document_entities")
    db.execute("DELETE FROM entities")
    db.executemany("INSERT INTO entities(entity_id, name, kind, gloss) VALUES (?,?,?,NULL)",
                   [(key, name, kinds.get(key)) for key, name in names.items()])
    db.executemany("INSERT OR IGNORE INTO document_entities(doc_id, entity_id, surface) "
                   "VALUES (?,?,?)", [(doc_id, opaque(surface), surface)
                                      for doc_id, surface, _ in rows])
    db.execute("COMMIT")


def _publish_lock(scope: str, registry: str | Path | None):
    """One publish or annotate per scope at a time. Held in the OPERATOR's state directory, never
    the shared folder, so no other user can hold it. Without it a manual `publish-snapshot` racing
    a refresh could finish with the older database under the newer manifest — whose fingerprint
    then matches every later refresh, so the stale copy would be re-verified as fresh for good."""
    return scopes.exclusive(scopes.registry_path(registry).parent / f"agent-snapshot-{scope}")


def publish(scope: str, directory: str | Path, *, registry: str | Path | None = None,
            now: datetime | None = None) -> Published:
    """Publish one scope's snapshot and manifest into `directory`, which must already exist."""
    with _publish_lock(scope, registry):
        return _publish(scope, Path(directory), registry=registry, now=now)


def _publish(scope: str, directory: Path, *, registry: str | Path | None,
             now: datetime | None) -> Published:
    from substrate import vault as _vault
    from substrate.store.index_store import IndexStore, SchemaMismatch

    db_path, manifest_path = snapshot_paths(directory, scope)
    _trusted_dir(directory)
    try:
        entry = scopes.resolve(scope, registry)
        chain = _vault.resolve_vaults(Path(entry.vault))
    except (scopes.ScopeError, _vault.VaultError) as e:
        raise AgentError(str(e)) from e
    roots = {v.name: v.path.resolve() for v in chain}
    withheld = _withheld(scope, Path(entry.vault))
    prior, _ = _read_manifest(manifest_path)
    if _withdraw_if_newly_guarded(withheld, db_path, manifest_path, prior):
        prior = None

    stamp = _stamp(now or _now())
    try:
        source = IndexStore(str(entry.db), migrate=False)
    except SchemaMismatch as e:
        raise AgentError(str(e)) from e
    try:
        if source.stats()["passages"] == 0:
            raise AgentError(f"scope {scope!r} has an EMPTY index; refusing to publish it.")
        rows = _doc_rows(source)
        notes, excluded = _read_notes(rows, roots, withheld)
        if not notes:
            # The source was not empty, so everything was withheld or excluded — most likely the
            # vault roots no longer match the indexed paths (a moved vault, before a recompose).
            # A published empty snapshot would answer "nothing on that", labelled fresh.
            raise AgentError(f"every note in {scope!r} was withheld or could not be matched to "
                             f"the index ({len(excluded)} excluded); refusing to publish an "
                             f"empty snapshot. Recompose the scope, then publish.")
        fingerprint = _fingerprint(source, withheld, excluded, rows, notes)
        index_version = source.index_version
        rewrite = not (prior and prior.get("fingerprint") == fingerprint and db_path.is_file())
        if not rewrite and _fingerprint(source, withheld, excluded, _doc_rows(source),
                                        notes) != fingerprint:
            # Re-verifying is a claim that the snapshot matches the live index NOW, so the same
            # re-check guards it: a change landing while the notes were read is not "unchanged".
            raise AgentError(f"the {scope!r} index changed while it was being checked; not "
                             f"re-verified. The next refresh will publish it.")
        if rewrite:
            fd, tmp_name = tempfile.mkstemp(dir=str(directory), prefix=f".{scope}.",
                                            suffix=".tmp")
            os.close(fd)
            tmp = Path(tmp_name)
            try:
                source.db.execute("VACUUM INTO ?", (tmp_name,))
                # A compose that committed between the fingerprint and the copy would leave a
                # snapshot whose recorded version describes different rows. Refused, and the next
                # refresh — which follows that compose — publishes the settled index.
                if _fingerprint(source, withheld, excluded, _doc_rows(source),
                                notes) != fingerprint:
                    raise AgentError(f"the {scope!r} index changed while it was being copied; "
                                     f"not published. The next refresh will publish it.")
                source.close()
                _fill(tmp, withheld, excluded, notes, {"scope": scope, "published": stamp,
                                             "index_version": index_version})
                os.chmod(tmp, FILE_MODE)
                os.replace(tmp, db_path)
            finally:
                for leftover in (tmp, Path(f"{tmp}-journal"), Path(f"{tmp}-wal"),
                                 Path(f"{tmp}-shm")):
                    leftover.unlink(missing_ok=True)
    finally:
        source.close()

    manifest = {
        "version": MANIFEST_VERSION,
        "scope": scope,
        "published": stamp if rewrite else prior.get("published"),
        # When the operator's engine last confirmed this snapshot matches the live index. AGE is
        # measured from here, so a scope that refreshes and does not change stays young.
        "verified": stamp,
        "index_version": index_version,
        "fingerprint": fingerprint,
        "sources": [v.name for v in chain],
        "withheld_vaults": sorted(withheld),
        # A count, not the ids: this file is the agent's to read, and the point of excluding a
        # document is that nothing about it reaches the agent.
        "excluded_documents": len(excluded),
        # The record as stored, judged on the agent side by `refresh_state.block_for` — so a
        # freeze the operator's engine recorded reaches the agent as the same freeze.
        "refresh": refresh_state.stored_row(scope, registry),
    }
    _write_atomic(manifest_path, (json.dumps(manifest, indent=2) + "\n").encode())
    return Published(scope, db_path, manifest_path, rewrite, tuple(sorted(withheld)),
                     len(excluded))


def annotate(scope: str, directory: str | Path, *,
             registry: str | Path | None = None) -> str:
    """Carry a FAILED refresh to the agent without touching the snapshot: the copy stays as good
    as it was, and its manifest now says the live scope is frozen.

    Returns what happened: `absent` (nothing published to annotate), `marked`, or `withdrawn` —
    the scope has gained a guard since the snapshot was built, and a failed refresh does not
    republish, so the snapshot is removed instead (`_withdraw_if_newly_guarded`). The agent then
    reads "no published snapshot", which is true, and the next successful refresh publishes it
    stripped."""
    directory = Path(directory)
    with _publish_lock(scope, registry):
        db_path, manifest_path = snapshot_paths(directory, scope)
        _trusted_dir(directory)
        prior, _ = _read_manifest(manifest_path)
        entry = scopes.load(registry).get(scope)
        if entry is not None and _withdraw_if_newly_guarded(
                _withheld(scope, Path(entry.vault)), db_path, manifest_path, prior):
            return "withdrawn"
        if prior is None:
            return "absent"
        prior["refresh"] = refresh_state.stored_row(scope, registry)
        _write_atomic(manifest_path, (json.dumps(prior, indent=2) + "\n").encode())
        return "marked"


def after_refresh_record(scope: str, outcome: str, *,
                         registry: str | Path | None = None) -> str | None:
    """The hook `refresh-record` calls once the outcome is recorded. Returns a line to print, or
    None when this scope is not published. Raises AgentError; the caller reports it, and a failed
    publish never turns a recorded refresh into a failed one."""
    target = load_config(registry).get(scope)
    if target is None:
        return None
    if refresh_state.OUTCOMES[outcome]["success"]:
        p = publish(scope, target, registry=registry)
        return f"{scope}: snapshot {'published' if p.rewrote else 'verified'} -> {p.db}"
    done = annotate(scope, target, registry=registry)
    if done == "withdrawn":
        return f"{scope}: snapshot WITHDRAWN — the scope declares a guard it was not built with"
    if done == "marked":
        return f"{scope}: snapshot manifest marked {outcome}"
    return None


# --------------------------------------------------------------------------- agent side

@dataclass(frozen=True)
class SnapshotEntry:
    """What `_open` hands the tools in agent mode — the fields of a `ScopeEntry` they read, with no
    vault: the agent has none to name."""

    name: str
    db: Path
    composed: str | None = None
    vault: None = None
    index_root: None = None


class AgentScopes:
    """The agent's whole world: the allowed scopes, and the folder their snapshots are in."""

    def __init__(self, allowed: Iterable[str], directory: str | Path, *,
                 max_age_seconds: int = DEFAULT_MAX_AGE_SECONDS):
        names = frozenset(allowed)
        bad = sorted(n for n in names if not valid_scope_name(n))
        if not names or bad:
            raise AgentError(f"--scopes needs one or more plain scope names; refused {bad}.")
        self.allowed = names
        self.directory = Path(directory)
        self.max_age_seconds = max_age_seconds

    def _paths(self, name: object) -> tuple[Path, Path]:
        if not isinstance(name, str) or name not in self.allowed:
            raise AgentError(UNAVAILABLE)
        return snapshot_paths(self.directory, name)

    def open(self, name: object):
        """`(entry, store)` for an allowed scope, opened immutable, or AgentError."""
        from substrate.store.index_store import IndexStore, SchemaMismatch

        db_path, manifest_path = self._paths(name)
        if not db_path.is_file():
            raise AgentError(f"scope {name!r} has no published snapshot yet.")
        try:
            store = IndexStore(str(db_path), migrate=False, immutable=True)
        except SchemaMismatch as e:
            raise AgentError(f"the snapshot for {name!r} cannot be read by this engine "
                             f"(schema v{e.found}, engine v{e.expected}); it must be "
                             f"republished.") from e
        try:
            row = store.db.execute(
                "SELECT value FROM snapshot_meta WHERE key='scope'").fetchone()
        except sqlite3.DatabaseError:
            row = None
        if row is None or row[0] != name:
            store.close()
            raise AgentError(f"the file at the {name!r} snapshot path is not that scope's "
                             f"snapshot.")
        manifest, _ = _read_manifest(manifest_path)
        published = manifest.get("published") if manifest else None
        return SnapshotEntry(name=name, db=db_path,
                             composed=published if isinstance(published, str) else None), store

    def refresh(self, name: str, *, now: datetime | None = None) -> dict:
        """The `refresh` block, judged from the manifest, plus `snapshot`: how old the copy is.

        `frozen` keeps its meaning — the operator's last recompose refused — and STALENESS is a
        separate key, because an old snapshot of a healthy scope is a different fact from a fresh
        snapshot of a frozen one, and a reader needs to tell them apart."""
        _, manifest_path = self._paths(name)
        manifest, unreadable = _read_manifest(manifest_path)
        block = refresh_state.block_for(manifest.get("refresh") if manifest else None)
        verified = manifest.get("verified") if manifest else None
        age = None
        if isinstance(verified, str) and len(verified) <= refresh_state.MAX_STAMP_CHARS:
            try:
                age = int(((now or _now()) - datetime.fromisoformat(verified)).total_seconds())
            except (ValueError, TypeError):
                age = None
        stale = None if age is None else age > self.max_age_seconds
        published = manifest.get("published") if manifest else None
        block["snapshot"] = {
            "published": published if isinstance(published, str)
            and len(published) <= refresh_state.MAX_STAMP_CHARS else None,
            "verified": verified if age is not None else None,
            "age_seconds": age,
            "max_age_seconds": self.max_age_seconds,
            # Tri-state like `frozen`: null means the age could not be established — no manifest,
            # or an unreadable one — which is absent evidence, not a young snapshot.
            "stale": stale,
        }
        lead = None
        if unreadable:
            lead = unreadable + "; the snapshot's age is unknown."
        elif stale is None:
            lead = "no snapshot manifest, so this snapshot's age is unknown."
        elif stale:
            lead = (f"STALE SNAPSHOT — last matched the live index {age // 3600}h ago, past the "
                    f"{self.max_age_seconds // 3600}h limit. The operator's refresh has not run "
                    f"since, so these answers may not reflect the vault.")
        if lead:
            block["note"] = lead if not block["note"] else f"{lead} {block['note']}"
        return block

    def note(self, store, doc_id: str, *, cap: int) -> dict:
        """The whole note behind a passage, from the snapshot — never from a vault."""
        row = store.db.execute(
            "SELECT path, text, stale FROM snapshot_notes WHERE doc_id=?", (doc_id,)
        ).fetchone()
        if row is None:
            raise AgentError(f"no note text for {doc_id!r} in this snapshot.")
        text = row["text"]
        return {
            "path": row["path"],
            "text": text[:cap],
            "n_chars": len(text),
            "truncated": len(text) > cap,
            # Judged at PUBLISH time. Always false or null: a note that had moved on from the index
            # is excluded from the snapshot rather than served.
            "stale": None if row["stale"] is None else bool(row["stale"]),
        }

    def scopes_payload(self) -> dict:
        out = []
        for name in sorted(self.allowed):
            db_path, manifest_path = snapshot_paths(self.directory, name)
            manifest, _ = _read_manifest(manifest_path)
            sources = manifest.get("sources") if manifest else None
            out.append({
                "scope": name, "db": str(db_path), "vault": None,
                "composed": (manifest or {}).get("published")
                if isinstance((manifest or {}).get("published"), str) else None,
                "index_present": db_path.is_file(),
                "refresh": self.refresh(name),
                "sources": [s for s in sources if isinstance(s, str)]
                if isinstance(sources, list) else None,
            })
        return {"scopes": out, "registry": None, "snapshot_dir": str(self.directory)}
