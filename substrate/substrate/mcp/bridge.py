"""`substrate-mcp --connect`: a stdio face on the ONE server Scripta runs, holding no stack.

Every stdio client spawns its own server, so N clients meant N engines. Each served whatever
commit was checked out when it started, and each probed Ollama for itself. Scripta already hosts
the shared engine (`SubstrateEngine`, `--socket <path> --read-only`). This process is what a stdio
client spawns instead: the reads go to that engine, and nothing heavier than the stdlib lives here.

**The engine is trusted only once it is proven to be this user's** (`local_socket`). It listens
on a Unix socket in a 0700 directory, and before a byte of a query is written, this side checks
that directory and the uid of the process on the far end. It used to be 127.0.0.1:8765. Any
process could bind that while Scripta was closed and be sent every query. It could even answer
`list_scopes` with a matching registry and wave a write through `registry_disagreement`.

**The writes (`ingest`, `amend`) are not forwarded, and that is the design.** The shared socket is read-only because
every process this user runs can reach it (Doc 3 §3). Forwarding the write would put it back on
that socket. Instead the write runs HERE, through the same `handle()` and the same PlanBook a stdio
server uses, so it stays exactly as reachable as it is today: you can only reach it by spawning
this process. `ingest` needs only the registry and the vault, never the retrieval stack, which is
why it can run in a process that has no stack.

Answered locally: `initialize`, `tools/list` and the write tools. A client therefore connects and keeps
its full tool list even while Scripta is closed. Forwarded: every other `tools/call`. Each one
opens a fresh connection, because the server closes a connection after it has been idle for a
while, and an agent's next call can arrive minutes later.
"""

from __future__ import annotations

import http.client
import json
from pathlib import Path
from typing import Any

from substrate import local_socket

# One forwarded call, end to end. The shared server serializes every tool call on one lock, so this
# covers waiting behind other clients' calls as well as a wired `search` (HyDE plus a cross-encoder
# rerank, several seconds alone). It bounds a hung engine, and is not sized for a fast reply.
TIMEOUT_SECONDS = 300.0

# The registry comparison before a write. Short, because it delays the write, and a busy server is
# not a reason to hold a note back (see `registry_disagreement`).
REGISTRY_CHECK_SECONDS = 10.0


def _tool_error(rid: Any, text: str) -> dict:
    """An isError RESULT, not a JSON-RPC error. This matches how every other tool fault comes back
    (`server._dispatch`): the model reads the condition and can tell the user, instead of getting
    a transport failure it cannot interpret."""
    return {"jsonrpc": "2.0", "id": rid,
            "result": {"content": [{"type": "text", "text": text}], "isError": True}}


