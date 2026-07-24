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
