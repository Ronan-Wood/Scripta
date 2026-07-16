import Foundation
import SQLite3
import OSLog

/// Transcript-level metadata as stored in the index.
struct IndexedTranscript {
    let path: String
    let title: String
    let date: String
    let time: String
    let duration: String
    let participants: [String]
    let tags: [String]
    let summary: String
    let mtime: Double
}

/// One retrievable chunk of a transcript (a speaker turn).
struct IndexedChunk {
    let startMs: Int
    let endMs: Int
    let speaker: String?
    let text: String
}

/// A full passage retrieved for on-device answering.
struct ContextChunk {
    let path: String
    let title: String
    let date: String
    let startMs: Int
    let speaker: String
    let text: String
    /// True for a synthetic "call summary/topics" passage (topic fusion), not spoken content.
    var isTopic: Bool = false
}

/// A ranked search result pointing back into a transcript.
struct SearchHit: Identifiable {
    let id = UUID()
    let path: String
    let title: String
    let date: String
    let startMs: Int
    let speaker: String?
    let snippet: String
    let score: Double
}

/// The local retrieval backend: a SQLite database (system SQLite, FTS5) holding a derived index
/// over the transcript Markdown files. The `.md` files remain the source of truth — this DB is a
/// rebuildable cache, so it never risks the vault and can be nuked + reindexed at any time.
///
/// Reads are safe across processes (the app writes; the bundled MCP reads) via WAL mode.
/// Access within a process is serialized by an internal lock.
final class IndexStore {
    static let shared = try? IndexStore()

    /// Fixed location, independent of the (user-configurable) transcript output folder.
    static var defaultURL: URL {
        let base = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("CallTranscriber", isDirectory: true)
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        return base.appendingPathComponent("index.db")
    }

    /// How `search`/`context` build their MATCH expression. Production is `.andFirst`; the eval
    /// harness flips to `.legacyOr` to measure the before/after of the stopword + AND-first change.
    enum QueryMode { case andFirst, legacyOr }
    var queryMode: QueryMode = .andFirst

    private let db: OpaquePointer
    private let lock = NSLock()
    private let log = Logger(subsystem: "com.ronanwood.CallTranscriber", category: "Index")
    private static let TRANSIENT = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

