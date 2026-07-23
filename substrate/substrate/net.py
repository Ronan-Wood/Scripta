"""Loopback egress guard, shared by every local-only daemon arm.

The embedder ships the corpus and the HyDE expanders ship the query, so both refuse a
non-loopback host by design. The refusal keys off the authority urlsplit parses, not a textual
prefix — the old `host.split("//")[-1].split(":")[0]` guard got the host wrong two ways:

  * `http://127.0.0.1:11434@evil.example:1337` read as "127.0.0.1", which is userinfo, not the
    host; urlsplit().hostname correctly reports evil.example. urllib.request happens to mangle
    this into a DNS failure rather than reaching evil.example — it does not strip userinfo before
    the socket — but a transport that does (requests, httpx) would connect off-machine. The
    authority is ambiguous whenever userinfo is present and no local daemon needs credentials, so
    any userinfo is refused outright.
  * `http://[::1]:port` mangled down to "[", wrongly refusing a legitimate IPv6 loopback.

One copy, because two copies is how this guard drifts back: a fix applied to one call site and
not the other is exactly the shape of the bug it replaces.
"""

from __future__ import annotations

from urllib.parse import urlsplit

# urllib's .hostname is already lowercased and IPv6-bracket-stripped, so these are the forms it
# yields. Kept intentionally to the exact set the split-based guard allowed (loopback name + the
# two loopback literals) — parsed correctly, not widened.
LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})


def is_loopback(host: str) -> bool:
    """True only if `host` names a loopback authority carrying no userinfo.

    Fails CLOSED: a non-str host, userinfo (which makes the connected-to host ambiguous — see
    module docstring), a host urlsplit rejects (it raises ValueError on some malformed bracketed
    netlocs), or one it extracts no hostname from (e.g. a scheme-less string) all read as
    non-loopback, so the caller refuses them. A scheme-less host would fail downstream at urlopen
    anyway.
    """
    if not isinstance(host, str):
        return False
    try:
        parts = urlsplit(host)
        if parts.username is not None or parts.password is not None:
            return False
        hostname = parts.hostname
    except ValueError:
        return False
    return bool(hostname) and hostname.lower() in LOOPBACK_HOSTS
