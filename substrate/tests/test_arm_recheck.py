"""A downed arm is probed again while the server runs, instead of staying down until a restart.

`stack.build` decides availability once, and `main()` kept that verdict for the life of the
process. On 2026-10-30 Ollama answered the MCP server's startup probes with HTTP 500, and the server
stayed lexical-only for hours after the daemon recovered.

Runnable with plain `python tests/test_arm_recheck.py`; discovered by pytest.
"""

from __future__ import annotations

import argparse
import contextlib
import inspect
import io
import sys
import threading
from pathlib import Path
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import render, stack  # noqa: E402
from substrate.mcp import server  # noqa: E402
from substrate.retrieve import retriever  # noqa: E402

EMBEDDER_DOWN = "embedder 'e' unreachable at x"
HYDE_DOWN = "hyde 'h' unreachable at x"
RERANKER_DOWN = "reranker 'r' unreachable at x"


class _Arm:
    """A wired arm. The tests check identity: a kept arm is the same object, not a rebuilt one."""


class _Clock:
    def __init__(self) -> None:
        self.now = 0.0

    def __call__(self) -> float:
        return self.now


@contextlib.contextmanager
def _fake_build(result: stack.Stack, calls: list[dict]):
    real = stack.build

    def fake(**kwargs):
        calls.append(kwargs)
        return result

    stack.build = fake
    try:
        yield
    finally:
        stack.build = real


def _query(cfg: server.Config) -> stack.Stack:
    """What every tool call does first, and what may start a re-check."""
    return cfg.stack


def _finish(cfg: server.Config) -> None:
    t = cfg._rechecking
    if t is not None:
        t.join(5)
        assert not t.is_alive(), "re-check never finished"


def test_recheck_probes_only_the_arms_that_are_down() -> None:
    embedder, reranker = _Arm(), _Arm()
    current = stack.Stack(embedder=embedder, unavailable=(HYDE_DOWN, RERANKER_DOWN))
    calls: list[dict] = []
    with _fake_build(stack.Stack(reranker=reranker, unavailable=(HYDE_DOWN,)), calls):
        after = stack.recheck(current, embed_model="e", hyde_model="h", rerank_model="r",
                              cache_path="/nowhere")
    assert calls == [{"embed_model": None, "hyde_model": "h", "rerank_model": "r",
                      "cache_path": "/nowhere"}], calls
    assert after.embedder is embedder, "a wired arm was rebuilt"
    assert after.reranker is reranker
    assert after.expander is None
    assert after.wiring == {"embedder": "wired", "hyde": "unavailable", "reranker": "wired"}


def test_recheck_with_nothing_down_probes_nothing() -> None:
    current = stack.Stack(embedder=_Arm())
    calls: list[dict] = []
    with _fake_build(stack.Stack(), calls):
        assert stack.recheck(current, embed_model="e") is current
    assert calls == []


def test_recheck_never_wires_a_lexical_only_stack() -> None:
    current = stack.Stack(unavailable=(EMBEDDER_DOWN,))
    calls: list[dict] = []
    with _fake_build(stack.Stack(embedder=_Arm()), calls):
        assert stack.recheck(current, embed_model="e", lexical_only=True) is current
    assert calls == []


def test_a_read_after_the_interval_recovers_the_arm_without_waiting_on_it() -> None:
    clock, release = _Clock(), threading.Event()
    recovered = stack.Stack(embedder=_Arm())

    def recheck(current: stack.Stack) -> stack.Stack:
        release.wait(5)
        return recovered

    cfg = server.Config(None, stack.Stack(unavailable=(EMBEDDER_DOWN,)), recheck=recheck,
                        recheck_after=60, clock=clock)
    clock.now = 59
    _query(cfg)
    assert cfg._rechecking is None, "probed again before the interval"

    clock.now = 60
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        during = cfg.stack
        assert during.unavailable_arms == ("embedder",), "the read waited on the probe"
        assert cfg._rechecking is not None, "no re-check started"
        release.set()
        _finish(cfg)
    assert cfg.stack is recovered
    assert cfg.stack.wiring["embedder"] == "wired"
    assert "substrate-mcp: embedder recovered" in err.getvalue(), err.getvalue()


