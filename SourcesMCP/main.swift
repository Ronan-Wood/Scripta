import Foundation
import SQLite3

// A tiny, dependency-free MCP server (JSON-RPC 2.0 over newline-delimited stdio) that
// exposes the app's transcripts read-only to LLM clients (Claude Code / Desktop / Cowork).
// It initiates nothing — it only answers requests. Bundled inside the .app; spawned per client.

let ownerMarker = OwnerMarker.value
let serverName = "calltranscriber"
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
        .appendingPathComponent("CallTranscriber", isDirectory: true)
}

// MARK: - Transcript model + reading

struct Meta {
    let url: URL
    let title, date, time, duration: String
    let participants, tags: [String]
    let isConference: Bool
    let group: String
}

/// Splits on delimiter LINES (`---` alone on a line), mirroring the app's Frontmatter helper —
/// a `---` inside a title or the body (Screen Context dividers) must not truncate parsing.
func splitFrontmatter(_ content: String) -> (frontmatter: String, body: String)? {
    var lines = content.components(separatedBy: "\n")[...]
    guard lines.popFirst()?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
    guard let close = lines.firstIndex(where: {
        let t = $0.trimmingCharacters(in: .whitespaces)
        return t == "---" || t == "..."
    }) else { return nil }
    return (lines[..<close].joined(separator: "\n"), lines[(close + 1)...].joined(separator: "\n"))
}

func rawFrontmatterValue(_ frontmatter: String, _ key: String) -> String {
    for line in frontmatter.split(separator: "\n") {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        if trimmed.hasPrefix("\(key):") {
            return String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
        }
    }
    return ""
}

func frontmatterField(_ frontmatter: String, _ key: String) -> String {
    rawFrontmatterValue(frontmatter, key).trimmingCharacters(in: CharacterSet(charactersIn: " \"[]"))
}

/// Quoted items are taken verbatim — a "Last, First" name is ONE participant, not two;
/// unquoted values fall back to comma-splitting. Mirrors the app's TranscriptStore.parseList.
func frontmatterList(_ frontmatter: String, _ key: String) -> [String] {
    var value = rawFrontmatterValue(frontmatter, key)
    if value.hasPrefix("[") { value.removeFirst() }
    if value.hasSuffix("]") { value.removeLast() }
    guard value.contains("\"") else {
        return value.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }
    var items: [String] = []
    var current = ""
    var inQuote = false
    for ch in value {
        if ch == "\"" {
            if inQuote {
                let item = current.trimmingCharacters(in: .whitespaces)
                if !item.isEmpty { items.append(item) }
                current = ""
            }
            inQuote.toggle()
        } else if inQuote {
            current.append(ch)
        }
    }
    return items
}

func parseMeta(_ url: URL) -> Meta? {
    guard let content = try? String(contentsOf: url, encoding: .utf8),
          let split = splitFrontmatter(content) else { return nil }
    let fm = split.frontmatter
    // Only app-authored files: the marker must sit on its own line inside the frontmatter,
    // tolerating YAML quoting (`app: "call-transcriber"`) an editor may have added.
    guard fm.components(separatedBy: "\n").contains(where: { line -> Bool in
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("app:") else { return false }
        return trimmed.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) == ownerMarker
    }) else { return nil }
    return Meta(
        url: url,
        title: frontmatterField(fm, "title"),
        date: frontmatterField(fm, "date"),
        time: frontmatterField(fm, "time"),
        duration: frontmatterField(fm, "duration"),
        participants: frontmatterList(fm, "participants"),
        tags: frontmatterList(fm, "tags").filter { $0 != ownerMarker },
        isConference: frontmatterField(fm, "mode") == "conference",
        group: frontmatterField(fm, "group")
    )
}

/// The active-workspace scope the server must honor, or a refusal. Reads the app's heartbeat file;
/// if the app isn't running (stale/absent beat), the server refuses rather than trust a stale
/// scope — the privacy wall can't be one process-death deep.
func activeGroupScope() -> (group: String, refusal: String?) {
    guard let obj = stateFileObject(),
          let beat = obj["heartbeat"] as? Double else {
        return ("", "Open CallTranscriber and pick a workspace — the assistant won't query your calls without a live scope.")
    }
    if Date().timeIntervalSince1970 - beat > 60 {
        return ("", "CallTranscriber isn't running. Open it (and choose the workspace you mean) before I query your calls — I won't answer against a stale scope.")
    }
    return ((obj["activeGroup"] as? String) ?? "", nil)
}

