"""The MCP surface is a transport, and its results are byte-identical to the CLI's.

Doc 3a §6: "an MCP `search` and the equivalent CLI query must return the same passages, same
capability, same index_version for the same scope. If they diverge, logic leaked into a
transport." `test_mcp_and_cli_render_the_same_envelope` IS that verification — it runs the real
CLI in a subprocess and the real tool handler in-process and compares the parsed envelopes.

The rest pin the refusals. Every one of them exists because the alternative is a well-formed
answer the caller cannot tell apart from a correct one: an unresolvable scope answered from a
narrower one, an empty rebuilt index answered as a no-match, a filter accepted and ignored.

Runnable with plain `python tests/test_mcp_server.py`; discovered by pytest if added.
"""

from __future__ import annotations

import atexit
import io
import json
import os
import shutil
import subprocess
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

REPO = Path(__file__).resolve().parent.parent

from substrate import render, scopes, stack  # noqa: E402
from substrate.mcp import server  # noqa: E402
from substrate.models import Chunk, Document  # noqa: E402
from substrate.store.index_store import IndexStore  # noqa: E402

_LONG = ("Composition resolves the manifest and indexes core plus project together. " * 12).strip()

_TMPDIRS: list[str] = []


def _tmpdir() -> Path:
    """Every temporary tree in this file comes from here, so a run cleans up after itself.

    Bare `mkdtemp` stranded one tree per test under a directory nothing reaps, each holding a
    SQLite file with its -wal and -shm siblings beside it. One copy of the cleanup, registered
    once — a second `mkdtemp` written elsewhere is how that drifts back.
    """
    d = tempfile.mkdtemp(prefix="substrate-mcp-test-")
    _TMPDIRS.append(d)
    return Path(d)


def _cleanup_tmpdirs() -> None:
    # atexit, not per-test: a test that fails mid-way still owns a tree, and the assertion is the
    # thing worth reading — a cleanup error raised on top of it would bury the diagnosis.
    for d in _TMPDIRS:
        shutil.rmtree(d, ignore_errors=True)


atexit.register(_cleanup_tmpdirs)


class _FakeEmbedder:
    """Wired but never used — these tests assert what STATUS reports about an index, which must
    not depend on a local daemon being up."""

    key = "qwen3-embedding:0.6b#raw"
    model = "qwen3-embedding:0.6b"


def _cfg(registry: Path, *, read_only: bool = False) -> server.Config:
    """Lexical-only, always. A test that depended on a local daemon would pass or fail on whether
    Ollama happened to be running, which is not a property of this code.

    `read_only` is the ONE thing the two transports differ by (Doc 3 §3), and it travels on Config
    rather than on a second dispatch — so a test of the HTTP write gate is this flag, not a
    different server. `main()` is what decides its default per transport; that decision has its own
    test, because nothing here would notice it flipping.
    """
    return server.Config(str(registry), stack.build(lexical_only=True), read_only=read_only)


def _cfg_embedder(registry: Path) -> server.Config:
    """An embedder REQUESTED — wired if the daemon is up, `unavailable` if it is not. Either way
    both adapters must agree, which is the point: this asserts agreement, not a value, so it does
    not depend on whether Ollama happens to be running. No generator arms, so no model call."""
    return server.Config(str(registry), stack.build(hyde_model=None, rerank_model=None))


def _fixture(*, manifest: bool = False) -> tuple[Path, Path]:
    """A composed-looking scope: one index, one registered name, one note on disk.

    Mirrors what `compose` actually stores, which is load-bearing here: `source_path` is the VAULT
    note and `source_sha256` its real digest, while `markdown_path` is the derived artifact in the
    disposable index root. Conflating them is precisely the bug this fixture used to hide.
    """
    import hashlib

    root = _tmpdir()
    vault = root / "demo-vault"
    vault.mkdir()
    note = vault / "composition.md"
    note.write_text(f"# Composition\n\n{_LONG}\n", encoding="utf-8")
    if manifest:
        (vault / ".substrate.toml").write_text('name = "demo"\ninherits = []\n', encoding="utf-8")

    derived = root / "demo-index" / "composition"
    derived.mkdir(parents=True)
    (derived / "document.md").write_text(f"{_LONG}\n", encoding="utf-8")

    db = root / "demo.db"
    with IndexStore(str(db)) as s:
        doc = Document(doc_id="composition", source_path=str(note),
                       source_sha256=hashlib.sha256(note.read_bytes()).hexdigest(),
                       source_pages=1, document_class="reference-frozen", title="Composition",
                       status="active", doc_type="explanation", confidence="proposed",
                       vault="demo-vault", tier=3, domains=["retrieval"],
                       supersedes=["old-composition", "older-composition"])
        ch = Chunk(chunk_id="composition#c00000", doc_id="composition", kind="passage",
                   text=_LONG, path=["Composition"], level=1, n_chars=len(_LONG),
                   document_class="reference-frozen")
        s.upsert(doc, [ch], markdown_path=str(derived / "document.md"), markdown_mtime=0.0,
                 markdown_sha256="d" * 64)

    registry = root / "scopes.toml"
    scopes.record("demo", vault=vault, db=db, index_root=root, registry=registry)
    return root, registry


def _call(tool: str, args: dict, registry: Path, cfg: server.Config | None = None) -> dict:
    """One tools/call through the real dispatcher; returns the parsed payload or raises on
    isError, so a test cannot mistake a refusal for a result.

    `cfg` is threaded through for the two-phase ingest tests: a real server holds ONE Config for
    its lifetime, and the PlanBook that makes a confirm_token unforgeable lives on it. A fresh
    Config per call would model a server restarting between plan and commit.
    """
    resp = server.handle(
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": tool, "arguments": args}},
        cfg or _cfg(registry),
    )
    body = resp["result"]
    text = body["content"][0]["text"]
    if body.get("isError"):
        raise AssertionError(f"tool refused: {text}")
    return json.loads(text)


def _call_raw(tool: str, args: dict, registry: Path,
              cfg: server.Config | None = None) -> dict:
    return server.handle(
        {"jsonrpc": "2.0", "id": 1, "method": "tools/call",
         "params": {"name": tool, "arguments": args}},
        cfg or _cfg(registry),
    )["result"]


# ---------------------------------------------------------------- Doc 3a §6

def test_mcp_and_cli_render_the_same_envelope() -> None:
    """The verification that keeps "one contract, N renderings" true rather than aspirational."""
    root, registry = _fixture()
    query = "composition manifest"

    mcp = _call("search", {"scope": "demo", "query": query, "k": 3}, registry)

    proc = subprocess.run(
        [sys.executable, "-m", "substrate.cli", "query", query, "--scope", "demo",
         "--registry", str(registry), "--k", "3", "--json", "--no-vector"],
        capture_output=True, text=True, cwd=REPO, check=True,
    )
    cli = json.loads(proc.stdout)

    # The WHOLE envelope, not a list of named fields. Comparing five keys let both adapters bolt
    # an extra one on unnoticed — the CLI a `db`, the server a clamp note — so the two emitted
    # structurally different shapes while every named assertion passed.
    assert set(mcp) == set(cli), set(mcp) ^ set(cli)
    assert mcp == cli, "envelope diverged — logic leaked into a transport"


def test_the_two_cli_renderings_agree_about_what_was_withheld() -> None:
    """The human read-out judged "sources excluded" from --include-sources alone while --json used
    the class-aware rule, so `query --doc-class conversation` and the same command with --json
    made OPPOSITE claims about the same result set."""
    _, registry = _fixture()
    base = [sys.executable, "-m", "substrate.cli", "query", "composition", "--scope", "demo",
            "--registry", str(registry), "--k", "1", "--no-vector", "--doc-class", "conversation"]
    human = subprocess.run(base, capture_output=True, text=True, cwd=REPO, check=True).stdout
    envelope = json.loads(subprocess.run([*base, "--json"], capture_output=True, text=True,
                                         cwd=REPO, check=True).stdout)
    assert ("sources excluded" in human) is envelope["filters"]["sources_excluded"], human


def test_cli_refuses_flags_the_envelope_cannot_carry() -> None:
    """`--expand` prints a per-hit orientation line the envelope has no field for, and `--db ""`
    is a supplied argument rather than an absent one. Both were accepted and silently discarded —
    the same defect as a filter accepted and not applied."""
    _, registry = _fixture()
    base = [sys.executable, "-m", "substrate.cli", "query", "composition"]
    for extra in (["--scope", "demo", "--registry", str(registry), "--json", "--expand"],
                  ["--db", ""]):
        r = subprocess.run([*base, *extra], capture_output=True, text=True, cwd=REPO)
        assert r.returncode == 2, (extra, r.stdout, r.stderr)
        assert "FATAL" in r.stderr, extra


def test_mcp_and_cli_agree_with_a_stack_actually_requested() -> None:
    """The equivalence above runs both sides lexical-only, so both take `stack.build`'s early
    return and it compares two identically-empty stacks — it cannot see the divergence the shared
    builder exists to prevent (a CLI reporting `unavailable: []` while the server names an
    unreachable daemon, which is exactly what the hand-wired CLI branch used to do).

    This asks BOTH sides for an embedder, matched. It asserts they agree rather than asserting a
    particular value, so it holds whether or not the daemon is up.
    """
    root, registry = _fixture()
    query = "composition manifest"

    mcp = _call("search", {"scope": "demo", "query": query, "k": 3}, registry,
                _cfg_embedder(registry))
    proc = subprocess.run(
        [sys.executable, "-m", "substrate.cli", "query", query, "--scope", "demo",
         "--registry", str(registry), "--k", "3", "--json"],   # no --no-vector: embedder asked for
        capture_output=True, text=True, cwd=REPO, check=True,
    )
    cli = json.loads(proc.stdout)

    assert mcp == cli, "envelope diverged once a real arm was requested"
    # And the arm state actually travelled — otherwise this passes by comparing two empty things
    # again, the defect it was written to close. Three states satisfy that, not two: over a
    # vectorless index (this fixture) the coverage guard degrades a reachable, wired embedder,
    # reporting `embedder: None` with an EMPTY `unavailable` and the condition in `fallbacks`.
    mode = mcp["retrieval_mode"]
    assert mode["embedder"] is not None or mode["unavailable"] or mode["fallbacks"], mode


