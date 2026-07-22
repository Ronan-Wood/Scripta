"""Cross-encoder reranking via Qwen3-Reranker — the purpose-built alternative.

The shipped reranker is LISTWISE: one call showing a general chat model all 20 candidates,
asking for an order. That was a workaround for not having a real reranker, and it works
(+0.095) but has a measured failure mode — it trades definitional answers for mechanistic
ones, which is why it triggers adaptively.

A cross-encoder is the purpose-built thing. It scores each (query, document) pair
independently, having been trained on exactly that judgment rather than asked to improvise
it. Two structural differences worth stating:

  * POINTWISE, so N calls per query rather than one. Slower, and the latency is real, but
    each call is prefill plus a SINGLE token — no generation — so it is far cheaper per call
    than it looks.
  * No comparative context. The listwise ranker sees candidates side by side and can reason
    "this one is more direct than that one"; a cross-encoder cannot. That is a genuine
    trade, not a strict upgrade, and it is why this is measured rather than assumed better.

Qwen3-Reranker is trained to answer a yes/no relevance question. Graded scores need token
logprobs; where those are unavailable we fall back to the binary judgment, which still
partitions relevant from irrelevant and preserves fused order within each partition.
"""

from __future__ import annotations

import json
import urllib.error
import urllib.request
from dataclasses import dataclass

from substrate.store.index_store import Hit

DEFAULT_MODEL = "dengcao/Qwen3-Reranker-4B:Q4_K_M"
DEFAULT_HOST = "http://127.0.0.1:11434"
POOL = 20
SNIPPET = 900          # cross-encoders see one doc at a time, so it can be longer than listwise
TIMEOUT = 60

INSTRUCTION = (
    "Given a question about a technical reference document, decide whether the passage "
    "directly answers it. A passage that merely mentions the topic is NOT relevant."
)

# Qwen3-Reranker's trained format. It is tuned to answer exactly "yes" or "no".
TEMPLATE = (
    "<Instruct>: {instruction}\n"
    "<Query>: {query}\n"
    "<Document>: {doc}\n"
)


@dataclass
class CrossEncoderReranker:
    model: str = DEFAULT_MODEL
    host: str = DEFAULT_HOST
    pool: int = POOL
    cache: object | None = None
    graded: bool = True     # try logprobs; fall back to binary

    @property
    def cache_key(self) -> str:
        return f"{self.model}#cross{self.pool}"

    def available(self) -> bool:
        try:
            with urllib.request.urlopen(f"{self.host}/api/tags", timeout=30) as r:
                names = {m["name"] for m in json.loads(r.read()).get("models", [])}
            return self.model in names
        except Exception:
            return False

    def _score(self, query: str, doc: str) -> float | None:
        """Relevance in [0,1]. None on failure, so the caller can keep fused order."""
        payload = {
            "model": self.model,
            "prompt": TEMPLATE.format(
                instruction=INSTRUCTION, query=query, doc=" ".join(doc.split())[:SNIPPET]
            ),
            "stream": False,
            "options": {"temperature": 0.0, "num_predict": 1},
        }
        if self.graded:
            payload["options"]["logprobs"] = 8
        req = urllib.request.Request(
            f"{self.host}/api/generate",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                data = json.loads(r.read())
        except (urllib.error.URLError, TimeoutError, json.JSONDecodeError):
            return None

        # Graded path: P(yes) from the first token's logprobs, when the server supplies them.
        import math

        lp = data.get("logprobs") or data.get("choices")
        if lp:
            try:
                top = lp[0].get("top_logprobs") or lp[0]
                probs = {
                    str(k).strip().lower(): math.exp(v)
                    for k, v in (top.items() if isinstance(top, dict) else [])
                }
                yes, no = probs.get("yes", 0.0), probs.get("no", 0.0)
                if yes or no:
                    return yes / (yes + no)
            except Exception:
                pass

        # Binary fallback — still separates relevant from irrelevant.
        text = (data.get("response") or "").strip().lower()
        if text.startswith("yes"):
            return 1.0
        if text.startswith("no"):
            return 0.0
        return None

    def rerank(self, query: str, hits: list[Hit]) -> tuple[list[Hit], bool]:
        if len(hits) < 2:
            return hits, False
        pool = hits[: self.pool]

        ckey = query + "\x00" + ",".join(h.chunk_id for h in pool)
        if self.cache is not None:
            cached = self.cache.get_expansion(ckey, self.cache_key)
            if cached is not None:
                try:
                    scores = [float(x) for x in cached.split(",")]
                    if len(scores) == len(pool):
                        order = sorted(range(len(pool)), key=lambda i: -scores[i])
                        return [pool[i] for i in order] + hits[self.pool :], True
                except ValueError:
                    pass

        scores: list[float] = []
        for h in pool:
            s = self._score(query, h.text)
            if s is None:
                return hits, False          # fail open, keep fused order
            scores.append(s)

        if self.cache is not None:
            self.cache.put_expansion(ckey, self.cache_key, ",".join(f"{s:.6f}" for s in scores))

        # STABLE sort: equal scores keep fused order. With a binary fallback most scores tie,
        # and an unstable sort would discard the fusion ranking that earned those positions.
        order = sorted(range(len(pool)), key=lambda i: (-scores[i], i))
        return [pool[i] for i in order] + hits[self.pool :], True
