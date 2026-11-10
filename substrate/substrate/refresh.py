"""Keeping every registered scope's index in step with its vault, run by the engine itself.

Until this existed the schedule lived in the app (`SubstrateRefresh.swift`): an index was refreshed
only while Scripta was open, and its one lock was an in-process flag, so a `compose` run from a
terminal was serialized against nothing. A week without opening the app was a week-old index
reading `frozen: false`, because nothing failed; nothing ran.

THE WORK IS THE COMMAND LINE'S, NOT A COPY OF IT. A pass runs `substrate compose` and `substrate
embed` as subprocesses, exactly as the app did, so every refusal compose makes is made the same way
here. Subprocesses also keep a compose that crashes, or holds a model stack for minutes, out of the
long-lived server that runs the loop.

THE OUTCOMES ARE THE APP'S, PORTED ONE BY ONE (`SubstrateRefresh.runPass`):

  * a compose that fails records `compose_failed`. That is the freeze, and recording it is the
    load-bearing rule: without it a scope keeps serving its last healthy verdict;
  * a compose that worked and an embed that did not records `embed_failed`. That is current
    content with no vectors, which is not a fully healthy pass;
  * both working records `refreshed`;
  * a compose that DECLINED, because another holds the vaults lock, records nothing. It did not
    run, and recording would overwrite a live verdict with the news that a duplicate stood down;
  * a registered scope whose row names no index root is frozen too (`compose_failed`), rather than
    composed into a guessed location. A compose must never move an index.

THE VAULTS LOCK (`vaults_lock`) is one `flock` beside the registry. `substrate compose` and
`substrate embed` take it at the CLI entry (`cli.main`), whoever runs them: this loop, the app, or
a terminal. An interactive caller waits for it (`DEFAULT_WAIT`). The loop's compose does not wait,
and declines, because the loop comes round again.
"""

from __future__ import annotations

import contextlib
import os
import signal
import subprocess
import sys
import threading
import time
from collections.abc import Callable, Iterator
from dataclasses import dataclass
from pathlib import Path

from substrate import prune, refresh_state, scopes

# The exit status of a compose or embed that did not run because another held the lock: BSD's
# EX_TEMPFAIL, "try again later". Distinct from every failure status, which the caller records.
EX_DECLINED = 75

LOCK_NAME = "vaults.lock"
# How long an interactive caller waits for the lock before declining. A pass over seven scopes takes
# seconds; a minute is long enough to wait out one and short enough to report a stuck holder.
DEFAULT_WAIT = 60.0
# The app's cadence, kept: chosen to match the vault sync, and a quiet pass costs a few seconds.
DEFAULT_EVERY = 900.0
# The least time between the end of one pass and the start of a REQUESTED one (`Loop.request`), so
# a client asking again and again brings passes forward without running them back to back.
REQUEST_GAP = 10.0
# How long the loop's embed waits for the lock. The compose it vectors has already run, so a
# decline here leaves a scope current but unvectored; it waits out anything short of a full
# re-embed by another caller.
EMBED_WAIT = 1800.0

# How much of a failing subprocess's stderr reaches the log. It names notes by path, so it is
# bounded rather than echoed whole.
_TAIL_LINES = 20

Say = Callable[[str], None]


def _stderr(line: str) -> None:
    print(line, file=sys.stderr)


class Declined(Exception):
    """The vaults lock is held by another compose, embed or refresh, past the wait allowed."""


def lock_path(registry: str | Path | None = None) -> Path:
    """Beside the registry, as the refresh state is (`refresh_state.state_path`), so a test or a
    second profile that points `$SUBSTRATE_REGISTRY` at a directory gets its own lock too. Raises
    `scopes.ScopeError` for a registry path that names nothing."""
    return scopes.registry_path(registry).parent / LOCK_NAME


