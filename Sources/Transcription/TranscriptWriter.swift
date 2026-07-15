import Foundation

/// Writes a transcript as a Markdown file with Obsidian-style YAML frontmatter into the
/// configured output folder. The `app: call-transcriber` frontmatter key marks files this
/// app owns — the retention pruner (M5) keys on it so it never touches unrelated vault files.
enum TranscriptWriter {

    /// Marker written into every transcript's frontmatter. Load-bearing for safe pruning.
    static let ownerMarker = "call-transcriber"

    static func write(
        segments: [TranscriptSegment],
        startedAt: Date,
        duration: TimeInterval,
        participants: [String] = [],
        tags: [String] = ["call"],
        title: String? = nil,
        summary: String? = nil,
        screenSnippets: [ScreenSnippet] = [],
        isConference: Bool = false
    ) throws -> URL {
        let folder = AppSettings.outputFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let url = uniqueURL(in: folder, startedAt: startedAt, title: title)
        var contents = frontmatter(startedAt: startedAt, duration: duration,
                                   participants: participants, tags: tags, title: title,
                                   isConference: isConference)
        if let summary, !summary.isEmpty {
            contents += "\n\n## Summary\n\n" + summary
        }
        contents += "\n" + body(segments: segments) + "\n"
        if !screenSnippets.isEmpty {
            contents += "\n" + screenContext(screenSnippets) + "\n"
        }

        try contents.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    // MARK: - Formatting

    /// Frontmatter and filename stamps are machine-readable contracts (index parsing, `since`
    /// filters, sorting) — POSIX-locked so Thai/Arabic system locales can't write Buddhist-era
    /// years or non-ASCII digits into them.
    private static func posixFormatter(_ format: String) -> DateFormatter {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = format
        return f
    }

    private static func frontmatter(startedAt: Date, duration: TimeInterval,
                                    participants: [String], tags: [String], title: String?,
                                    isConference: Bool) -> String {
        let dateFmt = posixFormatter("yyyy-MM-dd")
        let timeFmt = posixFormatter("HH:mm")
        let dateStr = dateFmt.string(from: startedAt)
        let timeStr = timeFmt.string(from: startedAt)

        // Every scalar goes through the sanitizer — enricher topics and calendar attendees are
        // uncontrolled input, and one embedded quote/newline invalidates the whole block.
        let allTags = (tags + [ownerMarker]).map(sanitizeScalar).filter { !$0.isEmpty }
        let tagList = allTags.map { "\"\($0)\"" }.joined(separator: ", ")
        let participantList = participants.map(sanitizeScalar).filter { !$0.isEmpty }
            .map { "\"\($0)\"" }.joined(separator: ", ")

        let cleanTitle = title.map(sanitizeScalar) ?? ""
        let heading = cleanTitle.isEmpty ? "Call — \(dateStr) \(timeStr)" : cleanTitle

        var yaml = "---\n"
        yaml += "date: \(dateStr)\n"
        yaml += "time: \"\(timeStr)\"\n"
        yaml += "duration: \"\(formatClock(duration))\"\n"
        if !cleanTitle.isEmpty { yaml += "title: \"\(cleanTitle)\"\n" }
        yaml += "participants: [\(participantList)]\n"
        yaml += "tags: [\(tagList)]\n"
        // Recorded from a single source, unlabeled. Absent = a normal two-party call.
        if isConference { yaml += "mode: conference\n" }
        yaml += "app: \(ownerMarker)\n"
        yaml += "---\n\n# \(heading)"
        return yaml
    }

    /// The one YAML scalar sanitizer (writer + metadata editor). Values are emitted inside
    /// double quotes on a single key line, so stripping quotes and newlines is what keeps a
    /// value — including one containing `---` — from escaping its line. Parsers must split
    /// frontmatter on delimiter LINES (see `Frontmatter`), never on the `---` substring.
    static func sanitizeScalar(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\r\n", with: " ")
            .replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "\r", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private static func body(segments: [TranscriptSegment]) -> String {
        guard !segments.isEmpty else {
            return "\n_(No speech detected.)_"
        }
        let lines = segments.map { segment in
            let stamp = formatClock(Double(segment.startMs) / 1000.0)
            let label = segment.speaker.map { " \($0.rawValue):" } ?? ""
            return "**[\(stamp)]\(label)** \(segment.text)"
        }
        return "\n" + lines.joined(separator: "\n\n")
    }

    private static func screenContext(_ snippets: [ScreenSnippet]) -> String {
        // Not blockquoted, so Markdown tables from the document reader render properly.
        let entries = snippets.map { snippet in
            "**[\(formatClock(Double(snippet.startMs) / 1000.0))]**\n\n\(snippet.text)"
        }
        return "## Screen Context\n\n" + entries.joined(separator: "\n\n---\n\n")
    }

    /// Seconds → M:SS or H:MM:SS.
    private static func formatClock(_ seconds: TimeInterval) -> String {
        let total = Int(seconds.rounded())
        let h = total / 3600, m = (total % 3600) / 60, s = total % 60
        return h > 0
            ? String(format: "%d:%02d:%02d", h, m, s)
            : String(format: "%d:%02d", m, s)
    }

    /// Builds a collision-free filename: "<Title> — 2026-07-13 1150.md", or
    /// "Call — 2026-07-13 1150.md" when there's no title.
    private static func uniqueURL(in folder: URL, startedAt: Date, title: String?) -> URL {
        let stamp = posixFormatter("yyyy-MM-dd HHmm").string(from: startedAt)
        let clean = title.map(sanitizeFilename) ?? ""
        let base = clean.isEmpty ? "Call — \(stamp)" : "\(clean) — \(stamp)"

        var candidate = folder.appendingPathComponent("\(base).md")
        var counter = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) (\(counter)).md")
            counter += 1
        }
        return candidate
    }

    private static func sanitizeFilename(_ title: String) -> String {
        let invalid = CharacterSet(charactersIn: "/\\:*?\"<>|")
        var result = title.components(separatedBy: invalid).joined(separator: " ")
        result = result.replacingOccurrences(of: "\n", with: " ")
        result = result.replacingOccurrences(of: " {2,}", with: " ", options: .regularExpression)
        result = result.trimmingCharacters(in: .whitespacesAndNewlines)
        if result.count > 50 {
            result = String(result.prefix(50)).trimmingCharacters(in: .whitespaces)
        }
        return result
    }
}
