"""Agent mode: one scope, served to another user from a published snapshot it cannot write.

The fixture registers THREE scopes — `prism` (allowed), `cbre` and `school` — so a refusal that
leaks the registry is visible: an error naming `cbre` or `school` would be exactly the sentence
`scopes.resolve` writes, which is the leak agent mode exists to close.

After publishing, the operator's index and vault are MOVED AWAY. Every agent-side assertion runs
against that state, so a path that quietly fell back to the live index or the vault on disk fails
here rather than passing on a machine where both happen to be readable.
"""

from __future__ import annotations

import hashlib
import io
import json
import os
import sqlite3
import sys
from datetime import UTC, datetime, timedelta
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import agent, cli, refresh_state, scopes, stack  # noqa: E402
from substrate.mcp import server  # noqa: E402
from substrate.models import Chunk, Document  # noqa: E402
from substrate.store.index_store import IndexStore  # noqa: E402

_BODY = ("Snapshot publishing copies the index into a shared folder for the agent. " * 10).strip()
_GUARDED = "Transcript of a guarded workspace call that the agent must never see."
OTHERS = ("cbre", "school")


def _scope(root: Path, registry: Path, name: str, *, guarded: bool = False) -> Path:
    """One composed-looking scope: a project vault with a manifest, two notes (one in a subfolder,
    one owned by an inherited tier), and an index whose rows mirror what `compose` stores."""
    vault = root / f"{name}-vault"
    (vault / "02-areas").mkdir(parents=True)
    manifest = f'name = "{name}"\ninherits = []\n'
    if guarded:
        manifest += f'guard_state = "{root / "state.json"}"\n'
    (vault / ".substrate.toml").write_text(manifest, encoding="utf-8")

    db = root / f"{name}.db"
    with IndexStore(str(db)) as s:
        # Guarded: the decision is INHERITED (core-vault) and the call is the guarded vault's own,
        # so withholding one vault and not the scope is what the publish test can see.
        notes = [("decision", vault / "02-areas" / "decision.md",
                  "core-vault" if guarded else f"{name}-vault", _BODY)]
        if guarded:
            notes.append(("call", vault / "call.md", f"{name}-vault", _GUARDED))
        for doc_id, path, owner, text in notes:
            path.write_text(f"# {doc_id}\n\n{text}\n", encoding="utf-8")
            doc = Document(doc_id=doc_id, source_path=str(path),
                           source_sha256=hashlib.sha256(path.read_bytes()).hexdigest(),
                           source_pages=1, document_class="reference-frozen", title=doc_id,
                           status="active", doc_type="decision", confidence="stated",
                           vault=owner, tier=3, domains=["agent"], supersedes=[])
            ch = Chunk(chunk_id=f"{doc_id}#c00000", doc_id=doc_id, kind="passage", text=text,
                       path=[doc_id], level=1, n_chars=len(text),
                       document_class="reference-frozen")
            s.upsert(doc, [ch], markdown_path=str(root / f"{name}-index" / doc_id / "document.md"),
                     markdown_mtime=0.0, markdown_sha256="d" * 64)
    scopes.record(name, vault=vault, db=db, index_root=root, registry=registry)
    return vault


@pytest.fixture
def world(tmp_path):
    """The operator's side, published, then made unreachable. Returns (shared dir, registry)."""
    home = tmp_path / "operator"
    home.mkdir()
    registry = home / "scopes.toml"
    for name in ("prism", *OTHERS):
        _scope(home, registry, name)
    refresh_state.record("prism", "refreshed", registry=registry)
    shared = tmp_path / "shared"
    shared.mkdir()
    agent.publish("prism", shared, registry=registry)
    return shared, registry


def _hide(registry: Path) -> None:
    """The agent cannot read the operator's home: rename it away."""
    home = registry.parent
    home.rename(home.with_name("operator-gone"))


def _cfg(shared: Path, **kw) -> server.Config:
    return server.Config(None, stack.build(lexical_only=True),
                         agent=agent.AgentScopes(["prism"], shared, **kw))


def _rpc(cfg, method: str, params: dict | None = None) -> dict:
    return server.handle({"jsonrpc": "2.0", "id": 1, "method": method, "params": params or {}},
                         cfg)


def _call(cfg, tool: str, args: dict) -> tuple[dict | str, bool]:
    body = _rpc(cfg, "tools/call", {"name": tool, "arguments": args})["result"]
    text = body["content"][0]["text"]
    return (text, True) if body.get("isError") else (json.loads(text), False)