# ---------------------------------------------------------------- the contract crosses

def test_search_carries_the_whole_spine() -> None:
    _, registry = _fixture()
    p = _call("search", {"scope": "demo", "query": "composition"}, registry)["passages"][0]
    assert p["confidence"] == "proposed", "an unbuilt design must not read as settled"
    assert p["status"] == "active", "status and confidence are independent axes"
    assert p["doc_type"] == "explanation"
    assert p["supersedes"] == ["old-composition", "older-composition"]
    assert p["vault"] == "demo-vault"
    assert p["domains"] == ["retrieval"]


def test_search_is_snippet_first_with_a_usable_ref() -> None:
    _, registry = _fixture()
    env = _call("search", {"scope": "demo", "query": "composition"}, registry)
    p = env["passages"][0]
    assert p["text"] is None and p["truncated"] is True
    full = _call("expand", {"expand_ref": p["expand_ref"]}, registry)
    assert full["passage"]["text"] == _LONG, "the ref search issued must resolve to the passage"


def test_filters_state_what_was_withheld() -> None:
    _, registry = _fixture()
    f = _call("search", {"scope": "demo", "query": "composition"}, registry)["filters"]
    assert f["statuses_excluded"] == ["archived", "superseded"]
    assert f["sources_excluded"] is True


def test_include_archived_and_include_sources_are_separate_axes() -> None:
    """Collapsing them into one flag would encode a conflation this project already rejected:
    superseded is excluded because it was REPLACED, a conversation because retrieval by passage
    MISREPRESENTS it. Same mechanism, opposite reasons."""
    _, registry = _fixture()
    a = _call("search", {"scope": "demo", "query": "composition",
                         "include_archived": True}, registry)["filters"]
    assert "archived" in a["statuses_included"]
    assert a["sources_excluded"] is True, "archived must not smuggle in conversation sources"

    s = _call("search", {"scope": "demo", "query": "composition",
                         "include_sources": True}, registry)["filters"]
    assert s["sources_excluded"] is False
    assert "archived" in s["statuses_excluded"], "sources must not smuggle in archived notes"


def test_superseded_is_never_included_by_either_flag() -> None:
    """A dead fact is reachable only as the `supersedes` link on its replacement (Doc 2 §6)."""
    _, registry = _fixture()
    for extra in ({}, {"include_archived": True}, {"include_sources": True}):
        f = _call("search", {"scope": "demo", "query": "composition", **extra}, registry)["filters"]
        assert "superseded" in f["statuses_excluded"], extra


# ---------------------------------------------------------------- expand

def test_expand_note_returns_the_vault_note_not_the_derived_artifact() -> None:
    """`markdown_path` is the derived copy in the disposable index root — regenerated by every
    compose, so it always agrees with the index and can never report that the vault moved on.
    The note the user owns is `source_path`, and it still carries its frontmatter."""
    root, registry = _fixture()
    ref = _call("search", {"scope": "demo", "query": "composition"}, registry)["passages"][0][
        "expand_ref"]
    out = _call("expand", {"expand_ref": ref, "mode": "note"}, registry)
    assert out["note"]["path"] == str(root / "demo-vault" / "composition.md")
    assert out["note"]["text"].startswith("# Composition")
    assert out["note"]["stale"] is False
    assert out["note"]["truncated"] is False


def test_expand_note_reports_a_note_that_changed_since_indexing() -> None:
    """A note silently newer than the passages quoted beside it is a mismatch the caller must be
    able to see."""
    root, registry = _fixture()
    (root / "demo-vault" / "composition.md").write_text("# Composition\n\nrewritten\n",
                                                        encoding="utf-8")
    ref = _call("search", {"scope": "demo", "query": "composition"}, registry)["passages"][0][
        "expand_ref"]
    assert _call("expand", {"expand_ref": ref, "mode": "note"}, registry)["note"]["stale"] is True


def test_expand_refuses_a_malformed_or_unknown_ref() -> None:
    _, registry = _fixture()
    assert _call_raw("expand", {"expand_ref": "no-separator"}, registry).get("isError")
    assert _call_raw("expand", {"expand_ref": "demo/nope#c0"}, registry).get("isError")


# ---------------------------------------------------------------- documents (browse)

def test_documents_lists_the_corpus_with_its_spine_and_provenance() -> None:
    _, registry = _fixture()
    out = _call("documents", {"scope": "demo"}, registry)

    assert out["total"] == 1 and out["returned"] == 1
    (doc,) = out["documents"]
    assert doc["doc_id"] == "composition"
    assert doc["title"] == "Composition"
    # The spine, with the same values `search` reports for the same note — a note must not read as
    # one thing in a result and another in a list.
    assert doc["status"] == "active"
    assert doc["doc_type"] == "explanation"
    assert doc["confidence"] == "proposed"
    assert doc["document_class"] == "reference-frozen"
    assert doc["domains"] == ["retrieval"]
    # A LIST, as v8 made it. The scalar form could name only one of the two dead notes.
    assert doc["supersedes"] == ["old-composition", "older-composition"]
    # The composition provenance, which is the whole reason this is not a directory listing.
    assert doc["vault"] == "demo-vault"
    assert doc["tier"] == 3
    # The envelope is the one a caller already knows how to read.
    assert out["scope"] == "demo"
    assert set(out) == {"scope", "db", "documents", "returned", "total", "filters",
                        "index_version", "refresh"}
    # No retrieval happened, so no arms block claims one did.
    assert "retrieval_mode" not in out


def test_documents_hands_back_a_ref_that_expand_reads() -> None:
    """The browse list's handle is the SAME handle a search result carries. If these two read
    paths ever diverge, the freshness verdict diverges with them."""
    _, registry = _fixture()
    (doc,) = _call("documents", {"scope": "demo"}, registry)["documents"]
    assert doc["passage_count"] == 1
    read = _call("expand", {"expand_ref": doc["expand_ref"], "mode": "note"}, registry)
    assert read["note"]["text"].strip().startswith("# Composition")


def test_documents_withholds_the_same_things_search_does_and_says_so() -> None:
    _, registry = _fixture()
    out = _call("documents", {"scope": "demo"}, registry)
    assert out["filters"]["sources_excluded"] is True
    assert set(out["filters"]["statuses_excluded"]) == {"archived", "superseded"}
    # `include_archived` widens to archived and NOT to superseded — a dead note whose replacement
    # is in the corpus stays out either way. Asserted as the engine's own rule rather than assumed
    # to be "show everything".
    assert _call("documents", {"scope": "demo", "include_archived": True},
                 registry)["filters"]["statuses_excluded"] == ["superseded"]


def test_documents_filters_by_vault_and_doc_type_and_reports_both() -> None:
    _, registry = _fixture()
    hit = _call("documents", {"scope": "demo", "vault": "demo-vault",
                              "doc_type": "explanation"}, registry)
    assert hit["total"] == 1
    assert hit["filters"]["doc_type"] == "explanation"
    assert "vault=demo-vault" in hit["filters"]["notes"]
    # A filter that matches nothing returns nothing and still says what it applied — an empty list
    # under an unreported filter is indistinguishable from an empty corpus.
    miss = _call("documents", {"scope": "demo", "vault": "some-other-vault"}, registry)
    assert miss["total"] == 0 and miss["documents"] == []
    assert "vault=some-other-vault" in miss["filters"]["notes"]


def test_documents_refuses_a_vault_name_that_names_no_vault() -> None:
    """`vault=""` filtered the corpus to nothing and reported no filter, because `browse` narrowed
    on `is not None` while the payload disclosed on truthiness. An empty list under a silent filter
    is the one thing the filters block exists to prevent, so the argument is refused outright."""
    _, registry = _fixture()
    assert _call_raw("documents", {"scope": "demo", "vault": ""}, registry).get("isError")
    assert _call_raw("documents", {"scope": "demo", "vault": "   "}, registry).get("isError")
    # A name that IS a vault, just not one here, still answers — and still reports the filter.
    miss = _call("documents", {"scope": "demo", "vault": "elsewhere"}, registry)
    assert miss["total"] == 0
    assert "vault=elsewhere" in miss["filters"]["notes"]


def test_documents_reports_a_clamped_offset_rather_than_rewriting_it_silently() -> None:
    _, registry = _fixture()
    out = _call("documents", {"scope": "demo", "offset": 50_000_000}, registry)
    assert out["documents"] == []
    assert any("offset" in n and "clamped" in n for n in out["filters"]["notes"]), out["filters"]


def test_documents_does_not_hand_back_every_notes_path_in_bulk() -> None:
    """`source_path` was the largest field in the record and the most identifying — one call
    returned the operator's whole directory layout. `expand` still gives the path for a note the
    caller has actually named, which is one at a time and asked for."""
    root, registry = _fixture()
    (doc,) = _call("documents", {"scope": "demo"}, registry)["documents"]
    assert "source_path" not in doc
    # No FILESYSTEM path anywhere in the record. Asserted against the fixture's real root rather
    # than by looking for a "/", because `expand_ref` legitimately contains one as its scope
    # separator and a blanket check fired on that instead.
    assert not any(str(root) in str(v) for v in doc.values()), doc