@contextlib.contextmanager
def vaults_lock(registry: str | Path | None = None, *, wait: float = DEFAULT_WAIT) -> Iterator[None]:
    """Hold the vaults lock for the body. Waits up to `wait` seconds (0: not at all), then raises
    `Declined`. Built on `scopes.flocked`, the one lock helper."""
    path = lock_path(registry)
    path.parent.mkdir(parents=True, exist_ok=True)
    with contextlib.ExitStack() as held:
        # Only TAKING the lock turns into `Declined`; the body's own errors pass through as they are.
        try:
            held.enter_context(scopes.flocked(path, wait=wait))
        except scopes.LockBusy:
            raise Declined(f"{path} is held by another compose, embed or refresh"
                           + (f" and was not released within {wait:.0f}s" if wait > 0 else "")
                           ) from None
        yield


def record_and_publish(scope: str, outcome: str, registry: str | Path | None = None, *,
                       say: Say = _stderr) -> Path:
    """Record one scope's outcome, then republish its agent snapshot: what every refresh does per
    scope (`substrate refresh-record`, and the loop). Raises `refresh_state.RefreshStateError` when
    the outcome cannot be recorded.

    A snapshot that fails to publish is a WARNING, never a failure: the outcome is recorded and
    true, and a caller reading a non-zero exit as "could not record" would be told something false.
    The catch is broad for the same reason: a full disk or a missing shared folder must not turn a
    recorded refresh into a failed one."""
    path = refresh_state.record(scope, outcome, registry=registry)
    try:
        from substrate import agent

        line = agent.after_refresh_record(scope, outcome,
                                          registry=None if registry is None else str(registry))
    except Exception as e:  # noqa: BLE001 — see the docstring
        say(f"WARNING (agent snapshot {scope}): {type(e).__name__}: {e}")
    else:
        if line:
            say(f"  {line}")
    return path


@dataclass(frozen=True)
class ScopeResult:
    """One scope's part in a pass. `outcome` is what the pass found, or None when there was nothing
    to record because the compose declined. `recorded` is whether the outcome reached the refresh
    state. `detail` says why, for the log."""
    scope: str
    outcome: str | None
    detail: str = ""
    recorded: bool = False


Runner = Callable[[list[str], dict[str, str]], "subprocess.CompletedProcess[str]"]

# The children a pass is running now, so a server shutting down can end them rather than leave
# them composing with their output pipes closed (`terminate_children`). Once `_closing` is set no
# new child starts: one spawned after the shutdown took its snapshot would otherwise outlive it.
_children: set[subprocess.Popen] = set()
_children_lock = threading.Lock()
_closing = threading.Event()


def _run(argv: list[str], env: dict[str, str]) -> subprocess.CompletedProcess[str]:
    # The package root as the working directory, so `-m substrate.cli` resolves to THIS engine
    # whether it is a checkout, a deployment or the bundle.
    root = Path(__file__).resolve().parent.parent
    # Spawned and registered under the one lock `terminate_children` takes, so no child can start
    # between its snapshot and its signal.
    with _children_lock:
        if _closing.is_set():
            return subprocess.CompletedProcess(argv, -signal.SIGTERM, "", "the server is stopping")
        child = subprocess.Popen(argv, env=env, cwd=root, stdout=subprocess.PIPE,
                                 stderr=subprocess.PIPE, text=True)
        _children.add(child)
    try:
        out, err = child.communicate()
    finally:
        with _children_lock:
            _children.discard(child)
    return subprocess.CompletedProcess(argv, child.returncode, out, err)


def begin_closing() -> None:
    """From now on no child starts (`_run`), and an unfinished one counts as interrupted."""
    with _children_lock:
        _closing.set()


def end_closing() -> None:
    """Children may start again: the server that was stopping has stopped, and nothing it ran is
    still running."""
    with _children_lock:
        _closing.clear()


def terminate_children(grace: float = 10.0) -> None:
    """End every compose or embed a pass is running: TERM, then KILL after `grace` seconds. The
    lock a child holds is released by the kernel as it exits. No new child starts after this."""
    with _children_lock:
        _closing.set()
        live = list(_children)
    for child in live:
        child.terminate()
    for child in live:
        try:
            child.wait(grace)
        except subprocess.TimeoutExpired:
            child.kill()


def _joined(*parts: str) -> str:
    return "\n".join(p for p in parts if p)


def _tail(text: str) -> str:
    lines = [ln for ln in text.strip().splitlines() if ln.strip()]
    return "\n".join(lines[-_TAIL_LINES:])