# --------------------------------------------------------------------------- allowed scope

def test_search_and_expand_answer_from_the_snapshot_alone(world):
    shared, registry = world
    _hide(registry)
    cfg = _cfg(shared)

    res, err = _call(cfg, "search", {"scope": "prism", "query": "snapshot publishing"})
    assert not err, res
    assert res["passages"], "the allowed scope must answer"
    ref = res["passages"][0]["expand_ref"]

    passage, err = _call(cfg, "expand", {"expand_ref": ref})
    assert not err, passage
    assert passage["passage"]["text"] == _BODY

    note, err = _call(cfg, "expand", {"expand_ref": ref, "mode": "note"})
    assert not err, note
    assert _BODY in note["note"]["text"]
    # Vault-relative, never the operator's absolute path.
    assert note["note"]["path"] == "prism-vault/02-areas/decision.md"
    assert note["note"]["stale"] is False

    for tool in ("status", "documents"):
        out, err = _call(cfg, tool, {"scope": "prism"})
        assert not err, out


def test_list_scopes_names_only_the_allowed_scope(world):
    shared, registry = world
    _hide(registry)
    out, err = _call(_cfg(shared), "list_scopes", {})
    assert not err
    assert [r["scope"] for r in out["scopes"]] == ["prism"]
    text = json.dumps(out)
    assert not any(o in text for o in OTHERS)


# --------------------------------------------------------------------------- disallowed scopes

@pytest.mark.parametrize("tool", ["search", "status", "documents"])
@pytest.mark.parametrize("scope", ["cbre", "school", "nope", "../prism", "prism/..", "PRISM", ""])
def test_any_other_scope_is_refused_without_naming_one(world, tool, scope):
    shared, registry = world
    _hide(registry)
    args = {"scope": scope, "query": "snapshot"} if tool == "search" else {"scope": scope}
    text, err = _call(_cfg(shared), tool, args)
    assert err
    if scope:
        assert text == f"ToolError: {agent.UNAVAILABLE}"
    else:
        assert not any(n in text for n in ("prism", *OTHERS))


@pytest.mark.parametrize("ref", [
    "cbre/decision#c00000",            # another scope's ref, well-formed
    "school/decision#c00000",
    "prism/../../../etc/passwd",       # traversal in the chunk id
    "prism/../cbre/decision#c00000",
    "../prism/decision#c00000",        # traversal in the scope
    "/etc/passwd",
    "prism/",
])
def test_expand_accepts_only_refs_inside_the_snapshot(world, ref):
    shared, registry = world
    _hide(registry)
    for mode in ("passage", "note"):
        text, err = _call(_cfg(shared), "expand", {"expand_ref": ref, "mode": mode})
        assert err, text
        assert "root:" not in text
        # The caller's own ref may be echoed back; nothing beyond it may name another scope.
        echoed = text.replace(ref, "").replace(ref.partition("/")[2], "")
        assert not any(o in echoed for o in OTHERS)


# --------------------------------------------------------------------------- read-only

def test_ingest_is_not_registered(world):
    shared, _ = world
    cfg = _cfg(shared)
    names = [t["name"] for t in _rpc(cfg, "tools/list")["result"]["tools"]]
    assert "ingest" not in names
    assert set(names) == {"search", "expand", "documents", "list_scopes", "status"}
    resp = _rpc(cfg, "tools/call", {"name": "ingest", "arguments": {"scope": "prism"}})
    assert resp["error"]["code"] == -32602 and "unknown tool" in resp["error"]["message"]


def test_the_snapshot_is_opened_read_only(world):
    shared, _ = world
    entry, store = agent.AgentScopes(["prism"], shared).open("prism")
    try:
        with pytest.raises(sqlite3.OperationalError):
            store.db.execute("INSERT INTO snapshot_meta(key, value) VALUES ('x', 'y')")
        with pytest.raises(sqlite3.OperationalError):
            store.db.execute("DELETE FROM chunks")
    finally:
        store.close()
    assert sorted(p.name for p in shared.iterdir()) == ["prism.snapshot.db",
                                                        "prism.snapshot.json"]


def _tree(root: Path) -> dict[str, tuple[int, int]]:
    return {str(p.relative_to(root)): (p.stat().st_size, p.stat().st_mtime_ns)
            for p in sorted(root.rglob("*"))}


