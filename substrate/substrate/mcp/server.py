"""MCP server over the substrate engine — transport, and nothing else.

The engine is the retrieval brain and sits at the bottom; the CLI is one face on it, Scripta is
another, and this is a third. None of them owns the engine, so this module holds NO retrieval
logic, no filtering rules and no ranking (Doc 3a §5). Every result is shaped by `substrate.render`
and every stack is wired by `substrate.stack`, which is what makes Doc 3a §6's verification —
an MCP `search` and the equivalent CLI query return the same passages, capability and
index_version — a single equality rather than a hope. If this file can return something
`substrate query --json` cannot, logic has leaked into a transport.

Hand-rolled JSON-RPC 2.0 over stdio, **stdlib only**. The retrieval path is deliberately
dependency-free — that is what keeps a Swift port a reimplementation rather than a rewrite — and
the wire format is small enough that a package would be more to pin than to write.

**Scope is a parameter, not server configuration** (Doc 3a §3). One server serves every composed
scope; the caller names the one it wants and `list_scopes` lets it discover them. A scope that
cannot be resolved HARD-FAILS: quietly answering from a narrower scope would be the chapter-title
bug — a well-formed answer from the wrong source set — wearing a new hat.

**What crosses the boundary is the point.** A passage arrives carrying its own currency
(`status`), job (`doc_type`), settledness (`confidence`), origin (`vault`, `citation`, `domains`)
and supersession link; every response carries the capability envelope, the filters that were
applied, and `index_version`. Returning bare text would break the one guarantee the spine exists
to provide: a model reading a proposal would have no way to know it was one.
"""

from __future__ import annotations

import json
import os
import sys
from pathlib import Path
from typing import Any

from substrate import introspect, notes, render, scopes, stack

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "substrate"
SERVER_VERSION = "0.1.0"

# A whole note, capped. Notes are small, but `expand` must not be a way to pull an unbounded blob
# into a caller's context — and a cap that is silently applied is the failure this file exists to
# avoid, so a truncated note says so as a field.
NOTE_CHAR_CAP = 20_000

# A caller-chosen `k` is a caller-chosen response size: every passage is a full spine record plus
# a snippet, serialized indented, straight into the caller's context. Capped for the same reason
# NOTE_CHAR_CAP exists one field over, and REPORTED when it bites — a silently narrowed result set
# is the thing the filters block exists to prevent.
MAX_K = 50

# `source_path` ingest reads a caller-named file before anything else can validate it. Bounded and
# restricted to regular files so one tool call cannot hand the server a 200MB blob, a FIFO that
# blocks forever, or /dev/zero. Mirrors the markdown reader's own cap, applied BEFORE the read
# rather than after it.
MAX_SOURCE_BYTES = 8 * 1024 * 1024


class ToolError(RuntimeError):
    """A condition the CALLER can act on — an unknown scope, a stale index, a bad ref. Returned
    inside the result as `isError`, never raised through the transport, so a model sees the
    condition instead of a protocol failure it cannot interpret."""


# --------------------------------------------------------------------------- scope access

def _open(name: str, registry: str | None, *, refuse_empty: bool = True):
    """Resolve a scope and open its index, or refuse. Opened per call, never cached: a recompose
    replaces the database file, and a cached handle would keep answering from the old one.

    `refuse_empty=False` is for `status` ALONE. Refusing there was backwards: status exists to
    tell a caller whether an index can be trusted, so going silent in the one state where it
    demonstrably cannot is the question being asked, answered with an error. Every other tool
    still refuses — answering a search from an index that was rebuilt empty returns zero results,
    which is indistinguishable from a genuine no-match.
    """
    from substrate.store.index_store import IndexStore, SchemaMismatch

    try:
        entry = scopes.resolve(name, registry)
    except scopes.ScopeError as e:
        raise ToolError(str(e)) from e

    # migrate=False: every tool on this server READS. A write-open drops and rebuilds an
    # old-schema index, so a search would have destroyed the index it was asked about and then
    # truthfully reported it empty.
    try:
        store = IndexStore(str(entry.db), migrate=False)
    except SchemaMismatch as e:
        raise ToolError(str(e)) from e
    if refuse_empty:
        # EMPTINESS, not the `rebuilt` flag. That flag is true only on the open that PERFORMED a
        # migration, so it is consumed by whoever opens first and cannot be relied on by anyone
        # after them. Emptiness survives any number of opens and is the condition that actually
        # matters: a composed scope always has notes (resolve_scope refuses a zero-note scope), so
        # zero chunks means something is wrong regardless of how it got that way.
        if store.stats()["passages"] == 0:
            store.close()
            raise ToolError(
                f"scope {name!r} has an EMPTY index — most likely dropped and rebuilt by a schema "
                f"change, or composed from a scope that failed. Re-run `substrate compose` before "
                f"querying it; answering from an empty index is indistinguishable from a genuine "
                f"no-match. (`status` still reports on it.)"
            )
    return entry, store


