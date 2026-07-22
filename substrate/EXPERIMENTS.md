# Substrate Engine — Experiment Log

Every retrieval experiment run, its result, and the verdict. Kept because commit messages are
chronological and mixed with implementation detail, so they answer "what changed" but not
"what did we try and what did we learn".

> The dominant failure shape of this project is written up separately in
> **[PRINCIPLES.md](PRINCIPLES.md)** — five incidents where information existed but did not
> cross the boundary to its consumer. Four of the entries below are instances of it.

**Rule for this file: a rejected experiment is as valuable as an accepted one, and a retracted
measurement is more valuable than either.** Most of the cost in this project has gone into
techniques that sounded right and did not survive measurement.

---

## Current best configuration

```
ingest    docling 2.114.0 + layout-heron, 100-page batches
chunk     class-driven; reference-frozen 1500/2800/450, reference-versioned 1000/2000/300
index     SQLite FTS5 (external content) + chunk_vectors, section-weighted bm25
embed     qwen3-embedding:0.6b, raw text both sides   (key: ...#raw)
expand    HyDE via qwen2.5:7b, canonical prompt, cached
fuse      RRF k=60, lexical + vector at equal weight
rerank    listwise via qwen2.5:7b, ADAPTIVE (skipped when the top hit is already a
          strong lexical match), pool 20, cached
```

| metric | value |
|---|---|
| semantic MRR | **0.698** (44 cases) |
| lexical gate | **28/28** |
| latency p50 / p95 | **412ms / 1074ms** warm · ~5s on a novel query (HyDE + rerank cold) |

---

## The cumulative arc — READ THE SCALES

Every published delta below is valid **within its cohort**. The arc as a whole is NOT five
measurements on one instrument: the gold set was expanded twice, and a cohort change is a
harness change, not a result.

```
7-case cohort
  0.207   lexical only
  0.369   + hybrid vectors            +0.162   within-scale
  0.381   + per-class chunk geometry  +0.012   below resolution

──  harness change: cohort 7 → 24  (NOT a measurement)  ──

24-case cohort
  0.375   same stack, re-measured on the larger set
  0.531   + HyDE (qwen2.5:7b)         +0.156   within-scale
  0.642   + qwen3-embedding:0.6b      +0.110   within-scale

──  harness change: cohort 24 → 44  (NOT a measurement)  ──

44-case cohort
  0.603   same stack, re-measured on the larger set
  0.698   + adaptive listwise rerank  +0.095   within-scale
```

**0.642 → 0.603 is not a regression.** It is the identical configuration scored against a
harder, larger set. Reading the arc as one continuous line would treat two harness changes as
if they were results, and would make the rerank step look like +0.056 when it is +0.095.

Numbers from different cohorts are not comparable to each other and must never be subtracted.
Any figure quoted from this file should carry its cohort size — this is the provenance rule
the substrate applies to retrieved passages, applied to its own measurement history.

---

## Measurement resolution — read before trusting any delta

With 44 semantic cases, MRR moves in quanta of **1/44 = 0.023 per case**. (At the earlier
24-case scale it was 0.042, and at 7 cases 0.143 — which is why nothing measured in the
7-case era below ~0.15 should be trusted at all, including the +0.012 chunk-geometry result
that was shipped on principle rather than evidence.) A case moving
rank 2→1 shifts it 0.011.

- **< 0.023** — sub-single-case. Not a small effect, a **non-effect**.
- **0.023 – 0.05** — one to two cases. Suggestive, not conclusive.
- **> 0.10** — real at this sample size.

This is why per-class chunking (+0.012) and snowflake (+0.005) were called noise, and why
vector weight and RRF weights are deliberately **untuned** — tuning against 44 cases fits
noise and then crowns it.

---

## Accepted — shipped