def test_agent_mode_writes_nothing_and_never_reads_the_registry(world, tmp_path, monkeypatch):
    shared, registry = world
    _hide(registry)
    agent_home = tmp_path / "agent-home"
    agent_home.mkdir()
    monkeypatch.setenv("HOME", str(agent_home))
    monkeypatch.chdir(agent_home)

    def forbidden(*a, **kw):
        raise AssertionError("agent mode reached the operator's registry or refresh record")

    monkeypatch.setattr(scopes, "load", forbidden)
    monkeypatch.setattr(scopes, "resolve", forbidden)
    monkeypatch.setattr(refresh_state, "report", forbidden)

    built = {}
    real_build = stack.build

    def capture(**kw):
        built.update(kw)
        return real_build(lexical_only=True)

    monkeypatch.setattr(server.stack, "build", capture)

    shared.chmod(0o555)
    before = _tree(tmp_path)
    frames = [
        {"jsonrpc": "2.0", "id": 1, "method": "initialize", "params": {}},
        {"jsonrpc": "2.0", "id": 2, "method": "tools/list"},
        {"jsonrpc": "2.0", "id": 3, "method": "tools/call",
         "params": {"name": "search", "arguments": {"scope": "prism", "query": "snapshot"}}},
        {"jsonrpc": "2.0", "id": 4, "method": "tools/call",
         "params": {"name": "expand",
                    "arguments": {"expand_ref": "prism/decision#c00000", "mode": "note"}}},
        {"jsonrpc": "2.0", "id": 5, "method": "tools/call",
         "params": {"name": "status", "arguments": {"scope": "prism"}}},
        {"jsonrpc": "2.0", "id": 6, "method": "tools/call",
         "params": {"name": "documents", "arguments": {"scope": "prism"}}},
        {"jsonrpc": "2.0", "id": 7, "method": "tools/call",
         "params": {"name": "list_scopes", "arguments": {}}},
    ]
    out = io.StringIO()
    monkeypatch.setattr(sys, "stdin", io.StringIO("\n".join(json.dumps(f) for f in frames)))
    monkeypatch.setattr(sys, "stdout", out)
    try:
        rc = server.main(["--agent-mode", "--scopes", "prism", "--snapshot-dir", str(shared)])
    finally:
        shared.chmod(0o755)
    assert rc == 0
    replies = [json.loads(line) for line in out.getvalue().splitlines()]
    assert len(replies) == 7
    for r in replies[2:]:
        assert not r["result"].get("isError"), r
    assert built["cache_path"] == ":memory:"
    assert _tree(tmp_path) == before


@pytest.mark.parametrize("extra", [["--registry", "/x.toml"], ["--http"], ["--no-read-only"]])
def test_agent_mode_refuses_flags_that_reach_past_the_snapshot(world, extra):
    shared, _ = world
    assert server.main(["--agent-mode", "--scopes", "prism", "--snapshot-dir", str(shared),
                        "--lexical-only", *extra]) == 2


def test_agent_mode_needs_its_scopes_and_folder():
    assert server.main(["--agent-mode", "--lexical-only"]) == 2
    assert server.main(["--scopes", "prism", "--lexical-only"]) == 2


# --------------------------------------------------------------------------- freshness

def test_a_stale_snapshot_says_so(world):
    shared, registry = world
    old = datetime.now(UTC) - timedelta(days=3)
    agent.publish("prism", shared, registry=registry, now=old)
    # Same content, so the publish above only re-verified — at the OLD time.
    _hide(registry)
    res, err = _call(_cfg(shared), "search", {"scope": "prism", "query": "snapshot"})
    assert not err
    snap = res["refresh"]["snapshot"]
    assert snap["stale"] is True and snap["age_seconds"] >= 3 * 86400
    assert res["refresh"]["note"].startswith("STALE SNAPSHOT")
    status, _ = _call(_cfg(shared), "status", {"scope": "prism"})
    assert status["refresh"]["snapshot"]["stale"] is True
    assert "error" in status["drift"]


def test_a_fresh_snapshot_is_not_stale_and_carries_the_operators_verdict(world):
    shared, registry = world
    _hide(registry)
    res, _ = _call(_cfg(shared), "search", {"scope": "prism", "query": "snapshot"})
    assert res["refresh"]["snapshot"]["stale"] is False
    assert res["refresh"]["known"] is True and res["refresh"]["outcome"] == "refreshed"
    assert res["refresh"]["frozen"] is False


