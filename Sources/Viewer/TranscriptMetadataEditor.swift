import Foundation

/// Rewrites the editable metadata (title + participants) in an existing app-authored transcript's
/// YAML frontmatter, in place. The file is NOT renamed — every display surface (viewer, MCP,
/// Recent menu) reads the title from frontmatter, not the filename, so a rename would only risk
/// breaking vault backlinks for no display benefit.
///
/// Only the frontmatter and the `# heading` line are touched; the transcript body is never mutated.
enum TranscriptMetadataEditor {
    struct EditError: LocalizedError {
        let message: String
        var errorDescription: String? { message }
    }

    /// Patches `title`, `participants`, and `tags` in the transcript at `url`, updating the
    /// `# heading` to match the new title. A no-op title (empty) leaves the heading as-is. The
    /// `call-transcriber` owner marker is always preserved in the tag list.
    static func update(url: URL, title rawTitle: String, participants rawParticipants: [String],
                       tags rawTags: [String]) throws {
        let content = try String(contentsOf: url, encoding: .utf8)
        let parts = content.components(separatedBy: "---")
        guard parts.count >= 3, parts[1].contains("app: \(TranscriptWriter.ownerMarker)") else {
            throw EditError(message: "This isn’t a Call Transcriber transcript.")
        }

        let title = sanitize(rawTitle)
        let participants = rawParticipants.map(sanitize).filter { !$0.isEmpty }
        let marker = TranscriptWriter.ownerMarker
        let tags = rawTags.map(sanitize).filter { !$0.isEmpty && $0 != marker } + [marker]

        // --- Rewrite the frontmatter block (parts[1]). Preserve leading/trailing newlines. ---
        var lines = parts[1].components(separatedBy: "\n")
        lines.removeAll {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t.hasPrefix("title:") || t.hasPrefix("participants:") || t.hasPrefix("tags:")
        }
        let participantsLine = "participants: [\(participants.map { "\"\($0)\"" }.joined(separator: ", "))]"
        let tagsLine = "tags: [\(tags.map { "\"\($0)\"" }.joined(separator: ", "))]"

        // Re-insert title (if any), participants, and tags immediately after the `duration:` line
        // so the block keeps a stable, readable order.
        var rebuilt: [String] = []
        var inserted = false
        for line in lines {
            rebuilt.append(line)
            if !inserted, line.trimmingCharacters(in: .whitespaces).hasPrefix("duration:") {
                if !title.isEmpty { rebuilt.append("title: \"\(title)\"") }
                rebuilt.append(participantsLine)
                rebuilt.append(tagsLine)
                inserted = true
            }
        }
        if !inserted {   // no duration line (unexpected) — fall back to the top of the block
            var at = 1
            if !title.isEmpty { rebuilt.insert("title: \"\(title)\"", at: at); at += 1 }
            rebuilt.insert(participantsLine, at: at); at += 1
            rebuilt.insert(tagsLine, at: at)
        }
        let newFront = rebuilt.joined(separator: "\n")

        // --- Update the `# heading` line in the body (everything after the frontmatter). ---
        var body = parts.dropFirst(2).joined(separator: "---")
        if !title.isEmpty {
            body = replacingFirstHeading(in: body, with: "# \(title)")
        }

        let result = "---" + newFront + "---" + body
        try result.write(to: url, atomically: true, encoding: .utf8)
    }

    /// Replaces the first Markdown H1 (`# …`) line, leaving surrounding whitespace intact.
    private static func replacingFirstHeading(in body: String, with heading: String) -> String {
        var lines = body.components(separatedBy: "\n")
        for i in lines.indices where lines[i].hasPrefix("# ") {
            lines[i] = heading
            break
        }
        return lines.joined(separator: "\n")
    }

    /// Frontmatter values are double-quoted; strip characters that would break the YAML line.
    private static func sanitize(_ text: String) -> String {
        text.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
