"""A wired embedder over an unembedded index must NOT report a measured tier.

The defect these pin is PRINCIPLES.md's second incident in its purest form. `vector_search`
returns [] on a model with no stored vectors — no exception, nothing to catch — so a full stack
wired over an index that was composed but never embedded produced:

    capability: embedder=qwen3-embedding:0.6b#raw · hyde=ran · rerank=ran · expected_mrr=0.698

over a run where the vector arm contributed nothing. Every field is well-formed. The thing that
would have failed inspection is the thing that did not travel.

The check is COMPLETENESS, not presence: 256 vectors of 1811 after a timeout passes `> 0` and
reports a confident number computed on 14% of the corpus.

`test_complete_vectors_keeps_the_measured_tier` is the one that stops this suite being
tautological — a guard that always degraded would pass every other test here while destroying
the measured path. It asserts the 0.698 tier SURVIVES when the vectors are actually there.

Runnable with plain `python tests/test_vector_coverage.py`; discovered by pytest if added.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.models import Chunk, Document  # noqa: E402
from substrate.retrieve.retriever import retrieve  # noqa: E402
from substrate.store.index_store import IndexStore  # noqa: E402

# The exact all-Ollama measured stack (retriever._STACKS): this key WITH these two models is the
# only combination that yields 0.698, which is what makes a false 0.698 possible at all.
_KEY = "qwen3-embedding:0.6b#raw"
_HYDE = "qwen2.5:7b"
_DIM = 4


class _Embedder:
    """Always reachable, always returns a valid vector — the failure under test is in the INDEX,
    not the daemon. A fake that failed would exercise the pre-existing fall-back path instead."""

    key = _KEY
    model = "qwen3-embedding:0.6b"

    def embed_query(self, text: str) -> list[float]:
        return [1.0, 0.0, 0.0, 0.0]


class _Expander:
    model = _HYDE

    def expand(self, q: str) -> str:
        return f"{q} — a paragraph in domain vocabulary that the answer would appear in"


class _Reranker:
    model = _HYDE
    fallback_queries = 0

    def rerank(self, q: str, hits: list) -> tuple[list, bool]:
        return hits, True


def _fresh_db() -> str:
    return str(Path(tempfile.mkdtemp()) / "index.db")


def _seed(store: IndexStore, n: int = 3) -> list[str]:
    """n single-chunk documents sharing one query token. Returns the chunk ids, in order."""
    ids = []
    for i in range(n):
        doc_id = f"d{i}"
        text = f"replication lag body number {i}"
        doc = Document(doc_id=doc_id, source_path=f"/{doc_id}.md", source_sha256="s" * 8,
                       source_pages=1, document_class="reference-frozen", title=doc_id,
                       status="active")
        ch = Chunk(chunk_id=f"{doc_id}#c0", doc_id=doc_id, kind="passage", text=text,
                   path=["Root", doc_id], level=2, n_chars=len(text),
                   document_class="reference-frozen")
        store.upsert(doc, [ch], markdown_path=f"/{doc_id}.md", markdown_mtime=0.0,
                     markdown_sha256="m" * 8)
        ids.append(ch.chunk_id)
    return ids


def _full_stack(store: IndexStore):
    return retrieve(store, "replication lag", k=3, embedder=_Embedder(),
                    expander=_Expander(), reranker=_Reranker())


# ---------------------------------------------------------------- the store helper

def test_vector_coverage_reports_both_counts() -> None:
    with IndexStore(_fresh_db()) as s:
        ids = _seed(s, 3)
        assert s.vector_coverage(_KEY) == (0, 3)
        s.store_vectors([(ids[0], [1.0, 0.0, 0.0, 0.0])], _KEY)
        assert s.vector_coverage(_KEY) == (1, 3)


def test_orphaned_vectors_do_not_count_as_coverage() -> None:
    """A vector whose chunk is gone is unreachable by any query. Counting it could satisfy
    `n >= total` on a partly-embedded index — reported complete, with a measured MRR on top,
    which is the exact failure this guard exists to stop. Both delete paths clean vectors up
    today, so this is not reachable through the engine; the JOIN makes it structural rather than
    dependent on every future delete path remembering."""
    with IndexStore(_fresh_db()) as s:
        ids = _seed(s, 2)
        s.store_vectors([(cid, [1.0, 0.0, 0.0, 0.0]) for cid in ids], _KEY)
        # Orphans, planted directly: the state a missed cleanup would leave behind.
        s.store_vectors([(f"ghost{i}", [1.0, 0.0, 0.0, 0.0]) for i in range(5)], _KEY)
        assert s.vector_coverage(_KEY) == (2, 2), "orphans must not inflate the numerator"


def test_vectors_under_another_key_do_not_count() -> None:
    """The orphaned-space failure: a key change leaves vectors present but unreachable. Counting
    them would report full coverage for a space the query can never match against."""
    with IndexStore(_fresh_db()) as s:
        ids = _seed(s, 2)
        for cid in ids:
            s.store_vectors([(cid, [1.0, 0.0, 0.0, 0.0])], "nomic-embed-text#nomic")
        assert s.vector_coverage(_KEY) == (0, 2)


# ---------------------------------------------------------------- the degradation

def test_no_vectors_refuses_the_measured_tier() -> None:
    with IndexStore(_fresh_db()) as s:
        _seed(s, 3)
        r = _full_stack(s)
        # The whole point: no number, because the stack that would have earned it did not run.
        assert r.capability.expected_mrr is None, r.capability
        assert r.capability.embedder == "", r.capability
        assert r.capability.degraded
        assert any("no vectors" in f and "0/3" in f and _KEY in f
                   for f in r.capability.fallbacks), r.capability.fallbacks
        # Lexical still answers — this degrades, it does not refuse. `eval` is the caller that
        # must refuse, because it publishes the number rather than answering a question.
        assert r.passages, "lexical retrieval should still return results"


def test_an_empty_index_is_not_full_coverage() -> None:
    """0 >= 0 is true, so a bare completeness comparison called an EMPTY index fully covered and
    let the measured tier through on a store with nothing in it. Reachable whenever a registered
    db exists but holds nothing: an interrupted compose, a clear(), a reconcile that removed every
    doc. Zero chunks is the absence of coverage, not the completion of it."""
    with IndexStore(_fresh_db()) as s:
        assert s.vector_coverage(_KEY) == (0, 0)
        r = _full_stack(s)
        assert r.capability.expected_mrr is None, r.capability
        assert r.capability.embedder == ""
        assert any("no chunks" in f for f in r.capability.fallbacks), r.capability.fallbacks


def test_partial_vectors_refuse_the_measured_tier_too() -> None:
    """Presence is not completeness. One vector of three is the shape that reported a confident
    MRR over 14% of a corpus."""
    with IndexStore(_fresh_db()) as s:
        ids = _seed(s, 3)
        s.store_vectors([(ids[0], [1.0, 0.0, 0.0, 0.0])], _KEY)
        r = _full_stack(s)
        assert r.capability.expected_mrr is None, r.capability
        assert r.capability.embedder == ""
        assert any("INCOMPLETE" in f and "1/3" in f for f in r.capability.fallbacks), \
            r.capability.fallbacks


def test_degraded_stack_reports_arms_off_not_ran() -> None:
    """A dead vector arm must not leave HyDE and rerank claiming they ran. HyDE only ever feeds
    the vector query, and the rerank stage is never reached — reporting either as `ran` would
    describe a pipeline that did not execute."""
    with IndexStore(_fresh_db()) as s:
        _seed(s, 3)
        cap = _full_stack(s).capability
        assert cap.hyde == "off", cap
        assert cap.reranker == "off", cap


# ---------------------------------------------------------------- the guard is not a no-op

def test_complete_vectors_keeps_the_measured_tier() -> None:
    """The mutation guard for this whole file. A check that degraded unconditionally would pass
    every test above and silently destroy the measured path; this fails if it does."""
    with IndexStore(_fresh_db()) as s:
        ids = _seed(s, 3)
        s.store_vectors([(cid, [1.0, 0.0, 0.0, 0.0]) for cid in ids], _KEY)
        assert s.vector_coverage(_KEY) == (3, 3)
        r = _full_stack(s)
        assert not r.capability.degraded, r.capability.fallbacks
        assert r.capability.embedder == _KEY, r.capability
        assert r.capability.hyde == "ran", r.capability
        assert r.capability.reranker == "ran", r.capability
        assert r.capability.expected_mrr == 0.698, r.capability


if __name__ == "__main__":
    _tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    _failed = 0
    for _t in _tests:
        try:
            _t()
            print(f"  PASS  {_t.__name__}")
        except Exception as e:  # noqa: BLE001
            _failed += 1
            print(f"  FAIL  {_t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(_tests) - _failed}/{len(_tests)} passed")
    raise SystemExit(1 if _failed else 0)
