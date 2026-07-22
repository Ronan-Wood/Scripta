# Substrate Engine — handoff

Written 2026-07-22 at the end of a long session, for a fresh context. Read this first, then
`PRINCIPLES.md` (how this project fails), then `EXPERIMENTS.md` (every measurement).

---

## 0. READ THIS BEFORE THE PLAN FILE

There is a plan at `~/.claude/plans/magical-percolating-quill.md` (Build Spec v1.1). **Its §3
architecture is WRONG** and was corrected by the user late in the session. Do not build from it
without applying this correction:

* §3 says *"the Python engine is a retrieval engine only"* and *"Scripta will never shell out
  to Python."* **Both are false.**
* **The Python engine IS the engine that powers the app.** It replaces Scripta's Swift
  retrieval. The app is a *client* of the engine.

Everything else in the plan (Phase 0 ingestion findings, assertions, chunking design) is
accurate and was executed. Only the boundary/architecture section is wrong.

I misread this three times in one session. The cause is worth knowing: I wrote an engine spec
without a product definition, then kept re-deriving conclusions from my own spec instead of
from what the user said. If something feels architecturally unclear, **ask what the user
downloads and what runs when they double-click it** — do not infer it.

---

## 1. The altitude (from the user, verbatim in substance)

* **The engine is the retrieval brain. It sits at the bottom.** The app (Scripta) is a face on
  top of it; Zed would be another face; the CLI is another. All are clients that ask the engine
  "find me the relevant passages" and get back the result contract. The engine doesn't care who
  is asking.
* **Apple FM is the zero-setup default.** A fresh download runs the Apple tier — Apple
  embedder + Apple FM HyDE + Apple FM rerank. No Ollama, no setup, offline. That is the 0.593
  floor, 85% of the full stack. The default is good, not a crippled teaser.
* **Users can swap models and eval their own.** Point at Ollama/LM Studio, assign per-task
  models, reach the 0.698 ceiling. Optional. Falls back to Apple FM if their server is down
  (fail-open envelope).

**"The engine is done" means the hard retrieval problem is solved and will not need
re-solving. It does NOT mean it is wired into everything.** That distinction is the single
biggest source of confusion in this project.

The four layers:

| layer | state |
|---|---|
| **Engine** | DONE as a retrieval component. Measured, optimised, finished as a tuning target. |
| **App (Scripta)** | Exists. Settings pane predates the eval, so its defaults need reconciling to the winners. (Doc 3) |
| **Vault structure** | Specced, NOT built. Tiers, manifest, domains. Engine has never been pointed at one. (Doc 2) |
| **Clients** | Future. App first-class, Zed first-class, MCP orchestration. (Docs 3/4) |

I have **not read Docs 2, 3, or 4.** Anything I say about vault shape is inference.

---

## 2. Current state — the numbers

All at the 44-case semantic cohort. Never compare across cohorts; see §6.

```
CEILING  0.698   Ollama: qwen3-embedding:0.6b + qwen2.5:7b (HyDE) + qwen2.5:7b (listwise rerank)
                 lexical 28/28 · p50 ~400ms

FLOOR    0.593   Apple only: NLContextualEmbedding + Apple FM HyDE + Apple FM rerank (pool 10)
                 lexical 27/28 · p50 ~1544ms · zero install

GAP      0.105   ~4.6 of 44 cases. The honest upgrade pitch.
```

Ladder for the floor:

```
Apple embedder alone          0.343
  + Apple FM HyDE             0.467   +0.124
  + Apple FM rerank           0.593   +0.126
```

Repo: ~44 commits on `substrate-engine`, 4,708 lines Python / 36 modules, 214 lines Swift /
3 shims, 981 lines of findings docs, 72 gold cases (28 lexical + 44 semantic), 3 documents
ingested. **Zero files outside `substrate/` touched** — verified, so the app is unaffected.

---

## 3. What is built, and why

### Ingestion (Phase 0) — 1,604 lines, needs Docling+torch (508 MB)

