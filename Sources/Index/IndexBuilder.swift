import Foundation

/// Builds the retrieval index from transcript Markdown files. Chunks by speaker turn so each
/// retrievable unit is a coherent stretch of one voice. The Markdown stays the source of truth;
/// this only writes into the derived SQLite index.
enum IndexBuilder {

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
            summary: Indexing.summary(from: content), mtime: mtime)

        store.upsert(transcript, chunks: Indexing.chunks(from: content))
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
            if let known = indexed[url.path], abs(known - mtime) < 0.01 { continue }
            index(url, into: store)
        }
    }
}
