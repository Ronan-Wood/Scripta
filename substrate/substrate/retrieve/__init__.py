"""Retrieval package.

Shared HTTP-failure handling for the local-daemon arms (HyDE, the rerankers) lives here so the
modules that each call a daemon over HTTP agree on what a failure IS. An incomplete per-module
exception list is how these calls used to abort a run mid-flight; a per-module copy of the same
tuple is how that would silently drift back.
"""

from __future__ import annotations

import http.client
import json

# Fail open on any transport / response-framing / body-decode failure — caught by FAMILY, not an
# explicit list: OSError covers URLError, timeouts and connection resets; HTTPException covers
# IncompleteRead / RemoteDisconnected; the decode errors cover a truncated or non-UTF-8 body.
_TRANSPORT_ERRORS = (OSError, http.client.HTTPException, json.JSONDecodeError, UnicodeDecodeError)


def _response_field(raw: bytes, key: str) -> str:
    """Field `key` from a JSON response body as a string; '' if absent, null, or the body is not
    a JSON object.

    A non-dict body — a bare string / list / null / number from a misbehaving daemon or proxy —
    must fail open here, not raise AttributeError from `.get` and abort a run. CALL INSIDE the
    caller's try: `json.loads` below can raise, and that belongs to _TRANSPORT_ERRORS at the site.
    """
    body = json.loads(raw)
    return (body.get(key) or "") if isinstance(body, dict) else ""
