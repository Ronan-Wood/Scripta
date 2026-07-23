"""Regression test for the not-indexed early-return cohort (semantic-MRR integrity).

Runnable with `python tests/test_cohort_assignment.py` or under pytest.

Pins the medium: run_case's "doc not indexed" early return used to build a CaseResult with no
cohort, defaulting to "lexical". A SEMANTIC case whose doc is missing therefore dropped out of the
`semantic` cohort — inflating the reported semantic MRR (a miss removed from the denominator, which
--update-baseline then persists) and polluting the lexical gate with a spurious failure. The early
return must carry the case's declared cohort so a missing doc reads as a miss in its own cohort.

The early return fires before `store` is touched, so a dummy store (None) suffices.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.eval.runner import run_case  # noqa: E402


def test_not_indexed_semantic_case_stays_semantic() -> None:
    r = run_case(None, {"id": "s", "query": "q", "doc": "missing-doc", "cohort": "semantic"}, {})
    assert r.cohort == "semantic"        # counted in the semantic denominator, not dropped
    assert r.both_rank is None           # as a miss (doc not indexed)
    assert "not indexed" in r.note


def test_not_indexed_expect_doc_case_keeps_cohort() -> None:
    # The early return also fires for the expect_doc (cross-document) shape.
    r = run_case(None, {"id": "e", "query": "q", "expect_doc": "missing", "cohort": "semantic"}, {})
    assert r.cohort == "semantic"


def test_not_indexed_lexical_case_stays_lexical() -> None:
    r = run_case(None, {"id": "l", "query": "q", "doc": "missing-doc"}, {})
    assert r.cohort == "lexical"         # absent cohort defaults to lexical, unchanged


if __name__ == "__main__":
    _tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    _failed = 0
    for _t in _tests:
        try:
            _t()
            print(f"  PASS  {_t.__name__}")
        except Exception as e:  # noqa: BLE001
            _failed += 1
            print(f"  FAIL  {_t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(_tests) - _failed}/{len(_tests)} passed")
    raise SystemExit(1 if _failed else 0)
