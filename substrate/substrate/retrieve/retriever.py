"""Retriever — retrieval STRATEGY over the IndexStore facade.

Split deliberately: IndexStore owns SQL, this owns how results are combined. Same division
Scripta uses (Retriever.swift over ScriptaCore.IndexStore), and it is what lets fusion change
without touching the store.

The idea worth stating: **the outline layer is a routing signal.** A query phrased in plain
language often shares no vocabulary with any individual passage ("what happens when the main
machine dies and another has to take over" vs a passage about failover), yet the SECTION's
orientation record — path, lede, child headings, summary — is a compact description of what
that section covers and matches much better. Hitting the outline, then pulling passages
beneath it, reaches content that direct passage search cannot, with no embedder involved.

Fusion is Reciprocal Rank Fusion: parameter-free, scale-free, and it does not require the
two result lists to have comparable scores (BM25 over passages and BM25 over outline records
are not on the same scale). Same choice, and same k=60, as Scripta's RRF.

## MEASURED RESULT: routing is OFF by default. It did not pay for itself.

Kept, with its measurement, so the idea is not re-litigated from scratch — the reasoning is
sound and it may well pay on a corpus with weaker lexical overlap or a larger k.

    config                          lexical    semantic mrr
    direct only                     28/28      0.207
    RRF fusion, equal weight        27/28  X   0.219
    RRF fusion, routed x0.45        27/28  X   0.250
    backfill (cannot displace)      28/28      0.207   (no-op)

Two failure modes, and they are mutually exclusive:

  * FUSION DISPLACES. Routed passages were retrieved because their SECTION matched, not
    because they did. Interleaving them floods top-k with section-mates and pushes the exact
    answer out — a real lexical regression, not a metric artifact. Down-weighting to 0.45
    reduced but did not remove it.
  * BACKFILL IS INERT. Restricting routed results to slots direct retrieval did not earn is
    safe by construction, but BM25 always returns k results, so there is never a free slot.
    Zero cost, zero effect.

The genuine gain was concentrated in ONE case (sem-copies-machines, rank 5 -> 1) while two
others regressed. That is not a technique earning its place; that is variance.

The remaining semantic gap is genuine semantic distance ("reserving the same seat" vs "write
skew" share no vocabulary), which is what the vector slot exists for. Routing was worth
measuring first precisely so vectors cannot take credit for something structural.
"""

from __future__ import annotations

from dataclasses import dataclass

from substrate.store.index_store import Hit, IndexStore

RRF_K = 60
OUTLINE_ROUTES = 3      # how many outline records may route
ROUTE_DEPTH = 12        # passages pulled per routed section
DIRECT_WEIGHT = 1.0
VECTOR_WEIGHT = 1.0     # equal footing; RRF is scale-free so no calibration is implied
ROUTE_WEIGHT = 0.45     # recall aid, must not outvote a precise direct hit
VARIANT_WEIGHT = 0.6    # paraphrases are coverage, not the question actually asked


@dataclass
class Trace:
    """Why a result set looks the way it does — retrieval must be explainable."""

    direct: int = 0
    vector: int = 0
    routed: int = 0
    variants: int = 0
    reranked: bool = False
    degraded: str = ""
    expanded: bool = False
    routes: list[str] = None
    fused: int = 0

    def __post_init__(self) -> None:
        if self.routes is None:
            self.routes = []


def _rrf(
    ranked_lists: list[tuple[float, list[Hit]]], k: int = RRF_K
) -> list[tuple[float, Hit]]:
    """Weighted RRF. Weights are not cosmetic here.

    Routed passages are a RECALL aid, not equal-authority evidence: they were retrieved
    because their SECTION matched, not because they did. Fusing them at parity floods top-k
    with section-mates and displaces the precise direct hit — measured as a lexical
    regression (28/28 -> 27/28) where routing found the right section and pushed the exact
    answer out of the window.
    """
    scores: dict[str, float] = {}
    best: dict[str, Hit] = {}
    for weight, hits in ranked_lists:
        for rank, h in enumerate(hits, start=1):
            scores[h.chunk_id] = scores.get(h.chunk_id, 0.0) + weight / (k + rank)
            best.setdefault(h.chunk_id, h)
    return sorted(((s, best[cid]) for cid, s in scores.items()), key=lambda x: -x[0])


