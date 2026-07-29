"""The refresh agent is the PRODUCER of the freeze signal, and it parses the CLI's JSON.

`tools/substrate-refresh` reads `status --json`'s `drift` object and decides from it whether to
recompose a scope; it then records an outcome that `render` and `introspect` read back as
`refresh.frozen`. Neither half was held by anything in CI while the script lived only in
`~/.local/bin`, and the failure mode is not a crash: the probe has a `try/except` that prints
`unknown` on any error, so a renamed key degrades it to "recompose every scope every fifteen
minutes" — and a key that changes MEANING degrades it to recording `unchanged`, the strongest
healthy claim in the vocabulary, for scopes nobody checked. Both are quiet.

These tests pin the two vocabularies at their SOURCE — `freshness.drift`, `introspect` and
`refresh_state.OUTCOMES` — against the literal strings the shell script reads. They fail when the
engine moves, which is the direction that matters: the script cannot be changed by an engine
refactor, so the engine has to be told.

**What is and is not executed here.** The engine side is exercised for real: `drift` is computed
over actual files, and the unresolvable-scope case calls `status_payload` rather than grepping
`introspect.py` for a source line. The agent side is not run as a WHOLE — invoking
`tools/substrate-refresh` would recompose six live scopes as a side effect — but its probe is
EXTRACTED from the script by `_probe_source()` and executed, so the code under test is the code
that ships.

That extraction replaced a hand-typed copy of the probe, which the previous docstring called "the
alarm". It was not one. Deleting the `"error" in d` arm from the script left every test in this
file green: the execution test ran its own copy, and the key check matched anywhere in the file —
including the two comments that quote `{"error": ...}` and `stale` in prose. Both are now read from
the extracted body, and that same mutation fails the suite.

Runnable with plain `python tests/test_refresh_contract.py`; discovered by pytest if added.
"""

from __future__ import annotations

import json
import re
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import freshness, introspect, scopes, stack  # noqa: E402
from substrate.models import Chunk, Document  # noqa: E402
from substrate.refresh_state import OUTCOMES  # noqa: E402
from substrate.store.index_store import IndexStore  # noqa: E402

_REPO = Path(__file__).resolve().parent.parent
_AGENT = _REPO / "tools" / "substrate-refresh"

# The three keys the agent's python3 probe reads, verbatim from its source:
#     if "error" in d or not d.get("checkable", True) or d.get("stale") is None:
_PROBE_KEYS = ("error", "checkable", "stale")

# The five outcomes the agent passes to `refresh-record`. `record` REFUSES an outcome outside
# OUTCOMES, so an outcome the agent emits that the engine dropped is a hard failure at 15-minute
# intervals, logged to a file nobody reads.
_AGENT_OUTCOMES = ("unchanged", "refreshed", "compose_failed", "embed_failed", "skipped")


def _seeded_store(db: str) -> IndexStore:
    s = IndexStore(db)
    doc = Document(doc_id="d0", source_path="/d0.md", source_sha256="s" * 8, source_pages=1,
                   document_class="reference-frozen", title="d0", status="active")
    ch = Chunk(chunk_id="d0#c0", doc_id="d0", kind="passage", text="replication lag",
               path=["Root", "d0"], level=2, n_chars=15, document_class="reference-frozen")
    s.upsert(doc, [ch], markdown_path="/d0.md", markdown_mtime=0.0, markdown_sha256="m" * 8)
    return s


# ---------------------------------------------------------------- the drift shape

def test_drift_emits_the_keys_the_agent_reads() -> None:
    """`stale` and `checkable` must exist and be booleans. The agent distinguishes three states
    from them, and a missing key collapses two of those into one: `.get("stale")` returning None
    for a renamed field is indistinguishable, at the call site, from a drift check that ran."""
    with _seeded_store(str(Path(tempfile.mkdtemp()) / "i.db")) as s:
        d = freshness.drift(s, [])
    for key in ("stale", "checkable"):
        assert key in d, f"the refresh agent reads drift[{key!r}]; it is gone"
        assert isinstance(d[key], bool), f"drift[{key!r}] must be a bool, got {type(d[key])}"


