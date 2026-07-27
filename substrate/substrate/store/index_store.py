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
import json
from dataclasses import dataclass, field
from datetime import UTC, datetime
from pathlib import Path
from typing import Any

from substrate.models import Chunk, Document
from substrate.store import fts, schema, sections


class StatusPartitionError(RuntimeError):
    """The indexed status set does not partition cleanly into the default-retrieval split."""


class DocTypeError(RuntimeError):
    """An indexed doc_type is outside the known four, or drifted between a chunk and its document."""


class ConfidenceError(RuntimeError):
    """An indexed confidence is not a storable value, or drifted between a chunk and its document."""


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
    # Doc-2 spine, carried ON the hit so a passage states its own currency, job and origin without
    # the caller running a second query (the Boundary Principle). `status` is the chunk-denormalized
    # currency and `doc_type` the chunk-denormalized job (§6a); `supersedes` is the link that surfaces
    # "this replaced X" when the live note is the hit; `domains`/`vault` are the retrieval tag and
    # composition provenance. (The inverse link `superseded_by` and the numeric `tier` live on the
    # documents row — read there, not surfaced on a hit: the superseded note is excluded from
    # retrieval, so its `superseded_by` never shows.)
    status: str = "active"
    doc_type: str = "reference"
    confidence: str = "unstated"
    supersedes: str | None = None
    domains: list[str] = field(default_factory=list)
    vault: str | None = None

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
        if self.vault:
            bits.append(f"@{self.vault}")
        return " · ".join(bits)


def _now() -> str:
    return datetime.now(UTC).isoformat(timespec="seconds")


def _like_escape(s: str) -> str:
    r"""Escape SQLite LIKE metacharacters so a structural path matches literally.

    A heading can contain `_` or `%` (a `snake_case` term, a "100% coverage" title); used raw as a
    LIKE prefix those act as wildcards and over-match unrelated paths. Backslash is the ESCAPE char,
    so it is escaped first. Pair with `ESCAPE '\'` in the query, and apply this to the LIKE-pattern
    arg only — an exact-match `= ?` arm takes the raw path (it has no wildcards to escape).
    """
    return s.replace("\\", "\\\\").replace("%", "\\%").replace("_", "\\_")


def _col(r: sqlite3.Row, name: str, default: object = None) -> object:
    """Row value by name, or a default when the column is absent from THIS query's projection.

    Some queries select `c.*` plus a few document aliases; others (vector_search) build their own
    projection. A hit is constructed from both, so a spine column missing from one projection must
    read as its default, not raise a KeyError."""
    return r[name] if name in r.keys() else default


def _add_status_filter(where: list[str], args: list[Any], statuses: frozenset[str] | None) -> None:
    """Append a `c.status IN (...)` clause when a status set is given. None means no filter.

    An EMPTY set is not "no filter" — it is "include nothing", and `IN ()` is a SQL syntax error,
    so it is compiled to a literal false. Silently treating an empty set as unfiltered would be the
    exact status-filter-includes-more-than-intended failure the A20 assertion guards against.
    """
    if statuses is None:
        return
    if not statuses:
        where.append("0")
        return
    ordered = sorted(statuses)
    where.append(f"c.status IN ({','.join('?' * len(ordered))})")
    args.extend(ordered)


def _add_class_exclusion(where: list[str], args: list[Any], *, include_sources: bool) -> None:
    """Exclude source-class documents from default retrieval unless explicitly asked for.

    A SEPARATE axis from status on purpose. Status says a note is dead or filed away; class says
    what KIND of thing this is. A conversation is neither superseded nor archived — it is raw
    material whose passages misrepresent it when retrieved individually (classes.EXCLUDED_CLASSES
    carries the full reasoning, including why this must not be merged with the status exclusion).

    `include_sources=True` is the explicit-ask path: the whole document is still wanted, it just
    must not arrive uninvited.
    """
    if include_sources:
        return
    from substrate.classes import EXCLUDED_CLASSES

    ordered = sorted(EXCLUDED_CLASSES)
    if not ordered:
        return
    where.append(f"c.document_class NOT IN ({','.join('?' * len(ordered))})")
    args.extend(ordered)


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
        title=_col(r, "title"),
        prev_id=r["prev_id"],
        next_id=r["next_id"],
        # `status` and `doc_type` are the chunk's own denormalized columns (from c.*); the
        # supersession link, domain tags and vault provenance are document-level, joined in and
        # aliased d_* so they never collide with the chunks table's own like-named columns.
        status=_col(r, "status", "active") or "active",
        doc_type=_col(r, "doc_type", "reference") or "reference",
        confidence=_col(r, "confidence", "unstated") or "unstated",
        supersedes=_col(r, "d_supersedes"),
        domains=json.loads(_col(r, "d_domains") or "[]"),
        vault=_col(r, "d_vault"),
    )


