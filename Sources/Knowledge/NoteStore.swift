import Foundation

/// A living knowledge note — a standing document you work out of, accumulating timestamped
/// entries across calls (the vault model: read it before, append to it after). Plain Markdown
/// in `<output folder>/Notes/`, wikilinked to transcripts so Obsidian's graph picks it up.
struct KnowledgeNote: Identifiable, Hashable {
    let url: URL
    let title: String
    let group: String
    let created: String
    let updated: String
    let entries: [Entry]

    struct Entry: Hashable {
        let stamp: String
        let text: String
        /// Transcript filename (sans extension) this entry came from, if it was added from a call.
        let linkedCall: String?
    }

    var id: URL { url }
}

/// Reads and writes knowledge notes. Deliberately NOT the transcript marker: notes carry
/// `app: call-transcriber-note`, so the retention pruner (transcript marker + transcript
/// filename shape) can never touch them, and transcript surfaces never list them.
/// The `Notes/` subfolder is invisible to the transcript index by construction (the indexer
/// scans the folder root only) — indexing notes for Ask/MCP is its own, later schema step.
enum NoteStore {
    static let marker = "call-transcriber-note"

    static var folder: URL {
        AppSettings.outputFolder.appendingPathComponent("Notes", isDirectory: true)
    }

    /// Notes in one workspace, most recently updated first.
    static func list(group: String) -> [KnowledgeNote] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "md" }
            .compactMap(parse)
            .filter { $0.group == group }
            .sorted { $0.updated > $1.updated }
    }

    /// Deletes a note file. The index row is cleared by the caller (needs the store).
    static func delete(_ note: KnowledgeNote) {
        try? FileManager.default.removeItem(at: note.url)
    }

    /// Creates an empty note in the workspace and returns it.
    static func create(title: String, group: String) -> KnowledgeNote? {
        let trimmed = title.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty else { return nil }
        try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let stamp = now()
        let content = """
        ---
        app: \(marker)
        title: "\(sanitize(trimmed))"
        group: "\(sanitize(group))"
        created: \(stamp)
        updated: \(stamp)
        ---

        # \(trimmed)

        """
        let url = uniqueURL(for: trimmed)
        guard (try? content.write(to: url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return parse(url)
    }

    /// Appends a timestamped entry (the "add on"), optionally linked to the call it came from.
    /// Returns the refreshed note.
    static func append(_ text: String, linkedCall: URL?, to note: KnowledgeNote) -> KnowledgeNote? {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              var content = try? String(contentsOf: note.url, encoding: .utf8) else { return nil }

        var line = "- **\(now())** — \(trimmed.replacingOccurrences(of: "\n", with: " "))"
        if let linkedCall {
            line += " ([[\(linkedCall.deletingPathExtension().lastPathComponent)]])"
        }
        if !content.hasSuffix("\n") { content += "\n" }
        content += line + "\n"

        // Refresh `updated:` in place — only inside the frontmatter block (line-delimited).
        var lines = content.components(separatedBy: "\n")
        if lines.first?.trimmingCharacters(in: .whitespaces) == "---",
           let close = lines.dropFirst().firstIndex(where: { $0.trimmingCharacters(in: .whitespaces) == "---" }),
           let idx = lines[1..<close].firstIndex(where: { $0.hasPrefix("updated:") }) {
            lines[idx] = "updated: \(now())"
        }
        content = lines.joined(separator: "\n")

        guard (try? content.write(to: note.url, atomically: true, encoding: .utf8)) != nil else { return nil }
        return parse(note.url)
    }

    // MARK: - Parsing

    static func parse(_ url: URL) -> KnowledgeNote? {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let split = Frontmatter.split(content) else { return nil }
        let fm = split.frontmatter.components(separatedBy: "\n")
        guard fm.contains(where: { line in
            let t = line.trimmingCharacters(in: .whitespaces)
            guard t.hasPrefix("app:") else { return false }
            return t.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: " \"'")) == marker
        }) else { return nil }

        func field(_ key: String) -> String {
            for line in fm {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("\(key):") {
                    return String(t.dropFirst(key.count + 1))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                }
            }
            return ""
        }

        let entries = split.body.components(separatedBy: "\n").compactMap(parseEntry)
        return KnowledgeNote(url: url, title: field("title"), group: field("group"),
                             created: field("created"), updated: field("updated"), entries: entries)
    }

    /// `- **2026-07-16 22:50** — text ([[Call name]])` → Entry. Non-entry lines return nil.
    private static func parseEntry(_ line: String) -> KnowledgeNote.Entry? {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("- **"),
              let stampEnd = trimmed.range(of: "**", range: trimmed.index(trimmed.startIndex, offsetBy: 4)..<trimmed.endIndex)
        else { return nil }
        let stamp = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 4)..<stampEnd.lowerBound])
        var rest = String(trimmed[stampEnd.upperBound...]).trimmingCharacters(in: .whitespaces)
        if rest.hasPrefix("—") { rest = String(rest.dropFirst()).trimmingCharacters(in: .whitespaces) }

        var linked: String?
        if rest.hasSuffix("]])"), let open = rest.range(of: "([[", options: .backwards) {
            linked = String(rest[open.upperBound..<rest.index(rest.endIndex, offsetBy: -3)])
            rest = String(rest[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
        }
        return KnowledgeNote.Entry(stamp: stamp, text: rest, linkedCall: linked)
    }

    // MARK: - Helpers

    private static func now() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: Date())
    }

    /// YAML-scalar safety for titles/groups (quotes + the `---` trap; see M9/M10).
    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "---", with: "—")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func uniqueURL(for title: String) -> URL {
        let base = title.replacingOccurrences(of: "/", with: "-")
            .replacingOccurrences(of: ":", with: "-")
        var candidate = folder.appendingPathComponent("\(base).md")
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent("\(base) \(n).md")
            n += 1
        }
        return candidate
    }
}