def test_a_failed_refresh_reaches_the_agent_as_frozen(world):
    shared, registry = world
    refresh_state.record("prism", "compose_failed", registry=registry)
    assert agent.after_refresh_record("prism", "compose_failed", registry=registry) is None
    (registry.parent / agent.CONFIG_FILENAME).write_text(
        f'[publish.prism]\ndir = "{shared}"\n', encoding="utf-8")
    db_before = (shared / "prism.snapshot.db").stat().st_mtime_ns
    assert agent.after_refresh_record("prism", "compose_failed", registry=registry)
    assert (shared / "prism.snapshot.db").stat().st_mtime_ns == db_before
    _hide(registry)
    res, _ = _call(_cfg(shared), "search", {"scope": "prism", "query": "snapshot"})
    assert res["refresh"]["frozen"] is True


def test_a_missing_manifest_reads_as_unknown_age_not_fresh(world):
    shared, registry = world
    (shared / "prism.snapshot.json").unlink()
    _hide(registry)
    res, err = _call(_cfg(shared), "search", {"scope": "prism", "query": "snapshot"})
    assert not err
    assert res["refresh"]["snapshot"]["stale"] is None
    assert res["refresh"]["known"] is False


# --------------------------------------------------------------------------- the publisher

def test_publishing_strips_guarded_notes_and_operator_paths(tmp_path):
    home = tmp_path / "operator"
    home.mkdir()
    registry = home / "scopes.toml"
    _scope(home, registry, "prism", guarded=True)
    shared = tmp_path / "shared"
    shared.mkdir()
    p = agent.publish("prism", shared, registry=registry)
    assert set(p.withheld) == {"prism", "prism-vault"}
    raw = (shared / "prism.snapshot.db").read_bytes()
    assert _GUARDED.encode() not in raw, "a withheld note survived in the file"
    assert str(home).encode() not in raw, "an operator path survived in the file"
    assert oct((shared / "prism.snapshot.db").stat().st_mode & 0o777) == oct(agent.FILE_MODE)

    _hide(registry)
    res, _ = _call(_cfg(shared), "documents", {"scope": "prism"})
    assert [d["title"] for d in res["documents"]] == ["decision"]
    assert res["total"] == 1


def test_an_unchanged_index_is_verified_not_rewritten(world):
    shared, registry = world
    before = (shared / "prism.snapshot.db").stat().st_mtime_ns
    p = agent.publish("prism", shared, registry=registry)
    assert not p.rewrote
    assert (shared / "prism.snapshot.db").stat().st_mtime_ns == before


def test_publishing_never_creates_the_shared_folder(world, tmp_path):
    _, registry = world
    with pytest.raises(agent.AgentError):
        agent.publish("prism", tmp_path / "absent", registry=registry)
    assert not (tmp_path / "absent").exists()


def test_refresh_record_publishes_and_a_publish_failure_does_not_fail_the_record(
        world, tmp_path, capsys):
    shared, registry = world
    (registry.parent / agent.CONFIG_FILENAME).write_text(
        f'[publish.prism]\ndir = "{shared}"\n', encoding="utf-8")
    (shared / "prism.snapshot.db").unlink()
    assert cli.main(["refresh-record", "--scope", "prism", "--outcome", "refreshed",
                     "--registry", str(registry), "--quiet"]) == 0
    assert (shared / "prism.snapshot.db").is_file()

    (registry.parent / agent.CONFIG_FILENAME).write_text(
        f'[publish.prism]\ndir = "{tmp_path / "absent"}"\n', encoding="utf-8")
    assert cli.main(["refresh-record", "--scope", "prism", "--outcome", "refreshed",
                     "--registry", str(registry), "--quiet"]) == 0
    assert "WARNING (agent snapshot prism)" in capsys.readouterr().err


def test_a_scope_not_in_the_config_is_never_published(world):
    shared, registry = world
    (registry.parent / agent.CONFIG_FILENAME).write_text(
        f'[publish.prism]\ndir = "{shared}"\n', encoding="utf-8")
    assert agent.after_refresh_record("cbre", "refreshed", registry=registry) is None
    assert not (shared / "cbre.snapshot.db").exists()


def test_a_file_at_the_snapshot_path_must_be_that_scopes_snapshot(world):
    shared, registry = world
    agent.publish("prism", shared, registry=registry)
    other = shared / "other"
    other.mkdir()
    os.replace(shared / "prism.snapshot.db", other / "x.db")
    con = sqlite3.connect(other / "x.db")
    con.execute("UPDATE snapshot_meta SET value='cbre' WHERE key='scope'")
    con.commit()
    con.close()
    os.replace(other / "x.db", shared / "prism.snapshot.db")
    text, err = _call(_cfg(shared), "search", {"scope": "prism", "query": "snapshot"})
    assert err and "cbre" not in text


