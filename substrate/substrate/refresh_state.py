"""What the unattended refresh agent last did to a scope — the field the query envelope lacked.

PRINCIPLES.md is exact about the gap this closes. `index_version` "surfaces staleness; does not
solve it", and `freshness.drift()` answers the real question — has the vault moved? — but it is a
stat-and-hash sweep over every note in the scope, far too expensive to run per query. So the
envelope carried `index_version` and nothing else, and the failure mode was the one the Boundary
Principle names:

    compose refuses -> the refresh agent logs the failure and moves on -> the OLD index stays ->
    every query keeps answering from it, in an envelope BYTE-IDENTICAL to a healthy run.

A frozen scope and a current one were indistinguishable at the point of use. Worse than before the
agent existed: it converted MANUAL freshness into ASSUMED freshness without adding a signal, so
nobody checked any more.

This module is the signal. The agent records its per-scope outcome here; `render` and `introspect`
read it and put it on the output. One small JSON file, one lookup — O(1), no sweep — so the cost is
compatible with running on every response, which is the only place it does any good.

**It reports the AGENT, not the vault.** That distinction is the whole honesty of the field. A
`refreshed` outcome means the agent recomposed successfully at that timestamp; it does not mean the
vault has not moved in the seconds since, and it is not a substitute for `drift`. Naming it
`refresh` rather than `freshness` is deliberate — a field called freshness that reported an agent's
exit status would be the sixth occurrence of the incident this file exists to prevent.

**Absence is a state, and it is not the healthy one.** A scope nobody has recorded reports
`known: false` with `frozen: null` — no basis for a verdict — never `frozen: false`.
"""

from __future__ import annotations

import json
import os
import stat
import tempfile
from datetime import UTC, datetime
from pathlib import Path

from substrate.scopes import exclusive, registry_path
from substrate.render import REF_SEP

STATE_FILENAME = "refresh.json"
VERSION = 1

# The record holds one small row per scope — seven of them, ~150 bytes each. Bounded anyway,
# because this file is parsed on the QUERY path: every search pays for it, and an unbounded
# `json.loads` there turns one bad file into a per-request cost. Same discipline the MCP server
# applies to a caller-named source, applied to our own state for the same reason.
MAX_STATE_BYTES = 1 << 20

# A recorded timestamp is echoed into the result envelope, which the MCP tool description tells a
# model to read as ENGINE-AUTHORED operational guidance — a better injection position than a
# passage, which at least arrives with a citation. So a value that is not a plausible timestamp is
# dropped rather than forwarded. An ISO-8601 stamp is ~25 characters.
MAX_STAMP_CHARS = 64

# The outcome vocabulary, and what each one licenses a consumer to conclude. ONE table: the CLI's
# argparse `choices`, the writer's success rule and the reader's verdict all read it, so the agent
# cannot record an outcome the reader has no interpretation for.
#
# `frozen` is TRI-STATE and each value is a different claim:
#   True  — the index demonstrably disagrees with the vault: the agent saw drift, tried to rebuild,
#           and the rebuild refused. Queries are answering from superseded content.
#   False — the agent's last pass left index and vault in agreement.
#   None  — no basis. The agent did not get far enough to form a view, so a verdict either way
#           would be invented. `skipped` is here rather than under False for exactly that reason:
#           nothing was checked, and "nothing was checked" is not "nothing is wrong".
#
# `success` decides whether an attempt advances `succeeded`. It is NOT `not frozen`: an embed
# failure leaves current CONTENT with no vectors, so the index agrees with the vault (not frozen)
# while the pass plainly did not succeed.
OUTCOMES: dict[str, dict] = {
    "unchanged": {
        "success": True, "frozen": False, "note": None,
    },
    "refreshed": {
        "success": True, "frozen": False, "note": None,
    },
    "compose_failed": {
        "success": False, "frozen": True,
        "note": ("FROZEN — the vault changed and the last recompose REFUSED, so these results "
                 "come from the index built before that change. Run `substrate compose` for this "
                 "scope and read the refusal; the refresh agent's log has the failing run."),
    },
    "embed_failed": {
        "success": False, "frozen": False,
        "note": ("the last refresh recomposed but could not embed, so this scope may be 0-vector "
                 "and answering lexically. `retrieval_mode` reports what actually ran; "
                 "`substrate status` reports vector coverage."),
    },
    "skipped": {
        "success": False, "frozen": None,
        "note": ("the last refresh tick made no attempt on this scope (typically the embedding "
                 "daemon was unreachable), so nothing has verified the index against the vault "
                 "since `succeeded`."),
    },
}

