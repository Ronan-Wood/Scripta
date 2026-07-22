# Substrate Engine — Audit Tracker

Living tracker for the 2026-07-22 audit pass and the fixes that follow it. Each fix goes
through implement → `/crosscheck` (auto-applies what clears the bar) → `/adversary` (diff-only
final gate) before it is presented for review. Findings and their evidence live in the git
history and in the conversation; this file is the index and status board.

**Status legend:** ✅ done · 🔧 in progress · 📋 queued · 🔭 reported, not scheduled · ✋ deferred / your call

---

## Dominant theme

> A degradation the producer knows about that never crosses the boundary to its consumer —
> PRINCIPLES.md incident #4, still live. The engine fixed this for *static / pre-flight*
> conditions (vector completeness guard, reranker refusal) but not for *dynamic / mid-run*
> ones. Most High findings are facets of that.

---

## H1 — Mid-run degradation → Trace → CaseResult  ✅

The eval discarded `retrieve()`'s `Trace`, so a mid-run embedder / HyDE / reranker failure was
counted under the full-pipeline label. **Fix (trace shape, chosen over per-arm counters):**
`retrieve()` records every primary-arm failure on `trace.degraded`; `run_case` threads it onto
`CaseResult.degraded`; `cmd_eval` refuses per-case (naming which query, with a denominator).

- crosscheck (3 reviewers) → drove the rework from counters to the trace shape (F2), plus
  expander-attribution (F1) and multi-query counting (F3).
- adversary (2 reviewers) → fixed a false-positive (empty multi-query result marked degraded)
  and a mis-attribution (store-search error labelled "embedder"). Multi-query and per-variant
  failures are now correctly treated as **supplementary** (fail open, no refusal); only the
  primary arms (vector embedder, HyDE on the primary query, reranker) degrade a case.
- Verified: 14 behavioral checks (every degradation path + no-false-positive on clean runs).

Touches: `retrieve/retriever.py`, `eval/runner.py`, `cli.py` (+ counter reverts in
`embed/engine.py`, `retrieve/expand.py`). Reranker keeps its own `fallback_queries` counter as
the internal per-call signal (gate-skip vs. real fallback can't be told apart externally).

---

## Original audit — remaining findings

| id | sev | finding | where | status |
|----|-----|---------|-------|--------|
| H2 | High | `reconcile` hashes only `document.md`, so `rechunk` never reaches the index; `run.json` reclassification leaves a stale spine | `store/reconcile.py:98,101` | 📋 |
| H3 | High | gold case missing `answer`/`path` passes vacuously at rank 1 (`all([])==True`); gold set is currently clean, so it's a guard | `eval/runner.py:72-79,129` | 📋 |
| H4 | High | split-prose chunks all inherit the whole paragraph's `char_start/char_end` → overlapping offsets, violates the disjoint-offset invariant | `chunk/chunker.py:110-112` | 📋 |
| M  | Med | vector store can't hold two model spaces (`chunk_id` sole PK); isolation held only by `drop_vectors` | `store/schema.py:103` | 🔭 |
| M  | Med | semantic-MRR inflation when a doc isn't indexed (early-return cohort defaults `lexical`); `--update-baseline` persists it | `eval/runner.py:112,205` | 🔭 |
| M  | Med | `AppleEmbedder` doesn't L2-normalize / dim-check (asymmetric with Ollama arm) | `embed/engine.py` | 🔭 |
| M  | Med | `AppleFMExpander.cache_key` undefined → apple-fm HyDE arm silently degrades (read/write key mismatch even if fixed) | `retrieve/expand.py` | 🔭 |
| M  | Med | extraction heuristics that misfire off-corpus (CAPTION two-number regex; `toc_pages` build/assign asymmetry; furniture caption readmitted as TEXT; `_coverage` >1.0; furniture `page=None` counted) | `extract/*` | 🔭 |
| M  | Med | text repair: block-scoped compound guard; `residue()` checks 4 of 8 glyphs (false-clean) | `text/hyphens.py` | 🔭 |
| L  | Low | committed binary DBs `substrate.db`/`vectors.db`; `neighbours` seq-window vs prev/next; LIKE metachar in path-prefix; `report/review.py` "Repaired words" mislabel; misc | various | 🔭 |

---

## Batch (from your review) — cross-encoder & shipped-code

### Unit B — cross-encoder correctness (`retrieve/rerank_cross.py`)  📋 next
- **High** all-abstain no-op labelled reranked → make it a real fallback (plugs into H1's refusal)
- **High** `ABSTAIN=0.5` outranks an explicit `no` (0.0) → "keeps fused order" comment is false
- **High** `transport_failures` / `fallback_queries` provably identical → differentiate or collapse
- Med: `_CONFIG_SIG` omits `num_predict`/`temperature`/`_defang`/parse rule · pair cache keyed by
  `chunk_id` but scored on `h.text` (stale after re-chunk) · `cache_key` omits host · reject a
  non-reranker model under `--cross-encoder`

### Unit C — exception-tuple breadth (shipped)  📋
`rerank.py:113`, `expand.py` HyDE/Llama catch only `(URLError, TimeoutError, JSONDecodeError)` —
miss `ConnectionResetError`/`RemoteDisconnected`/`IncompleteRead`/`UnicodeDecodeError`. Partly
pre-mitigated for the eval path by H1's retriever wraps; components' own contracts still need it.

### Unit D — arg / guard hardening (`cli.py` + rerankers)  📋
`--no-gate --no-rerank` slips the guard · `--rerank-pool 0/negative` · `available()` exact-match
rejects `:latest` · abstentions uncached so ordering isn't reproducible.

---

## Cross-cutting — surfaced, your call  ✋

**Loopback-guard bypass (SSRF-flavoured egress).** `host.split("//")[-1].split(":")[0]` returns
`127.0.0.1` for `http://127.0.0.1:11434@attacker.example:1337`, so query text can egress to a
non-loopback host while the guard passes. Present in `LlamaServerHyDE.__post_init__`
(`retrieve/expand.py`) and the pre-existing `OllamaEmbedder.__post_init__` (`embed/engine.py`).
Fix: `urllib.parse.urlsplit(host).hostname` + case-insensitive compare. Not scheduled — flagging.
