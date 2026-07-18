import Foundation

/// Splits a transcript document into its YAML frontmatter block and body by scanning for
/// delimiter LINES (`---` alone on a line) — never by substring, so a `---` inside a title,
/// tag, or the body (Screen Context dividers) can't truncate the frontmatter.
///
/// The single source of truth for frontmatter parsing across the app, the bundled MCP server, and
/// the eval harness (lives in `Sources/Shared`, which all three compile) — so the marker check that
/// gates "app-authored only" and the field/list parsing can never drift between them.
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
        frontmatter.components(separatedBy: "\n").contains(where: isOwnerMarkerLine)
    }

    /// Matches the owner-marker line, tolerating YAML quoting (`app: "call-transcriber"` or
    /// `'call-transcriber'`) that Obsidian's properties editor adds — those are still our files.
    /// Safe to accept broadly: the retention pruner also gates on the transcript filename shape.
    static func isOwnerMarkerLine(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("app:") else { return false }
        let value = trimmed.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return value == OwnerMarker.value
    }

    // MARK: - Field access (shared by the app's TranscriptStore and the MCP)

    /// The raw text after `key:` on its frontmatter line (surrounding whitespace trimmed), or "".
    static func rawValue(_ frontmatter: String, _ key: String) -> String {
        for line in frontmatter.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key):") {
                return String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    /// A scalar field: the raw value with surrounding quotes/brackets stripped.
    static func field(_ frontmatter: String, _ key: String) -> String {
        rawValue(frontmatter, key).trimmingCharacters(in: CharacterSet(charactersIn: " \"[]"))
    }

    /// A frontmatter flow list. Quoted items are taken verbatim — a "Last, First" name is ONE
    /// participant, not two; unquoted values (hand-edited files) fall back to comma-splitting.
    static func list(_ frontmatter: String, _ key: String) -> [String] {
        parseList(rawValue(frontmatter, key))
    }

    /// Parses a frontmatter flow-list value (the string after `key:`).
    static func parseList(_ raw: String) -> [String] {
        var value = raw.trimmingCharacters(in: .whitespaces)
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
}
