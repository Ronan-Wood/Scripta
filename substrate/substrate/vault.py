"""Manifest reading + scope composition — the inheritance mechanism (Doc 2 §1–2).

Option A inheritance is, in the engine, nothing more than *which source paths to index*. This
module is that and only that: read a project vault's `.substrate.toml`, resolve what it inherits
to concrete vault directories, discover the notes under the composed set, and hand back a Scope
the compose command ingests + indexes as one. No copies, no submodules, no sync.

The engine has an opinion on SHAPE, none on LOCATION (Doc 2 §0): an `inherits` entry is resolved
as an explicit path when it is one (absolute, or contains a separator) and otherwise as a sibling
directory of the project vault — so a user may keep core-vault in a cloud folder and point at it
by path, or keep it beside the project and name it. The manifest FORMAT is the system's; WHERE the
paths live is the user's.

Every refusal here is a hard failure with the condition attached, never a silent fallback to a
narrower scope — a composed query that quietly dropped the core tier and returned plausible
project-only results is the chapter-title bug (a well-formed answer from the wrong source set)
wearing a new hat. `assert_composed` is the post-index proof that it did not happen.
"""

from __future__ import annotations

import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from substrate.extract.base import doc_id_for  # stdlib-only; no Docling/torch pulled in
from substrate.markdown.reader import _DOC_ID, _parse_frontmatter, _parse_list

MANIFEST = ".substrate.toml"

# Mirror reader._MAX_MD_BYTES: every file the vault path reads — the manifest, each `_meta.md`, and
# each note during the doc_id pre-scan — is size-checked before it is slurped, so a pathological
# file (a multi-GB cloud-synced `_meta.md`) is refused rather than driven into an OOM. The note
# reader is already hardened this way; this extends the same guard to the reads it did not cover.
_MAX_BYTES = 64 * 1024 * 1024

# Files/dirs that are scaffolding, not retrievable notes. `_meta.md` is a source's metadata (read
# for domains/class, never indexed); `structure.md` is an orientation outline Doc 2 explicitly
# calls "not itself a retrieval target"; MEMORY.md and log.md are navigation/history; templates are
# templates. Excluding them is not a silent drop — they are not notes, and the count check in
# assert_composed is over the notes actually selected here, so nothing indexable goes missing.
SKIP_NAMES: frozenset[str] = frozenset({"_meta.md", "structure.md", "MEMORY.md", "log.md"})
SKIP_DIRS: frozenset[str] = frozenset({"99-templates"})


class VaultError(RuntimeError):
    """A manifest is malformed, points at a missing vault, or composes an empty/ambiguous scope."""


def _read_capped(path: Path) -> str:
    """Read a vault file as UTF-8 (line-endings normalized), refusing a pathologically large one
    before it is slurped into memory. VaultError on any read failure or over-cap size."""
    try:
        size = path.stat().st_size
    except OSError as e:
        raise VaultError(f"cannot stat {path}: {e}") from e
    if size > _MAX_BYTES:
        raise VaultError(f"{path} is {size} bytes (> {_MAX_BYTES} cap) — refusing to read.")
    try:
        return path.read_bytes().decode("utf-8").replace("\r\n", "\n").replace("\r", "\n")
    except (OSError, UnicodeDecodeError) as e:
        raise VaultError(f"cannot read {path}: {e}") from e


@dataclass(frozen=True)
class VaultRef:
    name: str          # the vault DIRECTORY name — the composition-provenance key
    path: Path


@dataclass(frozen=True)
class NoteRef:
    path: Path
    vault: str
    tier: int                       # 1 operator · 2 reference · 3 project — derived from location
    doc_class: str | None = None    # from a reference source's _meta.md `class`, else None
    override_status: str | None = None   # from _meta.md, applied only when the note declares none
    override_version: str | None = None  # from a versioned source's _meta.md
    extra_domains: list[str] = field(default_factory=list)  # merged from _meta.md


@dataclass(frozen=True)
class Scope:
    """The composed retrieval scope: the ordered vaults (roots first, project last) and the notes
    to index across them. `vaults` is the set assert_composed proves the index actually covers."""

    project: VaultRef
    vaults: tuple[VaultRef, ...]
    notes: tuple[NoteRef, ...]

    @property
    def vault_names(self) -> frozenset[str]:
        return frozenset(v.name for v in self.vaults)


def _read_manifest(vault_dir: Path) -> dict:
    path = vault_dir / MANIFEST
    text = _read_capped(path)  # size-checked; raises VaultError on read failure / over-cap
    try:
        manifest = tomllib.loads(text)
    except tomllib.TOMLDecodeError as e:
        raise VaultError(f"malformed manifest {path}: {e}") from e
    name = manifest.get("name")
    if not isinstance(name, str) or not name:
        raise VaultError(f"{path}: manifest has no string 'name'.")
    inherits = manifest.get("inherits", [])
    if not isinstance(inherits, list) or not all(isinstance(x, str) for x in inherits):
        raise VaultError(f"{path}: 'inherits' must be a list of strings.")
    return manifest


