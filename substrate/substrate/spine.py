"""Spine-field validation — the refuse-rather-than-mislead gate for a note's status.

Doc 2 §6 makes `status` the field the engine enforces: it decides the default retrieval set, so
a note that carries a wrong or missing status silently changes what a query can and cannot see —
the "green gates, silent loss" shape this project keeps hitting. This module is the boundary
check: a status outside the known set, or a `superseded` note with no link to what replaced it,
is refused with the condition attached rather than indexed into a silently-wrong retrieval set.

The reader stays a pure parser; strictness lives HERE and is chosen by the caller. The
manifest-composition path requires status on every note (`require_present=True`) — a vault whose
notes do not declare status is not honouring the contract. A standalone `ingest-md` of a single
reference file defaults an absent status to `active` (`require_present=False`), so the existing
PDF/markdown corpus, which predates the field, keeps ingesting unchanged.
"""

from __future__ import annotations

from substrate.models import Document

# The four Doc-2 §6 statuses and their default-retrieval membership. INCLUDED_STATUSES is the
# single source of truth for "the default retrieval set" — the store filter and its audit both
# read it, so the set the engine excludes can never drift from the set it claims to exclude.
STATUSES: frozenset[str] = frozenset({"active", "complete", "archived", "superseded"})
INCLUDED_STATUSES: frozenset[str] = frozenset({"active", "complete"})
EXCLUDED_STATUSES: frozenset[str] = STATUSES - INCLUDED_STATUSES  # {archived, superseded}

# The five Doc-2 §6a doc_types: the JOB a note does. Four are Diátaxis-derived; `digest` (a
# maintained per-area summary that POINTS at atomic notes, never contains them) is not. The
# rationale, the placement rule and the discipline are Doc 2 §6a — docs/README.md: this repo
# implements the contract, it does not define it, and a summary here would drift out of agreement.
#
# What IS this code's business: unlike status, doc_type has no default-retrieval partition — every
# value is retrievable — so there is no included/excluded split, only membership. `reference` is
# the lenient default: a standalone ingest is reference lookup material (the PDF corpus), and a
# note that reaches the store without a declared type is treated as reference rather than
# mislabelled as a decision/explanation it may not be.
DOC_TYPES: frozenset[str] = frozenset(
    {"decision", "explanation", "reference", "how-to", "digest"}
)
DEFAULT_DOC_TYPE = "reference"
# Named because `digests.py` keys an entire check on this one value, and a hand-copied string there
# would be a second author for a vocabulary this module owns — the shape `cli._refresh_outcomes`
# already refuses for the refresh outcomes.
DIGEST_DOC_TYPE = "digest"

# CONFIDENCE — how settled a note's claims are, and the axis `status` was silently absorbing.
#
# status answers "is this note live?"; confidence answers "why should I believe it?". They are
# independent: a note can be `active` AND `proposed`. Collapsing them is confidence laundering — a
# design that was never built retrieves as current with nothing saying so, which is WRITING.md
# rule 6 ("preserve confidence markers") having no carrier past the note body. Rule 6 is
# unenforceable prose until the marker is a FIELD that survives chunking, exactly as the capability
# envelope attaches its conditions to the result rather than beside it.
#
# The values are a provenance-of-claim axis, not an ordered scale (nothing ranks them):
#   proposed  — put forward as a design or suggestion; not built, ratified, or tested.
#   inferred  — derived from observation or reasoning; could be wrong.
#   stated    — asserted directly by an authority (the operator, or a published source).
#   verified  — measured, tested, or confirmed against reality.
CONFIDENCES: frozenset[str] = frozenset({"proposed", "inferred", "stated", "verified"})

