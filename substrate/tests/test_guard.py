"""A guarded vault refuses unless something vouches for it, right now.

EVERY TEST HERE IS A REFUSAL TEST except two. That ratio is the point: this is the wall that keeps a
model client out of the operator's call transcripts, and a wall is only worth what its failure modes
are worth. A guard that fell open on a missing file, an unparseable file, a `true` heartbeat or a
clock skew would be defeated by producing that condition — and a local process can produce all four.
"""

from __future__ import annotations

import json
import sys
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from substrate import guard  # noqa: E402


def _vault(tmp_path: Path, *, guard_state: str | None, name: str = "cbre") -> Path:
    vault = tmp_path / name
    vault.mkdir(parents=True, exist_ok=True)
    lines = [f'name = "{name}"', "inherits = []"]
    if guard_state is not None:
        lines.append(f'guard_state = "{guard_state}"')
    (vault / ".substrate.toml").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return vault


def _state(tmp_path: Path, **fields) -> Path:
    path = tmp_path / "mcp-state.json"
    path.write_text(json.dumps(fields), encoding="utf-8")
    return path


# --------------------------------------------------------------- the two that pass

def test_an_unguarded_vault_is_untouched(tmp_path: Path) -> None:
    """The operator's own vaults declare no guard and must not gain one. Absence of a declaration
    is not a failed check — if this ever refuses, every curated scope stops answering."""
    guard.check(_vault(tmp_path, guard_state=None), "cbre")


def test_a_fresh_beat_naming_this_scope_passes(tmp_path: Path) -> None:
    state = _state(tmp_path, heartbeat=time.time(), activeScope="cbre")
    guard.check(_vault(tmp_path, guard_state=str(state)), "cbre")


# --------------------------------------------------------------- everything else refuses

def test_a_missing_state_file_refuses(tmp_path: Path) -> None:
    """THE ONE A LOCAL PROCESS CAN ALWAYS ARRANGE. If deleting a file opened the vault, the wall
    would be decoration."""
    vault = _vault(tmp_path, guard_state=str(tmp_path / "nope.json"))
    with pytest.raises(guard.GuardError) as e:
        guard.check(vault, "cbre")
    # And it says the index is fine, so a refusal is not read as a broken corpus.
    assert "not reporting" in str(e.value)


def test_a_stale_beat_refuses(tmp_path: Path) -> None:
    state = _state(tmp_path, heartbeat=time.time() - (guard.STALE_AFTER_SECONDS + 5),
                   activeScope="cbre")
    with pytest.raises(guard.GuardError):
        guard.check(_vault(tmp_path, guard_state=str(state)), "cbre")


def test_a_beat_just_inside_the_window_still_passes(tmp_path: Path) -> None:
    """The boundary is asserted so a later tightening is a decision rather than a regression."""
    state = _state(tmp_path, heartbeat=time.time() - (guard.STALE_AFTER_SECONDS - 5),
                   activeScope="cbre")
    guard.check(_vault(tmp_path, guard_state=str(state)), "cbre")


def test_another_workspace_being_active_refuses(tmp_path: Path) -> None:
    """The partition, which is the whole feature: the app is running and vouching for a DIFFERENT
    corpus, so this one stays shut."""
    state = _state(tmp_path, heartbeat=time.time(), activeScope="personal")
    with pytest.raises(guard.GuardError) as e:
        guard.check(_vault(tmp_path, guard_state=str(state)), "cbre")
    assert "'personal'" in str(e.value)


def test_a_boolean_heartbeat_refuses(tmp_path: Path) -> None:
    """`True` is an `int` in Python, so an unguarded `isinstance(beat, (int, float))` would read it
    as 1 — an epoch in 1970, which is stale, so this one happens to fail safe. `False` is 0. Both
    are asserted because the guard must refuse them for being the wrong TYPE, not by luck."""
    for value in (True, False):
        state = _state(tmp_path, heartbeat=value, activeScope="cbre")
        with pytest.raises(guard.GuardError) as e:
            guard.check(_vault(tmp_path, guard_state=str(state)), "cbre")
        assert "numeric heartbeat" in str(e.value)


def test_a_future_beat_refuses(tmp_path: Path) -> None:
    """A clock this side cannot check is not a very fresh app."""
    state = _state(tmp_path, heartbeat=time.time() + 3600, activeScope="cbre")
    with pytest.raises(guard.GuardError):
        guard.check(_vault(tmp_path, guard_state=str(state)), "cbre")


def test_unparseable_or_wrongly_shaped_state_refuses(tmp_path: Path) -> None:
    path = tmp_path / "mcp-state.json"
    vault = _vault(tmp_path, guard_state=str(path))
    for body in ("not json", "[]", '"a string"', "null", "{}", '{"heartbeat": 1}'):
        path.write_text(body, encoding="utf-8")
        with pytest.raises(guard.GuardError):
            guard.check(vault, "cbre")


def test_a_missing_active_scope_refuses(tmp_path: Path) -> None:
    """Running but not saying which corpus it vouches for is not consent to all of them."""
    state = _state(tmp_path, heartbeat=time.time(), activeScope="")
    with pytest.raises(guard.GuardError) as e:
        guard.check(_vault(tmp_path, guard_state=str(state)), "cbre")
    assert "names no active scope" in str(e.value)


def test_an_oversized_state_file_refuses(tmp_path: Path) -> None:
    path = tmp_path / "mcp-state.json"
    path.write_text(" " * (guard._MAX_STATE_BYTES + 1), encoding="utf-8")
    with pytest.raises(guard.GuardError):
        guard.check(_vault(tmp_path, guard_state=str(path)), "cbre")


def test_a_guard_declared_as_a_non_string_refuses(tmp_path: Path) -> None:
    """A guard someone tried to write and got wrong is not an unguarded vault."""
    vault = tmp_path / "cbre"
    vault.mkdir()
    (vault / ".substrate.toml").write_text(
        'name = "cbre"\ninherits = []\nguard_state = true\n', encoding="utf-8")
    with pytest.raises(guard.GuardError):
        guard.check(vault, "cbre")


def test_an_unreadable_manifest_is_not_this_modules_error(tmp_path: Path) -> None:
    """Compose reports a malformed manifest in its own words; raising a GUARD error here would
    blame the wrong thing for it."""
    vault = tmp_path / "cbre"
    vault.mkdir()
    (vault / ".substrate.toml").write_text("this is not toml = = =", encoding="utf-8")
    assert guard.declared_guard(vault) is None
    guard.check(vault, "cbre")
