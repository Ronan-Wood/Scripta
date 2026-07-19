import Foundation
import ScriptaShared
import SQLite3
import OSLog
import Accelerate
import os

/// Transcript-level metadata as stored in the index.
public struct IndexedTranscript {
    public let path: String
    public let title: String
    public let date: String
    public let time: String
    public let duration: String
    public let participants: [String]
    public let tags: [String]
    public let summary: String
    public let mtime: Double
    /// "conference" for a single-source conference recording, "" for a normal call.
    public var mode: String = ""
    /// The privacy/workspace partition. "" = ungrouped.
    public var group: String = ""
    /// "call" for transcripts, "note" for knowledge notes. Call-listing surfaces filter on it;
    /// retrieval surfaces (Ask context, MCP retrieve) deliberately include both.
    public var kind: String = "call"
    /// The verbatim transcript body, stored so the MCP can serve get_transcript faithfully without
    /// reading the .md — which may live in a TCC-protected cloud vault the unsandboxed server can't
    /// open. A derived copy of the source (rebuilt on reconcile), distinct from the coarser `chunks`.
    public var body: String = ""

    public init(path: String, title: String, date: String, time: String, duration: String,
                participants: [String], tags: [String], summary: String, mtime: Double,
                mode: String = "", group: String = "", kind: String = "call", body: String = "") {
        self.path = path; self.title = title; self.date = date; self.time = time
        self.duration = duration; self.participants = participants; self.tags = tags
        self.summary = summary; self.mtime = mtime
        self.mode = mode; self.group = group; self.kind = kind; self.body = body
    }
}

/// One retrievable chunk of a transcript (a speaker turn).
public struct IndexedChunk {
    public let startMs: Int
    public let endMs: Int
    public let speaker: String?
    public let text: String

    public init(startMs: Int, endMs: Int, speaker: String?, text: String) {
        self.startMs = startMs; self.endMs = endMs; self.speaker = speaker; self.text = text
    }
}

/// A full passage retrieved for on-device answering.
public struct ContextChunk {
    public let path: String
    public let title: String
    public let date: String
    public let startMs: Int
    public let speaker: String
    public let text: String
    /// True for a synthetic "call summary/topics" passage (topic fusion), not spoken content.
    public var isTopic: Bool = false

    public init(path: String, title: String, date: String, startMs: Int, speaker: String,
                text: String, isTopic: Bool = false) {
        self.path = path; self.title = title; self.date = date; self.startMs = startMs
        self.speaker = speaker; self.text = text; self.isTopic = isTopic
    }
}

/// A ranked search result pointing back into a transcript.
public struct SearchHit: Identifiable {
    public let id = UUID()
    public let path: String
    public let title: String
    public let date: String
    public let startMs: Int
    public let speaker: String?
    public let snippet: String
    public let score: Double
}

/// The local retrieval backend: a SQLite database (system SQLite, FTS5) holding a derived index
/// over the transcript Markdown files. The `.md` files remain the source of truth — this DB is a
/// rebuildable cache, so it never risks the vault and can be nuked + reindexed at any time.
///
/// Reads are safe across processes (the app writes; the bundled MCP reads) via WAL mode.
/// Access within a process is serialized by an internal lock.
public final class IndexStore {
    public static let shared = try? IndexStore()

    /// Fixed location, independent of the (user-configurable) transcript output folder.
    /// Lives in the App Group container so the MCP server can read it across the sandbox
    /// boundary; a location change just means a rebuild — this is a declared cache.
    public static var defaultURL: URL { SharedLocations.indexDB }

    /// How `search`/`context` build their MATCH expression. Production is `.andFirst`; the eval
    /// harness flips to `.legacyOr` to measure the before/after of the stopword + AND-first change.
    public enum QueryMode { case andFirst, legacyOr }
    public var queryMode: QueryMode = .andFirst

    /// Bumped whenever the schema OR the chunking geometry (see `Indexing`) changes. A DB at a
    /// different version is dropped and recreated — correct for a declared rebuildable cache —
    /// then reconcile at launch repopulates it. v2 added the transcript `mode` column; v3 versioned
    /// `chunk_vectors` (embed model + dimension) so Phase B can't silently mix vector spaces;
    /// v4 added the `group` partition column; v5 added the enrichment ledger; v6 added the entity
    /// graph (entities cache + mentions + action items); v7 chunks on-screen text too; v8 added
    /// the `kind` column and indexes knowledge notes (retrievable by Ask/MCP, hidden from call
    /// lists); v9 added the vocabulary `terms` cache (registry → DB) powering alias expansion;
    /// v10 forced a one-time rebuild so documents indexed by an intermediate build during
    /// development re-index from their full companion notes; v11 forces another after fixing the
    /// NUL-byte truncation (a NUL from a broken PDF glyph truncated the FTS bind at strlen, so
    /// documents indexed as a fragment) — control chars are now stripped before indexing;
    /// v12 forces a rebuild so the transcript/summary path also gets that NUL stripping (audit L2)
    /// and so frontmatter scalars no longer lose surrounding brackets (audit L4) — reconcile skips
    /// unchanged files by mtime, so a version bump is the only way to re-index existing rows.
    private static let schemaVersion: Int32 = 13

    private let db: OpaquePointer
    private let lock = NSLock()
    #if DEBUG
    /// DEBUG-only owner tracking so a re-entrant acquire — a locked public method calling ANOTHER
    /// locked/public method — traps with a clear message instead of silently deadlocking on the
    /// non-reentrant NSLock. From inside the lock, call the `*Locked` helper variant (audit L13).
    private let lockOwner = OSAllocatedUnfairLock<ObjectIdentifier?>(initialState: nil)
    #endif