def _resolve_inherit(entry: str, project_dir: Path) -> Path:
    """An inherits entry → a vault directory. Absolute path used as-is, else project-relative.

    Location is the user's (Doc 2 §0): an ABSOLUTE path is honoured as given (a cloud-synced
    core-vault, a NAS mount). Everything else — a bare name OR a relative path with separators
    (`../core`, `shared/core`) — resolves against the PROJECT VAULT's parent, never the process
    CWD, so composition is deterministic regardless of where `compose` is invoked. A missing
    directory is a hard failure: resolving to nothing and proceeding project-only is exactly the
    silent core-tier drop this module refuses.
    """
    p = Path(entry).expanduser()
    resolved = p if p.is_absolute() else (project_dir.parent / entry)
    if not resolved.is_dir():
        raise VaultError(
            f"inherited vault {entry!r} resolves to {resolved}, which does not exist. Refusing to "
            "compose a scope missing a vault it declares — a query would silently drop that tier."
        )
    return resolved


def _tier_for(rel_parts: tuple[str, ...]) -> int:
    """A note's tier from where it lives: operator (1), reference (2), or project (3). Derived from
    location, not a vault-level flag, because core-vault holds both tier-1 and tier-2 content."""
    if any(part.startswith("00-operator") for part in rel_parts):
        return 1
    if any(part.startswith("10-reference") for part in rel_parts):
        return 2
    return 3


def _source_meta(note_path: Path) -> dict:
    """`_meta.md` context for a reference passage: the `class`/`status`/`domains` a passage under
    `<source>/passages/` inherits from its source. Empty for a note that is not under a passages/
    dir, or whose source has no _meta.md. The _meta is read, never indexed."""
    parts = note_path.parts
    if "passages" not in parts:
        return {}
    src_dir = Path(*parts[: parts.index("passages")])
    meta_file = src_dir / "_meta.md"
    if not meta_file.is_file():
        return {}
    front, _ = _parse_frontmatter(_read_capped(meta_file))
    return {
        # Doc 2 writes reference metadata as `class:`; the engine's field is `document_class`.
        "doc_class": front.get("class") or front.get("document_class"),
        "status": front.get("status"),
        "domains": _parse_list(front.get("domains")),
        "version": front.get("version"),
    }


def _discover_notes(vault: VaultRef) -> list[NoteRef]:
    notes: list[NoteRef] = []
    for path in sorted(vault.path.rglob("*.md")):
        # Match skip-dirs against the vault-RELATIVE path, not the absolute one — otherwise a vault
        # that happens to live under an ancestor named e.g. `99-templates` would skip every note.
        rel_parts = path.relative_to(vault.path).parts
        if any(part in SKIP_DIRS for part in rel_parts):
            continue
        if path.name in SKIP_NAMES:
            continue
        meta = _source_meta(path)
        notes.append(NoteRef(
            path=path, vault=vault.name, tier=_tier_for(rel_parts),
            doc_class=meta.get("doc_class"), override_status=meta.get("status"),
            override_version=meta.get("version"), extra_domains=list(meta.get("domains", [])),
        ))
    return notes


def resolve_scope(project_vault: Path) -> Scope:
    """Read a project vault's manifest, resolve its inheritance, and compose the note set to index.

    Refuses (VaultError) rather than mislead: a missing manifest, a malformed one, an inherited
    vault that does not exist, a scope that composes zero notes, or a doc_id that two notes in the
    composed scope both claim (reconcile keys the index on doc_id — a collision would silently make
    one note overwrite the other).
    """
    project_vault = project_vault.expanduser().resolve()
    if not (project_vault / MANIFEST).is_file():
        raise VaultError(
            f"{project_vault} has no {MANIFEST}. A project vault must carry a manifest — refusing "
            "to guess a scope."
        )

    # Resolve the inheritance chain, roots first, with cycle detection. core-vault has no manifest
    # (it is the root) so recursion bottoms out there; a vault that DOES declare inherits is
    # followed, so the chain is general, not hard-coded to one level.
    ordered: list[VaultRef] = []
    seen_paths: set[Path] = set()

    def visit(vault_dir: Path, chain: tuple[Path, ...]) -> None:
        vault_dir = vault_dir.resolve()
        if vault_dir in chain:
            raise VaultError(f"inheritance cycle: {' -> '.join(str(p) for p in (*chain, vault_dir))}")
        if vault_dir in seen_paths:
            return
        manifest_path = vault_dir / MANIFEST
        if manifest_path.is_file():
            manifest = _read_manifest(vault_dir)
            for entry in manifest.get("inherits", []):
                visit(_resolve_inherit(entry, vault_dir), (*chain, vault_dir))
        seen_paths.add(vault_dir)
        ordered.append(VaultRef(name=vault_dir.name, path=vault_dir))

    visit(project_vault, ())
    project_ref = next(v for v in ordered if v.path == project_vault)

    notes: list[NoteRef] = []
    for v in ordered:
        notes.extend(_discover_notes(v))

    if not notes:
        raise VaultError(
            f"composed scope over {[v.name for v in ordered]} discovered zero notes. An empty "
            "scope is refused rather than indexed into a silently-empty retrieval set."
        )

    # doc_id is computed at ingest from frontmatter, else filename+content (doc_id_for). A collision
    # across the composed scope makes one note silently overwrite another at reconcile (keyed on
    # doc_id), while every A-series gate stays green — the exact "green gates, silent loss" shape.
    # The EFFECTIVE id is checked (not just frontmatter-declared ones): two byte-identical, same-stem
    # notes in different vaults produce one filename-derived id, and assert_composed cannot catch
    # that (the ingested-id SET has already deduped them). Refuse it here, at the source.
    ids: dict[str, Path] = {}
    for n in notes:
        front, _ = _parse_frontmatter(_read_capped(n.path))  # size-checked before doc_id_for reads it
        fid = front.get("doc_id", "")
        eff = fid if _DOC_ID.fullmatch(fid) else doc_id_for(n.path)
        if eff in ids:
            raise VaultError(
                f"doc_id {eff!r} produced by two notes: {ids[eff]} and {n.path}. Composed vaults "
                "share one id space; refusing an ambiguous overwrite — one would silently replace "
                "the other at index time."
            )
        ids[eff] = n.path

    return Scope(project=project_ref, vaults=tuple(ordered), notes=tuple(notes))


