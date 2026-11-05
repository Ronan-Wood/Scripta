"""The reranker never uses a model that runs in Ollama's cloud — the rule HyDE already kept.

Ollama proxies its cloud models through the loopback daemon, so the loopback guard passes and the
request still leaves the machine. HyDE refused those (`expand.is_cloud`); the reranker did not, and
it sends more than HyDE does: the query AND the passages it reorders. `--rerank-model
gpt-oss:120b-cloud` was wired and reported `reranker: ran`. These pin the refusal on every path
that names a reranker: `stack.build` (what `substrate-mcp` builds), the listwise and cross-encoder
arms themselves (what `eval` builds directly), and the two command lines, which refuse by name
before anything is built so the reason reads "cloud" and not "unreachable".

Runnable with `python tests/test_rerank_cloud.py` or under pytest.
"""

from __future__ import annotations

import contextlib
import importlib
import io
import json
import sys
import tempfile
from pathlib import Path
from unittest import mock

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import stack  # noqa: E402
from substrate.retrieve import expand, rerank, rerank_cross  # noqa: E402
from substrate.retrieve.rerank import LLMReranker  # noqa: E402
from substrate.retrieve.rerank_cross import CrossEncoderReranker  # noqa: E402

_LISTING = {"models": [
    {"name": "big:latest", "capabilities": ["completion"], "remote_host": "https://ollama.com:443"},
    {"name": "gpt-oss:120b-cloud", "capabilities": ["completion"]},
    {"name": "glm-4.6:cloud", "capabilities": ["completion"]},
    {"name": "qwen3.5:4b-mlx", "capabilities": ["completion"]},
    {"name": rerank_cross.DEFAULT_MODEL, "capabilities": ["completion"]},
    {"name": "remote-ce:q4", "capabilities": ["completion"], "remote_host": "https://ollama.com:443"},
]}


@contextlib.contextmanager
def _tags(body: object, asked: list | None = None):
    """Every module's `open_local` answering `/api/tags` with `body`, so no daemon is contacted —
    patched in each module that has probed a listing, so the old code is held to the same fake.
    Patched on entering the `with`, inside it, so a patch that fails undoes the ones before it."""
    @contextlib.contextmanager
    def fake(*args, **kwargs):
        if asked is not None:
            asked.append(args)
        yield io.BytesIO(json.dumps(body).encode())

    with contextlib.ExitStack() as patches:
        for mod in (expand, rerank, rerank_cross, *_LOCALITY):
            patches.enter_context(mock.patch.object(mod, "open_local", fake))
        yield


# Where the locality rule lives now. Looked up rather than imported, so these tests still load
# against the code from before the rule existed and fail there on the behaviour, not an import.
try:
    _LOCALITY = (importlib.import_module("substrate.retrieve.local_models"),)
except ImportError:
    _LOCALITY = ()


def test_listwise_refuses_a_cloud_model_by_name_and_by_listing() -> None:
    with _tags(_LISTING):
        assert LLMReranker(model="qwen3.5:4b-mlx").available()
        assert not LLMReranker(model="gpt-oss:120b-cloud").available()
        assert not LLMReranker(model="glm-4.6:cloud").available()
        assert not LLMReranker(model="big:latest").available()      # `remote_host` alone says so
        assert not LLMReranker(model="big").available()             # `:latest` spelled short
        # HyDE's matching, so a spelling that misses the cloud entry by case, or reaches it by
        # family, is refused rather than matched past the cloud test.
        assert not LLMReranker(model="GPT-OSS:120b-CLOUD").available()
        assert not LLMReranker(model="gpt-oss").available()


def test_a_cloud_tag_is_refused_without_asking_the_daemon() -> None:
    """Recorded, not raised: `available()` swallows transport errors, so a raising fake would pass
    whether or not the daemon was asked."""
    asked: list = []
    with _tags(_LISTING, asked):
        assert not LLMReranker(model="gpt-oss:120b-cloud").available()
        assert not CrossEncoderReranker(model="glm-4.6:cloud").available()
    assert asked == []


