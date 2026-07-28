"""One contract, N renderings — the structured payload the CLI and the MCP server both emit.

Doc 3a §1: MCP is a thin adapter over the existing `RetrievalResult`; it does not define its own
result shape. This module IS that shape, and it lives in the engine rather than in either adapter
so the two cannot drift. Doc 3a §6's verification — an MCP `search` and the equivalent CLI query
must return the same passages, capability and index_version — is expressible as one equality only
because both sides call this function.

Two rules govern every field here.

**Payload discipline: snippet-first.** A passage is ~1500 chars; five of them is ~2k tokens per
query, and a model caller pays for every one. What crosses is a citation, ~200 chars, and an
`expand_ref` — expansion is a separate call, on demand. This is transport-independent discipline
that MCP makes newly important rather than newly true.

**Nothing that was withheld is silent.** Every spine field is emitted UNCONDITIONALLY, null
included, and the filters that shaped the result set are emitted as structured fields rather than
left implicit. A field that disappears when it has nothing interesting to say is prose, not a
field: its absence reads as "no claim was checked" rather than "no claim was made", and a caller
that does not know content was excluded concludes it does not exist. That is the Boundary
Principle at the one seam this whole spine exists to protect — a model that cannot see
`confidence=proposed` reads an unbuilt design as settled.
"""

from __future__ import annotations

from substrate.retrieve.retriever import RetrievalResult
from substrate.spine import STATUSES
from substrate.store.index_store import Hit

SNIPPET_CHARS = 200      # matches `query --chars`, so the two renderings cut at the same point
OUTLINE_RECORDS = 3      # the shared default, so a bare CLI --json and a bare MCP search agree
REF_SEP = "/"


class RefError(ValueError):
    """An expand_ref that does not name a scope and a chunk."""


def expand_ref(scope: str | None, chunk_id: str) -> str | None:
    """The handle a caller passes back to `expand`. Scope-qualified because ONE server serves
    every scope: a bare chunk_id would be resolved against whichever index the callee guessed,
    and a wrong guess returns a well-formed passage from the wrong vault.

    The separator-free scope name is an INVARIANT of the format, not a convention: a scope called
    `cbre/2026` issues refs that parse to scope `cbre` — which either does not exist, or does and
    is the wrong index. It is asserted here as well as refused at registration, because a ref that
    cannot round-trip is worse than no ref at all.
    """
    # No scope, no ref. A query addressed by raw db path has no name to resolve back through the
    # registry, and a handle that cannot round-trip is worse than an absent one — it looks usable.
    if not scope:
        return None
    if REF_SEP in scope:
        raise RefError(
            f"scope {scope!r} contains {REF_SEP!r}, so an expand_ref built from it cannot be "
            f"parsed back to it. Rename the vault's manifest `name`."
        )
    return f"{scope}{REF_SEP}{chunk_id}"


def parse_expand_ref(ref: str) -> tuple[str, str]:
    """`expand_ref` → (scope, chunk_id). Split on the FIRST separator: a chunk_id may contain one,
    a scope name may not, and the caller resolving the scope is what makes a bad split loud."""
    scope, sep, chunk_id = ref.partition(REF_SEP)
    if not sep or not scope or not chunk_id:
        raise RefError(
            f"malformed expand_ref {ref!r}; expected '<scope>{REF_SEP}<chunk_id>' as returned by "
            "search."
        )
    return scope, chunk_id


def _snippet(text: str, chars: int) -> tuple[str, bool]:
    body = " ".join(text.split())
    return (body[:chars], True) if len(body) > chars else (body, False)


def passage(h: Hit, *, scope: str | None, chars: int = SNIPPET_CHARS,
            full: bool = False) -> dict:
    """One hit as a consumer sees it: a snippet, a handle to the rest, and the whole spine.

    Every spine axis is present on every passage, with no field dropped for being uninteresting.
    `status` is the note's currency, `doc_type` its job, `confidence` its SETTLEDNESS (independent
    of status — a note can be active AND proposed), `domains` its retrieval tags, `vault` which
    tier it composed from, and `supersedes` the dead note this live one replaced. `unstated`
    confidence and a null `supersedes` are emitted exactly like any other value: "this note made
    no claim" is information, and it is not the same as "nobody looked".

    That last sentence was aspirational until 2026-07-28 — both states stored `unstated`, so the
    distinction it promised did not exist below this layer. It does now: `unstated` is the declared
    no-claim, `unjudged` the absence. A reader ranking a hit should treat `unjudged` as "not yet
    judged" and NEVER as "uncertain"; it is the state of 530 of 657 migrated notes and carries no
    signal about the claim at all.

    `full=True` is the `expand` path — same envelope, whole text, so a consumer never has to
    reconcile two different passage shapes. ONE key set either way: `text` is null on a search
    result rather than absent, and `snippet` is present on an expanded one. Emitting `text` only
    when populated made the shape depend on which call produced it, which is the same
    disappearing-field defect the spine fields are emitted unconditionally to avoid — and it
    contradicted the sentence above it.

    `truncated` means content was withheld from THIS payload: true for a cut snippet, false when
    the full text is included.
    """
    snippet, truncated = _snippet(h.text, chars)
    out = {
        "expand_ref": expand_ref(scope, h.chunk_id),
        "citation": h.citation,
        "path": h.path_str,
        "page": h.page_label_start,
        "n_chars": h.n_chars or len(h.text),
        # The spine — the reason this payload exists at all.
        "status": h.status,
        "doc_type": h.doc_type,
        "confidence": h.confidence,
        "domains": list(h.domains),
        "vault": h.vault,
        "supersedes": h.supersedes,
    }
    out["snippet"] = snippet
    out["text"] = h.text if full else None
    out["truncated"] = False if full else truncated
    return out


