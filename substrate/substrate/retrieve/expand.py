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
# WHY THE LARGER MODEL LOSES — measured, after two wrong explanations.
#
# Wrong #1: "14b writes longer, hedged prose that dilutes the vector." FALSE. 14b generates
#           SHORTER text (median 566 vs 621 chars) and truncates less (0/49 vs 2/49).
# Wrong #2: "14b fails to reach domain vocabulary." FALSE, and backwards: 14b contains the
#           target domain term MORE often (17/24 vs 14/24).
#
# Actual mechanism — retrieval is COMPETITIVE, not absolute:
#
#     model        cosine to correct chunk     margin over best competitor
#     7b           0.743                       -0.021
#     14b          0.745  (closer, 15/24)      -0.029  (worse, 7b wins 9v5)
#
# 14b moves the query vector closer to the right answer AND closer to everything else in
# the same topical neighbourhood. Absolute similarity rises while DISCRIMINATION falls: it
# writes more genericly on-topic prose, lifting the whole region instead of picking out one
# passage. Optimizing a HyDE prompt should therefore target separation from near-misses, not
# proximity to the answer — those are different objectives and they diverge with scale.
#
# Related: margins are almost all NEGATIVE, so the correct chunk is usually not the top
# VECTOR hit. Retrieval works because RRF fuses vectors with lexical; the vector layer
# supplies ranking signal but rarely wins outright.
#
# Apple FM's weakness against nomic is a REGISTER mismatch, not a capability gap — paired
# with Apple's own embedder it beats qwen 7b (0.472 vs 0.392). See embed/engine.py.
# 14b scores WORSE than 7b and runs 2.7x slower. This is a known HyDE failure mode rather
# than a fluke: larger models write longer, hedged, discursive hypotheticals, and the extra
# prose dilutes the query vector. The output here is never read by a human — it is only
# ever embedded — so tight and on-vocabulary beats comprehensive.
DEFAULT_MODEL = "qwen2.5:7b"
DEFAULT_HOST = "http://127.0.0.1:11434"
TIMEOUT = 45

# Two objectives, deliberately different. See the "canonical vs distinctive" note below.
PROMPTS = {
    # v1 CANONICAL — asks for the most TYPICAL passage on the topic.
    "canonical": (
        "Write one short factual paragraph, in precise technical language, that would appear "
        "in a reference book and would directly answer this question. Use the domain's "
        "standard terminology. Do not preamble, do not hedge, do not mention the question."
        "\n\nQuestion: {q}\n\nParagraph:"
    ),
    # v2 DISTINCTIVE — MEASURED WORSE. Kept as a recorded negative result.
    #
    #     qwen2.5:7b  canonical    0.531
    #     qwen2.5:7b  distinctive  0.445
    #
    # The theory was that a canonical paragraph sits at the topic centroid, which is exactly
    # where the near-misses live, so targeting separation should beat targeting typicality.
    # That theory predicted an improvement and got a 0.086 regression instead.
    #
    # Two candidate reasons, NOT separated because the experiment was stopped early:
    #   1. CONFOUNDED. It changed the objective AND the output length at once (a named term
    #      plus 2-3 sentences, versus a full paragraph), so less text to embed may be doing
    #      the damage rather than the objective.
    #   2. VARIANCE. Committing to one named concept is a high-variance bet: excellent when
    #      the model names the right concept, worse than a diffuse paragraph when it does
    #      not. Canonical prose is robust precisely because it is unfocused.
    #
    # If revisited, vary length and objective SEPARATELY.
    "distinctive": (
        "Name the single most specific concept that answers this question, then write 2-3 "
        "sentences that could ONLY describe that concept and not its general topic.\n"
        "Use the exact technical term, not a description of it. Include the distinguishing "
        "mechanism, condition, or failure mode that separates it from adjacent concepts.\n"
        "Omit background, motivation and anything true of the wider subject area.\n"
        "No preamble. Do not mention the question.\n\nQuestion: {q}\n\nAnswer:"
    ),
}
PROMPT = PROMPTS["canonical"]