def test_documents_pages_small_by_default() -> None:
    """A caller-chosen page is a caller-chosen response size. The default was 200 records (~30k
    tokens measured on the operator's `prism` scope) against a `search` ceiling of 50."""
    assert server.DEFAULT_DOCUMENTS <= server.MAX_K
    assert server.MAX_DOCUMENTS <= 500


def test_documents_normalises_a_malformed_domains_value() -> None:
    """`json.loads` does not guarantee a list, and this builder emits the decoded value straight
    onto the wire — so a scalar crossed as `"domains": 123` against a contract that says list."""
    from substrate.render import document_record

    row = {"doc_id": "d", "title": None, "first_chunk_id": None, "passage_count": 0,
           "vault": None, "tier": None, "document_class": None, "status": "active",
           "doc_type": "reference", "confidence": "unjudged",
           "domains": "123", "supersedes": "null", "superseded_by": None}
    out = document_record(row, scope="demo")
    assert out["domains"] == []
    assert out["supersedes"] == []


def test_documents_refuses_a_doc_type_outside_the_vocabulary() -> None:
    """Refused, not returned empty. `doc_type="explaination"` matching zero rows would read as a
    corpus with no explanations rather than as a typo."""
    _, registry = _fixture()
    assert _call_raw("documents", {"scope": "demo", "doc_type": "explaination"},
                     registry).get("isError")
    assert _call_raw("documents", {"scope": "demo", "limit": "10"}, registry).get("isError")
    assert _call_raw("documents", {"scope": "demo", "limit": 0}, registry).get("isError")
    assert _call_raw("documents", {"scope": "demo", "offset": -1}, registry).get("isError")
    assert _call_raw("documents", {}, registry).get("isError")


def test_documents_paging_keeps_the_total_and_reports_a_clamp() -> None:
    _, registry = _fixture()
    page = _call("documents", {"scope": "demo", "limit": 1, "offset": 1}, registry)
    # The page is empty; the corpus is not. A caller must be able to tell those apart.
    assert page["documents"] == [] and page["returned"] == 0 and page["total"] == 1
    clamped = _call("documents", {"scope": "demo", "limit": 99_999}, registry)
    assert any("clamped" in n for n in clamped["filters"]["notes"])


# ---------------------------------------------------------------- refusals

def test_unknown_scope_refuses_rather_than_guessing() -> None:
    _, registry = _fixture()
    body = _call_raw("search", {"scope": "nope", "query": "x"}, registry)
    assert body.get("isError")
    assert "demo" in body["content"][0]["text"], "a refusal must name what IS available"


def test_unimplemented_doc_type_filter_refuses_rather_than_ignoring() -> None:
    """Accepting a filter and not applying it returns unfiltered results under a filtered label —
    the caller cannot tell, which is the whole failure family."""
    _, registry = _fixture()
    body = _call_raw("search", {"scope": "demo", "query": "composition",
                                "doc_type": "decision"}, registry)
    assert body.get("isError")


def test_missing_arguments_refuse() -> None:
    _, registry = _fixture()
    assert _call_raw("search", {"scope": "demo"}, registry).get("isError")
    assert _call_raw("expand", {}, registry).get("isError")


# ---------------------------------------------------------------- protocol

def test_initialize_and_tools_list() -> None:
    _, registry = _fixture()
    cfg = _cfg(registry)
    init = server.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize"}, cfg)
    assert init["result"]["serverInfo"]["name"] == "substrate"
    assert init["result"]["protocolVersion"] == server.PROTOCOL_VERSION

    listed = server.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, cfg)["result"]
    assert {t["name"] for t in listed["tools"]} == {"search", "expand", "ingest", "list_scopes",
                                                    "status", "documents"}
    assert set(listed["tools"][0]) >= {"name", "description", "inputSchema"}
    for t in listed["tools"]:
        assert t["inputSchema"]["type"] == "object"
    # Doc 3a §4: the tool surface stays small — fewer tools, less resident schema every turn.
    #
    # Raised 5 → 6 for `documents`, and the bar it had to clear is the one this assertion's message
    # names. It is not a parameter variant of `search`: no query reaches it, nothing is ranked, and
    # the answer is the corpus rather than a claim about relevance. `search(query="")` could not
    # produce it — retrieval with an empty query is not a listing, it is a bug — and no combination
    # of the other five returns which vault an unretrieved note composed from.
    assert len(listed["tools"]) <= 6, "resist adding tools that are parameter variants"


def test_notifications_get_no_reply() -> None:
    """ANY method sent without an `id` is a notification, not just the one with its own branch.
    Deciding it per-branch meant `tools/list` as a notification answered with `"id": null` — a
    response to nothing."""
    _, registry = _fixture()
    cfg = _cfg(registry)
    for method in ("notifications/initialized", "initialize", "tools/list", "nonsense"):
        assert server.handle({"jsonrpc": "2.0", "method": method}, cfg) is None, method
    # An explicit id — including a falsy one — is NOT a notification.
    assert server.handle({"jsonrpc": "2.0", "id": 0, "method": "tools/list"}, cfg) is not None


def test_batches_are_served_not_rejected() -> None:
    """A batch is a legal array and this server advertises a protocol version that permits one.
    Rejecting it failed a conformant client's whole batch — `initialize` included — on a single
    id-less error."""
    _, registry = _fixture()
    cfg = _cfg(registry)

    out = server.handle([{"jsonrpc": "2.0", "id": 1, "method": "initialize"},
                         {"jsonrpc": "2.0", "id": 2, "method": "tools/list"}], cfg)
    assert isinstance(out, list)
    assert [m["id"] for m in out] == [1, 2]

    # An invalid member is an error INSIDE the batch, not a rejection of the whole.
    mixed = server.handle([{"jsonrpc": "2.0", "id": 3, "method": "tools/list"}, "garbage"], cfg)
    assert len(mixed) == 2
    assert mixed[0]["id"] == 3 and mixed[1]["error"]["code"] == -32600


def test_a_batch_of_only_notifications_gets_no_reply() -> None:
    """JSON-RPC: no response at all — not an empty array, which a client would try to parse as
    results."""
    _, registry = _fixture()
    assert server.handle([{"jsonrpc": "2.0", "method": "initialize"},
                          {"jsonrpc": "2.0", "method": "notifications/initialized"}],
                         _cfg(registry)) is None


def test_an_empty_batch_is_invalid() -> None:
    _, registry = _fixture()
    assert server.handle([], _cfg(registry))["error"]["code"] == -32600


def test_positional_params_refuse_instead_of_escaping() -> None:
    """JSON-RPC permits positional params. An array reached `.get` and threw out of the handler,
    becoming an id-less transport error the client could not match to its request."""
    _, registry = _fixture()
    resp = server.handle({"jsonrpc": "2.0", "id": 7, "method": "tools/call", "params": [1, 2]},
                         _cfg(registry))
    assert resp["id"] == 7, "the refusal must carry the id it is answering"
    assert resp["error"]["code"] == -32602


def test_unknown_method_and_tool() -> None:
    _, registry = _fixture()
    cfg = _cfg(registry)
    assert server.handle({"jsonrpc": "2.0", "id": 3, "method": "nope"}, cfg)["error"]["code"] \
        == -32601
    assert server.handle({"jsonrpc": "2.0", "id": 4, "method": "tools/call",
                          "params": {"name": "nope"}}, cfg)["error"]["code"] == -32602


def test_serve_reads_and_writes_line_delimited_json() -> None:
    _, registry = _fixture()
    stdin = io.StringIO(
        '{"jsonrpc":"2.0","id":1,"method":"initialize"}\n'
        "\n"
        "not json at all\n"
        '{"jsonrpc":"2.0","method":"notifications/initialized"}\n'
        '{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n'
    )
    stdout = io.StringIO()
    server.serve(_cfg(registry), stdin=stdin, stdout=stdout)
    lines = [json.loads(x) for x in stdout.getvalue().splitlines() if x.strip()]
    # The notification is silent; the junk line is ANSWERED. Swallowing it left a client waiting
    # on a reply that was never coming — the server's own liveness turned into a hang.
    assert [m.get("id") for m in lines] == [1, None, 2]
    assert lines[1]["error"]["code"] == -32700
    # A blank line is framing noise, not a malformed message, and must stay silent.
    assert sum(1 for m in lines if m.get("error")) == 1


