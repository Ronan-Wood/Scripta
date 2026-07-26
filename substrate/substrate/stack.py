"""The retrieval stack, built once and shared by every adapter.

Doc 3a §6 requires an MCP `search` and the equivalent CLI query to return the same passages,
capability and index_version — "if they diverge, logic leaked into a transport". Two adapters
that each wire their own embedder/HyDE/reranker would satisfy that on the day they were written
and drift the first time one gained a flag. So the wiring is one function and both call it.

**An arm that was ASKED for and could not start is not the same as an arm that was off.**
`Capability` reports both as `off`, correctly — nothing ran — but the caller needs to tell "this
configuration was never measured" from "your daemon is down", because only one of them is fixable
by starting Ollama. That distinction is what `unavailable` carries, as a field, to the response.

Everything here is local-only and fails soft: an unreachable arm is dropped and named, never
retried against a remote, never silently substituted with a different model. The measured tiers
are model-specific (retriever._STACKS), so a substitution would produce an unmeasured stack
wearing a measured stack's label.
"""

from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path

# The all-Ollama CEILING tier (retriever._STACKS): this embedder key with these two models is the
# 44-case 0.698 configuration. The defaults are the measured stack precisely so that a caller who
# changes nothing gets the number, and a caller who changes one model gets an honest None.
DEFAULT_EMBED = "qwen3-embedding:0.6b"
DEFAULT_HYDE = "qwen2.5:7b"
DEFAULT_RERANK = "qwen2.5:7b"
DEFAULT_POOL = 20
DEFAULT_CACHE = Path.home() / ".substrate" / "vector-cache.db"


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


def build(
    *,
    embed_model: str | None = DEFAULT_EMBED,
    hyde_model: str | None = DEFAULT_HYDE,
    rerank_model: str | None = DEFAULT_RERANK,
    embed_style: str = "auto",
    pool: int = DEFAULT_POOL,
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
            unavailable.append(f"embedder {embed_model!r} unreachable at "
                               f"{getattr(cand, 'host', 'the local daemon')}")

    expander = None
    if hyde_model:
        from substrate.retrieve.expand import AppleFMExpander, HyDE

        hc = (AppleFMExpander(cache=_cache()) if hyde_model in ("apple", "apple-fm")
              else HyDE(model=hyde_model, cache=_cache()))
        expander = hc if hc.available() else None
        if expander is None:
            unavailable.append(f"hyde {hyde_model!r} unreachable at "
                               f"{getattr(hc, 'host', 'the local daemon')}")

    reranker = None
    if rerank_model:
        if rerank_model in ("apple", "apple-fm"):
            from substrate.retrieve.rerank import AppleFMReranker

            # Apple FM overflows above ~10 candidates (measured): handed 20 it returns empty
            # replies and every query falls back to fused order — a silent no-op wearing a
            # reranked label. Its own default stands unless the pool was set explicitly.
            rc = AppleFMReranker(pool=pool if pool != DEFAULT_POOL else 10, cache=_cache())
        else:
            from substrate.retrieve.rerank import LLMReranker

            rc = LLMReranker(model=rerank_model, pool=pool, cache=_cache())
        reranker = rc if rc.available() else None
        if reranker is None:
            unavailable.append(f"reranker {rerank_model!r} unreachable at "
                               f"{getattr(rc, 'host', 'the local daemon')}")

    return Stack(embedder=embedder, expander=expander, reranker=reranker,
                 unavailable=tuple(unavailable))