# --------------------------------------------------------------------------- crosscheck regressions

def test_an_identity_only_change_republishes_rather_than_reverifying(world):
    shared, registry = world
    entry = scopes.resolve("prism", registry)
    with IndexStore(str(entry.db)) as s:
        s.replace_identity([("ada", "Ada Lovelace", "person", None)])
        s.set_document_entities("decision", [("ada", "Ada")])
    p = agent.publish("prism", shared, registry=registry)
    assert p.rewrote, "the roster changed, so the snapshot must be rebuilt"
    _hide(registry)
    status, _ = _call(_cfg(shared), "status", {"scope": "prism"})
    assert [e["name"] for e in status["entities"]] == ["Ada"]


def test_a_symlinked_or_shared_writable_folder_is_refused(world, tmp_path):
    shared, registry = world
    link = tmp_path / "link"
    link.symlink_to(shared)
    with pytest.raises(agent.AgentError):
        agent.publish("prism", link, registry=registry)
    loose = tmp_path / "loose"
    loose.mkdir()
    loose.chmod(0o777)
    with pytest.raises(agent.AgentError):
        agent.publish("prism", loose, registry=registry)
    assert not (loose / "prism.snapshot.db").exists()


def test_a_manifest_planted_as_a_symlink_is_not_read_through(world, tmp_path):
    shared, registry = world
    secret = tmp_path / "secret.json"
    secret.write_text('{"scopes": {"cbre": {}}, "token": "s3cr3t"}', encoding="utf-8")
    secret.chmod(0o600)
    manifest = shared / "prism.snapshot.json"
    manifest.unlink()
    manifest.symlink_to(secret)
    # Nothing readable through the link, so nothing to annotate and nothing copied out.
    assert agent.annotate("prism", shared, registry=registry) == "absent"
    assert manifest.is_symlink()
    assert "s3cr3t" not in "".join(p.read_text(errors="replace") for p in shared.iterdir()
                                   if p.is_file() and not p.is_symlink())


# --------------------------------------------------------------------------- adversary regressions

_SECRET = "zqxjsecrettoken"


@pytest.mark.parametrize("after", ["kept", "deleted", "retargeted"])
def test_a_document_compose_read_from_outside_the_vaults_is_excluded_whole(tmp_path, after):
    """Compose indexes a symlinked note THROUGH the link, so the outside file's text is in the
    passages and the search index — this builds the index that way. The secret must not reach
    the snapshot by either door, and what the link looks like NOW does not matter: deleted, or
    swapped for an innocent file, the chunks still hold what compose read.

    The token is one lowercase word because FTS5 stores tokens lowercased without separators: a
    phrase with spaces would be absent from the raw bytes even if the FTS index still held it."""
    secret_text = f"{_SECRET} " * 20
    home = tmp_path / "operator"
    home.mkdir()
    registry = home / "scopes.toml"
    vault = _scope(home, registry, "prism")
    secret = tmp_path / "operator-only.md"
    secret.write_text(secret_text, encoding="utf-8")
    link = vault / "02-areas" / "linked.md"
    link.symlink_to(secret)
    with IndexStore(str(home / "prism.db")) as s:
        for doc_id, source in (("linked", link), ("outside", secret)):
            doc = Document(doc_id=doc_id, source_path=str(source),
                           source_sha256=hashlib.sha256(secret.read_bytes()).hexdigest(),
                           source_pages=1, document_class="reference-frozen", title=_SECRET,
                           status="active", doc_type="decision", confidence="stated",
                           vault="prism-vault", tier=3, domains=[], supersedes=[])
            ch = Chunk(chunk_id=f"{doc_id}#c00000", doc_id=doc_id, kind="passage",
                       text=secret_text, path=[doc_id], level=1, n_chars=len(secret_text),
                       document_class="reference-frozen")
            s.upsert(doc, [ch], markdown_path="x", markdown_mtime=0.0, markdown_sha256="d" * 64)
    if after == "deleted":
        link.unlink()
    elif after == "retargeted":
        link.unlink()
        link.write_text("an innocent note\n", encoding="utf-8")
    shared = tmp_path / "shared"
    shared.mkdir()
    p = agent.publish("prism", shared, registry=registry)
    assert p.excluded == 2
    assert _SECRET.encode() not in (shared / "prism.snapshot.db").read_bytes()
    _hide(registry)
    res, err = _call(_cfg(shared), "search", {"scope": "prism", "query": _SECRET})
    assert not err and all(_SECRET not in json.dumps(x) for x in res["passages"])
    docs, _ = _call(_cfg(shared), "documents", {"scope": "prism"})
    assert [d["title"] for d in docs["documents"]] == ["decision"]


