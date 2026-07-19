import Foundation
import ScriptaShared

/// A renderable block of a parsed transcript.
public enum TranscriptBlock: Sendable {
    case section(String)                       // "## …" headers
    case audioLine(String, String?, String)    // timestamp, speaker (You/Them or nil), spoken text
    case screenMarker(String)                  // a Screen Context entry's timestamp
    case table([String])                       // consecutive Markdown table rows
    case paragraph(String)
    case divider
}

/// Parses our transcript Markdown into blocks for the in-app viewer. Purpose-built for the
/// format TranscriptWriter emits — not a general Markdown engine.
public enum TranscriptParser {

    public static func parse(_ content: String) -> [TranscriptBlock] {
        let body = Frontmatter.split(content)?.body ?? content

        var blocks: [TranscriptBlock] = []
        var tableBuffer: [String] = []

        func flushTable() {
            let rows = tableBuffer.filter { row in
                // Drop the "| --- | --- |" separator row.
                !row.filter { $0 != "|" && $0 != "-" && $0 != " " && $0 != ":" }.isEmpty
            }
            if !rows.isEmpty { blocks.append(.table(rows)) }
            tableBuffer = []
        }

        for rawLine in body.split(separator: "\n", omittingEmptySubsequences: false) {
            let trimmed = rawLine.trimmingCharacters(in: .whitespaces)

            if trimmed.isEmpty { flushTable(); continue }
            if trimmed.hasPrefix("|") { tableBuffer.append(trimmed); continue }
            flushTable()

            if trimmed.hasPrefix("# ") { continue }   // title already shown in the header
            if trimmed.hasPrefix("## ") { blocks.append(.section(String(trimmed.dropFirst(3)))); continue }
            if trimmed == "---" { blocks.append(.divider); continue }

            if let (stamp, speaker, rest) = parseTimestamp(trimmed) {
                blocks.append(rest.isEmpty ? .screenMarker(stamp) : .audioLine(stamp, speaker, rest))
                continue
            }

            blocks.append(.paragraph(trimmed))
        }
        flushTable()
        return blocks
    }

    /// Matches the bold-prefixed transcript line, with or without a speaker label:
    ///   "**[0:00]** spoken text"        → ("[0:00]", nil,   "spoken text")
    ///   "**[0:00] You:** spoken text"   → ("[0:00]", "You", "spoken text")
    private static func parseTimestamp(_ line: String) -> (stamp: String, speaker: String?, rest: String)? {
        guard line.hasPrefix("**[") else { return nil }
        let afterOpen = line.index(line.startIndex, offsetBy: 2)   // past the leading "**"
        guard let close = line.range(of: "**", range: afterOpen..<line.endIndex) else { return nil }

        // Inside the bold run: "[0:00]" or "[0:00] You:"
        let inner = String(line[afterOpen..<close.lowerBound])
        let rest = String(line[close.upperBound...]).trimmingCharacters(in: .whitespaces)
        guard let bracketEnd = inner.firstIndex(of: "]") else { return nil }

        let stamp = String(inner[inner.startIndex...bracketEnd])
        let after = inner[inner.index(after: bracketEnd)...].trimmingCharacters(in: .whitespaces)
        let speaker = after.hasSuffix(":") ? String(after.dropLast()) : (after.isEmpty ? nil : after)
        return (stamp, speaker, rest)
    }
}
