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

import json

from substrate.retrieve.retriever import RetrievalResult
from substrate.spine import STATUSES, UNJUDGED_CONFIDENCE
from substrate.store.index_store import Hit, decode_string_list

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
    tier it composed from, and `supersedes` the LIST of dead notes this live one replaced — `[]`
    when it replaced nothing, several entries when it consolidated several. `unstated` confidence
    and an empty `supersedes` are emitted exactly like any other value: "this note made no claim"
    is information, and it is not the same as "nobody looked".

    That last sentence was aspirational until 2026-07-28 — both states stored `unstated`, so the
    distinction it promised did not exist below this layer. It does now: `unstated` is the declared
    no-claim, `unjudged` the absence. A reader ranking a hit should treat `unjudged` as "not yet
    judged" and NEVER as "uncertain"; it is the state of 530 of 657 migrated notes and carries no
    signal about the claim at all.

    `document_class` is a DIFFERENT AXIS from all of those — not what job the note does, but what
    KIND of artifact it came out of (`classes.POLICIES`). It is here because `conversation` is the
    class default retrieval withholds, and a conversation passage that arrived without it was
    indistinguishable from default corpus: it rendered as settled knowledge, when the reason the
    class is withheld at all is that confidence varies WITHIN a transcript and a mid-conversation
    passage may be reasoning the same session abandoned four turns later.

    AN UNDECLARED CLASS CROSSES AS `unclassified`, its own token, and this is the half that was
    missing. The markdown reader used to default an absent `class:` to `reference-frozen` at
    INGEST — the defaulting that once relabelled six migrated conversations under a fully green
    compose — so "the note declared reference-frozen" and "the note declared nothing" arrived here
    as ONE VALUE and no honest field on this side could separate them. It no longer defaults:
    `classes.apply` resolves absence to `classes.UNCLASSIFIED_CLASS`, which is a legal stored value
    (the column is NOT NULL) and never NULL, so the distinction survives to the consumer. It is
    retrieved by default like any note — an absent label is evidence about the label, not about the
    note — and the client draws it with the ABSENT prominence it draws `unjudged` confidence with,
    rather than as a settled axis.

    NULL still means something, and something NARROWER: this index row carries no class at all,
    which is reachable only for a document built outside the reader and the class gate. Defaulting
    THAT to `reference-frozen` would be a second copy of the same bug, one layer further from the
    evidence — and defaulting it to `unclassified` would be a third, because a row that never
    passed the gate has not been judged undeclared, it has not been judged.

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
        # What KIND of artifact this came out of — the axis `applied_filters` reports the FILTER
        # for and the passage itself did not state. An undeclared class arrives here as
        # `unclassified` and is emitted as that word; `or None` covers only the narrower case of an
        # index row with no class at all, which says so rather than borrowing a real one.
        "document_class": h.document_class or None,
        # The spine — the reason this payload exists at all.
        "status": h.status,
        "doc_type": h.doc_type,
        "confidence": h.confidence,
        "domains": list(h.domains),
        "vault": h.vault,
        # A LIST as of v8 — `[]` when this note replaced nothing, never null. One live note can
        # replace several dead ones, and a scalar could name only one of them.
        "supersedes": list(h.supersedes),
    }
    out["snippet"] = snippet
    out["text"] = h.text if full else None
    out["truncated"] = False if full else truncated
    return out


