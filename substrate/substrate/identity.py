"""Who a note mentions, resolved from a file the vault declares.

THE ENGINE DOES NOT OWN IDENTITY, and that is the decision this module implements rather than a
limitation it works around. A person is the one thing here NOT derived from a document's text: the
knowledge that "A. McGinn", "Alexandra" and "McGinn, Alexandra @ Philadelphia" are one person is a
RULE somebody authored, and the pairwise "these two are the same" judgements behind it are hand-made
and expensive to remake.

The index cannot hold that. `compose --clean` drops and rebuilds every table, which is correct for
derived data and fatal for authored data — a merge decision an index rebuild could erase is worse
than no identity layer at all. So the rules live in a file the VAULT owns and this module only ever
READS them, re-deriving the mention cache on every compose. Losing the cache costs a compose.

DECLARED, THE WAY THE GUARD IS. A manifest may carry:

    identity = "/abs/path/to/identity.json"

holding `{"entities": [{"id", "name", "kind", "aliases", "gloss"}]}`. Unknown keys are ignored, so
the file an application already maintains for its own purposes can be pointed at directly without
being reshaped for the engine — Scripta's registry carries `groups`, `confirmed` and a `verdicts`
block that mean nothing here and cost nothing to skip.

SHARED BY DESIGN (operator, 2026-08-07). One file behind every scope means one identity everywhere:
the same person found in a call and in a project note is the same id, which is the entire point of
having ids. The alternative — a registry per workspace — makes "Alexandra" a different person in
each, which is a partition the operator did not ask for and cannot easily undo.
"""

from __future__ import annotations

import json
import re
import tomllib
from dataclasses import dataclass, field
from pathlib import Path

MANIFEST = ".substrate.toml"
IDENTITY_KEY = "identity"

# An identity file is a roster, not a corpus. Larger than this is a wrong file at that path.
MAX_IDENTITY_BYTES = 8 * 1024 * 1024

# A surface shorter than this is not evidence. "Al", "JD" and "PM" match half a transcript by
# accident, and a false mention is worse than a missing one: it puts a person's name on a document
# they never appear in, which is the one error an identity layer must not make.
MIN_SURFACE_CHARS = 3


class IdentityError(RuntimeError):
    """The declared identity file cannot be used. Compose reports it rather than indexing without."""


@dataclass(frozen=True)
class Entity:
    entity_id: str
    name: str
    kind: str | None = None
    gloss: str | None = None
    #: Every surface that resolves here, including the display name. Normalized, deduplicated.
    surfaces: tuple[str, ...] = field(default_factory=tuple)


def declared_identity(vault_dir: Path) -> Path | None:
    """The identity file this vault names, or None. An unreadable manifest is compose's error to
    report in its own words, so it reads as "none declared" here."""
    path = vault_dir / MANIFEST
    try:
        manifest = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError):
        return None
    declared = manifest.get(IDENTITY_KEY)
    if declared is None:
        return None
    if not isinstance(declared, str) or not declared.strip():
        raise IdentityError(
            f"{path} declares {IDENTITY_KEY!r} but not as a path. Refusing to compose an identity "
            f"layer from a declaration that names no file."
        )
    return Path(declared).expanduser()


def load(path: Path) -> list[Entity]:
    """The roster, or a refusal naming what is wrong with it.

    REFUSES RATHER THAN DEGRADES. A half-read roster silently drops people, and a document that
    stops mentioning someone reads exactly like a document that never did — the same
    absent-evidence failure the whole engine is arranged against. A declared file that cannot be
    read is a compose error, not a quietly emptier index.
    """
    try:
        raw = path.read_bytes()
    except OSError as e:
        raise IdentityError(f"the declared identity file {path} cannot be read ({e}).") from None
    if len(raw) > MAX_IDENTITY_BYTES:
        raise IdentityError(f"the identity file {path} is implausibly large to be a roster.")
    try:
        doc = json.loads(raw)
    except ValueError as e:
        raise IdentityError(f"the identity file {path} is not readable JSON ({e}).") from None
    if not isinstance(doc, dict):
        raise IdentityError(f"the identity file {path} is not an object.")

    rows = doc.get("entities")
    if rows is None:
        raise IdentityError(f"the identity file {path} declares no `entities`.")
    if not isinstance(rows, list):
        raise IdentityError(f"`entities` in {path} is not a list.")

    out: list[Entity] = []
    for row in rows:
        if not isinstance(row, dict):
            continue
        entity_id = row.get("id")
        name = row.get("name")
        if not isinstance(entity_id, str) or not entity_id.strip():
            continue
        if not isinstance(name, str) or not name.strip():
            continue
        surfaces = {name}
        aliases = row.get("aliases")
        if isinstance(aliases, list):
            surfaces.update(a for a in aliases if isinstance(a, str))
        kept = tuple(sorted({s.strip() for s in surfaces
                             if len(s.strip()) >= MIN_SURFACE_CHARS}, key=len, reverse=True))
        if not kept:
            continue
        out.append(Entity(entity_id=entity_id.strip(), name=name.strip(),
                          kind=_optional_str(row.get("kind")),
                          gloss=_optional_str(row.get("gloss")),
                          surfaces=kept))
    return out


def mentions(text: str, entities: list[Entity]) -> dict[str, set[str]]:
    """`entity_id` → the surfaces that actually appear in `text`.

    WORD-BOUNDED AND CASE-INSENSITIVE. Substring matching makes "Ana" a mention inside "analysis"
    and "Tim" one inside "estimate", which would attribute documents to people who are not in them.
    A missing mention costs recall; a false one puts someone's name on a conversation they were
    never part of, so the boundary is not an optimisation.

    Surfaces are tried LONGEST FIRST and a document records every surface that matched, because the
    surface is the evidence: an operator auditing a wrong merge needs to see what was written, not
    only what it resolved to.
    """
    found: dict[str, set[str]] = {}
    for entity in entities:
        for surface in entity.surfaces:
            if re.search(rf"(?<!\w){re.escape(surface)}(?!\w)", text, re.IGNORECASE):
                found.setdefault(entity.entity_id, set()).add(surface)
    return found


def _optional_str(value: object) -> str | None:
    return value.strip() or None if isinstance(value, str) else None