def assert_composed(store, *, ingested_doc_ids: set[str]) -> dict:
    """A-series composition proof: inheritance actually composed, nothing silently dropped or added.

    Runs after indexing. The core guarantee is that the indexed doc set is EXACTLY what this compose
    ingested — no more, no less — which closes the "green gates, silent loss" shape from both sides.
    `ingested_doc_ids` is the ground truth (every note this run ingested, one id each; compose aborts
    if any note fails, so it equals the discovered set), so the scope is not needed a second time:

      1. every ingested note is indexed. A note discovered, ingested, then absent from the index
         means reconcile dropped it. When a whole vault's notes go missing this way, the message
         names the vault — the CORE tier vanishing is the chapter-title bug reincarnate (plausible
         project-only results, core silently gone).
      2. no indexed doc that this compose did NOT ingest. A stale ingest dir left by a previous run
         (a since-deleted note that `compose` without --clean never cleared) would keep answering
         queries; out-of-scope content in the index root would answer from sources the manifest
         never authorised. Both are `indexed − ingested`.

    A vault that legitimately contributes zero notes (e.g. a freshly-scaffolded, empty core) is NOT
    an error — it simply adds nothing to either side of the equality, so it is neither required to
    appear nor flagged as missing. That distinguishes "empty vault" from "silently dropped tier",
    which a bare "every scope vault must have ≥1 doc" check conflated.

    Raises VaultError on any breach; returns per-vault / per-tier counts for the read-out.
    """
    rows = store.db.execute(
        "SELECT COALESCE(vault,'') AS vault, tier, COUNT(*) AS n FROM documents "
        "GROUP BY vault, tier ORDER BY vault, tier"
    ).fetchall()
    indexed_by_vault: dict[str, int] = {}
    for r in rows:
        indexed_by_vault[r["vault"]] = indexed_by_vault.get(r["vault"], 0) + r["n"]

    # Which vault each indexed doc belongs to — so a missing/stale doc can be named with its vault.
    doc_vault = {
        r["doc_id"]: (r["vault"] or "")
        for r in store.db.execute("SELECT doc_id, COALESCE(vault,'') AS vault FROM documents")
    }
    indexed_ids = set(doc_vault)

    # (1) ingested ⊆ indexed. A note discovered and ingested but absent from the index means
    # reconcile dropped it; a wholly-missing vault this way is the silent-tier-drop this catches.
    lost = ingested_doc_ids - indexed_ids
    if lost:
        raise VaultError(
            f"{len(lost)} note(s) ingested but not indexed: {sorted(lost)[:5]}. reconcile dropped "
            "content between ingest and index — inheritance did not compose."
        )

    # (2) indexed ⊆ ingested. An indexed doc this compose did not produce = a stale/polluted index
    # root (a since-deleted note's leftover dir, or out-of-scope content) still answering queries.
    stale = indexed_ids - ingested_doc_ids
    if stale:
        raise VaultError(
            f"{len(stale)} indexed doc(s) this compose did not ingest: "
            f"{sorted((d, doc_vault[d]) for d in stale)[:5]}. The index root holds stale or "
            "out-of-scope content — re-run with --clean so a deleted note leaves no stale dir."
        )

    by_tier: dict[int, int] = {}
    for r in rows:
        by_tier[r["tier"]] = by_tier.get(r["tier"], 0) + r["n"]
    return {"by_vault": indexed_by_vault, "by_tier": by_tier}