def test_cross_encoder_refuses_a_cloud_model() -> None:
    """`eval --cross-encoder --rerank-model` names this arm's model freely, and each scoring pass
    sends the query and a passage."""
    with _tags(_LISTING):
        assert CrossEncoderReranker(model=rerank_cross.DEFAULT_MODEL).available()
        assert not CrossEncoderReranker(model="gpt-oss:120b-cloud").available()
        assert not CrossEncoderReranker(model="remote-ce:q4").available()
        assert not CrossEncoderReranker(model="big").available()
        assert not CrossEncoderReranker(model="glm-4.6:CLOUD").available()


def test_a_missing_model_with_a_cloud_sibling_is_missing_not_cloud() -> None:
    """`qwen3:4b` is not pulled; a cloud `qwen3` is listed. Still refused — the family match must
    not let a cloud sibling through — but as missing: calling it a cloud model would report a
    model that only needs pulling as a policy refusal."""
    from substrate import cli

    listing = {"models": [{"name": "qwen3:235b-cloud", "capabilities": ["completion"]}]}
    with tempfile.TemporaryDirectory() as tmp, _tags(listing):
        for arm in (LLMReranker(model="qwen3:4b"), expand.HyDE(model="qwen3:4b")):
            assert not arm.available(), arm
            assert not getattr(arm, "refused_cloud", False), arm
        st = stack.build(embed_model=None, hyde_model="qwen3:4b", rerank_model="qwen3:4b",
                         cache_path=str(Path(tmp) / "cache.db"))
        assert st.unavailable_arms == ("hyde", "reranker"), st.unavailable
        assert not any("cloud" in e for e in st.unavailable), st.unavailable
        rc, err = _stderr_of(cli.main, [
            "eval", "--no-vector", "--no-hyde", "--rerank-model", "qwen3:4b",
            "--db", str(Path(tmp) / "absent.db"), "--baseline", str(Path(tmp) / "none.json"),
            "--cache", str(Path(tmp) / "cache.db")])
    assert rc == 2 and "not available" in err and "cloud model" not in err, (rc, err)


def test_a_cloud_reranker_leaves_the_arm_unavailable() -> None:
    """What a caller of `stack.build` gets when the command line's check is not in front of it:
    the arm is never wired."""
    with tempfile.TemporaryDirectory() as tmp, _tags(_LISTING):
        for model in ("gpt-oss:120b-cloud", "big"):
            st = stack.build(embed_model=None, hyde_model=None, rerank_model=model,
                             cache_path=str(Path(tmp) / "cache.db"))
            assert st.reranker is None, model
            assert st.unavailable_arms == ("reranker",), model
            # Said as a cloud refusal, by name or by the listing's `remote_host` alone ("big"),
            # never as a daemon that could not be reached.
            assert "cloud" in st.unavailable[0] and "unreachable" not in st.unavailable[0], \
                st.unavailable
            # The same reason the command lines give, from one constant.
            assert _LOCALITY, "substrate.retrieve.local_models did not import"
            assert _LOCALITY[0].CLOUD_REASON in st.unavailable[0], st.unavailable


def test_a_cross_encoder_on_the_cloud_is_refused_as_cloud() -> None:
    """The cross arm's model is fixed in `stack.build`, so only a listing that marks it remote can
    refuse it there — and that is still a cloud refusal, not "unreachable"."""
    listing = {"models": [{"name": rerank_cross.DEFAULT_MODEL, "capabilities": ["completion"],
                           "remote_host": "https://ollama.com:443"}]}
    with tempfile.TemporaryDirectory() as tmp, _tags(listing):
        st = stack.build(embed_model=None, hyde_model=None, rerank_model="cross",
                         cache_path=str(Path(tmp) / "cache.db"))
    assert st.reranker is None and st.unavailable_arms == ("reranker",)
    assert "cloud" in st.unavailable[0] and "unreachable" not in st.unavailable[0], st.unavailable


def _stderr_of(fn, argv: list[str]) -> tuple[int, str]:
    err = io.StringIO()
    with contextlib.redirect_stderr(err):
        rc = fn(argv)
    return rc, err.getvalue()


