"""The engine says which model its HyDE Auto picked, so no client keeps a copy of the rule.

The app drew "Auto (<model>)" in Settings from its own copy of `expand.pick_auto`
(`ModelResolver.best(for: .search)`), run against the Settings server's catalog. Two copies of a
rule drift, and the copy answered for the wrong machine whenever the engine's Ollama was not the
one Settings pointed at. The engine now reports what HyDE was asked for and what it resolved to,
on `list_scopes`, the call every client already makes. These fail on an engine that did not.

Runnable with `python tests/test_hyde_reported.py` or under pytest.
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import introspect, stack  # noqa: E402
from substrate.mcp import server  # noqa: E402
from substrate.retrieve import expand  # noqa: E402
from substrate.retrieve.expand import HyDE  # noqa: E402

NO_OTHER_ARMS = {"embed_model": None, "rerank_model": None}


def test_auto_reports_what_it_resolved_to() -> None:
    with tempfile.TemporaryDirectory() as tmp, \
            mock.patch.object(expand, "resolve_auto", return_value="qwen3.5:4b-mlx"), \
            mock.patch.object(HyDE, "available", return_value=True):
        st = stack.build(hyde_model=stack.HYDE_AUTO, cache_path=str(Path(tmp) / "c.db"),
                         **NO_OTHER_ARMS)
    arms = introspect.arms(st)
    assert (arms["hyde_requested"], arms["hyde"]) == ("auto", "qwen3.5:4b-mlx"), arms


def test_auto_with_nothing_to_pick_reports_the_request_and_no_model() -> None:
    with tempfile.TemporaryDirectory() as tmp, \
            mock.patch.object(expand, "resolve_auto", return_value=None):
        st = stack.build(hyde_model=stack.HYDE_AUTO, cache_path=str(Path(tmp) / "c.db"),
                         **NO_OTHER_ARMS)
    arms = introspect.arms(st)
    assert (arms["hyde_requested"], arms["hyde"]) == ("auto", None), arms


def test_a_recheck_of_another_arm_keeps_what_hyde_was_asked_for() -> None:
    """With HyDE up and the embedder down, the re-check rebuilds only the embedder and asks HyDE for
    nothing. Taking the request from that rebuild would make a working Auto engine report Off."""
    from substrate.embed.engine import OllamaEmbedder

    with tempfile.TemporaryDirectory() as tmp:
        kwargs = {"embed_model": "qwen3-embedding:0.6b", "hyde_model": stack.HYDE_AUTO,
                  "rerank_model": None, "cache_path": str(Path(tmp) / "c.db")}
        with mock.patch.object(expand, "resolve_auto", return_value="qwen3.5:4b-mlx"), \
                mock.patch.object(HyDE, "available", return_value=True), \
                mock.patch.object(OllamaEmbedder, "available", return_value=False):
            first = stack.build(**kwargs)
            assert first.unavailable_arms == ("embedder",), first.unavailable
            after = stack.recheck(first, **kwargs)
    arms = introspect.arms(after)
    assert (arms["hyde_requested"], arms["hyde"]) == ("auto", "qwen3.5:4b-mlx"), arms


def test_off_and_a_named_pick_are_reported_as_asked() -> None:
    for nothing in (stack.HYDE_OFF, ""):
        off = stack.build(hyde_model=nothing, **NO_OTHER_ARMS)
        assert introspect.arms(off)["hyde_requested"] is None, nothing
    with tempfile.TemporaryDirectory() as tmp, \
            mock.patch.object(HyDE, "available", return_value=True):
        named = stack.build(hyde_model="mistral:7b", cache_path=str(Path(tmp) / "c.db"),
                            **NO_OTHER_ARMS)
    assert introspect.arms(named)["hyde_requested"] == "mistral:7b"


def test_a_lexical_only_engine_still_says_what_hyde_was_asked_for() -> None:
    st = stack.build(hyde_model=stack.HYDE_AUTO, lexical_only=True)
    arms = introspect.arms(st)
    assert (arms["hyde_requested"], arms["hyde"]) == ("auto", None), arms


def test_list_scopes_carries_the_serving_processes_arms() -> None:
    with tempfile.TemporaryDirectory() as tmp:
        registry = Path(tmp) / "scopes.toml"
        registry.write_text("", encoding="utf-8")
        st = stack.Stack(hyde_requested="auto")
        cfg = server.Config(str(registry), st)
        reply = server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                               "params": {"name": "list_scopes", "arguments": {}}}, cfg)
        payload = json.loads(reply["result"]["content"][0]["text"])
        assert payload["retrieval_arms"]["hyde_requested"] == "auto", payload
        assert payload["retrieval_arms"]["hyde"] is None
        # The CLI's roster has no serving process to describe, and says nothing about one.
        assert "retrieval_arms" not in introspect.scopes_payload(str(registry))


if __name__ == "__main__":
    for _name, _fn in sorted(globals().items()):
        if _name.startswith("test_") and callable(_fn):
            _fn()
            print(f"ok  {_name}")
