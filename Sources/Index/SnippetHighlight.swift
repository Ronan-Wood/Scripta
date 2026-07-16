import SwiftUI

/// Renders an FTS5 snippet's ⟦…⟧ matched spans as bold accent text, so the user can see *what*
/// matched (the term, or a prefix expansion of it) instead of a plain truncated string.
enum SnippetHighlight {
    static func attributed(_ snippet: String, accent: Color) -> AttributedString {
        var out = AttributedString()
        var buffer = ""
        var inMatch = false
        func flush() {
            guard !buffer.isEmpty else { return }
            var segment = AttributedString(buffer)
            if inMatch {
                segment.font = .body.weight(.semibold)
                segment.foregroundColor = accent
            }
            out += segment
            buffer = ""
        }
        for ch in snippet {
            switch ch {
            case "⟦": flush(); inMatch = true
            case "⟧": flush(); inMatch = false
            default: buffer.append(ch)
            }
        }
        flush()
        return out
    }

    /// Number of highlighted spans in a raw snippet — a cheap relevance signal (a single
    /// common-word match is weaker than several).
    static func spanCount(_ snippet: String) -> Int {
        snippet.reduce(0) { $1 == "⟦" ? $0 + 1 : $0 }
    }
}
