"""The result contract crosses the boundary intact, and nothing withheld is silent.

This is the property the MCP surface exists to preserve. A passage that arrives without its
spine is not a smaller answer, it is a different one: a model that cannot see
`confidence=proposed` reads an unbuilt design as settled, and one that cannot see
`statuses_excluded` concludes the archived note it needed does not exist.

So these tests assert the ABSENCE of absence. Every spine field is present on every passage
regardless of value — `unstated`, `null` and `[]` are emitted exactly like any other value,
because a field that disappears when it has nothing interesting to say is prose, and its
disappearance is indistinguishable from nobody having checked.

The key-set assertions are deliberately exact rather than a spot-check of two fields: a renderer
that silently stops emitting `supersedes` produces output that passes every plausible-looking
test while breaking the one guarantee the caller relies on.

Runnable with plain `python tests/test_render.py`; discovered by pytest if added.
"""

from __future__ import annotations

import json
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import render  # noqa: E402
from substrate.retrieve.retriever import Capability, RetrievalResult, Trace  # noqa: E402
from substrate.spine import INCLUDED_STATUSES, STATUSES  # noqa: E402
from substrate.store.index_store import Hit  # noqa: E402

# The contract, written out. A passage MUST carry every one of these — not most of them.
PASSAGE_KEYS = {
    "expand_ref", "citation", "path", "page", "n_chars", "document_class",
    "status", "doc_type", "confidence", "domains", "vault", "supersedes",
    "snippet", "text", "truncated",
}
ENVELOPE_KEYS = {
    "scope", "db", "query", "passages", "outline_records", "retrieval_mode", "filters",
    "index_version", "refresh",
}
# What the unattended refresh agent last managed on this scope. `index_version` says what the
# index was BUILT from and stops there, so a scope whose recompose refused kept answering from
# the superseded index in an envelope byte-identical to a healthy run.
REFRESH_KEYS = {"known", "outcome", "attempted", "succeeded", "frozen", "frozen_since", "note"}
MODE_KEYS = {"embedder", "embedder_state", "hyde", "reranker", "expected_mrr", "unmeasured_reason",
             "cohort", "degraded", "fallbacks", "unavailable", "health"}
# Whether the arms could START — a different axis from what they did, and the one the prose in
# `unavailable` was the only carrier of.
HEALTH_KEYS = {"known", "state", "arms", "note"}
FILTER_KEYS = {"statuses_included", "statuses_excluded", "sources_excluded", "doc_type",
               "document_class", "notes"}

LONG = ("A proposed design that was never built. " * 40).strip()


def _hit(**over) -> Hit:
    """A hit with every spine field at its LEAST interesting value, so the tests exercise the
    case where a lazy renderer would be tempted to drop the key."""
    base = dict(
        chunk_id="note-a#c00000", doc_id="note-a", kind="passage", text=LONG,
        path_str="Note A > Section", path_depth=2, page_start=None, page_label_start=None,
        n_chars=len(LONG), score=1.0, document_class="reference-frozen", version=None,
        title="Note A", prev_id=None, next_id=None,
        status="active", doc_type="explanation", confidence="unstated",
        supersedes=[], domains=[], vault=None,
    )
    base.update(over)
    return Hit(**base)


def _cap(**over) -> Capability:
    """A lexical-only capability — the emptiest one, so the tests exercise the values a renderer
    is most tempted to drop. `unmeasured_reason` is stated because `Capability` refuses a null
    number with no reason: the two halves of the tier verdict are one decision."""
    kw = dict(embedder="", embedder_state="off", hyde="off", reranker="off", expected_mrr=None,
              unmeasured_reason="no_vector_arm", cohort="44-case semantic", fallbacks=())
    kw.update(over)
    return Capability(**kw)


def _result(hits=None, *, cap=None, outlines=None) -> RetrievalResult:
    return RetrievalResult(
        passages=list(hits if hits is not None else [_hit()]),
        capability=cap or _cap(),
        index_version="v6:deadbeef",
        trace=Trace(),
        outlines=list(outlines or []),
    )


# An empty directory standing in for the registry, so `refresh` is read from a location this test
# owns. Without it these tests read the OPERATOR's ~/.substrate/refresh.json and their result
# depends on what a launchd job happened to record five minutes ago — an ambient dependency that
# would pass today and fail on the first machine where the agent had touched a scope called demo.
_ISOLATED = str(Path(tempfile.mkdtemp(prefix="substrate-render-")) / "scopes.toml")


