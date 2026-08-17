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

import hashlib

import tomllib
from dataclasses import dataclass, field
from pathlib import Path

from substrate.extract.base import doc_id_for  # stdlib-only; no Docling/torch pulled in
from substrate.markdown.reader import _DOC_ID, _DOMAIN, _parse_frontmatter, _parse_list

MANIFEST = ".substrate.toml"

# Mirror reader._MAX_MD_BYTES: every file the vault path reads — the manifest, each `_meta.md`, and
# each note during the doc_id pre-scan — is size-checked before it is slurped, so a pathological
# file (a multi-GB cloud-synced `_meta.md`) is refused rather than driven into an OOM. The note
# reader is already hardened this way; this extends the same guard to the reads it did not cover.
_MAX_BYTES = 64 * 1024 * 1024

# Files/dirs that are scaffolding, not retrievable notes. `_meta.md` is a source's metadata (read
# for domains/class by `_source_meta`, never indexed); `structure.md` is an orientation outline Doc
# 2 explicitly calls "not itself a retrieval target"; MEMORY.md and log.md are navigation/history;
# WRITING.md is the authoring standard, a multi-job document by nature, so it is excluded rather
# than chunked into single-job passages; templates are templates. Nothing in this package reads
# `structure.md` or `WRITING.md` — they are excluded, full stop, and a reader who needs the standard
# opens it directly.
#
# Excluding them is not a silent drop for two reasons: the count check in assert_composed is over
# the notes actually selected here, and `_refuse_skipped_note_with_a_spine` refuses any of these
# that DECLARES itself a note. That second guard exists because the first argument — "they are not
# notes" — stopped being self-evident once §6a named `digest`, a doc_type that describes exactly
# what a MEMORY.md contains.
SKIP_NAMES: frozenset[str] = frozenset(
    {"_meta.md", "structure.md", "MEMORY.md", "log.md", "WRITING.md"}
)
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
    override_doc_type: str | None = None  # from _meta.md, applied only when the note declares none
    override_confidence: str | None = None  # ditto — a source states its settledness once
    raw: str | None = None            # §3b provenance, from the source's _meta.md
    raw_sha256: str | None = None
    raw_location: str | None = None
    override_version: str | None = None  # from a versioned source's _meta.md
    extra_domains: list[str] = field(default_factory=list)  # merged from _meta.md


@dataclass(frozen=True)
class Scope:
    """The composed retrieval scope: the ordered vaults (roots first, project last) and the notes
    to index across them. `vaults` is the set assert_composed proves the index actually covers.

    `name` is the manifest-DECLARED name (Doc 2 §2's `name = "prism"`) and is deliberately not
    `project.name`, which is the vault DIRECTORY (`prism-vault`) the composition provenance is
    keyed on. Both are real identifiers for different jobs: the directory names which vault a
    passage came from, the manifest names the scope a caller asks for.
    """

    project: VaultRef
    vaults: tuple[VaultRef, ...]
    notes: tuple[NoteRef, ...]
    name: str = ""

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

    # All four Doc 2 §2 keys are shape-checked, not just the two the engine acts on today. The
    # manifest FORMAT is the system's contract; a malformed one that parses cleanly and yields a
    # wrong scope silently is the chapter-title shape — well-formed, wrong, green.
    #
    # This exists because of a real defect: `reference_domains` was written BELOW `[reference_pins]`
    # in both shipped manifests, and in TOML every key after a table header belongs to that table.
    # It parsed as `reference_pins.reference_domains`, so the vault's declared domains never existed
    # at top level and the pins table gained a bogus entry. Nothing noticed for a whole phase,
    # because both features that would read those keys are deferred — the value was declared,
    # valid-looking, and read by nobody. Checking shape at PARSE time converts that into an
    # immediate loud failure instead of a surprise whenever the deferred feature lands.
    pins = manifest.get("reference_pins", {})
    if not isinstance(pins, dict) or not all(
        isinstance(k, str) and isinstance(v, str) for k, v in pins.items()
    ):
        raise VaultError(
            f"{path}: 'reference_pins' must be a table of string→string (name = \"version\"); "
            f"got {pins!r}."
        )
    domains = manifest.get("reference_domains", [])
    if not isinstance(domains, list) or not all(isinstance(x, str) for x in domains):
        raise VaultError(
            f"{path}: 'reference_domains' must be a top-level list of strings; got {domains!r}. "
            "If it looks absent, check it is not written BELOW a [table] header — in TOML every "
            "key after one belongs to that table."
        )
    # A pin whose value is not a plausible version, or a domain that is not a well-shaped tag, is
    # a typo that would otherwise surface as "why did this resolve to nothing" much later.
    bad_domains = [d for d in domains if not _DOMAIN.fullmatch(d)]
    if bad_domains:
        raise VaultError(f"{path}: malformed domain tag(s) {bad_domains}.")
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