* **Docling 2.114.0 + layout-heron** behind a swappable `Extractor` seam. Adopted as *a source
  of labels to be verified*, not an oracle — it silently deleted a real Go-spec sentence and
  three DDIA captions by mislabelling them furniture.
* **Furniture validator** (ours): never drop furniture (retained in `blocks.jsonl` so loss is
  auditable), re-admit blocks >90 chars or sentence-terminated, require cross-page repetition
  before honouring a furniture label. Calibrated `min_pages=2` against 690 real furniture blocks.
* **Batched extraction is mandatory, not an optimisation.** Whole-document `convert()` on 673pp
  = 7,270s (10.8 s/page). A 100-page batch = 0.22 s/page — **49× faster** for equivalent work.
* **Soft-hyphen calibration by fragment validity, NOT frequency.** DDIA's soft hyphen extracts
  as `!`. Frequency-based selection picks `-` and welds 743 real compounds (`read-optimized`).
* **Heading levels from glyph geometry** — Docling reports every heading as `level=1`.
* **Chunking is ours** (never Docling's chunkers). Atomic units never split, target 1400 chars,
  packed within leaf sections only. Two levels: passages + outline records for orientation,
  extractive, no LLM.
* **`chunk()` takes a `Document`, not a PDF** — zero Docling dependency. `cmd_rechunk` proves
  it: re-cuts chunks from `blocks.jsonl` in milliseconds without re-parsing.

### Store (Phases 1–2)

SQLite FTS5 external-content, `chunk_vectors` as struct-packed BLOBs (no sqlite-vec), spine
columns denormalised onto every chunk, `user_version` drop-and-rebuild migration (safe because
markdown is truth). Content-addressed durable vector cache keyed `(sha256(text), model)` —
survives index rebuilds. Now 22,945 vectors / 141 MB.

### Retrieval (Phase 3) — 1,729 lines, **pure stdlib**

No torch, no third-party deps at all: `sqlite3`, `json`, `urllib`, `re`, `hashlib`, `struct`.

| technique | gain | why |
|---|---|---|
| Hybrid lexical+vector, RRF k=60 | +0.168 | scale-invariant; weighted blending is not |
| HyDE expansion (qwen2.5:7b) | +0.156 | query and answer share no vocabulary |
| qwen3-embedding:0.6b | +0.110 | LLM-derived lineage beat BERT-family |
| Adaptive listwise rerank | +0.095 | ranking quality, not recall, was the headroom |
| Section weighting | — | References attractors 5/35 → 1/35 |

**Rejected, with reasons recorded:** multi-query fusion, outline routing, the "distinctive"
HyDE prompt (−0.086), weighted score blending.

**Adaptive rerank gate** (`_already_precise`): rerank only when the top hit does NOT already
contain the query's content terms. Measured failure mode it fixes — reranking trades
DEFINITIONAL answers for MECHANISTIC ones.

### On-device tier — 3 Swift shims, 214 lines

`tools/hyde-fm.swift`, `tools/embed-apple.swift`, `tools/rerank-fm.swift`. They exist because
**Python cannot call FoundationModels or NLContextualEmbedding — they are Swift-only.**
Persistent stdio processes; session setup dominates per-query cost.

`rerank-fm` was built in this session — before it, the default tier was the ONLY configuration
running with no reranker, and it is the tier reranking helps most.

### Eval (Phase 4)

72 gold cases, conjunctive answer+path assertions, per-case no-regression baseline, non-zero
exit for CI. A17 assertion (no top-level element spanning >30% of pages) catches stale ancestors.

---

## 4. Findings that generalise beyond this project

1. **The reranker is an equaliser.** Across five embedders, three architecture families, a 13×
   size range: reranking halves embedder spread (0.095 → 0.053) and allocates its gain
   *inversely* to embedder quality (+0.147 to the worst, +0.022 to the best). Confirmed a third
   time on the Apple tier (+0.126 vs Ollama's +0.095). **→ Pick the cheapest adequate embedder.**

2. **A component sweep run before its downstream corrective stage exists OVERSTATES that
   component.** This retroactively corrected my own "embedder lineage matters" claim — measured
   pre-reranker, it was less than half as large as reported.

3. **Retrieval is competitive, not absolute.** A bigger HyDE generator moved the query vector
   closer to the right answer *and* closer to everything else. Absolute similarity rose while
   discrimination fell. Optimise for separation from near-misses, not proximity to the answer.

4. **The Boundary Principle.** Information that exists but doesn't cross to its consumer reads
   as absence. Cure: attach the condition to the output as an un-smoothable *field*.

5. **The model axis is exhausted.** Five embedders, four reranking strategies, four generators.
   Everything ties the config found before any of them. Remaining gains are structural.

---

## 5. What is NOT done

Ordered by my recommendation, but the user triages.

1. **Today's Apple work is UNCROSSCHECKED.** `rerank-fm.swift`, `AppleFMReranker`, the
   `AppleFMExpander` cache_key fix, CLI wiring. The user's standing rule is crosscheck after
   every change set, adversary before presenting. Neither has run on it.
2. **The result contract.** `retrieve()` returns `(hits, trace)` and **every consumer discards
   the trace** (`runner.py:119`, `cli.py:273`). That is the Boundary Principle violated in our
   own code. Needs: passages + `capability` (which arms ACTUALLY ran) + `index_version`, as
   structured fields not prose. Tier costs are known: 0.698 / 0.593 / 0.343.
3. **markdown → Document reader.** The engine has only a PDF path. Vault ingestion (Doc 2)
   needs markdown → canonical `Document` → existing chunker. Est. ~100 lines, stdlib only,
   **no Docling**. This is the gate on "wire the engine to read Doc-2 vaults."
4. **Scanned-PDF guard.** `docling_arm.py:29` sets `do_ocr = False` and there is no text-layer
   assertion. A *fully* scanned PDF is caught by A14 (coverage 0.0) but only at `verify` time.
   The real hole is a *partially* scanned book — image-only pages vanish while coverage stays
   >0.95 and every gate goes green. Same shape as the chapter-title bug. `RapidOcr` and
   `granite-docling-258M` are downloaded and unwired.
5. **App settings reconciliation** (Doc 3) — its defaults predate the eval.

**Dropped from the roadmap:** extracting to a separate repo. I pushed it repeatedly on
inherited advice; once the architecture was corrected it stopped making sense. The Swift port
needs `gold.json` as its conformance test, and a split gold set silently drifts. Revisit only
if open-sourcing the engine while keeping the app closed.

**Do NOT build the PyMuPDF arm.** I proposed it to make ingestion lighter; it solves the wrong
problem, because the default ingestion path is markdown vaults, not PDFs.

---

## 6. Rules this project runs on

* **MRR quantum is 1/N per case** — 0.023 at 44 cases. A delta under that is a tie.
* **NEVER compare across cohorts.** The arc spans 7 → 24 → 44 cases. `0.642 → 0.603` is not a
  regression. Annotate harness changes explicitly.
* **Refuse rather than mislead.** The engine hard-fails on incomplete vectors, an unavailable
  reranker, or any query that fell back to a different arm.
* **Serial model work only.** One model at a time — concurrent runs cook the machine.
* **All model weights on `/Volumes/ExtremeSSD`**, never the internal disk. The user keeps
  unused models deliberately: the drive is a portable model library across machines.
* User workflow: `audit → review → implement → verify`. `/crosscheck` after implementation
  (auto-applies what clears its bar), `/adversary` last before presenting (report-only).

---

## 7. Known debt

**Adversary HIGH — ALL THREE FIXED** (verified 2026-07-22 against current code):

1. ~~ABSTAIN sinkhole~~ — FIXED. `rerank_cross.py:252` — `if not any(s != ABSTAIN for s in
   scores)` makes an all-abstain query a fallback, not a silent no-op rerank.
2. ~~ABSTAIN=0.5 outranks an explicit "no"~~ — FIXED. `:262` — the sort key is now
   `(scores[i] != 1.0, i)`, so "no" and ABSTAIN both sit below the yeses and keep fused order
   among themselves. An ABSTAIN is a non-signal and no longer buries a rejected rank-1.
3. ~~Counters provably identical~~ — FIXED. `transport_failures` is now documented and used as
   a strict SUBSET of `fallback_queries`, which also counts all-abstain queries.

Also fixed: `_CONFIG_SIG` now covers `TEMPERATURE` and `NUM_PREDICT`, plus a `_LOGIC_VERSION`
to bump when the parse rule or `_defang` changes (neither can be hashed from config).

**MEDIUM — still live:** exception tuple misses `ConnectionResetError`/`RemoteDisconnected`/
`IncompleteRead`/`UnicodeDecodeError` — **this one reaches shipped code**, all four sites:
`rerank_cross.py:191`, `rerank.py:113`, `expand.py:151,234` · pairs keyed by `chunk_id` but
scored on text · `cache_key` omits `host` · nothing rejects a non-reranker model under
`--cross-encoder`.

**Other:** Apple tier drops lexical to 27/28 (one case, unchased). Bonsai-27B runs via stock
`llama.cpp` at ~22 tok/s but is unshippable as a query-time generator; `LlamaServerHyDE` is
wired but never measured to a number.

---

## 8. Bugs worth remembering (they recur)

* **Silent path corruption.** A TOC rule deleted 11/14 DDIA chapter titles; every chunk then
  carried a well-formed path naming the WRONG chapter, with every gate green. Only a real query
  exposed it. → assertion A17.
* **Five retracted measurements**, every one a silent no-op producing a plausible number:
  orphaned cache key, a filter matching nothing falling through an `or`, deleted vectors, a
  doc filter matching nothing, an ad-hoc script bypassing the completeness guard.
* **`AppleFMExpander` had no `cache_key`** (fixed this session). With a cache attached, every
  call raised `AttributeError`, which `retriever.py`'s broad `except Exception` logged against
  **THE EMBEDDER**. The error named the wrong component with total confidence. Every prior
  Apple HyDE measurement passing a cache was silently lexical-only. It hid because the arm was
  only hand-tested with `cache=None` — **a different code path from the one that ships.**
* **A ranking probe with identical candidates proves nothing.** My first Apple-FM pool probe
  fed 20 identical passages and I nearly recorded the identity permutation as a finding.
* **Defaults sized for the smallest model in the fleet** killed two long runs (120s embed
  timeout, 5s availability probe).

---

## 9. Where things live

```
substrate/
  PRINCIPLES.md      how this project fails; read second
  EXPERIMENTS.md     every measurement, accepted AND rejected; read third
  FINDINGS.md        ingestion/document-structure findings
  HANDOFF.md         this file
  substrate/
    cli.py           ingest | verify | review | rechunk | index | query | embed | eval
    extract/         docling_arm, headings, furniture, toc      ← PDF only, heavy
    chunk/           chunker, sections, outline_records          ← takes Document, stdlib
    text/            hyphens, normalize, rejoin
    markdown/        emit, frontmatter
    store/           index_store, fts                            ← stdlib
    embed/           engine (Ollama + Apple), cache              ← stdlib
    retrieve/        retriever, expand, rerank, rerank_cross      ← stdlib
    eval/            runner
  tools/             hyde-fm.swift, embed-apple.swift, rerank-fm.swift
  bin/               built shims
  eval/gold.json     72 cases
  out/               ddia-2e, go-spec, paper-moral, substrate.db, vector-cache.db
```

Useful commands:

```bash
uv run python -m substrate.cli eval                                  # ceiling, 0.698
uv run python -m substrate.cli eval --embed-model apple \
    --hyde-model apple --rerank-model apple                          # floor, 0.593
uv run python -m substrate.cli eval --no-rerank                      # ablate
uv run python -m substrate.cli verify out/ddia-2e                    # A1-A17
swiftc -O tools/rerank-fm.swift -o bin/rerank-fm                     # rebuild a shim
```
