"""SQLite schema — a disposable cache, rebuildable from markdown alone.

Migration is DROP-AND-REBUILD on a `user_version` mismatch, not incremental ALTERs. That is
safe here for the same reason it is safe in ScriptaCore: no state lives only in the DB. If
this file cannot be reconstructed from the markdown in out/, something is wrong with the
design, not with the migration.

Spine columns are on every row of both tables. `document_class`, `version`, `source_sha256`,
`superseded_by`, `status`, `doc_type` and `confidence` are DENORMALIZED onto chunks on purpose: a
retrieved passage must be able to state whether it is current, what job it does (§6a), and how
settled its claims are (§6b) — all without a join, or it reads authoritative while being silently
stale, mis-shaped, or more certain than the note ever claimed.
"""

from __future__ import annotations

import sqlite3

SCHEMA_VERSION = 10

# v1 (2026-07-21) initial: documents, chunks, chunks_fts (external-content), chunk_vectors.
# v2 (2026-07-21) chunks.section_kind — references sections were acting as retrieval
#     attractors; ranking weights them down. Derived from path_str, so no re-ingest.
# v3 (2026-07-23) Doc-2 vault spine + composition provenance. documents gains status / domains /
#     vault / tier (supersedes/superseded_by already existed, previously always NULL); chunks
#     gains status, DENORMALIZED like the rest of the spine so the default-retrieval filter reads
#     currency off the chunk without a join. Drop-and-rebuild from markdown, no data loss.
# v4 (2026-07-24) Doc-2 §6a doc_type — the note-job axis, four values at the time. The column is
#     TEXT and `spine.DOC_TYPES` is the only authority, so a later value needs no bump and this
#     line is history, not the current set (a fifth, `digest`, was added without one).
#     documents + chunks each gain doc_type, DENORMALIZED like status so a
#     passage states its own job without a join. A retrieval axis alongside status/domains; the
#     value is carried + surfaced now, server-side filtering deferred (like domains). Drop-and-
#     rebuild. Adds a column, not text: the (chunk_id, text_with_path) eval signature is unmoved.
# v5 (2026-07-24) also DELETES two dead columns by the criterion this bump adopted —
#     declared, bound to NULL at every insert, never read: the `confidence REAL` pair
#     (meant for extractor run stats that only ever lived in run.json) and
#     `chunks.superseded_by`. A supersession link is a DOCUMENT property; a chunk
#     reads it off its document. Keeping one dead column while deleting another
#     leaves the next reader unable to tell which are intentional.
# v6 (2026-07-24) §3b raw provenance — documents gains raw / raw_sha256 / raw_location, the
#     markdown→raw pointer Doc 2 declares system-contract. Written at ingest, read by nothing yet.
#     Not on chunks: identical per source, and the hit query already joins documents.
# v5 (2026-07-24) confidence — lands together with v4 in one change set, so no database
#     ever carried v4; the split is kept because they are separate contracts.
#     The settledness axis (proposed/inferred/stated/verified, absent → 'unstated';
#     see v7, which splits that). status says whether a note is LIVE; confidence says why its claims should
#     be believed, and a note can be active AND proposed. Without it an unbuilt design
#     retrieves reading as settled — WRITING.md rule 6 with no carrier past the note body.
#     Denormalized onto chunks like status/doc_type. Never in the (chunk_id, text_with_path)
#     FTS signature, so the eval is unmoved.
# v7 (2026-07-28) confidence vocabulary split — absent confidence now stores 'unjudged';
#     'unstated' is reserved for a note that DECLARES it makes no settledness claim. No column
#     changes: only the DDL default and the meaning of stored values move.
#
#     THE BUMP IS THE POINT, and it is the reason to bump on a value-vocabulary change at all.
#     `user_version` guards the CONTRACT of the stored data, not just the shape of the table. Rows
#     written under v6 hold 'unstated' meaning ABSENT, while every consumer now reads it as a
#     deliberate no-claim — so a v6 index answering a v7 query mislabels ~80% of the corpus as
#     judged. Without a bump nothing detects that: `freshness` compares VAULT checksums, so a
#     code-only vocabulary change reports `current` forever, and A23 passes green because
#     'unstated' is still a legal value. With it, a read refuses (SchemaMismatch) until `compose`
#     rebuilds from markdown, which is the source of truth. Refuse rather than mislead.
#     Adds no column and no text: the (chunk_id, text_with_path) eval signature is unmoved.
# v8 (2026-07-28) `supersedes` becomes LIST-VALUED. Same TEXT column, new contract: it holds a
#     JSON array, exactly as `documents.domains` already does. One live note can replace SEVERAL
#     dead ones — `substrate-topology` replaced both `multi-vault-mcp` and `connections-topology` —
#     and the scalar could name only one, so that case was being recorded in PROSE, which is
#     precisely the "a field, not prose" rule the boundary principle exists to enforce.
#
#     A VALUE-SHAPE change, so it bumps for the same reason v7 did: `user_version` guards the
#     CONTRACT of stored data, not the table shape. A v7 row holds the bare string `old-note` where
#     every v8 consumer calls json.loads — which raises on most such values and, on the rest,
#     decodes SILENTLY to a non-list (`_DOC_ID` admits all-digit ids, and json.loads("123") returns
#     an int rather than raising). A reader that guessed instead of refusing would explode an
#     8-character doc_id into eight one-character links. Nothing else detects any of it:
#     `freshness` compares VAULT checksums, so a code-only change reports `current` forever. The
#     read refuses until `compose` rebuilds from markdown.
#
#     `superseded_by` deliberately stays scalar — a dead note has exactly one live replacement.
#     Adds no column and no indexed text: the (chunk_id, text_with_path) eval signature is unmoved.
# v9 (2026-07-30) `document_class` gains an ABSENCE value — `unclassified`. The markdown reader
#     defaulted an undeclared `class:` to `reference-frozen`; it no longer defaults at all, and
#     `classes.apply` resolves the absence. Same TEXT NOT NULL column, new vocabulary.
#
#     BUMPS FOR EXACTLY v7's REASON, and the parallel is close enough to state: `user_version`
#     guards the CONTRACT of the stored data, not the shape of the table. A v8 row holds
#     'reference-frozen' where the note declared NOTHING, while every v9 consumer reads that token
#     as a note that declared a published edition — and commit a711267 put the token on the wire,
#     so the client now draws it as a settled spine axis. Measured over the operator's vaults:
#     83 of 684 notes declare a class, so a v8 index answering a v9 query mislabels ~88% of them as
#     classified. Nothing else detects it. `freshness` compares VAULT checksums, so a code-only
#     vocabulary change reports `current` forever; the A-series stays green because
#     'reference-frozen' is still a legal value; and the fixture signature deliberately hashes only
#     (chunk_id, path_str, text), so it is unmoved by design. With the bump, a read refuses
#     (SchemaMismatch) until `compose` rebuilds from the markdown that is the source of truth.
#
#     THE REBUILD IS A PURE RELABEL. `unclassified` carries reference-frozen's chunk geometry
#     verbatim (classes.py says why), so chunk_ids, chunk text and `expand_ref`s are unchanged and
#     the (chunk_id, text_with_path) eval signature is unmoved. The drop-and-rebuild still empties
#     `chunk_vectors`, exactly as v7 and v8 did — embeddings are a pure function of text and are
#     re-derived, not lost.

