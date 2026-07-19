import Foundation
import ScriptaShared
import SQLite3

// A tiny, dependency-free MCP server (JSON-RPC 2.0 over newline-delimited stdio) that
// exposes the app's transcripts read-only to LLM clients (Claude Code / Desktop / Cowork).
// It initiates nothing — it only answers requests. Bundled inside the .app; spawned per client.

let ownerMarker = OwnerMarker.value
let serverName = "scripta"
let serverVersion = "1.0.0"

// MARK: - Output folder (published by the app in the shared state file)

/// The app→server handoff file in the App Group container. The sandboxed app's preferences
/// are invisible to this process, so the folder path travels here with the heartbeat.
func stateFileObject() -> [String: Any]? {
    guard let data = try? Data(contentsOf: SharedLocations.mcpState) else { return nil }
    return (try? JSONSerialization.jsonObject(with: data)) as? [String: Any]
}

func outputFolder() -> URL {
    if let path = stateFileObject()?["outputFolderPath"] as? String, !path.isEmpty {
        return URL(fileURLWithPath: path)
    }
    return FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("Scripta", isDirectory: true)
}

// MARK: - Transcript model + reading

struct Meta {
    let url: URL
    let title, date, time, duration: String
    let participants, tags: [String]
    let isConference: Bool
    let group: String
    var summary: String = ""   // populated from the index (empty when built by parseMeta from a file)
    var body: String = ""      // the verbatim transcript, stored in the index (empty from parseMeta)
}

// Frontmatter parsing (split, owner-marker check, scalar field, flow list) is shared with the app
// and the eval harness via Sources/Shared/Frontmatter.swift — see `enum Frontmatter` — so the
// "app-authored only" gate and field parsing can never drift between this server and the app.

func parseMeta(_ url: URL) -> Meta? {
    // Only app-authored files: the owner marker must sit on its own line inside the frontmatter.
    guard let content = try? String(contentsOf: url, encoding: .utf8),
          let split = Frontmatter.split(content),
          Frontmatter.hasOwnerMarker(split.frontmatter) else { return nil }
    let fm = split.frontmatter
    return Meta(
        url: url,
        title: Frontmatter.field(fm, "title"),
        date: Frontmatter.field(fm, "date"),
        time: Frontmatter.field(fm, "time"),
        duration: Frontmatter.field(fm, "duration"),
        participants: Frontmatter.list(fm, "participants"),
        tags: Frontmatter.list(fm, "tags").filter { $0 != ownerMarker },
        isConference: Frontmatter.field(fm, "mode") == "conference",
        group: Frontmatter.field(fm, "group")
    )
}

/// The active-workspace scope the server must honor, or a refusal. Reads the app's heartbeat file;
/// if the app isn't running (stale/absent beat), the server refuses rather than trust a stale
/// scope — the privacy wall can't be one process-death deep.
func activeGroupScope() -> (group: String, refusal: String?) {
    guard let obj = stateFileObject(),
          let beat = obj["heartbeat"] as? Double else {
        return ("", "Open Scripta and pick a workspace — the assistant won't query your calls without a live scope.")
    }
    if Date().timeIntervalSince1970 - beat > 60 {
        return ("", "Scripta isn't running. Open it (and choose the workspace you mean) before I query your calls — I won't answer against a stale scope.")
    }
    return ((obj["activeGroup"] as? String) ?? "", nil)
}

/// Calls, newest first. DB-first: the output folder may be a TCC-protected cloud vault (iCloud /
/// OneDrive / Dropbox) that this unsandboxed server can't scan, whereas the group-container index
/// is always readable across the sandbox boundary — and it holds only app-authored, group-scoped
/// rows, so it doubles as the authorship gate. Falls back to a folder scan only when the index
/// isn't built yet (openIndex → nil).
func allTranscripts() -> [Meta] {
    if let rows = dbCalls() { return rows }
    return folderTranscripts()
}

func folderTranscripts() -> [Meta] {
    let folder = outputFolder()
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ) else { return [] }
    return entries
        .filter { $0.pathExtension == "md" }
        .compactMap(parseMeta)
        .sorted { ($0.date, $0.time) > ($1.date, $1.time) }
}

func displayTitle(_ m: Meta) -> String {
    m.title.isEmpty ? [m.date, m.time].filter { !$0.isEmpty }.joined(separator: " ") : m.title
}

// MARK: - Retrieval index (read-only view of the app's SQLite index)

// The app owns writing this DB (built on launch + after each recording); the MCP only reads it.
// Path is fixed, independent of the transcript output folder.
let SQLITE_TRANSIENT_MCP = unsafeBitCast(-1, to: sqlite3_destructor_type.self)

func indexDBURL() -> URL { SharedLocations.indexDB }

