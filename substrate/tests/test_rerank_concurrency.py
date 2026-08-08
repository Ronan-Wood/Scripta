"""The cross-encoder pool is scored concurrently, and that must change NOTHING but the wall clock.

WHY THIS FILE EXISTS. Ask took 17,274ms against 286ms without the generator arms (measured
2026-08-06 on the operator's `cbre` scope), and the bulk of it was a pool of 20 candidates scored
one 7B generation at a time. Serial was never a requirement — a pointwise score is a function of
(query, ONE document), which is why the cache is keyed per pair — so the pool can be scored at once.

The whole risk of that change is ORDER. Results must land by index, never by completion order, or a
faster daemon response silently reranks the pool. Every test here holds the ranking fixed while the
timing varies.
"""

from __future__ import annotations

import sys
import time
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from substrate.retrieve import rerank_cross  # noqa: E402
from substrate.store.index_store import Hit  # noqa: E402


def _hit(i: int) -> Hit:
    return Hit(chunk_id=f"c{i}", doc_id=f"d{i}", kind="passage", text=f"body {i}", path_str="",
               path_depth=0, page_start=None, page_label_start=None, n_chars=6, score=0.0,
               document_class="reference-frozen", version=None, title=None, prev_id=None,
               next_id=None)


def _reranker(score_for, **kw) -> rerank_cross.CrossEncoderReranker:
    r = rerank_cross.CrossEncoderReranker(model="fake", gate=False, cache=None, **kw)
    r._score = lambda query, text: score_for(text)  # type: ignore[method-assign]
    return r


def test_completion_order_cannot_reorder_the_pool() -> None:
    """THE ONE THAT MATTERS. The last candidate answers instantly and the first is slow; if results
    were collected as they completed, the fast one would be promoted. Only indices 3 and 7 are
    relevant, and they must come back in that order regardless of who finished first."""
    relevant = {"body 3", "body 7"}

    def score(text: str) -> float:
        # Earlier candidates are slower, so completion order is the REVERSE of pool order.
        time.sleep(0.02 * (10 - int(text.split()[1])))
        return rerank_cross.YES if text in relevant else rerank_cross.NO

    hits = [_hit(i) for i in range(10)]
    out, changed = _reranker(score).rerank("q", hits)
    assert changed
    assert [h.chunk_id for h in out[:2]] == ["c3", "c7"], "promoted in POOL order, not finish order"


def test_it_matches_what_a_serial_pass_would_have_produced() -> None:
    """Order-identity stated directly: the concurrent result equals the sort over per-index scores,
    which is what the serial loop computed."""
    def score(text: str) -> float:
        return rerank_cross.YES if int(text.split()[1]) % 3 == 0 else rerank_cross.NO

    hits = [_hit(i) for i in range(9)]
    out, _ = _reranker(score).rerank("q", hits)
    expected = [f"c{i}" for i in range(9) if i % 3 == 0] + [f"c{i}" for i in range(9) if i % 3]
    assert [h.chunk_id for h in out] == expected


def test_one_transport_failure_fails_open_to_fused_order() -> None:
    """A dead daemon reaches the caller as a degradation, not as a partial rerank — unchanged from
    the serial version, and easy to lose when results arrive out of order."""
    def score(text: str) -> float | None:
        return None if text == "body 4" else rerank_cross.YES

    hits = [_hit(i) for i in range(8)]
    r = _reranker(score)
    out, changed = r.rerank("q", hits)
    assert not changed
    assert [h.chunk_id for h in out] == [f"c{i}" for i in range(8)]
    assert r.fallback_queries == 1


def test_the_budget_bounds_the_QUERY_and_discards_partial_scores() -> None:
    """Ranking on whichever candidates happened to finish is an artefact of daemon scheduling."""
    def score(text: str) -> float:
        time.sleep(0.5)
        return rerank_cross.YES

    hits = [_hit(i) for i in range(6)]
    r = _reranker(score, budget_s=0.05)
    out, changed = r.rerank("q", hits)
    assert not changed
    assert [h.chunk_id for h in out] == [f"c{i}" for i in range(6)]
    assert r.budget_exhaustions == 1
