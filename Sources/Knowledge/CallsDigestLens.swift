import SwiftUI
import ScriptaCore

/// One commitment, resolved to a display-ready owner name (M17). Grouping/keying uses `ownerID`,
/// never `ownerName` — two different people can share a display name, and merging their
/// commitments under one name silently misattributes them (crosscheck finding). `path` is the
/// owning call's file — needed to mark the commitment done.
struct CommitmentDisplay: Identifiable {
    let id: String
    let path: String
    let ownerID: String
    let ownerName: String
    let isYou: Bool
    let text: String
    let callTitle: String
}

/// Which entity's page (M19) is open, plus the name to show if the id never resolves to a real
/// registry entity (M17's commitment-owner fallback can pass a raw surface string as the id).
/// Not `private` (M21) — TranscriptDetail presents EntityDetailView too now (participant clicks),
/// and needs the same small target type rather than a near-duplicate of its own.
struct EntitySheetTarget: Identifiable {
    let id: String
    var fallbackName: String? = nil
}

/// What was said across your calls: a day-grouped digest of every call's generated note (title,
/// summary, topics, people), with the workspace's people and topics alongside — all served from the
/// index, so it opens instantly and never re-reads transcript files. Comments (the "add on" layer)
/// attach per call via NoteStore.
///
/// WAS THE `Knowledge` SECTION. Doc 4 §2's "Knowledge splits" is two moves, and this is the second:
/// the vault lens went to the Library, which is the surface that WRITES a scope and now also reads
/// what it holds; everything left is an aggregate over the LOCAL call index, which is what Calls
/// already is. Doc 4 §5 keeps these surfaces app-side deliberately — they are backed by `confirmed`
/// and `groups`, the two fields the engine's identity layer does not carry — so this is a fold, not
/// a deletion pending an engine equivalent.
///
/// This type owns the lens's state and everything that loads or mutates it; each visible area is
/// its own concrete `View` struct in a sibling file (overview, digest, rail, notes shelf,
/// documents, sheets).
struct CallsDigestLens: View {
    @ObservedObject var model = AppModel.shared
    @State private var entitySheetTarget: EntitySheetTarget?
    @State private var rows: [IndexStore.DigestRow] = []
    @State private var notes: [KnowledgeNote] = []
    @State private var openNote: KnowledgeNote?
    /// M24: the doc list (`docs`) is a lightweight projection with no `.body` — loading every
    /// document's full extracted text just to show a list would be wasteful, unlike notes (short
    /// entries, cheap to keep in full). A tap re-parses the ONE tapped document on demand.
    @State private var pendingLink: URL?
    @State private var creatingNote = false
    @State private var newNoteTitle = ""
    @State private var vocabTerms: [EntityRegistry.Entity] = []
    @State private var addingTerm = false
    @State private var termCanonical = ""
    @State private var termAliases = ""
    @State private var termGloss = ""
    @State private var suggestions: [String] = []
    @State private var commitments: [CommitmentDisplay] = []
    @State private var whatsImportant: String?
    @State private var whatsImportantGeneration = 0
    @State private var collisions: [(a: EntityRegistry.Entity, b: EntityRegistry.Entity)] = []
    @State private var docs: [DocumentRow] = []
    /// A vault document the reader opened from the shelf, read through the engine.
    @State private var openVaultDoc: VaultDocument?
    @State private var deleteTarget: ItemTarget?
    @State private var renameTarget: ItemTarget?
    @State private var renameText = ""

    /// A note or document the user is acting on (rename/delete), pending confirmation.
    enum ItemTarget: Identifiable {
        case note(KnowledgeNote)
        /// A document in the workspace vault. Carries the whole `VaultDocument` because deleting
        /// one needs its `expandRef` — the source directory is resolved through `expand`, not from
        /// a path the listing hands out.
        case vaultDoc(VaultDocument)

        var id: String {
            switch self {
            case .note(let n): return n.url.path
            case .vaultDoc(let d): return d.id
            }
        }
        var name: String {
            switch self {
            case .note(let n): return n.title
            case .vaultDoc(let d): return d.title ?? d.id
            }
        }
        var kindWord: String {
            switch self {
            case .note: return "note"
            case .vaultDoc: return "document"
            }
        }
    }