def _clamp_k(raw: object) -> tuple[int, str | None]:
    """`k`, bounded, plus a note when the bound bit. Returns the note rather than swallowing it:
    a result set narrowed without saying so is the failure the filters block exists to prevent."""
    # Strict, because the schema says integer and the block around this refuses everything else.
    # `int()` accepted "7", 3.9 (→3) and True (→1), so a malformed argument produced a plausible
    # result set instead of the refusal its neighbours give.
    if raw is None:
        return 5, None
    if isinstance(raw, bool) or not isinstance(raw, int):
        raise ToolError(f"`k` must be a whole number, got {raw!r}.")
    k = raw
    if k < 1:
        raise ToolError(f"`k` must be at least 1, got {k}.")
    if k > MAX_K:
        return MAX_K, f"k was clamped from {k} to the server maximum of {MAX_K}"
    return k, None


# --------------------------------------------------------------------------- tools

TOOLS = [
    {
        "name": "search",
        "description": (
            "Search a composed vault scope for relevant passages. Returns SNIPPETS — use `expand` "
            "with a passage's `expand_ref` to read the rest.\n\n"
            "READ THE SPINE ON EVERY PASSAGE. `status` is the note's currency; `doc_type` is the "
            "one job it does (decision/explanation/reference/how-to, or `digest` — a maintained "
            "per-area summary that POINTS at atomic notes rather than containing them; its links "
            "are titles, not resolvable refs, so treat a digest hit as evidence the area exists "
            "and run a narrower query for the specifics); `confidence` is how SETTLED "
            "the claim is (proposed/inferred/stated/verified/unstated) and is INDEPENDENT of "
            "status — a note can be active AND proposed, i.e. a design that was never built. "
            "Treating a `proposed` note as a settled decision is the specific failure this "
            "contract exists to prevent. A passage carrying `supersedes` is the live note that "
            "replaced a dead one.\n\n"
            "Check `filters` for what was withheld and `retrieval_mode` for which arms actually "
            "ran: `expected_mrr` is null when the running stack has no measured number, which "
            "means the ranking is weaker than a measured one, not that it is unmeasurable.\n\n"
            "Every passage also carries its `doc_type` (the one job the note does). There is no "
            "doc_type filter — filter the returned passages yourself."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "scope": {"type": "string",
                          "description": "Which composed scope to search. `list_scopes` names them."},
                "query": {"type": "string", "description": "What to look for, in natural words."},
                "k": {"type": "integer",
                      "description": f"Max passages (default 5, server maximum {MAX_K})."},
                "include_sources": {
                    "type": "boolean",
                    "description": (
                        "Include conversation-class sources, excluded by default. A passage from "
                        "mid-conversation may be reasoning ABANDONED later in the same session — "
                        "confidence varies within a transcript, so treat any hit as raw material "
                        "rather than a conclusion."
                    ),
                },
                "include_archived": {
                    "type": "boolean",
                    "description": (
                        "Include archived notes (complete work moved off the active surface), "
                        "excluded by default. Superseded notes stay excluded either way — they "
                        "are dead facts, surfaced only as the `supersedes` link on their "
                        "replacement."
                    ),
                },
            },
            "required": ["scope", "query"],
        },
    },
    {
        "name": "expand",
        "description": (
            "Read the full text behind a search result's `expand_ref`. `mode=\"passage\"` (default) "
            "returns that passage; `mode=\"note\"` returns the whole note it came from, for "
            "connective questions where the passage is only part of the argument. A note is read "
            "from disk, so it also reports whether it has changed since the index was built."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "expand_ref": {"type": "string",
                               "description": "An `expand_ref` exactly as returned by `search`."},
                "mode": {"type": "string", "enum": ["passage", "note"],
                         "description": "Default \"passage\"."},
            },
            "required": ["expand_ref"],
        },
    },
    {
        "name": "ingest",
        "description": (
            "Add a NEW markdown note to a project vault. THIS IS A WRITE, and it is two-phase: "
            "called without `confirm_token` it writes nothing and returns a plan — where the note "
            "would land, the doc_id and spine values it would get, and any gate that would refuse "
            "it. Show that plan to the human. Only with their agreement, call again with the same "
            "arguments plus the plan's `confirm_token`.\n\n"
            "Additive only: it will not overwrite an existing note (editing goes through diff "
            "review), it never writes into the shared core tier, and it does not update the "
            "index — the note is invisible to `search` until the scope is recomposed, which the "
            "response says explicitly."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {
                "scope": {"type": "string", "description": "Which scope's project vault to add to."},
                "content": {"type": "string",
                            "description": "The note's full markdown, including frontmatter. Use "
                                           "this OR source_path, not both."},
                "source_path": {"type": "string",
                                "description": "Path to an existing .md file to add instead."},
                "filename": {"type": "string",
                             "description": "Name in the vault, e.g. 'retrieval-decision.md'. "
                                            "Required with `content`."},
                "folder": {"type": "string", "enum": list(notes.WRITABLE_FOLDERS),
                           "description": "Project folder (Doc 2 §4). Defaults to 04-synthesis."},
                "confirm_token": {"type": "string",
                                  "description": "From a previous plan. Omit on the first call."},
            },
            "required": ["scope"],
        },
    },
    {
        "name": "list_scopes",
        "description": (
            "What scopes exist and what each one composes. A scope appears here only once it has "
            "actually been composed, so this is the authoritative list — a name that is missing "
            "has no index behind it, rather than an index you have not found. `sources` is the "
            "vault chain the manifest resolves to, resolved fresh, so you can see whether a "
            "project scope really inherits the shared core tier."
        ),
        "inputSchema": {"type": "object", "properties": {}},
    },
    {
        "name": "status",
        "description": (
            "Whether a scope's index can be trusted right now: what it holds (counts by vault, "
            "tier, status, doc_type and confidence), which retrieval arms are wired, whether the "
            "vector arm has complete coverage, and — the part `index_version` cannot tell you — "
            "whether the VAULT has changed since the index was built.\n\n"
            "Read `drift` before concluding something is absent: a note listed under `added` is "
            "one the scope composes but the index does not hold, which looks exactly like a "
            "question the corpus cannot answer. `unverifiable` counts notes whose stored checksum "
            "names a source PDF rather than themselves, so an edit to them cannot be seen from "
            "the index alone."
        ),
        "inputSchema": {
            "type": "object",
            "properties": {"scope": {"type": "string"}},
            "required": ["scope"],
        },
    },
]


