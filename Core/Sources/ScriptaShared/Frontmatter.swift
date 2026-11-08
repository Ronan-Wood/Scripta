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

    /// A scalar field: a single-quoted value decoded, any other with only surrounding quotes/space
    /// stripped — NOT brackets, so a title like `[Draft] Plan` keeps them. Flow lists go through
    /// `list`/`parseList`, which strip the outer `[ ]` themselves (audit L4).
    public static func field(_ frontmatter: String, _ key: String) -> String {
        let raw = rawValue(frontmatter, key)
        if let decoded = singleQuoted(raw) { return decoded }
        return raw.trimmingCharacters(in: CharacterSet(charactersIn: " \""))
    }

    // MARK: - Writing a scalar

    /// `value` as a single-quoted YAML scalar, the form every writer in the app uses for free text:
    /// YAML 1.2, YAML 1.1, the engine's line reader and `field` all read it back as `value`, with
    /// each character a one-line scalar cannot hold replaced by a space. Single quotes have no
    /// escapes, so a backslash means itself; inside double quotes YAML reads the `\a` of
    /// `$\alpha$` as a bell, and `\d` is not YAML at all. The engine keeps the same character rule
    /// (its contract's `yaml.printable`, which `FrontmatterYAMLTests` holds this to) and reads this
    /// quoted form alike in every reader, and it also writes a value plain where that cannot mean
    /// anything else.
    public static func quoted(_ value: String) -> String {
        var out = "'"
        for scalar in yamlSafe(value).unicodeScalars {
            if scalar == "'" { out += "''" } else { out.unicodeScalars.append(scalar) }
        }
        return out + "'"
    }

    /// `value` with each scalar a one-line quoted YAML scalar cannot hold replaced by a space: line
    /// breaks (YAML 1.1 also breaks at NEL, LS and PS), the C0 controls other than tab, the C1
    /// controls, DEL, the byte-order mark, U+FFFE and U+FFFF. Per Unicode scalar, not per Character: a control joined to a
    /// combining mark is one Character and would otherwise go through whole.
    public static func yamlSafe(_ value: String) -> String {
        var out = String.UnicodeScalarView()
        for scalar in value.unicodeScalars {
            out.append(isYAMLPrintable(scalar.value) ? scalar : " ")
        }
        return String(out)
    }

    private static func isYAMLPrintable(_ v: UInt32) -> Bool {
        switch v {
        case 0x09, 0x20...0x7E, 0xA0...0x2027, 0x202A...0xD7FF, 0xE000...0xFEFE, 0xFF00...0xFFFD,
             0x10000...0x10FFFF:
            return true
        default:
            return false
        }
    }

    /// The decoded text of `raw` when it is one closed single-quoted scalar (`'…'`, every inner
    /// quote doubled), else nil. `raw` is trimmed of surrounding whitespace first.
    public static func singleQuoted(_ raw: String) -> String? {
        let t = raw.trimmingCharacters(in: .whitespaces)
        let scalars = Array(t.unicodeScalars)
        guard scalars.count >= 2, scalars.first == "'", scalars.last == "'" else { return nil }
        var out = String.UnicodeScalarView()
        var i = 1
        while i < scalars.count - 1 {
            if scalars[i] == "'" {
                guard i + 1 < scalars.count - 1, scalars[i + 1] == "'" else { return nil }
                i += 1
            }
            out.append(scalars[i])
            i += 1
        }
        return String(out)
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
        guard value.contains("\"") || value.contains("'") else {
            return value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        return quotedItems(Array(value.unicodeScalars))
    }

    /// The items of a flow list holding quotes. A `'` opening an item begins a single-quoted
    /// scalar (what the writers emit now; `''` is a quote, a comma inside is text), a `"` a
    /// double-quoted one read verbatim to the next `"` (every list written before, which escaped
    /// nothing). A quote anywhere else is text, as YAML reads it: `[it's, x]` is two items.
    private static func quotedItems(_ s: [Unicode.Scalar]) -> [String] {
        var items: [String] = []
        var i = 0
        func isSpace(_ c: Unicode.Scalar) -> Bool { CharacterSet.whitespaces.contains(c) }
        func add(_ v: String.UnicodeScalarView, trim: Bool) {
            let item = trim ? String(v).trimmingCharacters(in: .whitespaces) : String(v)
            if !item.trimmingCharacters(in: .whitespaces).isEmpty { items.append(item) }
        }
        while i < s.count {
            while i < s.count, isSpace(s[i]) { i += 1 }
            guard i < s.count else { break }
            var item = String.UnicodeScalarView()
            if s[i] == "'" || s[i] == "\"" {
                let quote = s[i]
                i += 1
                while i < s.count {
                    if s[i] == quote {
                        if quote == "'", i + 1 < s.count, s[i + 1] == "'" { item.append("'"); i += 2; continue }
                        i += 1
                        break
                    }
                    item.append(s[i]); i += 1
                }
                add(item, trim: quote == "\"")
                while i < s.count, s[i] != "," { i += 1 }
            } else {
                while i < s.count, s[i] != "," { item.append(s[i]); i += 1 }
                add(item, trim: true)
            }
            i += 1  // the comma
        }
        return items
    }
}