# c.* carries the chunk spine (incl. its own denormalized `status`); the document-level fields a
# hit surfaces — the supersession link, the domain tags, the composition provenance — are aliased
# d_* so they are unambiguous next to the chunks table's like-named columns.
_SELECT = """
SELECT c.*, d.title AS title, d.supersedes AS d_supersedes,
       d.domains AS d_domains, d.vault AS d_vault
FROM chunks c JOIN documents d ON d.doc_id = c.doc_id
"""


class SchemaMismatch(RuntimeError):
    """A read-only open found an index built by a different schema version."""


class IndexStore:
    def __init__(self, path: str | Path, *, migrate: bool = True):
        """Open an index, migrating by default.

        `migrate=False` is the READ path. Migration is drop-and-rebuild on a version mismatch, so
        merely opening an old index destroys it — which meant a nominally read-only tool (`query`,
        `status`, an MCP `search`) annihilated the index it was asked to report on, then reported
        that it was empty. Recoverable, since markdown is the source of truth, but a diagnostic
        that destroys what it diagnoses is the wrong shape. A read open refuses instead, naming
        both versions, and leaves the data for `compose` to rebuild deliberately.
        """
        self.path = str(path)
        self.db = schema.connect(self.path)
        if migrate:
            self.rebuilt = schema.migrate(self.db)
            return
        self.rebuilt = False
        found = self.db.execute("PRAGMA user_version").fetchone()[0]
        if found != schema.SCHEMA_VERSION:
            self.db.close()
            raise SchemaMismatch(
                f"{self.path} " + ("has no schema — it was never composed"
                                   if found == 0 else f"was built by schema v{found}")
                + f", this engine is v{schema.SCHEMA_VERSION}. Opening it for WRITE would drop "
                  f"and rebuild it; refusing to do that on a read. Run `substrate compose`."
            )

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
            # `status` defaults to 'active' and `doc_type` to 'reference' when the document declares
            # none — the standalone ingest path allows that (the vault path refuses an absent one
            # upstream via spine.validate_{status,doc_type}), so the existing corpus, which predates
            # both fields, stays on the live surface as reference lookup material. `domains` is stored
            # as a JSON array so the multi-valued tag survives a round-trip losslessly.
            status = doc.status or "active"
            doc_type = doc.doc_type or "reference"
            # `confidence` defaults to 'unstated', which is the one default here that is NOT a
            # convenience: a note that declared nothing must not acquire a settledness it never
            # claimed. Unlike status/doc_type this default is also what the VAULT path produces —
            # confidence is optional everywhere by design (spine.validate_confidence).
            confidence = doc.confidence or "unstated"
            db.execute(
                """INSERT INTO documents(
                    doc_id, source_path, source_sha256, source_pages, markdown_path,
                    markdown_mtime, markdown_sha256, title, document_class, version,
                    version_date, page_label_offset, extractor, extractor_arm, layout_model,
                    pipeline_version, ingested_at, last_verified_at, supersedes,
                    superseded_by, status, domains, doc_type, confidence, vault, tier, coverage,
                    raw, raw_sha256, raw_location)
                   VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                (
                    doc.doc_id, doc.source_path, doc.source_sha256, doc.source_pages,
                    markdown_path, markdown_mtime, markdown_sha256, doc.title,
                    doc.document_class, doc.version, doc.version_date, doc.page_label_offset,
                    doc.extractor, doc.extractor_arm, doc.layout_model, doc.pipeline_version,
                    _now(), _now(), doc.supersedes, doc.superseded_by,
                    status, json.dumps(list(doc.domains)), doc_type, confidence, doc.vault,
                    doc.tier, coverage, doc.raw, doc.raw_sha256, doc.raw_location,
                ),
            )
            db.executemany(
                """INSERT INTO chunks(
                    chunk_id, doc_id, kind, seq, text, text_with_path, path_str, path_depth, section_kind,
                    level, char_start, char_end, page_start, page_end, page_label_start,
                    n_chars, part_index, part_count, oversize, prev_id, next_id,
                    document_class, version, source_sha256, status, doc_type,
                    confidence)
                   VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?,?)""",
                [
                    (
                        c.chunk_id, c.doc_id, c.kind, i, c.text, c.text_with_path,
                        c.path_str, len(c.path), sections.classify(c.path_str), c.level, c.char_start, c.char_end,
                        c.page_start, c.page_end, c.page_label(c.page_start), c.n_chars,
                        c.part_index, c.part_count, int(bool(c.oversize)), c.prev_id,
                        # status, doc_type and confidence are DENORMALIZED from the document onto
                        # every chunk (like class / version / sha) so a passage reads its own
                        # currency, job and settledness off the chunk row without a join.
                        c.next_id, c.document_class, c.version, c.source_sha256, status,
                        doc_type, confidence,
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
        statuses: frozenset[str] | None = None,
        include_sources: bool = False,
    ) -> list[Hit]:
        """Lexical search, precision-first with a recall TOP-UP.

        AND hits rank first, then OR fills the remainder. The fallback deliberately does not
        wait for zero results: an eval case looking for "top-down versus bottom-up" returned
        exactly one weak AND hit, and a fires-only-on-empty fallback let that single hit
        suppress every better OR match. The document spells it "topdown", so `"down"*` never
        matches even though `"top"*` does — one unmatched term is enough to starve AND while
        the right passages sit one query away.

        `statuses` restricts to the given status set (the default retrieval set is applied by the
        retriever, not here). None means NO status filter — the historical behaviour every
        existing direct caller (the eval) relies on, so their results are unchanged.
        """
        kw = dict(
            kind=kind, document_class=document_class, doc_id=doc_id,
            min_path_depth=min_path_depth, path_prefix=path_prefix, statuses=statuses,
            include_sources=include_sources,
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
            where.append("(c.path_str = ? OR c.path_str LIKE ? || ' > %' ESCAPE '\\')")
            args.extend([kw["path_prefix"], _like_escape(kw["path_prefix"])])
        _add_status_filter(where, args, kw.get("statuses"))
        _add_class_exclusion(where, args,
                             include_sources=kw.get("include_sources", False)
                             or kw.get("document_class") is not None)
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
        # NB: the LIKE pattern here is the per-row COLUMN c.path_str, not a bound param, so
        # _like_escape (which escapes a bound value) does not apply — a `_`/`%` in a stored heading
        # can still over-match. Same bug class as the path_prefix sites above; deferred, because a
        # column pattern needs a SQL-side escape (REPLACE) or a metachar-free substr prefix-check.
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
            "AND (c.path_str = ? OR c.path_str LIKE ? || ' > %' ESCAPE '\\') ORDER BY c.seq LIMIT ?",
            (doc_id, path_prefix, _like_escape(path_prefix), k),
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

    # ------------------------------------------------------- status audit

    # The only columns `counts_by` may ever see. An f-string is the only way to parameterize a
    # GROUP BY in SQLite, so the identifier is constrained structurally rather than trusted: every
    # call site passes a literal today, and this is what keeps that true through the refactor that
    # eventually wires a caller-supplied axis into a status payload.
    _GROUPABLE = frozenset({"vault", "tier", "status", "doc_type", "confidence"})

    def counts_by(self, column: str) -> dict:
        """Document count per value of one spine axis.

        One owner for a grouping that had five hand-rolled copies disagreeing about the
        missing-value key. Keys stay NATIVE: `tier` is an INTEGER and reads back as one, so a
        count still sorts numerically and still answers an `int` lookup, and `json.dumps` renders
        it as a string at the JSON boundary without being asked. NULL groups under `'(none)'`.

        That sentinel is reachable only for `vault` and `tier`. It is NOT the schema that rules it
        out elsewhere — on `documents` all five columns are nullable, the NOT NULL DEFAULT trio
        being on `chunks` — but the Python default applied at upsert (`doc.status or 'active'`, and
        so on), which `vault` and `tier` do not get. Note this is per-value, not a COALESCE: an
        empty-string vault and a NULL vault are two buckets here, where three of the replaced
        copies merged them.
        """
        if column not in self._GROUPABLE:
            raise ValueError(
                f"{column!r} is not a groupable column; known {sorted(self._GROUPABLE)}")
        return {r[0] if r[0] is not None else "(none)": r[1]
                for r in self.db.execute(
                    f"SELECT {column}, COUNT(*) FROM documents GROUP BY {column}")}

    def _count_status_filtered(self, statuses: frozenset[str] | None) -> int:
        """Count chunks the PRODUCTION filter builder selects for a status set — the same
        `_add_status_filter` the query path uses, so the audit tests the real code, not a copy."""
        where: list[str] = []
        args: list[Any] = []
        _add_status_filter(where, args, statuses)
        sql = "SELECT COUNT(*) FROM chunks c" + (f" WHERE {' AND '.join(where)}" if where else "")
        return self.db.execute(sql, args).fetchone()[0]

    def assert_status_partition(self) -> dict:
        """A20 — the default-retrieval status filter includes and excludes exactly its declared sets.

        "Green gates, silent loss" in its status form is a filter that admits one document more (or
        fewer) than intended and still returns plausible results. Three checks over the ACTUAL
        indexed rows:

          1. no status outside the known four — an unknown/NULL value is silently excluded by
             `IN (included)`, reading as absence; refuse it rather than drop it unseen.
          2. the chunk-denormalized status agrees with its document's — a drifted chunk would leak
             or hide against what a browse of the note shows.
          3. the PRODUCTION filter builder (`_add_status_filter`, the exact code the query path
             runs) selects EXACTLY the included set and EXACTLY the excluded set, and the two
             partition the whole corpus. Genuinely independent of check 1: a polarity or omission
             bug in the filter diverges from the direct `IN (included)` count here even when every
             status is valid.

        NOT asserted here, by design: that `INCLUDED_STATUSES == {active, complete}`. That the
        constant matches Doc 2 §6 is a spec fact, pinned by test_status_filter — not a property of
        the indexed data, so it is not this data-audit's job to claim it (claiming more than it
        proves would be its own small version of the failure this guards).

        Returns the partition counts for the read-out. Raises StatusPartitionError on any breach.
        """
        from substrate.spine import EXCLUDED_STATUSES, INCLUDED_STATUSES, STATUSES

        db = self.db
        # (1) unknown / NULL statuses on either table.
        bad_docs = [
            (r["doc_id"], r["status"])
            for r in db.execute("SELECT doc_id, status FROM documents").fetchall()
            if r["status"] not in STATUSES
        ]
        bad_chunks = db.execute(
            f"SELECT COUNT(*) FROM chunks WHERE status NOT IN ({','.join('?' * len(STATUSES))})",
            sorted(STATUSES),
        ).fetchone()[0]
        if bad_docs or bad_chunks:
            raise StatusPartitionError(
                f"status outside {sorted(STATUSES)}: documents={bad_docs[:5]} "
                f"chunks={bad_chunks}. An unknown status is excluded unseen — refusing."
            )

        # (2) denormalization integrity: every chunk's status matches its document's.
        drift = db.execute(
            "SELECT COUNT(*) FROM chunks c JOIN documents d ON d.doc_id=c.doc_id "
            "WHERE c.status IS NOT d.status"
        ).fetchone()[0]
        if drift:
            raise StatusPartitionError(
                f"{drift} chunk(s) carry a status that disagrees with their document — the "
                "denormalized currency has drifted from the source note."
            )

        # (3) the ACTUAL filter builder must select the declared sets. n_in_direct hand-writes
        # `IN (included)`; n_in_filter routes through _add_status_filter — a divergence means the
        # production filter no longer implements the set it claims to. And included+excluded must
        # cover every row (nothing falls outside the partition).
        inc = sorted(INCLUDED_STATUSES)
        total = db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        n_in_direct = db.execute(
            f"SELECT COUNT(*) FROM chunks WHERE status IN ({','.join('?' * len(inc))})", inc
        ).fetchone()[0]
        n_in_filter = self._count_status_filtered(INCLUDED_STATUSES)
        n_ex_filter = self._count_status_filtered(EXCLUDED_STATUSES)
        if n_in_direct != n_in_filter:
            raise StatusPartitionError(
                f"the default-retrieval filter selects {n_in_filter} chunks but the included set "
                f"{inc} has {n_in_direct} — _add_status_filter no longer matches its declared set."
            )
        if n_in_filter + n_ex_filter != total:
            raise StatusPartitionError(
                f"status partition does not close: included={n_in_filter} excluded={n_ex_filter} "
                f"total={total}. Some row falls outside {{included}} ∪ {{excluded}}."
            )
        return {
            "included_chunks": n_in_filter, "excluded_chunks": n_ex_filter, "total_chunks": total,
            "by_status": self.counts_by("status"),
        }

    def assert_doc_type_valid(self) -> dict:
        """A21 — every indexed doc_type is one of the four §6a jobs, and the chunk denormalization
        has not drifted from its document.

        doc_type has no default-retrieval partition (every job is retrievable — unlike status, which
        excludes archived/superseded), so this is validity + denormalization integrity, not a
        partition proof. Two checks over the ACTUAL indexed rows, mirroring A20's first two:

          1. no doc_type outside the known four on either table — an unknown value is a phantom
             retrieval-axis value nothing can act on; refuse it rather than carry it unseen. (A NULL
             cannot occur in practice: documents.doc_type defaults at upsert (`doc.doc_type or
             'reference'`) and chunks.doc_type is `NOT NULL DEFAULT 'reference'`. If one somehow
             appeared, the documents side is caught by the Python `not in DOC_TYPES` (None is not a
             member); a NULL *chunk* would slip this `NOT IN` test — SQL `NULL NOT IN (...)` is NULL,
             not true — but is then caught by the drift check below, as its document's doc_type is
             non-NULL. NOT this `NOT IN` test, contra an earlier version of this note.)
          2. the chunk-denormalized doc_type agrees with its document's — a drifted chunk would
             answer a `doc_type` query under a job its note does not actually do.

        Returns the per-doc_type counts for the read-out. Raises DocTypeError on any breach.
        """
        from substrate.spine import DOC_TYPES

        db = self.db
        bad_docs = [
            (r["doc_id"], r["doc_type"])
            for r in db.execute("SELECT doc_id, doc_type FROM documents").fetchall()
            if r["doc_type"] not in DOC_TYPES
        ]
        bad_chunks = db.execute(
            f"SELECT COUNT(*) FROM chunks WHERE doc_type NOT IN ({','.join('?' * len(DOC_TYPES))})",
            sorted(DOC_TYPES),
        ).fetchone()[0]
        if bad_docs or bad_chunks:
            raise DocTypeError(
                f"doc_type outside {sorted(DOC_TYPES)}: documents={bad_docs[:5]} "
                f"chunks={bad_chunks}. An unknown doc_type is a phantom retrieval axis — refusing."
            )

        drift = db.execute(
            "SELECT COUNT(*) FROM chunks c JOIN documents d ON d.doc_id=c.doc_id "
            "WHERE c.doc_type IS NOT d.doc_type"
        ).fetchone()[0]
        if drift:
            raise DocTypeError(
                f"{drift} chunk(s) carry a doc_type that disagrees with their document — the "
                "denormalized job has drifted from the source note."
            )
        return {"by_doc_type": self.counts_by("doc_type")}

    def assert_confidence_valid(self) -> dict:
        """A23 — every indexed confidence is a storable value, and the chunk denormalization has
        not drifted from its document.

        Like doc_type and unlike status, confidence has no default-retrieval partition: nothing is
        excluded for being merely `proposed`. It is carried and SURFACED, so this is validity +
        denormalization integrity. The reason it must be checked at all is that this axis exists to
        stop confidence laundering — a chunk whose settledness drifted from its note would state a
        settledness the note never claimed, which is the precise failure the field was added for.

          1. no value outside STORED_CONFIDENCES on either table. `unstated` IS a member: absence
             is a real, surfaced value here, not a NULL. A NULL cannot occur — documents defaults at
             upsert (`doc.confidence or 'unstated'`) and chunks.confidence is `NOT NULL DEFAULT
             'unstated'` — and the schema constraint, not this query, is what guarantees it: SQL
             `NULL NOT IN (...)` evaluates to NULL rather than true, so this test alone would not
             see one. The documents side is additionally covered by the Python membership test
             below, for which None is simply not a member.
          2. the chunk-denormalized confidence agrees with its document's.

        Returns the per-confidence counts for the read-out. Raises ConfidenceError on any breach.
        """
        from substrate.spine import STORED_CONFIDENCES

        db = self.db
        bad_docs = [
            (r["doc_id"], r["confidence"])
            for r in db.execute("SELECT doc_id, confidence FROM documents").fetchall()
            if r["confidence"] not in STORED_CONFIDENCES
        ]
        bad_chunks = db.execute(
            "SELECT COUNT(*) FROM chunks WHERE confidence NOT IN "
            f"({','.join('?' * len(STORED_CONFIDENCES))})",
            sorted(STORED_CONFIDENCES),
        ).fetchone()[0]
        if bad_docs or bad_chunks:
            raise ConfidenceError(
                f"confidence outside {sorted(STORED_CONFIDENCES)}: documents={bad_docs[:5]} "
                f"chunks={bad_chunks}. An unknown settledness is a phantom axis value — refusing."
            )

        drift = db.execute(
            "SELECT COUNT(*) FROM chunks c JOIN documents d ON d.doc_id=c.doc_id "
            "WHERE c.confidence IS NOT d.confidence"
        ).fetchone()[0]
        if drift:
            raise ConfidenceError(
                f"{drift} chunk(s) carry a confidence that disagrees with their document — a "
                "passage would state a settledness its note never claimed."
            )
        return {"by_confidence": self.counts_by("confidence")}

    # ------------------------------------------------------- vector slot

    def vector_coverage(self, model: str) -> tuple[int, int]:
        """(vectors stored under `model`, total chunks) — COMPLETENESS, not presence.

        `vector_search` on a model with no stored vectors returns [] rather than raising, so a
        wired embedder over an unembedded index produces a lexical-only result set with NO
        degradation recorded anywhere: the trace shows a live embedder, and the capability that
        implies stamps a measured MRR on a run the vector arm never contributed to. That is the
        second of PRINCIPLES.md's five incidents — the code knew there were zero vectors, and a
        plausible number is what crossed the boundary.

        Presence is not enough, for the same reason the eval learned it: 256 vectors of 1811 after
        a timeout passes `> 0` and reports a confident number computed on 14% of the corpus. The
        comparison is against ALL chunks because that is what `substrate embed` fills.

        Returning the pair rather than a bool is deliberate — the caller names `n/total` in the
        degradation reason, so "never embedded" and "partially embedded" stay distinguishable to
        whoever has to fix it.

        The numerator JOINS chunks so it counts only vectors a query could actually reach. Both
        delete paths (`_delete_rows`, `clear`) do remove vectors today, so an orphan is not
        reachable through the engine — but a bare COUNT over `chunk_vectors` makes this guard's
        correctness depend on every future delete path remembering to, and the failure it would
        produce is the one this whole function exists to stop: enough orphans to satisfy
        `n >= total` on a partly-embedded index, reported as complete, with a measured MRR on top.
        """
        n = self.db.execute(
            "SELECT COUNT(*) FROM chunk_vectors v JOIN chunks c ON c.chunk_id = v.chunk_id "
            "WHERE v.embed_model=?",
            (model,),
        ).fetchone()[0]
        total = self.db.execute("SELECT COUNT(*) FROM chunks").fetchone()[0]
        return n, total

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
        statuses: frozenset[str] | None = None,
        include_sources: bool = False,
    ) -> list[Hit]:
        """Brute-force cosine. Vectors are L2-normalized, so a dot product IS cosine.

        No ANN index: at personal-corpus scale this is instant and there is no index to
        rebuild or drift. sqlite-vec becomes worthwhile only when this stops being true.

        `statuses` mirrors `search`: the same default-retrieval filter must apply to the vector
        arm, or an archived/superseded passage the lexical arm excluded would re-enter via cosine.
        None means no filter, unchanged for callers that do not pass it.
        """
        import numpy as np

        where = ["v.embed_model = ?"]
        args: list[Any] = [model]
        for col, val in (("c.kind", kind), ("c.doc_id", doc_id),
                         ("c.document_class", document_class)):
            if val is not None:
                where.append(f"{col} = ?")
                args.append(val)
        _add_status_filter(where, args, statuses)
        _add_class_exclusion(where, args,
                             include_sources=include_sources or document_class is not None)

        rows = self.db.execute(
            "SELECT c.*, d.title AS title, d.supersedes AS d_supersedes, "
            "d.domains AS d_domains, d.vault AS d_vault, v.vector AS vector "
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