def _degrade(trace: Trace, reason: str) -> None:
    """Record a mid-run degradation ON the Trace — the seam that carries the condition to the
    consumer (the eval threads it onto CaseResult; a serving caller can show it).

    Accumulate rather than overwrite, so a query that loses two arms names both. This is the
    whole point: a number measured under a degradation must carry that condition with it, or it
    reads authoritative while being quietly a different configuration than its label claims.
    """
    trace.degraded = f"{trace.degraded}; {reason}" if trace.degraded else reason


def retrieve(
    store: IndexStore,
    query: str,
    *,
    k: int = 5,
    doc_id: str | None = None,
    document_class: str | None = None,
    route: bool = False,
    expand: bool = False,
    embedder=None,
    expander=None,
    multiquery=None,
    reranker=None,
) -> tuple[list[Hit], Trace]:
    """Passage retrieval, optionally routed through the outline layer."""
    trace = Trace()

    # Query set: the original, plus register-varied paraphrases. A relevant chunk only has
    # to match ONE phrasing, which is the point.
    queries = [query]
    if multiquery is not None:
        try:
            extra = multiquery.variants(query)
            queries += extra
            trace.variants = len(extra)
            # variants() fails open to [] internally, so an empty result under an enabled
            # multi-query config IS a silent degradation: the query ran without the paraphrases
            # its measured label claims. Surface it so the eval refuses rather than mislabels.
            if not extra:
                _degrade(trace, "multi-query produced no variants")
        except Exception as e:  # noqa: BLE001 — fail open to the bare query, but record it
            _degrade(trace, f"multi-query error: {str(e)[:80]}")

    direct = store.search(
        query, k=k * 3, kind="passage", doc_id=doc_id, document_class=document_class
    )
    trace.direct = len(direct)
    lists: list[tuple[float, list[Hit]]] = [(DIRECT_WEIGHT, direct)]

    # Paraphrases contribute at a lower weight than the question actually asked: they are a
    # coverage aid, not equal evidence. Same reasoning that stopped routed passages from
    # displacing precise hits.
    for variant in queries[1:]:
        vlist = store.search(variant, k=k * 2, kind="passage", doc_id=doc_id,
                             document_class=document_class)
        if vlist:
            lists.append((VARIANT_WEIGHT, vlist))
        if embedder is not None:
            try:
                vv = store.vector_search(
                    embedder.embed_query(variant),
                    getattr(embedder, "key", embedder.model),
                    k=k * 2, kind="passage", doc_id=doc_id, document_class=document_class,
                )
                if vv:
                    lists.append((VARIANT_WEIGHT, vv))
            except Exception as e:  # noqa: BLE001 — a variant is supplementary; keep going
                _degrade(trace, f"variant embed: {str(e)[:80]}")

    # Hybrid: lexical AND vector, fused by RRF. RRF is used rather than a score blend
    # precisely because BM25 and cosine are not on a comparable scale, so no weighting
    # calibration is implied or needed.
    if embedder is not None:
        # HyDE applies to the VECTOR query only. BM25 over a generated paragraph would inject
        # invented terms into a lexical match that is already at 28/28; scoping expansion to the
        # embedding makes it incapable of disturbing that by design.
        #
        # Expansion sits in its OWN try, separate from the embedder's: a HyDE failure must be
        # attributed to HyDE (not misreported as an embedder fallback) and must NOT disable the
        # vector arm — it simply falls back to embedding the bare query.
        vquery = query
        if expander is not None:
            expand_failed = False
            try:
                vquery = expander.expand(query)
            except Exception as e:  # noqa: BLE001 — the cache/generator calls can raise
                _degrade(trace, f"expansion error: {str(e)[:80]}")
                expand_failed = True
            trace.expanded = len(vquery) > len(query)
            # A successful generation always appends text, so an unchanged length means HyDE
            # fell back to the bare query internally — a silent degradation, surfaced.
            if not expand_failed and not trace.expanded:
                _degrade(trace, "expansion fell back to bare query")

        # FAIL OPEN. If the embedder is unreachable, retrieval degrades to pure lexical rather
        # than failing — an engine that stops answering because a local daemon is down is worse
        # than one that answers slightly less well. The degrade is recorded on the Trace so the
        # eval refuses a hybrid-labelled number measured partly without the vector arm.
        try:
            qv = embedder.embed_query(vquery)
            vhits = store.vector_search(
                qv, getattr(embedder, 'key', embedder.model), k=k * 3, kind="passage", doc_id=doc_id,
                document_class=document_class,
            )
            trace.vector = len(vhits)
            if vhits:
                lists.append((VECTOR_WEIGHT, vhits))
        except Exception as e:  # noqa: BLE001 — degrade on ANY embedder failure, by design
            _degrade(trace, f"embedder: {str(e)[:80]}")
            embedder = None

    if route:
        outlines = store.search(
            query, k=OUTLINE_ROUTES, kind="outline", doc_id=doc_id,
            document_class=document_class,
        )
        for o in outlines:
            if not o.path_str:
                continue
            # RELEVANCE-ranked within the section, not document order. Fusing a
            # position-ordered list into RRF is wrong: RRF reads rank as relevance, so
            # document order hands high weight to whatever happens to sit first. Measured
            # +0.012 MRR with two cases regressing before this was scoped as a search.
            under = store.search(
                query, k=ROUTE_DEPTH, kind="passage", doc_id=o.doc_id,
                path_prefix=o.path_str,
            )
            if under:
                trace.routes.append(o.path_str)
                trace.routed += len(under)
                lists.append((ROUTE_WEIGHT, under))

    # BACKFILL, not interleave. Weighted RRF still displaced a precise direct hit out of
    # top-k (lexical 28/28 -> 27/28): routing found the right SECTION and its section-mates
    # crowded out the exact answer. Letting routed results fill only the slots direct
    # retrieval did not earn makes routing incapable of harming precision by construction —
    # it can add recall, never subtract it.
    if embedder is not None or len(lists) > 1:
        fused = [h for _, h in _rrf(lists)]
        trace.fused = len(fused)
        # Rerank BEFORE truncating to k — reranking the already-cut top-k could only permute
        # what fusion already chose, and the whole point is to promote something fusion
        # ranked 6th-20th.
        if reranker is not None and fused:
            # The reranker fails open to fused order on a transport/parse failure, which is
            # indistinguishable by return value from the adaptive gate-skip (both leave the
            # order unchanged). Its own fallback counter is the honest per-call signal, so
            # snapshot-diff it and surface a real fallback onto the Trace for the eval to refuse.
            # The call is also wrapped: an error its own except tuple misses (a reset, a
            # RemoteDisconnected) must degrade the query, not abort the whole eval mid-run.
            rr_fb0 = getattr(reranker, "fallback_queries", 0)
            try:
                fused, trace.reranked = reranker.rerank(query, fused)
            except Exception as e:  # noqa: BLE001 — a reranker crash degrades, never aborts
                _degrade(trace, f"reranker error: {str(e)[:80]}")
            else:
                if getattr(reranker, "fallback_queries", 0) > rr_fb0:
                    _degrade(trace, "reranker fell back to fused order")
        return fused[:k], trace

    fused = list(direct[:k])
    seen_ids = {h.chunk_id for h in fused}
    if route and len(fused) < k:
        for _, h in _rrf(lists[1:]):
            if h.chunk_id not in seen_ids:
                seen_ids.add(h.chunk_id)
                fused.append(h)
            if len(fused) >= k:
                break
    fused.extend(h for _, h in _rrf(lists) if h.chunk_id not in seen_ids)
    trace.fused = len(fused)

    if expand and fused:
        seen = {h.chunk_id for h in fused[:k]}
        extra: list[Hit] = []
        for h in fused[:k]:
            for n in store.neighbours(h.chunk_id, window=1):
                if n.chunk_id not in seen:
                    seen.add(n.chunk_id)
                    extra.append(n)
        fused = fused[:k] + extra

    return fused[:k], trace
