"""A vault whose own notes stay withheld unless something vouches for it, right now.

WHY THIS EXISTS. Most vaults are the operator's own notes and any process running as the operator
may read them — the trust model the loopback bind and `WRITE_TOOLS` already assume. But a vault can
hold content whose owner is a live application with a narrower idea of who should see it, and the
case that forced this is Scripta's: a workspace vault holds CALL TRANSCRIPTS, the app partitions
them by workspace, and the app's own MCP server refused to answer at all unless the app was running
and that workspace was active. Doc 4 §7 moved those calls into vaults the engine composes, which
quietly made them reachable by any local process — the wall was in the server being retired, not in
the corpus.

THE VAULT DECLARES ITS OWN GUARD; THE ENGINE KNOWS NOTHING ABOUT SCRIPTA. A manifest may carry:

    guard_state = "/abs/path/to/state.json"

and that file must read as `{"heartbeat": <epoch seconds>, "activeScope": "<scope>"}`, with a recent
beat naming the scope being asked for. Nothing here imports an app, hardcodes a path, or knows what
a "workspace" is: the guarded party writes both halves and the engine enforces the shape.

IT WITHHOLDS A VAULT, NOT A SCOPE, and that is the correction that matters. Refusing the whole scope
was measured and found too blunt — `cbre` composes a workspace vault that INHERITS the operator's
curated `cbre-vault` and the shared `core-vault`, so shutting it withheld 69 curated notes to
protect zero calls and made the operator's own notes unreadable everywhere else whenever the app was
closed. A wall that costs more than it guards is a wall people route around. The verdict names the
guarded vault's OWN documents; what it inherits was never the guarded party's to withhold.

FAIL CLOSED, ALWAYS. Every way of failing to read, parse or verify produces a withholding verdict —
never an open one. A guard that fell open when its state file was missing would be defeated by
deleting a file, which is the one thing a local process certainly can do. An unguarded vault (no
`guard_state`) is untouched: absence of a declaration is not a failed check.

THE MCP SERVER IS THE ONLY ENFORCEMENT POINT, deliberately. `compose`, `embed` and the refresh agent
are the operator's own machinery running as the operator; making them refuse because an app is
closed would break the background job that keeps the index current — the guard would take the corpus
down rather than protect it. What this gates is the surface a MODEL reaches.
"""

from __future__ import annotations

import json
import time
import tomllib
from dataclasses import dataclass
from pathlib import Path

# Three missed beats at the 20-second cadence the guarded app publishes on. Long enough that a
# stalled main thread does not lock the operator out mid-question; short enough that "the app is
# closed" is answered within a minute.
STALE_AFTER_SECONDS = 60

# The state file is a handshake, not a document. A larger one is a wrong file at that path.
MAX_STATE_BYTES = 64 * 1024

MANIFEST = ".substrate.toml"
GUARD_KEY = "guard_state"


@dataclass(frozen=True)
class Verdict:
    """What a scope may answer with right now.

    `withhold` is the set of vault names whose documents must not be returned — empty when nothing
    is guarded or the guard is satisfied. `reason` is the sentence a caller should see, and it is
    non-None exactly when something is withheld.
    """

    withhold: frozenset[str] = frozenset()
    reason: str | None = None

    @property
    def vouched(self) -> bool:
        return not self.withhold


OPEN = Verdict()


def declared_guard(vault_dir: Path) -> Path | None | str:
    """The state file this vault nominates, `None` when it nominates none, or a `str` DIAGNOSIS when
    the declaration itself is malformed.

    A manifest that cannot be read at all reads as "no guard" rather than as a broken one: an
    unreadable manifest is `vault.compose`'s error to report in its own words, and diagnosing it
    here would blame the guard for someone else's parse error. A manifest that parses and declares
    a non-string `guard_state` is different — that is a guard someone tried to write and got wrong,
    and it must not serve the vault unguarded.
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
        return (f"{path} declares {GUARD_KEY!r} but not as a path, so nothing can vouch for this "
                f"vault. Its own notes are withheld rather than served unguarded.")
    return Path(declared).expanduser()


def check(vault_dir: Path, scope: str, *, now: float | None = None) -> Verdict:
    """What `scope` may answer with.

    THE VAULT'S OWN NAME IS THE SCOPE NAME. A project vault's manifest `name` is what `compose`
    registers the scope as and what `documents.vault` records for the notes it contributed — so
    withholding `{scope}` is exactly "this vault's own content, not what it inherits".
    """
    declared = declared_guard(vault_dir)
    if declared is None:
        return OPEN
    if isinstance(declared, str):
        return _withhold(scope, declared)

    try:
        raw = declared.read_bytes()
    except OSError:
        return _withhold(scope,
                         f"the application that vouches for {scope!r} is not reporting, so this "
                         f"vault's own notes are withheld. Open it and select this workspace. "
                         f"Nothing is wrong with the index, and everything this scope INHERITS "
                         f"still answered.")
    if len(raw) > MAX_STATE_BYTES:
        return _withhold(scope, f"the guard state for {scope!r} is implausibly large to be a "
                                f"handshake; withholding this vault's own notes.")
    try:
        state = json.loads(raw)
    except ValueError:
        return _withhold(scope, f"the guard state for {scope!r} is not readable JSON; withholding "
                                f"this vault's own notes.")
    if not isinstance(state, dict):
        return _withhold(scope, f"the guard state for {scope!r} is not an object; withholding this "
                                f"vault's own notes.")

    beat = state.get("heartbeat")
    # `bool` is an `int` in Python; a `True` heartbeat would otherwise arithmetic to 1 and read as
    # an epoch in 1970 — stale, so it would happen to fail safe. It must fail for being the wrong
    # TYPE rather than by luck.
    if isinstance(beat, bool) or not isinstance(beat, (int, float)):
        return _withhold(scope, f"the guard state for {scope!r} carries no numeric heartbeat; "
                                f"withholding this vault's own notes.")

    age = (time.time() if now is None else now) - float(beat)
    if age > STALE_AFTER_SECONDS:
        return _withhold(scope,
                         f"the application that vouches for {scope!r} last reported {int(age)}s "
                         f"ago, longer than the {STALE_AFTER_SECONDS}s this guard allows, so this "
                         f"vault's own notes are withheld. The wall cannot be one process-death "
                         f"deep.")
    # A beat from the future is a clock this side cannot reason about, not a very fresh app.
    if age < -STALE_AFTER_SECONDS:
        return _withhold(scope,
                         f"the guard state for {scope!r} reports a heartbeat {int(-age)}s in the "
                         f"future; withholding this vault's own notes rather than trusting a clock "
                         f"this side cannot check.")

    active = state.get("activeScope")
    if not isinstance(active, str) or not active:
        return _withhold(scope,
                         f"the application vouching for {scope!r} is running but has not said "
                         f"which corpus it is vouching for, so this vault's own notes are "
                         f"withheld.")
    if active != scope:
        return _withhold(scope,
                         f"the application is currently vouching for {active!r}, not {scope!r}, so "
                         f"{scope!r}'s own notes are withheld. Select it there and ask again — one "
                         f"partition answers at a time, which is what the guard is for.")
    return OPEN


def _withhold(scope: str, reason: str) -> Verdict:
    return Verdict(frozenset({scope}), reason)