def _tool_search(args: dict, cfg: Config) -> dict:
    from substrate.retrieve import retriever

    scope = args.get("scope")
    query = args.get("query")
    if not scope or not query:
        raise ToolError("search requires both `scope` and `query`.")

    # EVERY argument is validated before anything expensive runs. doc_type is carried on each
    # passage but is not a server-side filter in the engine yet (Doc 2 §6a ships the axis and
    # defers the filter); applying it here would be retrieval logic in the transport, and
    # accepting it silently would return unfiltered results under a filtered label. Refusing after
    # `retrieve()` — as this did — meant paying a full retrieval plus, on a wired stack, a HyDE
    # generation and a rerank pass to produce an error decidable from the arguments alone.
    if args.get("doc_type"):
        raise ToolError(
            f"doc_type filtering is not implemented in the engine yet, so `doc_type="
            f"{args['doc_type']!r}` cannot be honoured. Every passage carries its doc_type — "
            f"search without it and filter the results."
        )
    k, clamp_note = _clamp_k(args.get("k"))
    include_sources = bool(args.get("include_sources", False))
    statuses = retriever.statuses(include_archived=bool(args.get("include_archived", False)))

    entry, store = _open(scope, cfg.registry)
    try:
        result = retriever.retrieve(
            store, query, k=k, statuses=statuses,
            include_sources=include_sources, with_outlines=render.OUTLINE_RECORDS,
            embedder=cfg.stack.embedder, expander=cfg.stack.expander,
            reranker=cfg.stack.reranker,
        )
        return render.search_payload(
            result, scope=scope, query=query, statuses=statuses,
            include_sources=include_sources, unavailable=cfg.stack.unavailable,
            db=str(entry.db), filter_notes=(clamp_note,) if clamp_note else (),
        )
    finally:
        store.close()


