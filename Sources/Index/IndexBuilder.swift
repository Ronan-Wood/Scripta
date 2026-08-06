import Foundation
import ScriptaCore
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
    static func index(_ url: URL, into store: IndexStore, registry: EntityRegistry = EntityRegistry.shared) {
        // mtime is captured BEFORE reading the content: if the file changes mid-read we store
        // the older stamp and the next reconcile re-indexes, instead of skipping forever.
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        guard let meta = TranscriptStore.meta(of: url) else {
            store.remove(path: url.path)
            return
        }
        let content = TranscriptStore.body(of: url)

        // THE WORKSPACE IS WHERE THE FILE IS (Doc 4 §7). A transcript inside a vault belongs to that
        // vault's scope, whatever its frontmatter says; only a flat-layout transcript still answers
        // from `group:`. The index column stays — five query sites partition on it and the privacy
        // wall is built from them — but its VALUE stops being a field that can disagree with the
        // location it sits in.
        let derived = ScriptaVault.scope(forTranscriptAt: url, under: AppSettings.outputFolder)
        if let derived, !meta.group.isEmpty, derived != ScriptaVault.slug(meta.group) {
            // Reported, not reconciled: the file is not rewritten here. Location wins because it is
            // the thing the operator can see, and a stale `group:` is exactly what §7 retires — but
            // a transcript whose two answers disagree is worth knowing about, since one of them was
            // the privacy wall until this commit.
            log.error("\(url.lastPathComponent, privacy: .public) declares group '\(meta.group, privacy: .public)' but sits in the '\(derived, privacy: .public)' vault — indexing it under the vault")
        }
        // RESOLVED BACK TO THE DISPLAY NAME. The vault directory is `slug(workspace)`, and every
        // query site partitions on the raw `activeGroup` with an exact match — so storing the slug
        // would index a "CBRE" call under "cbre" and hide it from search, Ask, entity pages and
        // Related while it still appeared in the browse list, which reads frontmatter. The slug says
        // WHICH workspace; the name is what the rest of the row is keyed by.
        //
        // Falling back to the slug when no known workspace matches is deliberate: a vault whose
        // workspace has been renamed or removed from settings still has to index as something
        // stable, and the slug is what its own directory says. That row is then reachable by
        // selecting the workspace again, which restores the mapping.
        let group = derived.map { AppSettings.workspaceName(forSlug: $0, preferring: meta.group) ?? $0 }
            ?? meta.group

        // Strip NUL/control chars so sqlite3_bind_text (strlen-based) can't truncate the indexed text
        // at an embedded NUL — screen-context OCR of a broken glyph can emit one, the same class the
        // v11 rebuild fixed for the document/note paths (audit L2).
        let transcript = IndexedTranscript(
            path: url.path, title: meta.title, date: meta.date, time: meta.time,
            duration: meta.duration, participants: meta.participants, tags: meta.tags,
            summary: Indexing.stripControlChars(Indexing.summary(from: content)), mtime: mtime,
            mode: meta.isConference ? "conference" : "", group: group,
            // The full file, verbatim, so the MCP serves get_transcript byte-exact off the index.
            body: Indexing.stripControlChars(content))

        // Spoken chunks + on-screen text (marked "Screen") — both searchable + embeddable now.
        let chunks = (Indexing.chunks(from: content) + Indexing.screenChunks(from: content)).map {
            IndexedChunk(startMs: $0.startMs, endMs: $0.endMs, speaker: $0.speaker,
                         text: Indexing.stripControlChars($0.text))
        }
        // Commitments (M17): "<owner>: <text>" frontmatter entries, split on the first ": ".
        // "you" is a sentinel, not a trackable identity; any other owner resolves ONLY against a
        // CONFIRMED person (resolveConfirmed never allocates) — an FM's unreviewed guess at a
        // name must not mint a new permanent registry entity, per the ratified design (SPEC M17).
        // Falls back to the raw surface string when nothing confirmed matches, same as the spec's
        // own fallback — the commitment is still shown, just not tied to a tracked identity.
        // A trailing " [done]" (written by TranscriptMetadataEditor.markCommitmentDone) is status,
        // stripped before the owner/text split — round-tripped through frontmatter, not the DB
        // alone, since re-indexing rebuilds this table from scratch on every reconcile/metadata
        // edit and a DB-only status would silently revert.
        let actionItems: [IndexedActionItem] = meta.commitments.compactMap { rawLine in
            var line = rawLine
            let done = line.hasSuffix(" [done]")
            if done { line.removeLast(" [done]".count) }
            guard let range = line.range(of: ": ") else { return nil }
            let owner = Indexing.stripControlChars(String(line[..<range.lowerBound]).trimmingCharacters(in: .whitespaces))
            let text = Indexing.stripControlChars(String(line[range.upperBound...]).trimmingCharacters(in: .whitespaces))
            guard !owner.isEmpty, !text.isEmpty else { return nil }
            let ownerID = EntityRegistry.resolveCommitmentOwner(owner, group: group)
            return IndexedActionItem(ownerID: ownerID, text: text, status: done ? "done" : "open")
        }
        store.upsert(transcript, chunks: chunks, actionItems: actionItems)
        let hash = Indexing.contentHash(chunks)
        store.recordStage(path: url.path, stage: "chunk", hash: hash, model: "chunker-v1")

        // Entity extraction (deterministic: NLTagger + calendar attendees → registry → cache).
        // Ledger-gated: only re-runs when the derived content changed. The registry is the identity
        // system-of-record; the entity/mention tables are a cache resolved from it.
        if store.stageHash(path: url.path, stage: "extract") != hash {
            extractEntities(url: url, group: group, attendees: meta.participants, chunks: chunks, store: store, registry: registry)
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
        var wrote = false
        for path in store.indexedPaths().keys {
            guard let current = store.stageHash(path: path, stage: "chunk"),
                  store.stageHash(path: path, stage: "embed") != current else { continue }
            let rows = store.chunkRows(path: path)
            guard !rows.isEmpty, let vectors = await Embedder.embedDocuments(rows.map(\.text)),
                  vectors.count == rows.count else { continue }
            for (row, vec) in zip(rows, vectors) { store.storeVector(chunkID: row.id, vector: vec, model: model) }
            store.recordStage(path: path, stage: "embed", hash: current, model: model)
            wrote = true
        }
        // Vectors are large (a Float array per chunk); truncate the WAL once the batch settles.
        if wrote { store.checkpoint() }
    }

    private static func extractEntities(url: URL, group: String, attendees: [String],
                                        chunks: [IndexedChunk], store: IndexStore,
                                        registry: EntityRegistry) {
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
        let all = registry.allEntities()   // one locked snapshot, then scan it lock-free
        for id in Set(resolved.map(\.entityID)) {
            if let e = all.first(where: { $0.id == id }) { ents.append((e.id, e.name, e.kind)) }
        }
        store.setEntities(ents, mentions: url.path, resolved)
    }

    /// Reconciles the whole output folder against the index: indexes new/changed files, drops
    /// entries whose files are gone. Safe to run on launch.
    /// Mirrors vocabulary terms from the registry (system of record) into the index DB — the
    /// cache the retrieval layer and the MCP server read for alias expansion and glosses.
    /// One row per (term, group membership).
    static func syncTerms(store: IndexStore, registry: EntityRegistry = EntityRegistry.shared) {
        let rows = registry.allEntities()
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
    /// "summary", so topic fusion surfaces it in Ask context and MCP retrieve. Also
    /// entity-extracted, one chunk per entry (M20) — notes are the brain's freeform half, and a
    /// note mentioning someone must land on their entity page the same as a call does, or the
    /// graph has a hole exactly where freeform capture (Quick Capture, M14) put it. No real
    /// per-entry clock exists the way a call has one, so startMs/endMs are 0 — chunking by entry
    /// is for extraction locality (keeps NLTagger's input reasonably sized), not jump-to-timestamp.
    static func indexNote(_ url: URL, into store: IndexStore, registry: EntityRegistry = EntityRegistry.shared) {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        guard let note = NoteStore.parse(url) else {
            store.remove(path: url.path)
            return
        }
        let entriesText = Indexing.stripControlChars(note.entries
            .map { entry in entry.linkedCall.map { "[\(entry.stamp), re: \($0)] \(entry.text)" } ?? "[\(entry.stamp)] \(entry.text)" }
            .joined(separator: "\n"))
        store.upsert(IndexedTranscript(
            path: url.path, title: note.title, date: String(note.updated.prefix(10)), time: "",
            duration: "", participants: [], tags: [], summary: entriesText, mtime: mtime,
            mode: "", group: note.group, kind: "note"), chunks: [])

        let chunks = note.entries.map {
            IndexedChunk(startMs: 0, endMs: 0, speaker: nil, text: Indexing.stripControlChars($0.text))
        }
        let hash = Indexing.contentHash(chunks)
        if store.stageHash(path: url.path, stage: "extract") != hash {
            extractEntities(url: url, group: note.group, attendees: [], chunks: chunks, store: store, registry: registry)
            store.recordStage(path: url.path, stage: "extract", hash: hash, model: "nltagger-v1")
        }
    }

    /// Indexes one imported document's companion note as `kind: 'doc'` — retrievable by search,
    /// Clovis, and the MCP; invisible to every call surface. Extracted text is the searchable
    /// body. Also entity-extracted as a single chunk (M20) — same reasoning as `indexNote`, but a
    /// document has no entry structure to split on.
    static func indexDoc(_ url: URL, into store: IndexStore, registry: EntityRegistry = EntityRegistry.shared) {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate?.timeIntervalSince1970 ?? 0
        guard let doc = DocumentImporter.parse(url) else {
            store.remove(path: url.path)
            return
        }
        // Strip control chars (a NUL from a broken PDF glyph would truncate the FTS bind at strlen).
        let cleanBody = Indexing.stripControlChars(doc.body)
        store.upsert(IndexedTranscript(
            path: url.path, title: doc.title, date: String(doc.created.prefix(10)), time: "",
            duration: "", participants: [], tags: [], summary: String(cleanBody.prefix(60_000)),
            mtime: mtime, mode: "", group: doc.group, kind: "doc"), chunks: [])

        // Unlike the summary above, extraction runs over the FULL body, not the 60k-char
        // preview — a mention past that point should still land the doc on the person's page.
        let chunks = [IndexedChunk(startMs: 0, endMs: 0, speaker: nil, text: cleanBody)]
        let hash = Indexing.contentHash(chunks)
        if store.stageHash(path: url.path, stage: "extract") != hash {
            extractEntities(url: url, group: doc.group, attendees: [], chunks: chunks, store: store, registry: registry)
            store.recordStage(path: url.path, stage: "extract", hash: hash, model: "nltagger-v1")
        }
    }

    /// One directory's markdown, or the fact that it could not be read.
    ///
    /// THE DISTINCTION IS THE WHOLE POINT, because `reconcile` deletes every indexed path it does
    /// not find on disk. `(try? contentsOfDirectory) ?? []` reported an unreadable folder as an
    /// EMPTY one, so a single failed listing of the output folder removed every row in the index —
    /// every transcript, note and document — and the next pass would re-index only what it could
    /// then see. The entity cache prunes itself off those removals, so the loss reached further
    /// than the rows.
    ///
    /// It is not a hypothetical path. `AppSettings.outputFolder` is a user-chosen directory that on
    /// this machine sits in OneDrive, and reading it returned EPERM twice in one session on
    /// 2026-08-05 under an ordinary TCC state. Unmounted volumes and revoked folder grants reach
    /// the same branch.
    private enum Listing {
        case files([URL])
        /// The listing failed. NOT an empty folder — absent evidence is not evidence of absence,
        /// which is the rule `refresh.frozen` encodes on the engine side and the one this type
        /// carries here.
        case unreadable(String)

        /// What was found, or nothing. Safe for the ADDITIVE half of a pass, which cannot lose
        /// data by seeing too little; never sufficient for the destructive half.
        var files: [URL] {
            if case .files(let urls) = self { return urls }
            return []
        }

        var failure: String? {
            if case .unreadable(let why) = self { return why }
            return nil
        }
    }

    /// `mustExist` separates a folder whose absence is NORMAL from one whose absence is evidence
    /// something is wrong. `Notes/` and `Files/` are created lazily on first write, so a fresh
    /// install genuinely has none and that is zero notes. The output folder is configured by the
    /// user and created up front: its disappearance means the volume or the grant went away, never
    /// that the user deleted every call.
    private static func mdFiles(in folder: URL, mustExist: Bool) -> Listing {
        do {
            let urls = try FileManager.default.contentsOfDirectory(
                at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
                options: [.skipsHiddenFiles])
            return .files(urls.filter { $0.pathExtension == "md" })
        } catch let error as NSError where !mustExist
                    && error.domain == NSCocoaErrorDomain
                    && error.code == NSFileReadNoSuchFileError {
            return .files([])
        } catch {
            return .unreadable("\(folder.lastPathComponent): \(error.localizedDescription)")
        }
    }

    /// THE FAILURE THIS CLOSES, recorded where the removal happens. `Listing` already refuses to
    /// treat an unreadable folder as an empty one — but a vaults root is READABLE and holds no
    /// `.md` at all, because scope directories have no extension and the `.md` filter dropped them.
    /// The listing succeeded with zero files, the guard never fired, and every indexed row was
    /// removed on the first pass after a migration. Reachable at launch and on every 2-second
    /// watcher fire, which is why this landed BEFORE any file moved rather than after.
    ///
    /// Discovery lives in `ScriptaVault.transcriptLocations` so it can be tested; this file is in
    /// the app target and `swift test` cannot reach it.
    static func reconcile(store: IndexStore) {
        // One registry snapshot for the whole pass: a mid-pass folder change must not split the
        // pass across two registries (old-vault names contaminating the new vault's file).
        let registry = EntityRegistry.shared
        // CAPTURED ONCE, like the registry above and for the same reason this file already states:
        // this global is switchable. Read again per-iteration, a vault switch mid-pass would let the
        // OLD root fall to `mustExist: false`, turn its `NSFileReadNoSuchFileError` into
        // `.files([])` instead of `.unreadable`, leave `unreadable` empty — and run the removal
        // branch against a lower bound, stripping every row.
        let outputFolder = AppSettings.outputFolder
        let (locations, discoveryFailures) = ScriptaVault.transcriptLocations(under: outputFolder)
        var transcripts: [URL] = []
        var unreadable = discoveryFailures
        for location in locations {
            // `mustExist` FOR EVERY LOCATION, not just the root. A vault only appears in `locations`
            // because it carries a manifest this app wrote, and `ScriptaVault.write()` always
            // creates `_sources/transcripts` — so that directory being absent means it was REMOVED,
            // which is the "volume or grant went away" case the root is already protected against.
            // Read as "no calls yet", a vault whose subtree lost its grant had every one of its
            // transcripts deleted from the index.
            let listing = mdFiles(in: location, mustExist: true)
            transcripts += listing.files
            if let failure = listing.failure { unreadable.append(failure) }
        }
        let noteListing = mdFiles(in: NoteStore.folder, mustExist: false)
        let docListing = mdFiles(in: DocumentImporter.folder, mustExist: false)
        let notes = noteListing.files
        let docs = docListing.files
        unreadable += [noteListing, docListing].compactMap(\.failure)

        let start = Date()
        let indexed = store.indexedPaths()
        let livePaths = Set((transcripts + notes + docs).map(\.path))

        // Remove entries whose files no longer exist — ONLY when EVERY listing succeeded, across
        // both layouts and every vault.
        //
        // The removal is the half that needs COMPLETE knowledge: "not on disk" is only a fact if
        // every place the file could be was actually read. One unreadable folder makes the live set
        // a lower bound, and deleting against a lower bound deletes rows whose files are fine.
        //
        // The additive half below still runs on whatever WAS readable, and that asymmetry is
        // deliberate. Refusing the whole pass would mean a transient permission blip stops the
        // index updating until someone notices; indexing too little is recoverable on the next
        // pass, deleting too much is not.
        var removed = 0
        if let why = unreadable.first {
            log.error("reconcile: skipping removals — \(unreadable.count) folder(s) unreadable (\(why, privacy: .public)). The index keeps rows whose files could not be listed; they are not evidence of deletion.")
        } else {
            for path in indexed.keys where !livePaths.contains(path) {
                store.remove(path: path); removed += 1
            }
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
        sweep(transcripts) { index($0, into: $1, registry: registry) }
        sweep(notes) { indexNote($0, into: $1, registry: registry) }
        sweep(docs) { indexDoc($0, into: $1, registry: registry) }
        let ms = Int(Date().timeIntervalSince(start) * 1000)
        log.info("reconcile: \(transcripts.count)+\(notes.count)+\(docs.count) on disk, \(reindexed) indexed, \(removed) removed, \(unchanged) unchanged, \(ms)ms")

        // End of the write pass: fold this pass's writes out of the WAL and truncate it, so the -wal file
        // can't grow across passes and slow the read-only MCP opener. Only when the pass actually wrote.
        // Prune orphaned entity-cache rows before the checkpoint: removals happen both in the
        // loop above AND inside the sweeps (files that stop parsing call store.remove; a re-index
        // can drop a path's last mention) — so the trigger must include reindexed. Covers every
        // removal flow (retention, external deletes, vault switches); the wipe prunes for itself.
        if reindexed > 0 || removed > 0 {
            store.pruneOrphanedEntities()
            store.checkpoint()
        }
    }
}
