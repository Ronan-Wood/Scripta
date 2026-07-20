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

/// The Knowledge center: review what happened across your calls. A day-grouped digest of every
/// call's generated note (title, summary, topics, people), with the workspace's people and
/// topics alongside — all served from the index, so it opens instantly and never re-reads
/// transcript files. Comments (the "add on" layer) attach per call via NoteStore.
struct KnowledgeView: View {
    @ObservedObject var model = AppModel.shared
    @State private var entitySheetTarget: EntitySheetTarget?
    @State private var rows: [IndexStore.DigestRow] = []
    @State private var notes: [KnowledgeNote] = []
    @State private var openNote: KnowledgeNote?
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
    @State private var collisions: [(a: EntityRegistry.Entity, b: EntityRegistry.Entity)] = []
    @State private var docs: [(mdURL: URL, title: String, created: String, file: String)] = []
    @State private var deleteTarget: ItemTarget?
    @State private var renameTarget: ItemTarget?
    @State private var renameText = ""

    /// A note or document the user is acting on (rename/delete), pending confirmation.
    enum ItemTarget: Identifiable {
        case note(KnowledgeNote)
        case doc(mdURL: URL, title: String)

        var id: String {
            switch self {
            case .note(let n): return n.url.path
            case .doc(let url, _): return url.path
            }
        }
        var name: String {
            switch self {
            case .note(let n): return n.title
            case .doc(_, let title): return title
            }
        }
        var kindWord: String {
            switch self {
            case .note: return "note"
            case .doc: return "document"
            }
        }
    }