def _tool_expand(args: dict, cfg: Config) -> dict:
    ref = args.get("expand_ref")
    if not ref:
        raise ToolError("expand requires `expand_ref`.")
    mode = args.get("mode", "passage")
    if mode not in ("passage", "note"):
        raise ToolError(f"unknown mode {mode!r}; expected 'passage' or 'note'.")

    try:
        scope, chunk_id = render.parse_expand_ref(ref)
    except render.RefError as e:
        raise ToolError(str(e)) from e

    entry, store = _open(scope, cfg.registry)
    try:
        hit = store.chunk(chunk_id)
        if hit is None:
            raise ToolError(
                f"no passage {chunk_id!r} in scope {scope!r}. The index may have been recomposed "
                f"since that ref was issued — search again rather than assume the note is gone."
            )
        out = {"scope": scope, "mode": mode, "index_version": store.index_version,
               "passage": render.passage(hit, scope=scope, full=True)}
        if mode == "note":
            out["note"] = _note_text(store, hit.doc_id)
        return out
    finally:
        store.close()


def _note_text(store, doc_id: str) -> dict:
    """The whole note behind a passage, read from the VAULT.

    `source_path`, not `markdown_path`. They are different files: `markdown_path` is the derived
    artifact in the disposable index root, regenerated by every compose, and returning it would
    hand the caller a normalized copy of the note rather than the note — always agreeing with the
    index and therefore never able to report that the vault had moved on.

    Freshness uses the reader's own checksum rule (a declared `source_sha256` wins, else the
    file's own), so a PDF-derived passage — whose stored checksum names the PDF — is `unverifiable`
    rather than a false `stale`.
    """
    from substrate.freshness import effective_sha_of

    row = store.db.execute(
        "SELECT source_path, source_sha256 FROM documents WHERE doc_id=?", (doc_id,)
    ).fetchone()
    if row is None:
        raise ToolError(f"no document {doc_id!r} in this index.")

    path = Path(row["source_path"])
    try:
        # ONE bounded read, and the checksum computed from the SAME bytes. Reading twice let a write
        # land in between, so the returned text and the returned staleness verdict could describe
        # different versions of the file — and neither read was size-bounded, one function away
        # from the guards `_read_source` applies for exactly that reason.
        raw = _read_source(path)
        text = raw.decode("utf-8", errors="replace")
        sha, declared = effective_sha_of(raw)
    except OSError as e:
        raise ToolError(
            f"the note for {doc_id!r} is indexed at {path} but cannot be read ({e}). The passage "
            f"above is still valid; the source note has moved or been removed."
        ) from e

    return {
        "path": str(path),
        "text": text[:NOTE_CHAR_CAP],
        "n_chars": len(text),
        "truncated": len(text) > NOTE_CHAR_CAP,
        # A note that no longer matches what was indexed: the passages came from the OLD content.
        # `null` where the stored checksum is a declared one and an edit cannot be seen from here —
        # false is a claim, and this is the case where no claim can honestly be made.
        "stale": None if declared else (sha != (row["source_sha256"] or "")),
    }


