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

    @property
    def passed(self) -> bool:
        return self.both_rank is not None and self.both_rank <= K


@dataclass
class Summary:
    cases: list[CaseResult] = field(default_factory=list)
    elapsed_ms: float = 0.0

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


def run_case(store: IndexStore, case: dict, docs: dict[str, str], k: int = K) -> CaseResult:
    doc_id = docs.get(case["doc"])
    if doc_id is None:
        return CaseResult(id=case["id"], query=case["query"], note=f"doc {case['doc']!r} not indexed")
    hits = store.search(case["query"], k=k, kind="passage", doc_id=doc_id)

    res = CaseResult(id=case["id"], query=case["query"])
    if hits:
        res.top_path, res.top_page = hits[0].path_str, hits[0].page_start

    answer = case.get("answer", [])
    path = case.get("path", [])
    pages = case.get("pages")

    for i, h in enumerate(hits, start=1):
        a = _has_answer(h, answer)
        p = _has_path(h, path) and _in_pages(h, pages)
        if a and res.answer_rank is None:
            res.answer_rank = i
        if p and res.attrib_rank is None:
            res.attrib_rank = i
        if a and p and res.both_rank is None:
            res.both_rank = i

    if res.both_rank is None:
        if res.answer_rank and not res.attrib_rank:
            res.note = "content found, WRONG ATTRIBUTION"
        elif res.attrib_rank and not res.answer_rank:
            res.note = "right section, content missing"
        else:
            res.note = "not found"
    return res


def run(db: str, gold_path: Path, k: int = K) -> tuple[Summary, dict]:
    gold = json.loads(gold_path.read_text("utf-8"))
    summary = Summary()
    t0 = time.monotonic()
    with IndexStore(db) as store:
        docs = resolve_docs(store)
        for case in gold["cases"]:
            summary.cases.append(run_case(store, case, docs, k=k))
    summary.elapsed_ms = (time.monotonic() - t0) * 1000
    return summary, gold


def report(summary: Summary, gold: dict, baseline: dict | None) -> bool:
    m = summary.metrics
    gates = gold["gates"]

    failed = [c for c in summary.cases if not c.passed]
    print(f"  {len(summary.cases) - len(failed)}/{len(summary.cases)} cases pass "
          f"({summary.elapsed_ms:.0f}ms)\n")

    if failed:
        print("  FAILING CASES")
        for c in failed:
            print(f"    {c.id:<26} {c.note}")
            print(f"      q: {c.query[:74]}")
            print(f"      top: {c.top_path[:88] or '(nothing)'}")
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
        for c in summary.cases:
            was = baseline.get("cases", {}).get(c.id)
            if was and was.get("passed") and not c.passed:
                regressed.append(c.id)
        if regressed:
            ok = False
            print(f"\n  REGRESSED (passed in baseline, fail now): {', '.join(regressed)}")

    print(f"\n  {'PASS' if ok else 'FAIL'}")
    return ok
