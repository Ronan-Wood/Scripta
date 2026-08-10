"""The retrieval stack, built once and shared by every adapter.

Doc 3a §6 requires an MCP `search` and the equivalent CLI query to return the same passages,
capability and index_version — "if they diverge, logic leaked into a transport". Two adapters
that each wire their own embedder/HyDE/reranker would satisfy that on the day they were written
and drift the first time one gained a flag. So the wiring is one function and both call it.

**An arm that was ASKED for and could not start is not the same as an arm that was off.**
`Capability` reports both as `off`, correctly — nothing ran — but the caller needs to tell "this
configuration was never measured" from "your daemon is down", because only one of them is fixable
by starting Ollama. That distinction is what `unavailable` carries, as a field, to the response.

It carries it TWICE, on purpose and from one source: `unavailable` is prose naming the model and
the host it was looked for at, and `wiring` is the same fact as a per-arm state word derived from
it. The prose is what a human acts on; the state word is what a UI switches on, and without it
every consumer re-parses our sentences. What NEITHER can say is whether a local model server is
absent or merely down — `available()` collapses a refused connection, a timeout and a missing
model into one False — so nothing here reports that, rather than guessing it.

Everything here is local-only and fails soft: an unreachable arm is dropped and named, never
retried against a remote, never silently substituted with a different model. The measured tiers
are model-specific (retriever._STACKS), so a substitution would produce an unmeasured stack
wearing a measured stack's label.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

# The one import this module takes at load time, for the one value it needs before any function
# runs: the rerank default. Everything else here is imported lazily inside `build` on purpose —
# wiring an arm should not cost a caller who never asks for it. `rerank_cross` pulls only stdlib
# plus `substrate.net`/`substrate.retrieve`, so this is a name, not a model.
from substrate.retrieve.rerank_cross import DEFAULT_MODEL as CROSS_MODEL

# The all-Ollama CEILING tier (retriever._STACKS): this embedder key with these models is a MEASURED
# configuration. The defaults are a measured stack precisely so that a caller who changes nothing
# gets the number, and a caller who changes one model gets an honest None.
#
# THE RERANK DEFAULT MOVED TO THE CROSS-ENCODER on 2026-08-10, and the reason is that the argument
# for the listwise arm did not survive the operator's own corpus.
#
# EXPERIMENTS.md §"THE RERANKING AXIS IS SATURATED" measured the two as a tie at 44 cases over
# reference documents — 0.698 against 0.708, "total spread under two cases" — and kept the listwise
# arm because the cross-encoder cost 4,558ms against 385ms. Both halves reverse on the vaults, which
# is the corpus this engine actually answers from. Re-measured 2026-08-10 on `scripta` (v10, 34-case
# gold-vault, 21 lexical / 13 semantic), only the rerank arm varying:
#
#     arm                             semantic MRR    overall MRR    p50 (uncached)
#     none                               0.494          0.613           161 ms
#     listwise qwen2.5:7b (was default)  0.426          0.671         4,050 ms
#     cross-encoder                      0.679          0.683           586 ms
#
# The shipped arm scored BELOW no reranker at all on paraphrased queries, and was the slowest of the
# three. The latency reversal is the surprising half and it is structural rather than incidental:
# the listwise arm asks a 6.4 GB chat model to generate an ordering over 20 candidates, while the
# cross-encoder runs 20 short scoring passes through a 2.5 GB model TRAINED on the relevance
# judgment the other one improvises. The 586ms above includes loading it cold.
#
# This is the change `SubstrateEngine.serveArguments` asked for by refusing to make it itself: "that
# belongs in the shim or in `stack.DEFAULT_RERANK`, where one value serves the CLI, the MCP and this
# app alike." Moving the constant does exactly that, and the number survives the move because
# `retriever._STACKS` gained the cross-encoder's own measured 44-case tier rather than losing one.
DEFAULT_EMBED = "qwen3-embedding:0.6b"
DEFAULT_HYDE = "qwen2.5:7b"
DEFAULT_RERANK = CROSS_MODEL
DEFAULT_POOL = 20
APPLE_POOL = 10      # Apple FM overflows above ~10 candidates (measured)
DEFAULT_CACHE = Path.home() / ".substrate" / "vector-cache.db"


# The three query-time arms, named ONCE. Every `unavailable` entry LEADS with one of these names
# (see `_unreachable`), which is what lets `unavailable_arms` recover the arm structurally instead
# of a consumer parsing our prose — the Swift client was doing exactly that, and a client-side
# parse of an engine sentence is a contract nobody can see break.
ARMS = ("embedder", "hyde", "reranker")

# What `build` managed to do with an arm. A BUILD-time vocabulary, deliberately not the run-time
# one (`Capability.hyde` etc. say ran/skipped/off/fell_back): an arm can be wired and still never
# run, and collapsing the two axes is how "nothing ran" came to mean four different things.
ARM_WIRED = "wired"                # asked for, and it started
ARM_UNAVAILABLE = "unavailable"    # asked for, could not start
ARM_OFF = "off"                    # nobody asked


def _unreachable(arm: str, model: object, where: object) -> str:
    """The ONE spelling of an `unavailable` entry, so the arm name is always its leading token.

    Three hand-written f-strings agreed on that shape by habit; `unavailable_arms` now depends on
    it, and a habit that something depends on is a rule that should be enforced in one place.
    """
    return f"{arm} {model!r} unreachable at {where}"


@dataclass(frozen=True)
class Stack:
    """The three query-time arms, each None when off or unreachable.

    `unavailable` names the arms that were requested and could not start, with where they were
    looked for — the difference between a configuration choice and a broken daemon.
    """

    embedder: object | None = None
    expander: object | None = None
    reranker: object | None = None
    unavailable: tuple[str, ...] = ()

    @property
    def unavailable_arms(self) -> tuple[str, ...]:
        """`unavailable`, as arm NAMES. Derived from the prose rather than stored beside it: two
        fields carrying one fact is how they come to disagree, and the disagreement would be
        invisible because only one of them is human-readable."""
        lead = (e.split(" ", 1)[0] for e in self.unavailable)
        return tuple(a for a in lead if a in ARMS)

    @property
    def wiring(self) -> dict[str, str]:
        """Per-arm BUILD state — the one thing `Capability` structurally cannot say.

        An arm that could not start is handed to `retrieve()` as None, which is byte-identical to
        an arm nobody asked for, so the capability envelope reports `off` for both. This is where
        that distinction still exists, and it is a field so it survives the trip to a caller.

        Every arm appears, always, `off` included: a map that listed only the interesting arms
        would make "hyde is missing from this dict" mean either "off" or "this build predates the
        field", which is the disappearing-field defect the whole envelope is written to avoid.
        """
        bad = set(self.unavailable_arms)
        live = {"embedder": self.embedder, "hyde": self.expander, "reranker": self.reranker}
        return {
            arm: (ARM_WIRED if live[arm] is not None
                  else ARM_UNAVAILABLE if arm in bad else ARM_OFF)
            for arm in ARMS
        }


def build(
    *,
    embed_model: str | None = DEFAULT_EMBED,
    hyde_model: str | None = DEFAULT_HYDE,
    rerank_model: str | None = DEFAULT_RERANK,
    embed_style: str = "auto",
    pool: int | None = None,
    cache_path: str | Path = DEFAULT_CACHE,
    lexical_only: bool = False,
) -> Stack:
    """Wire the query-time arms that are actually reachable.

    `lexical_only` skips all three — the zero-dependency path, and the one the eval calls a
    catastrophic 0.343 tier. Passing None for any single model disables that arm alone, which is a
    different statement from it being unreachable and is reported as such: an arm nobody asked for
    is NOT "unavailable", and conflating the two would erase the distinction `unavailable` exists
    to preserve.

    Vector COMPLETENESS is deliberately not checked here — it is a property of an index, not of a
    stack, and one stack serves many scopes. `_retrieve` checks it per query and degrades.
    """
    if lexical_only or not (embed_model or hyde_model or rerank_model):
        return Stack()

    unavailable: list[str] = []
    cache = None

    def _cache():
        """Built ONLY when a generator arm asks for it. The embedder does not use it, so eagerly
        constructing one made every plain `substrate query` create a database in the user's home
        directory as a side effect of asking a question."""
        nonlocal cache
        if cache is None:
            from substrate.embed.cache import VectorCache

            resolved = Path(cache_path).expanduser()
            resolved.parent.mkdir(parents=True, exist_ok=True)
            cache = VectorCache(str(resolved))
        return cache

    embedder = None
    if embed_model:
        from substrate.embed.engine import AppleEmbedder, OllamaEmbedder

        cand = (AppleEmbedder() if embed_model.startswith("apple")
                else OllamaEmbedder(model=embed_model, prefix_style=embed_style))
        embedder = cand if cand.available() else None
        if embedder is None:
            unavailable.append(_unreachable("embedder", embed_model,
                                            getattr(cand, "host", "the local daemon")))

    expander = None
    if hyde_model:
        from substrate.retrieve.expand import AppleFMExpander, HyDE

        hc = (AppleFMExpander(cache=_cache()) if hyde_model in ("apple", "apple-fm")
              else HyDE(model=hyde_model, cache=_cache()))
        expander = hc if hc.available() else None
        if expander is None:
            unavailable.append(_unreachable("hyde", hyde_model,
                                            getattr(hc, "host", "the local daemon")))

    reranker = None
    if rerank_model:
        from substrate.retrieve.rerank_cross import DEFAULT_MODEL as CROSS_MODEL

        # The real model tag is matched alongside the sentinels, because `--rerank-model
        # dengcao/Qwen3-Reranker-4B:Q4_K_M` is the obvious thing to type and used to fall through
        # to the LISTWISE branch, where it IS reachable: the chat endpoint answers, the reply
        # parses to the identity permutation, and the query returns fused order under a
        # `reranker: ran` label with no fallback recorded. A wrong arm that reports success is
        # worse than one that refuses. "cross-encoder" is matched for the same reason — it is the
        # CLI flag's spelling, and it otherwise reported a daemon fault for a bad arm name.
        # The bare repo name matches too: `dengcao/Qwen3-Reranker-4B` is the `:latest` spelling
        # `CrossEncoderReranker.available()` already honours, and it missed this test while
        # `LLMReranker.available()` accepted it on a family-prefix match — so the one spelling most
        # likely to be typed from memory routed to the wrong arm and reported success.
        if rerank_model in ("cross", "cross-encoder", CROSS_MODEL, CROSS_MODEL.split(":")[0]):
            from substrate.retrieve.rerank_cross import POOL as CROSS_POOL
            from substrate.retrieve.rerank_cross import CrossEncoderReranker

            # A SENTINEL, not a model name — same shape as the "apple" branch below, and for the
            # same reason: the arm is the choice, its measured model is not the caller's to guess.
            # Whether the latency is worth it is corpus-dependent and measured in both directions;
            # EXPERIMENTS.md holds both runs. That is why this is a per-caller arm, not a default.
            #
            # `gate` is stated rather than defaulted because it is the one non-obvious choice here,
            # and the two corpora disagree about it: -0.008 (gate hurts) at 44 reference cases,
            # but on the vaults gate-off loses two lexical cases and gains nothing semantic. On
            # is right for the shared path by measurement, not by inheriting the dataclass default.
            # `eval --cross-encoder --no-gate` reaches the other configuration.
            rc = CrossEncoderReranker(model=CROSS_MODEL, cache=_cache(), gate=True,
                                      pool=CROSS_POOL if pool is None else pool)
        elif rerank_model in ("apple", "apple-fm"):
            from substrate.retrieve.rerank import AppleFMReranker

            # Apple FM overflows above ~10 candidates (measured): handed 20 it returns empty
            # replies and every query falls back to fused order — a silent no-op wearing a
            # reranked label. `pool=None` means "this arm's own default"; an explicit value is
            # honoured. Using DEFAULT_POOL as the sentinel meant a caller asking for exactly the
            # measured 20 silently got 10 instead.
            rc = AppleFMReranker(pool=APPLE_POOL if pool is None else pool, cache=_cache())
        else:
            from substrate.retrieve.rerank import LLMReranker

            rc = LLMReranker(model=rerank_model, pool=DEFAULT_POOL if pool is None else pool,
                             cache=_cache())
        reranker = rc if rc.available() else None
        if reranker is None:
            # The ARM's model, not the caller's word for it: `cross` is a sentinel, and the whole
            # value of naming an unreachable arm is that the reader can act on it — which means
            # printing the tag they have to pull, not the alias they typed.
            unavailable.append(_unreachable("reranker", getattr(rc, "model", rerank_model),
                                            getattr(rc, "host", "the local daemon")))

    return Stack(embedder=embedder, expander=expander, reranker=reranker,
                 unavailable=tuple(unavailable))