def _read_source(src: Path) -> bytes:
    """A caller-named file, bounded by the read ITSELF rather than by a prior check.

    The caller here is a model, and its arguments can be influenced by content it just read, so
    "a path" is untrusted input. An earlier version stat'd then read, which is a check-then-act
    pair: the path could be swapped for a FIFO or grown past the cap in between, and the bound
    described an ordering rather than a guarantee. This opens once, non-blocking so a FIFO cannot
    stall the open, fstats the DESCRIPTOR it will actually read, and reads at most one byte over
    the cap — so growth after the check cannot exceed it either.

    The failure message is deliberately fixed rather than echoing the OSError, which otherwise
    answers "does /etc/<x> exist and can you read it" for any path a model cares to name.
    """
    import stat as _stat

    try:
        fd = os.open(src, os.O_RDONLY | os.O_NONBLOCK)
    except OSError as e:
        raise ToolError(f"cannot read the given source_path ({type(e).__name__}).") from e
    try:
        st = os.fstat(fd)
        if not _stat.S_ISREG(st.st_mode):
            raise ToolError("source_path is not a regular file.")
        chunks, size = [], 0
        while size <= MAX_SOURCE_BYTES:
            block = os.read(fd, 1 << 20)
            if not block:
                break
            chunks.append(block)
            size += len(block)
        if size > MAX_SOURCE_BYTES:
            raise ToolError(f"source_path exceeds the {MAX_SOURCE_BYTES}-byte limit for a note.")
        return b"".join(chunks)
    except OSError as e:
        raise ToolError(f"cannot read the given source_path ({type(e).__name__}).") from e
    finally:
        os.close(fd)


def _tool_ingest(args: dict, cfg: Config) -> dict:
    """Two-phase by construction. Without a token this PLANS and writes nothing; with one it
    re-plans and writes only if the token still matches. A client that auto-approves tool calls
    therefore still cannot write on the first call — the token only exists after a plan came
    back for someone to read."""
    name = args.get("scope")
    if not name:
        raise ToolError("ingest requires `scope`.")

    source_path = args.get("source_path")
    content_arg = args.get("content")
    filename = args.get("filename")
    if bool(source_path) == bool(content_arg):
        raise ToolError("pass exactly one of `source_path` (an existing file) or `content` "
                        "(a note to write), not both and not neither.")

    # The scope is resolved BEFORE any file is touched, so a call naming an unknown scope costs
    # nothing — it previously read the whole source into memory first and then refused.
    try:
        entry = scopes.resolve(name, cfg.registry)
    except scopes.ScopeError as e:
        raise ToolError(str(e)) from e

    if source_path:
        src = Path(source_path).expanduser()
        if src.suffix.lower() == ".pdf":
            raise ToolError(
                "PDF ingestion does not run through this tool. A reference source becomes "
                "REVIEWED markdown before the engine reads it (Doc 2 §3b), the extraction takes "
                "minutes and is non-deterministic across Docling versions, and it lands in the "
                "shared core tier that nothing auto-writes into (Doc 2 §2). Use `substrate "
                "ingest --pdf` and place the reviewed output deliberately."
            )
        content = _read_source(src)
        filename = filename or src.name
    else:
        content = content_arg.encode("utf-8")
        if not filename:
            raise ToolError("`content` requires `filename` — the note needs a name in the vault.")

    folder = args.get("folder", notes.DEFAULT_FOLDER)
    token = args.get("confirm_token")
    try:
        if not token:
            p = notes.plan(project_vault=entry.vault, content=content, filename=filename,
                           folder=folder, book=cfg.plans)
            return {
                "written": False,
                "plan": {
                    "scope": name, "target": str(p.target), "doc_id": p.doc_id,
                    "status": p.status, "doc_type": p.doc_type, "confidence": p.confidence,
                    "domains": p.domains, "passages": p.passages, "warnings": p.warnings,
                    "confirm_token": p.confirm_token,
                },
                "next": ("NOTHING HAS BEEN WRITTEN. Show this plan to the human, and only with "
                         "their agreement call ingest again with the same arguments plus "
                         "`confirm_token`."),
            }
        target = notes.commit(project_vault=entry.vault, content=content, filename=filename,
                              folder=folder, confirm_token=token, book=cfg.plans)
    except notes.NoteError as e:
        raise ToolError(str(e)) from e

    return {
        "written": True,
        "scope": name,
        "target": str(target),
        # The note is in the vault and NOT in the index. Said as a field, and `status` will show
        # it under drift.added until the scope is recomposed.
        "index_stale": True,
        # `--index-root` is omitted when the registry entry predates the field: emitting a
        # defaulted "." would tell the user to write the disposable index tree into whatever
        # directory they happen to be standing in.
        "next": ("the note is in the vault but not in the index — run `substrate compose "
                 + str(entry.vault)
                 + (f" --index-root {entry.index_root}" if entry.index_root else "")
                 + f" --db {entry.db}` before it can be found by search."),
    }


