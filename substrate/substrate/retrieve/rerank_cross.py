"""Cross-encoder reranking via Qwen3-Reranker — the purpose-built alternative.

The shipped reranker is LISTWISE: one call showing a general chat model all 20 candidates,
asking for an order. That was a workaround for not having a real reranker, and it works
(+0.095) but has a measured failure mode — it trades definitional answers for mechanistic
ones, which is why it triggers adaptively.

A cross-encoder is the purpose-built thing. It scores each (query, document) pair
independently, having been trained on exactly that judgment rather than asked to improvise
it. Two structural differences worth stating:

  * POINTWISE, so N calls per query rather than one. Each call is prefill plus a SINGLE
    token — no generation — so it is far cheaper per call than it looks, but it is still N.
  * No comparative context. The listwise ranker sees candidates side by side and can reason
    "this one is more direct than that one"; a cross-encoder cannot. That is a genuine
    trade, not a strict upgrade, and it is why this is measured rather than assumed better.

THREE INVOCATION DETAILS, ALL MEASURED, ALL SILENT FAILURES IF MISSED
--------------------------------------------------------------------
1. `raw: true` with the chat template written out by hand. Ollama's /api/chat applies the
   GGUF's own template, and for this build that template is NOT the reranker's format: the
   model CONTINUES the document instead of judging it. Measured, same pair, same options:

       /api/chat                    -> " This is the case"     (continuation, useless)
       /api/generate raw + template -> "yes"                   (correct)

   A wrong-but-plausible string is the worst case here, because it parses. "This..." starts
   with neither yes nor no, so it degrades to None and the run fails open — but only by luck.

2. The assistant turn is primed with an EMPTY think block. Qwen3-Reranker is built on Qwen3,
   a thinking model; without `<think>\n\n</think>` already closed it reasons before answering
   and the single-token budget captures reasoning instead of the verdict.

3. BINARY ONLY on this stack. Graded relevance needs the logprob of "yes" against "no", and
   Ollama 0.20.3 does not expose it by any route tested: `logprobs` inside `options` is
   silently ignored (no error, no field), at the top level it is HTTP 400, and
   /v1/completions returns `top_logprobs` empty. So the score is 1.0 or 0.0.

   That makes this a RELEVANCE FILTER rather than a re-ranker: every "yes" is promoted above
   every "no", and within each partition the RRF fusion order is preserved by a stable sort.
   Losing that stability would discard the ranking those candidates earned — with binary
   scores most entries tie, so the sort's stability carries almost all the ordering.
"""

from __future__ import annotations

import json
import math
import urllib.error
import urllib.request
from dataclasses import dataclass

from substrate.store.index_store import Hit

DEFAULT_MODEL = "dengcao/Qwen3-Reranker-4B:Q4_K_M"
DEFAULT_HOST = "http://127.0.0.1:11434"
POOL = 20
SNIPPET = 900          # cross-encoders see one doc at a time, so it can exceed listwise's 320
TIMEOUT = 120

SYSTEM = (
    'Judge whether the Document meets the requirements based on the Query and the Instruct '
    'provided. Note that the answer can only be "yes" or "no".'
)
INSTRUCTION = (
    "Given a question about a technical reference document, decide whether the passage "
    "directly answers it. A passage that merely mentions the topic is NOT relevant."
)

# Qwen3-Reranker's trained format, written out because /api/chat will not apply it. The
# trailing empty think block is load-bearing — see note 2 above.
TEMPLATE = (
    "<|im_start|>system\n{system}<|im_end|>\n"
    "<|im_start|>user\n<Instruct>: {instruction}\n<Query>: {query}\n<Document>: {doc}<|im_end|>\n"
    "<|im_start|>assistant\n<think>\n\n</think>\n\n"
)


@dataclass
class CrossEncoderReranker:
    model: str = DEFAULT_MODEL
    host: str = DEFAULT_HOST
    pool: int = POOL
    cache: object | None = None
    gate: bool = True       # skip queries whose top hit is already lexically precise

    @property
    def cache_key(self) -> str:
        return f"{self.model}#cross{self.pool}{'' if self.gate else '-nogate'}"

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
                system=SYSTEM,
                instruction=INSTRUCTION,
                query=query,
                doc=" ".join(doc.split())[:SNIPPET],
            ),
            "raw": True,
            "stream": False,
            "options": {"temperature": 0.0, "num_predict": 1},
        }
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

        # Graded path, kept for the day Ollama exposes logprobs. Unreachable today (note 3);
        # it costs nothing and its absence is what makes the binary fallback load-bearing.
        lp = data.get("logprobs")
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

        text = (data.get("response") or "").strip().lower()
        if text.startswith("yes"):
            return 1.0
        if text.startswith("no"):
            return 0.0
        return None      # anything else is a template failure, not a judgment — fail open

    def rerank(self, query: str, hits: list[Hit]) -> tuple[list[Hit], bool]:
        if len(hits) < 2:
            return hits, False
        # Same skip as the listwise arm, so the two are compared on equal footing. Whether a
        # cross-encoder NEEDS it is a separate measurement (--no-gate): the gate exists
        # because a chat model second-guesses lexically-exact hits, and a purpose-trained
        # relevance model may not share that failure.
        if self.gate:
            from substrate.retrieve.rerank import LLMReranker

            if LLMReranker._already_precise(query, hits[0]):
                return hits, False
        pool = hits[: self.pool]

        ckey = query + "\x00" + ",".join(h.chunk_id for h in pool)
        if self.cache is not None:
            cached = self.cache.get_expansion(ckey, self.cache_key)
            if cached is not None:
                try:
                    scores = [float(x) for x in cached.split(",")]
                    if len(scores) == len(pool):
                        order = sorted(range(len(pool)), key=lambda i: (-scores[i], i))
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

        # STABLE sort: equal scores keep fused order. With binary scores most entries tie, so
        # an unstable sort would throw away the fusion ranking that earned those positions.
        order = sorted(range(len(pool)), key=lambda i: (-scores[i], i))
        return [pool[i] for i in order] + hits[self.pool :], True