def _interpreter_flags() -> list[str]:
    """This interpreter's flags (`-B -E -s` in the bundle), so a child runs the way its parent did
    and no `PYTHON*` variable the bundle shuts out reaches it. Not `-I` or `-P`: either keeps the
    working directory off `sys.path`, and `-m substrate.cli` resolves from it. `-I`'s isolation is
    kept as `-E -s`."""
    out: list[str] = []
    for flag in subprocess._args_from_interpreter_flags():
        if flag == "-I":
            out += ["-E", "-s"]
        elif flag != "-P":
            out.append(flag)
    return out


# How long a pass waits, after a child exits non-zero, to learn whether its server is stopping.
# Ctrl-C reaches the child and the server together, and the child can exit first.
_STOP_GRACE = 2.0


def _interrupted(proc: subprocess.CompletedProcess[str],
                 stopping: threading.Event | None) -> bool:
    """Whether a child that did not succeed was ended by its server stopping, which is not a
    failure: recording it would write a freeze for a healthy scope on every shutdown.

    A child that crashed (a signal of its own, an OOM kill) while the server runs on IS a failure,
    and is recorded as one: a scope that crashes every pass must freeze, not keep its last healthy
    verdict."""
    if proc.returncode == 0:
        return False
    if _closing.is_set():
        return True
    return stopping is not None and stopping.wait(_STOP_GRACE)


def run_pass(registry: str | Path | None = None, only: list[str] | None = None, *,
             runner: Runner = _run, log: Say | None = None,
             stopping: threading.Event | None = None) -> list[ScopeResult]:
    """Compose and embed every registered scope (or `only` those), and record each outcome.

    Raises `scopes.ScopeError` when the registry cannot be read, or `only` names a scope it does
    not hold, before anything runs: a pass that cannot do what it was asked says so first. Once
    `stopping` is set it starts no further scope, and records nothing for the one it was on."""
    say = log or _stderr
    # ABSOLUTE before it is handed on: the children run in the engine's root, and a relative path
    # would name another registry there, one every compose guard would then pass against.
    reg = scopes.registry_path(registry).absolute()
    entries = scopes.load(reg)
    unknown = [n for n in (only or []) if n not in entries]
    if unknown:
        raise scopes.ScopeError(f"not registered: {', '.join(unknown)}")
    names = list(only) if only else sorted(entries)
    env = {**os.environ, scopes.ENV_VAR: str(reg)}
    cli = [sys.executable, *_interpreter_flags(), "-m", "substrate.cli"]
    results: list[ScopeResult] = []
    for name in names:
        if stopping is not None and stopping.is_set():
            break
        entry = entries[name]
        if entry.index_root is None:
            result = ScopeResult(name, "compose_failed",
                                 "its registry row names no index root; compose it once by hand")
        else:
            # NO PATHS: compose reads where the registry has the vault when it runs, under the
            # vaults lock. Handed this pass's snapshot instead, a pass that started before another
            # compose moved a scope (the app's first-run rebuild) recomposed it where it had been.
            compose = runner([*cli, "compose", str(entry.vault), "--registry", str(reg),
                              "--no-wait"], env)
            if compose.returncode == EX_DECLINED:
                results.append(ScopeResult(name, None, "a compose was in flight"))
                say(f"substrate refresh: {name}: skipped, a compose was in flight")
                continue
            if _interrupted(compose, stopping):
                results.append(ScopeResult(name, None, "interrupted"))
                break
            # What compose pruned is said in the pass's report whatever the pass then records.
            pruned = "\n".join(ln.strip() for ln in (compose.stdout or "").splitlines()
                                if ln.strip().startswith(prune.PRUNED))
            if compose.returncode != 0:
                result = ScopeResult(name, "compose_failed", _joined(pruned, _tail(compose.stderr)))
            else:
                embed = runner([*cli, "embed", f"--scope={name}", "--registry", str(reg),
                                "--wait", str(EMBED_WAIT)], env)
                if _interrupted(embed, stopping):
                    results.append(ScopeResult(name, None, "interrupted"))
                    break
                result = (ScopeResult(name, "refreshed", pruned) if embed.returncode == 0
                          else ScopeResult(name, "embed_failed",
                                           _joined(pruned, _tail(embed.stderr))))
        results.append(_record(result, reg, say))
    return results