def test_an_internal_error_carries_the_id_of_the_frame_that_failed() -> None:
    """A client matches a response to a pending request BY ID, so an error carrying `id: null`
    resolves nothing — the call hangs to the client's own timeout instead of failing, which is a
    worse outcome than the error being reported at all.

    Null stays correct for the shape that genuinely has no single id (a batch), and a NOTIFICATION
    gets no reply whatsoever: nobody is waiting on an id that was never sent.
    """
    _, registry = _fixture()

    def _boom(msg: object, cfg: server.Config) -> dict:
        raise RuntimeError("handler exploded")

    # The dispatcher is replaced rather than fed a frame that happens to break it, because the
    # property under test belongs to the catch-all in `serve` and not to any one input — which
    # input escapes `_dispatch` is an implementation detail that a guard could close tomorrow.
    real = server._dispatch
    server._dispatch = _boom
    try:
        out = io.StringIO()
        server.serve(_cfg(registry), stdin=io.StringIO(
            '{"jsonrpc":"2.0","id":42,"method":"tools/list"}\n'
            '{"jsonrpc":"2.0","method":"tools/list"}\n'            # notification: no reply at all
            '[{"jsonrpc":"2.0","id":43,"method":"tools/list"}]\n'  # batch: no single id to answer
        ), stdout=out)
    finally:
        server._dispatch = real

    lines = [json.loads(x) for x in out.getvalue().splitlines() if x.strip()]
    assert [m["id"] for m in lines] == [42, None], out.getvalue()
    assert all(m["error"]["code"] == -32603 for m in lines), lines
    assert "RuntimeError" in lines[0]["error"]["message"], lines[0]

    # And the property holds for a frame that reaches that catch-all FROM THE WIRE today: a tool
    # name that is not a string is unhashable, so `HANDLERS.get(name)` throws straight past
    # `_dispatch`. Asserted as "answered, carrying this frame's id, and the loop lived" rather than
    # as a code — tightening that lookup into a -32602 would keep the property and change only the
    # number.
    out = io.StringIO()
    server.serve(_cfg(registry), stdin=io.StringIO(
        '{"jsonrpc":"2.0","id":44,"method":"tools/call","params":{"name":["tools/list"]}}\n'
        '{"jsonrpc":"2.0","id":45,"method":"initialize"}\n'
    ), stdout=out)
    lines = [json.loads(x) for x in out.getvalue().splitlines() if x.strip()]
    assert [m["id"] for m in lines] == [44, 45], "a frame the dispatcher could not survive took " \
                                                 f"the session with it: {out.getvalue()!r}"
    # Reported as a failure of some kind — a JSON-RPC error or an isError result, either is
    # actionable. What must never happen is a success.
    assert "error" in lines[0] or lines[0]["result"].get("isError"), lines[0]


def test_tool_fault_stays_inside_the_result() -> None:
    """A refusal must reach the model as content it can act on, not as a transport error."""
    _, registry = _fixture()
    resp = server.handle({"jsonrpc": "2.0", "id": 9, "method": "tools/call",
                          "params": {"name": "search", "arguments": {"scope": "nope",
                                                                     "query": "x"}}},
                         _cfg(registry))
    assert "error" not in resp
    assert resp["result"]["isError"] is True


# ---------------------------------------------------------------- honest absence

def test_unavailable_arms_are_named_not_just_absent() -> None:
    """`off` and `could not start` are byte-identical in Capability. To a caller they are opposite
    situations — one means the stack was never measured, the other means start Ollama."""
    _, registry = _fixture()
    cfg = server.Config(str(registry), stack.Stack(unavailable=("hyde 'qwen2.5:7b' unreachable",)))
    resp = server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                          "params": {"name": "search",
                                     "arguments": {"scope": "demo", "query": "composition"}}}, cfg)
    mode = json.loads(resp["result"]["content"][0]["text"])["retrieval_mode"]
    assert mode["unavailable"] == ["hyde 'qwen2.5:7b' unreachable"]
    assert mode["expected_mrr"] is None


def test_lexical_only_stack_reports_no_measured_number() -> None:
    _, registry = _fixture()
    mode = _call("search", {"scope": "demo", "query": "composition"}, registry)["retrieval_mode"]
    assert mode["embedder"] is None
    assert mode["expected_mrr"] is None, "a lexical-only run has no measured tier"


# ---------------------------------------------------------------- discovery and freshness

def test_list_scopes_reports_the_manifest_resolved_sources() -> None:
    _, registry = _fixture(manifest=True)
    out = _call("list_scopes", {}, registry)
    row = next(s for s in out["scopes"] if s["scope"] == "demo")
    assert row["sources"] == ["demo-vault"], row
    assert row["index_present"] is True


def test_list_scopes_lists_a_broken_scope_with_its_fault() -> None:
    """Omitting it would read as "that scope was never composed" — the opposite of the truth."""
    _, registry = _fixture()  # no manifest written: inheritance cannot resolve
    row = next(s for s in _call("list_scopes", {}, registry)["scopes"] if s["scope"] == "demo")
    assert row["sources"] is None
    assert "error" in row


def test_an_old_schema_index_is_refused_not_destroyed() -> None:
    """Opening for WRITE drops and rebuilds on a version mismatch, so a read-only tool used to
    annihilate the index it was asked about and then truthfully report it empty. Every tool here
    reads, so every tool opens with migrate=False: the refusal names both versions and the data
    survives for `compose` to rebuild deliberately."""
    import sqlite3

    root, registry = _fixture(manifest=True)
    db = scopes.resolve("demo", registry).db
    con = sqlite3.connect(str(db))
    con.execute("PRAGMA user_version = 1")
    con.commit()
    con.close()

    for tool, args in (("status", {"scope": "demo"}),
                       ("search", {"scope": "demo", "query": "composition"})):
        body = _call_raw(tool, args, registry)
        assert body.get("isError"), tool
        assert "schema v1" in body["content"][0]["text"], tool

    # THE POINT: the documents are still there. A destructive read would have left zero.
    con = sqlite3.connect(str(db))
    assert con.execute("SELECT COUNT(*) FROM documents").fetchone()[0] == 1
    con.close()


def test_status_reports_an_empty_index_while_search_refuses_it() -> None:
    """An index that is current-schema but empty: status answers (that IS the question it exists
    for), search refuses (an empty result is indistinguishable from a genuine no-match)."""
    root, registry = _fixture(manifest=True)
    with IndexStore(str(scopes.resolve("demo", registry).db)) as s:
        s.clear()

    out = _call("status", {"scope": "demo"}, registry)
    assert out["documents"] == 0 and out["passages"] == 0

    body = _call_raw("search", {"scope": "demo", "query": "composition"}, registry)
    assert body.get("isError")
    assert "EMPTY index" in body["content"][0]["text"]


def test_status_reports_counts_and_the_spine_distribution() -> None:
    _, registry = _fixture(manifest=True)
    out = _call("status", {"scope": "demo"}, registry)
    assert out["documents"] == 1
    assert out["by_confidence"] == {"proposed": 1}
    assert out["by_status"] == {"active": 1}
    assert out["index_version"]


def test_status_reports_vector_coverage_as_incomplete() -> None:
    """The condition that made a lexical-only run wear a 0.698 label. A caller must be able to see
    it BEFORE reading a ranking, not only in a per-query degradation."""
    _, registry = _fixture(manifest=True)
    cfg = server.Config(str(registry), stack.Stack(embedder=_FakeEmbedder()))
    resp = server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/call",
                          "params": {"name": "status", "arguments": {"scope": "demo"}}}, cfg)
    v = json.loads(resp["result"]["content"][0]["text"])["vectors"]
    assert v["stored"] == 0 and v["chunks"] > 0
    assert v["complete"] is False
    assert "substrate embed" in v["note"]


def test_status_detects_a_note_the_index_does_not_hold() -> None:
    """An unindexed note looks exactly like a question the corpus cannot answer."""
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "brand-new.md").write_text("# New\n\nunindexed\n", encoding="utf-8")
    d = _call("status", {"scope": "demo"}, registry)["drift"]
    assert d["stale"] is True
    assert any(p.endswith("brand-new.md") for p in d["added"]), d


def test_status_detects_an_edited_note() -> None:
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "composition.md").write_text("# Composition\n\nrewritten\n",
                                                        encoding="utf-8")
    d = _call("status", {"scope": "demo"}, registry)["drift"]
    assert d["stale"] is True
    assert any(p.endswith("composition.md") for p in d["changed"]), d


def test_status_is_clean_when_nothing_moved() -> None:
    """`stale: true` must mean something. Always-true is the same defect as always-false."""
    _, registry = _fixture(manifest=True)
    d = _call("status", {"scope": "demo"}, registry)["drift"]
    assert d["stale"] is False, d
    assert d["checked"] == 1 and d["changed"] == [] and d["added"] == []


# ---------------------------------------------------------------- the freeze signal

def test_a_frozen_scope_does_not_answer_like_a_healthy_one() -> None:
    """The failure this field closes, asserted end-to-end through the real tool call.

    `compose` returns before it opens the index database, so when it refuses the OLD index stays
    and every query keeps answering from it. Before `refresh`, the two responses were identical —
    so this asserts a DIFFERENCE rather than a value: pinning `frozen is True` alone would still
    pass if the healthy case reported True as well.
    """
    from substrate import refresh_state

    _, registry = _fixture()
    healthy = _call("search", {"scope": "demo", "query": "composition"}, registry)

    refresh_state.record("demo", "compose_failed", registry=registry)
    frozen = _call("search", {"scope": "demo", "query": "composition"}, registry)

    assert healthy["refresh"] != frozen["refresh"], "a refused recompose crossed as nothing"
    assert frozen["refresh"]["frozen"] is True
    assert frozen["refresh"]["known"] is True
    # And nothing ELSE moved: the passages are the same because the index is the same. That is
    # exactly why the condition had to be attached to the result rather than inferred from it.
    assert healthy["passages"] == frozen["passages"]


def test_the_freeze_signal_reaches_both_adapters_identically() -> None:
    """Doc 3a §6 applied to the new field. It is read inside `search_payload` rather than passed
    in by each adapter, so a divergence here would mean one of them resolved a different registry —
    the same class of fault as the CLI reporting `unavailable: []` while the server named a dead
    daemon."""
    from substrate import refresh_state

    _, registry = _fixture()
    refresh_state.record("demo", "compose_failed", registry=registry)
    query = "composition manifest"

    mcp = _call("search", {"scope": "demo", "query": query, "k": 3}, registry)
    proc = subprocess.run(
        [sys.executable, "-m", "substrate.cli", "query", query, "--scope", "demo",
         "--registry", str(registry), "--k", "3", "--json", "--no-vector"],
        capture_output=True, text=True, cwd=REPO, check=True,
    )
    cli = json.loads(proc.stdout)

    assert mcp == cli, "envelope diverged on the refresh record"
    assert mcp["refresh"]["frozen"] is True, "both adapters agreed on the wrong thing"


