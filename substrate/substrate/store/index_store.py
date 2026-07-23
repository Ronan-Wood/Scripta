"""IndexStore — the single facade over the index.

Every read and write goes through here; no caller issues SQL. That is what keeps a future
Postgres/pgvector port to "reimplement this class + fts.py, then re-index" rather than a
rewrite, and it is why ScriptaCore stayed portable while its bundled MCP reader (which
hand-writes its own SELECTs against the same tables, unversioned) is the drift risk.

Writes are wholesale per document — delete then insert, in one transaction — matching the
no-UPDATE-trigger contract in schema.py. A partial write rolls back, so a document is never
left half-indexed with a fresh mtime that would suppress re-indexing.
"""

from __future__ import annotations

import hashlib
import sqlite3
import struct
from dataclasses import dataclass
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from substrate.models import Chunk, Document
from substrate.store import fts, schema, sections


@dataclass
class Hit:
    chunk_id: str
    doc_id: str
    kind: str
    text: str
    path_str: str
    path_depth: int
    page_start: int | None
    page_label_start: int | None
    n_chars: int
    score: float
    document_class: str
    version: str | None
    title: str | None
    prev_id: str | None
    next_id: str | None

    @property
    def citation(self) -> str:
        """Provenance a reasoner can quote without a second lookup."""
        bits = [self.title or self.doc_id]
        if self.path_str:
            bits.append(self.path_str)
        if self.page_label_start is not None:
            bits.append(f"p{self.page_label_start}")
        if self.version:
            bits.append(f"v{self.version}")
        return " · ".join(bits)


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _row_to_hit(r: sqlite3.Row, score: float) -> Hit:
    return Hit(
        chunk_id=r["chunk_id"],
        doc_id=r["doc_id"],
        kind=r["kind"],
        text=r["text"],
        path_str=r["path_str"] or "",
        path_depth=r["path_depth"] or 0,
        page_start=r["page_start"],
        page_label_start=r["page_label_start"],
        n_chars=r["n_chars"] or 0,
        score=score,
        document_class=r["document_class"],
        version=r["version"],
        title=r["title"] if "title" in r.keys() else None,
        prev_id=r["prev_id"],
        next_id=r["next_id"],
    )


_SELECT = """
SELECT c.*, d.title AS title
FROM chunks c JOIN documents d ON d.doc_id = c.doc_id
"""


