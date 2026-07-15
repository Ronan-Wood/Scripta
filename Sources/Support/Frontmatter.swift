import Foundation

/// Splits a transcript document into its YAML frontmatter block and body by scanning for
/// delimiter LINES (`---` alone on a line) — never by substring, so a `---` inside a title,
/// tag, or the body (Screen Context dividers) can't truncate the frontmatter.
enum Frontmatter {
    struct Split {
        /// The lines between the delimiter lines (delimiters excluded).
        let frontmatter: String
        /// Everything after the closing delimiter line.
        let body: String
    }

    static func split(_ content: String) -> Split? {
        var lines = content.components(separatedBy: "\n")[...]
        guard lines.popFirst()?.trimmingCharacters(in: .whitespaces) == "---" else { return nil }
        guard let close = lines.firstIndex(where: {
            let t = $0.trimmingCharacters(in: .whitespaces)
            return t == "---" || t == "..."
        }) else { return nil }
        return Split(frontmatter: lines[..<close].joined(separator: "\n"),
                     body: lines[(close + 1)...].joined(separator: "\n"))
    }

    /// True when the `app: call-transcriber` owner marker sits on its own line in the block.
    static func hasOwnerMarker(_ frontmatter: String) -> Bool {
        frontmatter.components(separatedBy: "\n").contains {
            $0.trimmingCharacters(in: .whitespaces) == "app: \(TranscriptWriter.ownerMarker)"
        }
    }
}
