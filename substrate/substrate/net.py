"""Loopback egress guard for the engine's local-only daemon arms.

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

A checked host is not a checked connection, so this module also owns the one transport every
model request goes through (`open_local`, GitHub #6). The default urllib opener sends a request
to whatever proxy HTTP_PROXY or the macOS system settings name, and follows redirects — neither of
which the host check sees. With HTTP_PROXY set, an embed POST addressed to 127.0.0.1 reached the
proxy with the corpus in its body (reproduced 2026-09-16).

THE ENGINE IS LOOPBACK-ONLY, NARROWER THAN THE APP ON PURPOSE. `Sources/Engine/Locality.swift` also
admits a private-LAN model host the operator has confirmed, for the app's own endpoints. The engine
takes no model host from the app — it is started with `--http <endpoint> --read-only` — so the two
policies never meet, and neither is widened to match the other.

THE SOCKET IS CHECKED TOO (GitHub #6). Every rule on the URL judges a spelling, and what `localhost`
resolves to, or how a given Python parses an authority, is outside this module. So the connected
socket's peer must itself be a loopback address before any byte is written to it.
"""

from __future__ import annotations

import http.client
import io
import ipaddress
import re
import socket
import urllib.error
import urllib.request
from urllib.parse import urlsplit

# urllib's .hostname is already lowercased and IPv6-bracket-stripped, so these are the forms it
# yields. Kept intentionally to the exact set the split-based guard allowed (loopback name + the
# two loopback literals) — parsed correctly, not widened.
LOOPBACK_HOSTS = frozenset({"127.0.0.1", "localhost", "::1"})

# urllib also opens ftp:, file: and data: URLs, and a loopback ftp: host passed the host check.
ALLOWED_SCHEMES = frozenset({"http", "https"})

# ONLY PRINTABLE ASCII. http.client sends nothing else in a host or request path — a control
# character or space is refused as InvalidURL, anything non-ASCII fails to encode — and urlsplit
# silently DELETES tab, CR and LF before parsing, so `http://local\thost` read as localhost here.
# Either way the request died in an exception the embedder does not handle; refused here instead.
_UNSENDABLE = re.compile(r"[^\x21-\x7e]")

# THE WHOLE AUTHORITY, spelled exactly. `.hostname` is a parse, and parses differ by Python
# version: on 3.11.4 `http://[::1].evil.example` read as ::1 here while http.client dialled the DNS
# name `[::1].evil.example` (3.13 and 3.14 refuse it inside urlsplit). A literal match on the text
# http.client connects to does not depend on which parser is installed. A LITERAL, deliberately
# not built from LOOPBACK_HOSTS: that set also governs the MCP server's Host check, and widening it
# for that must not widen where model requests may go. Drift between the two can only refuse.
_AUTHORITY = re.compile(r"(?:localhost|127\.0\.0\.1|\[::1\])(?::[0-9]*)?",
                        re.IGNORECASE | re.ASCII)


def is_loopback(host: str) -> bool:
    """True only if `host` is an http(s) URL naming a loopback authority carrying no userinfo.

    Fails CLOSED: a non-str host, userinfo (which makes the connected-to host ambiguous — see
    module docstring), a host urlsplit rejects (it raises ValueError on some malformed bracketed
    netlocs), one it extracts no hostname from (e.g. a scheme-less string), a scheme other than
    http/https, a character http.client will not send, or an authority that is not exactly a
    loopback name with an optional port all read as non-loopback, so the caller refuses them.
    """
    if not isinstance(host, str) or _UNSENDABLE.search(host):
        return False
    try:
        parts = urlsplit(host)
        if parts.username is not None or parts.password is not None:
            return False
        hostname = parts.hostname
        # READ FOR ITS REFUSAL, NOT ITS VALUE. `.hostname` stops at the FIRST colon and http.client
        # splits host from port at the LAST, so `http://127.0.0.1:x.evil.example:80` read as
        # 127.0.0.1 here and dialled the DNS name `127.0.0.1:x.evil.example`. `.port` raises on
        # anything but digits, which is every such spelling.
        _ = parts.port
    except ValueError:
        return False
    if not _AUTHORITY.fullmatch(parts.netloc):
        return False
    return (parts.scheme.lower() in ALLOWED_SCHEMES
            and bool(hostname) and hostname.lower() in LOOPBACK_HOSTS)


def require_loopback(
    host: str, *, sends: str, suggest: str, exc: type[Exception] = ValueError,
) -> None:
    """Raise unless `host` is a loopback URL. This is the one place the loopback check and its
    refusal message live, so neither drifts between the call sites that route through it.

    `sends` is the noun phrase for what would egress ("the corpus", "the query"); `suggest` is an
    example loopback host for the message — the caller passes its OWN default so this module stays
    daemon-agnostic; `exc` lets a caller keep its own exception type.
    """
    if not is_loopback(host):
        raise exc(
            f"refusing host {host!r}: not a loopback URL — {sends} would egress off-machine, and "
            f"this engine is local-only by design. Pass an http:// loopback host such as {suggest}."
        )


