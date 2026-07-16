import Foundation

/// Transcript → index derivation: speaker-turn chunking and summary extraction. Shared so the
/// app's `IndexBuilder` and the eval harness produce identical index rows from the same Markdown.
enum Indexing {
    /// Budgets keep unlabeled/monologue calls from collapsing into one enormous chunk (which would
    /// give BM25 nothing to rank and produce useless snippets/timestamps).
    static let maxChunkChars = 500
    static let maxChunkMs = 45_000

    /// Groups transcript audio lines into retrievable chunks: a new chunk starts when the speaker
    /// changes, or when the running chunk passes a size/time budget.
    static func chunks(from content: String) -> [IndexedChunk] {
        var chunks: [IndexedChunk] = []
        var startMs = 0
        var lastMs = 0
        var speaker: String?? = .none   // .none = nothing buffered yet
        var buffer = ""

        func flush() {
            let t = buffer.trimmingCharacters(in: .whitespacesAndNewlines)
            if !t.isEmpty {
                chunks.append(IndexedChunk(startMs: startMs, endMs: lastMs, speaker: speaker ?? nil, text: t))
            }
            buffer = ""
        }

        for block in TranscriptParser.parse(content) {
            guard case let .audioLine(stamp, lineSpeaker, lineText) = block else { continue }
            let ms = parseStamp(stamp) ?? lastMs

            let speakerChanged = !buffer.isEmpty && lineSpeaker != (speaker ?? nil)
            let overBudget = !buffer.isEmpty && (buffer.count >= maxChunkChars || ms - startMs >= maxChunkMs)
            if speakerChanged || overBudget { flush() }

            if buffer.isEmpty { startMs = ms; speaker = .some(lineSpeaker) }
            lastMs = ms
            buffer += buffer.isEmpty ? lineText : " " + lineText
        }
        flush()
        return chunks
    }

    /// "[0:05]" / "[1:23:45]" → milliseconds.
    static func parseStamp(_ stamp: String) -> Int? {
        let digits = stamp.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = digits.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        return seconds * 1000
    }

    /// Pulls the "## Summary" section text (if any) for the transcript-level row.
    static func summary(from content: String) -> String {
        guard let range = content.range(of: "## Summary") else { return "" }
        let after = content[range.upperBound...]
        var lines: [String] = []
        for line in after.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") || t.hasPrefix("**[") { break }
            lines.append(t)
        }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