def outline_record(h: Hit, *, scope: str | None, chars: int = SNIPPET_CHARS) -> dict:
    """A section's orientation record — the two-speed layer of Doc 2 §7. Same spine, because an
    orientation record inherits the currency and settledness of the note it orients."""
    rec = passage(h, scope=scope, chars=chars)
    rec["kind"] = "outline"
    return rec


def retrieval_mode(result: RetrievalResult, *, unavailable: tuple[str, ...] = ()) -> dict:
    """Which arms actually ran and what that is measured to be worth.

    Doc 2 §7 sketched this as embedder/generator; the engine tracks the two generator-backed arms
    separately (HyDE feeds the vector query, the reranker reorders the fused list) and they fail
    independently, so both are reported rather than collapsed into one flag. `expected_mrr` is the
    measured tier for THIS exact stack or an honest null — never an estimate, never a number
    generalized from a neighbouring configuration.

    `unavailable` is the one thing `Capability` cannot say. An arm that was requested but could
    not start reports `off` — correctly, nothing ran — which is byte-identical to an arm nobody
    asked for. To a caller those are opposite situations: one means "this stack was never
    measured", the other means "start Ollama and ask again". The condition exists at the point the
    stack is built and would otherwise die there, which is the Boundary Principle exactly.
    """
    c = result.capability
    return {
        "embedder": c.embedder or None,     # null, not "lexical-only": absence is not a model name
        "hyde": c.hyde,
        "reranker": c.reranker,
        "expected_mrr": c.expected_mrr,
        "cohort": c.cohort,
        "degraded": c.degraded,
        "fallbacks": list(c.fallbacks),
        "unavailable": list(unavailable),
    }


def applied_filters(
    statuses: frozenset[str] | None, *, include_sources: bool, doc_type: str | None = None,
    document_class: str | None = None, notes: tuple[str, ...] = (),
) -> dict:
    """What this result set left out, said out loud.

    Doc 3a §2 requires the default exclusions to be surfaced structurally rather than applied
    silently, mirroring the CLI's `status filter: … · sources excluded` line. The EXCLUDED list is
    computed as the complement and carried alongside the included one on purpose: a caller who
    does not know the status vocabulary cannot derive it, and "archived and superseded notes were
    withheld" is the difference between a gap in the corpus and a gap in the query.

    (Reporting the complement is not the tautological A20 check this project retracted. That was
    an ASSERTION restating its own definition and proving nothing; this is a report, and telling a
    consumer what it did not receive is the entire job.)

    `doc_type` and `document_class` are DIFFERENT AXES and each gets its own field. `doc_type` is
    the note-job (the vocabulary is spine.DOC_TYPES); `document_class` is what kind
    of artifact a document is (reference-frozen, conversation). Reporting a class under the
    doc_type key put a value that is not a legal doc_type on that axis while leaving the filter
    that had actually been applied unreported — a false claim about what was withheld, in the one
    function whose entire contract is that nothing withheld is silent.

    `sources_excluded` answers the question a caller actually has — "could a conversation-class
    passage be in these results?" — not "did one particular SQL clause run". Those come apart
    under a class filter: `_add_class_exclusion` stands down when an explicit `document_class` is
    given, but a filter naming `reference-frozen` still withholds every conversation, by being the
    filter. Reporting `false` there said "nothing was withheld" about content that was, which is
    the failure this whole function exists to prevent. Sources are excluded unless they were asked
    for — either by `include_sources`, or by naming a source class outright.
    """
    from substrate.classes import EXCLUDED_CLASSES

    included = sorted(STATUSES) if statuses is None else sorted(statuses)
    return {
        "statuses_included": included,
        "statuses_excluded": sorted(STATUSES - set(included)),
        "sources_excluded": not (include_sources or document_class in EXCLUDED_CLASSES),
        "doc_type": doc_type,
        "document_class": document_class,
        # Anything else that narrowed this result set — a clamped `k`, today. ALWAYS present, and
        # empty when there is nothing to say: an adapter that injected this key only when it had
        # something to report made the envelope's shape depend on the request, which is the same
        # "field that disappears" defect the spine fields are emitted unconditionally to avoid.
        "notes": list(notes),
    }


def search_payload(
    result: RetrievalResult,
    *,
    scope: str | None,
    query: str,
    statuses: frozenset[str] | None,
    include_sources: bool,
    doc_type: str | None = None,
    document_class: str | None = None,
    chars: int = SNIPPET_CHARS,
    unavailable: tuple[str, ...] = (),
    db: str | None = None,
    filter_notes: tuple[str, ...] = (),
) -> dict:
    """The whole envelope: passages, orientation, capability, applied filters, index_version.

    `scope` and `index_version` travel together because either alone is unfalsifiable — a version
    hash says nothing about WHICH index it stamps when one server serves several. `db` names the
    file behind them, which is what a scope-less query has instead of a name.

    EVERY key is produced here. Both adapters previously bolted one field on after the fact — the
    CLI a `db`, the server a clamp note — so the two emitted structurally different envelopes
    while the help text promised one shape, and the exact-key-set test could not see either.
    """
    return {
        "scope": scope,
        "db": db,
        "query": query,
        "passages": [passage(h, scope=scope, chars=chars) for h in result.passages],
        "outline_records": [outline_record(h, scope=scope, chars=chars) for h in result.outlines],
        "retrieval_mode": retrieval_mode(result, unavailable=unavailable),
        "filters": applied_filters(statuses, include_sources=include_sources, doc_type=doc_type,
                                   document_class=document_class, notes=filter_notes),
        "index_version": result.index_version,
    }