| experiment | result | why |
|---|---|---|
| **Docling as extractor** | 29/29 parity footers, 66 outline-less headings, byte-identical reruns | Solved the two hardest layout problems; determinism gate passed |
| **100-page batching** | 10.80 → 0.22 s/page (**~49×**) | Whole-document conversion accumulates state; not an optimization, structural |
| **Furniture validation** | 671/690 honored, 0 captions lost | Docling silently deleted a body sentence + 3 captions; labels are claims to verify |
| **Heading inference from glyph geometry** | flat tree → depth 6 | Docling reports every heading `level=1`; hierarchy had to be inferred |
| **Back-index exclusion** | 129 blocks / 67,886 chars | Index entries are unretrievable noise; References survived (verified) |
| **Section weighting** | non-body in top-5: 5/35 → 1/35 | References sections were vocabulary-dense attractors for vague queries |
| **Hybrid vectors** | 0.207 → 0.375 (**+0.168**) | The single biggest structural win |
| **HyDE (qwen2.5:7b)** | 0.375 → 0.531 (**+0.156**) | Query/document vocabulary gap is the dominant failure mode |
| **qwen3-embedding:0.6b** | 0.531 → 0.642 (**+0.110**) | LLM-derived embedder; different lineage from the BERT-family cluster |
| **Adaptive listwise rerank** | 0.603 → 0.698 (**+0.095**) at +37ms | Sharpens order without widening the pool — the thing three failed experiments pointed at |

## Rejected — measured and not shipped

| experiment | result | why rejected |
|---|---|---|
| **Outline routing** | +0.043 but **27/28 lexical** | Routed passages displaced precise hits. Backfill variant was safe but inert (BM25 always fills k). Gain was one case against two regressions |
| **HyDE "distinctive" prompt** | 0.531 → 0.445 | Predicted improvement, got −0.086. Confounded (changed objective *and* length together) |
| **qwen2.5:14b for HyDE** | 0.472 vs 7b 0.531 | See "bigger is worse" below |
| **bge-m3 / snowflake / mxbai** | 0.527 / 0.536 / n/a | Wash, noise-with-a-regression, and disqualified respectively |
| **qwen3-embedding:4b** | 0.645 vs 0.6b 0.698, **27/28** | Better embedder, worse system — see below |
| **Multi-query fusion (3)** | +0.034 at **5× latency** | 11 up, 10 down, 3 newly broken. Redistribution, not improvement |
| **Per-class chunk geometry** | +0.012 | Below resolution. **Shipped anyway on principle**, explicitly not on evidence |
| **Chunk granularity sweep** | see below | Current geometry already at/near optimum |

### Chunk granularity (the axis that had never been varied)

Re-cut from `blocks.jsonl` without re-parsing the PDFs — the property the offset-mapped
blocks were built for, exercised here for the first time and it reproduced the original
ingest exactly (1051/252/74 passages, identical p50 and coverage) in seconds instead of ~4
minutes. That is what made this axis affordable to test at all.

| target | semantic mrr | lexical | p50 | notes |
|---|---|---|---|---|
| 700 | 0.547 (−0.056) | **27/28** | 640ms | fragments reappear (4/1/2) |
| ~1500 class-driven | **0.603** | 28/28 | 397ms | current |
| 2500 | 0.591 (−0.012) | 28/28 | **248ms** | statistically a wash, 1.6× faster |

**Verdict: keep current.** Small is decisively worse — denser chunks fragment concepts and
cost a gated regression. Large is *statistically indistinguishable* (−0.012 is under the
0.023 quantum) and meaningfully faster, so it is a real option if latency ever dominates.

Kept current anyway for a reason MRR cannot express: **MRR scores "did we find it", not "how
much noise came with it".** A 2500-char chunk containing the answer scores identically to a
1500-char one, but hands a reasoner 66% more surrounding text to wade through. Chunk size is
a precision-of-citation decision as well as a retrieval one, and the eval is blind to that
half.

---

### qwen3-embedding 4b — a BETTER component that made the system WORSE

The most instructive negative result in the log, because every component metric said 4b was
better and the system still lost.

    end-to-end        rerank OFF   rerank ON   rerank gain
    0.6b (0.64 GB)      0.603        0.698       +0.095
    4b   (2.50 GB)      0.623        0.645       +0.022

    vector layer only (margin analysis, 44 cases)
                        0.6b     4b
    mean cosine         0.422   0.451   4b closer on 36/44
    mean margin        -0.043  -0.015   4b DISCRIMINATES BETTER
    correct missed        20      16    4b misses fewer

4b's retrieval is genuinely better in isolation, and **without reranking it wins**
(0.623 vs 0.603). With reranking it loses, because the reranker contributes +0.095 to 0.6b
and only +0.022 to 4b.