    var body: some View {
        knowledgeContent
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .confirmationDialog(
            deleteTarget.map { "Delete the “\($0.name)” \($0.kindWord)?" } ?? "",
            isPresented: Binding(get: { deleteTarget != nil }, set: { if !$0 { deleteTarget = nil } }),
            presenting: deleteTarget
        ) { target in
            Button("Delete", role: .destructive) { performDelete(target) }
            Button("Cancel", role: .cancel) {}
        } message: { target in
            switch target {
            case .note: Text("This permanently deletes the note file. This can't be undone.")
            case .vaultDoc: Text("This removes the document from this workspace's vault and recomposes the scope without it. The file you imported from is not affected.")
            }
        }
        .alert("Rename \(renameTarget?.kindWord ?? "item")",
               isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { performRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
        }
        .sheet(item: $openVaultDoc) { document in
            VaultNoteSheet(document: document, model: VaultBrowseModel.shared)
        }
        .sheet(item: $openNote) { note in
            NoteDetailView(note: note, pendingLink: pendingLink) { refreshed in
                openNote = refreshed
                pendingLink = nil
                notes = NoteStore.list(group: model.activeGroup)
                reindex(refreshed)
            } onClose: {
                openNote = nil
                pendingLink = nil
                notes = NoteStore.list(group: model.activeGroup)
            } onDelete: {
                let target = openNote
                openNote = nil
                if let target { deleteTarget = .note(target) }
            }
        }
        .alert("New note", isPresented: $creatingNote) {
            TextField("Title (e.g. 425 Park)", text: $newNoteTitle)
            Button("Create") {
                if let note = NoteStore.create(title: newNoteTitle, group: model.activeGroup) {
                    notes = NoteStore.list(group: model.activeGroup)
                    openNote = note
                    reindex(note)
                }
                newNoteTitle = ""
            }
            Button("Cancel", role: .cancel) { newNoteTitle = "" }
        } message: {
            Text("A standing note you keep adding to — it lives in Notes/ inside your transcripts folder.")
        }
        .sheet(item: $entitySheetTarget) { target in
            EntitySheet(target: target, entitySheetTarget: $entitySheetTarget,
                        openNote: $openNote, onCommitmentsChanged: reload)
        }
    }

    /// The vault half of the shelf, merged in when the engine answers.
    ///
    /// SEPARATE FROM THE LOCAL LOAD because it is a subprocess round trip, and making the whole
    /// shelf wait on the engine would leave locally-imported documents invisible whenever the
    /// engine is slow or absent. The local half is already on screen by the time this lands.
    ///
    /// `uploadedDocuments()` returns [] rather than a refusal for the same reason — a shelf is not
    /// where an engine fault belongs; the Vault lens reports that.
    @MainActor
    private func loadVaultDocuments(group: String) {
        Task {
            let uploaded = await VaultBrowseModel.shared.uploadedDocuments()
            guard group == model.activeGroup else { return }   // a switch landed while we asked
            let vaultRows = uploaded.map {
                DocumentRow(id: $0.id, title: $0.title ?? $0.id, created: "", document: $0)
            }
            self.docs = vaultRows
        }
    }

    /// Split out of `body` so neither half carries the whole modifier chain. Cost here is a
    /// THRESHOLD, not a ramp, and that is the whole reason this seam exists: bisected, the first
    /// ~7 modifier wraps are free and each one after that costs the solver real time. Not modifier
    /// identity — `.confirmationDialog` is free at position 7, and these same six presentations
    /// cost ~600ms at depth 8-12 but ~36ms re-based on a shallow opaque type. Depth position is
    /// what the solver charges for.
    ///
    /// Measured across two independent runs: the single-expression form type-checked at 866 and
    /// 880ms mean; this pair costs ~36ms each. The per-modifier figure is NOT quoted because it did
    /// not reproduce — one run put it near 80ms and another near 130ms — so budget against the
    /// threshold, not a rate.
    ///
    /// The seam is load-bearing and nothing enforces it. Moving one presentation down here took a
    /// probe from 72ms back to 197ms; a lifecycle modifier up into `body` does the same in reverse.
    /// Anything in the 4...6 range works, which is the slack you have.
    private var knowledgeContent: some View {
        ScrollView {
            // Regrouped by purpose, not build order (M22): at-a-glance counts, then Recent (the
            // call log — the primary content) alongside Needs-attention/Browse in the rail, then
            // Notes/Documents as their own area instead of sitting above the actual content.
            VStack(alignment: .leading, spacing: Space.x6) {
                KnowledgeHeader(callCount: rows.count, workspaceName: workspaceName)
                KnowledgeStatRow(commitmentCount: commitments.count, peopleCount: scopedPeople.count,
                                 noteCount: notes.count, docCount: docs.count)
                WhatsImportantCard(text: whatsImportant)
                // `KnowledgeRail` (needs-attention + browse) is a permanent HStack member, not
                // nested inside the `!rows.isEmpty` branch (M22 crosscheck) — commitments, identity
                // collisions, and vocabulary are never derived from `rows` (calls-only; entities
                // also come from notes/docs since M20), so they shouldn't disappear whenever the
                // call digest happens to be empty. Restores the pre-M22 invariant that vocabulary/
                // identity-check were "never gated on having calls."
                HStack(alignment: .top, spacing: Space.x6) {
                    if rows.isEmpty && notes.isEmpty {
                        KnowledgeEmptyState()
                    } else if !rows.isEmpty {
                        KnowledgeDigestColumn(rows: rows, notes: notes) { note, call in
                            addToNote(note, from: call)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    KnowledgeRail(commitments: commitments,
                                  collisions: collisions,
                                  people: scopedPeople,
                                  topics: scopedTopics,
                                  vocabTerms: vocabTerms,
                                  suggestions: suggestions,
                                  entitySheetTarget: $entitySheetTarget,
                                  addingTerm: $addingTerm,
                                  termCanonical: $termCanonical,
                                  termAliases: $termAliases,
                                  termGloss: $termGloss,
                                  onMarkCommitmentDone: markCommitmentDone,
                                  onVerdict: { pair, same in verdict(pair, same: same) },
                                  onAddTerm: addTerm)
                        .frame(width: 300)
                }
                KnowledgeNotesShelf(notes: notes,
                                    openNote: $openNote,
                                    deleteTarget: $deleteTarget,
                                    onImport: importFromPanel,
                                    onNewNote: { newNoteTitle = ""; creatingNote = true },
                                    onRename: startRename)
                // jobs + imported files — visible with or without calls
                KnowledgeDocumentsSection(docs: docs,
                                          deleteTarget: $deleteTarget,
                                          openVaultDocument: { openVaultDoc = $0 })
            }
            .padding(Space.x7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Carbon.background)
        .onAppear(perform: reload)
        .onChange(of: model.activeGroup) { _, _ in reload() }
        .onChange(of: model.calls) { _, _ in reload() }
        .onDrop(of: [.fileURL], isTargeted: nil) { providers in
            for provider in providers {
                _ = provider.loadObject(ofClass: URL.self) { url, _ in
                    guard let url else { return }
                    // loadObject's completion is on a background queue — hop to the main actor
                    // before touching model state, or the whole import fails silently.
                    Task { @MainActor in await model.importDocument(url) }
                }
            }
            return true
        }
        .onChange(of: model.importJobs) { _, _ in reload() }
    }

    /// Notes are retrievable (Clovis, search fusion, MCP) — index immediately on every change
    /// rather than waiting for the next reconcile.
    private func reindex(_ note: KnowledgeNote) {
        guard let store = model.index else { return }
        let url = note.url
        Task.detached(priority: .utility) { IndexBuilder.indexNote(url, into: store) }
    }

    private func performDelete(_ target: ItemTarget) {
        switch target {
        case .note(let note):
            NoteStore.delete(note)
            model.index?.remove(path: note.url.path)
            if openNote?.id == note.id { openNote = nil }
        case .vaultDoc(let document):
            // THROUGH THE ENGINE, because that is where the document is. `remove(source:)` deletes
            // the source directory — constrained to the vault's own `10-reference/` — and
            // recomposes `--clean`, without which the removed note's ingest directory survives in
            // the index root and keeps answering.
            Task {
                guard let source = await VaultBrowseModel.shared.sourceDirectory(of: document)
                else { return }
                SubstrateLibraryModel.shared.remove(source: source)
                reload()
            }
        }
        deleteTarget = nil
        reload()
    }

    private func performRename() {
        guard let target = renameTarget else { return }
        let newName = renameText.trimmingCharacters(in: .whitespaces)
        guard !newName.isEmpty else { renameTarget = nil; return }
        switch target {
        case .note(let note):
            NoteStore.rename(note, to: newName)
            // Backgrounded (crosscheck): indexNote now runs a full NLTagger pass (M20), no longer
            // the cheap frontmatter-parse-plus-upsert it was when this call was written synchronous.
            // Safe to detach — reload() below reads the renamed FILE directly (NoteStore.rename
            // already wrote it), not the index, so the list reflects the new name regardless of
            // when the background re-index finishes.
            if let store = model.index {
                let url = note.url
                Task.detached(priority: .utility) { IndexBuilder.indexNote(url, into: store) }
            }
        case .vaultDoc:
            // NOT SUPPORTED, and deliberately not faked. A promoted document's title is what the
            // engine's extraction declared; renaming it here would be the app re-declaring a value
            // it does not own, and the next compose would read the engine's again.
            break
        }
        renameTarget = nil
        reload()
    }

    /// Opens the rename dialog seeded with the current name.
    private func startRename(_ target: ItemTarget) {
        renameText = target.name
        renameTarget = target
    }

    private func reload() {
        mineSuggestions()   // manages its own background Task
        // Registry reads are cheap in-memory scans (lock-protected against the off-main IndexBuilder
        // writers), kept inline for simplicity.
        vocabTerms = EntityRegistry.shared.terms(group: model.activeGroup)
        collisions = EntityRegistry.shared.collisionCandidates(group: model.activeGroup)
        // The heavy reads — SQLite digest (which can block behind a background index upsert on the
        // store's lock) plus two directory scans that read every note/doc file — go off the main
        // actor so opening the hub or switching workspace doesn't stall the UI (audit M7).
        let group = model.activeGroup
        let store = model.index
        Task.detached(priority: .userInitiated) {
            let rows = store?.digest(group: group) ?? []
            let notes = NoteStore.list(group: group)

            let rawCommitments = store?.commitments(group: group) ?? []
            await MainActor.run {
                guard group == model.activeGroup else { return }   // discard a stale load after a switch
                self.rows = rows
                self.notes = notes
                self.loadVaultDocuments(group: group)
                // ownerID → display name: a cheap in-memory registry lookup (same "cheap, inline"
                // reasoning as vocabTerms/collisions above), done here rather than in the
                // detached task so it always sees the freshest registry state at display time.
                // Group-scoped via EntityRegistry.entity(id:group:) — the same unscoped
                // allEntities().first{} pattern M19's crosscheck found and fixed in EntityDetailView
                // was still sitting here too: one entity id can legitimately span workspaces, so an
                // unscoped lookup risked showing a name only ever confirmed in a DIFFERENT
                // workspace's calls (crosscheck follow-up). ownerID is "you", a group-visible
                // confirmed entity id, OR (IndexBuilder's fallback when no confirmed person
                // matched) the raw name string itself — in that last case it IS already the
                // display name, not a lookup miss, so there's no "Someone" fallback.
                self.commitments = rawCommitments.map { row in
                    let isYou = row.ownerID == "you"
                    let name = isYou ? "You" : (EntityRegistry.shared.entity(id: row.ownerID, group: group)?.name ?? row.ownerID)
                    return CommitmentDisplay(id: row.id, path: row.path, ownerID: row.ownerID, ownerName: name,
                                             isYou: isYou, text: row.text, callTitle: row.callTitle)
                }
                // Called here, not folded into the block above: rows must already be fresh before
                // building its query, and this kicks off its own separate, slower background fetch
                // (an FM call) rather than gating everything else in reload() behind it (M23:
                // progressive, same discipline M18 already committed to).
                loadWhatsImportant(rows: rows, group: group, store: store)
            }
        }
    }

    /// "What's important" (M23) — a short FM-synthesized note connecting recent activity to older,
    /// related material, the other half of the dashboard alongside M22's stat tiles. Reuses
    /// RelatedSynthesizer.synthesize (M18's own primitive, zero view dependency) pointed at several
    /// recent calls' combined title+topics instead of one open transcript's — the same
    /// string-concatenation TranscriptDetail already does for one call, just over N. Grounded:
    /// synthesize() itself refuses to invent a connection below 2 real hits, so a quiet workspace
    /// (or one where nothing recent connects to anything older) shows nothing here, not an awkward
    /// "nothing important" placeholder.
    private func loadWhatsImportant(rows: [IndexStore.DigestRow], group: String, store: IndexStore?) {
        // Eager reset (crosscheck) — RelatedItemsPanel.load(), the pattern this function claims
        // to mirror, clears its own state BEFORE the guard for exactly this reason: without it, a
        // group switch left the OUTGOING workspace's synthesized blurb (built from ITS real call
        // content) visible for the whole duration of the new workspace's search+FM round trip —
        // which can take real wall-clock time — a private-content leak across the switch, not
        // just a stale-UI cosmetic issue.
        whatsImportant = nil
        // Generation token (crosscheck), same shape as AppModel.reloadCalls()'s own
        // callsReloadGeneration and for the same reason: reload() re-runs on every model.calls
        // change (recording finishes, index reconcile, import — not just a group switch), so two
        // overlapping loadWhatsImportant calls for the SAME group are a real, reachable case a
        // bare `group == model.activeGroup` check can't catch — that check passes for BOTH the
        // older and newer call alike. Latest-wins: an older, slower FM synthesis finishing after a
        // newer one already landed must not overwrite it. Bumped unconditionally, even on the
        // early-return path below, so a stale in-flight load from a PRIOR call gets superseded
        // even when THIS call has nothing of its own to load.
        whatsImportantGeneration &+= 1
        let generation = whatsImportantGeneration
        guard let store, rows.count >= 2 else { return }
        let recent = Array(rows.prefix(6))
        let current = recent.map { $0.title + " " + $0.tags.joined(separator: " ") }.joined(separator: " ")
        let excludePaths = Set(recent.map(\.path))
        Task.detached(priority: .utility) {
            // Same shape as RelatedItemsPanel.load(): dedupe by path, exclude the recent set
            // itself (a call must not "connect to" its own presence in the query), cap the hits
            // handed to synthesis. RelatedItemsPanel's own excludePath is a single String and
            // isn't touched — this doesn't go through the panel at all, just the bare function.
            var seen = Set<String>()
            var raw: [(title: String, snippet: String)] = []
            for hit in store.search(current, group: group, limit: 12) {
                guard !excludePaths.contains(hit.path), hit.score <= RelatedHit.relevanceFloor,
                      seen.insert(hit.path).inserted else { continue }
                raw.append((title: hit.title.isEmpty ? hit.date : hit.title, snippet: hit.snippet))
                if raw.count >= 6 { break }
            }
            let result = await RelatedSynthesizer.synthesize(current: current, hits: raw)
            await MainActor.run {
                // Supersedes the plain `group == model.activeGroup` check this line used to have:
                // that passes for TWO overlapping same-group loads alike, which is exactly the
                // race above. A group switch also always bumps this generation (reload() runs on
                // every .onChange(of: model.activeGroup)), so this one check covers both cases.
                guard generation == whatsImportantGeneration else { return }
                whatsImportant = result
            }
        }
    }

    private func importFromPanel() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Import"
        panel.message = "PDF, PowerPoint, Word, images, and plain text — analyzed on-device, searchable everywhere."
        guard panel.runModal() == .OK else { return }
        for url in panel.urls {
            Task { await model.importDocument(url) }
        }
    }

    /// Deterministic acronym mining over this workspace's spoken text: frequent ALL-CAPS tokens
    /// not already known to the registry become suggested vocabulary — you confirm, it learns.
    private func mineSuggestions() {
        guard let store = model.index else { return }
        let group = model.activeGroup
        let known = Set(EntityRegistry.shared.allEntities().flatMap { [EntityRegistry.normalize($0.name)] + $0.aliases })
        Task.detached(priority: .utility) {
            let blocklist: Set<String> = ["ok", "am", "pm", "tv", "us", "uk", "id", "ai", "iou"]
            var counts: [String: Int] = [:]
            for text in store.sampleChunkTexts(group: group) {
                for raw in text.split(separator: " ") {
                    let word = raw.trimmingCharacters(in: .punctuationCharacters)
                    guard word.count >= 2, word.count <= 5,
                          word == word.uppercased(), word.allSatisfy(\.isLetter) else { continue }
                    let norm = word.lowercased()
                    guard !known.contains(norm), !blocklist.contains(norm) else { continue }
                    counts[word, default: 0] += 1
                }
            }
            let top = counts.filter { $0.value >= 2 }
                .sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
                .prefix(5).map(\.key)
            await MainActor.run { suggestions = top }
        }
    }

    /// Confirms a mined or hand-typed vocabulary term. Stays with the hub, not the Vocabulary
    /// section: it needs the index handle for the term sync and the reload that follows.
    private func addTerm() {
        let aliases = termAliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
        EntityRegistry.shared.addTerm(canonical: termCanonical, aliases: aliases,
                                      gloss: termGloss.isEmpty ? nil : termGloss,
                                      group: model.activeGroup)
        if let store = model.index { IndexBuilder.syncTerms(store: store) }
        reload()
    }

    /// Route an "add this call to a note" gesture: existing note → open it with the link
    /// pending; nil → create-note flow (the link is carried once the note exists).
    private func addToNote(_ note: KnowledgeNote?, from call: URL) {
        pendingLink = call
        if let note {
            openNote = note
        } else {
            creatingNote = true
        }
    }

    private var workspaceName: String {
        model.activeGroup.isEmpty ? "your workspace" : "“\(model.activeGroup)”"
    }

    // MARK: - Rail facets (people + topics, scoped to what's on screen — the wall holds)

    private var scopedPeople: [(name: String, count: Int)] {
        aggregate(rows.map(\.participants))
    }
    private var scopedTopics: [(name: String, count: Int)] {
        aggregate(rows.map(\.tags))
    }

    private func aggregate(_ lists: [[String]]) -> [(name: String, count: Int)] {
        var counts: [String: (display: String, count: Int)] = [:]
        for list in lists {
            for value in Set(list) {   // one count per call, not per mention
                let key = value.lowercased()
                counts[key] = (counts[key]?.display ?? value, (counts[key]?.count ?? 0) + 1)
            }
        }
        return counts.values.map { (name: $0.display, count: $0.count) }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.name < $1.name }
    }

    /// Marks a commitment resolved: rewrites the owning call's frontmatter (the source of truth —
    /// `TranscriptMetadataEditor.markCommitmentDone` — re-indexing rebuilds `action_items` from
    /// it, so a DB-only status would silently revert) and re-indexes, then reloads. Removed from
    /// the list optimistically first: the write + re-index round-trip is real file I/O, and a
    /// tapped checkmark should disappear immediately, not after a visible delay.
    private func markCommitmentDone(_ item: CommitmentDisplay) {
        guard let store = model.index else { return }
        commitments.removeAll { $0.id == item.id }
        let url = URL(fileURLWithPath: item.path)
        let text = item.text
        let group = model.activeGroup
        let ownerID = item.ownerID
        Task.detached(priority: .utility) {
            try? TranscriptMetadataEditor.markCommitmentDone(url: url, group: group, ownerID: ownerID, commitmentText: text)
            IndexBuilder.index(url, into: store)
            await MainActor.run { reload() }
        }
    }

    private func verdict(_ pair: (a: EntityRegistry.Entity, b: EntityRegistry.Entity), same: Bool) {
        // On merge, the more specific name (more tokens) becomes canonical.
        let aTokens = pair.a.name.split(separator: " ").count
        let keep = aTokens >= pair.b.name.split(separator: " ").count ? pair.a : pair.b
        let other = keep.id == pair.a.id ? pair.b : pair.a
        EntityRegistry.shared.recordVerdict(keep.id, other.id, same: same)
        EntityRegistry.shared.save()
        collisions = EntityRegistry.shared.collisionCandidates(group: model.activeGroup)
    }
}