def test_a_note_symlinked_within_its_vault_is_still_served(tmp_path):
    home = tmp_path / "operator"
    home.mkdir()
    registry = home / "scopes.toml"
    vault = _scope(home, registry, "prism")
    real = vault / "02-areas" / "decision.md"
    moved = vault / "02-areas" / "decision-real.md"
    real.rename(moved)
    real.symlink_to(moved)
    shared = tmp_path / "shared"
    shared.mkdir()
    assert agent.publish("prism", shared, registry=registry).excluded == 0
    _hide(registry)
    out, err = _call(_cfg(shared), "expand",
                     {"expand_ref": "prism/decision#c00000", "mode": "note"})
    assert not err and _BODY in out["note"]["text"]


def _add_real_doc(registry: Path, doc_id: str, text: str) -> Path:
    """A second note indexed the way compose would: a vault file and its real checksum."""
    entry = scopes.resolve("prism", registry)
    note = Path(entry.vault) / "02-areas" / f"{doc_id}.md"
    note.write_text(f"# {doc_id}\n\n{text}\n", encoding="utf-8")
    with IndexStore(str(entry.db)) as s:
        doc = Document(doc_id=doc_id, source_path=str(note),
                       source_sha256=hashlib.sha256(note.read_bytes()).hexdigest(),
                       source_pages=1, document_class="reference-frozen", title=doc_id,
                       status="active", doc_type="decision", confidence="stated",
                       vault="prism-vault", tier=3, domains=[], supersedes=[])
        ch = Chunk(chunk_id=f"{doc_id}#c00000", doc_id=doc_id, kind="passage", text=text,
                   path=[doc_id], level=1, n_chars=len(text), document_class="reference-frozen")
        s.upsert(doc, [ch], markdown_path="x", markdown_mtime=0.0, markdown_sha256="d" * 64)
    return note


def test_a_note_edited_since_compose_is_left_out_until_recompose(world):
    """Its chunks are the OLD text and nothing on disk vouches for them any more, so it is not
    served — not even as `stale`. The refresh that recomposes it brings it back."""
    shared, registry = world
    _add_real_doc(registry, "other", _BODY)
    note = Path(scopes.resolve("prism", registry).vault) / "02-areas" / "decision.md"
    note.write_text(note.read_text(encoding="utf-8") + "\nAn edit compose has not seen.\n",
                    encoding="utf-8")
    p = agent.publish("prism", shared, registry=registry)
    assert p.rewrote and p.excluded == 1
    _hide(registry)
    text, err = _call(_cfg(shared), "expand", {"expand_ref": "prism/decision#c00000"})
    assert err
    out, err = _call(_cfg(shared), "expand", {"expand_ref": "prism/other#c00000", "mode": "note"})
    assert not err and out["note"]["stale"] is False


def test_a_snapshot_with_every_note_excluded_is_refused_not_published(world):
    shared, registry = world
    before = (shared / "prism.snapshot.db").read_bytes()
    note = Path(scopes.resolve("prism", registry).vault) / "02-areas" / "decision.md"
    note.write_text("edited", encoding="utf-8")
    with pytest.raises(agent.AgentError, match="empty snapshot"):
        agent.publish("prism", shared, registry=registry)
    assert (shared / "prism.snapshot.db").read_bytes() == before


def test_an_index_that_changes_during_the_copy_is_not_published(world, monkeypatch):
    shared, registry = world
    (shared / "prism.snapshot.db").unlink()
    real, calls = agent._fingerprint, []

    def drifting(*a):
        calls.append(1)
        return real(*a) + ("x" if len(calls) > 1 else "")

    monkeypatch.setattr(agent, "_fingerprint", drifting)
    with pytest.raises(agent.AgentError, match="changed while it was being copied"):
        agent.publish("prism", shared, registry=registry)
    assert sorted(p.name for p in shared.iterdir()) == ["prism.snapshot.json"]


