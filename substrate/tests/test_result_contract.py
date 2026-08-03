"""Tests for the retrieval result contract (Unit 2).

The contract's whole reason to exist: a mid-run degradation the engine KNOWS about must cross
the boundary to the caller as a FIELD, not be discarded (PRINCIPLES.md). These pin (a) the
arm-status derivation from the trace's structured flags, (b) the measured-tier envelope
(exact / lower-bound / honestly-unmeasured), and (c) index_version identity + staleness.

Runnable with plain `python tests/test_result_contract.py` and discovered by pytest.
"""

from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.retrieve.retriever import (  # noqa: E402
    UNMEASURED_REASONS,
    Capability,
    RetrievalResult,
    Trace,
    _capability,
    _measured_tier,
)
from substrate.store.index_store import IndexStore  # noqa: E402

_OLLAMA = "qwen3-embedding:0.6b#raw"


def _cap(trace, *, embed_key=_OLLAMA, emb=True, hyde_model="qwen2.5:7b", hyde=True,
         rerank_model="qwen2.5:7b", rr=True):
    return _capability(trace, embed_key=embed_key, emb_provided=emb,
                       hyde_model=hyde_model, hyde_provided=hyde,
                       rerank_model=rerank_model, rr_provided=rr)


# ---------------------------------------------------------------- tier envelope
#
# `_measured_tier` returns the pair (number, reason). These assert BOTH halves, because a null
# whose reason is wrong is a worse answer than a null with none: the reason is what a caller reads
# out loud, and it is the half nothing else in the payload can cross-check.

def test_expected_mrr_exact_stacks() -> None:
    assert _measured_tier(_OLLAMA, "qwen2.5:7b", "qwen2.5:7b", True, True) == (0.698, None)
    assert _measured_tier(_OLLAMA, "qwen2.5:7b", "qwen2.5:7b", True, False) == (0.603, None)
    assert _measured_tier("apple-nlcontextual", "apple-fm", "apple-fm", True, True) == (0.593, None)
    assert _measured_tier("apple-nlcontextual", "apple-fm", "apple-fm", True, False) == (0.467, None)
    assert _measured_tier("apple-nlcontextual", "apple-fm", "apple-fm", False, False) == (0.343, None)


def test_expected_mrr_wrong_embedder_is_unmeasured() -> None:
    """A different embedder is a different measured number (nomic 0.656, 8b 0.683) — never stamp
    the qwen3 0.698 on it; refuse with None."""
    unknown = (None, "unmeasured_embedder")
    assert _measured_tier("nomic-embed-text#nomic", "qwen2.5:7b", "qwen2.5:7b", True, True) == unknown
    assert _measured_tier("qwen3-embedding:8b#raw", "qwen2.5:7b", "qwen2.5:7b", True, True) == unknown


def test_expected_mrr_swapped_arm_model_is_unmeasured() -> None:
    """A swapped HyDE or rerank model (e.g. the cross-encoder, measured 0.708) is a different
    stack → unmeasured, not the shipped 0.698. The reason names WHICH arm was swapped: "no number"
    is actionable only if the reader knows which model to put back."""
    assert _measured_tier(_OLLAMA, "gemma3:4b", "qwen2.5:7b", True, True) == (
        None, "unmeasured_hyde_model")
    assert _measured_tier(_OLLAMA, "qwen2.5:7b", "dengcao/Qwen3-Reranker-4B", True, True) == (
        None, "unmeasured_rerank_model")


def test_expected_mrr_mixed_provider_is_unmeasured() -> None:
    assert _measured_tier("apple-nlcontextual", "qwen2.5:7b", "apple-fm", True, True) == (
        None, "unmeasured_hyde_model")


def test_expected_mrr_unmeasured_combos_return_none() -> None:
    combo = (None, "unmeasured_arm_combination")
    assert _measured_tier(_OLLAMA, "qwen2.5:7b", "qwen2.5:7b", False, False) == combo  # emb-alone
    assert _measured_tier("apple-nlcontextual", "apple-fm", "apple-fm", False, True) == combo


