import Foundation

/// A vault note broken into the blocks a reader sees, so a view can draw each as itself.
///
/// WHY THIS EXISTS. A note was rendered as one `Text` of the whole file — frontmatter included — so
/// the reader got `---`, `status: active`, `# Heading`, literal `**bold**` asterisks and a markdown
/// table as pipe-separated text. Notes ARE the product's content; showing them as source is showing
/// the reader the machinery instead of the thing.
///
/// SwiftUI renders INLINE markdown (`AttributedString(markdown:)` handles bold, italic, code, links)
/// and no block structure at all — no headings, no lists, no tables. So the blocks are found here
/// and the inline half is left to the view, which is the half the platform already does well.
///
/// IN THE PACKAGE, per Doc 4 §6: it is a parser with edge cases, and a parser the test suite cannot
/// reach is the shape this project has twice recorded defects hiding in.
public enum MarkdownBlocks {

    public enum Block: Equatable {
        /// `#` … `######`. `level` is 1-6, clamped.
        case heading(level: Int, text: String)
        case paragraph(String)
        case bullets([String])
        case numbered([String])
        /// A pipe table. `rows` excludes the header and the `|---|` separator.
        case table(headers: [String], rows: [[String]])
        case code(String)
        case rule
    }

    /// The note's body, without its frontmatter, as blocks.
    public static func parse(_ markdown: String) -> [Block] {
        var blocks: [Block] = []
        var paragraph: [String] = []
        var bullets: [String] = []
        var numbered: [String] = []

        func flushParagraph() {
            guard !paragraph.isEmpty else { return }
            blocks.append(.paragraph(paragraph.joined(separator: " ")))
            paragraph = []
        }
        func flushLists() {
            if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
            if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
        }
        func flushAll() { flushParagraph(); flushLists() }

        let lines = markdown.components(separatedBy: .newlines)
        var index = 0
        while index < lines.count {
            let line = lines[index]
            let trimmed = line.trimmingCharacters(in: .whitespaces)

            // Fenced code runs to its closing fence, or to the end — an unterminated fence is a
            // malformed note, and swallowing the rest as code beats emitting ``` as prose.
            if trimmed.hasPrefix("```") {
                flushAll()
                var body: [String] = []
                index += 1
                while index < lines.count,
                      !lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("```") {
                    body.append(lines[index])
                    index += 1
                }
                index += 1
                blocks.append(.code(body.joined(separator: "\n")))
                continue
            }

            // A table is a header row followed by a `|---|` separator. Checking the NEXT line is
            // what stops a lone pipe-bearing sentence becoming a one-column table.
            if trimmed.hasPrefix("|"), index + 1 < lines.count, isSeparator(lines[index + 1]) {
                flushAll()
                let headers = cells(trimmed)
                var rows: [[String]] = []
                index += 2
                while index < lines.count,
                      lines[index].trimmingCharacters(in: .whitespaces).hasPrefix("|") {
                    rows.append(cells(lines[index].trimmingCharacters(in: .whitespaces)))
                    index += 1
                }
                blocks.append(.table(headers: headers, rows: rows))
                continue
            }

            if trimmed.isEmpty {
                flushAll()
            } else if trimmed.hasPrefix("#") {
                flushAll()
                let hashes = trimmed.prefix { $0 == "#" }.count
                let text = trimmed.dropFirst(hashes).trimmingCharacters(in: .whitespaces)
                blocks.append(.heading(level: min(max(hashes, 1), 6), text: text))
            } else if trimmed == "---" || trimmed == "***" || trimmed == "___" {
                flushAll()
                blocks.append(.rule)
            } else if let item = bulletItem(trimmed) {
                flushParagraph()
                if !numbered.isEmpty { blocks.append(.numbered(numbered)); numbered = [] }
                bullets.append(item)
            } else if let item = numberedItem(trimmed) {
                flushParagraph()
                if !bullets.isEmpty { blocks.append(.bullets(bullets)); bullets = [] }
                numbered.append(item)
            } else {
                flushLists()
                paragraph.append(trimmed)
            }
            index += 1
        }
        flushAll()
        return blocks
    }

    /// `|---|:--:|` and friends — the row that turns the line above it into a header.
    static func isSeparator(_ line: String) -> Bool {
        let trimmed = line.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("|") else { return false }
        let body = trimmed.filter { !" |".contains($0) }
        return !body.isEmpty && body.allSatisfy { $0 == "-" || $0 == ":" }
    }

    static func cells(_ row: String) -> [String] {
        var trimmed = Substring(row)
        if trimmed.hasPrefix("|") { trimmed = trimmed.dropFirst() }
        if trimmed.hasSuffix("|") { trimmed = trimmed.dropLast() }
        return trimmed.components(separatedBy: "|")
            .map { $0.trimmingCharacters(in: .whitespaces) }
    }

    static func bulletItem(_ line: String) -> String? {
        for marker in ["- ", "* ", "+ "] where line.hasPrefix(marker) {
            return String(line.dropFirst(marker.count))
        }
        return nil
    }

    /// `1. ` / `12) ` — the digits are dropped because the renderer numbers the list itself, so a
    /// note whose source restarts at 1 mid-list still reads in order.
    static func numberedItem(_ line: String) -> String? {
        let digits = line.prefix { $0.isNumber }
        guard !digits.isEmpty, line.count > digits.count else { return nil }
        let rest = line.dropFirst(digits.count)
        guard rest.hasPrefix(". ") || rest.hasPrefix(") ") else { return nil }
        return String(rest.dropFirst(2))
    }

    /// Rewrite `[[wiki links]]` into markdown links so `AttributedString(markdown:)` renders them.
    ///
    /// ONLY THE ONES THAT RESOLVE. A `[[link]]` in a vault note names another note by title, and a
    /// scope composes a chain of vaults — so some targets are in this corpus and some are not. A
    /// link rendered for a target that cannot be opened is the control this project keeps writing
    /// apology cards for: it looks clickable, it is styled as reachable, and it does nothing.
    /// Unresolvable ones are therefore left EXACTLY as written, brackets included, which is honest
    /// — the note really does point at something this scope does not hold.
    ///
    /// The scheme is opaque on purpose: the view intercepts it through `openURL` rather than the
    /// system trying to find a handler for it.
    public static func linkify(_ text: String, scheme: String,
                               resolves: (String) -> Bool) -> String {
        var out = ""
        var rest = Substring(text)
        while let open = rest.range(of: "[["), let close = rest.range(of: "]]", range: open.upperBound..<rest.endIndex) {
            out += rest[rest.startIndex..<open.lowerBound]
            let target = String(rest[open.upperBound..<close.lowerBound])
            // `[[note|shown]]` — Obsidian's alias form. The link text is what a reader sees; the
            // target is what resolves.
            let parts = target.split(separator: "|", maxSplits: 1).map(String.init)
            let name = parts.first ?? target
            let shown = parts.count > 1 ? parts[1] : name
            if resolves(name), let encoded = name.addingPercentEncoding(
                withAllowedCharacters: .urlPathAllowed) {
                out += "[\(shown)](\(scheme)://\(encoded))"
            } else {
                out += "[[\(target)]]"
            }
            rest = rest[close.upperBound...]
        }
        out += rest
        return out
    }
}
