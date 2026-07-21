# Substrate Engine — Experiment Log

Every retrieval experiment run, its result, and the verdict. Kept because commit messages are
chronological and mixed with implementation detail, so they answer "what changed" but not
"what did we try and what did we learn".

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

## Measurement resolution — read before trusting any delta

With 44 semantic cases, MRR moves in quanta of **1/44 = 0.023 per case**. A case moving
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

## Retracted — measurements that were not measurements

These matter more than the results. Every one looked plausible and was nearly committed.

| claim | what it actually measured | cause |
|---|---|---|
| "qwen3 native instruction = 0.303" | lexical-only, no vectors at all | key change orphaned stored vectors |
| "outline routing = +0.012" | a bug, not the idea | routed list was document-ordered, fed to RRF which reads rank as relevance |
| "nomic = 0.303 in embedder A/B" | lexical-only | `drop_vectors` had deleted nomic's vectors when Apple's were written |
| "17/18 eval pass with doc filter" | unfiltered corpus-wide search | doc-name prefix never matched any doc_id, fell through `or hits` |

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
| 5 | qwen3-embedding 4b / 8b | pending download; **after** chunking is locked (they'd be re-embedded twice otherwise) |
| 6 | Reranking — qwen2.5:7b vs Bonsai-27B ternary | arguably should move ahead of #4 |
| — | Adaptive multi-query (fallback only on low confidence) | needs a confidence signal the retriever does not expose |
| — | qwen3 instruction format | **unanswered** — first attempt retracted |

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