func openIndex() -> OpaquePointer? {
    let path = indexDBURL().path
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    sqlite3_busy_timeout(db, 3000)
    return db
}

struct RetrieveHit {
    let title, date, path, speaker, snippet: String
    let startMs: Int
    let score: Double
    var isTopic = false
}

/// Whole-value match against a newline-joined column (tag "ai" must not match "training"), and the
/// column-weighted BM25 for the topic table — mirroring IndexStore so the MCP and app rank alike.
func delimitedClause(_ column: String) -> String { " AND (char(10)||lower(\(column))||char(10)) LIKE ? ESCAPE '\\'" }
func delimitedValue(_ value: String) -> String {
    // Escape LIKE metacharacters so a participant/tag containing % or _ matches exactly (audit L3).
    let escaped = value.lowercased()
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_")
    return "%\n\(escaped)\n%"
}
let topicBM25 = "bm25(transcripts_fts, 0.0, 4.0, 1.0, 3.0, 0.5)"

func retrieve(_ query: String, participant: String?, tag: String?, since: String?, speaker: String?, group: String, limit: Int) -> [RetrieveHit]? {
    guard let db = openIndex() else { return nil }
    defer { sqlite3_close(db) }
    let speakerSet = speaker?.isEmpty == false

    // Passage + (unless a speaker filter is set) topic fusion for one MATCH expression. Mirrors
    // IndexStore.search so the MCP and the app return the same results (shared FTSQuery).
    func fused(_ match: String) -> [RetrieveHit] {
        // Over-fetch passages (LIMIT ×4) so the per-call diversity cap below still leaves `limit`
        // results — mirrors IndexStore.passageHits so the MCP and app rank/diversify alike.
        var passageRows: [RetrieveHit] = []
        var sql = """
        SELECT t.title, t.date, c.path, c.start_ms, IFNULL(c.speaker,''),
               snippet(chunks_fts, 0, '⟦', '⟧', '…', 14), bm25(chunks_fts)
        FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid JOIN transcripts t ON t.path = c.path
        WHERE chunks_fts MATCH ?
        """
        if participant?.isEmpty == false { sql += " " + delimitedClause("t.participants") }
        if tag?.isEmpty == false { sql += " " + delimitedClause("t.tags") }
        if since?.isEmpty == false { sql += " AND t.date >= ?" }
        if speakerSet { sql += " AND c.speaker = ?" }
        sql += " AND t.\"group\" = ?"   // the privacy wall (always applied)
        sql += " ORDER BY bm25(chunks_fts) LIMIT \(max(1, limit) * 4);"

        var stmt: OpaquePointer?
        if sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK {
            var i: Int32 = 1
            func bind(_ s: String) { sqlite3_bind_text(stmt, i, s, -1, SQLITE_TRANSIENT_MCP); i += 1 }
            bind(match)
            if let p = participant, !p.isEmpty { bind(delimitedValue(p)) }
            if let t = tag, !t.isEmpty { bind(delimitedValue(t)) }
            if let s = since, !s.isEmpty { bind(s) }
            if let sp = speaker, speakerSet { bind(sp) }
            bind(group)
            func col(_ n: Int32) -> String { sqlite3_column_text(stmt, n).map { String(cString: $0) } ?? "" }
            while sqlite3_step(stmt) == SQLITE_ROW {
                passageRows.append(RetrieveHit(title: col(0), date: col(1), path: col(2), speaker: col(4),
                                               snippet: col(5), startMs: Int(sqlite3_column_int64(stmt, 3)),
                                               score: sqlite3_column_double(stmt, 6)))
            }
        }
        sqlite3_finalize(stmt); stmt = nil

        // Per-call diversity: keep each call's 2 best chunks so one long call can't monopolise.
        var perPath: [String: Int] = [:]
        var passages: [RetrieveHit] = []
        for h in passageRows {
            let n = perPath[h.path, default: 0]
            if n >= 2 { continue }
            perPath[h.path] = n + 1
            passages.append(h)
            if passages.count >= limit { break }
        }

        // Topic rows carry no speaker, so a speaker filter excludes them (mirrors the app).
        guard !speakerSet else { return Array(passages.prefix(max(1, limit))) }

        // Topic-level fusion: calls (and the user's notes/documents) matched by name/summary/
        // concept-tag with no spoken-word hit.
        let passagePaths = Set(passages.map(\.path))
        var topics: [RetrieveHit] = []
        var tsql = """
        SELECT f.title, t.date, f.path, f.summary, t.kind
        FROM transcripts_fts f JOIN transcripts t ON t.path = f.path
        WHERE transcripts_fts MATCH ?
        """
        if participant?.isEmpty == false { tsql += " " + delimitedClause("t.participants") }
        if tag?.isEmpty == false { tsql += " " + delimitedClause("t.tags") }
        if since?.isEmpty == false { tsql += " AND t.date >= ?" }
        tsql += " AND t.\"group\" = ?"   // the privacy wall
        tsql += " ORDER BY \(topicBM25) LIMIT \(max(1, limit));"
        if sqlite3_prepare_v2(db, tsql, -1, &stmt, nil) == SQLITE_OK {
            var j: Int32 = 1
            func tbind(_ s: String) { sqlite3_bind_text(stmt, j, s, -1, SQLITE_TRANSIENT_MCP); j += 1 }
            tbind(match)
            if let p = participant, !p.isEmpty { tbind(delimitedValue(p)) }
            if let t = tag, !t.isEmpty { tbind(delimitedValue(t)) }
            if let s = since, !s.isEmpty { tbind(s) }
            tbind(group)
            func tcol(_ n: Int32) -> String { sqlite3_column_text(stmt, n).map { String(cString: $0) } ?? "" }
            while sqlite3_step(stmt) == SQLITE_ROW {
                let path = tcol(2)
                if passagePaths.contains(path) { continue }
                let summary = tcol(3)
                let kind = tcol(4)
                // Notes/documents get a longer window: their "summary" IS the content, not a teaser.
                var snippet = summary.isEmpty ? "matched on topic" : String(summary.prefix(kind == "call" ? 160 : 400))
                // The user's own notes and files retrieve alongside calls — labeled as theirs.
                if kind == "note" { snippet = "the user's note — " + snippet }
                if kind == "doc" { snippet = "the user's document — " + snippet }
                topics.append(RetrieveHit(title: tcol(0), date: tcol(1), path: path, speaker: "",
                                          snippet: snippet, startMs: 0, score: 0, isTopic: true))
            }
            sqlite3_finalize(stmt); stmt = nil
        }

        guard !topics.isEmpty else { return passages }

        // Reserve up to 3 slots for topic matches so a concept-tag hit isn't starved when passages
        // fill the limit (mirrors IndexStore.fusedHits), then backfill any remaining budget with the
        // passages held back by the reservation.
        let reserve = min(3, topics.count)
        var out = Array(passages.prefix(max(0, limit - reserve)))
        var seenPaths = Set(out.map(\.path))
        for topic in topics where !seenPaths.contains(topic.path) {
            out.append(topic); seenPaths.insert(topic.path)
            if out.count >= limit { break }
        }
        if out.count < limit {
            var seenKeys = Set(out.map { "\($0.path)|\($0.startMs)" })
            for p in passages where out.count < limit {
                if seenKeys.insert("\(p.path)|\(p.startMs)").inserted { out.append(p) }
            }
        }
        return out
    }

    // AND-first (precise), OR fallback (recall floor) — same two-pass as the app, with the same
    // vocabulary alias expansion (terms cache in the DB; the registry file isn't visible here).
    let aliases = aliasGroups(db: db, group: group)
    guard let andMatch = FTSQuery.andExpression(query, aliasGroups: aliases) else { return [] }
    let hits = fused(andMatch)
    if !hits.isEmpty { return hits }
    guard let orMatch = FTSQuery.orExpression(query, aliasGroups: aliases) else { return [] }
    return fused(orMatch)
}

