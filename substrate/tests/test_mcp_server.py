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

import io
import json
import os
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


class _FakeEmbedder:
    """Wired but never used — these tests assert what STATUS reports about an index, which must
    not depend on a local daemon being up."""

    key = "qwen3-embedding:0.6b#raw"
    model = "qwen3-embedding:0.6b"


def _cfg(registry: Path) -> server.Config:
    """Lexical-only, always. A test that depended on a local daemon would pass or fail on whether
    Ollama happened to be running, which is not a property of this code."""
    return server.Config(str(registry), stack.build(lexical_only=True))


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

    root = Path(tempfile.mkdtemp())
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
                       supersedes="old-composition")
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
    assert p["supersedes"] == "old-composition"
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
                                                    "status"}
    assert set(listed["tools"][0]) >= {"name", "description", "inputSchema"}
    for t in listed["tools"]:
        assert t["inputSchema"]["type"] == "object"
    # Doc 3a §4: the tool surface stays small — fewer tools, less resident schema every turn.
    assert len(listed["tools"]) <= 5, "resist adding tools that are parameter variants"


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