def _tool_list_scopes(args: dict, cfg: Config) -> dict:
    return introspect.scopes_payload(cfg.registry)


def _tool_status(args: dict, cfg: Config) -> dict:
    name = args.get("scope")
    if not name:
        raise ToolError("status requires `scope`.")
    entry, store = _open(name, cfg.registry, refuse_empty=False)
    try:
        return introspect.status_payload(store, entry, stack=cfg.stack)
    finally:
        store.close()


HANDLERS = {"search": _tool_search, "expand": _tool_expand, "ingest": _tool_ingest,
            "list_scopes": _tool_list_scopes, "status": _tool_status}


# --------------------------------------------------------------------------- protocol

class Config:
    """Server-wide configuration: the registry to resolve scopes against, the stack to query with,
    and the plans this process has issued. Deliberately NOT a scope — one server serves them all
    (Doc 3a §3).

    The PlanBook lives here because it must be per-PROCESS: it is what makes an ingest token
    unforgeable, and a token that outlived the server would authorise a write against a plan
    nobody in this session ever saw.
    """

    def __init__(self, registry: str | None, retrieval: stack.Stack):
        self.registry = registry
        self.stack = retrieval
        self.plans = notes.PlanBook()


def _result(rid: Any, payload: dict) -> dict:
    return {"jsonrpc": "2.0", "id": rid, "result": payload}