# Absence is surfaced, never smoothed. A note that declares no confidence is making no claim about
# how settled it is, and that is information — so it is stored as a real value rather than NULL.
# Defaulting an absent marker to anything confident would BE the laundering this axis exists to
# stop, and a NULL would reintroduce the `NULL NOT IN (…)` hole the doc_type audit already had to
# correct.
#
# But "the author judged this note and it claims nothing" and "nobody has looked yet" are DIFFERENT
# FACTS, and until 2026-07-28 both stored `unstated`. Measured then, from the composed databases and deduplicated by doc_id
# (core-vault is re-counted in every scope): 530 of 657 distinct notes had no
# confidence key at all, while six `_sources` conversation notes DECLARED `confidence: unstated`
# deliberately — a transcript's settledness varies within it, so no single marker is true of the
# whole. Those six were byte-identical in the store to the 530 nobody had judged — a declared value
# that did not survive into anything downstream, which is PRINCIPLES.md's third law on this axis.
#
# Be precise about the blast radius rather than overstating it: all six are `class: conversation`
# under `_sources/`, so they are already outside DEFAULT retrieval and no ordinary query was
# mislabelled by the collapse. What it did cost is real but narrower — A23's per-value counts, any
# `--include-sources` hit, and every future filter on this axis, none of which could tell a
# deliberate no-claim from an unexamined note. The reason to fix it is that the axis is meant to be
# filterable, and a value that cannot be distinguished cannot be filtered on.
#
#   unstated  — DECLARED. Judged; makes no settledness claim of its own. Satisfies a write gate.
#   unjudged  — ABSENT. Nobody has decided. The migration's honest default.
#
# `unjudged` is storable but NEVER declarable: it is the absence marker, so accepting it in
# frontmatter would let an author satisfy `require_present` while declaring nothing — the gate
# bypassed by the very value that means "ungated". A note meaning "no claim" writes `unstated`.
UNSTATED_CONFIDENCE = "unstated"
UNJUDGED_CONFIDENCE = "unjudged"
DECLARABLE_CONFIDENCES: frozenset[str] = CONFIDENCES | {UNSTATED_CONFIDENCE}
STORED_CONFIDENCES: frozenset[str] = DECLARABLE_CONFIDENCES | {UNJUDGED_CONFIDENCE}


class SpineError(RuntimeError):
    """A note's spine fields are inconsistent — refuse rather than index a silently-wrong set."""


def validate_status(doc: Document, *, require_present: bool) -> str:
    """Enforce the status contract and return the effective status. Raises SpineError on violation.

    Three ways a note misleads, each refused:
      * status declared but outside the known four — an unknown value would be silently EXCLUDED by
        the default filter (it is not in INCLUDED_STATUSES), reading as absence with no signal.
      * status absent where the caller requires it (the vault path) — an undeclared note would
        default to `active` and join the live surface without anyone having said it should.
      * status `superseded` with no `superseded_by` — a dead fact excluded from retrieval AND with
        no pointer to the live one that replaced it: the history it exists to preserve is lost.
    """
    status = doc.status
    if status is None:
        if require_present:
            raise SpineError(
                f"{doc.doc_id}: no status. Doc-2 §6 requires every note to declare one of "
                f"{sorted(STATUSES)} — refusing to default it into the live retrieval set."
            )
        return "active"
    if status not in STATUSES:
        raise SpineError(
            f"{doc.doc_id}: status {status!r} is not one of {sorted(STATUSES)}. An unknown status "
            "is silently excluded by the default filter — refusing rather than dropping it unseen."
        )
    if status == "superseded" and not doc.superseded_by:
        raise SpineError(
            f"{doc.doc_id}: status 'superseded' but no 'superseded_by'. A superseded note is "
            "excluded from retrieval; without the link to what replaced it, its decision history "
            "is unreachable — the supersession link is what makes exclusion safe."
        )
    return status


