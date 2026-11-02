"""HyDE's stack default is `auto`, resolved from what the local Ollama lists — never a pinned tag.

A pinned `qwen2.5:7b` was every user's HyDE model, because the app passed the engine none, and it
cost HyDE to everyone the day that model left the machine. The app now passes Settings → Search's
Off, or a named pick its server has; Auto still comes here. These pin three things: the pick rule
(the app's `ModelResolver.best(for: .search)`, mirrored), that `off` is a choice and not a fault,
and that `auto` with nothing to pick is retried by `recheck` rather than frozen at startup.

Runnable with `python tests/test_hyde_auto.py` or under pytest.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import stack  # noqa: E402
from substrate.retrieve import expand  # noqa: E402
from substrate.retrieve.expand import HyDE, pick_auto  # noqa: E402

# The catalog of the machine the 2026-11-01 sweep ran on, as `/api/tags` reported it.
_SWEEP_MACHINE = [
    {"name": "hf.co/prism-ml/Bonsai-27B-gguf:Q1_0", "size": 4432699840,
     "capabilities": ["completion", "vision"]},
    {"name": "dengcao/Qwen3-Reranker-4B:Q4_K_M", "size": 2496714721, "capabilities": ["completion"]},
    {"name": "qwen3.5:4b-mlx", "size": 3973305013,
     "capabilities": ["completion", "vision", "thinking", "tools"]},
    {"name": "qwen3.5:9b-mlx", "size": 8903014758,
     "capabilities": ["completion", "vision", "thinking", "tools"]},
    {"name": "qwen3-embedding:0.6b", "size": 639150858, "capabilities": ["embedding"]},
    {"name": "nomic-embed-text:latest", "size": 274302450, "capabilities": ["embedding"]},
]


def test_auto_picks_the_smallest_chat_model() -> None:
    """Smaller embedders and a smaller reranker are listed; none of them is a chat model."""
    assert pick_auto(_SWEEP_MACHINE) == "qwen3.5:4b-mlx"


def test_auto_on_the_sweep_machine_is_the_named_default() -> None:
    """The measured tier reaches a default caller only if auto lands on the model that was
    measured. On the machine that measured it, it does."""
    assert pick_auto(_SWEEP_MACHINE) == expand.DEFAULT_MODEL


def test_auto_never_picks_a_cloud_model() -> None:
    models = [{"name": "gpt-oss:20b-cloud", "size": 10, "capabilities": ["completion"]},
              {"name": "glm-4.6:cloud", "size": 11, "capabilities": ["completion"]},
              {"name": "big:latest", "size": 99, "capabilities": ["completion"],
               "remote_host": "https://ollama.com"},
              {"name": "local:7b", "size": 500, "capabilities": ["completion"]}]
    assert pick_auto(models) == "local:7b"


def test_auto_without_capabilities_goes_by_name() -> None:
    """An older daemon lists no capabilities; the name is then the only signal, as in the app."""
    models = [{"name": "nomic-embed-text", "size": 1}, {"name": "bge-m3", "size": 2},
              {"name": "all-minilm", "size": 3}, {"name": "some-reranker", "size": 4},
              {"name": "llama3.2:3b", "size": 5}]
    assert pick_auto(models) == "llama3.2:3b"


def test_auto_prefers_a_known_size_then_name_order() -> None:
    models = [{"name": "b:1", "capabilities": ["completion"]},
              {"name": "z:1", "size": 7, "capabilities": ["completion"]},
              {"name": "a:1", "size": 7, "capabilities": ["completion"]}]
    assert pick_auto(models) == "a:1"


def test_auto_with_no_chat_model_is_none() -> None:
    assert pick_auto([m for m in _SWEEP_MACHINE if "completion" not in m["capabilities"]]) is None
    assert pick_auto([]) is None


def test_off_is_a_choice_not_a_fault() -> None:
    st = stack.build(embed_model=None, hyde_model=stack.HYDE_OFF, rerank_model=None)
    assert st.expander is None
    assert st.unavailable == ()
    assert st.wiring["hyde"] == stack.ARM_OFF


def test_auto_with_nothing_to_pick_is_unavailable_then_rechecked() -> None:
    """Nothing to pick at startup is a downed arm, named as `auto` — and the re-check, which calls
    `build` with the original arguments, resolves again once a chat model appears."""
    with tempfile.TemporaryDirectory() as tmp:
        _auto_rechecked(str(Path(tmp) / "cache.db"))


def _auto_rechecked(cache_path: str) -> None:
    kwargs = {"embed_model": None, "hyde_model": stack.DEFAULT_HYDE, "rerank_model": None,
              "cache_path": cache_path}
    with mock.patch.object(expand, "resolve_auto", return_value=None):
        first = stack.build(**kwargs)
    assert first.expander is None
    assert first.unavailable_arms == ("hyde",)
    assert first.unavailable[0].startswith("hyde 'auto' unreachable"), first.unavailable

    with mock.patch.object(expand, "resolve_auto", return_value="qwen3.5:4b-mlx"), \
            mock.patch.object(HyDE, "available", return_value=True), \
            mock.patch.object(stack, "build", wraps=stack.build) as rebuilt:
        after = stack.recheck(first, **kwargs)
    assert rebuilt.call_args.kwargs["hyde_model"] == stack.DEFAULT_HYDE
    assert after.expander is not None and after.expander.model == "qwen3.5:4b-mlx"
    assert after.unavailable == ()


def _tags(body: object):
    """`open_local` answering `/api/tags` with `body`, so no daemon is contacted."""
    import contextlib
    import io
    import json

    @contextlib.contextmanager
    def fake(*args, **kwargs):
        yield io.BytesIO(json.dumps(body).encode())
    return mock.patch.object(expand, "open_local", fake)


def test_hyde_refuses_a_cloud_model_even_when_named() -> None:
    """The socket is loopback and the query still leaves the machine: Ollama proxies its cloud
    models. HyDE's query is what the caller is searching their vault for, so a cloud model is
    refused by name, and by the daemon's own `remote_host`, whoever asked for it."""
    listing = {"models": [{"name": "big:latest", "size": 9, "capabilities": ["completion"],
                           "remote_host": "https://ollama.com:443"},
                          {"name": "gpt-oss:120b-cloud", "size": 9, "capabilities": ["completion"]},
                          {"name": "qwen3.5:4b-mlx", "size": 9, "capabilities": ["completion"]}]}
    with _tags(listing):
        assert HyDE(model="qwen3.5:4b-mlx").available()
        assert not HyDE(model="big:latest").available()
        assert not HyDE(model="big").available()            # `:latest` spelled the short way
        assert not HyDE(model="gpt-oss:120b-cloud").available()
        # Ollama matches names case-insensitively, so the cloud test must too — and a spelling
        # that misses the exact entry must not then match the cloud model by family.
        assert not HyDE(model="gpt-oss:120b-CLOUD").available()
        assert not HyDE(model="BIG:LATEST").available()
        assert not HyDE(model="gpt-oss").available()
        assert HyDE(model="QWEN3.5:4b-mlx").available()


