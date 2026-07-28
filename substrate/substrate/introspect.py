"""What a scope holds and whether it can be trusted right now — assembled once, rendered by both.

Sibling to `render`, which shapes retrieval RESULTS; this shapes what a caller needs to know
BEFORE reading one. It lives in the engine for the same reason: an adapter that assembled its own
status would answer a different question from the other adapter's, and the discrepancy would only
show up when someone compared them.

The honest ordering matters here. `index_version` says what the index was built from. Vector
coverage says whether the arm the capability envelope names can actually contribute. `refresh` says
what the unattended agent last managed to do. Drift says whether the vault has moved since. A
caller that reads only the first concludes an index is fine when three of the four say otherwise —
which is the whole reason `status` exists as a tool rather than as a line in the search response.

`refresh` and `drift` answer neighbouring questions and neither replaces the other. Drift is
computed HERE, live, from the notes on disk — authoritative, and a sweep over every note in the
scope. The refresh record is a lookup of what an agent reported, and it is the only one of the two
cheap enough to ride on every search response. They also disagree usefully: `drift.stale` with
`refresh.frozen` is a scope whose rebuild refused, while `drift.stale` with a clean refresh is
simply an edit made since the last tick.
"""

from __future__ import annotations

from substrate import freshness, refresh_state, scopes
from substrate import vault as _vault


def arms(stack) -> dict:
    """Which arms this PROCESS is wired with — distinct from what any one query achieved, which is
    what the per-response capability envelope reports."""
    return {
        "embedder": getattr(stack.embedder, "key", getattr(stack.embedder, "model", None))
        if stack.embedder else None,
        "hyde": getattr(stack.expander, "model", None) if stack.expander else None,
        "reranker": getattr(stack.reranker, "model", None) if stack.reranker else None,
        "unavailable": list(stack.unavailable),
    }


def vector_status(store, stack) -> dict | None:
    """Coverage for the CONFIGURED embedder, or null when no vector arm is wired.

    COMPLETENESS, not presence: a partially-embedded index answers lexically while a wired
    embedder reports live, which is what stamped a measured MRR on a lexical-only run before the
    per-query guard existed. This surfaces the same condition ahead of the query rather than only
    in the degradation that follows it.
    """
    if stack.embedder is None:
        return None
    key = getattr(stack.embedder, "key", getattr(stack.embedder, "model", ""))
    n, total = store.vector_coverage(key)
    # An EMPTY index satisfies `n >= total` as 0 >= 0. Reporting that as complete claimed full
    # vector coverage over a store with nothing in it — zero chunks is the absence of coverage,
    # not the completion of it. Same correction as the per-query guard in _retrieve.
    complete = total > 0 and n >= total
    if complete:
        note = None
    elif total == 0:
        note = "the index holds no chunks — recompose this scope"
    else:
        note = f"the vector arm cannot contribute — run `substrate embed --db {store.path}`"
    return {"model": key, "stored": n, "chunks": total, "complete": complete, "note": note}


def status_payload(store, entry, *, stack, registry: str | None = None) -> dict:
    """Everything `status` reports for one composed scope.

    The `refresh` block is the SAME shape `render.search_payload` emits — one reader, one key set,
    so a caller that learned to read it on a search result does not have to learn a second dialect
    here. It carries no clock-derived field for the reason given in `render`: the envelope is
    compared as a whole object across two processes, and a shape that varied between the two
    payloads would put that comparison back where it started.
    """
    s = store.stats()
    out = {
        "scope": entry.name,
        "db": str(entry.db),
        "vault": str(entry.vault),
        "composed": entry.composed,
        "index_version": store.index_version,
        # No `rebuilt_empty` field: every read path now opens with migrate=False, so a schema
        # mismatch REFUSES (naming both versions) instead of silently rebuilding. The flag could
        # only ever report False here, and a field that cannot vary reads as a check that ran.
        "documents": s["documents"],
        "passages": s["passages"],
        "outlines": s["outlines"],
        "schema_version": s["schema_version"],
        "by_vault": store.counts_by("vault"),
        "by_tier": store.counts_by("tier"),
        "by_status": store.counts_by("status"),
        "by_doc_type": store.counts_by("doc_type"),
        "by_confidence": store.counts_by("confidence"),
        "retrieval_arms": arms(stack),
        "vectors": vector_status(store, stack),
        "refresh": refresh_state.report(entry.name, registry),
    }
    try:
        notes = [n.path for n in _vault.resolve_scope(entry.vault).notes]
        out["drift"] = freshness.drift(store, notes)
    except _vault.VaultError as e:
        # A scope that cannot be RESOLVED cannot be drift-checked — the vault is gone, a manifest
        # is malformed, or a skip-list file declares a spine (`_refuse_skipped_note_with_a_spine`).
        # Reported as an error IN the drift slot rather than omitted: a missing key reads as
        # "nothing has changed". Note the coarseness — the whole added/changed/removed breakdown is
        # replaced by the message, so `status` says UNCHECKABLE for an authoring fault too.
        out["drift"] = {"error": str(e)}
    return out


def scopes_payload(registry: str | None = None) -> dict:
    """Every registered scope and what it composes.

    `sources` is resolved fresh from the manifest rather than remembered, because `inherits` can
    change and a vault can move after registration. A scope whose inheritance no longer resolves
    is listed WITH its fault — omitting it would read as "that scope was never composed", which is
    the opposite of the truth.
    """
    out = []
    for name, entry in sorted(scopes.load(registry).items()):
        row = {"scope": name, "db": str(entry.db), "vault": str(entry.vault),
               "composed": entry.composed, "index_present": entry.db.is_file(),
               # This is the "how are all my scopes doing" view — it already reports
               # `index_present` and a per-scope fault, so a frozen scope rendering here exactly
               # like a healthy one is the same indistinguishability the field exists to remove,
               # moved one surface over. Someone triaging with a bare `substrate status` would see
               # six clean lines while one had been answering from a superseded index for a week.
               "refresh": refresh_state.report(name, registry)}
        try:
            row["sources"] = [v.name for v in _vault.resolve_vaults(entry.vault)]
        except _vault.VaultError as e:
            row["sources"] = None
            row["error"] = str(e)
        out.append(row)
    return {"scopes": out, "registry": str(scopes.registry_path(registry))}
