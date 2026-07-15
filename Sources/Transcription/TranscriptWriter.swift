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
        screenSnippets: [ScreenSnippet] = []
    ) throws -> URL {
        let folder = AppSettings.outputFolder
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)

        let url = uniqueURL(in: folder, startedAt: startedAt, title: title)
        var contents = frontmatter(startedAt: startedAt, duration: duration,
                                   participants: participants, tags: tags, title: title)
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

    private static func frontmatter(startedAt: Date, duration: TimeInterval,
                                    participants: [String], tags: [String], title: String?) -> String {
        let dateFmt = DateFormatter(); dateFmt.dateFormat = "yyyy-MM-dd"
        let timeFmt = DateFormatter(); timeFmt.dateFormat = "HH:mm"
        let dateStr = dateFmt.string(from: startedAt)
        let timeStr = timeFmt.string(from: startedAt)

        let allTags = tags + [ownerMarker]
        let tagList = allTags.map { "\"\($0)\"" }.joined(separator: ", ")
        let participantList = participants.map { "\"\($0)\"" }.joined(separator: ", ")

        let cleanTitle = title.map(sanitizeYAML) ?? ""
        let heading = cleanTitle.isEmpty ? "Call — \(dateStr) \(timeStr)" : cleanTitle

        var yaml = "---\n"
        yaml += "date: \(dateStr)\n"
        yaml += "time: \"\(timeStr)\"\n"
        yaml += "duration: \"\(formatClock(duration))\"\n"
        if !cleanTitle.isEmpty { yaml += "title: \"\(cleanTitle)\"\n" }
        yaml += "participants: [\(participantList)]\n"
        yaml += "tags: [\(tagList)]\n"
        yaml += "app: \(ownerMarker)\n"
        yaml += "---\n\n# \(heading)"
        return yaml
    }

    private static func sanitizeYAML(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
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
        let fmt = DateFormatter(); fmt.dateFormat = "yyyy-MM-dd HHmm"
        let stamp = fmt.string(from: startedAt)
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
