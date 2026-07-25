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

from dataclasses import dataclass, field

from substrate.spine import INCLUDED_STATUSES
from substrate.store.index_store import Hit, IndexStore

# The default retrieval set (Doc 2 §6): active + complete included; archived + superseded excluded.
# Sourced from spine.INCLUDED_STATUSES so "the set retrieval uses" and "the set the audit checks"
# are one definition and cannot drift. A caller passes an explicit `statuses` (e.g. to include
# archived on an explicit request, or None for an unfiltered administrative scan) to override it.
DEFAULT_STATUSES = INCLUDED_STATUSES

RRF_K = 60
OUTLINE_ROUTES = 3      # how many outline records may route
ROUTE_DEPTH = 12        # passages pulled per routed section
DIRECT_WEIGHT = 1.0
VECTOR_WEIGHT = 1.0     # equal footing; RRF is scale-free so no calibration is implied
ROUTE_WEIGHT = 0.45     # recall aid, must not outvote a precise direct hit
VARIANT_WEIGHT = 0.6    # paraphrases are coverage, not the question actually asked


@dataclass
class Trace:
    """Why a result set looks the way it does — retrieval must be explainable.

    The per-arm `*_fell_back` flags and `fallback_reasons` are the STRUCTURED source `retrieve()`
    builds `Capability` from, so nothing has to parse the prose `degraded` back apart to know
    which arm degraded or how many did.
    """

    direct: int = 0
    vector: int = 0
    routed: int = 0
    variants: int = 0
    reranked: bool = False
    degraded: str = ""
    expanded: bool = False
    routes: list[str] = None
    fused: int = 0
    embedder_fell_back: bool = False
    hyde_fell_back: bool = False
    reranker_fell_back: bool = False
    rerank_reached: bool = False          # the rerank stage actually ran (vs gate-skip vs absent)
    fallback_reasons: list[str] = None    # one entry per fallback — the structured list, not prose

    def __post_init__(self) -> None:
        if self.routes is None:
            self.routes = []
        if self.fallback_reasons is None:
            self.fallback_reasons = []


# The two MEASURED 44-case stacks, each a FIXED model set. `expected_mrr` is a number ONLY when
# the running arms match one exactly — same embedder key AND the same HyDE/reranker models the
# tier was measured with. A different embedder, a swapped HyDE/rerank model, a mixed-provider
# stack, or an unknown model is honestly UNMEASURED (None): the tiers are model-specific
# (EXPERIMENTS.md measured nomic 0.656, 8b 0.683, embeddinggemma 0.691, cross-encoder 0.708 — NOT
# one "ollama" number), so generalizing them by family would stamp a number on a config it was
# never measured at, the exact Boundary-Principle sin this contract exists to prevent. NEVER
# compare across cohorts (HANDOFF §6); the cohort travels on the Capability field. This replaces
# PRINCIPLES.md's older mixed-cohort sketch (0.698/0.375/0.21) with same-cohort 44-case numbers.
_COHORT = "44-case semantic"
_STACKS: dict[str, dict] = {
    "qwen3-embedding:0.6b#raw": {           # all-Ollama CEILING
        "hyde": "qwen2.5:7b", "reranker": "qwen2.5:7b",
        "mrr": {(True, True): 0.698, (True, False): 0.603},
    },
    "apple-nlcontextual": {                 # all-Apple FLOOR (zero-install default)
        "hyde": "apple-fm", "reranker": "apple-fm",
        "mrr": {(True, True): 0.593, (True, False): 0.467, (False, False): 0.343},
    },
}


def _expected_mrr(
    embed_key: str, hyde_model: str, rerank_model: str, hyde_in_tier: bool, rerank_in_tier: bool
) -> float | None:
    """The measured 44-case MRR for the EXACT stack that ran, or None if this configuration was
    never measured. No interpolation, no family generalization, no lower-bound guessing — the
    tiers are model-specific, so anything but an exact match is honestly unmeasured."""
    stack = _STACKS.get(embed_key)
    if stack is None:
        return None
    if hyde_in_tier and hyde_model != stack["hyde"]:
        return None
    if rerank_in_tier and rerank_model != stack["reranker"]:
        return None
    return stack["mrr"].get((hyde_in_tier, rerank_in_tier))


