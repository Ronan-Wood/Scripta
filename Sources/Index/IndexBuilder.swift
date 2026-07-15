import Foundation

/// Builds the retrieval index from transcript Markdown files. Chunks by speaker turn so each
/// retrievable unit is a coherent stretch of one voice. The Markdown stays the source of truth;
/// this only writes into the derived SQLite index.
enum IndexBuilder {

    /// Parses one transcript file and upserts it into the index. No-op for non-app files.
    static func index(_ url: URL, into store: IndexStore) {
        guard let meta = TranscriptStore.meta(of: url) else { return }
        let content = TranscriptStore.body(of: url)
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0

        let transcript = IndexedTranscript(
            path: url.path, title: meta.title, date: meta.date, time: meta.time,
            duration: meta.duration, participants: meta.participants, tags: meta.tags,
            summary: extractSummary(content), mtime: mtime)

        store.upsert(transcript, chunks: chunks(from: content))
    }

    /// Reconciles the whole output folder against the index: indexes new/changed files, drops
    /// entries whose files are gone. Safe to run on launch.
    static func reconcile(store: IndexStore) {
        let folder = AppSettings.outputFolder
        let onDisk = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        let mdFiles = onDisk.filter { $0.pathExtension == "md" }

        let indexed = store.indexedPaths()
        let livePaths = Set(mdFiles.map(\.path))

        // Remove entries whose files no longer exist.
        for path in indexed.keys where !livePaths.contains(path) {
            store.remove(path: path)
        }
        // Index anything new or modified since it was last indexed.
        for url in mdFiles {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            if let known = indexed[url.path], abs(known - mtime) < 1 { continue }
            index(url, into: store)
        }
    }

    // MARK: - Chunking

    /// Groups transcript lines into retrievable chunks: a new chunk starts when the speaker
    /// changes, or when the running chunk grows past a size or time budget. The budgets keep
    /// unlabeled or monologue-heavy calls from collapsing into one enormous chunk (which would
    /// give BM25 nothing to rank and produce useless snippets/timestamps).
    private static let maxChunkChars = 500
    private static let maxChunkMs = 45_000

    private static func chunks(from content: String) -> [IndexedChunk] {
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
    private static func parseStamp(_ stamp: String) -> Int? {
        let digits = stamp.trimmingCharacters(in: CharacterSet(charactersIn: "[]"))
        let parts = digits.split(separator: ":").compactMap { Int($0) }
        guard !parts.isEmpty else { return nil }
        let seconds = parts.reduce(0) { $0 * 60 + $1 }
        return seconds * 1000
    }

    /// Pulls the "## Summary" section text (if any) for the transcript-level row.
    private static func extractSummary(_ content: String) -> String {
        guard let range = content.range(of: "## Summary") else { return "" }
        let after = content[range.upperBound...]
        // Up to the next blank-line-separated section header or timestamp line.
        var lines: [String] = []
        for line in after.split(separator: "\n", omittingEmptySubsequences: false).dropFirst() {
            let t = line.trimmingCharacters(in: .whitespaces)
            if t.hasPrefix("#") || t.hasPrefix("**[") { break }
            lines.append(t)
        }
        return lines.joined(separator: " ").trimmingCharacters(in: .whitespaces)
    }
}