_UNKNOWN_NOTE = (
    "no refresh agent has reported on this scope, so nothing here says whether the index still "
    "matches the vault. `substrate status --scope <name>` computes it directly."
)
_NO_SCOPE_NOTE = (
    "this query addressed an index by path rather than by scope name, so there is no scope to "
    "look up a refresh record for."
)


class RefreshStateError(RuntimeError):
    """The state file cannot be written."""


def state_path(registry: str | Path | None = None) -> Path:
    """Beside the registry, always. The two are one kind of thing — machine-local, disposable,
    rebuilt by running `compose` again — and deriving this path from the registry's is what lets a
    test (or a second machine profile) point `$SUBSTRATE_REGISTRY` at a directory and get BOTH
    files there. A separate rule would have a test recording into the operator's real state."""
    return registry_path(registry).parent / STATE_FILENAME


def _read_bounded(path: Path) -> bytes:
    """The state file, size-capped at the read itself. Raises OSError, which `_load` converts.

    Bounded because this is parsed on the query path — once per search — so an oversized file is a
    per-request cost, not a one-off. Opened once and fstat'd on the DESCRIPTOR so a non-regular
    file (a FIFO left where the record should be) cannot block the open forever.
    """
    fd = os.open(path, os.O_RDONLY | os.O_NONBLOCK)
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise OSError(f"{path} is not a regular file")
        data = os.read(fd, MAX_STATE_BYTES + 1)
        if len(data) > MAX_STATE_BYTES:
            raise OSError(f"{path} exceeds {MAX_STATE_BYTES} bytes")
        return data
    finally:
        os.close(fd)


def _load(path: Path) -> tuple[dict, str | None]:
    """Every recorded scope, plus the reason it could not be read.

    Returns `({}, reason)` rather than raising, and the reason is carried to the caller instead of
    dropped. A corrupt state file must not refuse queries — the index is fine, only the report
    about it is unreadable — but reporting `known: false` over a file that exists and is broken
    would be this project's own failure shape: the consumer would read "nobody has recorded this"
    where the truth is "the record is unreadable".

    The catch is DELIBERATELY broad. Converting any unreadable state into `({}, reason)` is this
    function's entire contract, and an enumerated tuple kept letting the contract break: 800KB of
    nested brackets raises `RecursionError` from `json.loads`, which is neither an OSError nor a
    JSONDecodeError, and it escaped straight through the query path. A guard that has to predict
    every way a parser can fail is a guard that will be wrong again.

    The reason names the path but NOT the exception text. The path is already disclosed by
    `status` and `list_scopes` so it is nothing new; an arbitrary OS error string is, and it would
    reach a model on the query path — the same disclosure `mcp/server._read_source` refuses one
    file over, on the grounds that it answers "does this path exist and can you read it".
    """
    if not path.is_file():
        return {}, None
    try:
        data = json.loads(_read_bounded(path).decode("utf-8"))
    except Exception as e:  # noqa: BLE001 — see the docstring: breadth IS the contract here
        return {}, f"the refresh record at {path} could not be read ({type(e).__name__})"
    if not isinstance(data, dict) or not isinstance(data.get("scopes"), dict):
        return {}, f"the refresh record at {path} is not in the expected shape"
    return {k: v for k, v in data["scopes"].items() if isinstance(v, dict)}, None


def _stamp(value: object) -> str | None:
    """A recorded timestamp, or nothing. Shape-checked because this value is COPIED INTO THE
    RESULT ENVELOPE, and the MCP tool description tells a model to read that block as the engine's
    own account of whether the answer can be trusted — a better place to land text than a passage,
    which at least arrives with a citation. Anything that is not a short string is dropped rather
    than forwarded, exactly as the reader drops a malformed `source_sha256` instead of carrying a
    pointer that cannot identify what it names."""
    return value if isinstance(value, str) and len(value) <= MAX_STAMP_CHARS else None