/// Vocabulary alias groups from the index's terms cache — workspace-scoped plus globals.
/// Returns [] when the table doesn't exist yet (index from a pre-v9 app build).
func aliasGroups(db: OpaquePointer, group: String) -> [[String]] {
    var out: [[String]] = []
    var stmt: OpaquePointer?
    let sql = "SELECT canonical, aliases FROM terms WHERE \"group\" = ? OR \"group\" = ''"
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, group, -1, SQLITE_TRANSIENT_MCP)
    while sqlite3_step(stmt) == SQLITE_ROW {
        let canonical = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        let aliases = sqlite3_column_text(stmt, 1).map { String(cString: $0) } ?? ""
        var members = [canonical.lowercased()]
        for alias in aliases.split(separator: "\n").map(String.init) where !members.contains(alias) {
            members.append(alias)
        }
        if members.count > 1 { out.append(members) }
    }
    return out
}

/// Spoken lines of one transcript within [start, end] ms (from the chunk index — Screen Context is
/// naturally excluded since chunks are built only from audio lines). nil for an unknown/guarded
/// path or an empty window.
func getSection(path: String, start: Int, end: Int) -> String? {
    // dbMeta confirms the path is an indexed (app-authored, in-folder) transcript; the chunk query
    // then binds the path AS PROVIDED (it came from retrieve/list = the index's stored key), not a
    // symlink-resolved path, which wouldn't match when the output folder sits under a symlink (audit L5).
    guard dbMeta(path: path) != nil, let db = openIndex() else { return nil }
    defer { sqlite3_close(db) }
    let sql = "SELECT start_ms, IFNULL(speaker,''), text FROM chunks WHERE path = ? AND start_ms >= ? AND start_ms <= ? ORDER BY start_ms;"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT_MCP)
    sqlite3_bind_int64(stmt, 2, Int64(start))
    sqlite3_bind_int64(stmt, 3, Int64(end))
    func col(_ n: Int32) -> String { sqlite3_column_text(stmt, n).map { String(cString: $0) } ?? "" }
    var lines: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let ms = Int(sqlite3_column_int64(stmt, 0))
        let who = col(1).isEmpty ? "" : " \(col(1)):"
        lines.append("[\(clockStamp(ms))]\(who) \(col(2))")
    }
    return lines.isEmpty ? nil : lines.joined(separator: "\n")
}