def _record(result: ScopeResult, registry: Path, say: Say) -> ScopeResult:
    try:
        record_and_publish(result.scope, result.outcome, registry, say=say)
    except refresh_state.RefreshStateError as e:
        # The recorder is the signal path: a pass whose verdict never lands leaves the scope
        # asserting its last healthy one, so this is said, and the pass reports it. The other
        # scopes still get their record: one unusable name must not cost them theirs.
        say(f"substrate refresh: {result.scope}: could not record {result.outcome}: {e}")
        return result
    line = f"substrate refresh: {result.scope}: {result.outcome}"
    say(line if not result.detail else f"{line}\n{result.detail}")
    return ScopeResult(result.scope, result.outcome, result.detail, recorded=True)


class _Stop(threading.Event):
    """`Loop.stop`: setting it also wakes the loop's wait, so a stop never waits out a request gap."""

    def __init__(self, wake: threading.Event) -> None:
        super().__init__()
        self._wake = wake

    def set(self) -> None:
        super().set()
        self._wake.set()


class Loop(threading.Thread):
    """A pass now, then one every `every` seconds, until `stop` is set or the process ends.

    SERIAL BY CONSTRUCTION: the wait comes after a pass, so a pass that overruns delays the next
    rather than stacking a second on top of it. A pass that raises is logged and the loop carries
    on, because one unreadable registry moment must not end refreshing for the server's life.

    `request()` brings the next pass forward, for a client that has just written notes for this
    engine to index. Requests COALESCE: however many arrive during a pass or a wait, one pass
    follows, and it starts no sooner than `REQUEST_GAP` after the last one ended, so no caller can
    make the loop run more often than that."""

    def __init__(self, registry: str | Path | None = None, *, every: float = DEFAULT_EVERY,
                 log: Say | None = None, gap: float = REQUEST_GAP,
                 clock: Callable[[], float] = time.monotonic, **pass_kwargs) -> None:
        super().__init__(name="substrate-refresh", daemon=True)
        self.registry = registry
        self.every = every
        self.gap = gap
        self._clock = clock
        self._wake = threading.Event()
        self.stop = _Stop(self._wake)
        self._say = log or _stderr
        self._pass_kwargs = pass_kwargs
        self._lock = threading.Lock()
        self._running = False
        self._ended: float | None = None

    def request(self) -> tuple[str, float]:
        """Bring the next pass forward. Returns when it starts: `("now", 0)`, `("after_pass", 0)`
        while one runs, or `("after_gap", seconds)` within `gap` of the last one's end."""
        with self._lock:
            running, ended = self._running, self._ended
            self._wake.set()
        if running:
            return "after_pass", 0.0
        wait = 0.0 if ended is None else max(0.0, ended + self.gap - self._clock())
        return ("after_gap", wait) if wait > 0 else ("now", 0.0)

    def _wait(self) -> None:
        """Until `every` has passed, or a request has and `gap` too, or `stop` is set."""
        deadline = self._clock() + self.every
        while not self.stop.is_set():
            left = deadline - self._clock()
            if left <= 0 or not self._wake.wait(left):
                return
            if self.stop.is_set():
                return
            with self._lock:
                self._wake.clear()
                ended = self._ended or self._clock()
            # A request: the pass it asks for, once the gap since the last one has passed.
            soonest = ended + self.gap - self._clock()
            if soonest <= 0 or not self.stop.wait(soonest):
                return

    def run(self) -> None:
        while not self.stop.is_set():
            with self._lock:
                self._running = True
                # A request made before this pass started is answered by it.
                self._wake.clear()
            try:
                run_pass(self.registry, log=self._say, stopping=self.stop, **self._pass_kwargs)
            except Exception as e:  # noqa: BLE001 — the loop outlives any single pass
                self._say(f"substrate refresh: the pass failed: {type(e).__name__}: {e}")
            finally:
                with self._lock:
                    self._running = False
                    self._ended = self._clock()
            self._wait()