def test_publishes_of_one_scope_are_serialized(world):
    import threading

    shared, registry = world
    done = threading.Event()
    with agent._publish_lock("prism", registry):
        t = threading.Thread(target=lambda: (agent.publish("prism", shared, registry=registry),
                                             done.set()))
        t.start()
        assert not done.wait(0.5), "publish ran while another held the scope's lock"
    t.join(10)
    assert done.is_set()


def test_a_guard_declared_after_publishing_withdraws_the_snapshot_on_a_failed_refresh(world):
    shared, registry = world
    (registry.parent / agent.CONFIG_FILENAME).write_text(
        f'[publish.prism]\ndir = "{shared}"\n', encoding="utf-8")
    vault = Path(scopes.resolve("prism", registry).vault)
    manifest = vault / ".substrate.toml"
    manifest.write_text(manifest.read_text(encoding="utf-8")
                        + f'guard_state = "{registry.parent / "state.json"}"\n', encoding="utf-8")
    refresh_state.record("prism", "compose_failed", registry=registry)
    line = agent.after_refresh_record("prism", "compose_failed", registry=registry)
    assert "WITHDRAWN" in line
    assert not (shared / "prism.snapshot.db").exists()
    text, err = _call(_cfg(shared), "search", {"scope": "prism", "query": "snapshot"})
    assert err and "no published snapshot" in text


# --------------------------------------------------------------------------- fix-pass crosscheck regressions

def _add_doc(db: Path, doc_id: str, vault: str, source: Path) -> None:
    with IndexStore(str(db)) as s:
        doc = Document(doc_id=doc_id, source_path=str(source), source_sha256="0" * 64,
                       source_pages=1, document_class="reference-frozen", title=doc_id,
                       status="active", doc_type="decision", confidence="stated",
                       vault=vault, tier=3, domains=[], supersedes=[])
        ch = Chunk(chunk_id=f"{doc_id}#c00000", doc_id=doc_id, kind="passage", text=_BODY,
                   path=[doc_id], level=1, n_chars=len(_BODY), document_class="reference-frozen")
        s.upsert(doc, [ch], markdown_path=str(source), markdown_mtime=0.0,
                 markdown_sha256="d" * 64)


@pytest.mark.parametrize("rebuild", [True, False])
@pytest.mark.parametrize("change", ["added", "moved"])
def test_a_document_that_changes_while_notes_are_read_is_not_published(world, monkeypatch,
                                                                        change, rebuild):
    shared, registry = world
    entry = scopes.resolve("prism", registry)
    if rebuild:
        (shared / "prism.snapshot.db").unlink()
    before = None if rebuild else (shared / "prism.snapshot.db").read_bytes()
    manifest_before = (shared / "prism.snapshot.json").read_bytes()
    real = agent._read_notes

    def then_compose(*a):
        out = real(*a)
        if change == "added":
            _add_doc(entry.db, "late", "prism-vault", Path(entry.vault) / "late.md")
        else:
            with IndexStore(str(entry.db)) as s:
                s.db.execute("UPDATE documents SET vault='core-vault' WHERE doc_id='decision'")
        return out

    monkeypatch.setattr(agent, "_read_notes", then_compose)
    with pytest.raises(agent.AgentError, match="changed while it was being"):
        agent.publish("prism", shared, registry=registry, now=datetime.now(UTC) + timedelta(1))
    db = shared / "prism.snapshot.db"
    assert (not db.exists()) if rebuild else db.read_bytes() == before
    assert (shared / "prism.snapshot.json").read_bytes() == manifest_before


def _declare_guard(registry: Path) -> None:
    vault = Path(scopes.resolve("prism", registry).vault)
    manifest = vault / ".substrate.toml"
    manifest.write_text(manifest.read_text(encoding="utf-8")
                        + f'guard_state = "{registry.parent / "state.json"}"\n', encoding="utf-8")


def test_a_new_guard_withdraws_the_snapshot_even_when_the_successful_publish_fails(
        world, monkeypatch):
    shared, registry = world
    _declare_guard(registry)
    real, calls = agent._fingerprint, []

    def drifting(*a):
        calls.append(1)
        return real(*a) + ("x" if len(calls) > 1 else "")

    monkeypatch.setattr(agent, "_fingerprint", drifting)
    with pytest.raises(agent.AgentError):
        agent.publish("prism", shared, registry=registry)
    assert not (shared / "prism.snapshot.db").exists()


def test_a_new_guard_withdraws_a_snapshot_whose_manifest_is_missing(world):
    shared, registry = world
    (shared / "prism.snapshot.json").unlink()
    _declare_guard(registry)
    assert agent.annotate("prism", shared, registry=registry) == "withdrawn"
    assert not (shared / "prism.snapshot.db").exists()