@dataclass(frozen=True)
class Capability:
    """Which retrieval arms ACTUALLY ran, and the measured MRR that implies — carried as FIELDS on
    the result so a degradation crosses the boundary to the caller instead of reading as absence
    (PRINCIPLES.md, the Boundary Principle). `fallbacks` is the un-hidden list of arms that
    dropped mid-run; a run with any fallback is a real degradation the caller must not treat as
    full-quality. `expected_mrr` is the measured envelope for THIS exact stack — None when the
    configuration was never measured at `cohort` (honest absence, not a smoothed guess; a number
    is always an exact measured tier, never an estimate)."""

    embedder: str                 # embedder key that ran, "" if the vector arm did not contribute
    hyde: str                     # "ran" | "off" | "fell_back"
    reranker: str                 # "ran" | "skipped" (adaptive gate) | "off" | "fell_back"
    expected_mrr: float | None    # exact measured MRR for this stack, or None if unmeasured
    cohort: str                   # the eval cohort that number was measured on
    fallbacks: tuple[str, ...]    # arms that fell back mid-run, with reasons — a field, not a log

    @property
    def degraded(self) -> bool:
        return bool(self.fallbacks)


@dataclass(frozen=True)
class RetrievalResult:
    """The result contract every consumer reads: the passages, WHICH arms produced them, and what
    the index was built from. Replaces the bare (hits, trace) tuple whose trace every caller
    discarded — the Boundary Principle violated in our own code."""

    passages: list[Hit]
    capability: Capability
    index_version: str
    trace: Trace                  # raw per-arm signals capability is derived from (audit/debug)
    # Orientation records for the same query — the two-speed layer of Doc 2 §7, off unless asked
    # for. NOT routing: routing fuses outline-derived passages into the ranking (measured, off by
    # default, see the module docstring). This only reports which SECTIONS matched, alongside an
    # unchanged passage ranking, so a consumer can see the shape of the corpus around an answer.
    outlines: list[Hit] = field(default_factory=list)


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


def _degrade(trace: Trace, arm: str, reason: str) -> None:
    """Record a mid-run degradation ON the Trace — the seam that carries the condition to the
    consumer. `arm` sets the structured `<arm>_fell_back` flag Capability reads (never parsed back
    out of the prose); `reason` accumulates onto `degraded` so a query that loses two arms names
    both. A number measured under a degradation must carry that condition with it, or it reads
    authoritative while being quietly a different configuration than its label claims.
    """
    if arm:
        setattr(trace, f"{arm}_fell_back", True)
    trace.fallback_reasons.append(reason)
    trace.degraded = f"{trace.degraded}; {reason}" if trace.degraded else reason