class EgressRefused(urllib.error.URLError):
    """A model request refused for leaving loopback, before any byte of it is written: by its URL,
    before a connection is attempted, or by its connected peer, right after the TCP connect. A
    URLError, so every caller's existing transport handling applies."""


class RedirectRefused(urllib.error.HTTPError):
    """A model daemon answered with a redirect, which is never followed."""


class _RefuseRedirects(urllib.request.HTTPRedirectHandler):
    # REFUSED AT THE ENTRY POINT, not in `redirect_request`: the base handler turns some redirects
    # away itself — no Location, or a scheme it will not follow — before that hook runs, and those
    # arrived as a plain HTTPError that the embedder retried as if the input were too large.
    # Raising before the base parses Location also keeps a malformed one (`http://[bad`) from
    # escaping as a ValueError no caller handles.
    def http_error_302(self, req, fp, code, msg, headers):
        target = headers.get("location") or headers.get("uri")
        refusal = RedirectRefused(
            req.full_url, code,
            f"refused a {code} redirect" + (f" to {target!r}" if target else "")
            + ": model requests are never followed anywhere, so a daemon cannot send one off "
            "this machine",
            headers, io.BytesIO(),
        )
        # NOTHING READS A REFUSAL'S BODY, so both files are closed here rather than left to the
        # garbage collector. The empty one is passed explicitly: an HTTPError built with no file
        # has none to close on older Pythons, and `close()` raised KeyError there instead of this
        # (seen on 3.9.6; 3.11.4 and 3.14.6 are fine).
        fp.close()
        refusal.close()
        raise refusal

    # The base class aliases these to ITS 302 handler, so each is rebound to this one.
    http_error_301 = http_error_303 = http_error_307 = http_error_308 = http_error_302


def _is_loopback_peer(address: str) -> bool:
    """Whether a connected socket's peer address is loopback. An IPv4-mapped IPv6 peer is judged by
    its IPv4 address: Python 3.11 calls `::ffff:127.0.0.1` not loopback, 3.14 calls it loopback."""
    try:
        ip = ipaddress.ip_address(address)
    except ValueError:
        return False
    if isinstance(ip, ipaddress.IPv6Address) and ip.ipv4_mapped is not None:
        ip = ip.ipv4_mapped
    return ip.is_loopback


def _connect_loopback(address, *args, **kwargs):
    # Runs after the TCP connect and before a byte of the request, or of a TLS handshake, is
    # written: http.client opens every connection through `_create_connection`, and HTTPS wraps
    # the socket only afterwards.
    # The socket is closed on EVERY way out but success: `getpeername()` itself fails when the
    # peer resets right after the handshake (EINVAL on macOS), and that left the socket open.
    sock = socket.create_connection(address, *args, **kwargs)
    try:
        peer = sock.getpeername()[0]
        if not _is_loopback_peer(peer):
            raise EgressRefused(
                f"refusing {address[0]!r}: it connected to {peer}, which is not a loopback address"
            )
    except BaseException:
        sock.close()
        raise
    return sock


class _LoopbackHTTPConnection(http.client.HTTPConnection):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._create_connection = _connect_loopback


class _LoopbackHTTPSConnection(http.client.HTTPSConnection):
    def __init__(self, *args, **kwargs):
        super().__init__(*args, **kwargs)
        self._create_connection = _connect_loopback


# `do_open`, not `http_open`/`https_open`: the arguments those pass differ between Python versions,
# and this forwards whatever they are.
class _LoopbackHTTPHandler(urllib.request.HTTPHandler):
    def do_open(self, http_class, req, **kwargs):
        return super().do_open(_LoopbackHTTPConnection, req, **kwargs)


class _LoopbackHTTPSHandler(urllib.request.HTTPSHandler):
    def do_open(self, http_class, req, **kwargs):
        return super().do_open(_LoopbackHTTPSConnection, req, **kwargs)


# NO PROXY — `ProxyHandler({})` replaces the default, which reads HTTP_PROXY and the macOS system
# settings — NO REDIRECTS, AND ONLY A LOOPBACK PEER, by construction rather than by each call site
# remembering. Each handler given here replaces urllib's default of the same kind.
_OPENER = urllib.request.build_opener(
    urllib.request.ProxyHandler({}), _RefuseRedirects(),
    _LoopbackHTTPHandler(), _LoopbackHTTPSHandler(),
)


def open_local(request: str | urllib.request.Request, *, timeout: float):
    """Open `request` if it is addressed to an http(s) loopback URL and its socket connects to a
    loopback address, or raise. The ONLY way the engine reaches a model daemon.

    The URL is checked on every request, not only when a client is built: `host` is an ordinary
    dataclass field, and a guard in `__post_init__` says nothing about a value assigned later.
    """
    url = request.full_url if isinstance(request, urllib.request.Request) else request
    if not is_loopback(url):
        raise EgressRefused(
            f"refusing {url!r}: model requests go only to an http(s) loopback URL"
        )
    try:
        return _OPENER.open(request, timeout=timeout)
    except urllib.error.URLError as e:
        # urllib wraps any OSError raised while connecting in a URLError, and the peer refusal is
        # one; unwrapped so callers see the refusal they handle.
        if isinstance(e.reason, EgressRefused):
            raise e.reason from None
        raise
