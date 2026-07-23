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
| M  | Med | `AppleEmbedder` doesn't L2-normalize / dim-check (asymmetric with Ollama arm) | `embed/engine.py` | ✅ |
| M  | Med | `AppleFMExpander.cache_key` undefined → apple-fm HyDE arm silently degrades (read/write key mismatch even if fixed) | `retrieve/expand.py` | ✅ |
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

## Cross-cutting — loopback egress guard  ✅

**Loopback-guard bypass (SSRF-flavoured egress).** The old `host.split("//")[-1].split(":")[0]`
read `127.0.0.1` out of `http://127.0.0.1:11434@evil.example:1337` (that's userinfo, not the host)
and mangled `http://[::1]:port` down to `[` (wrongly refusing IPv6 loopback). **Fix:** a shared
`substrate/net.py::is_loopback()` — `urlsplit(host).hostname`, refuses ANY userinfo outright, fails
closed on non-str / malformed / no-host, allowed set unchanged (not widened). Both
`LlamaServerHyDE.__post_init__` and `OllamaEmbedder.__post_init__` call it; refusal messages made
accurate (no false "non-loopback" for a scheme-less loopback host) + actionable. Regression test:
`tests/test_loopback_guard.py` (11 cases).
- crosscheck (3 reviewers) → reject userinfo outright: `urllib.request` does NOT strip it, so
  `urlsplit().hostname` and the socket disagree — the `@evil.example` string DNS-fails under this
  transport, but a userinfo-stripping one (requests/httpx) would connect off-machine. Reframed as
  parsing-correctness + defense-in-depth, not a live exfil-through-`urllib.request` bug.
- adversary (2 reviewers, diff-only) → **no bypass found** (both verified `is_loopback` never
  returns True for a host the transport reaches off-loopback). Added: non-str fail-closed guard
  (was leaking `AttributeError`), honest test comments (only the `@evil.example:1337` case was an
  old-guard bypass), actionable scheme-less message.

## Follow-up — HyDE / MultiQuery had NO egress guard  ✅

`HyDE` (the DEFAULT Ollama expander) and `MultiQuery` in `retrieve/expand.py` took a `host` and
POSTed the query to it with **no loopback check at all** — not the broken guard, none. **Fix:**
introduced `net.py::require_loopback(host, *, sends, suggest, exc=ValueError)` — one shared
guard-and-raise so the refusal message can't drift either — and routed all four arms through it
(embedder + LlamaServerHyDE + HyDE + MultiQuery). Regression test extended (13 cases).
- crosscheck (2 reviewers) → made `suggest` a required arg (the generic guard shouldn't hardcode
  Ollama's port); flagged `MultiQuery.available()` could raise now.
- adversary (2 reviewers, diff-only) → **reverted** a crosscheck-added `available()` try/except: it
  defended only a post-construction-mutation non-threat (host is already validated at construction)
  and over-caught. Also surfaced the reranker gap below and that the `net.py` docstring's "every
  arm" claim was false — docstring corrected.

## Follow-up — rerankers have NO egress guard  ✅

`LLMReranker` (`retrieve/rerank.py`) and `CrossEncoderReranker` (`retrieve/rerank_cross.py`) both
took a `host` and POSTed query/passages to `f"{self.host}/api/generate"` with **no
`require_loopback` guard**. Same egress class as the expanders. **Fix:** added `require_loopback`
(`sends="the query and passages"`) to both `__post_init__`. `AppleFMReranker` left unguarded — its
`host` is a read-only property returning `bin/rerank-fm` (a local subprocess), so guarding it would
wrongly raise. Every network-egress arm now routes through the shared guard; the `net.py` docstring
is left non-universal on purpose so a future arm can't silently re-falsify a "covers every arm"
claim. Regression test: `test_rerankers_carry_the_guard`.
