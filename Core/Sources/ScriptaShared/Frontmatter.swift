import Foundation

/// Splits a transcript document into its YAML frontmatter block and body by scanning for
/// delimiter LINES (`---` alone on a line) — never by substring, so a `---` inside a title,
/// tag, or the body (Screen Context dividers) can't truncate the frontmatter.
///
/// The single source of truth for frontmatter parsing across the app, the bundled MCP server, and
/// the eval harness (lives in `Sources/Shared`, which all three compile) — so the marker check that
/// gates "app-authored only" and the field/list parsing can never drift between them.
public enum Frontmatter {
    public struct Split {
        /// The lines between the delimiter lines (delimiters excluded).
        public let frontmatter: String
        /// Everything after the closing delimiter line.
        public let body: String
    }

    public static func split(_ content: String) -> Split? {
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
    public static func hasOwnerMarker(_ frontmatter: String) -> Bool {
        frontmatter.components(separatedBy: "\n").contains(where: isOwnerMarkerLine)
    }

    /// Matches an `app:` marker line for the given marker value, tolerating YAML quoting
    /// (`app: "value"` / `'value'`) that Obsidian's properties editor adds — those are still our
    /// files. Shared by the transcript owner marker and the entity-mirror stub marker.
    public static func isMarkerLine(_ line: String, marker: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("app:") else { return false }
        let value = trimmed.dropFirst(4).trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
        return value == marker
    }

    /// The transcript owner-marker line. Safe to accept quoting broadly: the retention pruner
    /// also gates on the transcript filename shape.
    public static func isOwnerMarkerLine(_ line: String) -> Bool {
        isMarkerLine(line, marker: OwnerMarker.value)
    }

    // MARK: - Field access (shared by the app's TranscriptStore and the MCP)

    /// The raw text after `key:` on its frontmatter line (surrounding whitespace trimmed), or "".
    public static func rawValue(_ frontmatter: String, _ key: String) -> String {
        for line in frontmatter.split(separator: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed.hasPrefix("\(key):") {
                return String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            }
        }
        return ""
    }

    /// A scalar field: the raw value with only surrounding quotes/space stripped — NOT brackets, so
    /// a title like `[Draft] Plan` keeps them. Flow lists go through `list`/`parseList`, which strip
    /// the outer `[ ]` themselves (audit L4).
    public static func field(_ frontmatter: String, _ key: String) -> String {
        rawValue(frontmatter, key).trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    }

    /// A frontmatter flow list. Quoted items are taken verbatim — a "Last, First" name is ONE
    /// participant, not two; unquoted values (hand-edited files) fall back to comma-splitting.
    public static func list(_ frontmatter: String, _ key: String) -> [String] {
        parseList(rawValue(frontmatter, key))
    }

    /// Parses a frontmatter flow-list value (the string after `key:`).
    public static func parseList(_ raw: String) -> [String] {
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