/// Per-value counts from a newline-joined column (participants or tags), most-frequent first.
func indexAggregate(column: String, group: String) -> [(name: String, count: Int)]? {
    guard let db = openIndex() else { return nil }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT \(column) FROM transcripts WHERE \"group\" = ?", -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, group, -1, SQLITE_TRANSIENT_MCP)
    var spellings: [String: [String: Int]] = [:]   // lowercased key -> [original spelling: count]
    while sqlite3_step(stmt) == SQLITE_ROW {
        let value = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        for v in value.split(separator: "\n") {
            let name = v.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && name != ownerMarker { spellings[name.lowercased(), default: [:]][name, default: 0] += 1 }
        }
    }
    // Fold case-insensitively; display the most frequent original spelling.
    return spellings.values.map { forms -> (name: String, count: Int) in
        (forms.max { $0.value < $1.value }?.key ?? "", forms.values.reduce(0, +))
    }
    .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
}

func clockStamp(_ ms: Int) -> String {
    let total = ms / 1000, h = total / 3600, m = (total % 3600) / 60, s = total % 60
    return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
}

// MARK: - DB-backed transcript reads (never touch the output folder)

/// The columns `metaFromRow` expects, in order — shared by the list and single-row lookups.
private let metaColumns = #"path, title, date, time, duration, participants, tags, summary, mode, "group", body"#

/// Builds a Meta from a `transcripts` row selected via `metaColumns`. participants/tags are stored
/// newline-joined (mirrors `indexAggregate`), with the owner marker filtered back out.
func metaFromRow(_ stmt: OpaquePointer?) -> Meta {
    func col(_ n: Int32) -> String { sqlite3_column_text(stmt, n).map { String(cString: $0) } ?? "" }
    func list(_ n: Int32) -> [String] {
        col(n).split(separator: "\n").map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty && $0 != ownerMarker }
    }
    return Meta(url: URL(fileURLWithPath: col(0)), title: col(1), date: col(2), time: col(3),
                duration: col(4), participants: list(5), tags: list(6),
                isConference: col(8) == "conference", group: col(9), summary: col(7), body: col(10))
}

/// Every indexed call (kind='call'), newest first — or nil when the index isn't built yet.
func dbCalls() -> [Meta]? {
    guard let db = openIndex() else { return nil }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT \(metaColumns) FROM transcripts WHERE IFNULL(kind,'call') = 'call';", -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    var out: [Meta] = []
    while sqlite3_step(stmt) == SQLITE_ROW { out.append(metaFromRow(stmt)) }
    return out.sorted { ($0.date, $0.time) > ($1.date, $1.time) }
}

/// One indexed transcript by its stored path, or nil. Membership in the index IS the authorship +
/// containment gate (the app only ever indexes files it authored inside the output folder), so this
/// replaces the old file-reading `safeTranscript` guard.
func dbMeta(path: String) -> Meta? {
    guard let db = openIndex() else { return nil }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT \(metaColumns) FROM transcripts WHERE path = ? LIMIT 1;", -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, path, -1, SQLITE_TRANSIENT_MCP)
    return sqlite3_step(stmt) == SQLITE_ROW ? metaFromRow(stmt) : nil
}