**The embedder and the reranker are SUBSTITUTES, not complements.** Both fix the same
deficiency — poor ranking — so improving one shrinks the headroom for the other. This
directly refutes the argument used to justify running 4b at all ("better embeddings feed the
reranker better candidates, so they compound"). They overlap.

Mechanism is HEADROOM, not trigger rate. A first hypothesis — that better vectors fire the
adaptive-skip more often — was tested and rejected: skip rates are 18% (0.6b) vs 20% (4b),
essentially identical, and the reranker runs on 36 vs 35 cases. What changes is how much
there is left to fix. With a worse starting order the reranker has plenty; with a better one
it has little, while its known error mode (promoting mechanistic passages over definitional
ones) still costs the same.

Generalizes: **a better upstream component can make a system worse when a downstream
component's value comes from correcting upstream deficiency.** Component benchmarks cannot
see this — only end-to-end evaluation can, and only if the pipeline is evaluated as shipped.

Costs, for completeness: 4b took 16.4 min to embed against 2.3 min, at 4× the size, and broke
the lexical gate (27/28).

---

## Retracted — measurements that were not measurements

These matter more than the results. Every one looked plausible and was nearly committed.

| claim | what it actually measured | cause |
|---|---|---|
| "qwen3 native instruction = 0.303" | lexical-only, no vectors at all | key change orphaned stored vectors |
| "outline routing = +0.012" | a bug, not the idea | routed list was document-ordered, fed to RRF which reads rank as relevance |
| "nomic = 0.303 in embedder A/B" | lexical-only | `drop_vectors` had deleted nomic's vectors when Apple's were written |
| "17/18 eval pass with doc filter" | unfiltered corpus-wide search | doc-name prefix never matched any doc_id, fell through `or hits` |
| "0.6b margin = miss on all 44 cases" | an index holding only 4b vectors | ad-hoc analysis script bypassed the eval's no-vectors guard; caught only because all-miss was implausible |

**Common cause: a silent no-op that still prints a plausible number.** Guards added since —
the eval now refuses to run with zero vectors for the active key, and cache keys include
everything that changes their output (prompt id, prefix style).

---

## What was learned (beyond individual results)

**Bigger is not better, and the reason is structural.** qwen2.5:14b scores *worse* than 7b at
HyDE. Two wrong explanations were published and retracted before the real one: 14b is neither
longer (566 vs 621 median chars) nor less domain-specific (it contains the target term *more*
often, 17/24 vs 14/24). Measuring cosine to the correct chunk:

```
model   cosine to correct    margin over best competitor
7b      0.743                -0.021
14b     0.745  (closer!)     -0.029  (worse)
```

**Retrieval is competitive, not absolute.** 14b moves the query vector closer to the right
answer *and* closer to everything else nearby. Absolute similarity rises, discrimination
falls. "Closer to the answer" and "further from the near-misses" are different objectives and
they diverge with scale.

**The correct chunk is usually NOT the top vector hit.** Margins are almost all negative;
retrieval works because RRF fuses vectors with lexical. Anyone tuning vector weight upward on
the assumption vectors carry the result is reasoning from a false premise.

**Widening recall keeps failing the same way.** Outline routing, multi-query, and 14b HyDE all
broaden the candidate pool and lose discrimination. Three independent results pointing the
same direction ⇒ remaining headroom is in **sharpening ranking**, not widening recall. This is
the argument for prioritising reranking.

**Embedder and generator must match in REGISTER.** Apple FM pairs better with Apple's
general-text embedder (0.472) than with nomic (0.422); qwen 7b pairs better with nomic
(0.531) than Apple's embedder does (0.392). Crossed, both degrade.

**A model's documented best practice may not survive the pipeline.** qwen3-embedding's
instruction format assumes a bare question; once HyDE makes the query document-shaped,
retrieval is symmetric and asymmetric instruction-prefixing is the wrong tool. (Measurement
pending — the first attempt was retracted.)

**"Diverse models agree ⇒ ceiling" only holds if the diversity spans the axis that matters.**
nomic/bge-m3/snowflake clustering within 0.009 looked like a ceiling. They are all the same
architectural generation. qwen3-embedding is LLM-derived and broke straight through it.

**An embedder's context window must exceed the chunk geometry.** mxbai-embed-large (512
tokens) cannot hold chunks that run to 5,645 chars. Disqualifying, and it rules out a whole
class of otherwise-strong small embedders.

**Gold cases must be checked against the CORPUS, never against retriever output.** Correcting
a case toward what retrieval returned is the tautology the harness exists to prevent. Cases
whose correct answer is not in the corpus (consistent hashing) get deleted, not repaired.