def _payload(result=None, **over) -> dict:
    kw = dict(scope="demo", query="q", statuses=INCLUDED_STATUSES, include_sources=False,
              registry=_ISOLATED)
    kw.update(over)
    return render.search_payload(result or _result(), **kw)


# ---------------------------------------------------------------- the spine survives

def test_every_spine_field_is_present_even_at_its_emptiest() -> None:
    p = _payload()["passages"][0]
    assert set(p) == PASSAGE_KEYS, set(p) ^ PASSAGE_KEYS
    # The values a conditional renderer would have dropped.
    assert p["confidence"] == "unstated"
    assert p["supersedes"] == []
    assert p["domains"] == []
    assert p["vault"] is None
    assert p["page"] is None


def test_proposed_confidence_crosses() -> None:
    """The named failure: an active-but-proposed note read as a settled decision."""
    p = _payload(_result([_hit(status="active", confidence="proposed", doc_type="decision")]))
    assert p["passages"][0]["confidence"] == "proposed"
    assert p["passages"][0]["status"] == "active"


def test_a_conversation_passage_says_it_is_one() -> None:
    """The BLOCKING one. `conversation` is the class default retrieval withholds, and a passage
    that arrived without its class was indistinguishable from default corpus — so a transcript
    fragment rendered as settled knowledge, which is precisely what withholding the class exists
    to prevent: confidence varies WITHIN a transcript, and a mid-conversation passage may be
    reasoning the same session abandoned four turns later."""
    p = _payload(_result([_hit(document_class="conversation")]))["passages"][0]
    assert p["document_class"] == "conversation"
    assert _payload()["passages"][0]["document_class"] == "reference-frozen"


def test_an_unclassed_row_is_not_relabelled_reference_frozen() -> None:
    """Absence and a default are different facts. A silent `reference-frozen` here would be right
    about two-thirds of the corpus by luck and would repeat, one layer further from the evidence,
    the ingest-time defaulting that relabelled six migrated conversations under a green compose.

    What null does NOT claim is that the note declared nothing: the markdown reader already
    defaults an undeclared `class:` before the store sees it, so that distinction is gone long
    before this layer and no field here can honestly re-create it."""
    p = _payload(_result([_hit(document_class="")]))["passages"][0]
    assert p["document_class"] is None


def test_supersession_link_crosses() -> None:
    """A superseded note is never retrieved directly; the ONLY way its identity reaches a caller
    is this field on the live note that replaced it (Doc 2 §6)."""
    p = _payload(_result([_hit(supersedes=["old-decision", "older-decision"])]))
    assert p["passages"][0]["supersedes"] == ["old-decision", "older-decision"]


def test_envelope_shape() -> None:
    env = _payload()
    assert set(env) == ENVELOPE_KEYS, set(env) ^ ENVELOPE_KEYS
    assert set(env["retrieval_mode"]) == MODE_KEYS
    assert set(env["retrieval_mode"]["health"]) == HEALTH_KEYS
    assert set(env["filters"]) == FILTER_KEYS
    assert set(env["refresh"]) == REFRESH_KEYS
    assert env["index_version"] == "v6:deadbeef"
    assert env["scope"] == "demo"


def test_the_envelope_carries_a_refresh_verdict_without_being_asked() -> None:
    """`refresh` is READ by `search_payload`, not passed in. An adapter that had to remember to
    attach it is an adapter that will one day not — and the field exists precisely to survive the
    person who forgets to look. This asserts it arrives on a bare call.

    `frozen: null` here rather than false: this fixture has no refresh record, and absence of a
    record is absence of evidence. A default of `false` would make the healthy-looking state the
    one that requires nothing to have happened.
    """
    r = _payload()["refresh"]
    assert r["known"] is False
    assert r["frozen"] is None, "no record became a clean bill of health"
    assert r["note"], "the condition crossed as a bare null with nothing explaining it"