/// Reassembles a readable transcript from the indexed chunks — spoken (You/Them) and screen-context
/// ("Screen") rows interleaved by timestamp — plus the stored summary. The .md may live in a cloud
/// vault this server can't open, so the index is the source. Coarser than the file (chunk-level
/// timestamps), but preserves speaker, timing, screen context, and summary.
func reconstructTranscript(_ meta: Meta) -> String? {
    guard let db = openIndex() else { return nil }
    defer { sqlite3_close(db) }
    var out = "# \(displayTitle(meta))\n"
    let head = [[meta.date, meta.time].joined(separator: " "), meta.duration]
        .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: " · ")
    if !head.isEmpty { out += "\(head)\(meta.isConference ? " · conference (unlabeled)" : "")\n" }
    if !meta.participants.isEmpty { out += "Participants: \(meta.participants.joined(separator: ", "))\n" }
    if !meta.tags.isEmpty { out += "Tags: \(meta.tags.joined(separator: ", "))\n" }
    if !meta.summary.isEmpty { out += "\n## Summary\n\(meta.summary)\n" }

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT start_ms, IFNULL(speaker,''), text FROM chunks WHERE path = ? ORDER BY start_ms;", -1, &stmt, nil) == SQLITE_OK else { return out }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, meta.url.path, -1, SQLITE_TRANSIENT_MCP)
    func col(_ n: Int32) -> String { sqlite3_column_text(stmt, n).map { String(cString: $0) } ?? "" }
    var body: [String] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        let who = col(1).isEmpty ? "" : " \(col(1)):"
        body.append("[\(clockStamp(Int(sqlite3_column_int64(stmt, 0))))]\(who) \(col(2))")
    }
    if !body.isEmpty { out += "\n## Transcript\n" + body.joined(separator: "\n") + "\n" }
    return out
}

/// Exact-substring search over the index (chunk text + title/participants), group-scoped — the
/// DB-backed replacement for the old file-scanning search. One hit per call, spoken and screen
/// context distinguished, mirroring the previous output shape.
func dbSearch(_ query: String, group: String, limit: Int = 15) -> [String] {
    guard let db = openIndex() else { return [] }
    defer { sqlite3_close(db) }
    let like = "%" + query.lowercased()
        .replacingOccurrences(of: "\\", with: "\\\\")
        .replacingOccurrences(of: "%", with: "\\%")
        .replacingOccurrences(of: "_", with: "\\_") + "%"
    func col(_ s: OpaquePointer?, _ n: Int32) -> String { sqlite3_column_text(s, n).map { String(cString: $0) } ?? "" }
    var hits: [String] = []
    var seen = Set<String>()

    // Body / screen-context matches (keep only the first, earliest hit per call).
    var stmt: OpaquePointer?
    let bodySQL = "SELECT t.title, t.date, c.text, IFNULL(c.speaker,''), c.path FROM chunks c JOIN transcripts t ON t.path = c.path WHERE t.\"group\" = ? AND lower(c.text) LIKE ? ESCAPE '\\' ORDER BY c.start_ms;"
    if sqlite3_prepare_v2(db, bodySQL, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_bind_text(stmt, 1, group, -1, SQLITE_TRANSIENT_MCP)
        sqlite3_bind_text(stmt, 2, like, -1, SQLITE_TRANSIENT_MCP)
        while hits.count < limit, sqlite3_step(stmt) == SQLITE_ROW {
            let path = col(stmt, 4)
            guard seen.insert(path).inserted else { continue }
            let title = col(stmt, 0).isEmpty ? col(stmt, 1) : col(stmt, 0)
            let section = col(stmt, 3) == "Screen" ? "screen" : "transcript"
            hits.append("• \(title) [\(section)] — …\(snippetAround(col(stmt, 2), needle: query))…\n  path: \(path)")
        }
    }
    sqlite3_finalize(stmt); stmt = nil

    // Title / participant matches for calls not already surfaced by a body hit.
    let metaSQL = "SELECT title, date, participants, summary, path FROM transcripts WHERE \"group\" = ? AND IFNULL(kind,'call')='call' AND (lower(title) LIKE ? ESCAPE '\\' OR lower(participants) LIKE ? ESCAPE '\\');"
    if sqlite3_prepare_v2(db, metaSQL, -1, &stmt, nil) == SQLITE_OK {
        sqlite3_bind_text(stmt, 1, group, -1, SQLITE_TRANSIENT_MCP)
        sqlite3_bind_text(stmt, 2, like, -1, SQLITE_TRANSIENT_MCP)
        sqlite3_bind_text(stmt, 3, like, -1, SQLITE_TRANSIENT_MCP)
        while hits.count < limit, sqlite3_step(stmt) == SQLITE_ROW {
            let path = col(stmt, 4)
            guard seen.insert(path).inserted else { continue }
            let title = col(stmt, 0).isEmpty ? col(stmt, 1) : col(stmt, 0)
            let where_ = col(stmt, 0).lowercased().contains(query.lowercased()) ? "title" : "participant"
            let summary = col(stmt, 3)
            hits.append("• \(title) [\(where_)] — \(summary.isEmpty ? "(metadata match)" : summary)\n  path: \(path)")
        }
    }
    sqlite3_finalize(stmt)
    return hits
}

