"""SQLite schema — a disposable cache, rebuildable from markdown alone.

Migration is DROP-AND-REBUILD on a `user_version` mismatch, not incremental ALTERs. That is
safe here for the same reason it is safe in ScriptaCore: no state lives only in the DB. If
this file cannot be reconstructed from the markdown in out/, something is wrong with the
design, not with the migration.

Spine columns are on every row of both tables. `document_class`, `version`, `source_sha256`
and `superseded_by` are DENORMALIZED onto chunks on purpose: a retrieved passage must be
able to state whether it is current without a join, or it reads authoritative while being
silently stale.
"""

from __future__ import annotations

import sqlite3

SCHEMA_VERSION = 3

# v1 (2026-07-21) initial: documents, chunks, chunks_fts (external-content), chunk_vectors.
# v2 (2026-07-21) chunks.section_kind — references sections were acting as retrieval
#     attractors; ranking weights them down. Derived from path_str, so no re-ingest.
# v3 (2026-07-23) Doc-2 vault spine + composition provenance. documents gains status / domains /
#     vault / tier (supersedes/superseded_by already existed, previously always NULL); chunks
#     gains status, DENORMALIZED like the rest of the spine so the default-retrieval filter reads
#     currency off the chunk without a join. Drop-and-rebuild from markdown, no data loss.
DDL = """
CREATE TABLE IF NOT EXISTS documents(
    doc_id            TEXT PRIMARY KEY,
    source_path       TEXT NOT NULL,
    source_sha256     TEXT NOT NULL,
    source_pages      INTEGER,
    markdown_path     TEXT NOT NULL,
    markdown_mtime    REAL,
    markdown_sha256   TEXT,
    title             TEXT,
    document_class    TEXT NOT NULL,
    version           TEXT,
    version_date      TEXT,
    page_label_offset INTEGER,
    extractor         TEXT,
    extractor_arm     TEXT,
    layout_model      TEXT,
    pipeline_version  TEXT,
    ingested_at       TEXT,
    last_verified_at  TEXT,
    supersedes        TEXT,
    superseded_by     TEXT,
    status            TEXT,
    domains           TEXT,
    vault             TEXT,
    tier              INTEGER,
    confidence        REAL,
    coverage          REAL
);
CREATE INDEX IF NOT EXISTS idx_documents_class  ON documents(document_class);
CREATE INDEX IF NOT EXISTS idx_documents_status ON documents(status);
CREATE INDEX IF NOT EXISTS idx_documents_vault  ON documents(vault);

CREATE TABLE IF NOT EXISTS chunks(
    chunk_id         TEXT PRIMARY KEY,
    doc_id           TEXT NOT NULL,
    kind             TEXT NOT NULL,
    seq              INTEGER,
    text             TEXT NOT NULL,
    text_with_path   TEXT NOT NULL,
    path_str         TEXT,
    path_depth       INTEGER,
    section_kind     TEXT NOT NULL DEFAULT 'body',
    level            INTEGER,
    char_start       INTEGER,
    char_end         INTEGER,
    page_start       INTEGER,
    page_end         INTEGER,
    page_label_start INTEGER,
    n_chars          INTEGER,
    part_index       INTEGER,
    part_count       INTEGER,
    oversize         INTEGER NOT NULL DEFAULT 0,
    prev_id          TEXT,
    next_id          TEXT,
    document_class   TEXT NOT NULL,
    version          TEXT,
    source_sha256    TEXT,
    confidence       REAL,
    superseded_by    TEXT,
    status           TEXT NOT NULL DEFAULT 'active'
);
CREATE INDEX IF NOT EXISTS idx_chunks_doc    ON chunks(doc_id);
CREATE INDEX IF NOT EXISTS idx_chunks_kind   ON chunks(kind);
CREATE INDEX IF NOT EXISTS idx_chunks_path   ON chunks(path_str);
CREATE INDEX IF NOT EXISTS idx_chunks_status ON chunks(status);

-- External-content FTS over chunks. text_with_path is indexed rather than text: BM25
-- cannot match a structural path that is not present in the indexed string.
CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(
    text_with_path,
    content='chunks',
    content_rowid='rowid'
);

-- No UPDATE trigger by design: writes are wholesale delete+insert per document, mirroring
-- ScriptaCore. An update trigger would silently diverge from that contract.
CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
    INSERT INTO chunks_fts(rowid, text_with_path) VALUES (new.rowid, new.text_with_path);
END;
CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
    INSERT INTO chunks_fts(chunks_fts, rowid, text_with_path)
    VALUES('delete', old.rowid, old.text_with_path);
END;

-- Vector slot: ONE embedding space at a time. chunk_id is the sole PK, so a row is per-chunk,
-- not per-(chunk, model); isolation is by convention, not the key -- drop_vectors (run on every
-- embed) purges other models and search scopes by embed_model. Stays empty until an embedder
-- beats the Phase 4 eval gate; retrieval works without it.
CREATE TABLE IF NOT EXISTS chunk_vectors(
    chunk_id    TEXT PRIMARY KEY,
    vector      BLOB NOT NULL,
    embed_model TEXT NOT NULL,
    dim         INTEGER NOT NULL
);
CREATE INDEX IF NOT EXISTS idx_vectors_model ON chunk_vectors(embed_model);

-- Per-(doc, stage) staleness ledger, ported from ScriptaCore's enrichment_ledger. Hash is
-- over DERIVED content, so a frontmatter edit does not invalidate embeddings but a body
-- edit does. model_version is load-bearing: it pins the extractor + layout model.
CREATE TABLE IF NOT EXISTS stage_ledger(
    doc_id        TEXT NOT NULL,
    stage         TEXT NOT NULL,
    content_hash  TEXT NOT NULL,
    model_version TEXT,
    updated_at    TEXT,
    PRIMARY KEY(doc_id, stage)
);
"""

DROP = """
DROP TRIGGER IF EXISTS chunks_ai;
DROP TRIGGER IF EXISTS chunks_ad;
DROP TABLE IF EXISTS chunks_fts;
DROP TABLE IF EXISTS chunk_vectors;
DROP TABLE IF EXISTS stage_ledger;
DROP TABLE IF EXISTS chunks;
DROP TABLE IF EXISTS documents;
"""


def connect(path: str) -> sqlite3.Connection:
    db = sqlite3.connect(path, isolation_level=None)
    db.row_factory = sqlite3.Row
    db.execute("PRAGMA journal_mode=WAL")
    db.execute("PRAGMA synchronous=NORMAL")
    db.execute("PRAGMA busy_timeout=5000")
    db.execute("PRAGMA foreign_keys=ON")
    db.execute("PRAGMA journal_size_limit=67108864")
    return db


def migrate(db: sqlite3.Connection) -> bool:
    """Drop and rebuild when the schema version moves. Returns True if a rebuild happened."""
    current = db.execute("PRAGMA user_version").fetchone()[0]
    rebuilt = False
    if current != SCHEMA_VERSION:
        db.executescript(DROP)
        rebuilt = True
    db.executescript(DDL)
    db.execute(f"PRAGMA user_version={SCHEMA_VERSION}")
    return rebuilt