def test_no_embedder_is_a_different_reason_from_an_unknown_one() -> None:
    """Both return no number and the two are opposite facts: one stack asked for no vector arm,
    the other ran an embedder nothing was ever measured on. Collapsing them would tell a caller to
    pull a model when the real answer is `--no-vector`, or the reverse."""
    assert _measured_tier("", "", "", False, False) == (None, "no_vector_arm")
    assert _measured_tier("bge-m3#raw", "", "", False, False) == (None, "unmeasured_embedder")


def test_every_reason_is_in_the_published_vocabulary() -> None:
    """A token no consumer has an interpretation for reports nothing while looking like an answer.
    `Capability` refuses one, so this pins that the reasons the tier lookup actually PRODUCES are
    inside the set that refusal is written against."""
    produced = {
        _measured_tier(*args)[1]
        for args in (
            ("", "", "", False, False),
            ("bge-m3#raw", "", "", False, False),
            (_OLLAMA, "gemma3:4b", "qwen2.5:7b", True, True),
            (_OLLAMA, "qwen2.5:7b", "cross", True, True),
            (_OLLAMA, "qwen2.5:7b", "qwen2.5:7b", False, False),
        )
    }
    assert produced == set(UNMEASURED_REASONS), produced ^ set(UNMEASURED_REASONS)


# ---------------------------------------------------------------- arm-status derivation

def test_full_ollama_stack() -> None:
    cap = _cap(Trace(vector=15, expanded=True, reranked=True))
    assert cap.embedder == _OLLAMA
    assert cap.embedder_state == "ran"
    assert cap.hyde == "ran" and cap.reranker == "ran"
    assert cap.expected_mrr == 0.698
    assert cap.unmeasured_reason is None, "a measured number needs no excuse"
    assert cap.fallbacks == () and cap.degraded is False


def test_full_apple_stack() -> None:
    cap = _cap(Trace(vector=15, expanded=True, reranked=True),
               embed_key="apple-nlcontextual", hyde_model="apple-fm", rerank_model="apple-fm")
    assert cap.embedder == "apple-nlcontextual"
    assert cap.expected_mrr == 0.593


def test_reranker_gate_skip_stays_in_tier() -> None:
    """An adaptive gate-skip (rerank stage reached, gate declined) is NOT a degradation — the
    measured tier already includes the gate, so quality stays at ceiling."""
    cap = _cap(Trace(vector=15, expanded=True, reranked=False, rerank_reached=True))
    assert cap.reranker == "skipped"
    assert cap.expected_mrr == 0.698
    assert cap.fallbacks == ()


def test_reranker_wired_but_stage_never_reached_is_off() -> None:
    """Pure-lexical path (no fusion) never reaches the rerank stage → 'off', not a phantom
    'skipped' (which implies the gate ran)."""
    cap = _cap(Trace(direct=15, rerank_reached=False))
    assert cap.reranker == "off"


def test_reranker_fell_back_is_degraded() -> None:
    t = Trace(vector=15, expanded=True, reranked=False, reranker_fell_back=True,
              rerank_reached=True, fallback_reasons=["reranker fell back to fused order"])
    cap = _cap(t)
    assert cap.reranker == "fell_back"
    assert cap.expected_mrr == 0.603  # dropped to the measured no-rerank tier
    assert cap.fallbacks == ("reranker fell back to fused order",)
    assert cap.degraded is True


def test_hyde_fell_back() -> None:
    t = Trace(vector=15, expanded=False, reranked=True, hyde_fell_back=True,
              fallback_reasons=["expansion error: boom"])
    cap = _cap(t)
    assert cap.hyde == "fell_back"
    assert cap.expected_mrr is None  # (ollama, no-hyde, rerank) never measured
    assert cap.fallbacks == ("expansion error: boom",)