    var body: some View {
        ScrollView {
            // Regrouped by purpose, not build order (M22): at-a-glance counts, then Recent (the
            // call log — the primary content) alongside Needs-attention/Browse in the rail, then
            // Notes/Documents as their own area instead of sitting above the actual content.
            VStack(alignment: .leading, spacing: Space.x6) {
                header
                statRow
                if rows.isEmpty && notes.isEmpty {
                    emptyState
                } else if !rows.isEmpty {
                    HStack(alignment: .top, spacing: Space.x6) {
                        digestColumn.frame(maxWidth: .infinity, alignment: .leading)
                        rail.frame(width: 300)
                    }
                }
                notesShelf
                documentsSection      // jobs + imported files — visible with or without calls
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
            case .doc: Text("This deletes the copied file and its extracted text from your vault. Your original file is not affected.")
            }
        }
        .alert("Rename \(renameTarget?.kindWord ?? "item")",
               isPresented: Binding(get: { renameTarget != nil }, set: { if !$0 { renameTarget = nil } })) {
            TextField("Name", text: $renameText)
            Button("Rename") { performRename() }
            Button("Cancel", role: .cancel) { renameTarget = nil }
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
        .sheet(item: $entitySheetTarget) { target in entitySheet(target) }
    }

    // Pulled out of the `.sheet` closure inline (was inside a very long modifier chain on `body`):
    // EntityDetailView's init got one field more complex for M21 (entityID/fallbackName became
    // @State for in-place retargeting), which was enough to push the surrounding expression past
    // the type checker's timeout. Isolating the construction here gives it its own inference scope.
    @ViewBuilder
    private func entitySheet(_ target: EntitySheetTarget) -> some View {
        EntityDetailView(entityID: target.id, group: model.activeGroup, fallbackName: target.fallbackName) {
            entitySheetTarget = nil
        } onCommitmentsChanged: {
            reload()
        } onOpenNote: { path in
            if let note = NoteStore.verified(atPath: path, group: model.activeGroup) { openNote = note }
        } onOpenDoc: { path in
            if let url = DocumentImporter.verifiedOriginalURL(atPath: path, group: model.activeGroup) {
                NSWorkspace.shared.open(url)
            }
        }
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
        case .doc(let mdURL, _):
            DocumentImporter.delete(mdURL: mdURL)
            model.index?.remove(path: mdURL.path)
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
        case .doc(let mdURL, _):
            DocumentImporter.rename(mdURL: mdURL, to: newName)
            if let store = model.index {
                let url = mdURL
                Task.detached(priority: .utility) { IndexBuilder.indexDoc(url, into: store) }
            }
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
            let docs = DocumentImporter.list(group: group)
            let rawCommitments = store?.commitments(group: group) ?? []
            await MainActor.run {
                guard group == model.activeGroup else { return }   // discard a stale load after a switch
                self.rows = rows
                self.notes = notes
                self.docs = docs
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

    // MARK: - Notes shelf (the living documents you work out of)

    private var notesShelf: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack {
                SectionHeader(title: "Your notes")
                Spacer()
                CarbonButton(title: "Import file", icon: "document", kind: .secondary,
                             action: importFromPanel)
                    .help("PDF, PowerPoint, Word, images — analyzed on-device, searchable everywhere. Or just drop files anywhere on this pane.")
                CarbonButton(title: "New note", icon: "edit", kind: .secondary) {
                    newNoteTitle = ""
                    creatingNote = true
                }
            }
            if notes.isEmpty {
                Text("Standing notes you keep adding to — a deal, a project, a person. Create one, or add a call to a note from the digest below.")
                    .font(CarbonFont.label(13)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let columns = [GridItem(.adaptive(minimum: 240), spacing: Space.x4)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: Space.x4) {
                    ForEach(notes) { note in
                        NoteShelfCard(note: note, open: { openNote = note },
                                      onRename: { startRename(.note(note)) },
                                      onDelete: { deleteTarget = .note(note) })
                    }
                }
            }
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text("Knowledge center").font(CarbonFont.semibold(24)).foregroundStyle(Carbon.textPrimary)
            Text("Compiled on-device from \(rows.count) call\(rows.count == 1 ? "" : "s") in \(workspaceName)")
                .font(CarbonFont.label(13)).foregroundStyle(Carbon.textSecondary)
        }
    }

    private var workspaceName: String {
        model.activeGroup.isEmpty ? "your workspace" : "“\(model.activeGroup)”"
    }

    /// At-a-glance counts (M22) — the shared `StatTile` `HomeView` already uses, with
    /// Knowledge-specific numbers (not a duplicate of Home's calls/hours tiles), all from data
    /// this view already loads in `reload()` — no new queries for the tiles themselves.
    private var statRow: some View {
        HStack(spacing: Space.x5) {
            StatTile(label: "Open commitments", value: "\(commitments.count)")
            StatTile(label: "People tracked", value: "\(scopedPeople.count)")
            StatTile(label: "Notes", value: "\(notes.count)")
            StatTile(label: "Documents", value: "\(docs.count)")
        }
    }

    /// Visually distinct from `SectionHeader` (bigger, sentence case, full-strength color) —
    /// used only for the two rail groups below, so "Needs attention"/"Browse" read as a tier
    /// above the individual section titles inside them, not a peer of "Commitments"/"People".
    private func groupHeader(_ title: String) -> some View {
        Text(title).font(CarbonFont.medium(14)).foregroundStyle(Carbon.textPrimary)
    }

    private var emptyState: some View {
        CarbonCard {
            VStack(alignment: .leading, spacing: Space.x3) {
                Text("Nothing here yet").font(CarbonFont.medium(15)).foregroundStyle(Carbon.textPrimary)
                Text("As you record calls, their notes collect here — a running record of what happened, who said it, and what you added.")
                    .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .frame(maxWidth: 520)
    }

    // MARK: - Digest (day-grouped call notes)

    /// Rows bucketed by their frontmatter date, newest day first.
    private var days: [(day: String, rows: [IndexStore.DigestRow])] {
        var buckets: [String: [IndexStore.DigestRow]] = [:]
        for row in rows { buckets[row.date, default: []].append(row) }
        return buckets.keys.sorted(by: >).map { (dayLabel($0), buckets[$0]!) }
    }

    private var digestColumn: some View {
        VStack(alignment: .leading, spacing: Space.x6) {
            ForEach(days, id: \.day) { day in
                VStack(alignment: .leading, spacing: Space.x3) {
                    SectionHeader(title: day.day)
                    VStack(spacing: Space.x3) {
                        ForEach(day.rows, id: \.path) { row in
                            DigestCard(row: row, notes: notes) { note in
                                addToNote(note, from: URL(fileURLWithPath: row.path))
                            }
                        }
                    }
                }
            }
        }
    }

    /// "Today" / "Yesterday" / "Monday, July 14" from a yyyy-MM-dd frontmatter date.
    private func dayLabel(_ date: String) -> String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let parsed = parser.date(from: date) else { return date }
        if Calendar.current.isDateInToday(parsed) { return "Today" }
        if Calendar.current.isDateInYesterday(parsed) { return "Yesterday" }
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d"
        return fmt.string(from: parsed)
    }

    // MARK: - Rail (people + topics, scoped to what's on screen — the wall holds)

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

    /// Two purpose-grouped zones (M22), not a flat stack of unrelated sections: things only you
    /// can resolve, then facets you browse by. Order matters — actionable before reference.
    private var rail: some View {
        VStack(alignment: .leading, spacing: Space.x7) {
            needsAttentionGroup
            browseGroup
        }
    }

    /// Commitments + identity collisions — both "only you can resolve this," previously
    /// scattered (commitments mid-rail, collisions buried at the bottom under Vocabulary with
    /// nothing suggesting they were related). Hidden entirely, not shown empty, when there's
    /// genuinely nothing pending — an empty "Needs attention" header with nothing under it would
    /// read as broken, not reassuring.
    @ViewBuilder private var needsAttentionGroup: some View {
        if !commitments.isEmpty || !collisions.isEmpty {
            VStack(alignment: .leading, spacing: Space.x5) {
                groupHeader("Needs attention")
                commitmentsSection
                identityCheck
            }
        }
    }

    /// People + Topics + Vocabulary — three "look something up by facet" surfaces that used to be
    /// split across the rail (People, Topics) and a separate section below the fold (Vocabulary).
    /// Always shown (unlike `needsAttentionGroup`): Vocabulary already renders a placeholder
    /// prompt when empty rather than disappearing, so this group is never genuinely empty.
    private var browseGroup: some View {
        VStack(alignment: .leading, spacing: Space.x5) {
            groupHeader("Browse")
            peopleSection
            topicsSection
            vocabularySection
        }
    }

    @ViewBuilder private var peopleSection: some View {
        if !scopedPeople.isEmpty {
            VStack(alignment: .leading, spacing: Space.x3) {
                SectionHeader(title: "People")
                VStack(spacing: 1) {
                    ForEach(scopedPeople.prefix(8), id: \.name) { person in
                        Button {
                            let id = EntityRegistry.shared.resolveConfirmed(surface: person.name, kind: "person", group: model.activeGroup)
                            entitySheetTarget = EntitySheetTarget(id: id ?? person.name, fallbackName: person.name)
                        } label: {
                            HStack(spacing: Space.x3) {
                                InitialsBadge(name: person.name)
                                Text(shortName(person.name)).font(CarbonFont.medium(13))
                                    .foregroundStyle(Carbon.textPrimary).lineLimit(1)
                                Spacer()
                                Text("\(person.count) call\(person.count == 1 ? "" : "s")")
                                    .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                            }
                            .padding(Space.x4)
                            .background(Carbon.layer)
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
            }
        }
    }

    @ViewBuilder private var topicsSection: some View {
        if !scopedTopics.isEmpty {
            VStack(alignment: .leading, spacing: Space.x3) {
                SectionHeader(title: "Topics")
                FlexWrap(spacing: Space.x2) {
                    ForEach(scopedTopics.prefix(14), id: \.name) { topic in
                        CarbonChip(text: topic.name) { model.route = .tag(topic.name) }
                    }
                }
            }
        }
    }

    /// Per-person commitment rollup (M17): what you owe, and what's owed to you, grouped by
    /// person — workspace-wide (via IndexStore.commitments), not scoped to what's currently
    /// rendered in `rows`, matching how the Vocabulary section is workspace-wide too.
    @ViewBuilder private var commitmentsSection: some View {
        let owedByYou = commitments.filter(\.isYou)
        // Keyed by ownerID, not the display name — two different people can share a name, and
        // grouping by string would silently merge their commitments (crosscheck finding).
        let owedToYou = Dictionary(grouping: commitments.filter { !$0.isYou }, by: \.ownerID)
        if !owedByYou.isEmpty || !owedToYou.isEmpty {
            VStack(alignment: .leading, spacing: Space.x3) {
                SectionHeader(title: "Commitments")
                if !owedByYou.isEmpty {
                    Text("You owe").font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                    ForEach(owedByYou) { commitmentRow($0) }
                }
                ForEach(owedToYou.keys.sorted(), id: \.self) { ownerID in
                    let items = owedToYou[ownerID] ?? []
                    if let name = items.first?.ownerName {
                        Button { entitySheetTarget = EntitySheetTarget(id: ownerID, fallbackName: name) } label: {
                            Text("\(name) owes you").font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                        }.buttonStyle(.plain)
                        ForEach(items) { commitmentRow($0) }
                    }
                }
            }
        }
    }

    private func commitmentRow(_ item: CommitmentDisplay) -> some View {
        HStack(alignment: .top, spacing: Space.x2) {
            Button { markCommitmentDone(item) } label: {
                CarbonIcon(name: "checkmark", size: 10, color: Carbon.textHelper)
            }.buttonStyle(.plain).help("Mark done")
            VStack(alignment: .leading, spacing: 1) {
                Text(item.text).font(CarbonFont.body(12)).foregroundStyle(Carbon.textPrimary)
                Text(item.callTitle).font(CarbonFont.label(10)).foregroundStyle(Carbon.textHelper)
            }
        }
        .padding(.leading, Space.x1)
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

    /// Imported files, newest first — click opens the original.
    @ViewBuilder private var documentsSection: some View {
        if !docs.isEmpty || !model.importJobs.isEmpty {
            VStack(alignment: .leading, spacing: Space.x3) {
                SectionHeader(title: "Documents")
                // In-flight / just-finished imports — the "is it done?" signal.
                ForEach(model.importJobs) { job in importJobRow(job) }
                VStack(spacing: 1) {
                    ForEach(docs.prefix(6), id: \.mdURL) { doc in
                        HStack(spacing: Space.x3) {
                            CarbonIcon(name: "document", size: 14, color: Carbon.iconSecondary)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(doc.title).font(CarbonFont.medium(13))
                                    .foregroundStyle(Carbon.textPrimary).lineLimit(1)
                                Text(doc.created).font(CarbonFont.label(11))
                                    .foregroundStyle(Carbon.textHelper)
                            }
                            Spacer()
                            ItemMenu(
                                open: { NSWorkspace.shared.open(DocumentImporter.folder.appendingPathComponent(doc.file)) },
                                openLabel: "Open original",
                                onRename: { startRename(.doc(mdURL: doc.mdURL, title: doc.title)) },
                                onDelete: { deleteTarget = .doc(mdURL: doc.mdURL, title: doc.title) })
                        }
                        .padding(Space.x4)
                        .background(Carbon.layer)
                        .contentShape(Rectangle())
                        .onTapGesture {
                            NSWorkspace.shared.open(DocumentImporter.folder.appendingPathComponent(doc.file))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
            }
        }
    }

    /// One import's live state: spinner while extracting, ✓ when added, error text if it failed.
    @ViewBuilder private func importJobRow(_ job: AppModel.ImportJob) -> some View {
        HStack(spacing: Space.x3) {
            switch job.state {
            case .processing:
                ProgressView().controlSize(.small)
            case .done:
                Image(systemName: "checkmark.circle.fill").font(.system(size: 14)).foregroundStyle(Carbon.success)
            case .failed:
                Image(systemName: "exclamationmark.triangle.fill").font(.system(size: 14)).foregroundStyle(Carbon.danger)
            }
            VStack(alignment: .leading, spacing: 1) {
                Text(job.filename).font(CarbonFont.medium(13)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                Text(jobStatusText(job)).font(CarbonFont.label(11))
                    .foregroundStyle(job.isFailed ? Carbon.danger : Carbon.textHelper)
                    .lineLimit(2)
            }
            Spacer()
            if case .failed = job.state {
                Button { model.dismissImportJob(job.id) } label: {
                    Image(systemName: "xmark").font(.system(size: 10, weight: .medium)).foregroundStyle(Carbon.iconSecondary)
                        .frame(width: 20, height: 20).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
    }

    private func jobStatusText(_ job: AppModel.ImportJob) -> String {
        switch job.state {
        case .processing: return "Analyzing on-device…"
        case .done: return "Added — searchable everywhere"
        case .failed(let message): return message
        }
    }

    // MARK: - Vocabulary (the correction loop's front door)

    private var vocabularySection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack {
                SectionHeader(title: "Vocabulary")
                Spacer()
                Button {
                    termCanonical = ""; termAliases = ""; termGloss = ""
                    addingTerm = true
                } label: {
                    Text("Add term").font(CarbonFont.label(12)).foregroundStyle(Carbon.interactive)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if vocabTerms.isEmpty {
                Text("Teach Scripta your jargon once — it biases transcription, and searching a term finds its expansions too (\"TIM\" finds \"tenants in the market\").")
                    .font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                FlexWrap(spacing: Space.x2) {
                    ForEach(vocabTerms, id: \.id) { term in
                        CarbonChip(text: term.name) { entitySheetTarget = EntitySheetTarget(id: term.id, fallbackName: term.name) }
                            .help(term.gloss?.isEmpty == false ? term.gloss!
                                  : term.aliases.joined(separator: ", "))
                    }
                }
            }
            if !suggestions.isEmpty {
                Text("Suggested from your calls — tap to teach:")
                    .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                FlexWrap(spacing: Space.x2) {
                    ForEach(suggestions, id: \.self) { word in
                        Button {
                            termCanonical = word; termAliases = ""; termGloss = ""
                            addingTerm = true
                        } label: {
                            HStack(spacing: 3) {
                                Image(systemName: "plus").font(.system(size: 8, weight: .bold))
                                Text(word).font(CarbonFont.label(12))
                            }
                            .foregroundStyle(Carbon.interactive)
                            .padding(.horizontal, Space.x4).padding(.vertical, Space.x2)
                            .background(Carbon.blueSoft, in: Capsule())
                            .contentShape(Capsule())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .alert("Add vocabulary term", isPresented: $addingTerm) {
            TextField("Term (e.g. TIM)", text: $termCanonical)
            TextField("Aliases, comma-separated (e.g. tenants in the market)", text: $termAliases)
            TextField("Meaning (optional)", text: $termGloss)
            Button("Add") {
                let aliases = termAliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                EntityRegistry.shared.addTerm(canonical: termCanonical, aliases: aliases,
                                              gloss: termGloss.isEmpty ? nil : termGloss,
                                              group: model.activeGroup)
                if let store = model.index { IndexBuilder.syncTerms(store: store) }
                reload()
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Feeds transcription biasing and search — a search for the term also matches its aliases, everywhere.")
        }
    }

    /// Deterministic identity clarifiers: pairs the registry itself flags as possibly the same
    /// person/org. Your verdict persists as a rule, so each pair is asked exactly once.
    @ViewBuilder private var identityCheck: some View {
        if !collisions.isEmpty {
            VStack(alignment: .leading, spacing: Space.x3) {
                SectionHeader(title: "Identity check")
                ForEach(Array(collisions.enumerated()), id: \.offset) { _, pair in
                    VStack(alignment: .leading, spacing: Space.x2) {
                        Text("Same \(pair.a.kind == "org" ? "company" : "person")?")
                            .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                        Text("\(pair.a.name)  ·  \(pair.b.name)")
                            .font(CarbonFont.medium(13)).foregroundStyle(Carbon.textPrimary)
                            .lineLimit(2)
                        HStack(spacing: Space.x3) {
                            Button("Same") { verdict(pair, same: true) }
                                .buttonStyle(.plain)
                                .font(CarbonFont.medium(12)).foregroundStyle(Carbon.interactive)
                            Button("Different") { verdict(pair, same: false) }
                                .buttonStyle(.plain)
                                .font(CarbonFont.medium(12)).foregroundStyle(Carbon.textSecondary)
                        }
                    }
                    .padding(Space.x4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay {
                        RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                            .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
                    }
                }
            }
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

    /// "Wertz, Lalita @ Harrisburg" → "Wertz, Lalita" for the rail; full name in the tooltip.
    private func shortName(_ name: String) -> String {
        name.components(separatedBy: " @ ").first ?? name
    }
}

/// One call's generated note in the digest, with the "add on" hook into your standing notes.
private struct DigestCard: View {
    let row: IndexStore.DigestRow
    let notes: [KnowledgeNote]
    let addToNote: (KnowledgeNote?) -> Void
    @ObservedObject var model = AppModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack(alignment: .firstTextBaseline) {
                Text(title).font(CarbonFont.medium(15)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                Spacer()
                Menu {
                    ForEach(notes) { note in
                        Button(note.title) { addToNote(note) }
                    }
                    if !notes.isEmpty { Divider() }
                    Button("New note…") { addToNote(nil) }
                } label: {
                    HStack(spacing: Space.x2) {
                        Image(systemName: "text.append").font(.system(size: 10, weight: .semibold))
                        Text("Add to note").font(CarbonFont.label(12))
                    }
                    .foregroundStyle(Carbon.textSecondary)
                    .contentShape(Rectangle())
                }
                .menuStyle(.borderlessButton)
                .menuIndicator(.hidden)
                .fixedSize()
                .help("Append what this call taught you to a standing note")
                Button {
                    model.route = .call(URL(fileURLWithPath: row.path))
                } label: {
                    HStack(spacing: Space.x2) {
                        Text("Open").font(CarbonFont.label(12))
                        Image(systemName: "chevron.right").font(.system(size: 9, weight: .semibold))
                    }
                    .foregroundStyle(Carbon.interactive)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(meta).font(CarbonFont.label(12)).foregroundStyle(Carbon.textHelper)
            if !row.summary.isEmpty {
                Text(row.summary).font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
                    .lineLimit(3).fixedSize(horizontal: false, vertical: true)
            }
            if !row.tags.isEmpty {
                FlexWrap(spacing: Space.x2) {
                    ForEach(row.tags.prefix(6), id: \.self) { tag in
                        // M21: matches the People rail's own tag chips, which already navigate —
                        // this was the one tag surface in the hub that didn't.
                        CarbonChip(text: tag) { model.route = .tag(tag) }
                    }
                }
            }
        }
        .padding(Space.x5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
        }
    }

    private var title: String {
        row.title.isEmpty ? "\(row.date) \(row.time)" : row.title
    }
    private var meta: String {
        var parts: [String] = []
        if !row.time.isEmpty { parts.append(row.time) }
        if !row.duration.isEmpty { parts.append(row.duration) }
        if !row.participants.isEmpty {
            parts.append(row.participants.prefix(3).map { $0.components(separatedBy: " @ ").first ?? $0 }
                .joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }
}

/// A standing note on the shelf: title, freshness, last entry.
private struct NoteShelfCard: View {
    let note: KnowledgeNote
    let open: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack(spacing: Space.x2) {
                CarbonIcon(name: "book", size: 14, color: Carbon.interactive)
                Text(note.title).font(CarbonFont.medium(14)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                Spacer()
                ItemMenu(open: open, openLabel: "Open", onRename: onRename, onDelete: onDelete)
            }
            if let last = note.entries.last {
                Text(last.text).font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary).lineLimit(2)
            }
            Text("\(note.entries.count) entr\(note.entries.count == 1 ? "y" : "ies") · updated \(note.updated)")
                .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
        }
        .padding(Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}

/// The visible "•••" actions menu used on note cards and document rows (Open / Rename / Delete),
/// so those actions don't require right-clicking.
private struct ItemMenu: View {
    let open: () -> Void
    let openLabel: String
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        Menu {
            Button(openLabel, action: open)
            Button("Rename…", action: onRename)
            Divider()
            Button("Delete", role: .destructive, action: onDelete)
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Carbon.iconSecondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("More actions")
    }
}

/// The note itself: the accumulated entries, and the composer that appends the next one.
/// Presented as a sheet; `pendingLink` carries "this came from that call" when the flow
/// started on a digest card.
private struct NoteDetailView: View {
    let note: KnowledgeNote
    let pendingLink: URL?
    let onChanged: (KnowledgeNote) -> Void
    let onClose: () -> Void
    let onDelete: () -> Void

    @ObservedObject var model = AppModel.shared
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(note.title).font(CarbonFont.semibold(18)).foregroundStyle(Carbon.textPrimary)
                    Text("Started \(note.created) · Notes/\(note.url.lastPathComponent)")
                        .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                }
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13)).foregroundStyle(Carbon.danger)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete this note")
                CarbonButton(title: "Done", kind: .secondary, action: onClose)
            }
            .padding(Space.x6)

            Divider().overlay(Carbon.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.x4) {
                    if note.entries.isEmpty {
                        Text("Nothing here yet — add the first entry below.")
                            .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
                    }
                    ForEach(Array(note.entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: Space.x1) {
                            HStack(spacing: Space.x3) {
                                Text(entry.stamp).font(CarbonFont.monospace(11)).foregroundStyle(Carbon.textHelper)
                                if let call = entry.linkedCall, !call.contains("/") {
                                    Button {
                                        let url = AppSettings.outputFolder.appendingPathComponent("\(call).md")
                                        // `call` comes from parsing freeform entry text (M14
                                        // crosscheck, security lens): the "/" reject above blocks
                                        // path components, this re-confirms the resolved file
                                        // still resolves inside outputFolder before navigating.
                                        let base = AppSettings.outputFolder.standardizedFileURL.path
                                        guard url.standardizedFileURL.path.hasPrefix(base + "/") else { return }
                                        onClose()
                                        model.route = .call(url)
                                    } label: {
                                        HStack(spacing: 2) {
                                            CarbonIcon(name: "document", size: 10, color: Carbon.interactive)
                                            Text(call).font(CarbonFont.label(11)).foregroundStyle(Carbon.interactive).lineLimit(1)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            Text(entry.text).font(CarbonFont.body(14)).foregroundStyle(Carbon.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Space.x6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().overlay(Carbon.borderSubtle)

            VStack(alignment: .leading, spacing: Space.x2) {
                if let pendingLink {
                    HStack(spacing: Space.x2) {
                        CarbonIcon(name: "document", size: 11, color: Carbon.interactive)
                        Text("Will link to \(pendingLink.deletingPathExtension().lastPathComponent)")
                            .font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary).lineLimit(1)
                    }
                }
                HStack(spacing: Space.x3) {
                    TextField("Add to this note…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(CarbonFont.body(14))
                        .foregroundStyle(Carbon.textPrimary)
                        .lineLimit(1...4)
                        .focused($composerFocused)
                        .onSubmit(submit)
                    CarbonButton(title: "Add", kind: .primary, action: submit)
                }
            }
            .padding(Space.x5)
            .background(Carbon.layer)
        }
        .frame(width: 560, height: 520)
        .background(Carbon.background)
        .onAppear { composerFocused = true }
    }

    private func submit() {
        guard let refreshed = NoteStore.append(draft, linkedCall: pendingLink, to: note) else { return }
        draft = ""
        onChanged(refreshed)
    }
}

/// Colored initials disc, Carbon-blue family.
struct InitialsBadge: View {
    let name: String
    var body: some View {
        Text(initials)
            .font(CarbonFont.medium(10))
            .foregroundStyle(Carbon.interactive)
            .frame(width: 24, height: 24)
            .background(Carbon.interactive.opacity(0.14), in: Circle())
    }
    private var initials: String {
        let words = name.components(separatedBy: " @ ").first?
            .components(separatedBy: CharacterSet(charactersIn: " ,")).filter { !$0.isEmpty } ?? []
        let letters = words.prefix(2).compactMap(\.first)
        return String(letters).uppercased()
    }
}