def _error(rid: Any, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def handle(msg: object, cfg: Config) -> dict | list | None:
    """One JSON-RPC frame in, one response out — a dict, a batch array, or None for a frame that
    takes no reply.

    A decoded frame is not necessarily an object: a batch is a legal array and a bare scalar is
    legal JSON. Both used to reach `msg.get(...)` and take the whole session down with an uncaught
    AttributeError — a dead pipe rather than an error the model can act on, which is the exact
    outcome the isError design exists to avoid.
    """
    # A BATCH is a legal array of requests, and this server advertises a protocol version that
    # permits them — rejecting one meant a conformant client's whole batch, `initialize` included,
    # failed on a single id-less error. Per JSON-RPC 2.0: an empty array is itself invalid; a
    # batch of only notifications gets NO response at all (not an empty array); otherwise the
    # replies come back as an array, and an invalid member is an error object inside it rather
    # than a rejection of the whole.
    if isinstance(msg, list):
        if not msg:
            return _error(None, -32600, "invalid request: empty batch")
        replies = [r for r in (handle(m, cfg) for m in msg) if r is not None]
        return replies or None
    if not isinstance(msg, dict):
        return _error(None, -32600, "invalid request: expected a JSON-RPC object")
    # A NOTIFICATION is a request with no `id` AT ALL — for any method, not just the one that had
    # its own branch. Deciding it per-branch meant `tools/list` sent as a notification got a reply
    # carrying `"id": null`, which is a response to nothing and which the docstring above says
    # does not happen. Decided once, here, and applied to whatever the dispatch returns.
    notification = "id" not in msg
    resp = _dispatch(msg, cfg)
    return None if notification else resp


def _dispatch(msg: dict, cfg: Config) -> dict | None:
    method, rid = msg.get("method"), msg.get("id")

    if method == "initialize":
        return _result(rid, {
            "protocolVersion": PROTOCOL_VERSION,
            "capabilities": {"tools": {}},
            "serverInfo": {"name": SERVER_NAME, "version": SERVER_VERSION},
        })
    if method in ("notifications/initialized", "initialized"):
        return None
    if method == "tools/list":
        return _result(rid, {"tools": TOOLS})
    if method == "tools/call":
        params = msg.get("params") or {}
        # JSON-RPC permits POSITIONAL params — a legal array here reached `.get` and threw out of
        # the handler, becoming an id-less transport error the client could not match to its
        # request. The message shape was guarded one function up; this is the same class of input
        # one line down.
        if not isinstance(params, dict):
            return _error(rid, -32602, "params must be an object for tools/call")
        name = params.get("name")
        fn = HANDLERS.get(name)
        if fn is None:
            return _error(rid, -32602, f"unknown tool {name!r}")
        try:
            # The serialization is INSIDE the try: a payload that will not serialize is a tool
            # fault like any other, and leaving json.dumps outside made it a second way to kill
            # the session rather than an isError the caller could read.
            text = json.dumps(fn(params.get("arguments") or {}, cfg), indent=2, ensure_ascii=False)
        except Exception as e:  # noqa: BLE001 — a tool fault must not kill the session
            # isError keeps the failure INSIDE the result, so the model sees the condition and can
            # act on it (compose the scope, search again) rather than a transport error it cannot
            # interpret. An unexpected exception is reported the same way for the same reason.
            return _result(rid, {
                "content": [{"type": "text", "text": f"{type(e).__name__}: {e}"}],
                "isError": True,
            })
        return _result(rid, {"content": [{"type": "text", "text": text}]})
    return _error(rid, -32601, f"unknown method {method!r}")


def serve(cfg: Config, stdin=None, stdout=None) -> int:
    stdin = stdin or sys.stdin
    stdout = stdout or sys.stdout
    for line in stdin:
        line = line.strip()
        if not line:
            continue
        try:
            msg = json.loads(line)
        except json.JSONDecodeError:
            # ANSWERED, not swallowed. A client that sent one malformed frame and got silence had
            # no way to distinguish "rejected" from "still working" and would wait on a reply that
            # was never coming — the server's own liveness turned into a hang. -32700 with a null
            # id is what JSON-RPC has for a frame too broken to carry one.
            stdout.write(json.dumps(_error(None, -32700, "parse error")) + "\n")
            stdout.flush()
            continue
        # No frame may end the session. `handle` refuses a non-object itself, and this catch-all
        # covers anything it did not anticipate — a server that dies on one malformed line takes
        # every later tool call in the conversation with it.
        try:
            resp = handle(msg, cfg)
            out = None if resp is None else json.dumps(resp, ensure_ascii=False)
        except Exception as e:  # noqa: BLE001 — the read loop outlives any single message
            out = json.dumps(_error(None, -32603, f"internal error: {type(e).__name__}: {e}"))
        if out is not None:
            stdout.write(out + "\n")
            stdout.flush()
    return 0


def main(argv: list[str] | None = None) -> int:
    import argparse

    ap = argparse.ArgumentParser(prog="substrate-mcp", description=__doc__.split("\n")[0])
    ap.add_argument("--registry", default=None,
                    help=f"scope registry (default ${scopes.ENV_VAR}, else "
                         f"{scopes.DEFAULT_REGISTRY})")
    ap.add_argument("--embed-model", default=stack.DEFAULT_EMBED)
    ap.add_argument("--hyde-model", default=stack.DEFAULT_HYDE)
    ap.add_argument("--rerank-model", default=stack.DEFAULT_RERANK)
    ap.add_argument("--cache", default=str(stack.DEFAULT_CACHE))
    ap.add_argument("--lexical-only", action="store_true",
                    help="no embedder, HyDE or reranker — the zero-dependency path")
    args = ap.parse_args(argv)

    retrieval = stack.build(
        embed_model=args.embed_model, hyde_model=args.hyde_model,
        rerank_model=args.rerank_model, cache_path=args.cache,
        lexical_only=args.lexical_only,
    )
    # stderr, not stdout: stdout is the JSON-RPC channel and a stray line corrupts the stream.
    # Reported at startup AND carried on every response — the caller may not see this.
    for note in retrieval.unavailable:
        print(f"substrate-mcp: {note}", file=sys.stderr)

    return serve(Config(args.registry, retrieval))


if __name__ == "__main__":
    raise SystemExit(main())
