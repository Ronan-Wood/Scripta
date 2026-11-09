"""The version of the shared socket's wire, so an engine and its clients can ship apart.

The tool payloads a socket client decodes (`search`, `expand`, `list_scopes`, …) are a contract
with clients outside this package. One is the Swift `SubstrateKit` that ships in an app, and one is
`substrate-mcp --connect` from another install. Until this existed, nothing said which shape a
reply had. An engine and a client from different releases could only find out by mis-decoding.

ONE INTEGER, NOT THE INDEX SCHEMA. `server.SERVER_VERSION` tracks `schema.SCHEMA_VERSION`, which
moves whenever the index's stored contract does. Most of those moves change nothing a client
decodes, so keying on it would refuse compatible pairs on every schema bump.

**THE ENGINE SERVES A RANGE,** on the model of Docker's daemon API (`ApiVersion` and
`MinAPIVersion`): every client from `MIN_VERSION` to `VERSION`. That holds because every change
between the two is additive. A reply is shaped for `VERSION`, and a client of an older version in
the range reads it by ignoring the keys it does not know. A client below `MIN_VERSION`, or above
`VERSION`, is refused, loudly.

**Bump `VERSION` when a client may rely on a change being there,** in a request or a reply: a
new tool, argument or key a newer client will use. An optional key whose absence every client
already handles needs no bump. **Raise `MIN_VERSION` too when an older client would send or read
something wrongly:** a tool, argument or key removed or renamed, an argument made required, a
default, type or meaning changed, or a new value in a closed vocabulary. That refuses every client
below it, so it is the breaking change, and it comes with an app release.

**Clients from before the range match exactly.** A Scripta or `substrate-mcp --connect` older than
`MIN_VERSION` reads only a reply stating its own version, so the first bump of `VERSION` refuses
every one of them, whatever `MIN_VERSION` says. Bump it only once those are gone.

Each request says `Substrate-Wire: <n>`, and an absent header means 1, which is what every client
before this one spoke. A request outside the range is not dispatched, and is answered with a
JSON-RPC error, `MISMATCH`, naming both sides. Every reply carries the header too. A client reads a
reply in its own version or a newer one: the engine served it, so the client is inside the engine's
range. Stdlib only: `substrate-mcp --connect` imports this.
"""

from __future__ import annotations

from typing import Any

VERSION = 1
# The oldest client this engine serves. Raised only by a change an older client would misread.
MIN_VERSION = 1
HEADER = "Substrate-Wire"
MISMATCH = -32010

# What a message without the header spoke: every client and engine before the header existed.
UNSTATED = 1

# How much of a malformed value is echoed back. It came from the far end, so it is not reflected
# whole.
_SHOWN = 32


class WireMismatch(OSError):
    """The two ends of the socket speak different wire versions. Nothing was decoded."""


def declared(value: str | None) -> int:
    """The version a `Substrate-Wire` header value states. Absent means `UNSTATED`. Raises
    ValueError for anything that is not one plain positive ASCII integer. Only spaces and tabs
    around it are ignored (HTTP's optional whitespace), the same on both ends of the wire."""
    if value is None:
        return UNSTATED
    text = value.strip(" \t")
    # Nine digits at most: no real version is longer, and Swift's Int reads exactly that far, so
    # both ends refuse the same values with the same words.
    if not text.isascii() or not text.isdigit() or len(text) > 9 or int(text) < 1:
        shown = value if len(value) <= _SHOWN else value[:_SHOWN] + "…"
        raise ValueError(f"{HEADER}: {shown!r} is not a wire version")
    return int(text)


def _stated(values: list[str] | None) -> int:
    values = values or []
    if len(values) > 1:
        raise ValueError(f"{HEADER} is stated {len(values)} times; one message has one version")
    return declared(values[0] if values else None)


def unserved(values: list[str] | None) -> str | None:
    """Why the engine will not serve a request carrying these `Substrate-Wire` values, or None."""
    try:
        version = _stated(values)
    except ValueError as e:
        return str(e)
    if MIN_VERSION <= version <= VERSION:
        return None
    served = f"{VERSION}" if MIN_VERSION == VERSION else f"{MIN_VERSION} to {VERSION}"
    update = "the client" if version < MIN_VERSION else "the engine"
    return (f"this engine serves substrate wire {served} and the client speaks {version}; "
            f"update {update}")


def unread(values: list[str] | None) -> str | None:
    """Why a client will not read a reply carrying these `Substrate-Wire` values, or None."""
    try:
        version = _stated(values)
    except ValueError as e:
        return f"the engine sent {e}"
    if version >= VERSION:
        return None
    return (f"the engine speaks substrate wire {version}, older than this client's {VERSION}; "
            f"update the engine")


def refusal(msg: Any, why: str) -> Any:
    """The reply to a request the engine will not serve: the JSON-RPC rules for any error.

    Each member with an id gets its own error under that id, so every pending call resolves rather
    than waiting out its timeout. A notification gets nothing, and a batch of only notifications
    gets no reply at all. Nothing is dispatched either way."""
    if isinstance(msg, list):
        if not msg:
            return _error(None, why)
        replies = [r for r in (refusal(m, why) for m in msg) if r is not None]
        return replies or None
    if isinstance(msg, dict):
        return None if "id" not in msg else _error(msg["id"], why)
    return _error(None, why)


def _error(rid: Any, why: str) -> dict:
    return {"jsonrpc": "2.0", "id": rid,
            "error": {"code": MISMATCH, "message": why,
                      "data": {"engine": VERSION, "engine_min": MIN_VERSION}}}