def test_the_envelope_reads_no_clock() -> None:
    """Doc 3a §6 compares the CLI's envelope to the server's as whole dicts, produced by two
    processes at two instants. Any clock-derived field would make that equality flaky, and a flake
    there reads as the divergence the shared render layer exists to prevent.

    Rendering twice in a row proves nothing on its own — microseconds apart, an `age_days` or
    `hours_since_success` field would agree and sail through, and those are exactly the fields
    someone would add. So this pins the key set instead: a clock-derived value has to LIVE
    somewhere, and there is nowhere for it to go that this assertion does not see. That is the
    A17-fixture rule — a check that cannot distinguish the world where it holds from the world
    where it does not manufactures confidence.
    """
    result = _result()
    assert _payload(result) == _payload(result)
    assert set(_payload(result)["refresh"]) == REFRESH_KEYS, "a new key appeared in the block"
    assert set(_payload(result)) == ENVELOPE_KEYS, "a new key appeared in the envelope"


def test_outline_records_carry_the_same_spine() -> None:
    env = _payload(_result(outlines=[_hit(chunk_id="note-a#o00000", kind="outline")]))
    rec = env["outline_records"][0]
    assert rec["kind"] == "outline"
    assert PASSAGE_KEYS <= set(rec), PASSAGE_KEYS - set(rec)


# ---------------------------------------------------------------- payload discipline

def test_snippet_first_does_not_ship_the_passage() -> None:
    p = _payload()["passages"][0]
    assert p["text"] is None, "a search result must not carry full passage text"
    assert len(p["snippet"]) <= render.SNIPPET_CHARS
    assert p["truncated"] is True
    assert p["n_chars"] == len(LONG), "the caller must be able to see how much was withheld"


def test_short_passage_is_not_marked_truncated() -> None:
    """`truncated` must mean something. Always-true is the same defect as always-false."""
    p = _payload(_result([_hit(text="short", n_chars=5)]))["passages"][0]
    assert p["snippet"] == "short"
    assert p["truncated"] is False


def test_search_and_expand_share_one_passage_shape() -> None:
    """The docstring promised "same envelope … so a consumer never has to reconcile two different
    passage shapes" while emitting `text` only on expand and `snippet` only on search — the same
    disappearing-field defect the spine fields are emitted unconditionally to avoid."""
    hit = _hit()
    search = render.passage(hit, scope="demo")
    expanded = render.passage(hit, scope="demo", full=True)
    assert set(search) == set(expanded) == PASSAGE_KEYS
    assert search["text"] is None and expanded["text"] == LONG
    assert search["snippet"] == expanded["snippet"], "the snippet is the same cut either way"
    # `truncated` means content was withheld from THIS payload.
    assert search["truncated"] is True and expanded["truncated"] is False


def test_snippet_first_is_actually_cheaper() -> None:
    """The discipline is the point, not the label — assert the saving is real and large."""
    hits = [_hit(chunk_id=f"n{i}#c0") for i in range(5)]
    snippet_bytes = len(json.dumps(_payload(_result(hits))))
    full_bytes = sum(len(h.text) for h in hits)
    assert snippet_bytes < full_bytes, (snippet_bytes, full_bytes)


# ---------------------------------------------------------------- expand_ref

def test_expand_ref_round_trips() -> None:
    ref = _payload()["passages"][0]["expand_ref"]
    assert render.parse_expand_ref(ref) == ("demo", "note-a#c00000")


def test_expand_ref_is_scope_qualified() -> None:
    """One server serves every scope. A bare chunk_id would be resolved against whichever index
    the callee guessed, and a wrong guess returns a well-formed passage from the wrong vault."""
    assert _payload()["passages"][0]["expand_ref"].startswith("demo/")


def test_malformed_ref_refuses() -> None:
    for bad in ("no-separator", "/leading", "trailing/", ""):
        try:
            render.parse_expand_ref(bad)
        except render.RefError:
            continue
        raise AssertionError(f"{bad!r} should not parse as an expand_ref")


# ---------------------------------------------------------------- what was withheld

def test_default_filters_name_what_was_excluded() -> None:
    f = _payload()["filters"]
    assert f["statuses_included"] == sorted(INCLUDED_STATUSES)
    assert f["statuses_excluded"] == ["archived", "superseded"]
    assert f["sources_excluded"] is True


def test_unfiltered_scan_excludes_nothing() -> None:
    f = _payload(statuses=None)["filters"]
    assert f["statuses_included"] == sorted(STATUSES)
    assert f["statuses_excluded"] == []


def test_include_sources_is_reported() -> None:
    assert _payload(include_sources=True)["filters"]["sources_excluded"] is False


def test_doc_type_filter_is_reported() -> None:
    assert _payload(doc_type="decision")["filters"]["doc_type"] == "decision"