def document_record(row: dict, *, scope: str | None) -> dict:
    """One note as a BROWSER sees it: its spine, where it came from, and a handle to read it.

    Deliberately NOT a `passage`. A passage is a retrieval result and carries a snippet, a score's
    worth of context, and the structural path it was cut from; a note in a browse list has no
    query behind it and inventing a snippet would be picking an arbitrary sentence and presenting
    it as the note's gist. `passage_count` says how much there is instead — a number the caller can
    read as size without it pretending to be summary.

    `expand_ref` names the note's FIRST passage, so reading is `expand(ref, mode="note")` — the
    same call a search result's ref takes, hitting the same reader, returning the same envelope
    with the same freshness verdict. A second read path would be a second place for "the vault has
    moved on since the index was built" to be got wrong.

    NO `source_path`. It was here and is deliberately gone: it was the largest field in the record
    and the most identifying, so a single call handed back every note filename and the operator's
    whole directory layout in bulk — an amplification `search` did not offer, over a port any local
    process can reach, and undocumented in the tool contract besides. A caller that has actually
    selected a note gets the path from `expand`, which is one note at a time and asked for by name.

    It is NULL for a note with no passages, and that is the honest answer rather than a defect to
    paper over: an empty note is in the corpus (it appears in this list, which is the point) and
    there is nothing to expand. A caller draws it as unreadable; a fabricated ref would fail at
    `expand` instead, one call later and further from the cause.
    """
    from substrate.markdown import reader

    return {
        "doc_id": row["doc_id"],
        "title": row.get("title"),
        "expand_ref": expand_ref(scope, row["first_chunk_id"]) if row.get("first_chunk_id") else None,
        "passage_count": row.get("passage_count", 0),
        # The composition provenance: WHICH vault in the chain this note came from, and the tier
        # that vault's layout put it at. In an inheriting scope this is the difference between the
        # operator's own note and one they share with every other project.
        "vault": row.get("vault"),
        "tier": row.get("tier"),
        "document_class": row.get("document_class") or None,
        # The spine, same keys and same fallbacks as `passage` — a note must not read as one thing
        # in a search result and another in a list.
        "status": row.get("status") or "active",
        "doc_type": row.get("doc_type") or "reference",
        "confidence": row.get("confidence") or UNJUDGED_CONFIDENCE,
        # `decode_string_list`, the SAME decoder `_row_to_hit` runs — so a malformed row reads
        # identically in a browse list and a search result, which is what "same fallbacks as
        # `passage`" above actually requires. It also swallows the decode itself: the guard used to
        # sit after the `json.loads` that raises, so non-JSON text still took the whole listing with
        # it while the comment claimed otherwise.
        "domains": decode_string_list(row.get("domains")),
        "supersedes": reader.doc_id_list(json.loads(row.get("supersedes") or "[]")),
        "superseded_by": row.get("superseded_by"),
    }


def documents_payload(
    rows: list[dict], total: int, *,
    scope: str | None,
    statuses: frozenset[str] | None,
    include_sources: bool,
    doc_type: str | None = None,
    vault: str | None = None,
    index_version: str,
    db: str | None = None,
    filter_notes: tuple[str, ...] = (),
    registry: str | None = None,
) -> dict:
    """The browse envelope. Same outer shape as `search_payload` — scope, db, filters,
    index_version, refresh — because a caller that has learned to read one envelope has learned to
    read this one, and the conditions that make an answer untrustworthy are the same conditions
    whether or not a query produced it.

    `total` and `returned` are BOTH reported. A page that happens to be shorter than the limit and
    a corpus that is genuinely that size look identical from the list alone, and "this is
    everything" is exactly the kind of claim this engine refuses to make by omission.

    No `retrieval_mode`: nothing retrieved. Reporting an arms block here would say a stack ran when
    a WHERE clause did, and a null `expected_mrr` attached to a browse would invite the reading
    that the LIST is unmeasured rather than inapplicable.
    """
    from substrate import refresh_state

    return {
        "scope": scope,
        "db": db,
        "documents": [document_record(r, scope=scope) for r in rows],
        "returned": len(rows),
        "total": total,
        # The vault narrowing is reported on its OWN AXIS now, not as a free-text note. It was a
        # note because `applied_filters` had nowhere to put it; it does now, and a structured field
        # is what a caller can act on.
        "filters": applied_filters(statuses, include_sources=include_sources, doc_type=doc_type,
                                   vaults=None if vault is None else frozenset({vault}),
                                   notes=filter_notes),
        "index_version": index_version,
        "refresh": refresh_state.report(scope, registry),
    }


def outline_record(h: Hit, *, scope: str | None, chars: int = SNIPPET_CHARS) -> dict:
    """A section's orientation record — the two-speed layer of Doc 2 §7. Same spine, because an
    orientation record inherits the currency and settledness of the note it orients."""
    rec = passage(h, scope=scope, chars=chars)
    rec["kind"] = "outline"
    return rec