    /// Acquires `lock` and returns its release closure: `let unlock = acquireLock(); defer { unlock() }`.
    /// The single choke point for the store lock, so the re-entrancy check has one place to live.
    private func acquireLock() -> () -> Void {
        #if DEBUG
        let me = ObjectIdentifier(Thread.current)
        lockOwner.withLock { owner in
            precondition(owner != me, "IndexStore: re-entrant lock — call the *Locked helper from inside the store lock, not a public locking method.")
        }
        #endif
        lock.lock()
        #if DEBUG
        lockOwner.withLock { $0 = me }
        #endif
        return { [self] in
            #if DEBUG
            lockOwner.withLock { $0 = nil }
            #endif
            lock.unlock()
        }
    }
    private let log = Logger(subsystem: "com.ronanwood.Scripta", category: "Index")
    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    public init(url: URL = IndexStore.defaultURL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "Scripta.Index", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not open the index database."])
        }
        db = handle
        sqlite3_busy_timeout(db, 3000)
        exec("PRAGMA journal_mode=WAL;")
        // Bound the on-disk WAL. The app is the sole writer and TRUNCATE-checkpoints at the end of each
        // indexing pass (see `checkpoint()`), but a passive auto-checkpoint that fires mid-pass leaves the
        // -wal file at its high-water mark; journal_size_limit makes SQLite hand that space back so the
        // file can't sit multi-MB and slow the read-only opener the bundled MCP mmaps it through.
        exec("PRAGMA journal_size_limit=\(4 * 1024 * 1024);")
        exec("PRAGMA foreign_keys=ON;")
        migrateIfNeeded()
        createSchema()
    }

    deinit { sqlite3_close(db) }

    // MARK: - Schema

    /// Drops everything if the stored schema version differs, so a schema/chunking change can't
    /// silently no-op against an old DB (createSchema is all `IF NOT EXISTS`).
    private func migrateIfNeeded() {
        var version: Int32 = 0
        query("PRAGMA user_version;") { version = sqlite3_column_int($0, 0) }
        guard version != Self.schemaVersion else { return }
        if version != 0 { log.notice("index schema \(version) → \(Self.schemaVersion): rebuilding") }
        dropAll()
        exec("PRAGMA user_version = \(Self.schemaVersion);")
    }

    private func dropAll() {
        // A schema/chunking bump is a full rebuild: drop EVERY derived table so createSchema recreates
        // each at the new schema and reconcile/syncTerms/embedPending repopulate from source (the .md
        // files + the EntityRegistry). DROP (not DELETE) is what lets a table's columns change across a
        // bump — createSchema is all IF NOT EXISTS, so any surviving table silently keeps its old schema.
        // This MUST cover the enrichment_ledger + entity graph: a ledger row that outlives its dropped
        // output table gates that output's regeneration off (stale hash == current ⇒ skip), e.g. leaving
        // chunk_vectors empty after the bump — the invariant clear() enforces (M2). clear() keeps `terms`
        // (a live rebuild at an unchanged schema); a migration drops it too, and syncTerms refills it.
        exec("""
        DROP TRIGGER IF EXISTS chunks_ai;
        DROP TRIGGER IF EXISTS chunks_ad;
        DROP TABLE IF EXISTS chunks_fts;
        DROP TABLE IF EXISTS transcripts_fts;
        DROP TABLE IF EXISTS chunk_vectors;
        DROP TABLE IF EXISTS chunks;
        DROP TABLE IF EXISTS transcripts;
        DROP TABLE IF EXISTS enrichment_ledger;
        DROP TABLE IF EXISTS entities;
        DROP TABLE IF EXISTS entity_mentions;
        DROP TABLE IF EXISTS action_items;
        DROP TABLE IF EXISTS terms;
        """)
    }

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS transcripts(
            path TEXT PRIMARY KEY,
            title TEXT, date TEXT, time TEXT, duration TEXT,
            participants TEXT, tags TEXT, summary TEXT, mtime REAL, mode TEXT, "group" TEXT,
            kind TEXT NOT NULL DEFAULT 'call',
            body TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_transcripts_group ON transcripts("group");
        CREATE TABLE IF NOT EXISTS chunks(
            id INTEGER PRIMARY KEY AUTOINCREMENT,
            path TEXT NOT NULL, start_ms INTEGER, end_ms INTEGER, speaker TEXT, text TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_chunks_path ON chunks(path);
        CREATE VIRTUAL TABLE IF NOT EXISTS chunks_fts USING fts5(text, content='chunks', content_rowid='id');
        CREATE TRIGGER IF NOT EXISTS chunks_ai AFTER INSERT ON chunks BEGIN
            INSERT INTO chunks_fts(rowid, text) VALUES (new.id, new.text);
        END;
        CREATE TRIGGER IF NOT EXISTS chunks_ad AFTER DELETE ON chunks BEGIN
            INSERT INTO chunks_fts(chunks_fts, rowid, text) VALUES('delete', old.id, old.text);
        END;
        -- Transcript-level search surface: title + summary + tags + participants. Lets a query
        -- match a call by its topic/name even when no spoken chunk contains the literal word
        -- (e.g. "baseball" finding a call that only says "home runs"). Standalone FTS keyed by path.
        CREATE VIRTUAL TABLE IF NOT EXISTS transcripts_fts USING fts5(path UNINDEXED, title, summary, tags, participants);
        -- Reserved for Phase B: chunk_id -> embedding BLOB, tagged with the embed model + its
        -- dimension so vectors from different models/spaces never mix (invalidate-on-change).
        -- Left empty until an embedder passes a measured eval gate; the retriever works without it.
        CREATE TABLE IF NOT EXISTS chunk_vectors(
            chunk_id INTEGER PRIMARY KEY, vector BLOB, embed_model TEXT, dim INTEGER
        );
        -- Enrichment ledger: per-transcript, per-stage {chunk, embed, extract, summarize} status
        -- so multi-stage processing heals independently. content_hash is over the derived chunks
        -- (Indexing.contentHash) — a stage whose stored hash != the current one is stale and re-runs.
        CREATE TABLE IF NOT EXISTS enrichment_ledger(
            path TEXT, stage TEXT, content_hash TEXT, model_version TEXT,
            PRIMARY KEY(path, stage)
        );
        -- Entity graph (a CACHE of the EntityRegistry, which is the system of record). Mentions
        -- carry no group column — a mention's group is its call's group, derived by joining
        -- transcripts (Fable: don't tag edges). Action items are call-attached rows, not entities.
        CREATE TABLE IF NOT EXISTS entities(id TEXT PRIMARY KEY, name TEXT, kind TEXT);
        CREATE TABLE IF NOT EXISTS entity_mentions(
            entity_id TEXT, path TEXT, start_ms INTEGER, surface TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_mentions_entity ON entity_mentions(entity_id);
        CREATE INDEX IF NOT EXISTS idx_mentions_path ON entity_mentions(path);
        CREATE TABLE IF NOT EXISTS action_items(
            path TEXT, owner_id TEXT, text TEXT, status TEXT
        );
        CREATE INDEX IF NOT EXISTS idx_actions_path ON action_items(path);
        -- Vocabulary cache (the EntityRegistry's kind="term" entries; registry is the system of
        -- record). One row per (term, group); "" group = global. Read by alias expansion here
        -- and by the MCP server, which cannot see the registry file.
        CREATE TABLE IF NOT EXISTS terms(
            id TEXT, canonical TEXT, aliases TEXT, gloss TEXT, "group" TEXT
        );
        """)
    }

    // MARK: - Writes

    /// Replaces a transcript's row + chunks wholesale (delete then insert), keeping FTS in sync
    /// via the triggers. Called on write and on any metadata edit.
    public func upsert(_ t: IndexedTranscript, chunks: [IndexedChunk]) {
        let unlock = acquireLock(); defer { unlock() }
        guard exec("BEGIN;") else { return }
        var ok = removeRows(path: t.path)
        if ok {
            ok = run("INSERT INTO transcripts(path,title,date,time,duration,participants,tags,summary,mtime,mode,\"group\",kind,body) VALUES(?,?,?,?,?,?,?,?,?,?,?,?,?)") { stmt in
                bind(stmt, 1, t.path); bind(stmt, 2, t.title); bind(stmt, 3, t.date)
                bind(stmt, 4, t.time); bind(stmt, 5, t.duration)
                bind(stmt, 6, t.participants.joined(separator: "\n"))
                bind(stmt, 7, t.tags.joined(separator: "\n"))
                bind(stmt, 8, t.summary); sqlite3_bind_double(stmt, 9, t.mtime)
                bind(stmt, 10, t.mode); bind(stmt, 11, t.group); bind(stmt, 12, t.kind)
                bind(stmt, 13, t.body)
            }
        }
        if ok {
            ok = run("INSERT INTO transcripts_fts(path,title,summary,tags,participants) VALUES(?,?,?,?,?)") { stmt in
                bind(stmt, 1, t.path); bind(stmt, 2, t.title); bind(stmt, 3, t.summary)
                bind(stmt, 4, t.tags.joined(separator: " ")); bind(stmt, 5, t.participants.joined(separator: " "))
            }
        }
        if ok {
            for c in chunks {
                guard run("INSERT INTO chunks(path,start_ms,end_ms,speaker,text) VALUES(?,?,?,?,?)", bind: { stmt in
                    bind(stmt, 1, t.path)
                    sqlite3_bind_int64(stmt, 2, Int64(c.startMs)); sqlite3_bind_int64(stmt, 3, Int64(c.endMs))
                    if let sp = c.speaker { bind(stmt, 4, sp) } else { sqlite3_bind_null(stmt, 4) }
                    bind(stmt, 5, c.text)
                }) else { ok = false; break }
            }
        }
        // A partial upsert must never COMMIT: the fresh mtime would make reconcile's
        // self-repair skip this file forever. Rolling back leaves the old rows (and old
        // mtime) in place, so the next reconcile retries.
        if ok && exec("COMMIT;") { return }
        exec("ROLLBACK;")
    }

    /// Removes a transcript from the index (e.g. after retention prunes the file).
    public func remove(path: String) {
        let unlock = acquireLock(); defer { unlock() }
        guard exec("BEGIN;") else { return }
        if removeRows(path: path) && exec("COMMIT;") { return }
        exec("ROLLBACK;")
    }

    private func removeRows(path: String) -> Bool {
        // Cascade (I6): vectors reference chunk ids, so drop them before the chunks; ledger + FTS
        // + transcript row follow. As entity mentions/registry arrive, delete them here too.
        var ok = run("DELETE FROM chunk_vectors WHERE chunk_id IN (SELECT id FROM chunks WHERE path = ?)") { bind($0, 1, path) }
        ok = run("DELETE FROM chunks WHERE path = ?") { bind($0, 1, path) } && ok
        ok = run("DELETE FROM enrichment_ledger WHERE path = ?") { bind($0, 1, path) } && ok
        ok = run("DELETE FROM entity_mentions WHERE path = ?") { bind($0, 1, path) } && ok
        ok = run("DELETE FROM action_items WHERE path = ?") { bind($0, 1, path) } && ok
        ok = run("DELETE FROM transcripts WHERE path = ?") { bind($0, 1, path) } && ok
        ok = run("DELETE FROM transcripts_fts WHERE path = ?") { bind($0, 1, path) } && ok
        return ok
    }

    // MARK: - Semantic vectors (Phase B — hybrid retrieval)

    /// Stores a chunk embedding, tagged with its embed model + dimension so vector spaces can never
    /// silently mix (Fable: a model change means a full re-embed, never mixed-space fusion).
    public func storeVector(chunkID: Int64, vector: [Float], model: String) {
        let unlock = acquireLock(); defer { unlock() }
        let data = vector.withUnsafeBytes { Data($0) }
        run("INSERT OR REPLACE INTO chunk_vectors(chunk_id,vector,embed_model,dim) VALUES(?,?,?,?)") { stmt in
            sqlite3_bind_int64(stmt, 1, chunkID)
            _ = data.withUnsafeBytes { sqlite3_bind_blob(stmt, 2, $0.baseAddress, Int32(data.count), Self.TRANSIENT) }
            bind(stmt, 3, model); sqlite3_bind_int64(stmt, 4, Int64(vector.count))
        }
    }

    /// (chunk id, text) for a transcript — the embed pipeline's input.
    public func chunkRows(path: String) -> [(id: Int64, text: String)] {
        let unlock = acquireLock(); defer { unlock() }
        var out: [(Int64, String)] = []
        query("SELECT id, text FROM chunks WHERE path = ? ORDER BY id",
              bind: { Self.bindStatic($0, 1, path) }) { out.append((sqlite3_column_int64($0, 0), text($0, 1))) }
        return out
    }

    /// True once any chunk is embedded with `model` (so the retriever knows to go hybrid).
    public func hasVectors(model: String) -> Bool {
        let unlock = acquireLock(); defer { unlock() }
        var n = 0
        query("SELECT 1 FROM chunk_vectors WHERE embed_model = ? LIMIT 1",
              bind: { Self.bindStatic($0, 1, model) }) { _ in n = 1 }
        return n == 1
    }

    /// Embed-version discipline: drop every vector NOT from the current model (a model change
    /// invalidates the whole space; cheap to re-embed at personal scale).
    public func dropVectors(keepingModel model: String) {
        let unlock = acquireLock(); defer { unlock() }
        run("DELETE FROM chunk_vectors WHERE embed_model <> ?") { bind($0, 1, model) }
    }

    /// Cosine top-k over in-group chunk vectors (brute-force vDSP — instant at personal scale, and
    /// no ANN index to maintain). Group-scoped inside the query, before ranking.
    public func vectorCandidates(vector queryVec: [Float], group: String?, model: String, limit: Int) -> [Int64] {
        let unlock = acquireLock(); defer { unlock() }
        var qnorm = queryVec
        var qmag: Float = 0; vDSP_svesq(queryVec, 1, &qmag, vDSP_Length(queryVec.count)); qmag = sqrt(qmag)
        if qmag > 0 { var inv = 1 / qmag; vDSP_vsmul(queryVec, 1, &inv, &qnorm, 1, vDSP_Length(queryVec.count)) }

        var sql = """
        SELECT v.chunk_id, v.vector FROM chunk_vectors v
        JOIN chunks c ON c.id = v.chunk_id JOIN transcripts t ON t.path = c.path
        WHERE v.embed_model = ?
        """
        if group != nil { sql += " AND t.\"group\" = ?" }
        var scored: [(Int64, Float)] = []
        query(sql, bind: { stmt in
            Self.bindStatic(stmt, 1, model)
            if let group { Self.bindStatic(stmt, 2, group) }
        }) { stmt in
            let id = sqlite3_column_int64(stmt, 0)
            guard let blob = sqlite3_column_blob(stmt, 1) else { return }
            let bytes = Int(sqlite3_column_bytes(stmt, 1))
            let count = bytes / MemoryLayout<Float>.size
            guard count == queryVec.count else { return }   // never compare across dimensions
            let vec = [Float](unsafeUninitializedCapacity: count) { buf, n in
                memcpy(buf.baseAddress, blob, bytes); n = count
            }
            var mag: Float = 0; vDSP_svesq(vec, 1, &mag, vDSP_Length(count)); mag = sqrt(mag)
            var dot: Float = 0; vDSP_dotpr(qnorm, 1, vec, 1, &dot, vDSP_Length(count))
            scored.append((id, mag > 0 ? dot / mag : 0))
        }
        return scored.sorted { $0.1 > $1.1 }.prefix(max(1, limit)).map(\.0)
    }

    /// FTS spoken-passage candidate chunk ids (group-scoped) — the lexical half of hybrid fusion.
    public func ftsCandidates(_ rawQuery: String, group: String?, limit: Int) -> [Int64] {
        let unlock = acquireLock(); defer { unlock() }
        let aliases = aliasGroupsLocked(group: group)
        var ids = rankedChunkIDs(FTSQuery.andExpression(rawQuery, aliasGroups: aliases), group: group, limit: limit)
        if ids.isEmpty { ids = rankedChunkIDs(FTSQuery.orExpression(rawQuery, aliasGroups: aliases), group: group, limit: limit) }
        return ids.map(\.id)
    }

    /// Materialises chunk ids into context passages (neighbour-expanded), preserving the given
    /// order — used by the hybrid retriever after RRF fusion.
    public func contextForChunkIDs(_ ids: [Int64], limit: Int) -> [ContextChunk] {
        let unlock = acquireLock(); defer { unlock() }
        var out: [ContextChunk] = []
        var seenID = Set<Int64>()
        for id in ids.prefix(limit) {
            var path = ""
            query("SELECT path FROM chunks WHERE id = ?", bind: { sqlite3_bind_int64($0, 1, id) }) { path = text($0, 0) }
            guard !path.isEmpty else { continue }
            for chunk in neighbours(of: id, path: path) where seenID.insert(chunk.id).inserted {
                out.append(chunk.chunk)
            }
        }
        return out
    }

    // MARK: - Entity graph (cache of the registry)

    /// Upserts entity cache rows (from the registry) and replaces a transcript's mentions wholesale.
    public func setEntities(_ ents: [(id: String, name: String, kind: String)],
                     mentions path: String, _ mentions: [(entityID: String, startMs: Int, surface: String)]) {
        let unlock = acquireLock(); defer { unlock() }
        guard exec("BEGIN;") else { return }
        for e in ents {
            run("INSERT OR REPLACE INTO entities(id,name,kind) VALUES(?,?,?)") { stmt in
                bind(stmt, 1, e.id); bind(stmt, 2, e.name); bind(stmt, 3, e.kind)
            }
        }
        run("DELETE FROM entity_mentions WHERE path = ?") { bind($0, 1, path) }
        for m in mentions {
            run("INSERT INTO entity_mentions(entity_id,path,start_ms,surface) VALUES(?,?,?,?)") { stmt in
                bind(stmt, 1, m.entityID); bind(stmt, 2, path)
                sqlite3_bind_int64(stmt, 3, Int64(m.startMs)); bind(stmt, 4, m.surface)
            }
        }
        if !exec("COMMIT;") { exec("ROLLBACK;") }
    }

    /// Calls that mention an entity, newest first — the entity-anchored retrieval rail (mode 3).
    /// Group-scoped by joining transcripts (a mention's group IS its call's group).
    public func callsMentioning(entityID: String, group: String?, limit: Int = 50) -> [SearchHit] {
        let unlock = acquireLock(); defer { unlock() }
        var sql = """
        SELECT DISTINCT t.path, t.title, t.date, MIN(m.start_ms)
        FROM entity_mentions m JOIN transcripts t ON t.path = m.path
        WHERE m.entity_id = ?
        """
        if group != nil { sql += " AND t.\"group\" = ?" }
        sql += " GROUP BY t.path ORDER BY t.date DESC, t.time DESC LIMIT \(max(1, limit));"
        var hits: [SearchHit] = []
        query(sql, bind: { stmt in
            Self.bindStatic(stmt, 1, entityID)
            if let group { Self.bindStatic(stmt, 2, group) }
        }) { stmt in
            hits.append(SearchHit(path: text(stmt, 0), title: text(stmt, 1), date: text(stmt, 2),
                                  startMs: Int(sqlite3_column_int64(stmt, 3)), speaker: nil,
                                  snippet: "mentions this entity", score: 0))
        }
        return hits
    }

    /// Entities appearing in a workspace, with call counts — the "People & Orgs" browse. Group-
    /// scoped by joining each mention's call to the active workspace (mentions carry no group).
    public func entities(group: String, limit: Int = 200) -> [(id: String, name: String, kind: String, count: Int)] {
        let unlock = acquireLock(); defer { unlock() }
        var out: [(String, String, String, Int)] = []
        let sql = """
        SELECT e.id, e.name, e.kind, COUNT(DISTINCT m.path) AS n
        FROM entities e JOIN entity_mentions m ON m.entity_id = e.id
        JOIN transcripts t ON t.path = m.path
        WHERE t.\"group\" = ?
        GROUP BY e.id ORDER BY n DESC, e.name LIMIT \(max(1, limit));
        """
        query(sql, bind: { Self.bindStatic($0, 1, group) }) { stmt in
            out.append((text(stmt, 0), text(stmt, 1), text(stmt, 2), Int(sqlite3_column_int(stmt, 3))))
        }
        return out
    }

    /// Distinct entity ids mentioned in a transcript (for its reader / entity chips).
    public func entityIDs(forPath path: String) -> [String] {
        let unlock = acquireLock(); defer { unlock() }
        var ids: [String] = []
        query("SELECT DISTINCT entity_id FROM entity_mentions WHERE path = ?",
              bind: { Self.bindStatic($0, 1, path) }) { ids.append(text($0, 0)) }
        return ids
    }

    // MARK: - Enrichment ledger

    /// Records that `stage` completed for `path` at content `hash` with `model`. A later reconcile
    /// treats a stage whose stored hash differs from the current content hash as stale.
    public func recordStage(path: String, stage: String, hash: String, model: String) {
        let unlock = acquireLock(); defer { unlock() }
        run("INSERT OR REPLACE INTO enrichment_ledger(path,stage,content_hash,model_version) VALUES(?,?,?,?)") { stmt in
            bind(stmt, 1, path); bind(stmt, 2, stage); bind(stmt, 3, hash); bind(stmt, 4, model)
        }
    }

    /// The content hash recorded for a completed stage, or nil if it never ran — so a caller can
    /// decide whether to (re)run embed/extract/summarize for a transcript at its current hash.
    public func stageHash(path: String, stage: String) -> String? {
        let unlock = acquireLock(); defer { unlock() }
        var h: String?
        query("SELECT content_hash FROM enrichment_ledger WHERE path = ? AND stage = ?",
              bind: { stmt in Self.bindStatic(stmt, 1, path); Self.bindStatic(stmt, 2, stage) }) { h = text($0, 0) }
        return h
    }

    /// Empties every table (keeping the schema) so a caller can reindex from disk — the "Rebuild
    /// Index" escape hatch for corruption, chunking changes, or "search seems wrong".
    public func clear() {
        let unlock = acquireLock(); defer { unlock() }
        guard exec("BEGIN;") else { return }
        exec("DELETE FROM chunks;")            // triggers keep chunks_fts in sync
        exec("DELETE FROM transcripts;")
        exec("DELETE FROM transcripts_fts;")
        exec("DELETE FROM chunk_vectors;")
        // Reset the derived caches too, or reconcile's ledger-gated stages no-op: stale
        // enrichment_ledger hashes suppress re-embedding + re-extraction, so "Rebuild Index" would
        // silently leave stale (now orphaned) embeddings and entity graph (audit M2). `terms` is the
        // vocabulary cache (from the registry, not content-derived), so it is deliberately kept.
        exec("DELETE FROM enrichment_ledger;")
        exec("DELETE FROM entities;")
        exec("DELETE FROM entity_mentions;")
        exec("DELETE FROM action_items;")
        if !exec("COMMIT;") { exec("ROLLBACK;") }
    }

    // MARK: - Maintenance

    /// Folds the WAL back into `index.db` and truncates the -wal file to zero (`wal_checkpoint(TRUNCATE)`).
    /// Call at the end of a write pass (reconcile / embed), never per-upsert. WAL mode defers every write
    /// into the -wal file; with no checkpoint it grows unbounded — bloating on disk and slowing the
    /// read-only opener the MCP uses. The app is the only writer, so this never fights another writer; it
    /// waits up to the busy timeout for any in-flight MCP reader (whose reads are per-request, never a
    /// long-lived snapshot) and, if one is mid-query, reports busy and leaves the WAL for the next pass.
    public func checkpoint() {
        let unlock = acquireLock(); defer { unlock() }
        // PRAGMA wal_checkpoint returns one row: (busy, walPages, checkpointedPages).
        var busy: Int32 = -1, moved: Int32 = 0
        query("PRAGMA wal_checkpoint(TRUNCATE);") { stmt in
            busy = sqlite3_column_int(stmt, 0)
            moved = sqlite3_column_int(stmt, 2)
        }
        if busy != 0 {
            log.notice("wal_checkpoint(TRUNCATE) busy — a reader was in flight; WAL kept, retrying next pass")
        } else {
            log.debug("wal_checkpoint(TRUNCATE): folded \(moved) frames back, WAL truncated")
        }
    }

    /// Row counts + on-disk size for the Settings "Index" section.
    public func stats() -> (calls: Int, passages: Int, bytes: Int) {
        let unlock = acquireLock(); defer { unlock() }
        var calls = 0, passages = 0
        query("SELECT (SELECT COUNT(*) FROM transcripts), (SELECT COUNT(*) FROM chunks);") { stmt in
            calls = Int(sqlite3_column_int(stmt, 0)); passages = Int(sqlite3_column_int(stmt, 1))
        }
        var bytes = 0
        query("SELECT page_count * page_size FROM pragma_page_count(), pragma_page_size();") { stmt in
            bytes = Int(sqlite3_column_int64(stmt, 0))
        }
        return (calls, passages, bytes)
    }

    /// path -> mtime for every indexed transcript, used to reconcile against the folder.
    public func indexedPaths() -> [String: Double] {
        let unlock = acquireLock(); defer { unlock() }
        var result: [String: Double] = [:]
        query("SELECT path, mtime FROM transcripts") { stmt in
            result[text(stmt, 0)] = sqlite3_column_double(stmt, 1)
        }
        return result
    }

    // MARK: - Retrieval

    /// Holistic search: free-text terms (AND-first, prefix, BM25-ranked, OR fallback) hit both
    /// spoken passages AND transcript-level fields (title/summary/tags/participants), so a call
    /// surfaces whether the word was said or is merely its topic. Passage hits rank first;
    /// topic-only calls are appended. participant/tag/date/speaker narrow results. [] if no terms.
    /// `group` is the privacy wall: non-nil scopes to that workspace ("" = ungrouped), nil means
    /// all groups (the explicit, non-default cross-group action). Applied inside the candidate
    /// query, before LIMIT.
    public func search(_ rawQuery: String, participant: String? = nil, tag: String? = nil,
                since: String? = nil, speaker: String? = nil, group: String? = nil, limit: Int = 30) -> [SearchHit] {
        let unlock = acquireLock(); defer { unlock() }
        if queryMode == .legacyOr {
            return Array(fusedHits(FTSQuery.legacyOr(rawQuery), participant: participant, tag: tag,
                                   since: since, speaker: speaker, group: group, limit: limit).prefix(limit))
        }
        // AND is near-precise for multi-word queries; fall back to OR (the recall floor) only when
        // AND finds nothing across both passages and topics. Vocabulary aliases expand both.
        let aliases = aliasGroupsLocked(group: group)
        var hits = fusedHits(FTSQuery.andExpression(rawQuery, aliasGroups: aliases), participant: participant, tag: tag,
                             since: since, speaker: speaker, group: group, limit: limit)
        if hits.isEmpty {
            hits = fusedHits(FTSQuery.orExpression(rawQuery, aliasGroups: aliases), participant: participant, tag: tag,
                             since: since, speaker: speaker, group: group, limit: limit)
        }
        return Array(hits.prefix(limit))
    }

    /// Passage hits + (unless a speaker filter is set) topic hits for one MATCH expression, with
    /// slots reserved for topic matches so a concept-tag hit isn't starved when passages fill the
    /// limit. BM25 scores aren't comparable across the two FTS tables, so reserve slots rather than
    /// merge scores.
    private func fusedHits(_ match: String?, participant: String?, tag: String?,
                           since: String?, speaker: String?, group: String?, limit: Int) -> [SearchHit] {
        guard let match else { return [] }
        let passages = passageHits(match, participant: participant, tag: tag, since: since, speaker: speaker, group: group, limit: limit)
        let speakerScoped = !(speaker == nil || speaker?.isEmpty == true)
        let passagePaths = Set(passages.map(\.path))
        let topics = speakerScoped ? [] :
            topicHits(match, participant: participant, tag: tag, since: since, group: group, limit: limit)
                .filter { !passagePaths.contains($0.path) }
        guard !topics.isEmpty else { return passages }

        let reserve = min(3, topics.count)
        var out = Array(passages.prefix(max(0, limit - reserve)))
        var seenPaths = Set(out.map(\.path))
        for topic in topics where !seenPaths.contains(topic.path) {
            out.append(topic); seenPaths.insert(topic.path)
            if out.count >= limit { break }
        }
        // Backfill any remaining budget with the passages held back by the reservation.
        if out.count < limit {
            var seenKeys = Set(out.map { "\($0.path)|\($0.startMs)" })
            for p in passages where out.count < limit {
                if seenKeys.insert("\(p.path)|\(p.startMs)").inserted { out.append(p) }
            }
        }
        return out
    }

    /// Whole-value match against a newline-joined column, so filtering by tag "ai" doesn't also
    /// match "training"/"email". The stored blob is wrapped in newlines and the value is matched
    /// as `%\nvalue\n%`.
    private static func delimitedClause(_ column: String) -> String {
        " AND (char(10)||lower(\(column))||char(10)) LIKE ? ESCAPE '\\'"
    }
    private static func delimitedValue(_ value: String) -> String {
        // Escape the LIKE metacharacters so a participant/tag literally containing % or _ matches
        // exactly, not as a wildcard (audit L3). Escape the escape char first.
        let escaped = value.lowercased()
            .replacingOccurrences(of: "\\", with: "\\\\")
            .replacingOccurrences(of: "%", with: "\\%")
            .replacingOccurrences(of: "_", with: "\\_")
        return "%\n\(escaped)\n%"
    }

    private func passageHits(_ match: String, participant: String?, tag: String?,
                             since: String?, speaker: String?, group: String?, limit: Int) -> [SearchHit] {
        var sql = """
        SELECT c.path, t.title, t.date, c.start_ms, c.speaker,
               snippet(chunks_fts, 0, '⟦', '⟧', '…', 14) AS snip, bm25(chunks_fts) AS score
        FROM chunks_fts
        JOIN chunks c ON c.id = chunks_fts.rowid
        JOIN transcripts t ON t.path = c.path
        WHERE chunks_fts MATCH ?
        """
        var binds: [(OpaquePointer?) -> Void] = [{ Self.bindStatic($0, 1, match) }]
        var n: Int32 = 2
        func filter(_ clause: String, _ value: String) {
            sql += clause; let i = n; binds.append { Self.bindStatic($0, i, value) }; n += 1
        }
        if let participant, !participant.isEmpty { filter(Self.delimitedClause("t.participants"), Self.delimitedValue(participant)) }
        if let tag, !tag.isEmpty { filter(Self.delimitedClause("t.tags"), Self.delimitedValue(tag)) }
        if let since, !since.isEmpty { filter(" AND t.date >= ?", since) }
        if let speaker, !speaker.isEmpty { filter(" AND c.speaker = ?", speaker) }
        if let group { filter(" AND t.\"group\" = ?", group) }   // the privacy wall, before LIMIT
        // Over-fetch so the per-call diversity cap below still leaves `limit` results. (The cap is
        // applied in Swift, not via a SQL window function — FTS5 snippet/bm25 don't survive being
        // wrapped in a windowed subquery.)
        sql += " ORDER BY score LIMIT \(max(1, limit) * 4);"

        var raw: [SearchHit] = []
        query(sql, bind: { stmt in binds.forEach { $0(stmt) } }) { stmt in
            raw.append(SearchHit(
                path: text(stmt, 0), title: text(stmt, 1), date: text(stmt, 2),
                startMs: Int(sqlite3_column_int64(stmt, 3)),
                speaker: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : text(stmt, 4),
                snippet: text(stmt, 5), score: sqlite3_column_double(stmt, 6)))
        }

        // Per-call diversity: keep each call's 2 best chunks so one long call can't monopolise.
        var perPath: [String: Int] = [:]
        var hits: [SearchHit] = []
        for h in raw {
            let seen = perPath[h.path, default: 0]
            if seen >= 2 { continue }
            perPath[h.path] = seen + 1
            hits.append(h)
            if hits.count >= limit { break }
        }
        return hits
    }

    private func topicHits(_ match: String, participant: String?, tag: String?,
                           since: String?, group: String?, limit: Int) -> [SearchHit] {
        // Column-weighted BM25: title strongest, then tags (the deliberate concept surface), then
        // summary, participants weakest (the participant filter already covers people-scoped search).
        var sql = """
        SELECT f.path, f.title, t.date, f.summary,
               snippet(transcripts_fts, 2, '⟦', '⟧', '…', 10) AS tagsnip,
               bm25(transcripts_fts, 0.0, 4.0, 1.0, 3.0, 0.5) AS score
        FROM transcripts_fts f
        JOIN transcripts t ON t.path = f.path
        WHERE transcripts_fts MATCH ? AND t.kind = 'call'
        """
        var binds: [(OpaquePointer?) -> Void] = [{ Self.bindStatic($0, 1, match) }]
        var n: Int32 = 2
        func filter(_ clause: String, _ value: String) {
            sql += clause; let i = n; binds.append { Self.bindStatic($0, i, value) }; n += 1
        }
        if let participant, !participant.isEmpty { filter(Self.delimitedClause("t.participants"), Self.delimitedValue(participant)) }
        if let tag, !tag.isEmpty { filter(Self.delimitedClause("t.tags"), Self.delimitedValue(tag)) }
        if let since, !since.isEmpty { filter(" AND t.date >= ?", since) }
        if let group { filter(" AND t.\"group\" = ?", group) }   // the privacy wall
        sql += " ORDER BY score LIMIT \(max(1, limit));"

        var hits: [SearchHit] = []
        query(sql, bind: { stmt in binds.forEach { $0(stmt) } }) { stmt in
            let summary = text(stmt, 3)
            let snippet = summary.isEmpty ? "matched on topic" : String(summary.prefix(160))
            hits.append(SearchHit(
                path: text(stmt, 0), title: text(stmt, 1), date: text(stmt, 2),
                startMs: 0, speaker: nil, snippet: snippet, score: sqlite3_column_double(stmt, 5)))
        }
        return hits
    }

    /// Full-text passages for retrieval-augmented answering: the whole chunk text (not a snippet),
    /// ranked by BM25, with provenance. Feeds the on-device "Ask your calls" chat.
    /// Retrieval for grounded answering. Ranks spoken passages (AND-first, OR fallback), caps to
    /// ≤2 per call for source diversity, expands each hit to its neighbour turns so the model sees
    /// the answer around the question, and appends up to 2 topic passages (title/summary/tags) so
    /// concept-tag matches — the "baseball" ↔ "home runs" layer — reach Ask too, not just search.
    /// Topic-only matches (documents, notes, and concept/title/tag call matches) for a query —
    /// the layer that has no spoken chunks or vectors. The hybrid (embeddings) retrieval path is
    /// chunk/vector-only, so it must call this too or docs and notes become invisible once a
    /// corpus is embedded.
    public func topicMatches(for rawQuery: String, group: String? = nil, limit: Int = 3) -> [ContextChunk] {
        let unlock = acquireLock(); defer { unlock() }
        let aliases = aliasGroupsLocked(group: group)
        return topicContext(FTSQuery.andExpression(rawQuery, aliasGroups: aliases)
                            ?? FTSQuery.orExpression(rawQuery, aliasGroups: aliases),
                            group: group, limit: limit)
    }

    public func context(for rawQuery: String, group: String? = nil, limit: Int = 6) -> [ContextChunk] {
        let unlock = acquireLock(); defer { unlock() }
        let aliases = aliasGroupsLocked(group: group)
        var hits = rankedChunkIDs(FTSQuery.andExpression(rawQuery, aliasGroups: aliases), group: group, limit: limit * 3)
        if hits.isEmpty { hits = rankedChunkIDs(FTSQuery.orExpression(rawQuery, aliasGroups: aliases), group: group, limit: limit * 3) }

        // Per-call diversity: at most 2 chunks per path, keeping best-ranked.
        var perPath: [String: Int] = [:]
        var kept: [(id: Int64, path: String)] = []
        for h in hits {
            let n = perPath[h.path, default: 0]
            if n >= 2 { continue }
            perPath[h.path] = n + 1
            kept.append((h.id, h.path))
            if kept.count >= limit { break }
        }

        // Expand each kept chunk to id-1…id+1 (chunk ids are contiguous and ordered per path),
        // de-duplicated, so a retrieved turn carries its surrounding exchange.
        var seenID = Set<Int64>()
        var out: [ContextChunk] = []
        for k in kept {
            for chunk in neighbours(of: k.id, path: k.path) where seenID.insert(chunk.id).inserted {
                out.append(chunk.chunk)
            }
        }

        // Topic fusion: append summary passages for concept/title/tag matches not already present.
        let seenPath = Set(out.map(\.path))
        for topic in topicContext(FTSQuery.andExpression(rawQuery, aliasGroups: aliases)
                                    ?? FTSQuery.orExpression(rawQuery, aliasGroups: aliases), group: group, limit: 2)
        where !seenPath.contains(topic.path) {
            out.append(topic)
        }
        return out
    }

    /// (chunk id, path) for spoken-passage hits, best-ranked first. Group-scoped inside the query
    /// (joins transcripts to apply the wall before LIMIT).
    private func rankedChunkIDs(_ match: String?, group: String?, limit: Int) -> [(id: Int64, path: String)] {
        guard let match else { return [] }
        var out: [(Int64, String)] = []
        var sql = """
        SELECT c.id, c.path FROM chunks_fts
        JOIN chunks c ON c.id = chunks_fts.rowid
        JOIN transcripts t ON t.path = c.path
        WHERE chunks_fts MATCH ?
        """
        if group != nil { sql += " AND t.\"group\" = ?" }
        sql += " ORDER BY bm25(chunks_fts) LIMIT \(max(1, limit));"
        query(sql, bind: { stmt in
            Self.bindStatic(stmt, 1, match)
            if let group { Self.bindStatic(stmt, 2, group) }
        }) { stmt in
            out.append((sqlite3_column_int64(stmt, 0), text(stmt, 1)))
        }
        return out
    }

    /// The chunk and its immediate neighbours on the same path, ordered by start time.
    private func neighbours(of id: Int64, path: String) -> [(id: Int64, chunk: ContextChunk)] {
        var out: [(Int64, ContextChunk)] = []
        let sql = """
        SELECT c.id, c.path, t.title, t.date, c.start_ms, IFNULL(c.speaker,''), c.text
        FROM chunks c JOIN transcripts t ON t.path = c.path
        WHERE c.path = ? AND c.id BETWEEN ? AND ? ORDER BY c.start_ms;
        """
        query(sql, bind: { stmt in
            Self.bindStatic(stmt, 1, path)
            sqlite3_bind_int64(stmt, 2, id - 1); sqlite3_bind_int64(stmt, 3, id + 1)
        }) { stmt in
            out.append((sqlite3_column_int64(stmt, 0),
                        ContextChunk(path: text(stmt, 1), title: text(stmt, 2), date: text(stmt, 3),
                                     startMs: Int(sqlite3_column_int64(stmt, 4)),
                                     speaker: text(stmt, 5), text: text(stmt, 6))))
        }
        return out
    }

    /// Synthetic passages for calls that matched by title/summary/tags — the connective tissue
    /// the on-device model uses for "reasonable connections" and whole-call questions.
    private func topicContext(_ match: String?, group: String?, limit: Int) -> [ContextChunk] {
        guard let match else { return [] }
        var out: [ContextChunk] = []
        var sql = """
        SELECT f.path, f.title, t.date, f.summary, f.tags, t.kind
        FROM transcripts_fts f JOIN transcripts t ON t.path = f.path
        WHERE transcripts_fts MATCH ?
        """
        if group != nil { sql += " AND t.\"group\" = ?" }
        sql += " ORDER BY bm25(transcripts_fts) LIMIT \(max(1, limit));"
        query(sql, bind: { stmt in
            Self.bindStatic(stmt, 1, match)
            if let group { Self.bindStatic(stmt, 2, group) }
        }) { stmt in
            let title = text(stmt, 1), summary = text(stmt, 3), tags = text(stmt, 4)
            let kind = text(stmt, 5)
            let name = title.isEmpty ? "Untitled" : title
            // Notes and documents ARE their body (indexed as summary): the user's own words and
            // files, labeled so the model treats them as theirs, not something spoken on a call.
            var parts: [String]
            switch kind {
            case "note": parts = ["The user's note: \(name)"]
            case "doc": parts = ["From the user's document “\(name)”:"]
            default: parts = ["Call: \(name)"]
            }
            if !summary.isEmpty { parts.append(kind == "call" ? "Summary: \(summary)" : summary) }
            if !tags.isEmpty { parts.append("Topics: \(tags.replacingOccurrences(of: " ", with: ", "))") }
            out.append(ContextChunk(path: text(stmt, 0), title: title, date: text(stmt, 2),
                                    startMs: 0, speaker: "", text: parts.joined(separator: ". "), isTopic: true))
        }
        return out
    }

    /// One call's card for the Home dashboard and Knowledge digest — everything the index
    /// already holds about a call, so those surfaces never re-read transcript files.
    public struct DigestRow {
        let path: String
        let title: String
        let date: String
        let time: String
        let duration: String
        let summary: String
        let participants: [String]
        let tags: [String]
    }

    /// Recent calls in one workspace, newest first — the dashboard/digest feed. Scoped to the
    /// group like every other read surface (the privacy wall applies to dashboards too).
    public func digest(group: String, limit: Int = 400) -> [DigestRow] {
        let unlock = acquireLock(); defer { unlock() }
        var rows: [DigestRow] = []
        query("""
            SELECT path, title, date, time, duration, participants, tags, summary FROM transcripts
            WHERE "group" = ? AND kind = 'call' ORDER BY date DESC, time DESC LIMIT ?
            """,
              bind: { Self.bindStatic($0, 1, group); sqlite3_bind_int($0, 2, Int32(limit)) }) { stmt in
            rows.append(DigestRow(
                path: text(stmt, 0), title: text(stmt, 1), date: text(stmt, 2), time: text(stmt, 3),
                duration: text(stmt, 4), summary: text(stmt, 7),
                participants: text(stmt, 5).split(separator: "\n").map(String.init),
                tags: text(stmt, 6).split(separator: "\n").map(String.init).filter { $0 != OwnerMarker.value }))
        }
        return rows
    }

    // MARK: - Vocabulary (terms cache)

    public struct TermRow {
        public let id: String
        public let canonical: String
        public let aliases: [String]
        public let gloss: String
        public let group: String

        public init(id: String, canonical: String, aliases: [String], gloss: String, group: String) {
            self.id = id; self.canonical = canonical; self.aliases = aliases
            self.gloss = gloss; self.group = group
        }
    }

    /// Replaces the vocabulary cache wholesale (mirrors the registry's kind="term" entries).
    public func setTerms(_ rows: [TermRow]) {
        let unlock = acquireLock(); defer { unlock() }
        guard exec("BEGIN;") else { return }
        var ok = run("DELETE FROM terms;") { _ in }
        for row in rows where ok {
            ok = run("INSERT INTO terms(id,canonical,aliases,gloss,\"group\") VALUES(?,?,?,?,?)") { stmt in
                bind(stmt, 1, row.id); bind(stmt, 2, row.canonical)
                bind(stmt, 3, row.aliases.joined(separator: "\n"))
                bind(stmt, 4, row.gloss); bind(stmt, 5, row.group)
            }
        }
        if ok && exec("COMMIT;") { return }
        exec("ROLLBACK;")
    }

    /// Alias groups for query expansion: [canonical + aliases], scoped to a workspace plus
    /// globals (nil group = everything, for the blind cross-workspace search).
    public func aliasGroups(group: String?) -> [[String]] {
        let unlock = acquireLock(); defer { unlock() }
        return aliasGroupsLocked(group: group)
    }

    /// Lock-free variant for callers already inside the store's lock (NSLock is non-reentrant).
    private func aliasGroupsLocked(group: String?) -> [[String]] {
        var out: [[String]] = []
        var sql = "SELECT canonical, aliases FROM terms"
        if group != nil { sql += " WHERE \"group\" = ? OR \"group\" = ''" }
        query(sql, bind: { stmt in if let group { Self.bindStatic(stmt, 1, group) } }) { stmt in
            var members = [text(stmt, 0).lowercased()]
            for alias in text(stmt, 1).split(separator: "\n").map(String.init) where !members.contains(alias) {
                members.append(alias)
            }
            if members.count > 1 { out.append(members) }
        }
        return out
    }

    /// A sample of spoken text for deterministic vocabulary suggestion (acronym mining).
    public func sampleChunkTexts(group: String, limit: Int = 400) -> [String] {
        let unlock = acquireLock(); defer { unlock() }
        var out: [String] = []
        query("""
            SELECT c.text FROM chunks c JOIN transcripts t ON t.path = c.path
            WHERE t."group" = ? AND t.kind = 'call' LIMIT ?
            """,
              bind: { Self.bindStatic($0, 1, group); sqlite3_bind_int($0, 2, Int32(limit)) }) { stmt in
            out.append(text(stmt, 0))
        }
        return out
    }

    /// Terms with a non-empty meaning, for gloss injection into Clovis context.
    public func termGlosses(group: String) -> [(term: String, gloss: String)] {
        let unlock = acquireLock(); defer { unlock() }
        var out: [(String, String)] = []
        query("SELECT canonical, gloss FROM terms WHERE (\"group\" = ? OR \"group\" = '') AND gloss != ''",
              bind: { Self.bindStatic($0, 1, group) }) { stmt in
            out.append((text(stmt, 0), text(stmt, 1)))
        }
        return out
    }

    /// Distinct non-empty groups (workspaces) with call counts, most-populated first.
    public func groups() -> [(name: String, count: Int)] {
        let unlock = acquireLock(); defer { unlock() }
        var counts: [String: Int] = [:]
        query("SELECT \"group\", COUNT(*) FROM transcripts WHERE kind = 'call' GROUP BY \"group\"") { stmt in
            let g = text(stmt, 0)
            if !g.isEmpty { counts[g] = Int(sqlite3_column_int(stmt, 1)) }
        }
        return counts.map { (name: $0.key, count: $0.value) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// Call count in one workspace ("" = ungrouped) — for the scope indicator.
    public func count(group: String) -> Int {
        let unlock = acquireLock(); defer { unlock() }
        var n = 0
        query("SELECT COUNT(*) FROM transcripts WHERE \"group\" = ? AND kind = 'call'",
              bind: { Self.bindStatic($0, 1, group) }) { n = Int(sqlite3_column_int($0, 0)) }
        return n
    }

    /// All participants across transcripts with a call count, most-frequent first.
    public func people() -> [(name: String, count: Int)] {
        aggregateList(column: "participants")
    }

    /// All tags across transcripts (excluding the owner marker) with a count, most-frequent first.
    public func tags() -> [(name: String, count: Int)] {
        aggregateList(column: "tags").filter { $0.name != OwnerMarker.value }
    }

    /// Splits a newline-joined column across all transcripts into per-value counts, folded
    /// case-insensitively so "Planning" and "planning" are one entry (displayed with the most
    /// frequent spelling) instead of two sidebar rows with split counts.
    private func aggregateList(column: String) -> [(name: String, count: Int)] {
        let unlock = acquireLock(); defer { unlock() }
        var spellings: [String: [String: Int]] = [:]   // lowercased key -> [original spelling: count]
        query("SELECT \(column) FROM transcripts WHERE kind = 'call'") { stmt in
            for value in text(stmt, 0).split(separator: "\n") {
                let v = value.trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { spellings[v.lowercased(), default: [:]][v, default: 0] += 1 }
            }
        }
        return spellings.values.map { forms -> (name: String, count: Int) in
            let display = forms.max { $0.value < $1.value }?.key ?? ""
            return (display, forms.values.reduce(0, +))
        }
        .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    // MARK: - SQLite helpers

    @discardableResult
    private func exec(_ sql: String) -> Bool {
        var err: UnsafeMutablePointer<CChar>?
        if sqlite3_exec(db, sql, nil, nil, &err) == SQLITE_OK { return true }
        let message = err.map { String(cString: $0) } ?? String(cString: sqlite3_errmsg(db))
        log.error("exec failed (\(message, privacy: .public)): \(sql.prefix(80), privacy: .public)")
        if let err { sqlite3_free(err) }
        return false
    }

    @discardableResult
    private func run(_ sql: String, bind: (OpaquePointer?) -> Void) -> Bool {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("prepare failed (\(String(cString: sqlite3_errmsg(self.db)), privacy: .public)): \(sql.prefix(80), privacy: .public)")
            return false
        }
        bind(stmt)
        let rc = sqlite3_step(stmt)
        sqlite3_finalize(stmt)
        guard rc == SQLITE_DONE || rc == SQLITE_ROW else {
            log.error("step failed (\(String(cString: sqlite3_errmsg(self.db)), privacy: .public)): \(sql.prefix(80), privacy: .public)")
            return false
        }
        return true
    }

    private func query(_ sql: String, bind: ((OpaquePointer?) -> Void)? = nil, row: (OpaquePointer?) -> Void) {
        var stmt: OpaquePointer?
        guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else {
            log.error("prepare failed (\(String(cString: sqlite3_errmsg(self.db)), privacy: .public)): \(sql.prefix(80), privacy: .public)")
            return
        }
        bind?(stmt)
        while sqlite3_step(stmt) == SQLITE_ROW { row(stmt) }
        sqlite3_finalize(stmt)
    }

    private func bind(_ stmt: OpaquePointer?, _ i: Int32, _ value: String) { Self.bindStatic(stmt, i, value) }
    private static func bindStatic(_ stmt: OpaquePointer?, _ i: Int32, _ value: String) {
        sqlite3_bind_text(stmt, i, value, -1, TRANSIENT)
    }
    private func text(_ stmt: OpaquePointer?, _ i: Int32) -> String {
        guard let c = sqlite3_column_text(stmt, i) else { return "" }
        return String(cString: c)
    }
}
