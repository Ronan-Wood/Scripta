"""`refresh`: a client that has written notes asks the engine's loop for its next pass now.

A client attached to an engine it did not start writes notes and leaves the indexing to that
engine (plan §9.4), so it needs a way to say "now" without running a compose itself. The loop
coalesces requests and keeps a gap after each pass, so asking again and again brings passes forward
without running them back to back. Only a server with a loop (`substrate serve`) has the tool.
"""

from __future__ import annotations

import json
import sys
import threading
import time
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import refresh, stack  # noqa: E402
from substrate.mcp import server  # noqa: E402


class _Passes:
    """A stand-in `run_pass` that records when each pass starts, and can hold one open."""

    def __init__(self) -> None:
        self.started: list[float] = []
        self.hold = threading.Event()
        self.hold.set()
        self.running = threading.Event()

    def __call__(self, *_args, **_kwargs) -> list:
        self.started.append(time.monotonic())
        self.running.set()
        self.hold.wait(10)
        self.running.clear()
        return []


@pytest.fixture
def passes(monkeypatch) -> _Passes:
    stand_in = _Passes()
    monkeypatch.setattr(refresh, "run_pass", stand_in)
    return stand_in


def _until(condition, timeout: float = 5.0) -> bool:
    deadline = time.monotonic() + timeout
    while time.monotonic() < deadline:
        if condition():
            return True
        time.sleep(0.01)
    return condition()


def _loop(**kwargs) -> refresh.Loop:
    loop = refresh.Loop(None, every=1000.0, log=lambda _: None, **kwargs)
    loop.start()
    return loop


def _stop(loop: refresh.Loop) -> None:
    loop.stop.set()
    loop.join(5)
    assert not loop.is_alive()


def test_a_request_brings_the_next_pass_forward(passes) -> None:
    loop = _loop(gap=0.0)
    try:
        assert _until(lambda: len(passes.started) == 1 and not passes.running.is_set())
        assert loop.request()[0] == "now"
        assert _until(lambda: len(passes.started) == 2), "the requested pass never ran"
    finally:
        _stop(loop)


def test_requests_during_a_pass_coalesce_into_one_more(passes) -> None:
    passes.hold.clear()
    loop = _loop(gap=0.0)
    try:
        assert _until(passes.running.is_set)
        answers = {loop.request()[0] for _ in range(5)}
        assert answers == {"after_pass"}
        passes.hold.set()
        assert _until(lambda: len(passes.started) == 2)
        time.sleep(0.3)
        assert len(passes.started) == 2, "five requests ran more than one more pass"
    finally:
        passes.hold.set()
        _stop(loop)


def test_a_requested_pass_waits_out_the_gap(passes) -> None:
    loop = _loop(gap=0.5)
    try:
        assert _until(lambda: len(passes.started) == 1 and not passes.running.is_set())
        when, wait = loop.request()
        assert when == "after_gap" and 0 < wait <= 0.5, (when, wait)
        assert _until(lambda: len(passes.started) == 2)
        assert passes.started[1] - passes.started[0] >= 0.45
    finally:
        _stop(loop)


def test_stopping_wakes_the_loop_out_of_its_wait(passes) -> None:
    loop = _loop(gap=60.0)
    assert _until(lambda: len(passes.started) == 1 and not passes.running.is_set())
    loop.request()
    began = time.monotonic()
    _stop(loop)
    assert time.monotonic() - began < 2, "a stop waited out the request gap"


def _call(cfg: server.Config, method: str, **params) -> dict:
    return server.handle({"jsonrpc": "2.0", "id": 1, "method": method, "params": params}, cfg)


def _tool_names(cfg: server.Config) -> set[str]:
    return {t["name"] for t in _call(cfg, "tools/list")["result"]["tools"]}


def test_only_a_server_with_a_loop_has_the_tool(passes) -> None:
    plain = server.Config(None, None, read_only=True)
    assert "refresh" not in _tool_names(plain)
    unknown = _call(plain, "tools/call", name="refresh", arguments={})
    assert "unknown tool" in unknown["error"]["message"]

    serving = server.Config(None, None, read_only=True)
    serving.refresh_loop = refresh.Loop(None, every=1000.0, log=lambda _: None)
    assert "refresh" in _tool_names(serving)


def test_the_read_only_socket_runs_it_and_says_when(passes) -> None:
    """It writes no note, so the read-only transport serves it like any read."""
    cfg = server.Config(None, None, read_only=True)
    cfg.refresh_loop = refresh.Loop(None, every=1000.0, log=lambda _: None)
    reply = _call(cfg, "tools/call", name="refresh", arguments={})
    assert "isError" not in reply["result"], reply
    payload = json.loads(reply["result"]["content"][0]["text"])
    assert payload == {"next_pass": "now", "wait_seconds": 0.0}


def test_the_server_block_says_whether_it_takes_requests(passes, tmp_path) -> None:
    registry = tmp_path / "scopes.toml"
    registry.write_text("")
    for loop, says in ((None, False), (refresh.Loop(None, every=1000.0, log=lambda _: None), True)):
        cfg = server.Config(str(registry), stack.Stack(), read_only=True)
        cfg.refresh_loop = loop
        reply = _call(cfg, "tools/call", name="list_scopes", arguments={})
        assert json.loads(reply["result"]["content"][0]["text"])["server"]["refresh_requests"] is says
