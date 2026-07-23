"""Regression tests for eval.runner._validate_gold and its wiring (H3).

Runnable with `python tests/test_gold_validation.py` or under pytest.

Pins H3: a gold case with no answer, or no attribution, has that half of the conjunctive gate
satisfied by every chunk (`all([]) == True`) and passes vacuously at rank 1. The validator must
reject such a case at LOAD, with a clean GoldError — and must reject the malformations the earlier
vacuous-pass fix uncovered (non-string members that crash scoring, missing id/query, non-`path`
attribution that only constrains for some corpora) — while accepting the whole committed gold set.

Also pins the cohort guard: report() buckets on cohort == "lexical" / "semantic" only, so a
present-but-unknown cohort (a typo, a non-string) matches neither bucket and vanishes from BOTH the
gate denominator and the semantic report. The validator must reject it at load; an absent cohort
(defaulting to "lexical") must still pass.
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.eval.runner import LEXICAL, SEMANTIC, GoldError, _validate_gold, run  # noqa: E402


def _raises(cases: list[dict]) -> bool:
    try:
        _validate_gold(cases)
        return False
    except GoldError:
        return True


def _case(**kw) -> dict:
    c = {"id": "c", "query": "q", "answer": ["x"], "path": ["Ch 1"]}
    c.update(kw)
    return c


def test_vacuous_case_rejected() -> None:
    assert _raises([{"id": "v", "query": "q"}])                      # no answer, no path


def test_answer_only_rejected() -> None:
    assert _raises([_case(path=[])])                                 # content but no attribution


def test_attribution_only_rejected() -> None:
    assert _raises([_case(answer=[])])                               # attribution but no content


def test_wellformed_case_accepted() -> None:
    _validate_gold([_case()])


def test_pages_or_expect_doc_without_path_rejected() -> None:
    # `path` is the only corpus-independent attribution; pages needs page metadata on the hit and
    # expect_doc needs a multi-doc un-scoped search, so neither substitutes for `path` at load.
    assert _raises([_case(path=[], pages=[1, 3])])
    assert _raises([_case(path=[], expect_doc="ddia-2e")])


def test_empty_and_blank_lists_rejected() -> None:
    # answer: [] / path: [] is the all([]) foot-gun; [""] / ["  "] is the same foot-gun behind a
    # truthy list ("" in hay is always True) — both must be rejected.
    assert _raises([_case(answer=[], path=[])])
    assert _raises([_case(answer=[""], path=[""])])
    assert _raises([_case(answer=["  "])])                           # blank answer member
    assert _raises([_case(path=["   "])])                            # blank path member


def test_non_string_members_rejected() -> None:
    # A non-string member ([None], [0], a bare string, a nested list) would crash _has_answer/
    # _has_path with AttributeError at scoring; catch it here as a clean GoldError instead.
    assert _raises([_case(answer=[None])])
    assert _raises([_case(answer=[0, "x"])])                         # mixed: still invalid
    assert _raises([_case(path=[None])])
    assert _raises([_case(answer="not a list")])


def test_missing_id_or_query_rejected() -> None:
    assert _raises([{"query": "q", "answer": ["x"], "path": ["c"]}])   # no id
    assert _raises([_case(id="")])                                     # blank id
    assert _raises([{"id": "c", "answer": ["x"], "path": ["c"]}])      # no query
    assert _raises([_case(query="  ")])                                # blank query


def test_unknown_cohort_rejected() -> None:
    # A typo'd cohort matches neither report() bucket and drops from both — reject at load.
    assert _raises([_case(cohort="lexcal")])                          # typo of "lexical"
    assert _raises([_case(cohort="hard")])                            # invented cohort
    assert _raises([_case(cohort="")])                                # blank string


def test_non_string_cohort_rejected() -> None:
    # `in COHORTS` compares by ==, so a non-string is never a bucket and must be rejected too.
    assert _raises([_case(cohort=None)])                             # JSON null present
    assert _raises([_case(cohort=1)])
    assert _raises([_case(cohort=["semantic"])])


def test_valid_and_absent_cohorts_accepted() -> None:
    _validate_gold([_case(cohort="lexical")])
    _validate_gold([_case(cohort="semantic")])
    _validate_gold([_case()])                                        # absent → defaults to lexical


def test_unknown_cohort_named_in_message() -> None:
    # The offending value must reach the operator, not just "invalid cohort".
    try:
        _validate_gold([_case(id="bc", cohort="lexcal")])
    except GoldError as e:
        assert "bc" in str(e) and "lexcal" in str(e)
    else:
        raise AssertionError("unknown cohort was not rejected")


def test_cohort_values_are_pinned() -> None:
    # report()'s buckets, the committed gold data, and cli.py's baseline all use these exact
    # spellings; pin them so a respelling of LEXICAL/SEMANTIC fails loudly here. (The real gold set
    # is exercised through the shipped validator by test_committed_gold_set_passes.)
    assert (LEXICAL, SEMANTIC) == ("lexical", "semantic")


def test_all_offenders_named_at_once() -> None:
    try:
        _validate_gold([_case(id="good"), {"id": "bad1", "query": "q"}, _case(id="bad2", path=[])])
    except GoldError as e:
        msg = str(e)
        assert "bad1" in msg and "bad2" in msg and "good" not in msg
    else:
        raise AssertionError("vacuous cases were not rejected")


def test_committed_gold_set_passes() -> None:
    gold = json.loads((Path(__file__).resolve().parent.parent / "eval" / "gold.json").read_text())
    _validate_gold(gold["cases"])


def _tmp_gold(content: str) -> Path:
    f = tempfile.NamedTemporaryFile("w", suffix=".json", delete=False)
    f.write(content)
    f.close()
    return Path(f.name)


def test_run_validates_before_opening_db() -> None:
    # Pins the WIRING: run() must validate the gold at load, before it opens the DB — so a bogus db
    # path is irrelevant; GoldError must fire first. (Guards against the validate call being lost.)
    gp = _tmp_gold(json.dumps({"cases": [{"id": "v", "query": "q"}], "gates": {}}))
    try:
        run("/no/such/db.sqlite", gp)
    except GoldError:
        pass
    else:
        raise AssertionError("run() did not validate the gold before opening the DB")
    finally:
        gp.unlink(missing_ok=True)


def test_run_rejects_bad_json_and_missing_cases() -> None:
    for content in ("{ not json", '{"gates": {}}'):     # unparseable JSON, then no 'cases' list
        gp = _tmp_gold(content)
        try:
            run("/no/such/db.sqlite", gp)
        except GoldError:
            pass
        else:
            raise AssertionError(f"run() accepted malformed gold: {content!r}")
        finally:
            gp.unlink(missing_ok=True)


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
