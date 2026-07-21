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
        except urllib.error.HTTPError as e:
            # MUST precede URLError: HTTPError subclasses it, so catching URLError first
            # reported every rejected request as "server unreachable" — which sent me
            # looking at the daemon when the real answer was in the response body.
            body = e.read()[:300].decode(errors="replace")
            if "context length" in body:
                raise EmbeddingError(
                    f"{self.model}: chunk exceeds the model's context window. "
                    f"This corpus chunks to ~1500 chars (max ~5600), so an embedder with a "
                    f"512-token window cannot hold it without silently truncating. "
                    f"Use a longer-context embedder. Server said: {body}"
                )
            raise EmbeddingError(f"{self.host} HTTP {e.code}: {body}")
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


@dataclass
class AppleEmbedder:
    """On-device embeddings via Apple's NLContextualEmbedding, through a Swift shim.

    The question this answers: can the substrate run with NO Ollama at all? Apple ships an
    on-device contextual embedder, so the answer is not automatically no — and Scripta's
    earlier rejection of it was measured on call transcripts with a weaker instrument, which
    is not the same as measuring it here.

    No task prefixes: those are a nomic convention, not a general one. Vectors arrive
    mean-pooled and L2-normalized from the shim.
    """

    binary: str = "bin/embed-apple"
    model: str = "apple-nlcontextual"
    dim: int = 0
    _proc: object | None = None

    def available(self) -> bool:
        from pathlib import Path as _P

        return _P(self.binary).exists()

    def _ensure(self):
        import subprocess
        from pathlib import Path as _P

        if self._proc is None or self._proc.poll() is not None:
            self._proc = subprocess.Popen(
                [str(_P(self.binary).resolve())],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True, bufsize=1,
            )
            ready = self._proc.stdout.readline().strip()
            if not ready.startswith("READY"):
                raise EmbeddingError(f"embed-apple did not start ({ready!r})")
            self.dim = int(ready.split()[1])
        return self._proc

    def _one(self, text: str) -> list[float]:
        import base64
        import struct as _s

        proc = self._ensure()
        proc.stdin.write(text.replace("\n", "\\n").replace("\r", " ") + "\n")
        proc.stdin.flush()
        line = (proc.stdout.readline() or "").strip()
        if not line:
            raise EmbeddingError("empty embedding from embed-apple")
        raw = base64.b64decode(line)
        return list(_s.unpack(f"{len(raw) // 4}f", raw))

    def embed_documents(self, texts: list[str]) -> list[list[float]]:
        return [self._one(t) for t in texts]

    def embed_query(self, text: str) -> list[float]:
        return self._one(text)