def report(scope: str | None, registry: str | Path | None = None) -> dict:
    """The block that rides on a result envelope. Never raises: a broken record degrades to
    `known: false` WITH the reason, because a report about the index must not be able to stop the
    index answering.

    Every key is present in every state, `null` included. A block that shrank when it had nothing
    to say would make its own absence the ambiguous case, which is the defect the spine fields are
    emitted unconditionally to avoid.
    """
    if not scope:
        return _block(known=False, note=_NO_SCOPE_NOTE)

    entries, unreadable = _load(state_path(registry))
    if unreadable:
        return _block(known=False, note=unreadable)

    row = entries.get(scope)
    if row is None:
        return _block(known=False, note=_UNKNOWN_NOTE)

    # The isinstance check comes BEFORE the lookup, not after. `OUTCOMES.get(outcome)` HASHES its
    # argument, so a row whose `outcome` is a JSON list or object raised TypeError straight out of
    # a function documented "never raises" — taking every search and status on that scope down
    # over one bad line, which is strictly worse than the freeze this module exists to warn about.
    # The guard existed; it sat one step too late to fire on the only input it was written for.
    outcome = row.get("outcome") if isinstance(row.get("outcome"), str) else None
    verdict = OUTCOMES.get(outcome)
    attempted, succeeded = _stamp(row.get("attempted")), _stamp(row.get("succeeded"))
    # A freeze OUTLIVES the pass that found it, and is cleared only by a pass that positively
    # disproves it. Without this, one `skipped` tick — which the producer writes for every scope
    # whenever the embedding daemon is unreachable, the single most anticipated failure here —
    # downgraded `frozen: true` to `frozen: null` and the human read-out dropped its banner. The
    # module already argued the symmetric case for `succeeded` ("a failing pass does not unmake the
    # last good one"); a pass that checked NOTHING does not unmake the last known failure either.
    since = _stamp(row.get("frozen_since"))

    if verdict is None:
        # Recorded by a NEWER agent than this code knows, or hand-edited. The timestamps are still
        # usable and are handed over; the verdict is not invented from a word this build cannot
        # interpret — except for a carried freeze, which was established by an outcome this build
        # DID understand and is not in doubt just because the latest word is unfamiliar.
        return _block(
            known=True, outcome=outcome, attempted=attempted, succeeded=succeeded,
            frozen=True if since else None, frozen_since=since,
            note=(_carried_freeze_note(outcome, since) if since else
                  f"the refresh agent recorded outcome {outcome!r}, which this build has no "
                  f"interpretation for — it is newer than this engine, or hand-edited."),
        )
    if since and verdict["frozen"] is not True:
        # Frozen earlier, and the latest pass neither confirmed nor cleared it.
        return _block(known=True, outcome=outcome, attempted=attempted, succeeded=succeeded,
                      frozen=True, frozen_since=since, note=_carried_freeze_note(outcome, since))
    return _block(
        known=True, outcome=outcome, attempted=attempted, succeeded=succeeded,
        frozen=verdict["frozen"], frozen_since=since, note=verdict["note"],
    )


def _carried_freeze_note(outcome: str | None, since: str | None) -> str:
    return (
        f"FROZEN — a recompose refused at {since} and nothing has succeeded since. The most "
        f"recent pass ({outcome or 'unrecognised'}) did not re-check, so this verdict is carried "
        f"forward rather than re-confirmed. These results come from the index built before the "
        f"vault changed."
    )