def test_unreadable_notes_clear_checkable_rather_than_setting_stale() -> None:
    """The distinction the agent's `unknown` arm exists for, and the one it used to miss.

    `stale: false, checkable: false` means "no change FOUND, and some notes were not examined".
    If unreadable notes were folded into `stale`, the agent would recompose (harmless); if they
    were folded into "clean", it would record `unchanged` for a scope nobody could check — the
    false-healthy direction. This asserts which way it falls.
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
    """`introspect` puts the failure IN `drift` rather than omitting the key, and the agent tests
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
    # The agent's own precedence: `"error" in d` is tested BEFORE `stale`, so an error object that
    # also happened to carry a `stale` key would still probe as `unknown`. Pin the absence anyway —
    # a drift error that grew a `stale: false` would be a false all-clear for any other reader.
    assert "stale" not in payload["drift"], "a drift error must not also claim a staleness verdict"


# ---------------------------------------------------------------- the agent's own source

def _probe_source() -> str:
    """The probe body, lifted OUT of `tools/substrate-refresh` at test time.

    Reading it from the script is the whole point. Both an earlier version of this file and its
    docstring claimed the inline copy was "the alarm" — it was not: the copy could be executed and
    pass while the shipped probe said something else, and the key check below matched anywhere in
    the file, including the two comment lines that quote `{"error": ...}` and `stale` in prose.
    Verified: deleting the `"error" in d` arm from the script left the whole file green.
    """
    src = _AGENT.read_text("utf-8")
    start = src.index("python3 -c '") + len("python3 -c '")
    end = src.index("'", start)
    body = src[start:end]
    assert "json.load" in body, f"probe extraction found no probe: {body[:80]!r}"
    return body


def test_agent_probe_reads_exactly_these_keys_and_no_others() -> None:
    """Pins the script against the engine in the OTHER direction, in BOTH directions of drift.

    Matched against the extracted PROBE, not the whole file — `"error"` and `"stale"` both appear
    in the script's comment prose, so a file-wide match was satisfied with no probe code at all.

    And it is set EQUALITY, not presence. A presence-only check cannot see a key being ADDED, so a
    probe that grew a dependency on some `drift["verified"]` the engine does not emit would pass
    while degrading every tick to `unknown` — six scopes recomposed every fifteen minutes forever,
    reported as healthy. Verified: that mutation passed the presence-only form.
    """
    body = _probe_source()
    read = set(re.findall(r'd\.get\("([^"]+)"', body)) | set(re.findall(r'"([^"]+)" in d', body))
    read |= set(re.findall(r'd\["([^"]+)"\]', body))
    assert read == set(_PROBE_KEYS), (
        f"the probe reads {sorted(read)}; this contract pins {sorted(_PROBE_KEYS)}. "
        "A key added here is a new dependency on the engine's payload; a key removed is an arm "
        "of the drift verdict that stopped being checked.")


def test_every_outcome_the_agent_records_is_in_the_vocabulary() -> None:
    """`refresh_state.record` refuses an unknown outcome, so a vocabulary change the agent does not
    follow makes every tick fail — and the agent only logs a WARNING on a failed record, so the
    scopes would keep serving their last healthy verdict while nothing new was ever written."""
    # Comment lines stripped, and only real `record <outcome>` invocations counted. The `or
    # '"<outcome>"' in src` arm this replaces matched the word `"unchanged"` inside the header
    # comment `(reconcile reports "unchanged")`, so deleting the ONLY line that records it left
    # this green — vacuous for precisely the outcome the vocabulary calls the strongest healthy
    # claim it has.
    # Comments stripped AND string literals blanked, then real invocations matched. Two false
    # positives to exclude and they need different treatment: `(reconcile reports "unchanged")` in
    # a comment, and `say "WARNING: record called with no outcome"` in a live line of code. Line
    # anchoring does not work either — the `unchanged` call sits after an `&&`.
    code = "\n".join(ln for ln in _AGENT.read_text("utf-8").splitlines()
                     if not ln.lstrip().startswith("#"))
    code = re.sub(r'"[^"]*"', '""', code)
    recorded = set(re.findall(r'\brecord\s+([a-z_]+)', code))
    for outcome in _AGENT_OUTCOMES:
        assert outcome in OUTCOMES, (
            f"the agent records {outcome!r}, which is no longer in refresh_state.OUTCOMES")
        assert outcome in recorded, (
            f"the agent no longer records {outcome!r}; this contract is stale")
    assert recorded <= set(OUTCOMES), (
        f"the agent records {sorted(recorded - set(OUTCOMES))}, which `refresh_state.record` "
        "refuses — every tick would fail, and it only logs a WARNING when it does")