def _source_meta(note_path: Path, vault_root: Path) -> dict:
    """`_meta.md` context for a reference passage: the `class`/`status`/`doc_type`/`confidence`/
    `domains` a passage under `<source>/passages/` inherits from its source. Empty for a note that
    is not under a passages/ dir, or whose source has no _meta.md. The _meta is read, never indexed.

    Resolved against the VAULT-RELATIVE path, and only ever from inside the vault. Matching the
    absolute path instead meant the first ancestor named `passages` won, so a vault that merely
    happened to live under such a directory inherited an `_meta.md` from OUTSIDE the composed scope
    — a file the manifest never authorised, silently supplying a note's class and (since these
    fields joined it) its stated settledness. `_discover_notes` already guards SKIP_DIRS this exact
    way, for this exact reason. `rindex` rather than `index` so a nested `passages/…/passages/`
    resolves to the NEAREST enclosing source, not the outermost.
    """
    try:
        rel_parts = note_path.relative_to(vault_root).parts
    except ValueError:
        return {}
    if "passages" not in rel_parts:
        return {}
    src_dir = vault_root.joinpath(*rel_parts[: len(rel_parts) - 1 - rel_parts[::-1].index("passages")])
    meta_file = src_dir / "_meta.md"
    # Belt-and-braces: the slice above cannot escape, but an `_meta.md` outside the vault must never
    # govern a note inside it, so assert the resolved path rather than trusting the arithmetic.
    if not meta_file.is_file() or vault_root not in meta_file.parents:
        return {}
    front, _ = _parse_frontmatter(_read_capped(meta_file))
    return {
        # Doc 2 writes reference metadata as `class:`; the engine's field is `document_class`.
        "doc_class": front.get("class") or front.get("document_class"),
        "status": front.get("status"),
        "doc_type": front.get("doc_type"),
        "confidence": front.get("confidence"),
        # §3b: the raw pointer lives on the SOURCE, so its passages inherit it —
        # that is the whole mechanism by which a chunk can name the PDF it came from.
        "raw": front.get("raw"),
        "raw_sha256": front.get("raw_sha256"),
        "raw_location": front.get("raw_location"),
        "domains": _parse_list(front.get("domains")),
        "version": front.get("version"),
    }


# SKIP_NAMES entries that nothing reads and that a writer could plausibly believe are indexable
# notes. `_meta.md` is the one exclusion NOT guarded: `_source_meta` genuinely reads it, so spine
# keys there are its job rather than a misplaced note.
_NAVIGATION_NAMES: frozenset[str] = frozenset(
    {"MEMORY.md", "log.md", "structure.md", "WRITING.md"}
)

# The keys whose presence means "this file declared itself a retrievable note". `title` and `class`
# are deliberately absent — a navigation file may legitimately carry either without claiming to be
# indexed, so refusing on them would be a false positive.
_SPINE_KEYS: frozenset[str] = frozenset({"doc_type", "status", "confidence", "domains"})


def _refuse_skipped_note_with_a_spine(path: Path) -> None:
    """Refuse a skipped file that declares a spine, rather than dropping it silently.

    Doc 2 §4 names `00-index/MEMORY.md` as the project content map, and §6a's `digest` is exactly
    that shape — so the obvious move is to put `doc_type: digest` on MEMORY.md, and before this
    check that produced a fully green compose with the note absent from the index. SKIP_NAMES'
    own comment argues the exclusion is not a silent drop because these files "are not notes";
    that reasoning held only while no doc_type could describe them, and `digest` ended it.

    Uses `_parse_frontmatter` rather than a local parser. A second implementation of "is this
    frontmatter" disagreed with the reader in BOTH directions: it refused a YAML block list (which
    the reader classifies as a thematic break, so the file has no spine at all) and it missed a
    real declaration past a fixed read window. Sharing the reader's rule is what makes "declared"
    here mean the same thing it means at ingest.

    An unreadable file is skipped, not refused: it cannot have declared anything, and these paths
    were never opened before this check existed — so a broken symlink or a non-UTF-8 `log.md` must
    not become the reason a whole scope fails to compose.
    """
    if path.name not in _NAVIGATION_NAMES:
        return
    try:
        text = _read_capped(path)
    except VaultError:
        return
    front, _ = _parse_frontmatter(text)
    declared = sorted(k for k in front if k in _SPINE_KEYS)
    if not declared:
        return
    raise VaultError(
        f"{path} declares spine fields ({', '.join(declared)}) but its filename is in the engine's "
        f"skip list, so it is never indexed. Doc 2 §6a: a `digest` is an ordinary indexed note — "
        f"give it a normal filename under 02-areas/ or 04-synthesis/. Refusing rather than "
        f"dropping a file that declared itself retrievable."
    )