def test_document_class_is_its_own_axis() -> None:
    """`doc_type` (the note's job) and `document_class` (what kind of artifact it is) are
    different axes. Reporting a class under the doc_type key put an illegal value on that axis
    and left the filter that HAD been applied unreported — both directions wrong at once."""
    f = _payload(document_class="conversation")["filters"]
    assert f["document_class"] == "conversation"
    assert f["doc_type"] is None


def test_sources_excluded_answers_the_question_not_the_sql() -> None:
    """The field means "could a conversation passage be in these results", not "did one SQL
    clause run". Those come apart under a class filter: the store's source exclusion stands down,
    but a filter naming `reference-frozen` still withholds every conversation BY BEING the filter.
    Reporting false there said "nothing was withheld" about content that was."""
    assert _payload(document_class="reference-frozen")["filters"]["sources_excluded"] is True
    # Asking for the source class outright is the one case where they really are not withheld.
    assert _payload(document_class="conversation")["filters"]["sources_excluded"] is False
    assert _payload(include_sources=True)["filters"]["sources_excluded"] is False
    assert _payload()["filters"]["sources_excluded"] is True


# ---------------------------------------------------------------- the capability envelope

def test_unmeasured_stack_reports_null_not_a_guess() -> None:
    m = _payload()["retrieval_mode"]
    assert m["expected_mrr"] is None
    assert m["embedder"] is None, "absence is not a model name"
    assert m["degraded"] is False


def test_measured_stack_reports_its_number_and_cohort() -> None:
    cap = _cap(embedder="qwen3-embedding:0.6b#raw", embedder_state="ran", hyde="ran",
               reranker="ran", expected_mrr=0.698, unmeasured_reason=None)
    m = _payload(_result(cap=cap))["retrieval_mode"]
    assert m["expected_mrr"] == 0.698
    assert m["cohort"] == "44-case semantic", "a number without its cohort is uncomparable"
    assert m["unmeasured_reason"] is None, "a measured number must not also carry an excuse"


def test_requested_but_unreachable_arms_are_named() -> None:
    """`Capability` reports "off" for an arm nobody asked for AND for one that could not start.
    To a caller those are opposite: one means this stack was never measured, the other means the
    daemon is down. The condition exists where the stack is built and would otherwise die there."""
    m = _payload(unavailable=("hyde 'qwen2.5:7b' unreachable at 127.0.0.1:11434",))
    assert m["retrieval_mode"]["unavailable"] == [
        "hyde 'qwen2.5:7b' unreachable at 127.0.0.1:11434"]
    assert m["retrieval_mode"]["hyde"] == "off", "the arm still reports off — nothing ran"
    assert _payload()["retrieval_mode"]["unavailable"] == [], "nothing requested, nothing missing"


# ---------------------------------------------------------------- can the arms even start

def test_health_states_are_the_ones_the_engine_can_observe() -> None:
    """Three states, each one a thing this process actually saw. `lexical_only` and `unreachable`
    are the pair the prose was the only carrier of — and they are NOT severities: one is a
    configuration, the other is a fault."""
    from substrate.stack import Stack

    ready = _payload(wiring=Stack(embedder=object()).wiring)["retrieval_mode"]["health"]
    assert (ready["state"], ready["arms"]["embedder"]) == ("ready", "wired")
    assert ready["note"] is None, "a healthy stack does not need a sentence"

    lexical = _payload(wiring=Stack().wiring)["retrieval_mode"]["health"]
    assert lexical["state"] == "lexical_only"
    assert set(lexical["arms"].values()) == {"off"}

    down = _payload(wiring=Stack(unavailable=("hyde 'q' unreachable at h",)).wiring,
                    unavailable=("hyde 'q' unreachable at h",))["retrieval_mode"]["health"]
    assert down["state"] == "unreachable"
    assert down["arms"] == {"embedder": "off", "hyde": "unavailable", "reranker": "off"}


def test_health_refuses_to_guess_why_an_arm_did_not_start() -> None:
    """The distinction a UI most wants is the one this engine cannot make: `available()` collapses
    a refused connection, a timeout and a missing model into one False, and nothing looks for an
    installation at all. So "not installed" (the zero-install default, not a fault) and "installed
    and down" (a fault) share one observation — said out loud in `note` rather than guessed at in
    a field, because a field that reports a guess is worse than no field."""
    from substrate.stack import Stack

    h = _payload(wiring=Stack(unavailable=("embedder 'q' unreachable at h",)).wiring,
                 unavailable=("embedder 'q' unreachable at h",))["retrieval_mode"]["health"]
    assert set(h) == HEALTH_KEYS, "a key claiming installation state appeared"
    assert "installed" in (h["note"] or ""), "the unknowable is not stated anywhere"