# --------------------------------------------------------------------------- the identity roster

def _roster(tmp_path: Path, registry: Path, *, inside: bool) -> Path:
    """A declared roster with two people: one a prism note mentions, one it never does — the
    shape of a roster shared across every scope."""
    vault = Path(scopes.resolve("prism", registry).vault)
    roster = (vault / "roster.json") if inside else (tmp_path / "shared-roster.json")
    roster.write_text(json.dumps({"entities": [
        {"id": "ada-lovelace", "name": "Ada Lovelace", "kind": "person",
         "aliases": ["Ada"], "gloss": "zqxjglossofada"},
        {"id": "zqxjotherscopeperson", "name": "Zqxjotherscopeperson", "kind": "person",
         "gloss": "zqxjglossofother"},
    ]}), encoding="utf-8")
    manifest = vault / ".substrate.toml"
    manifest.write_text(manifest.read_text(encoding="utf-8") + f'identity = "{roster}"\n',
                        encoding="utf-8")
    with IndexStore(str(scopes.resolve("prism", registry).db)) as s:
        s.replace_identity([("ada-lovelace", "Ada Lovelace", "person", "zqxjglossofada"),
                            ("zqxjotherscopeperson", "Zqxjotherscopeperson", "person",
                             "zqxjglossofother")])
        s.set_document_entities("decision", [("ada-lovelace", "Ada")])
    return roster


def test_a_shared_roster_reaches_the_agent_only_as_this_scopes_notes_show_it(world, tmp_path):
    shared, registry = world
    _roster(tmp_path, registry, inside=False)
    assert agent.publish("prism", shared, registry=registry).rewrote
    raw = (shared / "prism.snapshot.db").read_bytes()
    for leak in (b"zqxjotherscopeperson", b"zqxjglossofada", b"zqxjglossofother", b"Lovelace",
                 b"ada-lovelace"):
        assert leak not in raw, leak
    _hide(registry)
    status, _ = _call(_cfg(shared), "status", {"scope": "prism"})
    [ada] = status["entities"]
    assert ada["name"] == "Ada" and ada["gloss"] is None and ada["kind"] == "person"
    assert ada["entity_id"].startswith("e-")
    # The opaque id still drives the `entity` filter.
    res, err = _call(_cfg(shared), "search",
                     {"scope": "prism", "query": "snapshot", "entity": ada["entity_id"]})
    assert not err and res["passages"]
    docs, _ = _call(_cfg(shared), "documents", {"scope": "prism", "entity": ada["entity_id"]})
    assert docs["total"] == 1


@pytest.mark.parametrize("where", ["vault", "guarded vault"])
def test_a_roster_kept_inside_the_vault_is_stripped_the_same_way(tmp_path, where):
    """Where the roster file lives grants nothing: one kept in the project vault — the vault a
    guard withholds — would otherwise ship its glosses beside the stripped notes."""
    home = tmp_path / "operator"
    home.mkdir()
    registry = home / "scopes.toml"
    _scope(home, registry, "prism", guarded=where == "guarded vault")
    _roster(tmp_path, registry, inside=True)
    shared = tmp_path / "shared"
    shared.mkdir()
    agent.publish("prism", shared, registry=registry)
    raw = (shared / "prism.snapshot.db").read_bytes()
    for leak in (b"zqxjotherscopeperson", b"zqxjglossofada", b"zqxjglossofother", b"Lovelace",
                 b"ada-lovelace"):
        assert leak not in raw, leak


def test_the_rosters_alias_merges_do_not_reach_the_agent(world, tmp_path):
    """"Ada" in one note and "Countess" in another resolve to ONE person in the roster. That is a
    judgement the roster holds and no note states, so the snapshot keeps them apart."""
    shared, registry = world
    _add_real_doc(registry, "other", _BODY)
    _roster(tmp_path, registry, inside=False)
    with IndexStore(str(scopes.resolve("prism", registry).db)) as s:
        s.set_document_entities("other", [("ada-lovelace", "Countess")])
    agent.publish("prism", shared, registry=registry)
    _hide(registry)
    status, _ = _call(_cfg(shared), "status", {"scope": "prism"})
    assert sorted(e["name"] for e in status["entities"]) == ["Ada", "Countess"]
    assert len({e["entity_id"] for e in status["entities"]}) == 2
