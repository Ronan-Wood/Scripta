"""What crosses the boundary between the refresh pass and the readers of its record.

The engine refreshes its own scopes (`substrate.refresh`) and records each outcome
(`refresh_state.record`), which `render` and `introspect` read back as `refresh.frozen`. These pin
the vocabularies at their SOURCE: the freeze must mean what it says, and `status`'s `drift` object must keep the shape its readers
depend on. The retired shell agent (`tools/substrate-refresh`) was the first producer and parsed
`drift` itself; these tests outlived it because the record and the drift shape did.

Runnable with plain `python tests/test_refresh_contract.py`; discovered by pytest if added.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import freshness, introspect, scopes, stack  # noqa: E402
from substrate.models import Chunk, Document  # noqa: E402
from substrate.refresh_state import OUTCOMES  # noqa: E402
from substrate.store.index_store import IndexStore  # noqa: E402


def _seeded_store(db: str) -> IndexStore:
    s = IndexStore(db)
    doc = Document(doc_id="d0", source_path="/d0.md", source_sha256="s" * 8, source_pages=1,
                   document_class="reference-frozen", title="d0", status="active")
    ch = Chunk(chunk_id="d0#c0", doc_id="d0", kind="passage", text="replication lag",
               path=["Root", "d0"], level=2, n_chars=15, document_class="reference-frozen")
    s.upsert(doc, [ch], markdown_path="/d0.md", markdown_mtime=0.0, markdown_sha256="m" * 8)
    return s


# ---------------------------------------------------------------- the drift shape

def test_drift_emits_the_keys_its_readers_read() -> None:
    """`stale` and `checkable` must exist and be booleans. A reader distinguishes three states from
    them (the app's drift report, `substrate status`), and a missing key collapses two of those into
    one: `.get("stale")` returning None for a renamed field is indistinguishable, at the call site,
    from a drift check that ran."""
    with _seeded_store(str(Path(tempfile.mkdtemp()) / "i.db")) as s:
        d = freshness.drift(s, [])
    for key in ("stale", "checkable"):
        assert key in d, f"drift[{key!r}] is read by every drift reader; it is gone"
        assert isinstance(d[key], bool), f"drift[{key!r}] must be a bool, got {type(d[key])}"


def test_unreadable_notes_clear_checkable_rather_than_setting_stale() -> None:
    """The distinction a reader's `unknown` arm exists for.

    `stale: false, checkable: false` means "no change FOUND, and some notes were not examined".
    If unreadable notes were folded into `stale`, a reader would recompose (harmless); if they were
    folded into "clean", it would report a scope nobody could check as current — the false-healthy
    direction. This asserts which way it falls.
    """
    tmp = Path(tempfile.mkdtemp())
    missing = tmp / "gone.md"
    with _seeded_store(str(tmp / "i.db")) as s:
        # Indexed and composed, but unreadable now: a path the store holds that does not resolve.
        s.db.execute("UPDATE documents SET source_path=? WHERE doc_id='d0'", (str(missing),))
        d = freshness.drift(s, [missing])
    assert d["checkable"] is False, "an unreadable note must clear `checkable`"
    assert d["stale"] is False, "and must NOT be reported as a detected change"


def test_unresolvable_scope_reports_error_in_the_drift_slot() -> None:
    """`introspect` puts the failure IN `drift` rather than omitting the key, and a reader tests
    `"error" in d` FIRST. A moved vault, an unsynced OneDrive or a malformed manifest all land
    here, and `status` still exits 0 with valid JSON — so an omitted key would reach `.get("stale")
    is None` and, before that arm existed, `current`.

    EXECUTED, not grepped. An earlier version of this asserted that a source line was present in
    `introspect.py`, which is a weaker instrument twice over: it passes if the line moves into
    dead code, and it fails on a pure rename that preserved the behaviour exactly.
    """
    tmp = Path(tempfile.mkdtemp())
    entry = scopes.ScopeEntry(name="ghost", vault=tmp / "no-such-vault", db=tmp / "i.db",
                              index_root=None, composed="2026-01-01T00:00:00+00:00")
    with _seeded_store(str(tmp / "i.db")) as s:
        payload = introspect.status_payload(s, entry, stack=stack.Stack(),
                                            registry=str(tmp / "reg.toml"))
    assert "drift" in payload, "the drift key must be present even when the vault is unresolvable"
    assert "error" in payload["drift"], (
        f"an unresolvable vault must report drift.error; got {payload['drift']!r}")
    # A drift error that grew a `stale: false` would be a false all-clear for any reader that
    # checks `stale` before `error`.
    assert "stale" not in payload["drift"], "a drift error must not also claim a staleness verdict"


# ---------------------------------------------------------------- the record

def test_freeze_is_only_claimed_by_a_failed_compose() -> None:
    """The signal's meaning, pinned. `frozen: True` says "results come from a superseded index",
    and only a refused recompose establishes that. `embed_failed` recomposed successfully, so it
    degrades quality without freezing; `skipped` attempted nothing, so it can prove neither."""
    assert OUTCOMES["compose_failed"]["frozen"] is True
    assert OUTCOMES["embed_failed"]["frozen"] is False
    assert OUTCOMES["skipped"]["frozen"] is None, "no attempt is absent evidence, not a clean run"
    assert OUTCOMES["unchanged"]["frozen"] is False
    assert OUTCOMES["refreshed"]["frozen"] is False


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