# v10 (2026-08-07) IDENTITY, as a CACHE. `entities` and `document_entities` hold who a note
#     mentions, resolved at compose from a file the vault DECLARES (`identity` in the manifest,
#     the same pattern `guard_state` uses). It bumps the version because it adds tables, and it is
#     worth stating why they are only ever a cache: the system of record is that vault file, not
#     this index. The index is dropped and rebuilt by every `--clean` compose, and identity must
#     survive that — a hand-made "these two names are one person" decision that a rebuild could
#     erase is worse than no identity layer at all. So nothing here is authored here; it is
#     re-derived from the declared file on every compose, and losing it costs a compose.

DDL = """CREATE TABLE IF NOT EXISTS documents(
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
    doc_type          TEXT,
    -- The note's SETTLEDNESS (proposed/inferred/stated/verified), independent of status.
    -- v5 replaces a dead `confidence REAL` column here (declared, bound to NULL at every
    -- insert, never read) that was meant for the extractor's run stats. Those live in
    -- run.json under `extract`, the only place they ever reached, so the column is deleted
    -- rather than kept beside this one. NOT NULL on chunks: absence is `unjudged`, not NULL.
    confidence        TEXT,
    -- §3b markdown→raw provenance, which Doc 2 calls system-contract. Raw is the ONLY
    -- irreplaceable layer: the index rebuilds from markdown and markdown regenerates from raw,
    -- so a lost pointer permanently freezes a source on the chunking that produced it. Recorded
    -- at ingest with no consumer yet, on purpose — RECORDING has a deadline (every source ingested
    -- without one loses its regeneration path silently, and looks identical to a source whose raw
    -- was deliberately discarded); USING it does not.
    -- Document-level only. The pointer is the same for every chunk of a source, and the hit query
    -- already joins documents, so denormalizing would be per-chunk cost for nothing.
    raw               TEXT,
    raw_sha256        TEXT,
    raw_location      TEXT,
    vault             TEXT,
    tier              INTEGER,
    coverage          REAL
);
-- Identity, re-derived at compose from the vault's declared identity file. See v10 above for why
-- this is a cache and not a record.
CREATE TABLE IF NOT EXISTS entities(
    entity_id TEXT PRIMARY KEY,
    name      TEXT NOT NULL,
    -- person / org / term. Not constrained here: the vocabulary belongs to whoever authors the
    -- identity file, and an unknown kind should reach a reader as itself rather than be rejected
    -- by an index that has no opinion about people.
    kind      TEXT,
    gloss     TEXT
);

CREATE TABLE IF NOT EXISTS document_entities(
    doc_id    TEXT NOT NULL REFERENCES documents(doc_id) ON DELETE CASCADE,
    entity_id TEXT NOT NULL REFERENCES entities(entity_id) ON DELETE CASCADE,
    -- The surface form that matched, kept because it is evidence: "A. McGinn" resolving to
    -- Alexandra McGinn is a claim, and a reader auditing a wrong merge needs to see what was
    -- actually written rather than what it was resolved to.
    surface   TEXT NOT NULL,
    PRIMARY KEY (doc_id, entity_id, surface)
);
CREATE INDEX IF NOT EXISTS idx_document_entities_entity ON document_entities(entity_id);

CREATE INDEX IF NOT EXISTS idx_documents_class    ON documents(document_class);
CREATE INDEX IF NOT EXISTS idx_documents_status   ON documents(status);
CREATE INDEX IF NOT EXISTS idx_documents_doc_type ON documents(doc_type);
CREATE INDEX IF NOT EXISTS idx_documents_confidence ON documents(confidence);
CREATE INDEX IF NOT EXISTS idx_documents_vault    ON documents(vault);

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
    status           TEXT NOT NULL DEFAULT 'active',
    doc_type         TEXT NOT NULL DEFAULT 'reference',
    -- Denormalized like status/doc_type so a passage states how settled it is without a join.
    -- NOT NULL, never NULL: a NULL would reintroduce the `NULL NOT IN (…)` hole the doc_type
    -- audit had to correct, and would read as absence rather than as 'the note did not say' —
    -- which is the distinction this axis exists to preserve.
    --
    -- v7 moves this default from 'unstated' to 'unjudged' with the vocabulary split, so the DDL
    -- and `spine` agree on what an unwritten value means. `upsert` is the sole chunk writer and
    -- binds the column explicitly on every row, so the default is unreachable in practice —
    -- but a default that contradicted the vocabulary would be a trap for the next writer.
    confidence       TEXT NOT NULL DEFAULT 'unjudged'
);
CREATE INDEX IF NOT EXISTS idx_chunks_doc      ON chunks(doc_id);
CREATE INDEX IF NOT EXISTS idx_chunks_kind     ON chunks(kind);
CREATE INDEX IF NOT EXISTS idx_chunks_path     ON chunks(path_str);
CREATE INDEX IF NOT EXISTS idx_chunks_status   ON chunks(status);
CREATE INDEX IF NOT EXISTS idx_chunks_doc_type ON chunks(doc_type);
CREATE INDEX IF NOT EXISTS idx_chunks_confidence ON chunks(confidence);

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
DROP TABLE IF EXISTS document_entities;
DROP TABLE IF EXISTS entities;
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
