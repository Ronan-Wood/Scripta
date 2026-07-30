"""MCP server over the substrate engine — transport, and nothing else.

The engine is the retrieval brain and sits at the bottom; the CLI is one face on it, Scripta is
another, and this is a third. None of them owns the engine, so this module holds NO retrieval
logic, no filtering rules and no ranking (Doc 3a §5). Every result is shaped by `substrate.render`
and every stack is wired by `substrate.stack`, which is what makes Doc 3a §6's verification —
an MCP `search` and the equivalent CLI query return the same passages, capability and
index_version — a single equality rather than a hope. If this file can return something
`substrate query --json` cannot, logic has leaked into a transport.

Hand-rolled JSON-RPC 2.0 over stdio OR loopback HTTP, **stdlib only**. The retrieval path is
deliberately dependency-free — that is what keeps a Swift port a reimplementation rather than a
rewrite — and the wire format is small enough that a package would be more to pin than to write.

**Two transports, one dispatch.** stdio is one server per client by construction: the client
spawns this process and owns its pipes, so N clients mean N servers and a code change lands only
after every one of them restarts. `--http` is the same server behind a loopback socket that all
of them share. Both reach `handle()` and neither adds dispatch of its own — a second copy of the
JSON-RPC rules is how the two would drift into answering differently, which is exactly the
divergence Doc 3a §6 forbids between the MCP and the CLI.

**The transports differ in exactly one thing, and it is a parameter rather than a fork.** HTTP is
`--read-only` by default, so `ingest` is neither advertised nor run there (Doc 3 §3): any local
process can reach a loopback port, and `ingest` writes notes into real vaults that the next
refresh serves back as settled knowledge. Reaching stdio already requires spawning this process,
so stdio keeps it. That decision travels on `Config`, not in a second dispatch — `handle()` is
still one function answering one frame the same way whichever socket it arrived on.

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

import copy
import json
import os
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path
from typing import Any

from substrate import introspect, net, notes, render, scopes, stack
from substrate.store import schema

PROTOCOL_VERSION = "2024-11-05"
SERVER_NAME = "substrate"
# DERIVED, not typed. This is the only version a client displays, and as a literal it sat at
# "0.1.0" through schema v1..v8 — so the one surface that advertises how current the server is
# reported the same string no matter how stale it actually was, which is the false-healthy shape
# the envelope exists to remove. Tracks the INDEX CONTRACT rather than the package version in
# pyproject.toml: what a caller needs from this field is whether the server can read their index,
# and `schema.SCHEMA_VERSION` is the fact that answers it. Do not "fix" this back to a literal.
SERVER_VERSION = f"0.{schema.SCHEMA_VERSION}.0"

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
        # The remedy is scope-specific and the exception deliberately does not name one, so this
        # adapter supplies it: every scope on this server was built by `compose`.
        raise ToolError(f"{e} Rebuild the scope with `substrate compose`.") from e
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
            "the claim is (proposed/inferred/stated/verified, plus `unstated` = the author judged "
            "it and it claims nothing, and `unjudged` = nobody has judged it yet — treat "
            "`unjudged` as ABSENT SIGNAL, never as 'uncertain'; most migrated notes are in it) "
            "and is INDEPENDENT of "
            "status — a note can be active AND proposed, i.e. a design that was never built. "
            "Treating a `proposed` note as a settled decision is the specific failure this "
            "contract exists to prevent. `supersedes` is a LIST of the dead notes this live one "
            "replaced — `[]` when it replaced nothing, and more than one entry when a single note "
            "consolidated several.\n\n"
            "Check `filters` for what was withheld and `retrieval_mode` for which arms actually "
            "ran: `expected_mrr` is null when the running stack has no measured number, which "
            "means the ranking is weaker than a measured one, not that it is unmeasurable.\n\n"
            "READ `refresh` BEFORE TRUSTING A RESULT AS CURRENT. A background job keeps each "
            "scope's index in step with its vault; this is what it last managed. "
            "`frozen: true` means the vault changed and the rebuild REFUSED, so these passages "
            "come from content that has since been edited — say so rather than presenting them "
            "as current. `frozen: false` means the last pass left index and vault in agreement. "
            "`frozen: null` means no verdict is possible (nothing was attempted, or nothing has "
            "ever been recorded) — that is ABSENT EVIDENCE, not a clean bill of health. Compare "
            "`attempted` with `succeeded`: a gap between them is how long the scope has been "
            "going wrong. `status` computes the vault-vs-index comparison directly.\n\n"
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
            "response says explicitly.\n\n"
            "REQUIRED FRONTMATTER: `status`, `doc_type`, AND `confidence` — the last is required "
            "HERE even though `compose` accepts notes without it, because a note being written now "
            "has an author present to judge it. Pick the value from evidence, never to fill the "
            "field: `verified` only for something measured or reproduced, `stated` for an "
            "authority's assertion or any inventory, `inferred` for a conclusion drawn, `proposed` "
            "for a design not yet built. If the note makes no settledness claim, write "
            "`confidence: unstated` — that is a real declaration and satisfies this gate. "
            "`unjudged` is the absence marker and is REFUSED if declared."
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
            "the index alone.\n\n"
            "`refresh` is the same block `search` returns — what the background job last managed "
            "on this scope. Read it WITH `drift`, not instead of it: `drift.stale` with "
            "`refresh.frozen` is an index whose rebuild refused, while `drift.stale` with a clean "
            "refresh is only an edit made since the last pass."
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
            registry=cfg.registry,
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
        return introspect.status_payload(store, entry, stack=cfg.stack, registry=cfg.registry)
    finally:
        store.close()


HANDLERS = {"search": _tool_search, "expand": _tool_expand, "ingest": _tool_ingest,
            "list_scopes": _tool_list_scopes, "status": _tool_status}

# The tools that WRITE. Named once because read-only has to mean the same thing to `tools/list`
# and to `tools/call`: a tool hidden from the list but still runnable when called is not read-only,
# and one that is listed and always refuses trains a model to keep trying.
WRITE_TOOLS = frozenset({"ingest"})


# --------------------------------------------------------------------------- protocol

class Config:
    """Server-wide configuration: the registry to resolve scopes against, the stack to query with,
    and the plans this process has issued. Deliberately NOT a scope — one server serves them all
    (Doc 3a §3).

    The PlanBook lives here because it must be per-PROCESS: it is what makes an ingest token
    unforgeable, and a token that outlived the server would authorise a write against a plan
    nobody in this session ever saw.
    """

    def __init__(self, registry: str | None, retrieval: stack.Stack, *,
                 read_only: bool = False):
        self.registry = registry
        self.stack = retrieval
        self.plans = notes.PlanBook()
        # Doc 3 §3. FALSE by default because a bare Config is the stdio one, and reaching stdio
        # already means spawning this process — the write primitive is no wider than the process
        # that owns it. `main()` turns this ON for `--http`, where any local process can reach the
        # port.
        self.read_only = read_only


def _result(rid: Any, payload: dict) -> dict:
    return {"jsonrpc": "2.0", "id": rid, "result": payload}


def _error(rid: Any, code: int, message: str) -> dict:
    return {"jsonrpc": "2.0", "id": rid, "error": {"code": code, "message": message}}


def _internal_error(msg: object, exc: BaseException) -> dict | None:
    """The -32603 for a frame `handle()` could not survive — carrying THAT FRAME'S id.

    A JSON-RPC client matches a response to a pending request by id, so an error with `id: null`
    resolves nothing: the call hangs to the client's own timeout instead of failing, which is a
    worse outcome than the error being reported. The id is recoverable from the decoded frame in
    the one shape that has one — a single request object — and both transports come through here,
    so neither can drift into answering the other's shape (module docstring).

    Null stays correct for the two shapes that genuinely have no id: a batch, which has no single
    one, and a frame too broken to parse. A NOTIFICATION gets no reply at all — JSON-RPC forbids
    responding to one, and nobody is waiting on an id that was never sent.
    """
    text = f"internal error: {type(exc).__name__}: {exc}"
    if isinstance(msg, dict):
        return None if "id" not in msg else _error(msg["id"], -32603, text)
    return _error(None, -32603, text)


def _available_tools(cfg: Config) -> list[dict]:
    """What this server will actually run. A read-only transport does not ADVERTISE `ingest`: a
    model told a tool exists will call it, and Doc 3 §3 takes the write primitive off the socket
    rather than letting it fail late."""
    if not cfg.read_only:
        return TOOLS
    return [t for t in TOOLS if t["name"] not in WRITE_TOOLS]


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
        return _result(rid, {"tools": _available_tools(cfg)})
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
        if cfg.read_only and name in WRITE_TOOLS:
            # NOT reported as an unknown tool. The tool exists and is reachable over stdio; saying
            # it does not exist would send a model hunting for another way to write, which is the
            # misleading answer this codebase refuses. It comes back as an isError result for the
            # same reason every other ToolError does — the caller can act on it.
            return _result(rid, {"content": [{"type": "text", "text": (
                f"`{name}` is refused on this transport: the server is read-only (Doc 3 §3). Any "
                f"local process can reach a loopback port, and `{name}` writes notes into real "
                f"vaults that the next refresh serves back as settled knowledge — so the write "
                f"primitive is off the socket entirely rather than guarded by a token. It is "
                f"still available over stdio: run the server without `--http`, or with "
                f"`--no-read-only` if the write is genuinely intended."
            )}], "isError": True})
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
            # `msg`, not None: the id this frame arrived with is what a client matches its pending
            # request against, and an error carrying `id: null` never resolves that call.
            err = _internal_error(msg, e)
            out = None if err is None else json.dumps(err)
        if out is not None:
            stdout.write(out + "\n")
            stdout.flush()
    return 0


DEFAULT_HTTP = "127.0.0.1:8765"

# A POST body is caller-controlled input that arrives before anything can validate it. Bounded
# for the same reason MAX_SOURCE_BYTES is, and BEFORE the read rather than after it.
MAX_BODY_BYTES = 8 * 1024 * 1024

# How long shutdown waits for a tool call that is already running. Long enough for a wired-stack
# `search` (HyDE generation plus a rerank pass) to finish rather than be killed halfway.
SHUTDOWN_GRACE_SECONDS = 30.0


# Longer than any legitimate Content-Length or port, and short enough that the `int()` every
# caller performs next cannot raise. CPython refuses to convert a decimal string past 4300 digits
# (sys.set_int_max_str_digits), so a header of 5000 nines passed the digit check and then threw
# ValueError out of `do_POST` — no response, a dropped connection and a traceback, from a header
# read BEFORE any body. A predicate whose whole job is to make the following `int()` safe has to
# bound length as well as alphabet. 20 digits covers uint64.
MAX_DIGITS = 20


def _is_digits(s: str) -> bool:
    """RFC 7230 `1*DIGIT`: at least one ASCII 0-9, nothing else, and short enough for `int()`.

    The two lenient parsers this replaces both sat inside guards whose stated posture is
    fail-closed. `int()` accepts `+5`, ` 5 `, `1_0` (→10) and non-ASCII decimal digits, so a
    Content-Length could mean one number here and another to the peer — which is the whole framing
    desync. `str.isdigit()` alone is true for `٥` and `²`, which no port parser accepts.
    """
    return 0 < len(s) <= MAX_DIGITS and s.isascii() and s.isdigit()


def _host_is_loopback(host: str) -> bool:
    """Is this an authority the listener could actually be serving on?

    ONE copy, used by both the `Host:` header guard and `parse_bind` — they are the same question
    asked at two moments, and a fix applied to one and not the other is exactly how this guard
    drifts back (see `substrate.net`).

    NOT `net.is_loopback`. That predicate parses a URL, and a URL parser discards everything after
    the first `/`, `?` or `#` — so `localhost/evil.com` reads as "localhost" and passes. An
    authority is validated as an authority: a name, an optional `:port`, and nothing else at all.

    IPv6 is REFUSED, `[::1]` included, because ThreadingHTTPServer inherits address_family =
    AF_INET. No bind this server can perform produces such an authority, so blessing one meant the
    request-time guard accepting a Host the listener could never have been reached at — a claim
    about a server that does not exist.
    """
    if not isinstance(host, str) or not host.strip():
        return False
    rest = host.strip()
    if rest.startswith("[") or rest.count(":") > 1:
        return False
    name, _, port = rest.partition(":")
    if port and not _is_digits(port):
        return False
    # Anything that could re-parse as a path, query, fragment or userinfo is not an authority.
    if any(c in name for c in "/?#@\\ \t"):
        return False
    return name.lower() in net.LOOPBACK_HOSTS


def parse_bind(spec: str) -> tuple[str, int]:
    """`HOST:PORT` -> (host, port), refusing anything that is not loopback.

    The check is `_host_is_loopback`, the SAME predicate the Host header goes through. It used to
    be `net.is_loopback`, which parses a URL — and a URL parser discards everything after the
    first `/`, `?` or `#`, so `127.0.0.1#@evil.com:8765` was validated as "127.0.0.1" and then
    returned `127.0.0.1#@evil.com` to bind. The host that was checked was not the host that would
    be served, which is the exact weakness `_host_is_loopback` was written to close one guard over;
    it failed closed here only because getaddrinfo happened to reject the result, which is an
    accident rather than a guard.

    Binding off-loopback would put `ingest` — which WRITES vaults and reads caller-named files —
    on the network, so this fails closed on anything it cannot parse, and the string it validates
    is the string it returns.
    """
    host, sep, port_s = spec.rpartition(":")
    if not sep or not host:
        raise ValueError(f"--http wants HOST:PORT, got {spec!r} (e.g. {DEFAULT_HTTP})")
    host = host.strip()
    # A BARE IPv4 host, nothing else. `_host_is_loopback` refuses these anyway; this branch only
    # supplies the better message. ThreadingHTTPServer inherits address_family = AF_INET, so an
    # accepted `[::1]` parsed cleanly and then died at bind() with a gaierror — an address the
    # validator blessed and the server could not serve. Under a KeepAlive'd launch job that is a
    # traceback every ThrottleInterval, forever. Refused rather than fixed by an AF_INET6 subclass
    # because nothing needs IPv6 loopback: the clients are on this machine and reach 127.0.0.1.
    if host.startswith("[") or ":" in host:
        raise ValueError(
            f"refusing to bind {spec!r}: HOST must be a bare IPv4 loopback address — this listener "
            f"is AF_INET, so a bracketed or colon-bearing host (IPv6, or a second port) is not "
            f"something it can serve. Bind an address such as {DEFAULT_HTTP}."
        )
    if not _host_is_loopback(host):
        raise ValueError(
            f"refusing to bind {spec!r}: not a loopback address. This server exposes `ingest`, "
            f"which writes vaults and reads caller-named files — off-loopback it is a remote "
            f"write primitive. Bind a loopback address such as {DEFAULT_HTTP}."
        )
    if not _is_digits(port_s):
        raise ValueError(f"--http port must be an integer, got {port_s!r}")
    port = int(port_s)
    if not 1 <= port <= 65535:
        raise ValueError(f"--http port out of range: {port}")
    return host, port


class _Handler(BaseHTTPRequestHandler):
    """One POST carries one JSON-RPC frame; the reply is that frame's response.

    This is the transport half of Streamable HTTP and none of the streaming half: there is no SSE
    channel and no session id, because every tool here is request/response and a stream the server
    never writes to is a liveness bug waiting to happen. GET is refused rather than left to the
    base class's 501, so a client probing for the stream gets a definite answer.
    """

    protocol_version = "HTTP/1.1"  # keep-alive; clients reuse the connection across tool calls

    # StreamRequestHandler applies this to the socket, and handle_one_request turns the resulting
    # timeout into a connection close. Without it `timeout` is None: a client that announces a
    # Content-Length and then stalls parks a worker thread until TCP keepalive gives up, which is
    # hours. That was survivable when a server died with its one client; this one is shared by
    # every client and meant to run for weeks, and a thread-starved server does not die — it just
    # stops answering, which is indistinguishable from a slow tool call.
    timeout = 30

    cfg: Config
    lock: threading.Lock

    def log_message(self, fmt: str, *args: Any) -> None:
        # stderr, never stdout. This process may still be holding a stdio JSON-RPC channel (tests
        # drive `serve` and `serve_http` in one interpreter) and a stray line there corrupts it —
        # the same rule main() follows for its startup notes.
        sys.stderr.write("substrate-mcp[http]: " + (fmt % args) + "\n")

    def _refuse(self, code: int, why: str) -> None:
        # CLOSE THE CONNECTION. Every refusal here replies without reading the request body, and
        # HTTP/1.1 keep-alive would then leave those unread bytes in the socket for the next
        # `handle_one_request` to parse AS A REQUEST. That is not merely a poisoned next call: a
        # page can send one CORS-simple POST (text/plain, no preflight) whose BODY is a complete
        # second request carrying `Host: 127.0.0.1`, no Origin and `Content-Type: application/json`
        # — the outer request is refused, the smuggled one is served, and all three guards below
        # are bypassed by the page they exist to stop.
        self.close_connection = True
        body = json.dumps(_error(None, -32600, why)).encode()
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)
        # NOTHING FOLLOWS. A lingering half-close-and-discard used to sit here, to stop the close
        # from becoming an RST that destroys the refusal before the client reads it. It was removed
        # after measurement: its budget (1MiB/1s) was smaller than any body that can reach the 413
        # branch it was written for, so a 6MiB POST still got the reset; it parked the handler
        # thread AND its connection slot for up to a second, so the cheapest possible refusals
        # exhausted the ceiling (cap 4 → four text/plain POSTs → the next legitimate request got
        # 503); and no test pinned it — stubbing it to a no-op left every smuggling test green.
        # `close_connection` above is what actually holds that property. The RST hazard is real but
        # was never observed here, and a reproduced denial of service is the worse trade.

    def _guarded(self) -> bool:
        """Refuse anything that smells like a browser reaching a local daemon.

        A loopback bind keeps other machines out; it does NOT keep out a page in the operator's own
        browser, which can resolve an attacker-controlled name to 127.0.0.1 (DNS rebinding) or post
        a form cross-origin. Three cheap checks close that: the Host must still be loopback after
        DNS, a cross-origin Origin is rejected outright, and the body must be application/json —
        which no form can send without a preflight this server never answers.
        """
        host = self.headers.get("Host")
        # REQUIRED, not merely checked. `if host and ...` let a caller skip the guard by omitting
        # the header entirely — BaseHTTPRequestHandler does not enforce HTTP/1.1's Host rule — so
        # the one check that fails closed everywhere else failed open on absence.
        if not host or not _host_is_loopback(host):
            self._refuse(421, f"refusing Host {host!r}: this server answers on loopback only")
            return False
        origin = self.headers.get("Origin")
        if origin is not None:
            # ANY Origin is refused, not just a foreign one: this server has no web UI, so there is
            # no page it legitimately serves and nothing to allow-list. An absent Origin is a
            # non-browser caller (an MCP client, curl), which is the only shape expected here.
            self._refuse(403, f"refusing cross-origin request from {origin!r}")
            return False
        ctype = (self.headers.get("Content-Type") or "").split(";")[0].strip().lower()
        if ctype != "application/json":
            self._refuse(415, f"expected Content-Type: application/json, got {ctype or 'none'!r}")
            return False
        return True

    def _framing(self) -> int | None:
        """How many body bytes to read, or None having already refused.

        Header-only by construction, which is what lets `handle_expect_100` run it BEFORE the
        client is invited to send anything. Every branch is a framing disagreement: the length
        this server reads has to be the length the peer wrote, or the remainder stays in the socket
        and `handle_one_request` parses it as the next request line — the same desync `_refuse`
        closes from the refusal side, reached through the accepted side instead.
        """
        # TRANSFER-ENCODING, inspected rather than ignored. `Transfer-Encoding: chunked` with
        # `Content-Length: 0` read a zero-byte body, answered keep-alive 200 with a parse error,
        # and left the chunked payload to be read as the next request line. RFC 7230 forbids
        # reconciling the two, and this server does not read chunked at all — so both shapes are
        # refused rather than framed on whichever header happens to be looked at first.
        if self.headers.get_all("Transfer-Encoding"):
            if self.headers.get_all("Content-Length"):
                self._refuse(400, "Transfer-Encoding and Content-Length together: refusing to "
                                  "guess which one frames the body")
            else:
                self._refuse(411, "Content-Length required; chunked bodies are not read here")
            return None

        lengths = self.headers.get_all("Content-Length") or []
        if not lengths:
            # No chunked support: a body whose length is unknown until it ends cannot be bounded
            # before it is read, which is the whole point of MAX_BODY_BYTES.
            self._refuse(411, "Content-Length required")
            return None
        if len(lengths) > 1:
            # `self.headers.get()` returns only the FIRST of a repeated header, so conflicting
            # values framed the body on one and left the remainder for the next request. Refused
            # whether or not they agree: an agreeing pair buys nothing, and the disagreeing pair is
            # the entire smuggling primitive.
            self._refuse(400, f"{len(lengths)} Content-Length headers; refusing an ambiguous body")
            return None
        raw = lengths[0].strip()
        if not _is_digits(raw):
            # Covers the negative length too, and says so as a MALFORMED HEADER rather than an
            # oversized body — telling a caller to shrink a body that was never too large is the
            # wrong-signal failure the other refusals go out of their way to avoid.
            self._refuse(400, f"malformed Content-Length {lengths[0]!r}")
            return None
        length = int(raw)
        if length > MAX_BODY_BYTES:
            self._refuse(413, f"body over {MAX_BODY_BYTES} bytes")
            return None
        return length

    def handle_expect_100(self) -> bool:
        """Refuse before the body instead of inviting it and refusing it after.

        The base class answers `Expect: 100-continue` from `parse_request`, BEFORE do_POST runs —
        so a client asking permission to send 9MB was told to go ahead, and the size check then
        refused a body already on the wire. That inverts the "bounded BEFORE the read" property
        the branch exists for. Both guards are decidable from the headers alone, so both run here,
        where "no" still costs the caller nothing. `_refuse` has answered and closed the connection
        by the time this returns False, and `parse_request` then stops without dispatching.
        """
        if self.command == "POST" and (not self._guarded() or self._framing() is None):
            return False
        return super().handle_expect_100()

    def do_GET(self) -> None:  # noqa: N802 — BaseHTTPRequestHandler's naming
        self._refuse(405, "this server has no SSE stream; POST one JSON-RPC frame per request")

    def do_POST(self) -> None:  # noqa: N802 — BaseHTTPRequestHandler's naming
        # THE REQUEST PATH IS NOT EXAMINED, and that is the decision rather than an omission: every
        # URL on this server is the one JSON-RPC endpoint. There is no second resource to route to
        # and no client contract that names a path, so matching one would invent a convention whose
        # only effect is a 404 for whoever configured `/mcp`. Routing is dispatch, and this module
        # adds none of its own (module docstring). A second endpoint is what changes this.
        if not self._guarded():
            return
        length = self._framing()
        if length is None:
            return
        body = self.rfile.read(length)

        try:
            msg = json.loads(body)
        except (json.JSONDecodeError, UnicodeDecodeError):
            # Same answer stdio gives an unparseable frame, and for the same reason: silence leaves
            # the client unable to tell "rejected" from "still working".
            payload = _error(None, -32700, "parse error")
        else:
            # SERIALIZED. Every tool was written under stdio, where one frame is handled at a time,
            # and Config carries mutable state that assumption protects — the PlanBook holding
            # two-phase ingest plans above all. Threads accept connections so one slow caller
            # cannot block the listener; the lock keeps what they run one-at-a-time, which is the
            # concurrency the tools were actually built for.
            with self.lock:
                try:
                    payload = handle(msg, self.cfg)
                except Exception as e:  # noqa: BLE001 — the server outlives any single message
                    # `msg`, not None — same reason and the same helper as the stdio loop: an
                    # error carrying `id: null` never resolves the call it answers, so the client
                    # hangs to its own timeout instead of failing.
                    payload = _internal_error(msg, e)

        if payload is None:
            # A notification takes no reply. 202 is Streamable HTTP's way of saying "accepted, and
            # there is nothing to say back" — an empty 200 body would not parse as a response.
            self.send_response(202)
            self.send_header("Content-Length", "0")
            self.end_headers()
            return
        out = json.dumps(payload, ensure_ascii=False).encode("utf-8")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(out)))
        self.end_headers()
        self.wfile.write(out)


class _BoundedThreadingHTTPServer(ThreadingHTTPServer):
    """ThreadingHTTPServer with a ceiling on live CONNECTIONS — which is not a ceiling on work.

    The stock class spawns a thread per connection with no cap. 300 connections that announce a
    Content-Length and then stall produce 300 parked threads, and this is now the ONE server Zed,
    Claude Desktop and Claude Code all depend on — so a single local process could wedge all three
    at once. What this bounds is sockets and threads: the resource that actually runs out.

    Two things it does NOT do, written down because the comment that stood here asserted the first
    of them ("bounds how many can be in flight while that timer runs"):

      * It does not bound requests in flight. A slot is taken per CONNECTION, and
        `protocol_version = "HTTP/1.1"` keeps connections alive between tool calls — so a client
        sitting idle still holds one. `_Handler.timeout` closes a connection 30s after its last
        byte, which caps how LONG an idle connection squats a slot, not how many do.
      * It does not reap a thread waiting on the dispatch lock. Every request serializes on that
        one lock (see `do_POST`, where the serialization is deliberate), and a thread waiting for
        it has no I/O pending — so the socket timeout never fires and nothing else here interrupts
        it. One slow `handle()` parks every slot behind it. The cap turns thread exhaustion into a
        connection refusal; it does not make this server concurrent.
    """

    MAX_CONNECTIONS = 64

    def __init__(self, *a: Any, **kw: Any) -> None:
        super().__init__(*a, **kw)
        self._slots = threading.BoundedSemaphore(self.MAX_CONNECTIONS)
        # Built PER INSTANCE, from the cap actually in force. Interpolated at class-definition time
        # it read the class attribute, so a subclass or a test lowering MAX_CONNECTIONS still told
        # callers the ceiling was 64 — a refusal that misreports the very number it is refusing on.
        #
        # A refusal the caller can READ: closing the socket with nothing written is indistinguishable
        # from the hung server this cap exists to prevent, which was the stated reason for refusing
        # rather than queueing. Pre-rendered as bytes because it is written from `process_request`,
        # before any handler — and therefore any of BaseHTTPRequestHandler's response machinery —
        # exists for this connection. A null id is honest here in a way it is not in
        # `_internal_error`: the request was never read.
        body = json.dumps(_error(
            None, -32603, f"server is at its connection ceiling of {self.MAX_CONNECTIONS}; retry",
        )).encode()
        self._busy_response = (
            b"HTTP/1.1 503 Service Unavailable\r\n"
            b"Content-Type: application/json\r\n"
            b"Connection: close\r\n"
            b"Retry-After: 1\r\n"
            b"Content-Length: " + str(len(body)).encode() + b"\r\n\r\n" + body
        )

    def process_request(self, request: Any, client_address: Any) -> None:
        if not self._slots.acquire(blocking=False):
            # REFUSED, not queued: a queued connection is one the client waits on with no way to
            # tell a busy server from a hung one. This runs on the ACCEPT thread, which is why it
            # is a fixed byte string on a tight budget rather than a handler — a refusal must not
            # itself become the thing that stops the listener accepting.
            try:
                request.settimeout(1.0)
                request.sendall(self._busy_response)
            except OSError:
                pass
            self.shutdown_request(request)
            return
        try:
            super().process_request(request, client_address)
        except BaseException:
            # The slot is released by process_request_thread, which only runs if the thread was
            # actually started. If spawning it failed, release here or the cap leaks downward.
            self._slots.release()
            raise

    def process_request_thread(self, request: Any, client_address: Any) -> None:
        # Paired with the acquire above, and the ONLY release on the served path. Releasing in
        # close_request instead would also fire for the refusal above — which never acquired — and
        # hand back slots that were never taken, silently raising the ceiling under load.
        try:
            super().process_request_thread(request, client_address)
        finally:
            self._slots.release()


def serve_http(cfg: Config, host: str, port: int, *, ready: Any = None,
               allow_writes: bool = False) -> int:
    """One long-lived server, every client. Returns only when interrupted.

    `ready` is an optional callable handed the bound server once the socket is listening. Tests
    need the real port when they ask for port 0 and a handle to stop it again, and polling for
    either is a race.

    READ-ONLY IS ENFORCED HERE, not upstream. `Config.read_only` defaults False — correct for
    stdio, wrong for a socket — so when the guarantee lived only in `main()`'s argparse, every
    other caller of this function got a loopback server that would run `ingest`. That is not a
    hypothetical: the whole test suite reached it that way. The transport is what the exposure
    depends on, so the transport is what decides, and opting out is explicit and audible.
    """
    if not allow_writes and not cfg.read_only:
        # A VIEW, not a mutation. Setting the flag on the caller's Config would reach through to
        # anything else holding it — `test_http_and_stdio_answer_the_same_frame` passes one Config
        # to both transports, so mutating here would quietly make the stdio side read-only and turn
        # that equality into a comparison of two identical halves. `copy.copy` is the right depth:
        # the stack and the PlanBook stay shared, only the flag is ours.
        cfg = copy.copy(cfg)
        cfg.read_only = True
    elif allow_writes and not cfg.read_only:
        print(f"substrate-mcp: writes ENABLED on {host}:{port} — `ingest` is reachable by any "
              f"local process", file=sys.stderr)
    handler = type("_BoundHandler", (_Handler,), {"cfg": cfg, "lock": threading.Lock()})
    try:
        httpd = _BoundedThreadingHTTPServer((host, port), handler)
    except OSError as e:
        # A taken port is the common case — a second instance, or an old process that outlived its
        # client. Unhandled it escapes as a traceback, and under a KeepAlive'd launch job that is a
        # traceback every ThrottleInterval into an unrotated log. Refused with the same shape the
        # bind validator uses, so both failures read alike.
        print(f"substrate-mcp: cannot bind {host}:{port} — {e}", file=sys.stderr)
        return 2
    # Daemon threads, so an idle keep-alive connection cannot hold the interpreter open for its
    # full `_Handler.timeout` with nothing in flight. That is only safe alongside the barrier
    # below: socketserver's `server_close()` joins non-daemon threads and SKIPS these, so on its
    # own this let Ctrl-C drop the interpreter with a handler mid-`handle()` — and `notes.commit`
    # writes a note with a plain write() into a real vault, so an exit there leaves a truncated
    # note that the next compose reads as the note.
    httpd.daemon_threads = True
    bound_host, bound_port = httpd.server_address[0], httpd.server_address[1]
    print(f"substrate-mcp: serving http://{bound_host}:{bound_port} "
          f"(v{SERVER_VERSION}, schema v{schema.SCHEMA_VERSION})", file=sys.stderr)
    if ready is not None:
        ready(httpd)
    try:
        httpd.serve_forever()
    except KeyboardInterrupt:
        pass
    finally:
        # `shutdown()` is NOT called here: serve_forever has already returned by the time this
        # runs, so it would only latch a flag. `server_close()` is the one that releases the port.
        httpd.server_close()
        # THE BARRIER, and the reason daemon threads above are survivable. Every tool call runs
        # under this one dispatch lock, so holding it IS "no handler is inside handle()" — narrower
        # and far cheaper than joining threads, which keep-alive would stretch to `_Handler.timeout`
        # for each connection that is doing nothing. Never released: the listener is already
        # closed, the process is leaving, and no write may start after this point.
        if not handler.lock.acquire(timeout=SHUTDOWN_GRACE_SECONDS):
            print(f"substrate-mcp: a tool call was still running after "
                  f"{SHUTDOWN_GRACE_SECONDS:.0f}s — exiting anyway. If it was an `ingest`, check "
                  f"the target note: it is written with a plain write() and may be truncated.",
                  file=sys.stderr)
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
    ap.add_argument("--http", nargs="?", const=DEFAULT_HTTP, default=None, metavar="HOST:PORT",
                    help=f"serve over loopback HTTP instead of stdio (default {DEFAULT_HTTP}); "
                         f"one shared server for every client, restartable without touching them")
    ap.add_argument("--read-only", action=argparse.BooleanOptionalAction, default=None,
                    help="refuse `ingest`, the one tool that writes. ON by default under --http "
                         "and off under stdio; state it either way to override that.")
    args = ap.parse_args(argv)

    # BEFORE the stack is built: a refused bind should cost nothing, and building the stack first
    # means a typo'd --http pays for model probes before it fails.
    bind = None
    if args.http is not None:
        try:
            bind = parse_bind(args.http)
        except ValueError as e:
            print(f"substrate-mcp: {e}", file=sys.stderr)
            return 2

    retrieval = stack.build(
        embed_model=args.embed_model, hyde_model=args.hyde_model,
        rerank_model=args.rerank_model, cache_path=args.cache,
        lexical_only=args.lexical_only,
    )
    # stderr, not stdout: stdout is the JSON-RPC channel and a stray line corrupts the stream.
    # Reported at startup AND carried on every response — the caller may not see this.
    for note in retrieval.unavailable:
        print(f"substrate-mcp: {note}", file=sys.stderr)

    # Doc 3 §3: `ingest` comes off the TCP transport. Any local process can reach a loopback port,
    # and `ingest` writes notes into real Obsidian vaults that the next refresh serves back as
    # settled knowledge — a persistent false-decision primitive that also syncs to OneDrive.
    # REMOVING the write is the control; a bearer token is not, which is why there is no token
    # here. stdio keeps `ingest` because reaching stdio already requires spawning this process.
    # An explicit --read-only / --no-read-only is honoured on either transport; unstated, the
    # default follows the transport, because that is the thing the exposure depends on.
    read_only = (bind is not None) if args.read_only is None else args.read_only
    # The warning for an opted-out socket belongs to `serve_http`, which is now what enforces the
    # default — one copy, so it cannot be printed by a path that does not actually apply the rule.

    cfg = Config(args.registry, retrieval, read_only=read_only)
    if bind is not None:
        return serve_http(cfg, *bind, allow_writes=not read_only)
    return serve(cfg)


if __name__ == "__main__":
    raise SystemExit(main())