def test_freeze_is_only_claimed_by_a_failed_compose() -> None:
    """The signal's meaning, pinned. `frozen: True` says "results come from a superseded index",
    and only a refused recompose establishes that. `embed_failed` recomposed successfully, so it
    degrades quality without freezing; `skipped` attempted nothing, so it can prove neither."""
    assert OUTCOMES["compose_failed"]["frozen"] is True
    assert OUTCOMES["embed_failed"]["frozen"] is False
    assert OUTCOMES["skipped"]["frozen"] is None, "no attempt is absent evidence, not a clean run"
    assert OUTCOMES["unchanged"]["frozen"] is False
    assert OUTCOMES["refreshed"]["frozen"] is False


# ---------------------------------------------------------------- end to end

def _probe(label: str, payload: str) -> str:
    """Run the SHIPPED probe over one payload and return its verdict."""
    r = subprocess.run([sys.executable, "-c", _probe_source()], input=payload,
                       capture_output=True, text=True)
    return r.stdout.strip()


def test_probe_parses_a_real_status_payload() -> None:
    """The string assertions above compare two files; this runs the agent's ACTUAL probe over a
    payload the engine actually emitted. Both are needed — a key can be present and mean something
    new, which only executing the parse can catch.

    The clean case needs a note that is genuinely on disk with a matching checksum. An earlier
    version of this fixture passed `[]` for the note set, which makes the indexed document
    *removed* — so it probed `stale`, and the test would have been "corrected" by loosening the
    assertion to accept the value the broken fixture produced.
    """
    tmp = Path(tempfile.mkdtemp())
    note = tmp / "d0.md"
    note.write_text("replication lag\n", encoding="utf-8")
    sha, _ = freshness.effective_sha_of(note.read_bytes())
    with _seeded_store(str(tmp / "i.db")) as s:
        s.db.execute("UPDATE documents SET source_path=?, source_sha256=? WHERE doc_id='d0'",
                     (str(note), sha))
        d = freshness.drift(s, [note])
    assert d == {**d, "stale": False, "checkable": True}, f"fixture is not clean: {d}"
    payload = json.dumps({"drift": d})

    # The SHIPPED probe, read out of the script — not a copy retyped here. A copy can only prove
    # that some probe parses this payload; it cannot notice the deployed one drifting away from it.
    assert _probe("current", payload) == "current", "a clean, checkable index must probe `current`"

    # EVERY ARM, because two of the four were unpinned and their mutations stayed green:
    #
    #   `stale`      — nothing ever fed the probe a changed vault, so a probe that could never
    #                  return `stale` passed the whole suite. That agent records `unchanged` — the
    #                  strongest healthy claim the vocabulary has — for every scope that moved.
    #   `checkable`  — the arm this whole mechanism was built for. `stale: false, checkable: false`
    #                  is "no change found, and some notes were not examined"; folding it into
    #                  `current` is the original bug. `test_unreadable_notes_...` proves only that
    #                  the ENGINE emits that shape; nothing handed it to the probe.
    #
    # The `stale is None` arm covers a renamed field: absent key, no verdict, not an all-clear.
    changed = {**d, "stale": True}
    assert _probe("stale", json.dumps({"drift": changed})) == "stale", (
        "a vault that demonstrably changed must probe `stale` — a probe that cannot say so "
        "records `unchanged` for every scope that moved")

    uncheckable = {**d, "stale": False, "checkable": False}
    assert _probe("uncheckable", json.dumps({"drift": uncheckable})) == "unknown", (
        "notes that could not be read must probe `unknown`, never `current`")

    renamed = {k: v for k, v in d.items() if k != "stale"}
    assert _probe("renamed", json.dumps({"drift": renamed})) == "unknown", (
        "a missing `stale` key is absent evidence, not a clean result")

    assert _probe("error", json.dumps({"drift": {"error": "x"}})) == "unknown", (
        "an unresolvable scope must probe `unknown`")

    assert _probe("garbage", "not json at all") == "unknown", (
        "an unparseable payload must probe `unknown`")