/// A ±70-char window around the first case-insensitive match, for search snippets.
func snippetAround(_ text: String, needle: String) -> String {
    let flat = text.replacingOccurrences(of: "\n", with: " ")
    guard let r = flat.range(of: needle, options: .caseInsensitive) else { return String(flat.prefix(140)).trimmingCharacters(in: .whitespaces) }
    let start = flat.index(r.lowerBound, offsetBy: -70, limitedBy: flat.startIndex) ?? flat.startIndex
    let end = flat.index(r.upperBound, offsetBy: 70, limitedBy: flat.endIndex) ?? flat.endIndex
    return flat[start..<end].trimmingCharacters(in: .whitespaces)
}

// MARK: - Tools

func toolDefinitions() -> [[String: Any]] {
    [
        [
            "name": "overview",
            "description": "Scannable overview of recent call transcripts (newest first) — each one's title, date, participants, and summary, plus its file path. Returns a bounded page and tells you the total. Use this FIRST to figure out which call(s) are relevant, then get_transcript for the full text. For older calls, pass `since` or raise `limit`, or use list_transcripts filters.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "Max transcripts to return (default 40, newest first)."],
                    "since": ["type": "string", "description": "Only include transcripts on or after this date (YYYY-MM-DD)."],
                    "compact": ["type": "boolean", "description": "Omit summaries — just title/date/participants per call."]
                ]
            ]
        ],
        [
            "name": "list_transcripts",
            "description": "List call transcripts (newest first) with their title, date, duration, participants, tags, and file path.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "limit": ["type": "integer", "description": "Max number to return (default 20)."],
                    "since": ["type": "string", "description": "Only include transcripts on or after this date (YYYY-MM-DD)."],
                    "participant": ["type": "string", "description": "Only include transcripts naming this participant."],
                    "tag": ["type": "string", "description": "Only include transcripts with this tag."]
                ]
            ]
        ],
        [
            "name": "get_transcript",
            "description": "Return the full Markdown of one transcript by its file path (from list_transcripts). Very long transcripts are truncated at ~24k characters with a pointer to `retrieve`/`get_section` for the rest — prefer those to reading a whole call unless you genuinely need it verbatim.",
            "inputSchema": [
                "type": "object",
                "properties": ["path": ["type": "string", "description": "The transcript's file path."]],
                "required": ["path"]
            ]
        ],
        [
            "name": "search_transcripts",
            "description": "Full-text search across all transcripts; returns matches with surrounding context and the file path.",
            "inputSchema": [
                "type": "object",
                "properties": ["query": ["type": "string", "description": "Text to search for."]],
                "required": ["query"]
            ]
        ],
        [
            "name": "retrieve",
            "description": "Semantic-style retrieval over the indexed call chunks: keyword-ranked (BM25) passages with their call, date, timestamp, and speaker, optionally filtered by participant/tag/date/speaker. Calls that match only by topic/title are shown as 'topic match' with no timestamp. Prefer this over search_transcripts, then use get_section to read around a hit.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to look for (natural words; any term may match)."],
                    "participant": ["type": "string", "description": "Only calls naming this participant."],
                    "tag": ["type": "string", "description": "Only calls with this tag."],
                    "since": ["type": "string", "description": "Only calls on or after this date (YYYY-MM-DD)."],
                    "speaker": ["type": "string", "description": "Only passages spoken by this side: 'You' or 'Them'. Excludes unlabeled (single-sided/in-person) calls and topic matches."],
                    "limit": ["type": "integer", "description": "Max passages to return (default 15)."]
                ],
                "required": ["query"]
            ]
        ],
        [
            "name": "get_section",
            "description": "Read the spoken lines of one transcript within a time window — e.g. the two minutes around a retrieve hit — instead of pulling the whole file. Screen Context is excluded. Times are milliseconds from the call start; the window is padded ~30s before `start` and `end` defaults to start + 2 min.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "path": ["type": "string", "description": "The transcript's file path (from retrieve/list)."],
                    "start": ["type": "integer", "description": "Start time in milliseconds from the call start."],
                    "end": ["type": "integer", "description": "End time in milliseconds (default start + 120000)."]
                ],
                "required": ["path", "start"]
            ]
        ],
        [
            "name": "people",
            "description": "Index of everyone named across all calls, with how many calls each appears in (most frequent first). Use to see who the user meets with.",
            "inputSchema": ["type": "object"]
        ],
        [
            "name": "tags",
            "description": "Index of all topic tags across calls, with a count per tag (most frequent first). Use to see recurring themes.",
            "inputSchema": ["type": "object"]
        ]
    ]
}

func textResult(_ text: String, isError: Bool = false) -> [String: Any] {
    ["content": [["type": "text", "text": text]], "isError": isError]
}

// A whole transcript can run to tens of thousands of tokens; dumping all of it on every get_transcript
// is a latency/token liability as calls (and the corpus) grow. Cap the text, and when we cut, steer the
// model to the bounded, retrieve-first tools for the rest. At or below the cap the text is byte-exact.
let transcriptCharCap = 24_000