class IndexStore:
    def __init__(self, path: str | Path):
        self.path = str(path)
        self.db = schema.connect(self.path)
        self.rebuilt = schema.migrate(self.db)

    def close(self) -> None:
        self.db.close()

    def __enter__(self) -> IndexStore:
        return self

    def __exit__(self, *exc: object) -> None:
        self.close()

    # ---------------------------------------------------------------- writes

    def upsert(
        self,
        doc: Document,
        chunks: list[Chunk],
        *,
        markdown_path: str,
        markdown_mtime: float,
        markdown_sha256: str,
        coverage: float | None = None,
    ) -> int:
        """Replace a document and all its chunks atomically."""
        db = self.db
        db.execute("BEGIN")
        try:
            self._delete_rows(doc.doc_id)
            db.execute(
                """INSERT INTO documents(
                    doc_id, source_path, source_sha256, source_pages, markdown_path,
                    markdown_mtime, markdown_sha256, title, document_class, version,
                    version_date, page_label_offset, extractor, extractor_arm, layout_model,
                    pipeline_version, ingested_at, last_verified_at, supersedes,
                    superseded_by, confidence, coverage)
                   VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    doc.doc_id, doc.source_path, doc.source_sha256, doc.source_pages,
                    markdown_path, markdown_mtime, markdown_sha256, doc.title,
                    doc.document_class, doc.version, doc.version_date, doc.page_label_offset,
                    doc.extractor, doc.extractor_arm, doc.layout_model, doc.pipeline_version,
                    _now(), _now(), None, None, None, coverage,
                ),
            )
            db.executemany(
                """INSERT INTO chunks(
                    chunk_id, doc_id, kind, seq, text, text_with_path, path_str, path_depth, section_kind,
                    level, char_start, char_end, page_start, page_end, page_label_start,
                    n_chars, part_index, part_count, oversize, prev_id, next_id,
                    document_class, version, source_sha256, confidence, superseded_by)
                   VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                [
                    (
                        c.chunk_id, c.doc_id, c.kind, i, c.text, c.text_with_path,
                        c.path_str, len(c.path), sections.classify(c.path_str), c.level, c.char_start, c.char_end,
                        c.page_start, c.page_end, c.page_label(c.page_start), c.n_chars,
                        c.part_index, c.part_count, int(bool(c.oversize)), c.prev_id,
                        c.next_id, c.document_class, c.version, c.source_sha256, None, None,
                    )
                    for i, c in enumerate(chunks)
                ],
            )
            db.execute("COMMIT")
        except Exception:
            db.execute("ROLLBACK")
            raise
        return len(chunks)

    def _delete_rows(self, doc_id: str) -> None:
        self.db.execute(
            "DELETE FROM chunk_vectors WHERE chunk_id IN "
            "(SELECT chunk_id FROM chunks WHERE doc_id=?)",
            (doc_id,),
        )
        self.db.execute("DELETE FROM chunks WHERE doc_id=?", (doc_id,))
        self.db.execute("DELETE FROM documents WHERE doc_id=?", (doc_id,))

    def remove(self, doc_id: str) -> None:
        self.db.execute("BEGIN")
        try:
            self._delete_rows(doc_id)
            self.db.execute("DELETE FROM stage_ledger WHERE doc_id=?", (doc_id,))
            self.db.execute("COMMIT")
        except Exception:
            self.db.execute("ROLLBACK")
            raise

    def clear(self) -> None:
        """Empty the cache, keep the schema. Safe: markdown is the source of truth."""
        for t in ("chunk_vectors", "chunks", "documents", "stage_ledger"):
            self.db.execute(f"DELETE FROM {t}")
        self.db.execute("INSERT INTO chunks_fts(chunks_fts) VALUES('rebuild')")

    def checkpoint(self) -> None:
        self.db.execute("PRAGMA wal_checkpoint(TRUNCATE)")

    # ---------------------------------------------------------------- reads

    def search(
        self,
        query: str,
        *,
        k: int = 10,
        kind: str | None = None,
        document_class: str | None = None,
        doc_id: str | None = None,
        min_path_depth: int | None = None,
        path_prefix: str | None = None,
    ) -> list[Hit]:
        """Lexical search, precision-first with a recall TOP-UP.

        AND hits rank first, then OR fills the remainder. The fallback deliberately does not
        wait for zero results: an eval case looking for "top-down versus bottom-up" returned
        exactly one weak AND hit, and a fires-only-on-empty fallback let that single hit
        suppress every better OR match. The document spells it "topdown", so `"down"*` never
        matches even though `"top"*` does — one unmatched term is enough to starve AND while
        the right passages sit one query away.
        """
        kw = dict(
            kind=kind, document_class=document_class, doc_id=doc_id,
            min_path_depth=min_path_depth, path_prefix=path_prefix,
        )
        seen: set[str] = set()
        out: list[Hit] = []
        for expr in (fts.and_expression(query), fts.or_expression(query)):
            if not expr or len(out) >= k:
                continue
            for h in self._match(expr, k=k, **kw):
                if h.chunk_id not in seen:
                    seen.add(h.chunk_id)
                    out.append(h)
                if len(out) >= k:
                    break
        return out[:k]

    def _match(self, expr: str, **kw: Any) -> list[Hit]:
        where = ["chunks_fts MATCH ?"]
        args: list[Any] = [expr]
        for col, val in (
            ("c.kind", kw.get("kind")),
            ("c.document_class", kw.get("document_class")),
            ("c.doc_id", kw.get("doc_id")),
        ):
            if val is not None:
                where.append(f"{col} = ?")
                args.append(val)
        if kw.get("min_path_depth") is not None:
            where.append("c.path_depth >= ?")
            args.append(kw["min_path_depth"])
        if kw.get("path_prefix"):
            where.append("(c.path_str = ? OR c.path_str LIKE ? || ' > %')")
            args.extend([kw["path_prefix"], kw["path_prefix"]])
        args.append(kw.get("k", 10))

        sql = (
            f"{_SELECT} JOIN chunks_fts ON chunks_fts.rowid = c.rowid "
            f"WHERE {' AND '.join(where)} "
            f"ORDER BY bm25(chunks_fts) * {sections.weight_sql()} LIMIT ?"
        )
        rows = self.db.execute(sql, args).fetchall()
        return [_row_to_hit(r, -float(i)) for i, r in enumerate(rows)]

    def chunk(self, chunk_id: str) -> Hit | None:
        r = self.db.execute(f"{_SELECT} WHERE c.chunk_id=?", (chunk_id,)).fetchone()
        return _row_to_hit(r, 0.0) if r else None

    def neighbours(self, chunk_id: str, window: int = 1) -> list[Hit]:
        """Expand around a hit without a second query from the caller."""
        base = self.db.execute(
            "SELECT doc_id, seq FROM chunks WHERE chunk_id=?", (chunk_id,)
        ).fetchone()
        if not base:
            return []
        rows = self.db.execute(
            f"{_SELECT} WHERE c.doc_id=? AND c.kind='passage' AND c.seq BETWEEN ? AND ? "
            "ORDER BY c.seq",
            (base["doc_id"], base["seq"] - window, base["seq"] + window),
        ).fetchall()
        return [_row_to_hit(r, 0.0) for r in rows]

    def outline_for(self, chunk_id: str) -> Hit | None:
        """The orientation record whose path is the deepest prefix of this chunk's path."""
        c = self.db.execute(
            "SELECT doc_id, path_str FROM chunks WHERE chunk_id=?", (chunk_id,)
        ).fetchone()
        if not c or not c["path_str"]:
            return None
        r = self.db.execute(
            f"{_SELECT} WHERE c.doc_id=? AND c.kind='outline' AND ? LIKE c.path_str || '%' "
            "ORDER BY LENGTH(c.path_str) DESC LIMIT 1",
            (c["doc_id"], c["path_str"]),
        ).fetchone()
        return _row_to_hit(r, 0.0) if r else None

    def passages_under(self, doc_id: str, path_prefix: str, k: int = 20) -> list[Hit]:
        """Every passage beneath a structural path. The outline layer routes with this."""
        rows = self.db.execute(
            f"{_SELECT} WHERE c.doc_id=? AND c.kind='passage' "
            "AND (c.path_str = ? OR c.path_str LIKE ? || ' > %') ORDER BY c.seq LIMIT ?",
            (doc_id, path_prefix, path_prefix, k),
        ).fetchall()
        return [_row_to_hit(r, 0.0) for r in rows]

    def documents(self) -> list[dict]:
        return [dict(r) for r in self.db.execute("SELECT * FROM documents ORDER BY doc_id")]

    @property
    def index_version(self) -> str:
        """Identity of the INDEXED content — schema version + a hash over each document's indexing
        stage_ledger hash (a sha over its chunks.jsonl + class block; reconcile writes it). So it
        changes on a re-chunk or re-extraction, not only a source-file change — 'what the index was
        built from' includes the chunk geometry, not just the source PDF. Falls back to
        source_sha256 for a doc inserted without a ledger row. Travels on the result contract so a
        caller can DETECT staleness; per PRINCIPLES.md that is surfaced, not solved — this side has
        no FSEvents watcher, so the caller must compare. Cheap: one indexed join over the (small)
        documents table. Vector-space staleness is out of scope — the embed model is a query-time
        choice, and the eval's completeness guard already refuses a partially-embedded corpus."""
        rows = self.db.execute(
            "SELECT d.doc_id, COALESCE(s.content_hash, d.source_sha256) AS h "
            "FROM documents d "
            "LEFT JOIN stage_ledger s ON s.doc_id = d.doc_id AND s.stage = 'index' "
            "ORDER BY d.doc_id"
        ).fetchall()
        sv = self.db.execute("PRAGMA user_version").fetchone()[0]
        if not rows:
            return f"v{sv}:empty"
        sig = hashlib.sha256(
            "\n".join(f"{r['doc_id']}:{r['h']}" for r in rows).encode()
        ).hexdigest()[:12]
        return f"v{sv}:{sig}"

    def stats(self) -> dict:
        q = lambda s: self.db.execute(s).fetchone()[0]  # noqa: E731
        return {
            "documents": q("SELECT COUNT(*) FROM documents"),
            "chunks": q("SELECT COUNT(*) FROM chunks"),
            "passages": q("SELECT COUNT(*) FROM chunks WHERE kind='passage'"),
            "outlines": q("SELECT COUNT(*) FROM chunks WHERE kind='outline'"),
            "vectors": q("SELECT COUNT(*) FROM chunk_vectors"),
            "schema_version": q("PRAGMA user_version"),
        }

    # ------------------------------------------------------- vector slot

    def has_vectors(self, model: str) -> bool:
        n = self.db.execute(
            "SELECT COUNT(*) FROM chunk_vectors WHERE embed_model=?", (model,)
        ).fetchone()[0]
        return n > 0

    def store_vector(self, chunk_id: str, vector: list[float], model: str) -> None:
        blob = struct.pack(f"{len(vector)}f", *vector)
        self.db.execute(
            "INSERT OR REPLACE INTO chunk_vectors(chunk_id, vector, embed_model, dim) "
            "VALUES(?,?,?,?)",
            (chunk_id, blob, model, len(vector)),
        )

    def chunks_missing_vectors(self, model: str, limit: int = 100000) -> list[tuple[str, str]]:
        """Chunks with no vector in the CURRENT model's space. This is the embed cache.

        The JOIN filters on embed_model, but the TABLE is keyed on chunk_id alone (one space at a
        time, not (chunk_id, embed_model)). So re-running the same model is a no-op, and a model
        change relies on drop_vectors -- which cmd_embed runs first -- to clear the old space
        rather than the two coexisting.
        """
        rows = self.db.execute(
            "SELECT c.chunk_id, c.text_with_path FROM chunks c "
            "LEFT JOIN chunk_vectors v ON v.chunk_id = c.chunk_id AND v.embed_model = ? "
            "WHERE v.chunk_id IS NULL LIMIT ?",
            (model, limit),
        ).fetchall()
        return [(r["chunk_id"], r["text_with_path"]) for r in rows]

    def store_vectors(self, pairs: list[tuple[str, list[float]]], model: str) -> int:
        self.db.execute("BEGIN")
        try:
            self.db.executemany(
                "INSERT OR REPLACE INTO chunk_vectors(chunk_id, vector, embed_model, dim) "
                "VALUES(?,?,?,?)",
                [
                    (cid, struct.pack(f"{len(v)}f", *v), model, len(v))
                    for cid, v in pairs
                ],
            )
            self.db.execute("COMMIT")
        except Exception:
            self.db.execute("ROLLBACK")
            raise
        return len(pairs)

    def vector_search(
        self,
        query_vec: list[float],
        model: str,
        *,
        k: int = 10,
        kind: str | None = None,
        doc_id: str | None = None,
        document_class: str | None = None,
    ) -> list[Hit]:
        """Brute-force cosine. Vectors are L2-normalized, so a dot product IS cosine.

        No ANN index: at personal-corpus scale this is instant and there is no index to
        rebuild or drift. sqlite-vec becomes worthwhile only when this stops being true.
        """
        import numpy as np

        where = ["v.embed_model = ?"]
        args: list[Any] = [model]
        for col, val in (("c.kind", kind), ("c.doc_id", doc_id),
                         ("c.document_class", document_class)):
            if val is not None:
                where.append(f"{col} = ?")
                args.append(val)

        rows = self.db.execute(
            "SELECT c.*, d.title AS title, v.vector AS vector "
            "FROM chunks c JOIN documents d ON d.doc_id = c.doc_id "
            "JOIN chunk_vectors v ON v.chunk_id = c.chunk_id "
            f"WHERE {' AND '.join(where)}",
            args,
        ).fetchall()
        if not rows:
            return []

        dim = len(query_vec)
        keep = [r for r in rows if len(r["vector"]) == dim * 4]  # never compare across spaces
        if not keep:
            return []

        mat = np.frombuffer(b"".join(r["vector"] for r in keep), dtype=np.float32)
        mat = mat.reshape(len(keep), dim)
        sims = mat @ np.asarray(query_vec, dtype=np.float32)
        top = np.argsort(-sims)[:k]
        return [_row_to_hit(keep[i], float(sims[i])) for i in top]

    def drop_vectors(self, keeping_model: str) -> int:
        """A model change invalidates the whole space — spaces are never mixed."""
        cur = self.db.execute(
            "DELETE FROM chunk_vectors WHERE embed_model <> ?", (keeping_model,)
        )
        return cur.rowcount or 0

    # ------------------------------------------------------- stage ledger

    def stage_hash(self, doc_id: str, stage: str) -> str | None:
        r = self.db.execute(
            "SELECT content_hash FROM stage_ledger WHERE doc_id=? AND stage=?",
            (doc_id, stage),
        ).fetchone()
        return r["content_hash"] if r else None

    def record_stage(
        self, doc_id: str, stage: str, content_hash: str, model_version: str | None = None
    ) -> None:
        self.db.execute(
            "INSERT OR REPLACE INTO stage_ledger"
            "(doc_id, stage, content_hash, model_version, updated_at) VALUES(?,?,?,?,?)",
            (doc_id, stage, content_hash, model_version, _now()),
        )
