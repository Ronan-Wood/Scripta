"""Query expansion (HyDE) — bridging lay vocabulary to domain vocabulary.

Diagnosed failure: the query "what happens when the main machine dies and another has to
take over" shares NO vocabulary with the passage that answers it ("Handling a failure of the
leader is trickier. One of the followers needs to be promoted..."). Embeddings narrow that
gap but do not close it — the query still retrieved Chapter 2's general fault-tolerance
material, which is a plausible near-miss.

HyDE closes it from the other side: ask a local model to write the passage the answer would
appear in, then embed THAT. The generated text is wrong on facts and does not matter — it is
never shown to anyone and never enters the substrate. It is used only as a better-shaped
query vector, in domain vocabulary.

Boundaries this deliberately respects:
  * QUERY TIME only. No model touches ingestion, so the substrate stays deterministic and
    re-runs stay diffable.
  * Local only, same loopback rule as the embedder.
  * FAIL OPEN. If generation is unavailable or slow, the raw query is used.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass
from pathlib import Path

# MEASURED, and bigger is NOT better. Semantic mrr by generator, 24 cases:
#   none 0.375 | apple-fm 0.422 | llama3.2:3b 0.478 | qwen2.5:7b 0.531 | qwen2.5:14b 0.472
#
# Apple FM (on-device) helps but is the weakest generator that does: it stays in LAY
# register ("emergency restart", "backup machine") instead of reaching the domain vocabulary
# ("failover", "follower", "promoted") that is the entire mechanism. Its value is that
# generation never leaves the device, not that it removes a dependency — HyDE only shapes
# the VECTOR query, and vectors still need the embedder.
# 14b scores WORSE than 7b and runs 2.7x slower. This is a known HyDE failure mode rather
# than a fluke: larger models write longer, hedged, discursive hypotheticals, and the extra
# prose dilutes the query vector. The output here is never read by a human — it is only
# ever embedded — so tight and on-vocabulary beats comprehensive.
DEFAULT_MODEL = "qwen2.5:7b"
DEFAULT_HOST = "http://127.0.0.1:11434"
TIMEOUT = 45

PROMPT = (
    "Write one short factual paragraph, in precise technical language, that would appear in "
    "a reference book and would directly answer this question. Use the domain's standard "
    "terminology. Do not preamble, do not hedge, do not mention the question.\n\n"
    "Question: {q}\n\nParagraph:"
)


@dataclass
class HyDE:
    model: str = DEFAULT_MODEL
    host: str = DEFAULT_HOST
    max_tokens: int = 160
    cache: object | None = None

    def available(self) -> bool:
        try:
            with urllib.request.urlopen(f"{self.host}/api/tags", timeout=5) as r:
                names = {m["name"] for m in json.loads(r.read()).get("models", [])}
            return self.model in names or self.model.split(":")[0] in {
                n.split(":")[0] for n in names
            }
        except Exception:
            return False

    def expand(self, query: str) -> str:
        """Return `query + hypothetical passage`, or the bare query on any failure."""
        if self.cache is not None:
            hit = self.cache.get_expansion(query, self.model)
            if hit is not None:
                return hit

        payload = {
            "model": self.model,
            "prompt": PROMPT.format(q=query),
            "stream": False,
            "options": {"temperature": 0.0, "num_predict": self.max_tokens},
        }
        req = urllib.request.Request(
            f"{self.host}/api/generate",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                text = (json.loads(r.read()).get("response") or "").strip()
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            return query
        if not text:
            return query
        # Keep the original query: the hypothetical supplies domain vocabulary, the query
        # supplies what was actually asked. Dropping the query loses the user's specifics.
        out = f"{query}\n\n{text}"
        if self.cache is not None:
            self.cache.put_expansion(query, self.model, out)
        return out


@dataclass
class AppleFMExpander:
    """On-device HyDE via Apple Foundation Models, through a small persistent Swift shim.

    Exists because the substrate should work with nothing installed beyond the OS — the same
    constraint Scripta ships under, where Apple FM is the default and a local endpoint is the
    opt-in upgrade. FoundationModels is Swift-only, so this drives `bin/hyde-fm` over stdio
    rather than binding in-process.

    The shim is persistent: session setup dominates per-query cost, so spawning per query
    would measure startup instead of generation.
    """

    binary: str = "bin/hyde-fm"
    model: str = "apple-fm"
    cache: object | None = None
    _proc: object | None = None

    def available(self) -> bool:
        return Path(self.binary).exists()

    def _ensure(self):
        import subprocess

        if self._proc is None or self._proc.poll() is not None:
            self._proc = subprocess.Popen(
                [str(Path(self.binary).resolve())],
                stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                stderr=subprocess.DEVNULL, text=True, bufsize=1,
            )
            ready = self._proc.stdout.readline().strip()
            if ready != "READY":
                raise RuntimeError(f"hyde-fm did not start (got {ready!r})")
        return self._proc

    def expand(self, query: str) -> str:
        if self.cache is not None:
            hit = self.cache.get_expansion(query, self.model)
            if hit is not None:
                return hit
        try:
            proc = self._ensure()
            proc.stdin.write(query.replace("\n", " ") + "\n")
            proc.stdin.flush()
            text = (proc.stdout.readline() or "").strip().replace("\\n", "\n")
        except Exception:
            return query  # fail open, exactly as the Ollama path does
        if not text:
            return query
        out = f"{query}\n\n{text}"
        if self.cache is not None:
            self.cache.put_expansion(query, self.model, out)
        return out
