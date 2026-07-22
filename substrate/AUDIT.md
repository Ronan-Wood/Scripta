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
| H2 | High | `reconcile` hashes only `document.md`, so `rechunk` never reaches the index; `run.json` reclassification leaves a stale spine | `store/reconcile.py` | ✅ |
| H3 | High | gold case missing `answer`/`path` passes vacuously at rank 1 (`all([])==True`); gold set is currently clean, so it's a guard | `eval/runner.py:72-79,129` | 📋 |
| H4 | High | split-prose chunks all inherit the whole paragraph's `char_start/char_end` → overlapping offsets, violates the disjoint-offset invariant | `chunk/chunker.py` | ✅ |
| M  | Med | vector store can't hold two model spaces (`chunk_id` sole PK); isolation held only by `drop_vectors` | `store/schema.py:103` | 🔭 |
| M  | Med | semantic-MRR inflation when a doc isn't indexed (early-return cohort defaults `lexical`); `--update-baseline` persists it | `eval/runner.py:112,205` | 🔭 |
| M  | Med | `AppleEmbedder` doesn't L2-normalize / dim-check (asymmetric with Ollama arm) | `embed/engine.py` | 🔭 |
| M  | Med | `AppleFMExpander.cache_key` undefined → apple-fm HyDE arm silently degrades (read/write key mismatch even if fixed) | `retrieve/expand.py` | 🔭 |
| M  | Med | extraction heuristics that misfire off-corpus (CAPTION two-number regex; `toc_pages` build/assign asymmetry; furniture caption readmitted as TEXT; `_coverage` >1.0; furniture `page=None` counted) | `extract/*` | 🔭 |
| M  | Med | text repair: block-scoped compound guard; `residue()` checks 4 of 8 glyphs (false-clean) | `text/hyphens.py` | 🔭 |
| L  | Low | committed binary DBs `substrate.db`/`vectors.db`; `neighbours` seq-window vs prev/next; LIKE metachar in path-prefix; `report/review.py` "Repaired words" mislabel; misc | various | 🔭 |

---

## Batch (from your review) — cross-encoder & shipped-code

### Unit B — cross-encoder correctness (`retrieve/rerank_cross.py`)  ✅
- **High** all-abstain no-op → real fallback (bumps `fallback_queries`; plugs into H1's refusal — a
  non-reranker model under `--cross-encoder` now self-rejects at runtime)
- **High** sort fixed: `(scores[i] != YES, i)` promotes "yes", keeps "no"/ABSTAIN in fused order
  (verified identical to the old sort when no abstains → recorded 0.708/0.716 unchanged)
- **High** `transport_failures` ⊆ `fallback_queries` now distinct (all-abstain bumps only the latter)
- Med: `_CONFIG_SIG` rebuilt from explicit VALUES (prompt, sampling, `_CTRL.pattern`,
  `_DEFANG_TOKEN`, verdict tokens+values) + function BYTECODE — captures referenced constants and
  structural logic, no import-time `OSError`, no cosmetic cache-bust · per-pair cache keyed on a
  content hash of `h.text` (re-chunk-safe) · `cache_key` includes `host` · `--rerank-pool 0` guarded
- crosscheck (2 reviewers) → replaced a `_LOGIC_VERSION` manual-bump foot-gun with hashed logic;
  named `YES`/`NO`; fixed a stale cli abstention note. adversary (2 reviewers) → both caught that
  hashing function *source* missed referenced-constant values → rebuilt as values + bytecode.

### Unit C — exception-tuple breadth (shipped)  ✅
The 4 narrow `except (URLError, TimeoutError, JSONDecodeError)` sites (rerank.py, expand.py ×2,
rerank_cross.py) now catch by FAMILY via a shared `_TRANSPORT_ERRORS = (OSError,
http.client.HTTPException, json.JSONDecodeError, UnicodeDecodeError)` — covers the escaping
`ConnectionResetError`/`RemoteDisconnected`/`IncompleteRead`/`UnicodeDecodeError` (verified).
- adversary (2 reviewers) → cleared over-catch (try blocks are tight) + confirmed `OSError` subsumes
  `TimeoutError`/`ssl`; flagged the tuple triplication (DRY) and a residual non-dict-JSON-body
  `AttributeError`. Both fixed: `_TRANSPORT_ERRORS` + a safe `_response_field` helper consolidated
  into `retrieve/__init__.py`; all 4 sites route through it → a non-dict body now fails open.

### Unit D — arg / guard hardening (`cli.py` + rerankers)  ✅
`--no-gate` misuse now caught before the rerank block (so `--no-gate --no-rerank` can't slip) ·
`--rerank-pool < 1` rejected · cross-encoder `available()` honours tagless == `:latest` while
keeping exact-quant pinning.
- adversary (2 reviewers) → cleared the guard truth-table + `:latest` logic; flagged the 4th
  proposed fix (caching ABSTAIN scores for reproducibility) as HIGH — a durable, TTL-less cache
  would freeze a transient decode glitch (temp-0 greedy decode is not bit-exact on batched GPU),
  and the reproducibility was illusory (it froze noise). **Reverted** that fix per review; the
  anti-freeze rationale is now documented in the code so it isn't re-attempted.

---

## Cross-cutting — surfaced, your call  ✋

**Loopback-guard bypass (SSRF-flavoured egress).** `host.split("//")[-1].split(":")[0]` returns
`127.0.0.1` for `http://127.0.0.1:11434@attacker.example:1337`, so query text can egress to a
non-loopback host while the guard passes. Present in `LlamaServerHyDE.__post_init__`
(`retrieve/expand.py`) and the pre-existing `OllamaEmbedder.__post_init__` (`embed/engine.py`).
Fix: `urllib.parse.urlsplit(host).hostname` + case-insensitive compare. Not scheduled — flagging.