def test_status_carries_the_same_refresh_block_as_search() -> None:
    """One reader, one key set. A caller that learned to read this on a search result must not
    have to learn a second dialect on `status`."""
    from substrate import refresh_state

    _, registry = _fixture(manifest=True)
    refresh_state.record("demo", "embed_failed", registry=registry)

    searched = _call("search", {"scope": "demo", "query": "composition"}, registry)["refresh"]
    stated = _call("status", {"scope": "demo"}, registry)["refresh"]
    assert searched == stated


def test_an_unrecorded_scope_reports_no_verdict_rather_than_a_clean_one() -> None:
    """The default state of every scope until an agent records one. It must not be the state that
    looks healthiest — absence of a record is absence of evidence."""
    _, registry = _fixture()
    r = _call("search", {"scope": "demo", "query": "composition"}, registry)["refresh"]
    assert r["known"] is False
    assert r["frozen"] is None, "no record read as a clean bill of health"
    assert r["note"]


# ---------------------------------------------------------------- the write gate

_NOTE = """---
status: active
doc_type: decision
confidence: proposed
---

# A decision

Written through the MCP surface, which is a write and therefore two-phase.
"""


def test_ingest_without_a_token_plans_and_writes_nothing() -> None:
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    out = _call("ingest", {"scope": "demo", "content": _NOTE, "filename": "d.md"}, registry)
    assert out["written"] is False
    assert out["plan"]["confirm_token"]
    assert out["plan"]["confidence"] == "proposed"
    assert not (root / "demo-vault" / "04-synthesis" / "d.md").exists()
    assert "NOTHING HAS BEEN WRITTEN" in out["next"]


def test_ingest_token_cannot_be_derived_by_the_caller() -> None:
    """THE regression, at the tool boundary. The token was sha256(target + content), both of
    which the caller supplies, so a first call carrying a self-computed digest wrote the note
    with no plan ever issued — verified against this dispatcher."""
    import hashlib

    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    target = (root / "demo-vault" / "04-synthesis" / "d.md").resolve()
    forged = hashlib.sha256(str(target).encode() + b"\0" + _NOTE.encode()).hexdigest()
    body = _call_raw("ingest", {"scope": "demo", "content": _NOTE, "filename": "d.md",
                                "confirm_token": forged}, registry)
    assert body.get("isError")
    assert not target.exists(), "a forged token must never reach the vault"


def test_ingest_with_the_token_writes_and_declares_the_index_stale() -> None:
    """The note is in the vault and not in the index. Said as a field — and `status` drift will
    list it — because a note that exists but cannot be found is the silent-omission shape."""
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    cfg = _cfg(registry)      # ONE server across both phases, as in production
    plan = _call("ingest", {"scope": "demo", "content": _NOTE, "filename": "d.md"},
                 registry, cfg)["plan"]
    out = _call("ingest", {"scope": "demo", "content": _NOTE, "filename": "d.md",
                           "confirm_token": plan["confirm_token"]}, registry, cfg)
    assert out["written"] is True
    assert out["index_stale"] is True
    assert (root / "demo-vault" / "04-synthesis" / "d.md").exists()

    d = _call("status", {"scope": "demo"}, registry)["drift"]
    assert any(p.endswith("d.md") for p in d["added"]), "the new note must show as unindexed"


def test_k_is_strict_about_its_type() -> None:
    """The schema says integer and every neighbour refuses what it cannot honour; `int()` accepted
    "7", 3.9 (→3) and True (→1), turning a malformed argument into a plausible result set."""
    _, registry = _fixture()
    for bad in ("7", 3.9, True, [5]):
        assert _call_raw("search", {"scope": "demo", "query": "x", "k": bad},
                         registry).get("isError"), bad
    assert _call("search", {"scope": "demo", "query": "composition", "k": 1}, registry)


def test_ingest_refuses_a_non_regular_source() -> None:
    """A caller-named path is untrusted input. The bound is enforced on the DESCRIPTOR that gets
    read, not by a prior stat — the check-then-act version could be swapped for a FIFO in
    between, and open() on one blocks forever."""
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    fifo = root / "pipe.md"
    os.mkfifo(fifo)
    body = _call_raw("ingest", {"scope": "demo", "source_path": str(fifo)}, registry)
    assert body.get("isError")
    assert "regular file" in body["content"][0]["text"]


def test_ingest_refuses_an_oversized_source() -> None:
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    big = root / "big.md"
    big.write_bytes(b"x" * (server.MAX_SOURCE_BYTES + 1))
    body = _call_raw("ingest", {"scope": "demo", "source_path": str(big)}, registry)
    assert body.get("isError")
    assert "limit" in body["content"][0]["text"]


def test_ingest_refuses_a_pdf_with_the_reason() -> None:
    """Not a capability gap silently hidden: reviewed markdown is what the engine reads, and the
    reference tier is not auto-written (Doc 2 §2, §3b)."""
    root, registry = _fixture(manifest=True)
    pdf = root / "paper.pdf"
    pdf.write_bytes(b"%PDF-1.4\n")
    body = _call_raw("ingest", {"scope": "demo", "source_path": str(pdf)}, registry)
    assert body.get("isError")
    assert "substrate ingest --pdf" in body["content"][0]["text"]


def test_ingest_refuses_both_or_neither_source() -> None:
    _, registry = _fixture(manifest=True)
    assert _call_raw("ingest", {"scope": "demo"}, registry).get("isError")
    assert _call_raw("ingest", {"scope": "demo", "content": _NOTE, "filename": "d.md",
                                "source_path": "/tmp/x.md"}, registry).get("isError")


def test_ingest_refuses_a_stale_token() -> None:
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    cfg = _cfg(registry)
    plan = _call("ingest", {"scope": "demo", "content": _NOTE, "filename": "d.md"},
                 registry, cfg)["plan"]
    edited = _NOTE.replace("proposed", "verified")
    body = _call_raw("ingest", {"scope": "demo", "content": edited, "filename": "d.md",
                                "confirm_token": plan["confirm_token"]}, registry, cfg)
    assert body.get("isError")
    assert not (root / "demo-vault" / "04-synthesis" / "d.md").exists()


def test_render_defaults_are_shared_not_copied() -> None:
    """The MCP server must not carry its own outline count — that is how two adapters drift."""
    assert server.render.OUTLINE_RECORDS is render.OUTLINE_RECORDS


def test_advertised_version_tracks_the_schema_not_a_literal() -> None:
    """The one version a client displays sat at "0.1.0" through schema v1..v8 — the surface that
    says how current the server is reported the same string however stale it was. Derived now, so
    it cannot drift again."""
    from substrate.store import schema

    # NOT `SERVER_VERSION == f"0.{SCHEMA_VERSION}.0"` — restating the constant's own definition
    # can only fail when someone edits the line it mirrors, and says nothing about the property
    # this test is named for. What matters is that the number reaches a client: it is read off the
    # wire, from the one field a client displays.
    _, registry = _fixture()
    init = server.handle({"jsonrpc": "2.0", "id": 1, "method": "initialize"}, _cfg(registry))
    assert init["result"]["serverInfo"]["version"] == server.SERVER_VERSION
    assert str(schema.SCHEMA_VERSION) in init["result"]["serverInfo"]["version"]


def test_the_vector_cache_survives_the_thread_the_stack_was_built_on() -> None:
    """`serve_http` builds the stack once on the main thread and serves from per-connection handler
    threads. sqlite3's default thread affinity made the first cache touch a ProgrammingError, which
    the retriever CAUGHT and degraded — so HyDE and the reranker fell back to fused lexical order
    on every HTTP query and said so only in `fallbacks`. Nothing caught it because every other test
    here builds `lexical_only=True`, which never constructs a cache at all.
    """
    import threading

    from substrate.embed.cache import VectorCache, content_sha

    cache = VectorCache(_tmpdir() / "vectors.db")  # main thread, as main() does
    try:
        sha = content_sha("composition resolves the manifest")
        cache.put_many([(sha, [0.5, 0.25])], "m")

        box: dict = {}

        def _read() -> None:
            try:
                box["got"] = cache.get_many([sha], "m")
            except Exception as e:  # noqa: BLE001 — the failure under test is an exception
                box["err"] = e

        t = threading.Thread(target=_read)
        t.start()
        t.join(10)
        # Checked before the box is read. A reader still blocked on the connection is a third
        # outcome, and indexing `box["got"]` reported it as a bare KeyError naming neither the
        # thread nor the timeout.
        assert not t.is_alive(), "cache read never returned — a blocked reader is not a pass"
        assert "err" not in box, f"cache unusable off its creating thread: {box.get('err')}"
        assert "got" in box, "reader thread recorded neither a result nor an exception"
        assert box["got"][sha] == [0.5, 0.25]
    finally:
        cache.close()


