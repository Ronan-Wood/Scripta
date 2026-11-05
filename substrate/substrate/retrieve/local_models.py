"""Which Ollama models count as local, for every generator arm (HyDE, the rerankers).

`is_cloud` is the cloud test all of them share. `locality` is the matching HyDE and the listwise
reranker use (exact name, else family); the cross-encoder matches exact tags itself, since its
quant is its identity, and applies `is_cloud` to what it finds.

Ollama serves its cloud models through the local daemon. The socket is loopback, so the loopback
guard in `substrate.net` passes, and the request still leaves the machine. Whatever these arms send
is what the caller is searching their vault for — the query, and for a reranker the passages too —
so a cloud model is never used, picked or named. Same test as the app's `ModelResolver.isRemote`.
"""

from __future__ import annotations

import json

from substrate.net import open_local

# `locality` verdicts. CLOUD is kept apart from MISSING so a refusal can say "cloud" instead of
# "unreachable", which sends the reader to debug a daemon that is fine.
LOCAL = "local"
MISSING = "missing"
CLOUD = "cloud"

# What a reranker sends a model, for its refusals.
RERANK_SENDS = "every query and the passages it reorders"

# Why any cloud model is refused, in every refusal: the command lines' and `stack`'s alike.
CLOUD_REASON = "search never uses a model that runs in Ollama's cloud"


def is_cloud(entry: dict) -> bool:
    """A listing entry (or `{"name": ...}`) Ollama serves from its cloud: `remote_host` says so,
    and the tag does (`gpt-oss:120b-cloud`, `glm-4.6:cloud`) when the listing says nothing more."""
    tag = str(entry.get("name") or "").lower().rsplit(":", 1)[-1]
    return bool(entry.get("remote_host")) or tag == "cloud" or tag.endswith("-cloud")


def _bare(name: str) -> str:
    """A model name as Ollama matches it: case-insensitively, `:latest` implied."""
    low = name.lower()
    return low[: -len(":latest")] if low.endswith(":latest") else low


def locality(model: str, host: str) -> str:
    """LOCAL, MISSING or CLOUD for `model` on the daemon at `host`.

    ONE matching rule for both halves, so "refused" and "available" cannot disagree about which
    listing entry this model is: the exact name if listed, else its family (the older loose
    match, kept). Any cloud entry among the matches refuses — a differently-cased or bare spelling
    of a cloud model must not slip past the cloud test and then match by family. A cloud NAME is
    refused without asking the daemon. An unreadable listing is MISSING.

    CLOUD only when the name itself, or the entry it names exactly, is a cloud model. A name that
    matched only by family names no listed entry, so it is not a cloud model either: it is refused
    when a cloud sibling is listed, but as MISSING, since "`qwen3:4b` is a cloud model" would report
    a model that only needs pulling as a policy refusal. With no cloud sibling the loose family
    match still accepts it, as it always has, though Ollama will not resolve it to a sibling; that
    acceptance is older than this rule and is not changed here.
    """
    if is_cloud({"name": model}):
        return CLOUD
    try:
        with open_local(f"{host}/api/tags", timeout=30) as r:
            listed = [m for m in json.loads(r.read()).get("models", [])
                      if isinstance(m, dict) and isinstance(m.get("name"), str)]
    except Exception:
        return MISSING
    want = _bare(model)
    exact = [m for m in listed if _bare(m["name"]) == want]
    if exact:
        return CLOUD if any(is_cloud(m) for m in exact) else LOCAL
    family = [m for m in listed if _bare(m["name"]).split(":")[0] == want.split(":")[0]]
    return LOCAL if family and not any(is_cloud(m) for m in family) else MISSING


def cloud_message(flag: str | None, model: str, *, sends: str) -> str:
    """The refusal of `model`, once it is known to be a cloud model. `flag` is the option that
    named it, or None for an arm's own default — which no flag can be left out to avoid."""
    lead = f"{flag} {model!r}" if flag else repr(model)
    advice = f" Name a local model, or leave {flag} out." if flag else ""
    return (f"{lead} is a cloud model: Ollama would send {sends} off this Mac, and "
            f"{CLOUD_REASON}.{advice}")


def cloud_refusal(flag: str, model: str, *, sends: str) -> str | None:
    """`cloud_message` when `model`'s NAME is a cloud one, else None — for refusing at the command
    line, before the daemon is asked anything. A cloud model only the listing gives away
    (`remote_host`) is refused later, by the arm's `available()`."""
    return cloud_message(flag, model, sends=sends) if is_cloud({"name": model}) else None
