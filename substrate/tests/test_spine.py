"""spine.validate_status — the refuse-rather-than-mislead gate for a note's status (Doc 2 §6).

The reader is a pure parser; strictness lives in spine, chosen by the caller. These pin the two
strictness modes and every way a status misleads: absent-where-required, unknown, and superseded
with no link to what replaced it.

Runnable with plain `python tests/test_spine.py`.
"""

from __future__ import annotations

import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.models import Document  # noqa: E402
from substrate.spine import SpineError, validate_doc_type, validate_status  # noqa: E402


def _doc(**kw: object) -> Document:
    base = dict(doc_id="d", source_path="/d.md", source_sha256="s", source_pages=1,
                document_class="reference-frozen")
    base.update(kw)
    return Document(**base)  # type: ignore[arg-type]


def test_absent_status_defaults_active_when_lenient() -> None:
    assert validate_status(_doc(status=None), require_present=False) == "active"


def test_absent_status_refused_when_required() -> None:
    try:
        validate_status(_doc(status=None), require_present=True)
    except SpineError:
        return
    raise AssertionError("expected SpineError for an absent status in the strict path")


def test_unknown_status_refused_in_both_modes() -> None:
    for req in (True, False):
        try:
            validate_status(_doc(status="bogus"), require_present=req)
        except SpineError:
            continue
        raise AssertionError(f"expected SpineError for an unknown status (require={req})")


def test_superseded_requires_a_link() -> None:
    try:
        validate_status(_doc(status="superseded", superseded_by=None), require_present=True)
    except SpineError:
        pass
    else:
        raise AssertionError("expected SpineError for superseded with no superseded_by")
    # With the link it is accepted.
    assert validate_status(
        _doc(status="superseded", superseded_by="newer"), require_present=True
    ) == "superseded"


def test_each_valid_status_accepted() -> None:
    assert validate_status(_doc(status="active"), require_present=True) == "active"
    assert validate_status(_doc(status="complete"), require_present=True) == "complete"
    assert validate_status(_doc(status="archived"), require_present=True) == "archived"


# ---------------------------------------------------------------- doc_type (§6a)

def test_absent_doc_type_defaults_reference_when_lenient() -> None:
    # The standalone reference corpus (no doc_type) stays ingesting as reference lookup material.
    assert validate_doc_type(_doc(doc_type=None), require_present=False) == "reference"


def test_absent_doc_type_refused_when_required() -> None:
    # The vault path forces every note to declare its job — defaulting would hide a two-job note.
    try:
        validate_doc_type(_doc(doc_type=None), require_present=True)
    except SpineError:
        return
    raise AssertionError("expected SpineError for an absent doc_type in the strict path")


def test_unknown_doc_type_refused_in_both_modes() -> None:
    for req in (True, False):
        try:
            validate_doc_type(_doc(doc_type="tutorial"), require_present=req)
        except SpineError:
            continue
        raise AssertionError(f"expected SpineError for an unknown doc_type (require={req})")


def test_each_valid_doc_type_accepted() -> None:
    for dt in ("decision", "explanation", "reference", "how-to"):
        assert validate_doc_type(_doc(doc_type=dt), require_present=True) == dt


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
