import Foundation

/// Builds FTS5 MATCH expressions from free text. The single source of truth for query building,
/// compiled into the app (`IndexStore`), the MCP server, and the eval harness — so the three can
/// never drift (they used to hold verbatim copies).
///
/// Two-pass strategy: an implicit-AND expression is near-precise for multi-word queries (the
/// dominant shape in search and Ask); the OR expression is the recall floor when AND finds
/// nothing. Stopwords are dropped so BM25 ranks on content terms, not function words — this is
/// deterministic query rewriting, not LLM expansion.
enum FTSQuery {
    /// ~100 common English function words. Dropping them stops "the"*/"with"* from matching
    /// nearly every chunk and dominating the OR-sum BM25 score.
    static let stopwords: Set<String> = [
        "a", "about", "above", "after", "again", "all", "am", "an", "and", "any", "are", "as",
        "at", "be", "because", "been", "before", "being", "below", "between", "both", "but", "by",
        "can", "could", "did", "do", "does", "doing", "down", "during", "each", "few", "for",
        "from", "further", "had", "has", "have", "having", "he", "her", "here", "hers", "him",
        "his", "how", "if", "in", "into", "is", "it", "its", "just", "let", "me", "more", "most",
        "my", "no", "nor", "not", "now", "of", "off", "on", "once", "only", "or", "other", "our",
        "out", "over", "own", "really", "same", "she", "should", "so", "some", "such", "than",
        "that", "the", "their", "them", "then", "there", "these", "they", "think", "this", "those",
        "through", "to", "too", "under", "until", "up", "very", "was", "we", "were", "what", "when",
        "where", "which", "while", "who", "whom", "why", "will", "with", "would", "you", "your",
    ]

    /// Content terms: lowercased, split on non-alphanumerics, ≥2 chars, stopwords removed,
    /// de-duplicated, capped to the 10 longest. If removing stopwords empties the query (e.g.
    /// "what about it"), the originals are kept so the query still returns something.
    static func terms(_ raw: String) -> [String] {
        let all = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        guard !all.isEmpty else { return [] }

        var content = all.filter { !stopwords.contains($0) }
        if content.isEmpty { content = all }   // keep-originals fallback

        var seen = Set<String>()
        var unique = [String]()
        for term in content where seen.insert(term).inserted { unique.append(term) }
        if unique.count > 10 {
            unique = Array(unique.sorted { $0.count > $1.count }.prefix(10))
        }
        return unique
    }

    /// Implicit-AND of quoted prefix terms — `"budget"* "review"* "sarah"*`. Precise. nil if empty.
    static func andExpression(_ raw: String) -> String? {
        let t = terms(raw)
        guard !t.isEmpty else { return nil }
        return t.map { "\"\($0)\"*" }.joined(separator: " ")
    }

    /// OR of quoted prefix terms — the recall floor. nil if empty.
    static func orExpression(_ raw: String) -> String? {
        let t = terms(raw)
        guard !t.isEmpty else { return nil }
        return t.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }

    /// The pre-overhaul behaviour: OR over every ≥2-char term with no stopword filtering. Kept
    /// only so the eval harness can measure the before/after of the AND-first + stopword change.
    static func legacyOr(_ raw: String) -> String? {
        let all = raw.lowercased()
            .components(separatedBy: CharacterSet.alphanumerics.inverted)
            .filter { $0.count >= 2 }
        guard !all.isEmpty else { return nil }
        return all.map { "\"\($0)\"*" }.joined(separator: " OR ")
    }
}
