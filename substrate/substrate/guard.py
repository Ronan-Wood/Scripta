"""A vault that will not answer unless something vouches for it, right now.

WHY THIS EXISTS. Most vaults are the operator's own notes and any process running as the operator
may read them — that is the trust model the loopback bind and `WRITE_TOOLS` already assume. But a
vault can hold content whose owner is a live application with a narrower idea of who should see it,
and the case that forced this is Scripta's: a workspace vault holds CALL TRANSCRIPTS, the app
partitions them by workspace, and the app's own MCP server refused to answer at all unless the app
was running and the workspace was the active one. Doc 4 §7 moved those calls into vaults the engine
composes, which quietly made them reachable by any local process — the wall was in the server being
retired, not in the corpus.

THE VAULT DECLARES ITS OWN GUARD; THE ENGINE KNOWS NOTHING ABOUT SCRIPTA. A manifest may carry:

    guard_state = "/abs/path/to/state.json"

and that file must exist and read as `{"heartbeat": <epoch seconds>, "activeScope": "<scope>"}`.
The engine requires the heartbeat to be recent and `activeScope` to name the scope being asked for.
Nothing here imports an app, hardcodes a path, or knows what a "workspace" is — the guarded party
writes the manifest and writes the file, and the engine only enforces the shape.

FAIL CLOSED, ALWAYS. Every failure to read, parse, or verify is a refusal: a guard that fell open
when its state file was missing would be defeated by deleting a file, which is the one attack a
local process certainly can perform. An unguarded vault (no `guard_state`) is unaffected — absence
of a declaration is not a failed check.

THE MCP SERVER IS THE ONLY ENFORCEMENT POINT, and deliberately so. `compose`, `embed` and the
refresh agent are the operator's own machinery running as the operator; making them refuse because
an app is closed would break the background job that keeps the index current — the guard would take
the corpus down rather than protect it. What this gates is the surface a MODEL reaches.
"""

from __future__ import annotations

import json
import time
import tomllib
from pathlib import Path

# Three missed beats at the 20-second cadence the guarded app publishes on. Long enough that a
# stalled main thread does not lock the operator out mid-question; short enough that "the app is
# closed" is answered within a minute.
STALE_AFTER_SECONDS = 60

# The state file is a handshake, not a document. A larger one is a wrong file at that path.
_MAX_STATE_BYTES = 64 * 1024

MANIFEST = ".substrate.toml"
GUARD_KEY = "guard_state"


class GuardError(RuntimeError):
    """A guarded vault would not be vouched for. The message is shown to the caller."""


def declared_guard(vault_dir: Path) -> Path | None:
    """The state file this vault nominates, or None when it nominates none.

    A manifest that cannot be read at all returns None rather than raising: an unreadable manifest
    is `vault.compose`'s error to report, in its own words, and raising a GUARD error for it would
    blame the wrong thing. A manifest that parses and declares a non-string `guard_state` is a
    different matter — that is a guard someone tried to write and got wrong, and it refuses below.
    """
    path = vault_dir / MANIFEST
    try:
        manifest = tomllib.loads(path.read_text(encoding="utf-8"))
    except (OSError, UnicodeDecodeError, tomllib.TOMLDecodeError):
        return None
    declared = manifest.get(GUARD_KEY)
    if declared is None:
        return None
    if not isinstance(declared, str) or not declared.strip():
        raise GuardError(
            f"{path} declares {GUARD_KEY!r} but not as a path. A guarded vault that cannot name its "
            f"guard is refused rather than served unguarded."
        )
    return Path(declared).expanduser()


def check(vault_dir: Path, scope: str, *, now: float | None = None) -> None:
    """Refuse unless this vault's declared guard vouches for `scope` right now. No-op when the
    vault declares no guard."""
    state_path = declared_guard(vault_dir)
    if state_path is None:
        return

    try:
        raw = state_path.read_bytes()
    except OSError:
        raise GuardError(
            f"the scope {scope!r} is guarded, and the application that vouches for it "
            f"({state_path}) is not reporting. Open it and select this workspace. Nothing is wrong "
            f"with the index — this scope is withheld on purpose while nothing is vouching for it."
        ) from None
    if len(raw) > _MAX_STATE_BYTES:
        raise GuardError(f"the guard state at {state_path} is implausibly large; refusing {scope!r}.")

    try:
        state = json.loads(raw)
    except ValueError:
        raise GuardError(f"the guard state at {state_path} is not readable JSON; refusing {scope!r}.")
    if not isinstance(state, dict):
        raise GuardError(f"the guard state at {state_path} is not an object; refusing {scope!r}.")

    beat = state.get("heartbeat")
    # `bool` is an `int`; a `True` heartbeat would otherwise arithmetic to 1 and read as 1970.
    if isinstance(beat, bool) or not isinstance(beat, (int, float)):
        raise GuardError(
            f"the guard state at {state_path} carries no numeric heartbeat; refusing {scope!r}."
        )
    age = (time.time() if now is None else now) - float(beat)
    if age > STALE_AFTER_SECONDS:
        raise GuardError(
            f"the scope {scope!r} is guarded and its application last reported "
            f"{int(age)}s ago, which is longer than the {STALE_AFTER_SECONDS}s this guard allows. "
            f"Open it and select this workspace. The wall cannot be one process-death deep."
        )
    # A beat from the future is a clock that cannot be reasoned about, not a very fresh app.
    if age < -STALE_AFTER_SECONDS:
        raise GuardError(
            f"the guard state at {state_path} reports a heartbeat {int(-age)}s in the future; "
            f"refusing {scope!r} rather than trusting a clock this side cannot check."
        )

    active = state.get("activeScope")
    if not isinstance(active, str) or not active:
        raise GuardError(
            f"the guard state at {state_path} names no active scope; refusing {scope!r}. The "
            f"application is running but has not said which corpus it is vouching for."
        )
    if active != scope:
        raise GuardError(
            f"the scope {scope!r} is guarded, and its application is currently vouching for "
            f"{active!r} instead. Select {scope!r} there and ask again — one partition answers at a "
            f"time, which is what the guard is for."
        )
