import Foundation
import SQLite3

// A tiny, dependency-free MCP server (JSON-RPC 2.0 over newline-delimited stdio) that
// exposes the app's transcripts read-only to LLM clients (Claude Code / Desktop / Cowork).
// It initiates nothing — it only answers requests. Bundled inside the .app; spawned per client.

let ownerMarker = "call-transcriber"
let serverName = "calltranscriber"
let serverVersion = "1.0.0"

// MARK: - Output folder (shared with the app via its preferences domain)

func outputFolder() -> URL {
    if let path = UserDefaults(suiteName: "com.ronanwood.CallTranscriber")?.string(forKey: "outputFolderPath"),
       !path.isEmpty {
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
    // Only app-authored files: the marker must sit on its own line inside the frontmatter.
    guard fm.components(separatedBy: "\n").contains(where: {
        $0.trimmingCharacters(in: .whitespaces) == "app: \(ownerMarker)"
    }) else { return nil }
    return Meta(
        url: url,
        title: frontmatterField(fm, "title"),
        date: frontmatterField(fm, "date"),
        time: frontmatterField(fm, "time"),
        duration: frontmatterField(fm, "duration"),
        participants: frontmatterList(fm, "participants"),
        tags: frontmatterList(fm, "tags").filter { $0 != ownerMarker }
    )
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

func indexDBURL() -> URL {
    FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
        .appendingPathComponent("CallTranscriber", isDirectory: true)
        .appendingPathComponent("index.db")
}

func openIndex() -> OpaquePointer? {
    let path = indexDBURL().path
    guard FileManager.default.fileExists(atPath: path) else { return nil }
    var db: OpaquePointer?
    guard sqlite3_open_v2(path, &db, SQLITE_OPEN_READONLY, nil) == SQLITE_OK else { return nil }
    sqlite3_busy_timeout(db, 3000)
    return db
}

/// OR-of-prefix-terms FTS query, mirroring the app's builder so results match.
func ftsQuery(_ raw: String) -> String? {
    let terms = raw.lowercased()
        .components(separatedBy: CharacterSet.alphanumerics.inverted)
        .filter { $0.count >= 2 }
    guard !terms.isEmpty else { return nil }
    return terms.map { "\"\($0)\"*" }.joined(separator: " OR ")
}

struct RetrieveHit {
    let title, date, path, speaker, snippet: String
    let startMs: Int
    let score: Double
}

func retrieve(_ query: String, participant: String?, tag: String?, since: String?, limit: Int) -> [RetrieveHit]? {
    guard let db = openIndex() else { return nil }
    defer { sqlite3_close(db) }
    guard let match = ftsQuery(query) else { return [] }

    var sql = """
    SELECT t.title, t.date, c.path, c.start_ms, IFNULL(c.speaker,''),
           snippet(chunks_fts, 0, '⟦', '⟧', '…', 12), bm25(chunks_fts)
    FROM chunks_fts JOIN chunks c ON c.id = chunks_fts.rowid JOIN transcripts t ON t.path = c.path
    WHERE chunks_fts MATCH ?
    """
    if participant?.isEmpty == false { sql += " AND lower(t.participants) LIKE ?" }
    if tag?.isEmpty == false { sql += " AND lower(t.tags) LIKE ?" }
    if since?.isEmpty == false { sql += " AND t.date >= ?" }
    sql += " ORDER BY bm25(chunks_fts) LIMIT \(max(1, limit));"

    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, sql, -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    var i: Int32 = 1
    func bind(_ s: String) { sqlite3_bind_text(stmt, i, s, -1, SQLITE_TRANSIENT_MCP); i += 1 }
    bind(match)
    if let p = participant, !p.isEmpty { bind("%\(p.lowercased())%") }
    if let t = tag, !t.isEmpty { bind("%\(t.lowercased())%") }
    if let s = since, !s.isEmpty { bind(s) }

    func col(_ n: Int32) -> String { sqlite3_column_text(stmt, n).map { String(cString: $0) } ?? "" }
    var hits: [RetrieveHit] = []
    while sqlite3_step(stmt) == SQLITE_ROW {
        hits.append(RetrieveHit(title: col(0), date: col(1), path: col(2), speaker: col(4),
                                snippet: col(5), startMs: Int(sqlite3_column_int64(stmt, 3)),
                                score: sqlite3_column_double(stmt, 6)))
    }
    sqlite3_finalize(stmt); stmt = nil

    // Topic-level fusion: surface calls that matched by name/summary/concept-tag even when no
    // spoken chunk contained the word. Appended for paths not already returned as passages.
    let seen = Set(hits.map(\.path))
    var tsql = """
    SELECT f.title, t.date, f.path, f.summary
    FROM transcripts_fts f JOIN transcripts t ON t.path = f.path
    WHERE transcripts_fts MATCH ?
    """
    if participant?.isEmpty == false { tsql += " AND lower(t.participants) LIKE ?" }
    if tag?.isEmpty == false { tsql += " AND lower(t.tags) LIKE ?" }
    if since?.isEmpty == false { tsql += " AND t.date >= ?" }
    tsql += " ORDER BY bm25(transcripts_fts) LIMIT \(max(1, limit));"
    if sqlite3_prepare_v2(db, tsql, -1, &stmt, nil) == SQLITE_OK {
        var j: Int32 = 1
        func tbind(_ s: String) { sqlite3_bind_text(stmt, j, s, -1, SQLITE_TRANSIENT_MCP); j += 1 }
        tbind(match)
        if let p = participant, !p.isEmpty { tbind("%\(p.lowercased())%") }
        if let t = tag, !t.isEmpty { tbind("%\(t.lowercased())%") }
        if let s = since, !s.isEmpty { tbind(s) }
        func tcol(_ n: Int32) -> String { sqlite3_column_text(stmt, n).map { String(cString: $0) } ?? "" }
        while sqlite3_step(stmt) == SQLITE_ROW {
            let path = tcol(2)
            if seen.contains(path) { continue }
            let summary = tcol(3)
            hits.append(RetrieveHit(title: tcol(0), date: tcol(1), path: path, speaker: "",
                                    snippet: summary.isEmpty ? "matched on topic" : String(summary.prefix(160)),
                                    startMs: 0, score: 0))
        }
        sqlite3_finalize(stmt); stmt = nil
    }
    // Both queries are individually capped, so the fused list can reach 2× limit — trim.
    return Array(hits.prefix(max(1, limit)))
}

/// Per-value counts from a newline-joined column (participants or tags), most-frequent first.
func indexAggregate(column: String) -> [(name: String, count: Int)]? {
    guard let db = openIndex() else { return nil }
    defer { sqlite3_close(db) }
    var stmt: OpaquePointer?
    guard sqlite3_prepare_v2(db, "SELECT \(column) FROM transcripts", -1, &stmt, nil) == SQLITE_OK else { return [] }
    defer { sqlite3_finalize(stmt) }
    var counts: [String: Int] = [:]
    while sqlite3_step(stmt) == SQLITE_ROW {
        let value = sqlite3_column_text(stmt, 0).map { String(cString: $0) } ?? ""
        for v in value.split(separator: "\n") {
            let name = v.trimmingCharacters(in: .whitespaces)
            if !name.isEmpty && name != ownerMarker { counts[name, default: 0] += 1 }
        }
    }
    return counts.map { (name: $0.key, count: $0.value) }
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
            "description": "Scannable overview of ALL call transcripts — each one's title, date, participants, and summary, plus its file path. Use this FIRST to figure out which call(s) are relevant to a question, then call get_transcript for the full text.",
            "inputSchema": ["type": "object"]
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
            "description": "Semantic-style retrieval over the indexed call chunks: keyword-ranked (BM25) passages with their call, timestamp, and speaker, optionally filtered by participant/tag/date. Prefer this over search_transcripts for finding the most relevant moments across many calls.",
            "inputSchema": [
                "type": "object",
                "properties": [
                    "query": ["type": "string", "description": "What to look for (natural words; any term may match)."],
                    "participant": ["type": "string", "description": "Only calls naming this participant."],
                    "tag": ["type": "string", "description": "Only calls with this tag."],
                    "since": ["type": "string", "description": "Only calls on or after this date (YYYY-MM-DD)."],
                    "limit": ["type": "integer", "description": "Max passages to return (default 15)."]
                ],
                "required": ["query"]
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
    switch name {
    case "overview":
        let items = allTranscripts()
        if items.isEmpty { return textResult("No transcripts yet.") }
        let blocks = items.prefix(60).map { m -> String in
            let content = (try? String(contentsOf: m.url, encoding: .utf8)) ?? ""
            let summary = summaryOf(content)
            let meta = [[m.date, m.time].joined(separator: " "), m.duration]
                .filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }.joined(separator: ", ")
            var block = "### \(displayTitle(m))"
            if !meta.isEmpty { block += "  (\(meta))" }
            if !m.participants.isEmpty { block += "\nParticipants: \(m.participants.joined(separator: ", "))" }
            block += "\n\(summary.isEmpty ? "(no summary)" : summary)"
            block += "\npath: \(m.url.path)"
            return block
        }
        return textResult(blocks.joined(separator: "\n\n"))

    case "list_transcripts":
        var items = allTranscripts()
        if let participant = (args["participant"] as? String)?.lowercased(), !participant.isEmpty {
            items = items.filter { $0.participants.contains { $0.lowercased().contains(participant) } }
        }
        if let tag = (args["tag"] as? String)?.lowercased(), !tag.isEmpty {
            items = items.filter { $0.tags.contains { $0.lowercased().contains(tag) } }
        }
        if let since = args["since"] as? String, !since.isEmpty {
            items = items.filter { $0.date >= since }
        }
        let limit = (args["limit"] as? Int) ?? 20
        items = Array(items.prefix(max(1, limit)))
        if items.isEmpty { return textResult("No transcripts found.") }
        let lines = items.map { m -> String in
            var parts = ["• \(displayTitle(m))"]
            let meta = [[m.date, m.time].joined(separator: " "), m.duration].filter { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
            if !meta.isEmpty { parts.append("(\(meta.joined(separator: ", ")))") }
            if !m.participants.isEmpty { parts.append("— \(m.participants.joined(separator: ", "))") }
            return parts.joined(separator: " ") + "\n  path: \(m.url.path)"
        }
        return textResult(lines.joined(separator: "\n"))

    case "get_transcript":
        guard let path = args["path"] as? String, let meta = safeTranscript(at: path) else {
            return textResult("No transcript found at that path (or it isn't an app transcript).", isError: true)
        }
        return textResult((try? String(contentsOf: meta.url, encoding: .utf8)) ?? "")

    case "search_transcripts":
        guard let query = (args["query"] as? String)?.trimmingCharacters(in: .whitespaces), !query.isEmpty else {
            return textResult("Provide a non-empty query.", isError: true)
        }
        let needle = query.lowercased()
        var hits: [String] = []
        for m in allTranscripts() {
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
                                  limit: limit) else {
            return textResult("The retrieval index isn't built yet. Open Call Transcriber once to build it.", isError: true)
        }
        if hits.isEmpty { return textResult("No relevant passages for \"\(query)\".") }
        let blocks = hits.map { h -> String in
            let title = h.title.isEmpty ? h.date : h.title
            let who = h.speaker.isEmpty ? "" : " \(h.speaker):"
            let snippet = h.snippet.replacingOccurrences(of: "⟦", with: "**").replacingOccurrences(of: "⟧", with: "**")
            return "• \(title) — [\(clockStamp(h.startMs))]\(who) …\(snippet)…\n  path: \(h.path)"
        }
        return textResult(blocks.joined(separator: "\n\n"))

    case "people":
        guard let entries = indexAggregate(column: "participants") else {
            return textResult("The retrieval index isn't built yet. Open Call Transcriber once to build it.", isError: true)
        }
        if entries.isEmpty { return textResult("No participants named yet. Name calls in the app to populate this.") }
        return textResult(entries.map { "• \($0.name) — \($0.count) call\($0.count == 1 ? "" : "s")" }.joined(separator: "\n"))

    case "tags":
        guard let entries = indexAggregate(column: "tags") else {
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