    init(url: URL = IndexStore.defaultURL) throws {
        var handle: OpaquePointer?
        guard sqlite3_open(url.path, &handle) == SQLITE_OK, let handle else {
            throw NSError(domain: "CallTranscriber.Index", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "Could not open the index database."])
        }
        db = handle
        sqlite3_busy_timeout(db, 3000)
        exec("PRAGMA journal_mode=WAL;")
        exec("PRAGMA foreign_keys=ON;")
        createSchema()
    }

    deinit { sqlite3_close(db) }

    // MARK: - Schema

    private func createSchema() {
        exec("""
        CREATE TABLE IF NOT EXISTS transcripts(
            path TEXT PRIMARY KEY,
            title TEXT, date TEXT, time TEXT, duration TEXT,
            participants TEXT, tags TEXT, summary TEXT, mtime REAL
        );
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
        -- Reserved for Phase B: chunk_id -> embedding BLOB. Left empty until an on-device
        -- embedder passes a real quality gate; the retriever works without it.
        CREATE TABLE IF NOT EXISTS chunk_vectors(chunk_id INTEGER PRIMARY KEY, vector BLOB);
        """)
    }

    // MARK: - Writes

    /// Replaces a transcript's row + chunks wholesale (delete then insert), keeping FTS in sync
    /// via the triggers. Called on write and on any metadata edit.
    func upsert(_ t: IndexedTranscript, chunks: [IndexedChunk]) {
        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN;") else { return }
        var ok = removeRows(path: t.path)
        if ok {
            ok = run("INSERT INTO transcripts(path,title,date,time,duration,participants,tags,summary,mtime) VALUES(?,?,?,?,?,?,?,?,?)") { stmt in
                bind(stmt, 1, t.path); bind(stmt, 2, t.title); bind(stmt, 3, t.date)
                bind(stmt, 4, t.time); bind(stmt, 5, t.duration)
                bind(stmt, 6, t.participants.joined(separator: "\n"))
                bind(stmt, 7, t.tags.joined(separator: "\n"))
                bind(stmt, 8, t.summary); sqlite3_bind_double(stmt, 9, t.mtime)
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
    func remove(path: String) {
        lock.lock(); defer { lock.unlock() }
        guard exec("BEGIN;") else { return }
        if removeRows(path: path) && exec("COMMIT;") { return }
        exec("ROLLBACK;")
    }

    private func removeRows(path: String) -> Bool {
        var ok = run("DELETE FROM chunks WHERE path = ?") { bind($0, 1, path) }
        ok = run("DELETE FROM transcripts WHERE path = ?") { bind($0, 1, path) } && ok
        ok = run("DELETE FROM transcripts_fts WHERE path = ?") { bind($0, 1, path) } && ok
        return ok
    }

    /// path -> mtime for every indexed transcript, used to reconcile against the folder.
    func indexedPaths() -> [String: Double] {
        lock.lock(); defer { lock.unlock() }
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
    func search(_ rawQuery: String, participant: String? = nil, tag: String? = nil,
                since: String? = nil, speaker: String? = nil, limit: Int = 30) -> [SearchHit] {
        lock.lock(); defer { lock.unlock() }
        if queryMode == .legacyOr {
            return Array(fusedHits(FTSQuery.legacyOr(rawQuery), participant: participant, tag: tag,
                                   since: since, speaker: speaker, limit: limit).prefix(limit))
        }
        // AND is near-precise for multi-word queries; fall back to OR (the recall floor) only when
        // AND finds nothing across both passages and topics.
        var hits = fusedHits(FTSQuery.andExpression(rawQuery), participant: participant, tag: tag,
                             since: since, speaker: speaker, limit: limit)
        if hits.isEmpty {
            hits = fusedHits(FTSQuery.orExpression(rawQuery), participant: participant, tag: tag,
                             since: since, speaker: speaker, limit: limit)
        }
        return Array(hits.prefix(limit))
    }

    /// Passage hits + (unless a speaker filter is set) topic hits for one MATCH expression.
    private func fusedHits(_ match: String?, participant: String?, tag: String?,
                           since: String?, speaker: String?, limit: Int) -> [SearchHit] {
        guard let match else { return [] }
        var hits = passageHits(match, participant: participant, tag: tag, since: since, speaker: speaker, limit: limit)
        let seen = Set(hits.map(\.path))
        if speaker == nil || speaker?.isEmpty == true {
            for hit in topicHits(match, participant: participant, tag: tag, since: since, limit: limit)
            where !seen.contains(hit.path) {
                hits.append(hit)
            }
        }
        return hits
    }

    private func passageHits(_ match: String, participant: String?, tag: String?,
                             since: String?, speaker: String?, limit: Int) -> [SearchHit] {
        var sql = """
        SELECT c.path, t.title, t.date, c.start_ms, c.speaker,
               snippet(chunks_fts, 0, '⟦', '⟧', '…', 10) AS snip, bm25(chunks_fts) AS score
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
        if let participant, !participant.isEmpty { filter(" AND lower(t.participants) LIKE ?", "%\(participant.lowercased())%") }
        if let tag, !tag.isEmpty { filter(" AND lower(t.tags) LIKE ?", "%\(tag.lowercased())%") }
        if let since, !since.isEmpty { filter(" AND t.date >= ?", since) }
        if let speaker, !speaker.isEmpty { filter(" AND c.speaker = ?", speaker) }
        sql += " ORDER BY score LIMIT \(max(1, limit));"

        var hits: [SearchHit] = []
        query(sql, bind: { stmt in binds.forEach { $0(stmt) } }) { stmt in
            hits.append(SearchHit(
                path: text(stmt, 0), title: text(stmt, 1), date: text(stmt, 2),
                startMs: Int(sqlite3_column_int64(stmt, 3)),
                speaker: sqlite3_column_type(stmt, 4) == SQLITE_NULL ? nil : text(stmt, 4),
                snippet: text(stmt, 5), score: sqlite3_column_double(stmt, 6)))
        }
        return hits
    }

    private func topicHits(_ match: String, participant: String?, tag: String?,
                           since: String?, limit: Int) -> [SearchHit] {
        var sql = """
        SELECT f.path, f.title, t.date, f.summary,
               snippet(transcripts_fts, 2, '⟦', '⟧', '…', 10) AS tagsnip, bm25(transcripts_fts) AS score
        FROM transcripts_fts f
        JOIN transcripts t ON t.path = f.path
        WHERE transcripts_fts MATCH ?
        """
        var binds: [(OpaquePointer?) -> Void] = [{ Self.bindStatic($0, 1, match) }]
        var n: Int32 = 2
        func filter(_ clause: String, _ value: String) {
            sql += clause; let i = n; binds.append { Self.bindStatic($0, i, value) }; n += 1
        }
        if let participant, !participant.isEmpty { filter(" AND lower(t.participants) LIKE ?", "%\(participant.lowercased())%") }
        if let tag, !tag.isEmpty { filter(" AND lower(t.tags) LIKE ?", "%\(tag.lowercased())%") }
        if let since, !since.isEmpty { filter(" AND t.date >= ?", since) }
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
    func context(for rawQuery: String, limit: Int = 6) -> [ContextChunk] {
        lock.lock(); defer { lock.unlock() }
        var hits = rankedChunkIDs(FTSQuery.andExpression(rawQuery), limit: limit * 3)
        if hits.isEmpty { hits = rankedChunkIDs(FTSQuery.orExpression(rawQuery), limit: limit * 3) }

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
        for topic in topicContext(FTSQuery.andExpression(rawQuery) ?? FTSQuery.orExpression(rawQuery), limit: 2)
        where !seenPath.contains(topic.path) {
            out.append(topic)
        }
        return out
    }

    /// (chunk id, path) for spoken-passage hits, best-ranked first.
    private func rankedChunkIDs(_ match: String?, limit: Int) -> [(id: Int64, path: String)] {
        guard let match else { return [] }
        var out: [(Int64, String)] = []
        let sql = """
        SELECT c.id, c.path FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid
        WHERE chunks_fts MATCH ? ORDER BY bm25(chunks_fts) LIMIT \(max(1, limit));
        """
        query(sql, bind: { Self.bindStatic($0, 1, match) }) { stmt in
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
    private func topicContext(_ match: String?, limit: Int) -> [ContextChunk] {
        guard let match else { return [] }
        var out: [ContextChunk] = []
        let sql = """
        SELECT f.path, f.title, t.date, f.summary, f.tags
        FROM transcripts_fts f JOIN transcripts t ON t.path = f.path
        WHERE transcripts_fts MATCH ? ORDER BY bm25(transcripts_fts) LIMIT \(max(1, limit));
        """
        query(sql, bind: { Self.bindStatic($0, 1, match) }) { stmt in
            let title = text(stmt, 1), summary = text(stmt, 3), tags = text(stmt, 4)
            var parts = ["Call: \(title.isEmpty ? "Untitled" : title)"]
            if !summary.isEmpty { parts.append("Summary: \(summary)") }
            if !tags.isEmpty { parts.append("Topics: \(tags.replacingOccurrences(of: " ", with: ", "))") }
            out.append(ContextChunk(path: text(stmt, 0), title: title, date: text(stmt, 2),
                                    startMs: 0, speaker: "", text: parts.joined(separator: ". "), isTopic: true))
        }
        return out
    }

    /// All participants across transcripts with a call count, most-frequent first.
    func people() -> [(name: String, count: Int)] {
        aggregateList(column: "participants")
    }

    /// All tags across transcripts (excluding the owner marker) with a count, most-frequent first.
    func tags() -> [(name: String, count: Int)] {
        aggregateList(column: "tags").filter { $0.name != OwnerMarker.value }
    }

    /// Splits a newline-joined column across all transcripts into per-value counts.
    private func aggregateList(column: String) -> [(name: String, count: Int)] {
        lock.lock(); defer { lock.unlock() }
        var counts: [String: Int] = [:]
        query("SELECT \(column) FROM transcripts") { stmt in
            for value in text(stmt, 0).split(separator: "\n") {
                let v = value.trimmingCharacters(in: .whitespaces)
                if !v.isEmpty { counts[v, default: 0] += 1 }
            }
        }
        return counts.map { (name: $0.key, count: $0.value) }
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
