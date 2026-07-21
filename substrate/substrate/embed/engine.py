"""EmbeddingEngine — pluggable, local-only, and gated on the eval.

The interface exists so the embedder is a swappable decision, not a dependency. The only
implementation is Ollama, matching the path Scripta already wired (`nomic-embed-text` via
EndpointEngine/OpenAIWire), and the endpoint is restricted to loopback for the same reason
Scripta's Locality guard exists: an embedding request carries the corpus off the machine.

Two details that fail SILENTLY if missed:

  * nomic-embed-text requires TASK PREFIXES — `search_document:` when embedding a chunk,
    `search_query:` when embedding a query. Omitting them does not error; it just degrades
    retrieval, which is the worst possible failure for something being eval-gated.
  * Vectors must be L2-normalized before storage so a dot product IS cosine similarity.
    Skipping it makes long chunks systematically score higher.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from typing import Protocol

DEFAULT_HOST = "http://127.0.0.1:11434"
DEFAULT_MODEL = "nomic-embed-text"
BATCH = 64
TIMEOUT = 120

LOOPBACK = ("127.0.0.1", "localhost", "::1", "[::1]")


class EmbeddingError(RuntimeError):
    pass


class EmbeddingEngine(Protocol):
    model: str
    dim: int

    def embed_documents(self, texts: list[str]) -> list[list[float]]: ...
    def embed_query(self, text: str) -> list[float]: ...


def _l2(v: list[float]) -> list[float]:
    n = sum(x * x for x in v) ** 0.5
    return [x / n for x in v] if n else v


@dataclass
class OllamaEmbedder:
    """Local Ollama embeddings. Loopback only — never carries the corpus off the machine."""

    model: str = DEFAULT_MODEL
    host: str = DEFAULT_HOST
    dim: int = 0

    def __post_init__(self) -> None:
        host = self.host.split("//")[-1].split(":")[0]
        if host not in LOOPBACK:
            raise EmbeddingError(
                f"refusing non-loopback embedding host {self.host!r}. Embedding sends the "
                "corpus to the endpoint; this engine is local-only by design."
            )

    def _post(self, path: str, payload: dict) -> dict:
        req = urllib.request.Request(
            f"{self.host}{path}",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                return json.loads(r.read())
        except urllib.error.URLError as e:
            raise EmbeddingError(f"{self.host} unreachable — is `ollama serve` running? ({e})")

    def _embed(self, texts: list[str]) -> list[list[float]]:
        out: list[list[float]] = []
        for i in range(0, len(texts), BATCH):
            chunk = texts[i : i + BATCH]
            res = self._post("/api/embed", {"model": self.model, "input": chunk})
            vecs = res.get("embeddings") or []
            if len(vecs) != len(chunk):
                raise EmbeddingError(f"expected {len(chunk)} embeddings, got {len(vecs)}")
            out.extend(_l2([float(x) for x in v]) for v in vecs)
        if out:
            self.dim = len(out[0])
        return out

    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        return self._embed([f"search_document: {t}" for t in texts])

    def embed_query(self, text: str) -> list[float]:
        return self._embed([f"search_query: {text}"])[0]

    def available(self) -> bool:
        try:
            with urllib.request.urlopen(f"{self.host}/api/tags", timeout=5) as r:
                names = {m["name"].split(":")[0] for m in json.loads(r.read()).get("models", [])}
            return self.model.split(":")[0] in names
        except Exception:
            return False