def _block(*, known: bool, outcome: str | None = None, attempted: str | None = None,
           succeeded: str | None = None, frozen: bool | None = None,
           frozen_since: str | None = None, note: str | None = None) -> dict:
    """One key set for every state — see `report`."""
    return {
        "known": known,
        "outcome": outcome,
        # When the agent last LOOKED at this scope, and when it last left it verified. They differ
        # exactly when something has been going wrong since `succeeded`, which is the interval a
        # reader needs and which neither timestamp alone expresses.
        "attempted": attempted,
        "succeeded": succeeded,
        "frozen": frozen,
        # When the freeze STARTED, as a field rather than a sentence inside `note`. How long a
        # scope has been answering from superseded content is the question a reader has the moment
        # `frozen` is true, and prose is what gets paraphrased away by whoever passes this on.
        "frozen_since": frozen_since,
        "note": note,
    }


def record(scope: str, outcome: str, *, registry: str | Path | None = None,
           now: str | None = None) -> Path:
    """Write one scope's outcome. Returns the state file written.

    Locked and atomically replaced for the same two reasons `scopes.record` is: the lock stops two
    passes each writing a full snapshot where the second drops the first's scopes, and the atomic
    replace stops a crash leaving a truncated file that every later read reports as unreadable —
    which would silently disarm the very signal this module exists to raise.
    """
    if outcome not in OUTCOMES:
        raise RefreshStateError(
            f"unknown outcome {outcome!r}; expected one of {sorted(OUTCOMES)}. An outcome the "
            f"reader cannot interpret is a record that reports nothing."
        )
    # The SAME rule the registry applies (`scopes.record`), because these two files are keyed by
    # the same name. A scope carrying the ref separator cannot be registered, so a record written
    # under one is unreadable forever: the recorder exits 0, the agent logs nothing, and the scope
    # reports `known: false` for good — a record that reports nothing, which is exactly what the
    # outcome check above refuses one line earlier.
    if not scope or scope.strip() != scope or REF_SEP in scope or len(scope) > 128:
        raise RefreshStateError(
            f"scope name {scope!r} is unusable as a record key: it must be non-empty, at most 128 "
            f"characters, carry no {REF_SEP!r}, and have no leading or trailing whitespace."
        )

    path = state_path(registry)
    stamp = now or datetime.now(UTC).isoformat(timespec="seconds")

    # EVERY filesystem operation is inside the conversion, not just the write. `mkdir`, the lock's
    # own `open`, and `mkstemp` each raise bare OSError, and `cmd_refresh_record` catches only
    # RefreshStateError — so a read-only home or a full disk aborted the whole batch on the first
    # scope with a traceback, defeating the per-scope loop written so one bad name could not cost
    # the other six their record. ENOSPC is the realistic trigger, and it is also a condition that
    # makes `compose` fail: the tick where these records matter most is the one that dropped them.
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with exclusive(path):
            entries, _ = _load(path)
            prior = entries.get(scope) or {}
            v = OUTCOMES[outcome]
            # `succeeded` is CARRIED FORWARD on a failure, never cleared. A failing pass does not
            # unmake the last good one, and the gap between the two timestamps is the measurement a
            # reader actually wants: how long this scope has been going wrong.
            succeeded = stamp if v["success"] else _stamp(prior.get("succeeded"))
            # `frozen_since` keeps the ORIGINAL timestamp across repeated failures — it answers
            # "since when", so re-stamping it every tick would reset the answer to "just now" and
            # make a week-old freeze look fresh. Cleared only by an outcome that positively
            # disproves it (`frozen is False`), which is every outcome implying compose SUCCEEDED.
            if v["frozen"] is True:
                frozen_since = _stamp(prior.get("frozen_since")) or stamp
            elif v["frozen"] is False:
                frozen_since = None
            else:
                frozen_since = _stamp(prior.get("frozen_since"))
            entries[scope] = {"attempted": stamp, "outcome": outcome, "succeeded": succeeded,
                              "frozen_since": frozen_since}
            body = json.dumps(
                {"version": VERSION, "scopes": dict(sorted(entries.items()))},
                indent=2, ensure_ascii=False,
            ) + "\n"

            fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".refresh-",
                                            suffix=".json")
            try:
                with os.fdopen(fd, "w", encoding="utf-8") as fh:
                    fh.write(body)
                os.replace(tmp_name, path)
            except OSError:
                Path(tmp_name).unlink(missing_ok=True)
                raise
    except OSError as e:
        raise RefreshStateError(f"cannot write {path}: {e}") from e
    return path
