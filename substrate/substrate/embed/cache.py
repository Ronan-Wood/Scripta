"""Durable, content-addressed vector cache.

This is the one store that is NOT disposable, and the exception is principled.

Everything else in the index rebuilds from markdown in seconds. Vectors do not: regenerating
them costs an embedder run and a live local daemon. So they live in their own file, outside
the index, and survive schema migrations, index drops, re-ingests and chunker changes.

Keyed on (sha256(text), model) rather than chunk_id. chunk_id is `{doc_id}#c{seq}`, so any
change to chunking renumbers every chunk and invalidates the entire cache even though the
TEXT is mostly identical. Content addressing means a chunker tweak re-embeds only the
passages whose text actually changed — which is the difference between iterating on chunking
and dreading it.

A content hash is also self-validating: a stale entry is impossible, because different text
is a different key.
"""

from __future__ import annotations

import hashlib
import sqlite3
import struct
from pathlib import Path

SCHEMA = """
CREATE TABLE IF NOT EXISTS expansions(
    query_sha  TEXT NOT NULL,
    model      TEXT NOT NULL,
    expanded   TEXT NOT NULL,
    created_at TEXT DEFAULT (datetime('now')),
    PRIMARY KEY(query_sha, model)
);

CREATE TABLE IF NOT EXISTS vectors(
    content_sha TEXT NOT NULL,
    model       TEXT NOT NULL,
    dim         INTEGER NOT NULL,
    vector      BLOB NOT NULL,
    created_at  TEXT DEFAULT (datetime('now')),
    PRIMARY KEY(content_sha, model)
);
"""


def content_sha(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


class VectorCache:
    def __init__(self, path: str | Path):
        self.path = str(path)
        Path(self.path).parent.mkdir(parents=True, exist_ok=True)
        self.db = sqlite3.connect(self.path, isolation_level=None)
        self.db.row_factory = sqlite3.Row
        self.db.execute("PRAGMA journal_mode=WAL")
        self.db.executescript(SCHEMA)

    def close(self) -> None:
        self.db.close()

    def __enter__(self) -> VectorCache:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    def get_many(self, shas: list[str], model: str) -> dict[str, list[float]]:
        """Look up many at once — one query per batch, not per chunk."""
        out: dict[str, list[float]] = {}
        for i in range(0, len(shas), 900):  # under SQLite's variable limit
            window = shas[i : i + 900]
            qs = ",".join("?" * len(window))
            for r in self.db.execute(
                f"SELECT content_sha, vector, dim FROM vectors "
                f"WHERE model=? AND content_sha IN ({qs})",
                [model, *window],
            ):
                out[r["content_sha"]] = list(struct.unpack(f"{r['dim']}f", r["vector"]))
        return out

    def put_many(self, items: list[tuple[str, list[float]]], model: str) -> int:
        self.db.executemany(
            "INSERT OR REPLACE INTO vectors(content_sha, model, dim, vector) VALUES(?,?,?,?)",
            [(sha, model, len(v), struct.pack(f"{len(v)}f", *v)) for sha, v in items],
        )
        return len(items)

    def get_expansion(self, query: str, model: str) -> str | None:
        r = self.db.execute(
            "SELECT expanded FROM expansions WHERE query_sha=? AND model=?",
            (content_sha(query), model),
        ).fetchone()
        return r["expanded"] if r else None

    def put_expansion(self, query: str, model: str, expanded: str) -> None:
        """Generation is deterministic at temperature 0, so the same question always yields
        the same hypothetical — which makes it cacheable, and turns HyDE from a ~10s/query
        cost into a one-time cost per distinct question."""
        self.db.execute(
            "INSERT OR REPLACE INTO expansions(query_sha, model, expanded) VALUES(?,?,?)",
            (content_sha(query), model, expanded),
        )

    def stats(self) -> dict:
        r = self.db.execute(
            "SELECT COUNT(*) n, COUNT(DISTINCT model) models FROM vectors"
        ).fetchone()
        size = Path(self.path).stat().st_size if Path(self.path).exists() else 0
        return {"vectors": r["n"], "models": r["models"], "bytes": size}