def test_agent_refuses_a_repo_it_cannot_resolve() -> None:
    """A derived REPO must be VALIDATED, and the check is exercised, not grepped.

    `dirname "$0"` follows the invocation path, not the real one, so deploying the agent as a
    symlink (the obvious simplification of the exec shim) silently made REPO the symlink's parent —
    a writable directory. The agent would compose six scopes there, re-register all of them against
    the new location, and record `refreshed`/`frozen: false`, while every query kept reading the
    untouched old indexes. The signal's own writer emitting a false-healthy verdict.

    Run under a throwaway HOME so the log, the lock and `refresh.json` all land in the sandbox —
    the script records `skipped` on this path, and pointing that at the real state file would make
    the test degrade the live freshness signal for six scopes every time it ran.
    """
    import os
    import subprocess as sp

    tmp = Path(tempfile.mkdtemp())
    link = tmp / "bin" / "substrate-refresh"
    link.parent.mkdir()
    link.symlink_to(_AGENT)          # REPO resolves to tmp/, which is not a checkout

    # The agent checks its recorder BEFORE its repo, deliberately: a missing `substrate` means the
    # REPO guard's own `record skipped` would fail silently too. So the sandbox gets a stub, and
    # what this test observes is the REPO refusal rather than the recorder one.
    stub = tmp / ".local" / "bin" / "substrate"
    stub.parent.mkdir(parents=True)
    stub.write_text("#!/bin/sh\nexit 0\n", encoding="utf-8")
    stub.chmod(0o755)

    env = {**os.environ, "HOME": str(tmp)}
    r = sp.run([str(link)], env=env, capture_output=True, text=True)
    assert r.returncode == 1, f"an unresolvable REPO must exit non-zero, got {r.returncode}"
    log = (tmp / "Library" / "Logs" / "substrate-refresh.log").read_text("utf-8")
    assert "does not resolve to a substrate checkout" in log, log[-400:]
    # And it must not have composed anything into the guessed path.
    assert not (tmp / "out-vault").exists(), "the agent composed into a path it could not verify"


def test_agent_is_executable_and_derives_its_own_repo() -> None:
    """The move is only safe if the script still finds the repo. It used to carry an absolute path;
    now it derives one from its own location, and the shim in ~/.local/bin holds the machine fact."""
    import os

    assert os.access(_AGENT, os.X_OK), f"{_AGENT} is not executable"
    src = _AGENT.read_text("utf-8")
    assert 'REPO=$(cd "$(dirname "$0")/.." && pwd)' in src, "the agent must derive REPO"
    # WHOLE file. This was `src.split("REPO=")[0]`, which is only the comment header above the
    # derivation — it could not see a hardcoded path anywhere below it, which is exactly where the
    # machine-specific paths in this script actually live.
    assert "/Users/" not in src, (
        "the agent carries an absolute home path; it is meant to derive REPO and take everything "
        "else from $HOME, so that the repo copy is the portable one and the shim holds the "
        "machine-specific line")
    # The derivation is worthless unguarded — a symlink deployment resolves it to somewhere
    # writable and the agent composes six scopes into it, reporting success.
    assert "does not resolve to a substrate checkout" in src, "REPO is derived but not validated"


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