func cappedTranscript(_ text: String, path: String) -> String {
    if text.count <= transcriptCharCap { return text }
    // Snap the cut back to the last line break inside the cap so we never emit half a speaker turn.
    var head = String(text.prefix(transcriptCharCap))
    if let lastBreak = head.lastIndex(of: "\n") { head = String(head[..<lastBreak]) }
    return head + "\n\n— Truncated: this transcript is \(text.count) characters and only the first ~\(transcriptCharCap) are shown. To read the rest without pulling the whole call, use `retrieve` for keyword-ranked passages, or `get_section` with a start time (ms from call start) to read a specific stretch.\n  path: \(path)"
}

func handleToolCall(_ name: String, _ args: [String: Any]) -> [String: Any] {
    // Every tool is hard-scoped to the app's active workspace; refuse entirely on a stale scope.
    let scope = activeGroupScope()
    if let refusal = scope.refusal { return textResult(refusal, isError: true) }
    let group = scope.group

    switch name {
    case "overview":
        var items = allTranscripts().filter { $0.group == group }
        if let since = args["since"] as? String, !since.isEmpty { items = items.filter { $0.date >= since } }
        let total = items.count
        let overviewLimit = max(1, (args["limit"] as? Int) ?? 40)
        let compact = (args["compact"] as? Bool) ?? false
        let shown = Array(items.prefix(overviewLimit))
        if shown.isEmpty { return textResult("No transcripts yet.") }
        let blocks = shown.map { m -> String in
            let meta = [[m.date, m.time].joined(separator: " "), m.duration]
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: ", ")
            var block = "### \(displayTitle(m))\(m.isConference ? " · conference (unlabeled)" : "")"
            if !meta.isEmpty { block += "  (\(meta))" }
            if !m.participants.isEmpty { block += "\nParticipants: \(m.participants.joined(separator: ", "))" }
            if !compact {
                block += "\n\(m.summary.isEmpty ? "(no summary)" : m.summary)"
            }
            block += "\npath: \(m.url.path)"
            return block
        }
        var out = blocks.joined(separator: "\n\n")
        if total > shown.count {
            out += "\n\n— Showing \(shown.count) of \(total) calls (newest first). Pass `since` or a larger `limit`, or use list_transcripts filters, to see the rest."
        }
        return textResult(out)

    case "list_transcripts":
        var items = allTranscripts().filter { $0.group == group }
        if let participant = (args["participant"] as? String)?.lowercased(), !participant.isEmpty {
            items = items.filter { $0.participants.contains { $0.lowercased().contains(participant) } }
        }
        if let tag = (args["tag"] as? String)?.lowercased(), !tag.isEmpty {
            items = items.filter { $0.tags.contains { $0.lowercased() == tag } }   // whole tag, not substring
        }
        if let since = args["since"] as? String, !since.isEmpty {
            items = items.filter { $0.date >= since }
        }
        let limit = (args["limit"] as? Int) ?? 20
        items = Array(items.prefix(max(1, limit)))
        if items.isEmpty { return textResult("No transcripts found.") }
        let lines = items.map { m -> String in
            var parts = ["• \(displayTitle(m))"]
            if m.isConference { parts.append("[conference]") }
            let meta = [[m.date, m.time].joined(separator: " "), m.duration].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !meta.isEmpty { parts.append("(\(meta.joined(separator: ", ")))") }
            if !m.participants.isEmpty { parts.append("— \(m.participants.joined(separator: ", "))") }
            var line = parts.joined(separator: " ")
            if !m.tags.isEmpty { line += "\n  tags: \(m.tags.joined(separator: ", "))" }
            return line + "\n  path: \(m.url.path)"
        }
        return textResult(lines.joined(separator: "\n"))

    case "get_section":
        guard let path = args["path"] as? String, let start = args["start"] as? Int else {
            return textResult("Provide `path` and `start` (milliseconds).", isError: true)
        }
        // Refuse a path outside the active workspace (the wall applies to direct reads too).
        guard let meta = dbMeta(path: path), meta.group == group else {
            return textResult("That call isn't in the active workspace.", isError: true)
        }
        let end = (args["end"] as? Int) ?? (start + 120_000)
        guard let section = getSection(path: path, start: max(0, start - 30_000), end: end) else {
            return textResult("No section found there (empty window).", isError: true)
        }
        return textResult(section)

    case "get_transcript":
        guard let path = args["path"] as? String, let meta = dbMeta(path: path) else {
            return textResult("No transcript found at that path (or it isn't an app transcript).", isError: true)
        }
        guard meta.group == group else {
            return textResult("That call isn't in the active workspace.", isError: true)
        }
        // The verbatim body stored in the index — byte-exact, never the .md (which may be in a cloud
        // vault this server can't read). Chunk reconstruction is the fallback for rows indexed before
        // the body column existed (superseded on the next reconcile), then the raw file as a last resort.
        let full = meta.body.isEmpty
            ? (reconstructTranscript(meta) ?? (try? String(contentsOf: meta.url, encoding: .utf8)) ?? "")
            : meta.body
        return textResult(cappedTranscript(full, path: path))

    case "search_transcripts":
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return textResult("Provide a non-empty query.", isError: true)
        }
        let hits = dbSearch(query, group: group)
        return textResult(hits.isEmpty ? "No matches for \"\(query)\"." : hits.joined(separator: "\n\n"))

    case "retrieve":
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return textResult("Provide a non-empty query.", isError: true)
        }
        // Clamp both ends: a client can send any Int, and fused() over-fetches limit*4, which would
        // trap on overflow for a huge value. 200 is far above any useful retrieval page.
        let limit = min(200, max(1, (args["limit"] as? Int) ?? 15))
        guard let hits = retrieve(query, participant: args["participant"] as? String,
                                  tag: args["tag"] as? String, since: args["since"] as? String,
                                  speaker: args["speaker"] as? String, group: group, limit: limit) else {
            return textResult("The retrieval index isn't built yet. Open Scripta once to build it.", isError: true)
        }
        if hits.isEmpty { return textResult("No relevant passages for \"\(query)\".") }
        let blocks = hits.map { h -> String in
            let title = h.title.isEmpty ? "Untitled" : h.title
            let date = h.date.isEmpty ? "" : " (\(h.date))"
            let snippet = h.snippet.replacingOccurrences(of: "⟦", with: "**").replacingOccurrences(of: "⟧", with: "**")
            if h.isTopic {
                return "• \(title)\(date) — topic match: \(snippet)\n  path: \(h.path)"
            }
            let who = h.speaker.isEmpty ? "" : " \(h.speaker):"
            return "• \(title)\(date) — [\(clockStamp(h.startMs))]\(who) …\(snippet)…\n  path: \(h.path)"
        }
        return textResult(blocks.joined(separator: "\n\n"))

    case "people":
        guard let entries = indexAggregate(column: "participants", group: group) else {
            return textResult("The retrieval index isn't built yet. Open Scripta once to build it.", isError: true)
        }
        if entries.isEmpty { return textResult("No participants named yet. Name calls in the app to populate this.") }
        return textResult(entries.map { "• \($0.name) — \($0.count) call\($0.count == 1 ? "" : "s")" }.joined(separator: "\n"))

    case "tags":
        guard let entries = indexAggregate(column: "tags", group: group) else {
            return textResult("The retrieval index isn't built yet. Open Scripta once to build it.", isError: true)
        }
        if entries.isEmpty { return textResult("No topic tags yet.") }
        return textResult(entries.map { "• \($0.name) — \($0.count) call\($0.count == 1 ? "" : "s")" }.joined(separator: "\n"))

    default:
        return textResult("Unknown tool: \(name)", isError: true)
    }
}