def test_embedder_fell_back_is_lexical_only() -> None:
    # Realistic: HyDE runs (expanded) BEFORE the embed call, then the embed fails → the vector
    # arm did not contribute, so quality is lexical-only regardless of the (now moot) expansion.
    t = Trace(vector=0, expanded=True, embedder_fell_back=True,
              fallback_reasons=["embedder: connection refused"])
    cap = _cap(t)
    assert cap.embedder == ""            # vector arm did not contribute
    assert cap.embedder_state == "fell_back"
    assert cap.hyde == "ran"             # it did run; its output was just discarded
    assert cap.expected_mrr is None      # lexical-only unmeasured at cohort
    assert cap.unmeasured_reason == "no_vector_arm"
    assert cap.fallbacks == ("embedder: connection refused",)


def test_lexical_only_no_arms_provided() -> None:
    cap = _cap(Trace(direct=15), emb=False, hyde=False, rr=False)
    assert cap.embedder == "" and cap.hyde == "off" and cap.reranker == "off"
    assert cap.embedder_state == "off"
    assert cap.expected_mrr is None and cap.fallbacks == ()
    assert cap.unmeasured_reason == "no_vector_arm"


def test_an_embedder_that_fell_back_is_not_one_nobody_asked_for() -> None:
    """The embedder arm's own gap. `embedder` empties on a fallback, which is byte-identical to
    the key of an arm that was never wired — so the one arm the coverage guard degrades most often
    was the one arm that could not report having degraded. The state word is what separates them;
    asserting a DIFFERENCE rather than a value, because both still send `embedder: ""`."""
    fell = _cap(Trace(vector=0, embedder_fell_back=True,
                      fallback_reasons=["no vectors: 0/595 under 'qwen3'"]))
    never = _cap(Trace(direct=15), emb=False)
    assert fell.embedder == never.embedder == ""
    assert fell.embedder_state != never.embedder_state
    assert (fell.embedder_state, never.embedder_state) == ("fell_back", "off")


def test_two_arms_fall_back_names_both() -> None:
    t = Trace(vector=0, expanded=True, embedder_fell_back=True, hyde_fell_back=True,
              fallback_reasons=["expansion error: x", "embedder: y"])
    cap = _cap(t)
    assert cap.fallbacks == ("expansion error: x", "embedder: y")


def test_fallback_reason_containing_semicolon_stays_one_entry() -> None:
    """The fix for the prose-resplit bug: fallbacks is the structured list, so a reason that
    itself contains '; ' is ONE fallback, not two."""
    t = Trace(vector=0, embedder_fell_back=True,
              fallback_reasons=["embedder: connection reset; retry failed"])
    cap = _cap(t)
    assert cap.fallbacks == ("embedder: connection reset; retry failed",)
    assert len(cap.fallbacks) == 1


# ---------------------------------------------------------------- index_version

def _seed_store(db: Path, docs: list[tuple[str, str]]) -> None:
    from substrate.models import Chunk, Document

    with IndexStore(db) as s:
        for doc_id, sha in docs:
            d = Document(doc_id=doc_id, source_path=f"/x/{doc_id}", source_sha256=sha,
                         source_pages=1, document_class="reference-frozen", title=doc_id)
            c = Chunk(chunk_id=f"{doc_id}#c0", doc_id=doc_id, kind="passage", text="body",
                      path=["Root"], source_sha256=sha)
            s.upsert(d, [c], markdown_path=f"/x/{doc_id}/document.md",
                     markdown_mtime=0.0, markdown_sha256=sha)


def test_index_version_shape_and_stability() -> None:
    tmp = Path(tempfile.mkdtemp())
    try:
        db = tmp / "s.db"
        _seed_store(db, [("doc-a", "a" * 64), ("doc-b", "b" * 64)])
        with IndexStore(db) as s:
            v1 = s.index_version
            assert v1.startswith("v") and ":" in v1
            assert s.index_version == v1  # stable across calls on unchanged docs
    finally:
        shutil.rmtree(tmp)