def test_the_server_refuses_a_cloud_reranker_at_launch() -> None:
    """Exit 2 before the stack is built, saying why. Left to `stack.build`, the arm is dropped as
    "unreachable at http://127.0.0.1:11434" — a fault in a daemon that is fine."""
    from substrate.mcp import server

    with tempfile.TemporaryDirectory() as tmp, \
            mock.patch.object(server.stack, "build", side_effect=_Built):
        registry = ["--registry", str(Path(tmp) / "scopes.toml")]
        for model in ("gpt-oss:120b-cloud", "glm-4.6:CLOUD"):
            rc, err = _stderr_of(server.main, ["--rerank-model", model, *registry])
            assert rc == 2, (model, rc, err)
            assert "cloud model" in err and model in err, err
        # The control: the same launch with a local model gets as far as building the stack, so
        # the 2 above is the refusal and not some earlier step failing on this machine.
        try:
            server.main(["--rerank-model", "qwen3.5:4b-mlx", *registry])
        except _Built:
            pass
        else:
            raise AssertionError("a local reranker never reached stack.build")


class _Built(Exception):
    """`stack.build` was reached."""


def test_eval_refuses_a_cloud_reranker() -> None:
    """`eval` builds its reranker itself, past `stack.build`. Under the fake listing the old code
    found the cloud model available and went on to rerank with it."""
    from substrate import cli

    with tempfile.TemporaryDirectory() as tmp, _tags(_LISTING):
        for extra in ([], ["--cross-encoder"]):
            rc, err = _stderr_of(cli.main, [
                "eval", "--no-vector", "--no-hyde", *extra,
                "--rerank-model", "gpt-oss:120b-cloud",
                "--db", str(Path(tmp) / "absent.db"),
                "--baseline", str(Path(tmp) / "none.json"),
                "--cache", str(Path(tmp) / "cache.db")])
            assert rc == 2, (extra, rc, err)
            assert "cloud model" in err, err


def test_eval_refuses_a_reranker_the_listing_marks_cloud() -> None:
    """A name that does not say "cloud", served from the cloud all the same (`remote_host`). The
    arm refuses it; `eval` must say why, not "not available", which points at a healthy daemon."""
    from substrate import cli

    with tempfile.TemporaryDirectory() as tmp, _tags(_LISTING):
        for extra, model in (([], "big"), (["--cross-encoder"], "remote-ce:q4")):
            rc, err = _stderr_of(cli.main, [
                "eval", "--no-vector", "--no-hyde", *extra, "--rerank-model", model,
                "--db", str(Path(tmp) / "absent.db"),
                "--baseline", str(Path(tmp) / "none.json"),
                "--cache", str(Path(tmp) / "cache.db")])
            assert rc == 2, (extra, rc, err)
            assert "cloud model" in err and "not available" not in err, err


def test_eval_does_not_blame_a_flag_nobody_passed() -> None:
    """`eval --cross-encoder` with no `--rerank-model` runs the arm's default. When the listing
    marks THAT remote, the refusal must not tell the user to leave out a flag they never gave."""
    from substrate import cli

    listing = {"models": [{"name": rerank_cross.DEFAULT_MODEL, "capabilities": ["completion"],
                           "remote_host": "https://ollama.com:443"}]}
    with tempfile.TemporaryDirectory() as tmp, _tags(listing):
        rc, err = _stderr_of(cli.main, [
            "eval", "--no-vector", "--no-hyde", "--cross-encoder",
            "--db", str(Path(tmp) / "absent.db"), "--baseline", str(Path(tmp) / "none.json"),
            "--cache", str(Path(tmp) / "cache.db")])
    assert rc == 2, (rc, err)
    assert "cloud model" in err and rerank_cross.DEFAULT_MODEL in err, err
    assert "--rerank-model" not in err, err


def test_server_and_eval_give_one_reason() -> None:
    """The two command lines refuse the same model in the same words, from one source."""
    from substrate import cli
    from substrate.mcp import server

    model = "gpt-oss:120b-cloud"
    with tempfile.TemporaryDirectory() as tmp, \
            mock.patch.object(server.stack, "build", side_effect=_Built):
        _, served = _stderr_of(server.main, ["--rerank-model", model,
                                             "--registry", str(Path(tmp) / "scopes.toml")])
        _, evaluated = _stderr_of(cli.main, [
            "eval", "--no-vector", "--no-hyde", "--rerank-model", model,
            "--db", str(Path(tmp) / "absent.db"), "--baseline", str(Path(tmp) / "none.json"),
            "--cache", str(Path(tmp) / "cache.db")])
    reason = served.strip().removeprefix("substrate-mcp: ")
    assert "cloud model" in reason, served
    assert evaluated.strip().endswith(f"FATAL: {reason}"), (served, evaluated)


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"ok  {name}")