def _discover_notes(vault: VaultRef) -> list[NoteRef]:
    notes: list[NoteRef] = []
    for path in sorted(vault.path.rglob("*.md")):
        # Match skip-dirs against the vault-RELATIVE path, not the absolute one — otherwise a vault
        # that happens to live under an ancestor named e.g. `99-templates` would skip every note.
        rel_parts = path.relative_to(vault.path).parts
        if any(part in SKIP_DIRS for part in rel_parts):
            continue
        if path.name in SKIP_NAMES:
            _refuse_skipped_note_with_a_spine(path)
            continue
        meta = _source_meta(path, vault.path)
        notes.append(NoteRef(
            path=path, vault=vault.name, tier=_tier_for(rel_parts),
            doc_class=meta.get("doc_class"), override_status=meta.get("status"),
            override_doc_type=meta.get("doc_type"),
            override_confidence=meta.get("confidence"),
            raw=meta.get("raw"), raw_sha256=meta.get("raw_sha256"),
            raw_location=meta.get("raw_location"),
            override_version=meta.get("version"), extra_domains=list(meta.get("domains", [])),
        ))
    return notes


def resolve_vaults(project_vault: Path) -> tuple[VaultRef, ...]:
    """The composed vault chain, roots first — inheritance only, no note discovery.

    Split out so a caller that only needs "what does this scope compose" (scope discovery, a
    freshness check) does not pay for walking every note, and — more importantly — so it reads the
    SAME resolution the compose path does. A second, cheaper implementation of "which vaults" is
    how a discovery surface comes to disagree with what is actually indexed.
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
    return tuple(ordered)


def resolve_scope(project_vault: Path) -> Scope:
    """Read a project vault's manifest, resolve its inheritance, and compose the note set to index.

    Refuses (VaultError) rather than mislead: a missing manifest, a malformed one, an inherited
    vault that does not exist, a scope that composes zero notes, or a doc_id that two notes in the
    composed scope both claim (reconcile keys the index on doc_id — a collision would silently make
    one note overwrite the other).
    """
    project_vault = project_vault.expanduser().resolve()
    ordered = list(resolve_vaults(project_vault))
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
    #
    # AND THE SAME COLLISION WHERE NO ID WAS DECLARED. The guard above catches a duplicate whose
    # doc_id is declared, because both copies carry it. It CANNOT catch the undeclared case: the id
    # then derives from filename AND content, so a copy under a different filename gets a different
    # id and both notes compose — measured 2026-08-17, all gates green, two near-identical notes
    # answering the same query.
    #
    # That is what every file-sync tool produces on a conflict, whatever it calls the sibling
    # ("… (conflicted copy)", "…-MacBookPro", "….sync-conflict-…"). Keying on those names would tie
    # this engine to one vendor's convention and fail for the next; Doc 2 §0 says the engine has an
    # opinion on shape and none on location, and a sync tool is part of location. **Byte identity is
    # the convention-independent signal** — two files with the same bytes are one note twice, which
    # is never intentional in a vault.
    #
    # EXACT ONLY, stated rather than implied: a conflict copy that was then EDITED is not caught.
    # Near-duplicate detection needs a threshold, and a threshold that refuses a whole scope on a
    # similarity score is a worse failure than the one it prevents. Measured before shipping this:
    # 693 notes across all seven live vaults, zero exact-duplicate groups — so this refuses nothing
    # that exists.
    ids: dict[str, Path] = {}
    bodies: dict[str, Path] = {}
    for n in notes:
        raw = _read_capped(n.path)
        front, _ = _parse_frontmatter(raw)  # size-checked before doc_id_for reads it
        fid = front.get("doc_id", "")
        eff = fid if _DOC_ID.fullmatch(fid) else doc_id_for(n.path)
        if eff in ids:
            raise VaultError(
                f"doc_id {eff!r} produced by two notes: {ids[eff]} and {n.path}. Composed vaults "
                "share one id space; refusing an ambiguous overwrite — one would silently replace "
                "the other at index time."
            )
        ids[eff] = n.path

        digest = hashlib.sha256(raw.encode("utf-8", "surrogateescape")).hexdigest()
        if digest in bodies:
            raise VaultError(
                f"two notes are byte-identical: {bodies[digest]} and {n.path}. That is what a file "
                "sync leaves behind when two machines edited a note, and indexing both answers one "
                "question with the same passage twice while hiding that a conflict happened. "
                "Delete or merge one, then recompose."
            )
        bodies[digest] = n.path

    # The project's own manifest is re-read for its declared name. `visit` parsed it already but
    # kept only `inherits`; the file is size-capped and tiny, and reading it here keeps the name
    # sourced from the manifest rather than inferred from the directory (they legitimately differ).
    return Scope(
        project=project_ref, vaults=tuple(ordered), notes=tuple(notes),
        name=_read_manifest(project_vault)["name"],
    )


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

    # Counted by the store, not here: this hand-rolled its own GROUP BY with a third missing-value
    # convention (`COALESCE(vault,'')`, so a NULL vault and an empty one shared a bucket). The
    # query it replaced fed only this read-out — both membership proofs above run off `doc_vault`.
    return {"by_vault": store.counts_by("vault"), "by_tier": store.counts_by("tier")}