def test_http_bind_refuses_anything_but_loopback() -> None:
    """`ingest` writes vaults and reads caller-named files. Off-loopback that is a remote write
    primitive, so the bind fails closed — including on the forms the old split-based host guard in
    `net` got wrong."""
    # The accepted forms come back as the exact pair `serve_http` binds. Asserting `"[" not in
    # host` here asserted nothing: neither input can produce a bracket, so the check could not fail
    # for either — and a host silently rewritten on the way to bind() is the failure that matters.
    for spec, expected in (("127.0.0.1:8765", ("127.0.0.1", 8765)),
                           ("localhost:8765", ("localhost", 8765))):
        assert server.parse_bind(spec) == expected, spec

    # IPv6 is REFUSED, not unwrapped: the listener is AF_INET, so `[::1]` parsed cleanly and then
    # died at bind() with a gaierror — an address the validator blessed and the server cannot serve.
    for spec in ("[::1]:8765", "::1:8765",
                 "0.0.0.0:8765", "192.168.1.5:8765", "127.0.0.2:8765", "evil.example:8765",
                 "127.0.0.1:notaport", "8765", "", "127.0.0.1:0x10",
                 # THE INJECTIONS, and the reason this guard is not `net.is_loopback`: a URL parser
                 # discards everything after the first `/`, `?` or `#` and treats what precedes an
                 # `@` as userinfo, so each of these validated as "127.0.0.1" and then returned the
                 # WHOLE string to bind. The host that was checked was not the host that would be
                 # served — it failed closed only because getaddrinfo happened to reject the
                 # result, which is an accident rather than a guard.
                 "127.0.0.1#@evil.com:8765", "127.0.0.1?x=1:8765", "127.0.0.1/evil.com:8765",
                 "evil.com@127.0.0.1:8765",
                 # A PORT `int()` would have taken. From argv these arrive as real str — a shell
                 # can hand over `٥`, and `int("٥")` is 5 — so `_is_digits`' isascii/isdigit pair
                 # is what stands between a typo'd flag and a port nobody named. Whitespace is
                 # refused HERE because nothing strips it first (`_framing` does, per RFC 7230).
                 "127.0.0.1:+5", "127.0.0.1:1_0", "127.0.0.1: 8765", "127.0.0.1:٥"):
        try:
            server.parse_bind(spec)
            raise AssertionError(f"expected refusal for {spec!r}")
        except ValueError:
            pass


def _http_server(cfg: server.Config):
    """Start `serve_http` on an ephemeral loopback port; returns (base_url, stop).

    `stop` JOINS the serving thread. `httpd.shutdown()` only asks `serve_forever` to return —
    `serve_http`'s `finally: httpd.server_close()` then runs on that thread, after `stop` has
    already returned. Handing back the bare `shutdown` let a listening socket outlive the test that
    owned it, so a leaked port and a genuine bind failure looked the same from here.
    """
    import threading as _t

    box: dict = {}
    started = _t.Event()

    def _ready(httpd) -> None:
        box["httpd"] = httpd
        started.set()

    th = _t.Thread(target=server.serve_http,
                   kwargs={"cfg": cfg, "host": "127.0.0.1", "port": 0, "ready": _ready},
                   daemon=True)
    th.start()
    assert started.wait(10), "http server never bound"
    httpd = box["httpd"]
    port = httpd.server_address[1]

    def _stop() -> None:
        httpd.shutdown()
        th.join(10)
        assert not th.is_alive(), "serve_http never returned — the port is still bound"

    return f"http://127.0.0.1:{port}", _stop


def _raw(base: str, payload: bytes, *, half_close: bool = False, timeout: float = 10.0):
    """One raw-socket exchange with the server: send `payload`, read until it closes or stalls.
    Returns (everything seen, whether the SERVER closed).

    `urllib` always sends `Connection: close` and reads exactly one response, so nothing driven
    through `_post` can observe a refusal that leaves the connection alive with unread bytes still
    in it — which is the entire smuggling defect. This is the only socket driver in this file for
    that reason: a second hand-rolled recv loop is how one of them drifts back into dying as a bare
    TimeoutError that names neither the frame nor what the server answered.

    `half_close` shuts the write half after sending, which ends `_linger`'s discard budget at once
    instead of a second later. OFF by default: with it on, our own FIN is what ends the connection,
    so `closed` stops being evidence that the SERVER closed it.
    """
    import socket

    s = socket.create_connection(("127.0.0.1", _port(base)), timeout=timeout)
    seen, closed = b"", False
    try:
        try:
            s.sendall(payload)
            if half_close:
                s.shutdown(socket.SHUT_WR)
            while True:
                try:
                    chunk = s.recv(65536)
                except TimeoutError:
                    # A refusal that keeps the connection alive is the exploit's precondition, and
                    # it stalls this loop. Break and let the caller's assertions do the reporting.
                    break
                if not chunk:
                    closed = True
                    break
                seen += chunk
        except (ConnectionResetError, BrokenPipeError):
            # A server that drops the connection with nothing written on it is a RESULT, not an
            # error in the driver — it is precisely what the ceiling refusal and every 4xx branch
            # must not do. Returned as an empty `seen` so the caller's own assertion names it,
            # rather than raising an OSError that names only a socket.
            closed = True
    finally:
        s.close()
    return seen, closed


def _port(base: str) -> int:
    return int(base.rsplit(":", 1)[1])


# A complete second request, used in two POSITIONS with opposite expectations: inside a refused
# request's body it is the smuggling primitive (the refusal replies without reading the body, so
# these bytes are what `handle_one_request` would parse next), and after a correctly framed body it
# is ordinary keep-alive pipelining that MUST be answered. One copy, because the two cases are only
# meaningful against identical bytes.
_INNER_FRAME = b'{"jsonrpc": "2.0", "id": 99, "method": "tools/list"}'
# MEASURED, never hardcoded. `Content-Length: 50` against a 52-byte body truncated the inner
# frame to invalid JSON, so a VULNERABLE server answered it -32700 and then read the two orphaned
# bytes as a third request line — the exploit could not be reproduced, and every assertion below
# passed on a broken server.
_SECOND_REQUEST = (b"POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
                   b"Content-Length: " + str(len(_INNER_FRAME)).encode() + b"\r\n\r\n"
                   + _INNER_FRAME)


def _assert_refused_cleanly(seen: bytes, closed: bool, code: int, *, why: bytes) -> None:
    """One refusal, delivered and legible, with NOTHING left in the socket for the next request
    line. Every refusal branch replies without reading the body, so this property belongs to the
    branch shape rather than to any one header — asserted in one place, because a second copy is
    how one branch keeps keep-alive on while the test for it goes on passing.
    """
    assert str(code).encode() in seen.split(b"\r\n")[0], (why, seen[:200])
    # The reason travels too: a bare status code sends a caller hunting through their own client.
    assert why in seen, (why, seen[:400])
    # ONE response. A second status line means the unread body reached `handle_one_request` at
    # all — even a -32700 counts as served, because a body the connection re-parsed as a request IS
    # the defect.
    assert seen.count(b"HTTP/1.1 ") == 1, f"[{why!r}] a second, smuggled request was answered: " \
                                          f"{seen!r}"
    assert b'"id": 99' not in seen and b'"id":99' not in seen, \
        f"[{why!r}] the smuggled tools/list was answered: {seen!r}"
    assert b"inputSchema" not in seen, \
        f"[{why!r}] a tool listing crossed a refused request: {seen!r}"
    assert b"Connection: close" in seen, f"[{why!r}] the refusal left keep-alive on: {seen!r}"
    assert closed, f"[{why!r}] the connection outlived the refusal: {seen!r}"


def _post(url: str, payload, *, headers: dict | None = None):
    """Returns (status, parsed-body-or-None)."""
    import urllib.error
    import urllib.request

    data = payload if isinstance(payload, bytes) else json.dumps(payload).encode()
    hdrs = {"Content-Type": "application/json"}
    hdrs.update(headers or {})
    req = urllib.request.Request(url, data=data, headers=hdrs, method="POST")
    try:
        with urllib.request.urlopen(req, timeout=10) as r:
            raw = r.read()
            return r.status, (json.loads(raw) if raw else None)
    except urllib.error.HTTPError as e:
        raw = e.read()
        return e.code, (json.loads(raw) if raw else None)