def retrieval_mode(result: RetrievalResult, *, unavailable: tuple[str, ...] = (),
                   wiring: dict[str, str] | None = None) -> dict:
    """Which arms actually ran and what that is measured to be worth.

    Doc 2 §7 sketched this as embedder/generator; the engine tracks the two generator-backed arms
    separately (HyDE feeds the vector query, the reranker reorders the fused list) and they fail
    independently, so both are reported rather than collapsed into one flag. `expected_mrr` is the
    measured tier for THIS exact stack or an honest null — never an estimate, never a number
    generalized from a neighbouring configuration. `unmeasured_reason` is why there is no number,
    and it is not optional garnish: "unmeasured" alone is indistinguishable from a bug, while the
    engine knew which of `retriever.UNMEASURED_REASONS` applied at the moment it declined.

    `embedder_state` is the state word the embedder arm never had. `hyde` and `reranker` report
    what they DID; the embedder reported only its model key, which empties on a fallback and is
    then byte-identical to an arm nobody asked for. Three arms, two vocabularies, and the missing
    one belonged to the arm the vector-coverage guard degrades most often.

    `unavailable` is the one thing `Capability` cannot say. An arm that was requested but could
    not start reports `off` — correctly, nothing ran — which is byte-identical to an arm nobody
    asked for. To a caller those are opposite situations: one means "this stack was never
    measured", the other means "start Ollama and ask again". The condition exists at the point the
    stack is built and would otherwise die there, which is the Boundary Principle exactly.

    `health` is that same condition as STRUCTURE rather than prose, for all three arms at once —
    see `engine_health`. It does not replace `unavailable`: the prose still carries the model and
    the host it was looked for at, which is what a human acts on. It replaces the parse a consumer
    was otherwise forced to run over our sentences to recover the arm name.
    """
    c = result.capability
    return {
        "embedder": c.embedder or None,     # null, not "lexical-only": absence is not a model name
        "embedder_state": c.embedder_state,
        "hyde": c.hyde,
        "reranker": c.reranker,
        "expected_mrr": c.expected_mrr,
        "unmeasured_reason": c.unmeasured_reason,
        "cohort": c.cohort,
        "degraded": c.degraded,
        "fallbacks": list(c.fallbacks),
        "unavailable": list(unavailable),
        "health": engine_health(wiring, unavailable),
    }


# What the caller did not tell us, said as itself. A wiring-less call is a caller that never
# reported which arms it asked for — not a caller whose arms are all fine.
_WIRING_UNREPORTED = (
    "the caller did not report which arms it wired, so nothing here says whether a requested arm "
    "failed to start. `substrate status` reports the arms this process holds."
)
_NOTHING_ASKED = (
    "no local-model arm was requested — the zero-dependency path, which is a configuration and "
    "not a fault."
)
_SOMETHING_DID_NOT_START = (
    "an arm was requested and could not start; `unavailable` names it and where it was looked "
    "for. WHY it did not start is NOT reported here and must not be inferred: the probe collapses "
    "a refused connection, a timeout and a missing model into one answer, so 'no model server "
    "installed' — the zero-install default, not a fault — and 'installed and down' are the same "
    "observation from where this runs."
)
_UNATTRIBUTED = (
    "something was requested and could not start, but no entry in `unavailable` names one of the "
    "known arms — so this cannot say WHICH. Read `unavailable` directly; the arms map below is "
    "reporting less than the prose does."
)


def engine_health(wiring: dict[str, str] | None, unavailable: tuple[str, ...] = ()) -> dict:
    """The condition of the arms THEMSELVES — a different axis from what they did on this query.

    Every state here is observable. The one a UI most wants is not: "no local model server
    installed" and "installed and unreachable" need different words on screen, and this engine
    cannot tell them apart. `available()` returns a bool over a probe that swallows a refused
    connection, a timeout and a missing model alike, and nothing anywhere looks for an
    installation — so a field claiming that distinction would be reporting a guess, which is worse
    than the field being absent. It is stated in `note` instead, because "we cannot tell" is an
    answer and silence is not.

    `known: false` is a caller that passed no wiring. Not folded into `ready`: a healthy-looking
    default that requires nothing to have happened is the shape every field in this module exists
    to remove — the same reason `refresh.frozen` is null rather than false with no record.

    `unavailable` is read only to make the two carriers unable to CONTRADICT each other. The arm
    map recovers its names from the leading token of each entry, and an entry that led with
    something else would drop out of the map silently while remaining in the prose — leaving this
    to report `ready` over a stack with a dead arm. So a non-empty `unavailable` forces
    `unreachable` whichever way the attribution went; the map says which arm when it can, and says
    that it cannot when it cannot.
    """
    from substrate.stack import ARMS, ARM_OFF, ARM_UNAVAILABLE

    if wiring is None:
        return {"known": False, "state": None, "arms": None, "note": _WIRING_UNREPORTED}
    # Normalized against the arm vocabulary rather than copied: a map missing an arm would make
    # that arm's absence mean either `off` or "this caller predates the field", and a map carrying
    # an extra key would put a name on the wire that no consumer has an arm for.
    arms = {a: wiring.get(a, ARM_OFF) for a in ARMS}
    named = ARM_UNAVAILABLE in arms.values()
    if named or unavailable:
        state = "unreachable"
        note = _SOMETHING_DID_NOT_START if named else _UNATTRIBUTED
    elif set(arms.values()) == {ARM_OFF}:
        state, note = "lexical_only", _NOTHING_ASKED
    else:
        state, note = "ready", None     # a healthy stack does not need a sentence
    return {"known": True, "state": state, "arms": arms, "note": note}


