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
import urllib.request
from dataclasses import dataclass, field
from pathlib import Path

from substrate.retrieve import _TRANSPORT_ERRORS, _response_field
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

    # Counters the eval reads (cli.py) to refuse a mixed-arm number. A query whose rerank fell
    # back to fused order was measured WITHOUT reranking; aggregating it under the reranked
    # label is the shape of this project's retracted measurements. The cross-encoder arm
    # already carries these; the shipped listwise arm did not, so the refusal read a getattr
    # default of 0 and could never fire for the arm actually shipped.
    transport_failures: int = field(default=0, init=False)
    fallback_queries: int = field(default=0, init=False)

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

    @staticmethod
    def _listing(hits: list[Hit], snippet: int = SNIPPET) -> str:
        return "\n".join(
            f"[{i + 1}] {' '.join(h.text.split())[:snippet]}" for i, h in enumerate(hits)
        )

    @staticmethod
    def _parse_order(text: str, n: int) -> list[int] | None:
        """Extract a 0-based ordering from a model's reply. Shared by every reranker arm.

        Shared deliberately: two arms that parsed differently would not be comparable, and
        comparability is the only reason a second arm exists.
        """
        seen: list[int] = []
        for tok in re.findall(r"\d+", text):
            idx = int(tok) - 1
            if 0 <= idx < n and idx not in seen:
                seen.append(idx)
        return seen or None

    def _order(self, query: str, hits: list[Hit]) -> list[int] | None:
        listing = self._listing(hits)
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
                text = _response_field(r.read(), "response").strip()
        except _TRANSPORT_ERRORS:
            return None

        return self._parse_order(text, len(hits))

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
                # Transport/parse failure: this query is NOT reranked. Record it so the eval
                # can refuse rather than average a fused-order result under the reranked label.
                self.transport_failures += 1
                self.fallback_queries += 1
                return hits, False
            if self.cache is not None:
                self.cache.put_expansion(
                    query + "\x00" + ",".join(h.chunk_id for h in pool),
                    self.cache_key,
                    ",".join(str(i) for i in order),
                )

        if not order:
            # Cached order no longer maps onto the pool (candidates changed): the query falls
            # back to fused order, so it counts as un-reranked for the mixed-arm refusal.
            self.fallback_queries += 1
            return hits, False
        # Anything the model omitted keeps its original relative position, appended after.
        ranked = [pool[i] for i in order]
        ranked += [h for i, h in enumerate(pool) if i not in order]
        return ranked + hits[self.pool :], True


@dataclass
class AppleFMReranker:
    """Listwise reranking on-device via Apple Foundation Models, through a Swift shim.

    THE FLOOR'S BIGGEST LEVER. Until this existed, the default all-Apple tier was the only
    configuration in the engine running with NO reranker — and it is the tier that should
    gain most from one. Measured across five embedders, reranking gives its largest gains to
    the WEAKEST embedder (+0.147 to embeddinggemma, +0.128 to nomic, +0.022 to the best), and
    Apple's NLContextualEmbedding is the weakest in the fleet.

    Deliberately shares PROMPT, _listing, _parse_order and _already_precise with the Ollama
    arm. Only the transport differs. Two arms with drifting prompts or parsers would not be
    comparable, and comparability is the entire reason this arm exists.

    The real risk is CONTEXT: Apple FM's window is far smaller than the 7B's, and 20
    candidates at 320 chars is roughly 6.4k chars of passages before instructions. Overflow
    arrives as an empty line from the shim, which is indistinguishable from any other failure
    — so it is COUNTED. A reranker that silently overflowed on every query would otherwise
    report the un-reranked number under the reranked label, which is the failure this project
    has already retracted five measurements to.
    """

    binary: str = "bin/rerank-fm"
    model: str = "apple-fm"
    # MEASURED, on real retrieved candidates, not synthetic ones. Apple FM's context cannot
    # hold the 20-candidate pool the Ollama arm uses:
    #     pool=20  6,917 chars  -> EMPTY REPLY (overflow)
    #     pool=10  3,657 chars  -> valid, non-identity ordering
    #     pool= 5  2,031 chars  -> valid, non-identity ordering
    # So the floor tier structurally reranks a SMALLER pool. That is a property of the tier,
    # not a tuning choice, and it is a confound against the Ollama arm — comparing the two
    # requires running Ollama at pool=10 as well.
    pool: int = 10
    snippet: int = SNIPPET
    cache: object | None = None
    _proc: object | None = None

    transport_failures: int = field(default=0, init=False)
    fallback_queries: int = field(default=0, init=False)

    @property
    def cache_key(self) -> str:
        return f"{self.model}#rerank{self.pool}s{self.snippet}"

    @property
    def host(self) -> str:          # for the CLI's unavailability message
        return self.binary

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
            ready = (self._proc.stdout.readline() or "").strip()
            if ready != "READY":
                raise RuntimeError(f"rerank-fm did not start (got {ready!r})")
        return self._proc

    def _order(self, query: str, hits: list[Hit]) -> list[int] | None:
        prompt = PROMPT.format(q=query, passages=LLMReranker._listing(hits, self.snippet))
        try:
            proc = self._ensure()
            proc.stdin.write(prompt.replace("\n", "\\n") + "\n")
            proc.stdin.flush()
            text = (proc.stdout.readline() or "").strip().replace("\\n", "\n")
        except Exception:
            return None
        if not text:
            return None          # empty reply: most likely context overflow
        return LLMReranker._parse_order(text, len(hits))

    def rerank(self, query: str, hits: list[Hit]) -> tuple[list[Hit], bool]:
        if len(hits) < 2:
            return hits, False
        if LLMReranker._already_precise(query, hits[0]):
            return hits, False
        pool = hits[: self.pool]

        order = None
        ckey = query + "\x00" + ",".join(h.chunk_id for h in pool)
        if self.cache is not None:
            cached = self.cache.get_expansion(ckey, self.cache_key)
            if cached is not None:
                order = [int(x) for x in cached.split(",") if x.strip().isdigit()]
                order = [i for i in order if 0 <= i < len(pool)]

        if order is None:
            order = self._order(query, pool)
            if order is None:
                self.transport_failures += 1
                self.fallback_queries += 1
                return hits, False
            if self.cache is not None:
                self.cache.put_expansion(ckey, self.cache_key, ",".join(str(i) for i in order))

        if not order:
            self.fallback_queries += 1
            return hits, False
        ranked = [pool[i] for i in order]
        ranked += [h for i, h in enumerate(pool) if i not in order]
        return ranked + hits[self.pool :], True