// MARK: - JSON-RPC stdio loop

func send(_ message: [String: Any]) {
    guard let data = try? JSONSerialization.data(withJSONObject: message),
          var string = String(data: data, encoding: .utf8) else { return }
    string += "\n"
    FileHandle.standardOutput.write(Data(string.utf8))
}

func respond(id: Any?, result: [String: Any]) {
    guard let id else { return }   // notifications have no id and get no response
    send(["jsonrpc": "2.0", "id": id, "result": result])
}

func respondError(id: Any?, code: Int, message: String) {
    guard let id else { return }
    send(["jsonrpc": "2.0", "id": id, "error": ["code": code, "message": message]])
}

while let line = readLine(strippingNewline: true) {
    if line.isEmpty { continue }
    guard let data = line.data(using: .utf8),
          let message = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else { continue }

    let id = message["id"]
    let method = message["method"] as? String ?? ""

    switch method {
    case "initialize":
        respond(id: id, result: [
            "protocolVersion": "2025-06-18",
            "capabilities": ["tools": [:]],
            "serverInfo": ["name": serverName, "version": serverVersion]
        ])
    case "notifications/initialized":
        break
    case "tools/list":
        respond(id: id, result: ["tools": toolDefinitions()])
    case "tools/call":
        let params = message["params"] as? [String: Any] ?? [:]
        let name = params["name"] as? String ?? ""
        let args = params["arguments"] as? [String: Any] ?? [:]
        respond(id: id, result: handleToolCall(name, args))
    case "ping":
        respond(id: id, result: [:])
    default:
        respondError(id: id, code: -32601, message: "Method not found: \(method)")
    }
}