def _retrieve(
    store: IndexStore,
    query: str,
    *,
    k: int = 5,
    doc_id: str | None = None,
    document_class: str | None = None,
    statuses: frozenset[str] | None = DEFAULT_STATUSES,
    include_sources: bool = False,
    route: bool = False,
    expand: bool = False,
    embedder=None,
    expander=None,
    multiquery=None,
    reranker=None,
) -> tuple[list[Hit], Trace]:
    """Passage retrieval, optionally routed through the outline layer. Returns (hits, trace);
    `retrieve()` wraps this into the RetrievalResult contract. Behaviour is unchanged from before
    the contract existed — this is the identical retrieval body, only the return is now wrapped.

    `statuses` is the default-retrieval filter, applied uniformly to EVERY arm (direct, variant,
    vector, route) so a status the lexical arm excludes cannot re-enter through the vector or
    routing arm. The default excludes archived + superseded; the existing corpus is all `active`,
    so its results are unchanged."""
    trace = Trace()

    # ONE coverage check, before any arm runs. An embedder wired over an index holding no (or
    # partial) vectors for ITS key contributes nothing and raises nothing — `vector_search`
    # returns [] on an empty space — so without this the trace shows a live embedder and the
    # capability stamps a measured tier on what is really a lexical-only run. Degrading here is
    # what keeps the envelope honest: `embedder` empties, HyDE (which only ever feeds the vector
    # query) reports off, and `_expected_mrr` returns None rather than a number the stack did not
    # earn. Fail OPEN, like every other arm on this path — a lexical answer correctly labelled is
    # useful; `eval` is the caller that must refuse instead, because it publishes the number.
    # The commonest cause is a key change orphaning the stored vectors, which is why the reason
    # names the key and the counts rather than saying "unavailable".
    if embedder is not None:
        vec_key = getattr(embedder, "key", getattr(embedder, "model", ""))
        n_vec, n_chunks = store.vector_coverage(vec_key)
        if n_vec < n_chunks:
            _degrade(
                trace, "embedder",
                f"{'no vectors' if n_vec == 0 else 'INCOMPLETE'}: {n_vec}/{n_chunks} under "
                f"{vec_key!r} — run `substrate embed`",
            )
            embedder = None

    # Query set: the original, plus register-varied paraphrases. A relevant chunk only has
    # to match ONE phrasing, which is the point.
    queries = [query]
    if multiquery is not None:
        # Multi-query variants are a SUPPLEMENTARY recall aid (VARIANT_WEIGHT, off by default),
        # not part of the primary measured configuration. Their absence lowers recall but does
        # NOT mislabel the lexical+vector+HyDE+rerank number, and variants() returns [] on a
        # legitimate no-op (a query it declines to paraphrase) as readily as on failure — so it
        # fails open WITHOUT degrading the case, unlike the primary arms below.
        try:
            extra = multiquery.variants(query)
            queries += extra
            trace.variants = len(extra)
        except Exception:  # noqa: BLE001 — supplementary; fail open to the bare query
            pass

    direct = store.search(
        query, k=k * 3, kind="passage", doc_id=doc_id, document_class=document_class,
        statuses=statuses, include_sources=include_sources,
    )
    trace.direct = len(direct)
    lists: list[tuple[float, list[Hit]]] = [(DIRECT_WEIGHT, direct)]

    # Paraphrases contribute at a lower weight than the question actually asked: they are a
    # coverage aid, not equal evidence. Same reasoning that stopped routed passages from
    # displacing precise hits.
    for variant in queries[1:]:
        vlist = store.search(variant, k=k * 2, kind="passage", doc_id=doc_id,
                             document_class=document_class, statuses=statuses, include_sources=include_sources)
        if vlist:
            lists.append((VARIANT_WEIGHT, vlist))
        if embedder is not None:
            try:
                vv = store.vector_search(
                    embedder.embed_query(variant),
                    getattr(embedder, "key", embedder.model),
                    k=k * 2, kind="passage", doc_id=doc_id, document_class=document_class,
                    statuses=statuses, include_sources=include_sources,
                )
                if vv:
                    lists.append((VARIANT_WEIGHT, vv))
            except Exception:  # noqa: BLE001 — a variant is supplementary; fail open, no degrade
                pass

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
                _degrade(trace, "hyde", f"expansion error: {str(e)[:80]}")
                expand_failed = True
            trace.expanded = len(vquery) > len(query)
            # A successful generation always appends text, so an unchanged length means HyDE
            # fell back to the bare query internally — a silent degradation, surfaced.
            if not expand_failed and not trace.expanded:
                _degrade(trace, "hyde", "expansion fell back to bare query")

        # FAIL OPEN. If the embedder is unreachable, retrieval degrades to pure lexical rather
        # than failing — an engine that stops answering because a local daemon is down is worse
        # than one that answers slightly less well. The degrade is recorded on the Trace so the
        # eval refuses a hybrid-labelled number measured partly without the vector arm. The embed
        # call and the store search are kept in separate try scopes so the reason attributes to
        # the right arm: a dead Ollama daemon reads "embedder", a store/index error reads
        # "vector search" — not the former mislabelled as the latter.
        qv = None
        try:
            qv = embedder.embed_query(vquery)
        except Exception as e:  # noqa: BLE001 — degrade on ANY embedder failure, by design
            _degrade(trace, "embedder", f"embedder: {str(e)[:80]}")
            embedder = None
        if qv is not None:
            try:
                vhits = store.vector_search(
                    qv, getattr(embedder, 'key', embedder.model), k=k * 3, kind="passage",
                    doc_id=doc_id, document_class=document_class, statuses=statuses, include_sources=include_sources,
                )
                trace.vector = len(vhits)
                if vhits:
                    lists.append((VECTOR_WEIGHT, vhits))
            except Exception as e:  # noqa: BLE001 — a store-side failure also degrades the case
                _degrade(trace, "embedder", f"vector search: {str(e)[:80]}")
                embedder = None

    if route:
        outlines = store.search(
            query, k=OUTLINE_ROUTES, kind="outline", doc_id=doc_id,
            document_class=document_class, statuses=statuses, include_sources=include_sources,
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
                path_prefix=o.path_str, statuses=statuses, include_sources=include_sources,
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
            trace.rerank_reached = True  # distinguishes an adaptive gate-skip from "never ran"
            rr_fb0 = getattr(reranker, "fallback_queries", 0)
            try:
                fused, trace.reranked = reranker.rerank(query, fused)
            except Exception as e:  # noqa: BLE001 — a reranker crash degrades, never aborts
                _degrade(trace, "reranker", f"reranker error: {str(e)[:80]}")
            else:
                if getattr(reranker, "fallback_queries", 0) > rr_fb0:
                    _degrade(trace, "reranker", "reranker fell back to fused order")
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


def _capability(
    trace: Trace, *, embed_key: str, emb_provided: bool, hyde_model: str, hyde_provided: bool,
    rerank_model: str, rr_provided: bool,
) -> Capability:
    """Derive the arm-by-arm capability from the trace's STRUCTURED flags (never the prose).

    Tier note: the adaptive gate legitimately SKIPS the reranker on an already-precise query, and
    the measured tiers already include that behaviour — so a gate-skip stays in the reranked tier;
    only 'off' (never reached) or 'fell_back' (reached, failed) drop out of it. HyDE only feeds the
    vector query, so with no embedder it is 'off' regardless.
    """
    embedder = "" if (not emb_provided or trace.embedder_fell_back) else embed_key
    emb_ok = bool(embedder)

    if not (hyde_provided and emb_provided):
        hyde = "off"
    elif trace.hyde_fell_back:
        hyde = "fell_back"
    elif trace.expanded:
        hyde = "ran"
    else:
        hyde = "off"  # provided but never produced an expansion (and did not flag a failure)

    if not rr_provided:
        reranker = "off"
    elif trace.reranker_fell_back:
        reranker = "fell_back"
    elif trace.reranked:
        reranker = "ran"
    elif trace.rerank_reached:
        reranker = "skipped"          # reached the rerank stage, adaptive gate declined
    else:
        reranker = "off"              # wired, but the pipeline never reached the rerank stage

    tier_key = embed_key if emb_ok else ""
    exp = _expected_mrr(tier_key, hyde_model, rerank_model,
                        hyde == "ran", reranker in ("ran", "skipped"))
    return Capability(
        embedder=embedder, hyde=hyde, reranker=reranker,
        expected_mrr=exp, cohort=_COHORT, fallbacks=tuple(trace.fallback_reasons),
    )


def retrieve(
    store: IndexStore,
    query: str,
    *,
    k: int = 5,
    doc_id: str | None = None,
    document_class: str | None = None,
    statuses: frozenset[str] | None = DEFAULT_STATUSES,
    include_sources: bool = False,
    route: bool = False,
    expand: bool = False,
    embedder=None,
    expander=None,
    multiquery=None,
    reranker=None,
    with_outlines: int = 0,
) -> RetrievalResult:
    """Passage retrieval, returning the RESULT CONTRACT: passages + which arms actually ran +
    index_version. The retrieval itself is `_retrieve`, unchanged — this only surfaces the
    condition the engine already knew and used to throw away (PRINCIPLES.md, the Boundary
    Principle). No consumer should ever go back to reading a bare hit list.

    `statuses` is the default-retrieval filter (Doc 2 §6), defaulting to active+complete. Pass a
    broader set to answer an explicit archived/superseded query, or None for an unfiltered scan.

    `with_outlines` adds N orientation records for the same query, under the SAME filters. It is
    strictly additive: the passage ranking is computed and returned unchanged, so requesting them
    cannot move a result. Defaults to 0 — nothing on the eval path asks, so no measured number can
    shift underneath it.
    """
    # Capture what was WIRED (and each arm's model identity) before _retrieve can null an arm out
    # on fallback. The model identities gate the measured tier — a swapped HyDE/rerank model is a
    # different, unmeasured stack.
    emb_provided = embedder is not None
    embed_key = getattr(embedder, "key", getattr(embedder, "model", "")) if emb_provided else ""
    hyde_model = getattr(expander, "model", "") if expander is not None else ""
    rerank_model = getattr(reranker, "model", "") if reranker is not None else ""

    hits, trace = _retrieve(
        store, query, k=k, doc_id=doc_id, document_class=document_class, statuses=statuses,
                    include_sources=include_sources,
        route=route, expand=expand, embedder=embedder, expander=expander, multiquery=multiquery,
        reranker=reranker,
    )
    cap = _capability(
        trace, embed_key=embed_key, emb_provided=emb_provided,
        hyde_model=hyde_model, hyde_provided=expander is not None,
        rerank_model=rerank_model, rr_provided=reranker is not None,
    )
    outlines: list[Hit] = []
    if with_outlines > 0:
        # The same filters as the passage arms. An orientation record that survived a status or
        # source exclusion the passages were subject to would name a section whose content the
        # caller is not allowed to see — an exclusion leaking back in through the other layer.
        outlines = store.search(
            query, k=with_outlines, kind="outline", doc_id=doc_id,
            document_class=document_class, statuses=statuses, include_sources=include_sources,
        )

    return RetrievalResult(
        passages=hits, capability=cap, index_version=store.index_version, trace=trace,
        outlines=outlines,
    )