def validate_doc_type(doc: Document, *, require_present: bool) -> str:
    """Enforce the Doc-2 §6a doc_type contract and return the effective doc_type. Raises on violation.

    Mirrors validate_status's two strictness modes (chosen by the caller, not the reader):
      * doc_type absent where required (the vault path) — every note must DECLARE its job. Defaulting
        it would defeat the point of the field: the split into decision/explanation/reference/how-to/
        digest is what keeps a note readable, and a silent default hides a note that blends two jobs
        (§6a rule 8). A reference source supplies `doc_type: reference` via its `_meta.md`, same as
        status.
      * doc_type outside the known five — an unknown value is not a retrieval job the engine or a
        reader can act on; refuse it rather than carry a phantom axis value.

    Absent-and-lenient (the standalone ingest of the existing reference corpus) returns the
    `reference` default, so that corpus keeps ingesting unchanged.
    """
    dt = doc.doc_type
    if dt is None:
        if require_present:
            raise SpineError(
                f"{doc.doc_id}: no doc_type. Doc-2 §6a requires every note to declare one of "
                f"{sorted(DOC_TYPES)} — the job it does. Refusing to default it and hide a note "
                "that may blend two jobs."
            )
        return DEFAULT_DOC_TYPE
    if dt not in DOC_TYPES:
        raise SpineError(
            f"{doc.doc_id}: doc_type {dt!r} is not one of {sorted(DOC_TYPES)}. An unknown doc_type "
            "is a retrieval axis value nothing can act on — refusing rather than carrying it."
        )
    return dt


def validate_confidence(doc: Document, *, require_present: bool = False) -> str:
    """Enforce the confidence contract and return the effective value. Raises SpineError on an
    unknown value, on the absence marker being declared, and on absence where required.

    `require_present` DEFAULTS TO FALSE, unlike status and doc_type, and the asymmetry is the whole
    sequencing decision (2026-07-28). Flipping it globally would refuse 530 of 657 indexed notes at
    the next compose — which a launchd agent runs unattended every 15 minutes. Worse than loud:
    `cmd_compose` returns before it opens the IndexStore, so the DB keeps its last good content and
    every scope would answer queries normally while silently frozen, with no drift field on the
    result envelope to say so. That is PRINCIPLES.md's second law (promoting a check to a gate
    audits every value it now judges) landing in the one place the first law makes invisible.

    So the gate is per-caller: the vault WRITE path (`notes.py`) passes True, because a note being
    authored now has someone present to judge it. `compose` leaves it False, grandfathering a corpus
    whose `unjudged` majority is not a defect — `MIGRATION-VOCABULARY.md` §8 records it as the
    ratified source-signal policy, and WRITING.md forbids inventing a marker to fill the field.

    Absence returns UNJUDGED, not UNSTATED: see the vocabulary comment above. Declaring UNJUDGED is
    refused, so `require_present` cannot be satisfied by the value that means "not judged".
    """
    c = doc.confidence
    if c is None or c == "":
        if require_present:
            raise SpineError(
                f"{doc.doc_id}: no confidence. A note written into a vault must declare one of "
                f"{sorted(DECLARABLE_CONFIDENCES)} — including {UNSTATED_CONFIDENCE!r}, which is "
                "the honest value for a note that makes no settledness claim. Absence is reserved "
                f"for {UNJUDGED_CONFIDENCE!r}, the state of a note nobody has judged yet."
            )
        return UNJUDGED_CONFIDENCE
    if c == UNJUDGED_CONFIDENCE:
        raise SpineError(
            f"{doc.doc_id}: confidence {UNJUDGED_CONFIDENCE!r} is the ABSENCE marker and cannot be "
            f"declared — declaring it would assert that nobody judged this note, which the act of "
            f"writing it contradicts. Omit the key, or write {UNSTATED_CONFIDENCE!r} if the note "
            "makes no settledness claim."
        )
    if c not in DECLARABLE_CONFIDENCES:
        raise SpineError(
            f"{doc.doc_id}: confidence {c!r} is not one of {sorted(DECLARABLE_CONFIDENCES)}. "
            "Confidence answers how SETTLED a claim is — a certainty "
            "word like 'high' belongs in the note body, not on this axis."
        )
    return c