def test_a_cloud_tag_is_refused_without_asking_the_daemon() -> None:
    """Recorded, not raised: `available()` swallows transport errors, so a raising fake would pass
    whether or not the daemon was asked. The listing would call these local, so only the name
    test can refuse them."""
    asked = []
    local = {"models": [{"name": "glm-4.6:cloud", "capabilities": ["completion"]},
                        {"name": "gpt-oss:120b-cloud", "capabilities": ["completion"]}]}
    with _tags(local):
        real = expand.open_local
        with mock.patch.object(expand, "open_local",
                               lambda *a, **k: asked.append(a) or real(*a, **k)):
            assert not HyDE(model="glm-4.6:cloud").available()
            assert not HyDE(model="gpt-oss:120b-Cloud").available()
    assert asked == []


def test_a_named_cloud_model_leaves_the_arm_unavailable() -> None:
    with tempfile.TemporaryDirectory() as tmp, _tags({"models": [
            {"name": "gpt-oss:120b-cloud", "capabilities": ["completion"]}]}):
        st = stack.build(embed_model=None, hyde_model="gpt-oss:120b-cloud", rerank_model=None,
                         cache_path=str(Path(tmp) / "cache.db"))
    assert st.expander is None and st.unavailable_arms == ("hyde",)


def test_a_malformed_listing_is_no_pick_not_a_crash() -> None:
    """Whatever answers on the port decides the body. A bad one must leave HyDE unavailable rather
    than raise out of `stack.build` and take the engine's startup with it."""
    for body in ({"models": None}, {"models": 5}, {"models": [{"name": 5, "size": "x"}]},
                 {"models": [{"name": "a:1", "capabilities": 5}]}, [1, 2]):
        with _tags(body):
            assert expand.resolve_auto() is None, body


def test_eval_refuses_a_hyde_sentinel() -> None:
    """`eval` publishes a number against a model name. `auto` would make that number depend on
    whatever this machine lists today, and `off` is what `--no-hyde` already says."""
    from substrate import cli

    for sentinel in (expand.AUTO, expand.OFF):
        with tempfile.TemporaryDirectory() as tmp:
            rc = cli.main(["eval", "--no-vector", "--hyde-model", sentinel,
                           "--db", str(Path(tmp) / "absent.db"),
                           "--baseline", str(Path(tmp) / "none.json")])
        assert rc == 2, (sentinel, rc)


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"ok  {name}")