def test_index_version_changes_with_content() -> None:
    tmp = Path(tempfile.mkdtemp())
    try:
        db1, db2, db3 = tmp / "1.db", tmp / "2.db", tmp / "3.db"
        _seed_store(db1, [("doc-a", "a" * 64)])
        _seed_store(db2, [("doc-a", "c" * 64)])           # same id, different sha (re-ingest)
        _seed_store(db3, [("doc-a", "a" * 64), ("doc-b", "b" * 64)])  # doc added
        with IndexStore(db1) as s1, IndexStore(db2) as s2, IndexStore(db3) as s3:
            assert s1.index_version != s2.index_version    # content change is visible
            assert s1.index_version != s3.index_version    # added doc is visible
    finally:
        shutil.rmtree(tmp)


def test_empty_index_version() -> None:
    tmp = Path(tempfile.mkdtemp())
    try:
        with IndexStore(tmp / "e.db") as s:
            assert s.index_version.endswith(":empty")
    finally:
        shutil.rmtree(tmp)


def test_shipped_objects_match_stacks() -> None:
    """The tier lookup extracts embed_key/hyde_model/rerank_model via getattr from the LIVE
    objects, so a rename of `.key`/`.model` (or dropping the `#raw` suffix) would silently make
    every measured stack resolve to None. Pin the shipped defaults against `_STACKS` so that
    breakage is loud. Constructing these is offline (no daemon contacted)."""
    from substrate.embed.engine import AppleEmbedder, OllamaEmbedder
    from substrate.retrieve.expand import AppleFMExpander, HyDE
    from substrate.retrieve.rerank import AppleFMReranker, LLMReranker
    from substrate.retrieve.retriever import _STACKS

    ok = OllamaEmbedder().key
    assert ok in _STACKS and _STACKS[ok]["hyde"] == HyDE().model
    assert _STACKS[ok]["reranker"] == LLMReranker().model

    ak = AppleEmbedder().key
    assert ak in _STACKS and _STACKS[ak]["hyde"] == AppleFMExpander().model
    assert _STACKS[ak]["reranker"] == AppleFMReranker().model


def _capability_kwargs(**over) -> dict:
    kw = dict(embedder="", embedder_state="off", hyde="off", reranker="off", expected_mrr=None,
              unmeasured_reason="no_vector_arm", cohort="44-case semantic", fallbacks=())
    kw.update(over)
    return kw


def test_a_number_and_a_reason_cannot_both_be_stated() -> None:
    """The two halves of the tier verdict are one decision. A number carrying a reason claims to
    be both measured and not; a null with no reason is the "unmeasured, indistinguishable from a
    bug" state the reason field was added to remove. `_measured_tier` returns them as a pair so
    production cannot reach either, and this pins the door a fixture would otherwise walk in by."""
    for bad in (dict(expected_mrr=0.698), dict(unmeasured_reason=None)):
        try:
            Capability(**_capability_kwargs(**bad))
        except ValueError:
            continue
        raise AssertionError(f"{bad} should not construct a Capability")


def test_an_uninterpretable_reason_is_refused() -> None:
    """A token outside `UNMEASURED_REASONS` reports nothing while looking like an answer — the
    same failure as sending null, wearing the appearance of a claim."""
    try:
        Capability(**_capability_kwargs(unmeasured_reason="because"))
    except ValueError:
        return
    raise AssertionError("an unknown reason token should not construct a Capability")


def test_result_is_frozen_contract() -> None:
    """RetrievalResult/Capability are the contract — immutable so a consumer can't quietly mutate
    a degradation away before passing it on."""
    cap = _cap(Trace(vector=1, expanded=True, reranked=True))
    r = RetrievalResult(passages=[], capability=cap, index_version="v2:x", trace=Trace())
    for obj, field in ((cap, "hyde"), (r, "index_version")):
        try:
            setattr(obj, field, "mutated")
            assert False, "expected frozen dataclass"
        except (AttributeError, TypeError):
            pass


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