def test_one_recheck_at_a_time_and_the_interval_runs_from_its_end() -> None:
    """A daemon that accepts a connection and never answers makes every probe wait out its 30 s
    timeout, so one re-check of three arms outlasts a 60 s interval. Counted from its START, the
    next re-check would begin the moment it ended and the server would probe without pause."""
    clock, release = _Clock(), threading.Event()
    calls: list[int] = []

    def recheck(current: stack.Stack) -> stack.Stack:
        calls.append(1)
        release.wait(5)
        clock.now = 150     # the probe took 90 s
        return current

    cfg = server.Config(None, stack.Stack(unavailable=(EMBEDDER_DOWN, HYDE_DOWN)),
                        recheck=recheck, recheck_after=60, clock=clock)
    clock.now = 60
    _query(cfg)
    clock.now = 100
    _query(cfg)
    _query(cfg)
    release.set()
    _finish(cfg)
    assert calls == [1], "a second re-check started while one was in flight"

    clock.now = 150 + 59
    _query(cfg)
    assert cfg._rechecking is None, "probed again before an interval had passed since the last ended"
    clock.now = 150 + 60
    _query(cfg)
    assert cfg._rechecking is not None, "a still-down arm was never probed again"
    _finish(cfg)


def test_nothing_escaping_a_recheck_turns_rechecking_off() -> None:
    """Anything that escaped before the reset — a BaseException out of `build`, or the failure
    message raising because the host closed stderr — left `_rechecking` pointing at a dead thread,
    and the server never re-checked again: the bug this change fixes, reintroduced."""

    class _ClosedStderr(io.StringIO):
        def write(self, s: str) -> int:
            raise BrokenPipeError("stderr is gone")

    def exits(current: stack.Stack) -> stack.Stack:
        raise SystemExit(3)

    def fails(current: stack.Stack) -> stack.Stack:
        raise RuntimeError("daemon exploded")

    real_hook = threading.excepthook
    threading.excepthook = lambda args: None    # the escaping exception is the point; keep it quiet
    try:
        for recheck, stderr in ((exits, io.StringIO()), (fails, _ClosedStderr())):
            clock = _Clock()
            built = stack.Stack(unavailable=(EMBEDDER_DOWN,))
            cfg = server.Config(None, built, recheck=recheck, recheck_after=60, clock=clock)
            clock.now = 60
            with contextlib.redirect_stderr(stderr):
                _query(cfg)
                _finish(cfg)
            assert cfg._rechecking is None, f"{recheck.__name__}: re-checking left switched off"
            assert cfg.stack is built
            clock.now = 120
            _query(cfg)
            assert cfg._rechecking is not None, f"{recheck.__name__}: never re-checked again"
            _finish(cfg)
    finally:
        threading.excepthook = real_hook


def test_a_thread_that_will_not_start_does_not_fail_the_query() -> None:
    class _NoThread:
        def __init__(self, *a, **kw) -> None:
            pass

        def start(self) -> None:
            raise RuntimeError("can't start new thread")

    clock = _Clock()
    built = stack.Stack(unavailable=(EMBEDDER_DOWN,))
    cfg = server.Config(None, built, recheck=lambda current: current, recheck_after=60,
                        clock=clock)
    clock.now = 60
    real = server.threading.Thread
    server.threading.Thread = _NoThread
    try:
        with contextlib.redirect_stderr(io.StringIO()) as err:
            assert _query(cfg) is built, "the query was not served"
    finally:
        server.threading.Thread = real
    assert cfg._rechecking is None, "an unstarted thread was recorded as in flight"
    assert "could not start a re-check" in err.getvalue(), err.getvalue()
    clock.now = 119
    _query(cfg)
    assert cfg._rechecking is None, "a failed start was retried on the very next read"