def test_health_makes_the_unavailable_prose_redundant_without_contradicting_it() -> None:
    """Two carriers, one source. The prose keeps what only it has — the model and the host it was
    looked for at — and the structured map keeps what only it has: an arm name a consumer does not
    have to recover by parsing our sentences."""
    from substrate.stack import Stack

    st = Stack(embedder=object(), unavailable=("reranker 'qwen2.5:7b' unreachable at local",))
    m = _payload(wiring=st.wiring, unavailable=st.unavailable)["retrieval_mode"]
    named = {a for a, s in m["health"]["arms"].items() if s == "unavailable"}
    assert named == {"reranker"}
    assert m["unavailable"] == ["reranker 'qwen2.5:7b' unreachable at local"]
    assert "local" in m["unavailable"][0], "the where is the prose's whole remaining job"


def test_prose_that_names_no_known_arm_still_forbids_a_healthy_reading() -> None:
    """The two carriers must not be able to contradict each other. The arm map recovers its names
    from the leading token of each `unavailable` entry, so an entry that led with something else
    would vanish from the map while staying in the prose — and health would then report `ready`
    over a stack with a dead arm, which is the false-healthy shape all of this exists to remove.
    An unattributable entry costs the WHICH, never the WHETHER."""
    from substrate.stack import Stack

    odd = ("the local daemon did not answer",)
    h = _payload(wiring=Stack().wiring, unavailable=odd)["retrieval_mode"]["health"]
    assert h["state"] == "unreachable", "an entry nothing could attribute read as healthy"
    assert set(h["arms"].values()) == {"off"}, "no arm may be blamed on an unattributable entry"
    assert "cannot say WHICH" in h["note"]


def test_a_caller_that_reported_no_wiring_is_not_reported_healthy() -> None:
    """`known: false`, not `ready`. A healthy-looking state that requires nothing to have happened
    is the shape this module exists to remove — the same reason `refresh.frozen` is null with no
    record rather than false."""
    h = _payload()["retrieval_mode"]["health"]
    assert h["known"] is False
    assert h["state"] is None and h["arms"] is None
    assert h["note"], "the absence crossed as a bare null with nothing explaining it"


def test_degradation_crosses_with_its_reason() -> None:
    """A degraded run that reads as full quality is the whole failure family."""
    cap = _cap(embedder_state="fell_back", fallbacks=("no vectors: 0/595 under 'qwen3'",))
    m = _payload(_result(cap=cap))["retrieval_mode"]
    assert m["degraded"] is True
    assert m["fallbacks"] == ["no vectors: 0/595 under 'qwen3'"]
    assert m["expected_mrr"] is None


def test_the_embedder_arm_reports_a_state_beside_its_key() -> None:
    """`hyde` and `reranker` sent a state word and the embedder sent a model KEY, which empties on
    a fallback — so the arm the vector-coverage guard degrades most often was the only one that
    could not say it had degraded. Both cases still send `embedder: null`, so this asserts the
    two envelopes DIFFER rather than pinning a value that would pass on either."""
    fell = _payload(_result(cap=_cap(embedder_state="fell_back",
                                     fallbacks=("no vectors: 0/595",))))["retrieval_mode"]
    never = _payload()["retrieval_mode"]
    assert fell["embedder"] is never["embedder"] is None
    assert (fell["embedder_state"], never["embedder_state"]) == ("fell_back", "off")


def test_an_absent_number_always_says_why() -> None:
    """"Unmeasured" with no reason is indistinguishable from a bug, and the engine knew which of
    the five applied at the moment it declined to publish one."""
    from substrate.retrieve.retriever import UNMEASURED_REASONS

    m = _payload()["retrieval_mode"]
    assert m["expected_mrr"] is None
    assert m["unmeasured_reason"] in UNMEASURED_REASONS


# ---------------------------------------------------------------- serializable

def test_payload_is_json_serializable() -> None:
    """It crosses a JSON-RPC boundary; a non-serializable field is a runtime failure per call."""
    json.dumps(_payload(_result(outlines=[_hit(kind="outline")])))


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
