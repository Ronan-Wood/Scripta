"""Retrieval eval — asserts the RIGHT answer, not a well-formed one.

Ports the discipline of Scripta's ./Eval/run.sh: written gates, a per-case no-regression
baseline, and a non-zero exit code so CI can hold the line.

The one design decision that matters: **the gate is conjunctive.** A case passes only when a
single returned chunk satisfies both the answer phrase AND the expected attribution. During
Phase 0 the pipeline produced three separate all-green states in which chunks carried
well-formed paths naming the WRONG chapter; a harness scoring attribution or content alone
would have blessed every one of them. Scoring them together is the whole point.

Structural metrics (MRR) are reported but are never the gate on their own.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path

from substrate.retrieve.retriever import retrieve
from substrate.store.index_store import Hit, IndexStore

K = 5


@dataclass
class CaseResult:
    id: str
    query: str
    answer_rank: int | None = None      # first chunk containing the answer phrase
    attrib_rank: int | None = None      # first chunk with the right attribution
    both_rank: int | None = None        # first chunk satisfying BOTH — the real signal
    top_path: str = ""
    top_page: int | None = None
    note: str = ""
    max_rank: int | None = None
    cohort: str = "lexical"
    ms: float = 0.0
    degraded: str = ""                   # mid-run arm failure, from result.capability.fallbacks
    expected_mrr: float | None = None    # measured tier for the arms that ran (result contract)

    @property
    def passed(self) -> bool:
        if self.both_rank is None:
            return False
        return self.both_rank <= (self.max_rank or K)


@dataclass
class Summary:
    cases: list[CaseResult] = field(default_factory=list)
    elapsed_ms: float = 0.0
    index_version: str = ""              # run-level, from the result contract (same for all cases)
    expected_cohort: str = ""            # the cohort the expected-MRR tier was measured on

    def rate(self, pred) -> float:
        return sum(1 for c in self.cases if pred(c)) / max(len(self.cases), 1)

    @property
    def metrics(self) -> dict:
        mrr = 0.0
        for c in self.cases:
            if c.both_rank:
                mrr += 1.0 / c.both_rank
        return {
            "answer_at_5": round(self.rate(lambda c: c.answer_rank and c.answer_rank <= 5), 4),
            "answer_at_1": round(self.rate(lambda c: c.answer_rank == 1), 4),
            "attribution_at_5": round(self.rate(lambda c: c.attrib_rank and c.attrib_rank <= 5), 4),
            "both_at_5": round(self.rate(lambda c: c.passed), 4),
            "mrr": round(mrr / max(len(self.cases), 1), 4),
        }


def _has_answer(hit: Hit, phrases: list[str]) -> bool:
    hay = hit.text.lower()
    return all(p.lower() in hay for p in phrases)


def _has_path(hit: Hit, fragments: list[str]) -> bool:
    hay = hit.path_str.lower()
    return all(f.lower() in hay for f in fragments)


def _in_pages(hit: Hit, bounds: list[int] | None) -> bool:
    if not bounds or hit.page_start is None:
        return True
    return bounds[0] <= hit.page_start <= bounds[1]


def resolve_docs(store: IndexStore) -> dict[str, str]:
    """Map an output-directory name (what gold cases name) to the real doc_id.

    Gold cases say "ddia-2e"; the doc_id is "designing-data-intensive-applications-...".
    An earlier prefix-match here silently matched NOTHING and fell through to an unfiltered
    corpus-wide search — a no-op filter that still reported plausible numbers.
    """
    out: dict[str, str] = {}
    for d in store.documents():
        parts = Path(d["markdown_path"]).parts
        if len(parts) >= 2:
            out[parts[-2]] = d["doc_id"]
    return out


def run_case(store: IndexStore, case: dict, docs: dict[str, str], k: int = K, route: bool = True, embedder=None, expander=None, multiquery=None, reranker=None) -> CaseResult:
    # Three case shapes:
    #   doc         — search within one document (the answer's location is the question)
    #   expect_doc  — search EVERYTHING; the right source must win (cross-document)
    #   max_rank    — the answer must be at rank N, not merely inside k
    scoped = case.get("doc")
    expect_doc = case.get("expect_doc")
    target = scoped or expect_doc
    doc_id = docs.get(target) if target else None
    if target and doc_id is None:
        return CaseResult(id=case["id"], query=case["query"], note=f"doc {target!r} not indexed")

    _t0 = time.monotonic()
    cap = None
    if case.get("kind") == "outline":
        hits = store.search(case["query"], k=k, kind="outline", doc_id=doc_id if scoped else None)
    else:
        result = retrieve(
            store, case["query"], k=k, doc_id=doc_id if scoped else None, route=route,
            embedder=embedder, expander=expander, multiquery=multiquery, reranker=reranker,
        )
        hits, cap = result.passages, result.capability

    _elapsed = (time.monotonic() - _t0) * 1000
    res = CaseResult(id=case["id"], query=case["query"], ms=_elapsed)
    # Read the result contract, don't discard it. A mid-run arm failure crosses the boundary as
    # capability.fallbacks (fields, not prose), so cmd_eval can refuse a number measured under a
    # degradation its label does not state, and name WHICH case. The measured tier and index
    # version ride along too, so the eval surfaces what stack produced the number.
    if cap is not None:
        res.degraded = "; ".join(cap.fallbacks)
        res.expected_mrr = cap.expected_mrr
    if hits:
        res.top_path, res.top_page = hits[0].path_str, hits[0].page_start

    answer = case.get("answer", [])
    path = case.get("path", [])
    pages = case.get("pages")

    for i, h in enumerate(hits, start=1):
        a = _has_answer(h, answer)
        p = _has_path(h, path) and _in_pages(h, pages)
        if expect_doc and h.doc_id != doc_id:
            p = False  # right content from the WRONG SOURCE is not a pass
        if a and res.answer_rank is None:
            res.answer_rank = i
        if p and res.attrib_rank is None:
            res.attrib_rank = i
        if a and p and res.both_rank is None:
            res.both_rank = i

    res.max_rank = case.get("max_rank")
    res.cohort = case.get("cohort", "lexical")
    if res.both_rank is None:
        if res.answer_rank and not res.attrib_rank:
            res.note = (
                "content found, WRONG SOURCE" if expect_doc else "content found, WRONG ATTRIBUTION"
            )
        elif res.attrib_rank and not res.answer_rank:
            res.note = "right section, content missing"
        else:
            res.note = "not found"
    elif res.max_rank and res.both_rank > res.max_rank:
        res.note = f"found at rank {res.both_rank}, required rank {res.max_rank}"
    return res


def run(db: str, gold_path: Path, k: int = K, route: bool = True, embedder=None, expander=None, multiquery=None, reranker=None) -> tuple[Summary, dict]:
    gold = json.loads(gold_path.read_text("utf-8"))
    summary = Summary()
    t0 = time.monotonic()
    from substrate.retrieve.retriever import _COHORT

    with IndexStore(db) as store:
        docs = resolve_docs(store)
        for case in gold["cases"]:
            summary.cases.append(run_case(store, case, docs, k=k, route=route, embedder=embedder, expander=expander, multiquery=multiquery, reranker=reranker))
        summary.index_version = store.index_version  # run-level: one index per eval
    summary.expected_cohort = _COHORT
    summary.elapsed_ms = (time.monotonic() - t0) * 1000
    return summary, gold


def report(summary: Summary, gold: dict, baseline: dict | None) -> bool:
    # The semantic cohort is the IMPROVEMENT TARGET, not the CI line. Gates are computed on
    # the lexical cohort so a known-hard paraphrase set cannot mask a real regression, and a
    # real regression cannot hide behind a hard set that was always failing.
    lexical = Summary([c for c in summary.cases if c.cohort == "lexical"], summary.elapsed_ms)
    semantic = [c for c in summary.cases if c.cohort == "semantic"]

    m = lexical.metrics
    gates = gold["gates"]

    failed = [c for c in lexical.cases if not c.passed]
    print(f"  LEXICAL  {len(lexical.cases) - len(failed)}/{len(lexical.cases)} pass "
          f"({summary.elapsed_ms:.0f}ms)")
    if semantic:
        sp = sum(1 for c in semantic if c.passed)
        print(f"  SEMANTIC {sp}/{len(semantic)} pass   (paraphrase cohort — Phase 3 target, "
              "not gated)")
    print()

    if failed:
        print("  FAILING CASES")
        for c in failed:
            print(f"    {c.id:<26} {c.note}")
            print(f"      q: {c.query[:74]}")
            print(f"      top: {c.top_path[:88] or '(nothing)'}")
        print()

    if semantic:
        # Report a GRADIENT, not three binary flags. Section-aware ranking measurably
        # improved retrieval while the pass count stayed at 4/7 — the progress was visible
        # only in the failure notes. A continuous signal is what the remaining work climbs.
        base_cases = (baseline or {}).get("cases", {})
        sem_mrr = sum(1.0 / c.both_rank for c in semantic if c.both_rank) / len(semantic)
        base_mrr = (baseline or {}).get("semantic_mrr")
        delta = f"  ({sem_mrr - base_mrr:+.3f})" if base_mrr is not None else ""
        print(f"  SEMANTIC COHORT — mrr {sem_mrr:.3f}{delta}   (ungated; Phase 3 target)")
        for c in semantic:
            was = base_cases.get(c.id, {}).get("rank")
            now = c.both_rank
            if now and was:
                mark = "=" if now == was else ("↑" if now < was else "↓")
                move = f"rank {now} (was {was}) {mark}"
            elif now:
                move = f"rank {now} (was miss) ↑"
            elif was:
                move = f"MISS (was rank {was}) ↓"
            else:
                move = f"miss — {c.note}"
            print(f"    {'PASS' if c.passed else 'gap '}  {c.id:<26} {move}")
            if not c.passed:
                print(f"          top: {c.top_path[:80] or '(nothing)'}")
        print()

    print("  METRICS")
    ok = True
    for name, value in m.items():
        gate = gates.get(name)
        if gate is None:
            print(f"    {name:<18} {value}")
            continue
        good = value >= gate
        ok = ok and good
        print(f"    {name:<18} {value}   gate {gate}   {'PASS' if good else 'FAIL'}")

    # Per-case no-regression: a case that used to pass may never start failing.
    regressed: list[str] = []
    if baseline:
        for c in lexical.cases:
            was = baseline.get("cases", {}).get(c.id)
            if was and was.get("passed") and not c.passed:
                regressed.append(c.id)
        if regressed:
            ok = False
            print(f"\n  REGRESSED (passed in baseline, fail now): {', '.join(regressed)}")

    # LATENCY IS A SCORED AXIS. A local engine scoring 0.65 at 8s/query is worse in practice
    # than 0.62 at 1s — a config is only "best" if it is affordable to run on every query.
    # Reporting it beside MRR keeps that visible instead of buried in a commit message.
    lat = sorted(c.ms for c in summary.cases if c.ms)
    if lat:
        p50 = lat[len(lat) // 2]
        p95 = lat[min(int(len(lat) * 0.95), len(lat) - 1)]
        print(
            f"\n  LATENCY  p50 {p50:.0f}ms   p95 {p95:.0f}ms   max {lat[-1]:.0f}ms"
            "   (per query; expansions cached)"
        )

    # Surface the result contract the eval now reads instead of discarding: which index this ran
    # against, and the measured tier for the arms that ran — taken from a NON-degraded case so it
    # represents the run's configured stack, not a mid-run casualty. ALWAYS print the tier's
    # cohort AND this run's semantic count side by side, unconditionally: a number measured at 44
    # cases beside an MRR computed over N≠44 is the cross-cohort comparison HANDOFF §6 forbids, so
    # the reader must always see both counts (never a substring/equality suppression that a stray
    # count like 4 ⊂ 44 could defeat).
    rep = next((c for c in summary.cases if not c.degraded and c.expected_mrr is not None), None)
    exp_s = f"~{rep.expected_mrr}" if rep is not None else "unmeasured for this stack"
    n_sem = sum(1 for c in summary.cases if c.cohort == "semantic")
    tier_cohort = summary.expected_cohort or "measured"
    print(f"\n  CONTRACT  index {summary.index_version or '(n/a)'}   "
          f"expected {exp_s} (tier: {tier_cohort}; this run: {n_sem} semantic case"
          f"{'s' if n_sem != 1 else ''})")

    print(f"\n  {'PASS' if ok else 'FAIL'}")
    return ok
