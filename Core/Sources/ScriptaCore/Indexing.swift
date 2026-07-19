import Foundation
import ScriptaShared
import CryptoKit

/// Transcript → index derivation: speaker-turn chunking and summary extraction. Shared so the
/// app's `IndexBuilder` and the eval harness produce identical index rows from the same Markdown.
public enum Indexing {
    /// Removes NUL and other C0/DEL control characters (keeping tab + newline). Broken PDF glyph
    /// or ligature mappings emit NUL bytes; `sqlite3_bind_text(…, -1, …)` uses strlen and would
    /// truncate the indexed text at the first NUL — silently indexing only a fragment. Stripping
    /// them also keeps FTS tokenization clean. Lives here (not on the app's document importer)
    /// because it guards every FTS bind path.
    public static func stripControlChars(_ s: String) -> String {
        String(s.unicodeScalars.filter { scalar in
            scalar == "\n" || scalar == "\t" || (scalar.value >= 0x20 && scalar.value != 0x7F)
        })
    }

    /// Content hash for the enrichment ledger, taken over the DERIVED chunks (not the raw file).
    /// So a frontmatter edit (title / group / tag) never invalidates chunks/embeddings/entities,
    /// but a body edit (a user ASR fix in Obsidian) does — which is exactly when re-enrich is due.
    public static func contentHash(_ chunks: [IndexedChunk]) -> String {
        let joined = chunks.map { "\($0.startMs):\($0.speaker ?? ""):\($0.text)" }.joined(separator: "\n")
        return SHA256.hash(data: Data(joined.utf8)).map { String(format: "%02x", $0) }.joined()
    }

    /// Budgets keep unlabeled/monologue calls from collapsing into one enormous chunk (which would
    /// give BM25 nothing to rank and produce useless snippets/timestamps).
    public static let maxChunkChars = 500
    public static let maxChunkMs = 45_000

    /// Groups transcript audio lines into retrievable chunks: a new chunk starts when the speaker
    /// changes, or when the running chunk passes a size/time budget.
    public static func chunks(from content: String) -> [IndexedChunk] {
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
    public static func parseStamp(_ stamp: String) -> Int? {
        let digits = stamp.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = digits.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        return seconds * 1000
    }

    /// Chunks the "## Screen Context" section so on-screen text becomes searchable + embeddable
    /// (it's captured today but invisible to retrieval). Marked speaker "Screen" so retrieval
    /// provenance distinguishes what was shown from what was said. Each captured entry is one chunk.
    public static func screenChunks(from content: String) -> [IndexedChunk] {
        guard let range = content.range(of: "## Screen Context") else { return [] }
        let section = String(content[range.upperBound...])
        var chunks: [IndexedChunk] = []
        for entry in section.components(separatedBy: "\n\n---\n\n") {
            let trimmed = entry.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmed.isEmpty else { continue }
            var startMs = 0
            var text = trimmed
            // Entries are "**[m:ss]**\n\n<ocr text>".
            if trimmed.hasPrefix("**["), let close = trimmed.range(of: "]**") {
                let stamp = String(trimmed[trimmed.index(trimmed.startIndex, offsetBy: 3)..<close.lowerBound])
                startMs = parseStamp(stamp) ?? 0
                text = String(trimmed[close.upperBound...]).trimmingCharacters(in: .whitespacesAndNewlines)
            }
            if !text.isEmpty { chunks.append(IndexedChunk(startMs: startMs, endMs: startMs, speaker: "Screen", text: text)) }
        }
        return chunks
    }

    /// Pulls the "## Summary" section text (if any) for the transcript-level row.
    public static func summary(from content: String) -> String {
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