func bodyText(_ content: String) -> String {
    splitFrontmatter(content)?.body ?? content
}

/// Extracts the "## Summary" section, if present.
func summaryOf(_ content: String) -> String {
    let body = bodyText(content)
    guard let start = body.range(of: "## Summary") else { return "" }
    var section = String(body[start.upperBound...])
    var cut = section.endIndex
    for stop in ["\n**[", "\n## ", "\n# "] {
        if let r = section.range(of: stop), r.lowerBound < cut { cut = r.lowerBound }
    }
    section = String(section[..<cut])
    return section.trimmingCharacters(in: .whitespacesAndNewlines)
}

func allTranscripts() -> [Meta] {
    let folder = outputFolder()
    guard let entries = try? FileManager.default.contentsOfDirectory(
        at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
    ) else { return [] }
    return entries
        .filter { $0.pathExtension == "md" }
        .compactMap(parseMeta)
        .sorted { ($0.date, $0.time) > ($1.date, $1.time) }
}

/// Resolves a client-provided path, but only if it's an app-authored transcript inside the
/// output folder — so the tool can never be used to read arbitrary files.
func safeTranscript(at path: String) -> Meta? {
    // Resolve symlinks on BOTH sides: a symlinked .md dropped inside the output folder must
    // not read through to a file elsewhere (SPEC containment invariant).
    let folder = outputFolder().standardizedFileURL.resolvingSymlinksInPath()
    let url = URL(fileURLWithPath: path).standardizedFileURL.resolvingSymlinksInPath()
    guard url.deletingLastPathComponent().path == folder.path else { return nil }
    return parseMeta(url)
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
func delimitedClause(_ column: String) -> String { " AND (char(10)||lower(\(column))||char(10)) LIKE ?" }
func delimitedValue(_ value: String) -> String { "%\n\(value.lowercased())\n%" }
let topicBM25 = "bm25(transcripts_fts, 0.0, 4.0, 1.0, 3.0, 0.5)"

func retrieve(_ query: String, participant: String?, tag: String?, since: String?, speaker: String?, group: String, limit: Int) -> [RetrieveHit]? {
    guard let db = openIndex() else { return nil }
    defer { sqlite3_close(db) }
    let speakerSet = speaker?.isEmpty == false

    // Passage + (unless a speaker filter is set) topic fusion for one MATCH expression. Mirrors
    // IndexStore.search so the MCP and the app return the same results (shared FTSQuery).
    func fused(_ match: String) -> [RetrieveHit] {
        var hits: [RetrieveHit] = []
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
        sql += " ORDER BY bm25(chunks_fts) LIMIT \(max(1, limit));"

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
                hits.append(RetrieveHit(title: col(0), date: col(1), path: col(2), speaker: col(4),
                                        snippet: col(5), startMs: Int(sqlite3_column_int64(stmt, 3)),
                                        score: sqlite3_column_double(stmt, 6)))
            }
        }
        sqlite3_finalize(stmt); stmt = nil

        // Topic-level fusion: calls matched by name/summary/concept-tag with no spoken-word hit.
        // Skipped under a speaker filter (topic rows carry no speaker), mirroring the app.
        guard !speakerSet else { return Array(hits.prefix(max(1, limit))) }
        let seen = Set(hits.map(\.path))
        var tsql = """
        SELECT f.title, t.date, f.path, f.summary
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
                if seen.contains(path) { continue }
                let summary = tcol(3)
                hits.append(RetrieveHit(title: tcol(0), date: tcol(1), path: path, speaker: "",
                                        snippet: summary.isEmpty ? "matched on topic" : String(summary.prefix(160)),
                                        startMs: 0, score: 0, isTopic: true))
            }
            sqlite3_finalize(stmt); stmt = nil
        }
        return Array(hits.prefix(max(1, limit)))
    }

    // AND-first (precise), OR fallback (recall floor) — same two-pass as the app.
    guard let andMatch = FTSQuery.andExpression(query) else { return [] }
    let hits = fused(andMatch)
    if !hits.isEmpty { return hits }
    guard let orMatch = FTSQuery.orExpression(query) else { return [] }
    return fused(orMatch)
}

/// Spoken lines of one transcript within [start, end] ms (from the chunk index — Screen Context is
/// naturally excluded since chunks are built only from audio lines). nil for an unknown/guarded
/// path or an empty window.
func getSection(path: String, start: Int, end: Int) -> String? {
    guard let meta = safeTranscript(at: path), let db = openIndex() else { return nil }
    defer { sqlite3_close(db) }
    let sql = "SELECT start_ms, IFNULL(speaker,''), text FROM chunks WHERE path = ? AND start_ms >= ? AND start_ms <= ? ORDER BY start_ms;"
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return nil }
    defer { sqlite3_finalize(stmt) }
    sqlite3_bind_text(stmt, 1, meta.url.path, -1, SQLITE_TRANSIENT_MCP)
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
            "description": "Return the full Markdown of one transcript by its file path (from list_transcripts).",
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
                let summary = summaryOf((try? String(contentsOf: m.url, encoding: .utf8)) ?? "")
                block += "\n\(summary.isEmpty ? "(no summary)" : summary)"
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
        guard let meta = safeTranscript(at: path), meta.group == group else {
            return textResult("That call isn't in the active workspace.", isError: true)
        }
        let end = (args["end"] as? Int) ?? (start + 120_000)
        guard let section = getSection(path: path, start: max(0, start - 30_000), end: end) else {
            return textResult("No section found there (empty window).", isError: true)
        }
        return textResult(section)

    case "get_transcript":
        guard let path = args["path"] as? String, let meta = safeTranscript(at: path) else {
            return textResult("No transcript found at that path (or it isn't an app transcript).", isError: true)
        }
        guard meta.group == group else {
            return textResult("That call isn't in the active workspace.", isError: true)
        }
        return textResult((try? String(contentsOf: meta.url, encoding: .utf8)) ?? "")

    case "search_transcripts":
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return textResult("Provide a non-empty query.", isError: true)
        }
        let needle = query.lowercased()
        var hits: [String] = []
        for m in allTranscripts() where m.group == group {
            guard let content = try? String(contentsOf: m.url, encoding: .utf8) else { continue }
            let body = bodyText(content)   // exclude YAML frontmatter from snippets
            let title = displayTitle(m)

            if let range = body.range(of: query, options: [.caseInsensitive]) {
                let start = body.index(range.lowerBound, offsetBy: -70, limitedBy: body.startIndex) ?? body.startIndex
                let end = body.index(range.upperBound, offsetBy: 70, limitedBy: body.endIndex) ?? body.endIndex
                let matchAt = body.distance(from: body.startIndex, to: range.lowerBound)
                let screenAt = body.range(of: "## Screen Context").map { body.distance(from: body.startIndex, to: $0.lowerBound) }
                let section = (screenAt.map { matchAt >= $0 } ?? false) ? "screen" : "transcript"
                let snippet = body[start..<end].replacingOccurrences(of: "\n", with: " ").trimmingCharacters(in: .whitespaces)
                hits.append("• \(title) [\(section)] — …\(snippet)…\n  path: \(m.url.path)")
            } else if title.lowercased().contains(needle) || m.participants.contains(where: { $0.lowercased().contains(needle) }) {
                let where_ = title.lowercased().contains(needle) ? "title" : "participant"
                let summary = summaryOf(content)
                hits.append("• \(title) [\(where_)] — \(summary.isEmpty ? "(metadata match)" : summary)\n  path: \(m.url.path)")
            }
            if hits.count >= 15 { break }
        }
        return textResult(hits.isEmpty ? "No matches for \"\(query)\"." : hits.joined(separator: "\n\n"))

    case "retrieve":
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return textResult("Provide a non-empty query.", isError: true)
        }
        let limit = (args["limit"] as? Int) ?? 15
        guard let hits = retrieve(query, participant: args["participant"] as? String,
                                  tag: args["tag"] as? String, since: args["since"] as? String,
                                  speaker: args["speaker"] as? String, group: group, limit: limit) else {
            return textResult("The retrieval index isn't built yet. Open Call Transcriber once to build it.", isError: true)
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
            return textResult("The retrieval index isn't built yet. Open Call Transcriber once to build it.", isError: true)
        }
        if entries.isEmpty { return textResult("No participants named yet. Name calls in the app to populate this.") }
        return textResult(entries.map { "• \($0.name) — \($0.count) call\($0.count == 1 ? "" : "s")" }.joined(separator: "\n"))

    case "tags":
        guard let entries = indexAggregate(column: "tags", group: group) else {
            return textResult("The retrieval index isn't built yet. Open Call Transcriber once to build it.", isError: true)
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
