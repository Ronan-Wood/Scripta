"""An input the embedder cannot hold must not cost the corpus.

Measured 2026-08-10 on the operator's `prism` scope: ONE chunk of 8,681 chars — 34 over what
`qwen3-embedding:0.6b` accepts — out of 16,153 chunks across six scopes. Ollama did not reject it
cleanly; it killed its own runner and returned `HTTP 400: do embedding request: … EOF`, a shape the
`context length` guard does not match. The whole run failed, which left the index below `complete`,
which switches the vector arm off, and HyDE and the reranker with it. One table cost a 321-note
corpus its entire retrieval stack.

These pin the two halves of the remedy without needing Ollama: a batch is BISECTED to find the
input that is refused, and a single refused input is SHRUNK until it is accepted.
"""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.embed.engine import (  # noqa: E402
    MIN_EMBED_CHARS,
    EmbeddingError,
    OllamaEmbedder,
)


class _FakeServer:
    """Refuses any single input longer than `ceiling`, exactly as the real runner does."""

    def __init__(self, ceiling: int) -> None:
        self.ceiling = ceiling
        self.calls: list[int] = []

    def __call__(self, path: str, payload: dict) -> dict:
        texts = payload["input"]
        self.calls.append(len(texts))
        if any(len(t) > self.ceiling for t in texts):
            raise EmbeddingError("http://127.0.0.1:11434 HTTP 400: do embedding request: … EOF")
        return {"embeddings": [[1.0, 0.0] for _ in texts]}


def _embedder(server) -> OllamaEmbedder:
    e = OllamaEmbedder()
    e._post = server  # type: ignore[method-assign]
    return e


def test_a_batch_survives_one_input_the_model_refuses() -> None:
    server = _FakeServer(ceiling=1000)
    e = _embedder(server)
    texts = ["short one", "x" * 5000, "short two"]

    vectors = e.embed_documents(texts)

    # EVERY input still gets a vector, including the neighbours of the bad one. Before the
    # bisection they were lost with it — the failure was per-BATCH.
    assert len(vectors) == 3
    assert all(len(v) == 2 for v in vectors)
    # And it really did bisect rather than give up: more than one request was made.
    assert len(server.calls) > 1


def test_the_refused_input_is_shrunk_until_it_is_accepted() -> None:
    server = _FakeServer(ceiling=1000)
    e = _embedder(server)

    vectors = e.embed_documents(["y" * 4000])

    assert len(vectors) == 1
    # The accepted length is a prefix under the ceiling, reached by halving.
    accepted = [n for n in server.calls if n == 1]
    assert accepted, "the single oversized input was never retried on its own"


def test_a_model_that_refuses_everything_raises_rather_than_halving_to_nothing() -> None:
    """The shrink loop must not swallow a broken model. A refusal that survives down to the floor
    is not about the input's SIZE, and reporting a healthy corpus built from nothing would be the
    quiet degradation this whole path exists to prevent."""
    server = _FakeServer(ceiling=0)   # refuses everything, at every length
    e = _embedder(server)

    with pytest.raises(EmbeddingError) as caught:
        e.embed_documents(["z" * 4000])
    assert "not rejecting its SIZE" in str(caught.value)
    assert str(MIN_EMBED_CHARS) in str(caught.value)