---

## Open / next

| # | experiment | status |
|---|---|---|
| 4 | Chunk granularity (600 / 1500 / 2500) as an axis | not started — the one factor never varied |
| 5 | qwen3-embedding 4b / 8b | **unblocked** — chunking is locked. Runbook below |
| 6 | Reranking — qwen2.5:7b vs Bonsai-27B ternary | arguably should move ahead of #4 |
| — | Adaptive multi-query (fallback only on low confidence) | needs a confidence signal the retriever does not expose |
| — | qwen3 instruction format | **unanswered** — first attempt retracted |
| — | Result contract (snippet-first, graduated capability + measured cost, version-stamped) | the cure for PRINCIPLES.md; precedes any transport choice |
| — | Extract engine to its own repo | relocate BEFORE wiring consumers — do not wire through the weld |
| — | Claude access: skill+CLI primary, MCP only if Desktop/web reach is real | trivial once the contract exists |

### Runbook: qwen3-embedding 4b / 8b

Chunking is locked, so this can run any time. Result is directly comparable to **0.698** —
same 44-case cohort, embedder as the only variable, no cross-scale caveat.

**Run BOTH 4b and 8b**, not 8b conditionally on 4b. Two points give a direction; three give
the SHAPE. That matters because the generator axis turned out non-monotonic (7b beat 14b at
HyDE) — if embedder scaling is monotonic while generator scaling peaks, that is a real
structural difference between the two roles, and it is invisible from a single pairwise
comparison.

Run serially, one resident model at a time:

```bash
cd ~/CodeHome/CallTranscriber/substrate

for M in qwen3-embedding:4b qwen3-embedding:8b; do
  ollama pull  "$M"
  uv run python -m substrate.cli embed --model "$M"        # 4b ~10-15m · 8b ~25-40m
  uv run python -m substrate.cli eval  --embed-model "$M"  # cold pass, ~7m
  ollama stop  "$M"
done

uv run python -m substrate.cli embed --model qwen3-embedding:0.6b   # restore, free from cache
```

The eval will be a COLD pass (~7 min): new embeddings mean new candidate lists, so rerank
cache keys miss. Its warm latency is the number to compare, not the first run's.

**ADOPTION rule — fixed before the numbers exist, so no result can rationalise itself.**
This governs what ships, not what gets run; both sizes get measured either way.

| best result vs 0.698 | verdict |
|---|---|
| within ±0.023 | non-effect at this resolution — keep 0.6b, it is 4-12x smaller |
| gains < 0.05 | real but small: does it justify 2.5-5 GB resident on the QUERY hot path? Default no |
| gains ≥ 0.05 | adopt the winner |
| loses | 0.6b confirmed |

Record the **shape** regardless of what ships — flat / monotonic / peaked across 0.6b→4b→8b
is the finding here, independent of which one wins. Log latency alongside MRR for all three;
an 8b that wins on MRR while pushing p50 past ~1s is a worse engine, not a better one.

**Prediction (recorded so it can be scored):** genuinely uncertain. An earlier prediction that
4b would lose was withdrawn as unfounded — the evidence base for it was one *generator* size
comparison (14b HyDE) whose mechanism is specific to producing text, plus cross-family
embedder comparisons already identified as confounded by lineage. There are ZERO within-family
embedder size comparisons on record, which is precisely what this measures. A positive
mechanism also exists and was underweighted: reranking (+0.095) operates on the fused
candidate pool, so better embeddings feed it better candidates and the two compound.

**Bonsai-27B note:** ternary 1.58-bit, ~4 GB for 27B-class, derived from Qwen3.6-27B — the
same family already in use. Interesting as a **reranker** (judgment task, where scale helps
and the centroid problem does not apply), not as a HyDE generator (where scale measurably
hurts). Trap: Ollama registry uploads are F16 variants (~54 GB); the ternary-packed GGUF must
come from HF directly.

## Operating rules

1. **One model-backed job at a time.** Concurrent evals plus model pulls thrashed a 24 GB
   machine. Group work by model so a large one loads once.
2. **One axis at a time**, lock the winner, then move. Grid-searching the full product
   (embedder × chunk × transform × fusion × rerank ≈ 180 configs) against 44 cases would
   select noise.
3. **Expand the gold set before trusting any multi-factor winner.**
4. **Latency is a scored axis.** A config is only best if it is affordable on every query.
