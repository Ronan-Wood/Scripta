import Foundation
import OSLog

/// Builds the retrieval index from transcript Markdown files. Chunks by speaker turn so each
/// retrievable unit is a coherent stretch of one voice. The Markdown stays the source of truth;
/// this only writes into the derived SQLite index.
enum IndexBuilder {
    private static let log = Logger(subsystem: "com.ronanwood.Scripta", category: "Index")

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

        // Spoken chunks + on-screen text (marked "Screen") — both searchable + embeddable now.
        let chunks = Indexing.chunks(from: content) + Indexing.screenChunks(from: content)
        store.upsert(transcript, chunks: chunks)
        let hash = Indexing.contentHash(chunks)
        store.recordStage(path: url.path, stage: "chunk", hash: hash, model: "chunker-v1")

        // Entity extraction (deterministic: NLTagger + calendar attendees → registry → cache).
        // Ledger-gated: only re-runs when the derived content changed. The registry is the identity
        // system-of-record; the entity/mention tables are a cache resolved from it.
        if store.stageHash(path: url.path, stage: "extract") != hash {
            extractEntities(url: url, group: meta.group, attendees: meta.participants, chunks: chunks, store: store)
            store.recordStage(path: url.path, stage: "extract", hash: hash, model: "nltagger-v1")
        }
    }

    /// Best-effort semantic embedding pass (Phase B). No-op unless a local embedder is configured.
    /// Ledger-gated per transcript so it only (re)embeds what changed; batched to respect the
    /// endpoint's one-in-flight limit. Enforces embed-version discipline first.
    static func embedPending(store: IndexStore) async {
        guard Embedder.isConfigured else { return }
        let model = Embedder.model
        store.dropVectors(keepingModel: model)   // a model change invalidates the whole space
        for path in store.indexedPaths().keys {
            guard let current = store.stageHash(path: path, stage: "chunk"),
                  store.stageHash(path: path, stage: "embed") != current else { continue }
            let rows = store.chunkRows(path: path)
            guard !rows.isEmpty, let vectors = await Embedder.embedDocuments(rows.map(\.text)),
                  vectors.count == rows.count else { continue }
            for (row, vec) in zip(rows, vectors) { store.storeVector(chunkID: row.id, vector: vec, model: model) }
            store.recordStage(path: path, stage: "embed", hash: current, model: model)
        }
    }

    private static func extractEntities(url: URL, group: String, attendees: [String],
                                        chunks: [IndexedChunk], store: IndexStore) {
        let registry = EntityRegistry.shared
        var resolved: [(entityID: String, startMs: Int, surface: String)] = []
        for m in EntityExtractor.mentions(chunks: chunks, attendees: attendees) {
            let id = registry.resolve(surface: m.surface, kind: m.kind, group: group)
            resolved.append((id, m.startMs, m.surface))
        }
        // Participants are user/calendar-provided ground truth → confirm them, so their names feed
        // ASR (contextualStrings) on future calls in this workspace. The self-reinforcing loop.
        for name in attendees where !name.isEmpty { registry.confirm(surface: name, group: group) }
        registry.save()
        var ents: [(id: String, name: String, kind: String)] = []
        for id in Set(resolved.map(\.entityID)) {
            if let e = registry.entities.first(where: { $0.id == id }) { ents.append((e.id, e.name, e.kind)) }
        }
        store.setEntities(ents, mentions: url.path, resolved)
    }

    /// Reconciles the whole output folder against the index: indexes new/changed files, drops
    /// entries whose files are gone. Safe to run on launch.
    /// Mirrors vocabulary terms from the registry (system of record) into the index DB — the
    /// cache the retrieval layer and the MCP server read for alias expansion and glosses.
    /// One row per (term, group membership).
    static func syncTerms(store: IndexStore) {
        let rows = EntityRegistry.shared.entities
            .filter { $0.kind == "term" }
            .flatMap { entity in
                entity.groups.map { group in
                    IndexStore.TermRow(id: entity.id, canonical: entity.name,
                                       aliases: entity.aliases, gloss: entity.gloss ?? "", group: group)
                }
            }
        store.setTerms(rows)
    }

    /// Indexes one knowledge note (schema v8): the note's entries become its searchable
    /// "summary", so topic fusion surfaces it in Ask context and MCP retrieve. No chunks, no
    /// ledger, no entity pass — notes are the user's own words, already curated.
    static func indexNote(_ url: URL, into store: IndexStore) {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        guard let note = NoteStore.parse(url) else {
            store.remove(path: url.path)
            return
        }
        let entriesText = note.entries
            .map { entry in entry.linkedCall.map { "[\(entry.stamp), re: \($0)] \(entry.text)" } ?? "[\(entry.stamp)] \(entry.text)" }
            .joined(separator: "\n")
        store.upsert(IndexedTranscript(
            path: url.path, title: note.title, date: String(note.updated.prefix(10)), time: "",
            duration: "", participants: [], tags: [], summary: entriesText, mtime: mtime,
            mode: "", group: note.group, kind: "note"), chunks: [])
    }

    static func reconcile(store: IndexStore) {
        func mdFiles(in folder: URL) -> [URL] {
            ((try? FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
            )) ?? []).filter { $0.pathExtension == "md" }
        }
        let transcripts = mdFiles(in: AppSettings.outputFolder)
        let notes = mdFiles(in: NoteStore.folder)

        let start = Date()
        let indexed = store.indexedPaths()
        let livePaths = Set((transcripts + notes).map(\.path))

        // Remove entries whose files no longer exist.
        var removed = 0
        for path in indexed.keys where !livePaths.contains(path) {
            store.remove(path: path); removed += 1
        }
        // Index anything new or modified since it was last indexed.
        var reindexed = 0, unchanged = 0
        func sweep(_ urls: [URL], _ indexOne: (URL, IndexStore) -> Void) {
            for url in urls {
                let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
                    .contentModificationDate?.timeIntervalSince1970 ?? 0
                if let known = indexed[url.path], abs(known - mtime) < 0.01 { unchanged += 1; continue }
                indexOne(url, store); reindexed += 1
            }
        }
        sweep(transcripts, index)
        sweep(notes, indexNote)
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        log.info("reconcile: \(transcripts.count)+\(notes.count) on disk, \(reindexed) indexed, \(removed) removed, \(unchanged) unchanged, \(ms)ms")
    }
}