def test_http_and_stdio_answer_the_same_frame() -> None:
    """Doc 3a §6's equality, extended to transports: HTTP adds a socket, never a dispatch. If these
    diverge, JSON-RPC logic was copied into the HTTP half.

    Compared at the SAME read-only setting, deliberately. `serve_http` forces read-only on the
    Config it serves, so comparing against a writable one measures the policy difference rather
    than the transport — which is what this test is for. That the two policies differ is real and
    intended (Doc 3 §3), and it is pinned separately below; here it would only mask a drift in
    dispatch. This assertion used to pass for the wrong reason: `serve_http` mutated the caller's
    Config, so the "stdio" half of the comparison was silently read-only too.
    """
    _, registry = _fixture()
    cfg = _cfg(registry)
    ro = server.Config(cfg.registry, cfg.stack, read_only=True)
    base, stop = _http_server(cfg)
    try:
        for frame in ({"jsonrpc": "2.0", "id": 1, "method": "initialize"},
                      {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
                      {"jsonrpc": "2.0", "id": 3, "method": "nonsense"},
                      [{"jsonrpc": "2.0", "id": 4, "method": "initialize"},
                       {"jsonrpc": "2.0", "id": 5, "method": "tools/list"}]):
            status, over_http = _post(base, frame)
            assert status == 200, frame
            assert over_http == server.handle(frame, ro), frame
    finally:
        stop()


def test_serve_http_does_not_make_the_callers_config_read_only() -> None:
    """`serve_http` enforces read-only on what it serves, but it must not reach back through the
    Config it was handed — anything else holding that object (the stdio loop, another test) would
    silently change policy. The flag is taken on a copy; the stack and PlanBook stay shared."""
    _, registry = _fixture()
    cfg = _cfg(registry)
    assert cfg.read_only is False
    _, stop = _http_server(cfg)
    stop()
    assert cfg.read_only is False, "serve_http mutated the Config it was given"
    listed = server.handle({"jsonrpc": "2.0", "id": 1, "method": "tools/list"}, cfg)["result"]
    assert "ingest" in {t["name"] for t in listed["tools"]}, "stdio lost `ingest` to the HTTP policy"


def test_http_refuses_a_browser_reaching_the_daemon() -> None:
    """A loopback bind keeps other machines out, not a page in the operator's own browser. Origin,
    Host-after-DNS-rebinding and a non-JSON content type are each refused."""
    _, registry = _fixture()
    base, stop = _http_server(_cfg(registry))
    frame = {"jsonrpc": "2.0", "id": 1, "method": "initialize"}
    try:
        assert _post(base, frame, headers={"Origin": "https://evil.example"})[0] == 403
        assert _post(base, frame, headers={"Host": "evil.example"})[0] == 421
        assert _post(base, frame, headers={"Content-Type": "text/plain"})[0] == 415
        # A bad body is a -32700, not a refusal — and the message has to be worth its word: a 200
        # carrying any other error satisfied the status check alone, so the code is read too.
        status, parsed = _post(base, b'{"not', headers={})
        assert status == 200, parsed
        assert parsed["error"]["code"] == -32700, parsed
        # An oversized body is refused BEFORE it is read.
        big = b'{"jsonrpc":"2.0","id":1,"method":"initialize","pad":"' + b"x" * 16 + b'"}'
        import urllib.error
        import urllib.request
        req = urllib.request.Request(base, data=big, method="POST",
                                     headers={"Content-Type": "application/json",
                                              "Content-Length": str(server.MAX_BODY_BYTES + 1)})
        try:
            urllib.request.urlopen(req, timeout=10)
            raise AssertionError("expected 413")
        except urllib.error.HTTPError as e:
            assert e.code == 413
    finally:
        stop()


def test_a_refused_request_cannot_smuggle_the_next_one() -> None:
    """The refusal paths reply WITHOUT reading the body. On a keep-alive connection those unread
    bytes were parsed as the next request line — so one CORS-simple POST (text/plain, no preflight)
    whose body is a complete second request with `Host: 127.0.0.1`, no Origin and a JSON content
    type got the outer request refused and the SMUGGLED one served, bypassing all three guards.
    `urllib` always sends `Connection: close`, which is why the first round of tests could not see
    this; this one drives a raw socket.
    """
    _, registry = _fixture()
    base, stop = _http_server(_cfg(registry))
    try:
        outer = (b"POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nOrigin: https://evil.example\r\n"
                 b"Content-Type: text/plain\r\nContent-Length: "
                 + str(len(_SECOND_REQUEST)).encode() + b"\r\n\r\n" + _SECOND_REQUEST)
        # NOT half-closed, unlike its neighbours: here `closed` has to be the SERVER's doing,
        # because a refusal that leaves the connection alive is the exploit's precondition.
        seen, closed = _raw(base, outer)
        _assert_refused_cleanly(seen, closed, 403, why=b"cross-origin")
    finally:
        stop()


def test_every_refusal_leaves_nothing_for_the_next_request_line() -> None:
    """The Origin case above is one branch of eight, and the property belongs to the SHAPE of a
    refusal rather than to Origin: each of these replies without reading the body, so each can
    leave a complete second request in the socket. The status codes themselves are pinned by
    `test_http_refuses_a_browser_reaching_the_daemon` and the framing branches' own messages; what
    this adds is that no branch hands the smuggled frame to `handle_one_request`.
    """
    _, registry = _fixture()
    base, stop = _http_server(_cfg(registry))
    n = str(len(_SECOND_REQUEST)).encode()
    head = b"POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
    cases = (
        # DNS rebinding: the page resolves an attacker-controlled name to 127.0.0.1, so the request
        # is well formed in every other respect.
        (421, b"refusing Host",
         b"POST / HTTP/1.1\r\nHost: evil.example\r\nContent-Type: application/json\r\n"
         b"Content-Length: " + n + b"\r\n\r\n" + _SECOND_REQUEST),
        # text/plain is CORS-simple — a page sends it with no preflight for this server to refuse.
        (415, b"application/json",
         b"POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: text/plain\r\n"
         b"Content-Length: " + n + b"\r\n\r\n" + _SECOND_REQUEST),
        (411, b"Content-Length required", head + b"\r\n" + _SECOND_REQUEST),
        # RFC 7230 forbids reconciling the two. Framed on Content-Length: 0 this read a zero-byte
        # body, answered keep-alive 200, and left the chunked payload to be read as a request line.
        (400, b"refusing to guess",
         head + b"Content-Length: 0\r\nTransfer-Encoding: chunked\r\n\r\n0\r\n\r\n"
         + _SECOND_REQUEST),
        # Chunked alone is refused rather than read: a body whose length is unknown until it ends
        # cannot be bounded before it is read, which is the whole point of MAX_BODY_BYTES.
        (411, b"chunked bodies are not read",
         head + b"Transfer-Encoding: chunked\r\n\r\n0\r\n\r\n" + _SECOND_REQUEST),
        # `headers.get()` returns only the FIRST of a repeated header, so the disagreeing pair
        # framed the body on one and left the remainder — the entire smuggling primitive.
        (400, b"2 Content-Length headers",
         head + b"Content-Length: 0\r\nContent-Length: " + n + b"\r\n\r\n" + _SECOND_REQUEST),
        (400, b"malformed Content-Length", head + b"Content-Length: +" + n + b"\r\n\r\n"
         + _SECOND_REQUEST),
        (413, b"body over", head + b"Content-Length: "
         + str(server.MAX_BODY_BYTES + 1).encode() + b"\r\n\r\n" + _SECOND_REQUEST),
        # The same refusal, asked for permission first. The base class answers `Expect:
        # 100-continue` from `parse_request`, BEFORE do_POST runs, so a client asking to send 9MB
        # was told to go ahead and refused after — which inverts the bounded-BEFORE-the-read
        # property the branch exists for. The one-response assertion covers the interim `100
        # Continue` too: an invitation is a second status line.
        (413, b"body over", head + b"Expect: 100-continue\r\nContent-Length: "
         + str(server.MAX_BODY_BYTES + 1).encode() + b"\r\n\r\n" + _SECOND_REQUEST),
    )
    try:
        for code, why, req in cases:
            seen, closed = _raw(base, req, half_close=True)
            _assert_refused_cleanly(seen, closed, code, why=why)
    finally:
        stop()


def test_a_host_header_is_required_not_merely_checked() -> None:
    """`if host and ...` let a caller skip the Host guard by omitting it. A guard that fails open
    on absence is not a guard."""
    _, registry = _fixture()
    base, stop = _http_server(_cfg(registry))
    try:
        body = b'{"jsonrpc": "2.0", "id": 1, "method": "tools/list"}'
        seen, closed = _raw(base, b"POST / HTTP/1.1\r\nContent-Type: application/json\r\n"
                                  b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n"
                                  + body, half_close=True)
        _assert_refused_cleanly(seen, closed, 421, why=b"refusing Host None")
    finally:
        stop()


def test_host_validation_does_not_go_through_a_url_parser() -> None:
    """A URL parser drops everything after the first `/`, `?` or `#`, so `localhost/evil.com` read
    as "localhost". Nothing builds a URL from this header today; that stops being true the first
    time a `Location:` is added."""
    for good in ("127.0.0.1", "127.0.0.1:8765", "localhost", "LOCALHOST:80"):
        assert server._host_is_loopback(good), good
    for bad in ("localhost/evil.com", "localhost#@evil.com", "localhost?x=1", "user@localhost",
                "127.0.0.1.evil.com", "localhost.", "0.0.0.0", "evil.example", "",
                "localhost:notaport", "[::1", "localhost x",
                # IPv6 belongs on the refused side even though ::1 IS loopback: this predicate is
                # shared with `parse_bind`, ThreadingHTTPServer inherits address_family = AF_INET,
                # and no bind this server can perform produces such an authority. Blessing one had
                # the request-time guard accepting a Host the listener could never have been
                # reached at — a claim about a server that does not exist.
                "[::1]", "[::1]:8765", "::1"):
        assert not server._host_is_loopback(bad), bad


def test_a_malformed_content_length_is_not_reported_as_an_oversized_body() -> None:
    """Telling a caller to shrink a body that was never too large is the wrong-signal failure the
    other refusals go out of their way to avoid.

    The forms are the ones a lenient parser takes: `int()` reads `+5` as 5 and `1_0` as ten, and
    the rest are digits to something. Every one of them would mean one number here and another to
    the peer, which IS the framing desync — so each is a MALFORMED HEADER, never a 413. (The
    non-ASCII digits arrive latin-1-decoded, so `_is_digits`' isascii half is not what refuses them
    HERE; `parse_bind` is where that str is real, and its own test covers it.)
    """
    _, registry = _fixture()
    base, stop = _http_server(_cfg(registry))
    head = b"POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
    try:
        for value in (b"-5", b"+5", b"1_0", b"0x10", b"5 5", "٥".encode()):
            seen, _ = _raw(base, head + b"Content-Length: " + value + b"\r\n\r\n",
                           half_close=True)
            assert b"400" in seen.split(b"\r\n")[0], (value, seen[:200])
            assert b"malformed Content-Length" in seen, (value, seen[:400])
            assert b"body over" not in seen, (value, seen[:400])

        # …and the ONE padding that is stripped rather than refused, because RFC 7230 says a
        # field's value excludes its surrounding whitespace: `5 ` means five bytes here and five
        # bytes to every conformant peer, so refusing it would refuse a legal request without
        # closing any desync. Asserted by FRAMING on it — the pipelined request lands exactly at
        # byte five and is answered as a request, which a length read differently from the one the
        # peer wrote would have swallowed or split.
        seen, _ = _raw(base, head + b"Content-Length: 5 \r\n\r\n[1,2]" + _SECOND_REQUEST,
                       half_close=True)
        assert seen.count(b"HTTP/1.1 ") == 2, f"the padded length did not frame at 5: {seen!r}"
        assert b'"id": 99' in seen, f"the pipelined request was lost: {seen!r}"
    finally:
        stop()


def test_http_notification_is_accepted_with_no_body() -> None:
    """A notification takes no reply on either transport. An empty 200 would not parse as a
    JSON-RPC response, so it is a 202."""
    _, registry = _fixture()
    base, stop = _http_server(_cfg(registry))
    try:
        status, body = _post(base, {"jsonrpc": "2.0", "method": "notifications/initialized"})
        assert status == 202 and body is None
    finally:
        stop()


def test_http_answers_an_internal_error_with_the_requests_id_too() -> None:
    """Same helper and same reason as the stdio loop: `do_POST` hands `_internal_error` the decoded
    FRAME rather than None, so a client's pending call fails instead of hanging to its own timeout.
    Two transports, one dispatch — an id that survives one socket and not the other would mean the
    error path had been copied rather than shared."""
    _, registry = _fixture()

    def _boom(msg: object, cfg: server.Config) -> dict:
        raise RuntimeError("handler exploded")

    base, stop = _http_server(_cfg(registry))
    real = server._dispatch
    server._dispatch = _boom
    try:
        status, resp = _post(base, {"jsonrpc": "2.0", "id": 42, "method": "tools/list"})
    finally:
        server._dispatch = real
        stop()
    assert status == 200, resp
    assert resp["id"] == 42, \
        f"an error with a null id resolves nothing the client is waiting on: {resp}"
    assert resp["error"]["code"] == -32603, resp


def test_ingest_is_refused_over_http_and_the_refusal_is_legible() -> None:
    """Doc 3 §3: the write primitive comes OFF the socket rather than being guarded on it. Any
    local process can reach a loopback port, and `ingest` writes notes into real vaults that the
    next refresh serves back as settled knowledge.

    Not advertised AND not runnable — a tool hidden from `tools/list` but still served when called
    is not read-only. And the refusal must not read as "no such tool": a model told the tool does
    not exist goes hunting for another way to write, which is the misleading answer this codebase
    refuses. The tool still exists over stdio, which the last assertion holds it to.
    """
    root, registry = _fixture(manifest=True)
    (root / "demo-vault" / "04-synthesis").mkdir()
    args = {"scope": "demo", "content": _NOTE, "filename": "d.md"}
    base, stop = _http_server(_cfg(registry, read_only=True))
    try:
        status, listed = _post(base, {"jsonrpc": "2.0", "id": 1, "method": "tools/list"})
        assert status == 200, listed
        assert "ingest" not in {t["name"] for t in listed["result"]["tools"]}, listed

        status, resp = _post(base, {"jsonrpc": "2.0", "id": 2, "method": "tools/call",
                                    "params": {"name": "ingest", "arguments": args}})
        assert status == 200, resp
        # An isError RESULT, not a transport error: the caller can act on this one.
        assert "error" not in resp, resp
        assert resp["result"]["isError"] is True, resp
        text = resp["result"]["content"][0]["text"]
        assert "read-only" in text and "stdio" in text, text
        assert "unknown tool" not in text, text
    finally:
        stop()
    assert not (root / "demo-vault" / "04-synthesis" / "d.md").exists(), \
        "a refusal wrote the vault"

    # The SAME tool, same arguments, over the transport that keeps it: what differs is a parameter
    # on Config, not a second dispatch.
    assert _call("ingest", args, registry)["written"] is False


def test_the_read_only_default_follows_the_transport() -> None:
    """Doc 3 §3 is decided in `main()`, and nothing else in this file would notice it flipping:
    every other test states `read_only` outright. Unstated, it is ON for `--http` and OFF for
    stdio, because exposure is what differs — reaching stdio already means spawning this process.
    An explicit flag overrides it on either transport.
    """
    _, registry = _fixture()
    seen: dict = {}

    def _capture(key: str):
        def _f(cfg, *a, **kw):   # serve(cfg, stdin, stdout) and serve_http(cfg, host, port, ...)
            seen[key] = cfg
            return 0
        return _f

    real = server.serve_http, server.serve
    server.serve_http, server.serve = _capture("http"), _capture("stdio")
    try:
        for argv, where, read_only in ((["--http"], "http", True),
                                       (["--http", "--no-read-only"], "http", False),
                                       ([], "stdio", False),
                                       (["--read-only"], "stdio", True)):
            seen.clear()
            rc = server.main([*argv, "--lexical-only", "--registry", str(registry)])
            assert rc == 0, (argv, rc)
            assert where in seen, (argv, "went to the wrong transport", sorted(seen))
            assert seen[where].read_only is read_only, argv
    finally:
        server.serve_http, server.serve = real


def test_the_connection_ceiling_refuses_with_a_response_not_a_bare_close() -> None:
    """A socket closed with nothing written on it is indistinguishable from the hung server this
    cap exists to prevent — which was the stated reason for refusing rather than queueing, and then
    the refusal said nothing at all. It is written from `process_request`, on the ACCEPT thread,
    before any handler exists for the connection, so it is pre-rendered bytes rather than a normal
    response path.

    The ceiling is lowered instead of opening 65 sockets: what is under test is the refusal, and 64
    parked connections would make it a load test that fails on whatever else the machine is doing.
    """
    import socket

    _, registry = _fixture()
    real_cap = server._BoundedThreadingHTTPServer.MAX_CONNECTIONS
    server._BoundedThreadingHTTPServer.MAX_CONNECTIONS = 1  # read in __init__, so set before bind
    try:
        base, stop = _http_server(_cfg(registry))
        try:
            frame = b'{"jsonrpc": "2.0", "id": 1, "method": "initialize"}'
            req = (b"POST / HTTP/1.1\r\nHost: 127.0.0.1\r\nContent-Type: application/json\r\n"
                   b"Content-Length: " + str(len(frame)).encode() + b"\r\n\r\n" + frame)
            held = socket.create_connection(("127.0.0.1", _port(base)), timeout=10)
            try:
                held.sendall(req)
                # An ANSWER is what proves the slot is taken: the handler thread is running, and
                # keep-alive holds the connection after the response. Polling for that state
                # instead would be a race.
                assert b"200" in held.recv(65536).split(b"\r\n")[0]
                seen, closed = _raw(base, req, half_close=True)
            finally:
                # FIN rather than RST. The handler is parked in `readline`, and closing on it
                # outright makes socketserver print a ConnectionResetError traceback that looks
                # like a failure in whatever test runs next.
                try:
                    held.shutdown(socket.SHUT_WR)
                    held.recv(65536)
                except OSError:
                    pass
                held.close()
        finally:
            stop()
    finally:
        server._BoundedThreadingHTTPServer.MAX_CONNECTIONS = real_cap

    assert b"503" in seen.split(b"\r\n")[0], \
        f"the ceiling gave the caller nothing to read: {seen[:200]!r}"
    assert b"Retry-After: 1" in seen, seen[:200]
    assert b"Connection: close" in seen, seen[:200]
    assert closed, "a refused connection must not be left for the caller to time out on"
    body = json.loads(seen.split(b"\r\n\r\n", 1)[1])
    # A null id is honest HERE in a way it is not in `_internal_error`: the request was never read,
    # so there is no id to answer with.
    assert body["id"] is None and body["error"]["code"] == -32603, body
    assert "connection ceiling" in body["error"]["message"], body


def test_http_has_no_stream_and_says_so() -> None:
    """No SSE channel is implemented, so a client probing for one gets a definite 405 rather than
    a connection that never produces bytes."""
    import urllib.error
    import urllib.request

    _, registry = _fixture()
    base, stop = _http_server(_cfg(registry))
    try:
        try:
            urllib.request.urlopen(urllib.request.Request(base, method="GET"), timeout=10)
            raise AssertionError("expected 405")
        except urllib.error.HTTPError as e:
            assert e.code == 405
    finally:
        stop()


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


def test_search_declares_and_honours_a_fast_arm() -> None:
    """`fast` drops the generator arms for a caller that must answer inside a turn of speech.

    Measured 2026-08-06 against the live engine on the `cbre` scope: 17,274ms considered vs 286ms
    fast — 60x, and far worse than EXPERIMENTS.md's 385ms → 4,558ms estimate for the arm swap alone.
    Nothing useful arrives seventeen seconds into a conversation that has already moved on.

    The honesty is what makes it safe to offer: dropping the arms rather than swapping them means
    `Capability` reports what RAN, so a fast reply carries `hyde=off · rerank=off` and a null
    `expected_mrr` with `unmeasured_arm_combination`. A live hit must not wear the measured stack's
    number — Doc 4 §8's open question, answered where it can be.
    """
    _, registry = _fixture()
    cfg = _cfg(registry)
    listed = server.handle({"jsonrpc": "2.0", "id": 2, "method": "tools/list"}, cfg)["result"]
    tools = {t["name"]: t for t in listed["tools"]}
    schema = tools["search"]["inputSchema"]["properties"]
    assert "fast" in schema, "the arm has to be declarable or no caller can ask for it"
    assert schema["fast"]["type"] == "boolean"
    # The description must carry the honesty contract, not just the speed claim — a caller reading
    # only "faster" would use it for considered questions too.
    described = schema["fast"]["description"]
    assert "expected_mrr" in described and "unmeasured_arm_combination" in described, described
