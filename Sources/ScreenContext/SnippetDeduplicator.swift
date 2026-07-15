import Foundation

/// Decides whether a freshly-read screen differs enough from the last kept one to be worth
/// persisting. Uses Jaccard similarity over normalized line sets rather than an exact hash,
/// so trivial churn (clocks, unread badges, blinking cursors) doesn't register as a new
/// screen. Comparison ignores structure; the original text (including Markdown tables) is
/// returned untouched when a capture is kept.
final class SnippetDeduplicator {
    /// Persist a capture only when its similarity to the last kept one is below this.
    private let keepBelowSimilarity: Double
    private var previousLines: Set<String> = []

    init(keepBelowSimilarity: Double = 0.85) {
        self.keepBelowSimilarity = keepBelowSimilarity
    }

    /// Returns the text to persist if the screen changed meaningfully, else nil.
    func consider(_ text: String) -> String? {
        let current = Set(comparisonLines(text))
        guard !current.isEmpty else { return nil }

        let similarity = jaccard(current, previousLines)
        guard similarity < keepBelowSimilarity else { return nil }

        previousLines = current
        return text
    }

    // MARK: - Helpers

    /// Lines used only for the similarity comparison — trimmed, with tiny fragments and
    /// pure clock/counter lines dropped.
    private func comparisonLines(_ text: String) -> [String] {
        text.split(separator: "\n")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { $0.count > 2 && !isNoise($0) }
    }

    /// True for lines that are just clocks, counters, or numeric badges — the churny bits.
    private func isNoise(_ line: String) -> Bool {
        let stripped = line.filter { !$0.isWhitespace }
        guard !stripped.isEmpty else { return true }
        return stripped.allSatisfy { $0.isNumber || $0 == ":" || $0 == "." || $0 == "%" || $0 == "+" || $0 == "/" || $0 == "-" }
    }

    private func jaccard(_ a: Set<String>, _ b: Set<String>) -> Double {
        if a.isEmpty && b.isEmpty { return 1 }
        let union = a.union(b).count
        guard union > 0 else { return 1 }
        return Double(a.intersection(b).count) / Double(union)
    }
}