def test_main_rebuilds_with_arguments_the_real_build_accepts() -> None:
    """Every other test here fakes `build`, which accepts anything. A renamed parameter would make
    each re-check raise TypeError, caught and printed once a minute while the arm stays down — and
    every test green."""
    parsed = argparse.Namespace(embed_model=stack.DEFAULT_EMBED, hyde_model=stack.DEFAULT_HYDE,
                                rerank_model=stack.DEFAULT_RERANK, cache="/nowhere",
                                lexical_only=False)
    args = server._build_args(parsed)
    inspect.signature(stack.build).bind(**args)
    inspect.signature(stack.recheck).bind(stack.Stack(), **args)


def test_a_search_reports_the_arms_it_ran_with_even_if_they_recover_mid_call() -> None:
    """The first query after an arm comes back starts the re-check, and the probe finishes long
    before retrieval does. A reply that re-read the stack afterwards described a recovered embedder
    over an answer retrieved without one: a healthy-looking envelope on a lexical-only result."""
    go = threading.Event()
    recovered = stack.Stack(embedder=_Arm())

    def recheck(current: stack.Stack) -> stack.Stack:
        go.wait(5)
        return recovered

    cfg = server.Config(None, stack.Stack(unavailable=(EMBEDDER_DOWN,)), recheck=recheck,
                        recheck_after=0)
    seen: dict = {}

    class _Store:
        def close(self) -> None:
            pass

    def fake_retrieve(store, query, **kw):
        seen["embedder"] = kw["embedder"]
        go.set()            # the recovery lands HERE: after retrieval took its arms,
        _finish(cfg)        # before the reply is rendered
        return "result"

    def fake_payload(result, **kw):
        return kw

    real = (server._open, retriever.retrieve, render.search_payload)
    server._open = lambda scope, registry: (
        SimpleNamespace(db="/nowhere.db"), _Store(), SimpleNamespace(withhold=(), reason=None))
    retriever.retrieve, render.search_payload = fake_retrieve, fake_payload
    try:
        with contextlib.redirect_stderr(io.StringIO()):
            reply = server._tool_search({"scope": "demo", "query": "q"}, cfg)
    finally:
        server._open, retriever.retrieve, render.search_payload = real

    assert cfg.stack is recovered, "the re-check never landed, so this tested nothing"
    assert seen["embedder"] is None
    assert reply["wiring"]["embedder"] == "unavailable", reply["wiring"]
    assert reply["unavailable"] == (EMBEDDER_DOWN,), reply["unavailable"]


def test_a_failed_recheck_keeps_the_stack_and_says_why() -> None:
    clock = _Clock()
    built = stack.Stack(unavailable=(EMBEDDER_DOWN,))

    def recheck(current: stack.Stack) -> stack.Stack:
        raise RuntimeError("daemon exploded")

    cfg = server.Config(None, built, recheck=recheck, recheck_after=60, clock=clock)
    clock.now = 60
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        _query(cfg)
        _finish(cfg)
    assert cfg.stack is built
    assert "re-checking unavailable arms failed: daemon exploded" in err.getvalue(), err.getvalue()


def test_a_healthy_stack_is_never_probed_again() -> None:
    clock = _Clock()

    def recheck(current: stack.Stack) -> stack.Stack:
        raise AssertionError("re-checked a stack with nothing down")

    cfg = server.Config(None, stack.Stack(embedder=_Arm()), recheck=recheck, clock=clock)
    clock.now = 10_000
    _query(cfg)
    assert cfg._rechecking is None


def test_a_config_without_recheck_keeps_the_stack_as_built() -> None:
    clock = _Clock()
    built = stack.Stack(unavailable=(EMBEDDER_DOWN,))
    cfg = server.Config(None, built, clock=clock)
    clock.now = 10_000
    assert cfg.stack is built
    assert cfg._rechecking is None


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