class Remote:
    """Forwards one `tools/call` to the shared server and returns its response under OUR id."""

    def __init__(self, path: Path, *, timeout: float = TIMEOUT_SECONDS) -> None:
        self.path = Path(path)
        self.timeout = timeout

    @property
    def endpoint(self) -> str:
        return str(self.path)

    def __call__(self, rid: Any, name: str, arguments: dict) -> dict:
        frame = {"jsonrpc": "2.0", "id": rid, "method": "tools/call",
                 "params": {"name": name, "arguments": arguments}}
        # ASCII-escaped: a lone surrogate is legal in a JSON string, and `encode("utf-8")` of the
        # unescaped form raises on it.
        body = json.dumps(frame).encode("ascii")
        try:
            status, raw = self._post(body)
        except (OSError, http.client.HTTPException) as e:
            return self._unreachable(rid, name, e)
        return self._relay(rid, name, status, raw)

    def registry_disagreement(self, local: Path, *, tool: str = "ingest") -> str | None:
        """Why a write here would land outside what the reads see, or None.

        One session answers from TWO registries under `--connect`. `ingest` resolves its scope
        against this process's registry, and every read resolves against the shared server's.
        A shell that exports SUBSTRATE_REGISTRY, against a Scripta launched from Finder, makes
        them differ. `search` would then show one vault while `ingest` writes into another, which
        is the silent-omission shape.

        Unknown is not a disagreement. A closed or busy Scripta is the case `ingest` must still
        serve, so only a server that ANSWERS with a different registry refuses the write. A
        listener that is not this user's never gets to answer: `local_socket` refuses it before the
        question is sent, so it cannot vouch for a registry either.

        Asked on EVERY write, never cached. The engine is restartable without touching its
        clients, and a restart can come up on another registry.
        """
        frame = {"jsonrpc": "2.0", "id": 0, "method": "tools/call",
                 "params": {"name": "list_scopes", "arguments": {}}}
        try:
            _, raw = self._post(json.dumps(frame).encode("utf-8"), REGISTRY_CHECK_SECONDS)
            text = json.loads(raw)["result"]["content"][0]["text"]
            theirs = Path(json.loads(text)["registry"]).expanduser().resolve()
        except (OSError, http.client.HTTPException, ValueError, KeyError, IndexError, TypeError):
            return None
        if theirs == local.expanduser().resolve():
            return None
        return (f"`{tool}` is refused: this process resolves scopes against {local}, but the "
                f"shared engine on {self.endpoint} reads {theirs}. Every search in this session "
                f"comes from the engine, so a note written here would go to a vault those reads "
                f"may never cover. Start this client with the same registry as Scripta's engine "
                f"(unset SUBSTRATE_REGISTRY, or pass --registry {theirs}).")

    def _post(self, body: bytes, timeout: float | None = None) -> tuple[int, bytes]:
        """One POST to this user's engine, whatever the status. A refusal (the 503 at the
        connection ceiling, a guard's 4xx) carries a JSON-RPC body, and that body is the message
        worth relaying."""
        return local_socket.post(self.path, body, timeout=timeout or self.timeout)

    def _unreachable(self, rid: Any, name: str, reason: object) -> dict:
        if isinstance(reason, local_socket.UntrustedSocket):
            return _tool_error(rid, (
                f"`{name}` was NOT sent: what holds the substrate engine's socket is not this "
                f"user's engine ({reason}). Nothing was sent to it, so no answer from it can be "
                f"relayed. Remove whatever holds {self.endpoint}, then open Scripta. `ingest` does "
                f"not need the engine and still works."))
        # No socket file is the ordinary state while Scripta is closed; a refused connection is a
        # crashed engine's leftover. Both mean the same thing to the reader.
        if isinstance(reason, (ConnectionRefusedError, FileNotFoundError)):
            return _tool_error(rid, (
                f"`{name}` runs in the shared substrate engine, which the Scripta app hosts, and "
                f"nothing is listening on {self.endpoint}. Open Scripta (it starts the engine on "
                f"launch) and call again. `ingest` does not need it and still works."))
        if isinstance(reason, TimeoutError):
            return _tool_error(rid, (
                f"the shared substrate engine on {self.endpoint} did not answer `{name}` within "
                f"{self.timeout:.0f}s. It runs one call at a time for every client, so it may be "
                f"busy, or it may be hung. Scripta's Ask pane shows its state and can restart it."))
        return _tool_error(rid, (
            f"the shared substrate engine on {self.endpoint} dropped `{name}`: "
            f"{type(reason).__name__}: {reason}"))

    def _relay(self, rid: Any, name: str, status: int, raw: bytes) -> dict:
        try:
            payload = json.loads(raw)
        except (ValueError, UnicodeDecodeError):
            payload = None
        if not isinstance(payload, dict) or not ("result" in payload or "error" in payload):
            return _tool_error(rid, (
                f"{self.endpoint} answered `{name}` with HTTP {status} and a body that is not a "
                f"JSON-RPC response. Something other than the substrate engine may hold the "
                f"socket."))
        # REWRITTEN, not trusted. Refusals made before the request is read (a 503 at the connection
        # ceiling, a guard's 4xx) carry `id: null`, and a client only resolves a pending call by
        # its own id. Passing null through would leave the call to hang until the client's timeout.
        payload["id"] = rid
        return payload