def applied_filters(
    statuses: frozenset[str] | None, *, include_sources: bool, doc_type: str | None = None,
    document_class: str | None = None, vaults: frozenset[str] | None = None,
    notes: tuple[str, ...] = (),
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
        # WHICH TIERS OF THE COMPOSED CHAIN ANSWERED. `null` is every vault the scope composes —
        # the default — and a list is the narrowing the caller asked for. Emitted unconditionally
        # like every other axis: a reader who does not know the answer came from one tier of an
        # inheriting scope reads a partial corpus as the whole one.
        "vaults": None if vaults is None else sorted(vaults),
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
    vaults: frozenset[str] | None = None,
    chars: int = SNIPPET_CHARS,
    unavailable: tuple[str, ...] = (),
    wiring: dict[str, str] | None = None,
    db: str | None = None,
    filter_notes: tuple[str, ...] = (),
    registry: str | None = None,
) -> dict:
    """The whole envelope: passages, orientation, capability, applied filters, index_version, and
    what the refresh agent last did to this scope.

    `scope` and `index_version` travel together because either alone is unfalsifiable — a version
    hash says nothing about WHICH index it stamps when one server serves several. `db` names the
    file behind them, which is what a scope-less query has instead of a name.

    `refresh` closes the gap PRINCIPLES.md predicted and the unattended refresh agent then opened.
    `index_version` says what the index was BUILT from; nothing said whether the job that keeps it
    current had succeeded. So a scope whose recompose refused kept answering from the superseded
    index in an envelope byte-identical to a healthy run — the Boundary Principle at the one seam a
    background job creates. It is READ here, not passed in, precisely because an adapter that had
    to remember to attach it is an adapter that will one day not: the field exists to survive the
    person who forgets to look for it. Cost is one small JSON read; the real drift check
    (`freshness.drift`) is a stat-and-hash sweep over every note and is `status`'s job, not this
    one's.

    NOTHING HERE READS A CLOCK, and that is a constraint rather than an omission. Doc 3a §6's
    verification compares the CLI's envelope to the server's as whole dicts, produced by two
    processes at two instants; a derived age would make that equality flaky and the flake would be
    read as divergence. So the timestamps cross as RECORDED VALUES and no component ages them —
    not this one, not `status`. A consumer that wants an interval compares `attempted` against
    `succeeded`, both of which are here. (An earlier draft of this paragraph handed the ageing
    verdict off to `status`, which does not implement one and whose own docstring says it does
    not — a docstring asserting a property nobody implemented, which is the failure this repo has
    now recorded five times.)

    `wiring` is the counter-example to `refresh`, and the asymmetry is not an oversight. It is the
    adapter's PROCESS state — which arms this CLI invocation or this long-lived server managed to
    start — and no amount of reading from here can recover it, so it is passed or it is absent.
    Absent is a real answer (`health.known: false`) rather than a defaulted-healthy one, which is
    what makes forgetting it loud instead of flattering.

    EVERY key is produced here. Both adapters previously bolted one field on after the fact — the
    CLI a `db`, the server a clamp note — so the two emitted structurally different envelopes
    while the help text promised one shape, and the exact-key-set test could not see either.
    """
    # Imported here rather than at module top so `render` stays importable without dragging in
    # `scopes` (and `fcntl`) — the shape a Swift port reimplements is the payload, not the
    # machine-local state beside it. Nothing about a cycle: `scopes` imports `render` only inside
    # `record()`, and an earlier version of this comment claimed an import-weight saving that was
    # not real, since `render` already imports the retriever at module top.
    from substrate import refresh_state

    return {
        "scope": scope,
        "db": db,
        "query": query,
        "passages": [passage(h, scope=scope, chars=chars) for h in result.passages],
        "outline_records": [outline_record(h, scope=scope, chars=chars) for h in result.outlines],
        "retrieval_mode": retrieval_mode(result, unavailable=unavailable, wiring=wiring),
        "filters": applied_filters(statuses, include_sources=include_sources, doc_type=doc_type,
                                   document_class=document_class, vaults=vaults,
                                   notes=filter_notes),
        "index_version": result.index_version,
        "refresh": refresh_state.report(scope, registry),
    }