@dataclass
class HyDE:
    model: str = DEFAULT_MODEL
    host: str = DEFAULT_HOST
    max_tokens: int = 160
    cache: object | None = None
    prompt_id: str = "canonical"

    @property
    def cache_key(self) -> str:
        """Cache identity MUST include the prompt. Keying on (query, model) alone would
        serve generations produced by a different prompt — a silent staleness bug that would
        have invalidated the very A/B this exists to run."""
        return f"{self.model}#{self.prompt_id}"

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
            hit = self.cache.get_expansion(query, self.cache_key)
            if hit is not None:
                return hit

        payload = {
            "model": self.model,
            "prompt": PROMPTS[self.prompt_id].format(q=query),
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
            self.cache.put_expansion(query, self.cache_key, out)
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
            hit = self.cache.get_expansion(query, self.cache_key)
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


MULTIQUERY_PROMPT = (
    "Rewrite the question below {n} different ways, each phrased as someone with different "
    "expertise would ask it. Vary the vocabulary REGISTER: at least one using the precise "
    "technical terminology of the field, at least one in plain everyday words, at least one "
    "phrased as the situation or symptom rather than the concept.\n"
    "Each rewrite on its own line. No numbering, no preamble, nothing else.\n\n"
    "Question: {q}\n\nRewrites:"
)


@dataclass
class MultiQuery:
    """Generate register-varied paraphrases and retrieve with all of them.

    Motivated by the measured evidence rather than by fashion: HyDE was the single biggest
    win (+0.150), which says the dominant problem is the gap between how a question is
    phrased and how the corpus words the answer. HyDE attacks that by making the query
    document-shaped. Multi-query attacks it differently — by covering several phrasings at
    once, so a hit only has to match ONE of them.

    MEASURED — default OFF. Stacked on HyDE over 44 semantic cases:

        config                     semantic mrr    p50 latency
        HyDE only                  0.603           397ms
        HyDE + multi-query(3)      0.637  +0.034   1996ms  (5x)

    The net is positive but it is a REDISTRIBUTION, not an improvement: 11 cases improved,
    10 regressed, and 3 that were passing broke entirely. Structurally the same failure as
    outline routing — extra candidate lists rescue misses while displacing precise hits, so
    rank-1 answers slide to 2-3. Paying 5x latency for ~1.5 cases of contested net gain is
    not a trade worth making by default.

    It IS a genuine recall tool though: sem-leader-crash finally passed (miss -> rank 4),
    rescued by a variant that used the word "failover" — the exact domain term the original
    query lacked. That suggests the right use is ADAPTIVE rather than always-on: fall back to
    multi-query only when primary retrieval returns nothing confident, paying the latency
    only when the cheap path has already failed. Untested; needs a confidence signal.

    ONE generation call produces all variants. N separate calls would multiply the dominant
    cost (LLM latency) for no extra diversity.
    """

    model: str = DEFAULT_MODEL
    host: str = DEFAULT_HOST
    n: int = 3
    cache: object | None = None
    prompt_id: str = "multiquery"

    @property
    def cache_key(self) -> str:
        return f"{self.model}#{self.prompt_id}{self.n}"

    def available(self) -> bool:
        return HyDE(model=self.model, host=self.host).available()

    def variants(self, query: str) -> list[str]:
        """Return paraphrases (NOT including the original). Empty list on any failure."""
        if self.cache is not None:
            hit = self.cache.get_expansion(query, self.cache_key)
            if hit is not None:
                return [ln for ln in hit.split("\n") if ln.strip()]

        payload = {
            "model": self.model,
            "prompt": MULTIQUERY_PROMPT.format(n=self.n, q=query),
            "stream": False,
            "options": {"temperature": 0.0, "num_predict": 200},
        }
        req = urllib.request.Request(
            f"{self.host}/api/generate",
            data=json.dumps(payload).encode(),
            headers={"Content-Type": "application/json"},
        )
        try:
            with urllib.request.urlopen(req, timeout=TIMEOUT) as r:
                text = (json.loads(r.read()).get("response") or "").strip()
        except Exception:
            return []

        out: list[str] = []
        for line in text.splitlines():
            line = line.strip().lstrip("0123456789.)-• ").strip()
            if len(line) > 8 and line.lower() != query.lower():
                out.append(line)
        out = out[: self.n]
        if out and self.cache is not None:
            self.cache.put_expansion(query, self.cache_key, "\n".join(out))
        return out
