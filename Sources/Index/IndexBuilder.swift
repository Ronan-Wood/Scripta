import Foundation
import OSLog

/// Builds the retrieval index from transcript Markdown files. Chunks by speaker turn so each
/// retrievable unit is a coherent stretch of one voice. The Markdown stays the source of truth;
/// this only writes into the derived SQLite index.
enum IndexBuilder {
    private static let log = Logger(subsystem: "com.ronanwood.CallTranscriber", category: "Index")

    /// Parses one transcript file and upserts it into the index. For files that no longer parse
    /// as app transcripts (de-marked, malformed frontmatter), any existing rows are purged —
    /// otherwise old spoken text stays retrievable via search/Ask/MCP with no in-app way to
    /// remove it (the file is also invisible in the viewer).
    static func index(_ url: URL, into store: IndexStore) {
        // mtime is captured BEFORE reading the content: if the file changes mid-read we store
        // the older stamp and the next reconcile re-indexes, instead of skipping forever.
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        guard let meta = TranscriptStore.meta(of: url) else {
            store.remove(path: url.path)
            return
        }
        let content = TranscriptStore.body(of: url)

        let transcript = IndexedTranscript(
            path: url.path, title: meta.title, date: meta.date, time: meta.time,
            duration: meta.duration, participants: meta.participants, tags: meta.tags,
            summary: Indexing.summary(from: content), mtime: mtime,
            mode: meta.isConference ? "conference" : "", group: meta.group)

        let chunks = Indexing.chunks(from: content)
        store.upsert(transcript, chunks: chunks)
        // Ledger: the chunk stage is now current at this content hash. Embed/extract (Phase 4)
        // record their own stages and heal against a hash mismatch here.
        store.recordStage(path: url.path, stage: "chunk", hash: Indexing.contentHash(chunks), model: "chunker-v1")
    }

    /// Reconciles the whole output folder against the index: indexes new/changed files, drops
    /// entries whose files are gone. Safe to run on launch.
    static func reconcile(store: IndexStore) {
        let folder = AppSettings.outputFolder
        let onDisk = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        )) ?? []
        let mdFiles = onDisk.filter { $0.pathExtension == "md" }

        let start = Date()
        let indexed = store.indexedPaths()
        let livePaths = Set(mdFiles.map(\.path))

        // Remove entries whose files no longer exist.
        var removed = 0
        for path in indexed.keys where !livePaths.contains(path) {
            store.remove(path: path); removed += 1
        }
        // Index anything new or modified since it was last indexed.
        var reindexed = 0, unchanged = 0
        for url in mdFiles {
            let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                .contentModificationDate?.timeIntervalSince1970 ?? 0
            if let known = indexed[url.path], abs(known - mtime) < 0.01 { unchanged += 1; continue }
            index(url, into: store); reindexed += 1
        }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        log.info("reconcile: \(mdFiles.count) on disk, \(reindexed) indexed, \(removed) removed, \(unchanged) unchanged, \(ms)ms")
    }
}
