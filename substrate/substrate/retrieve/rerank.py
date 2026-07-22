"""Listwise reranking — sharpening the order, not widening the pool.

Motivated by a pattern rather than a hunch. Three independent experiments (outline routing,
multi-query fusion, a larger HyDE generator) all failed the SAME way: they broadened the
candidate pool and lost discrimination, so rank-1 answers slid to 2-3. And the margin
analysis showed the correct chunk is usually not even the top vector hit — retrieval works
because RRF fuses lexical and vector signals, not because either nails it alone.

That points at ranking quality, not recall, as the remaining headroom. Reranking is the only
technique in the stack that improves order without adding candidates.

LISTWISE, one call. Pointwise scoring (ask per passage) is the usual approach and costs N
calls per query — 20 passages at ~1s each is 20s, which fails the latency budget outright.
One call showing the model all candidates is both cheaper and gives it the comparative
context that makes ranking judgments meaningful.

Fails open: any parse failure, timeout or malformed ordering returns the original order, so a
reranker that misbehaves degrades to the fused ranking rather than to garbage.
"""

from __future__ import annotations

import json
import re
import urllib.error
import urllib.request
from dataclasses import dataclass

from substrate.store.index_store import Hit

DEFAULT_MODEL = "qwen2.5:7b"
DEFAULT_HOST = "http://127.0.0.1:11434"
POOL = 20          # candidates handed to the reranker
SNIPPET = 320      # chars per candidate; 20 x 320 keeps the prompt small enough to be fast
TIMEOUT = 60

PROMPT = (
    "You are ranking retrieved passages by how directly they ANSWER a question.\n\n"
    "Question: {q}\n\n"
    "Passages:\n{passages}\n\n"
    "Rank the passages from most to least directly answering the question. A passage that "
    "merely mentions the topic ranks BELOW one that states the specific answer.\n"
    "Reply with the passage numbers only, best first, comma-separated. Nothing else."
)


@dataclass
class LLMReranker:
    model: str = DEFAULT_MODEL
    host: str = DEFAULT_HOST
    pool: int = POOL
    cache: object | None = None

    @property
    def cache_key(self) -> str:
        return f"{self.model}#rerank{self.pool}"

    def available(self) -> bool:
        try:
            with urllib.request.urlopen(f"{self.host}/api/tags", timeout=30) as r:
                names = {m["name"] for m in json.loads(r.read()).get("models", [])}
            return self.model in names or self.model.split(":")[0] in {
                n.split(":")[0] for n in names
            }
        except Exception:
            return False

    def _order(self, query: str, hits: list[Hit]) -> list[int] | None:
        listing = "\n".join(
            f"[{i + 1}] {' '.join(h.text.split())[:SNIPPET]}" for i, h in enumerate(hits)
        )
        payload = {
            "model": self.model,
            "prompt": PROMPT.format(q=query, passages=listing),
            "stream": False,
            "options": {"temperature": 0.0, "num_predict": 80},
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
            return None

        seen: list[int] = []
        for tok in re.findall(r"\d+", text):
            idx = int(tok) - 1
            if 0 <= idx < len(hits) and idx not in seen:
                seen.append(idx)
        return seen or None

    @staticmethod
    def _already_precise(query: str, top: Hit) -> bool:
        """True when the top hit already satisfies the query lexically.

        MEASURED failure mode: reranking trades DEFINITIONAL answers for MECHANISTIC ones.
        Asked "two-phase commit coordinator and participants atomic commit", fusion returns
        the passage defining 2PC; the reranker promotes a passage about what the coordinator
        does, because the query mentions coordinators. For a vague paraphrase that judgment
        is exactly right (+0.090 on the semantic cohort); for a query that already names its
        concept it is second-guessing a hit BM25 had correct.

        So rerank only where it helps: when the top hit does NOT already contain the query's
        content terms. Precise lookups keep their answer, vague ones get reordered.
        """
        from substrate.store import fts

        terms = [t for t in fts.terms(query) if len(t) > 3]
        if not terms:
            return False
        hay = f"{top.path_str} {top.text}".lower()
        return sum(t in hay for t in terms) >= max(2, int(len(terms) * 0.75))

    def rerank(self, query: str, hits: list[Hit]) -> tuple[list[Hit], bool]:
        """Return (reordered, changed). Original order on any failure."""
        if len(hits) < 2:
            return hits, False
        if self._already_precise(query, hits[0]):
            return hits, False
        pool = hits[: self.pool]

        cached = None
        if self.cache is not None:
            key = query + "\x00" + ",".join(h.chunk_id for h in pool)
            cached = self.cache.get_expansion(key, self.cache_key)

        if cached is not None:
            order = [int(x) for x in cached.split(",") if x.strip().isdigit()]
            order = [i for i in order if 0 <= i < len(pool)]
        else:
            order = self._order(query, pool)
            if order is None:
                return hits, False
            if self.cache is not None:
                self.cache.put_expansion(
                    query + "\x00" + ",".join(h.chunk_id for h in pool),
                    self.cache_key,
                    ",".join(str(i) for i in order),
                )

        if not order:
            return hits, False
        # Anything the model omitted keeps its original relative position, appended after.
        ranked = [pool[i] for i in order]
        ranked += [h for i, h in enumerate(pool) if i not in order]
        return ranked + hits[self.pool :], True
