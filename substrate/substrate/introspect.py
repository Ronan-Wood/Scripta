"""What a scope holds and whether it can be trusted right now — assembled once, rendered by both.

Sibling to `render`, which shapes retrieval RESULTS; this shapes what a caller needs to know
BEFORE reading one. It lives in the engine for the same reason: an adapter that assembled its own
status would answer a different question from the other adapter's, and the discrepancy would only
show up when someone compared them.

The honest ordering matters here. `index_version` says what the index was built from. Vector
coverage says whether the arm the capability envelope names can actually contribute. Drift says
whether the vault has moved since. A caller that reads only the first concludes an index is fine
when two of the three say otherwise — which is the whole reason `status` exists as a tool rather
than as a line in the search response.
"""

from __future__ import annotations

from substrate import freshness, scopes
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


def status_payload(store, entry, *, stack) -> dict:
    """Everything `status` reports for one composed scope."""
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
    }
    try:
        notes = [n.path for n in _vault.resolve_scope(entry.vault).notes]
        out["drift"] = freshness.drift(store, notes)
    except _vault.VaultError as e:
        # A scope whose vault no longer resolves cannot be drift-checked. Reported as an error IN
        # the drift slot rather than omitted: a missing key reads as "nothing has changed".
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
               "composed": entry.composed, "index_present": entry.db.is_file()}
        try:
            row["sources"] = [v.name for v in _vault.resolve_vaults(entry.vault)]
        except _vault.VaultError as e:
            row["sources"] = None
            row["error"] = str(e)
        out.append(row)
    return {"scopes": out, "registry": str(scopes.registry_path(registry))}
