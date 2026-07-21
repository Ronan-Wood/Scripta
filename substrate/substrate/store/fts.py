"""FTS5 query construction — the ONLY place a MATCH string is built.

Isolated deliberately: a Postgres port should be "reimplement the facade + this module and
re-index", not a rewrite. Ranking is NOT here — bm25() weights live in the SQL at each call
site, the same split ScriptaShared uses.

Two behaviours are ported from FTSQuery.swift because both fail SILENTLY (a malformed MATCH
returns zero rows rather than raising, so the bug looks like "no results"):

  * AND is joined EXPLICITLY. Under implicit AND, FTS5 rejects a parenthesized group placed
    next to a bare term, which silently zeroes any query using one.
  * A stray double quote terminates a phrase and corrupts the whole expression, so it is
    stripped before assembly.
"""

from __future__ import annotations

import re

STOPWORDS = frozenset(
    """
    a an and are as at be been but by can could did do does for from had has have he her
    him his how i if in into is it its me my no not of on or our out over said she should
    so some such than that the their them then there these they this those to too under up
    was we were what when where which who why will with would you your
    """.split()
)

MAX_TERMS = 12
TOKEN = re.compile(r"[A-Za-z0-9_]+")


def sanitize(text: str) -> str:
    """Remove the one character that can corrupt a MATCH expression."""
    return text.replace('"', " ")


def terms(query: str) -> list[str]:
    """Lowercase content tokens, stopwords dropped, deduped, longest kept."""
    raw = [t.lower() for t in TOKEN.findall(sanitize(query)) if len(t) >= 2]
    kept = [t for t in raw if t not in STOPWORDS] or raw
    seen: set[str] = set()
    out: list[str] = []
    for t in kept:
        if t not in seen:
            seen.add(t)
            out.append(t)
    return sorted(out, key=len, reverse=True)[:MAX_TERMS]


def _atom(term: str, prefix: bool) -> str:
    return f'"{term}"*' if prefix else f'"{term}"'


def and_expression(query: str, prefix: bool = True) -> str:
    """Precision-first: every term must appear. Explicit AND — see module docstring."""
    ts = terms(query)
    return " AND ".join(_atom(t, prefix) for t in ts) if ts else ""


def or_expression(query: str, prefix: bool = True) -> str:
    """Recall floor, used when the AND form returns nothing."""
    ts = terms(query)
    return " OR ".join(_atom(t, prefix) for t in ts) if ts else ""


def phrase_expression(query: str) -> str:
    """Exact phrase, for quoted or highly specific lookups."""
    cleaned = " ".join(TOKEN.findall(sanitize(query))).strip()
    return f'"{cleaned}"' if cleaned else ""
