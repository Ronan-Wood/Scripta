import SwiftUI

/// The Knowledge center: review what happened across your calls. A day-grouped digest of every
/// call's generated note (title, summary, topics, people), with the workspace's people and
/// topics alongside — all served from the index, so it opens instantly and never re-reads
/// transcript files. Comments (the "add on" layer) attach per call via NoteStore.
struct KnowledgeView: View {
    @ObservedObject var model = AppModel.shared
    @State private var rows: [IndexStore.DigestRow] = []
    @State private var notes: [KnowledgeNote] = []
    @State private var openNote: KnowledgeNote?
    @State private var pendingLink: URL?
    @State private var creatingNote = false
    @State private var newNoteTitle = ""

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x6) {
                header
                notesShelf
                if rows.isEmpty && notes.isEmpty {
                    emptyState
                } else if !rows.isEmpty {
                    HStack(alignment: .top, spacing: Space.x6) {
                        digestColumn.frame(maxWidth: .infinity, alignment: .leading)
                        rail.frame(width: 300)
                    }
                }
            }
            .padding(Space.x7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .background(Carbon.background)
        .onAppear(perform: reload)
        .onChange(of: model.activeGroup) { _, _ in reload() }
        .onChange(of: model.calls) { _, _ in reload() }
        .sheet(item: $openNote) { note in
            NoteDetailView(note: note, pendingLink: pendingLink) { refreshed in
                openNote = refreshed
                pendingLink = nil
                notes = NoteStore.list(group: model.activeGroup)
            } onClose: {
                openNote = nil
                pendingLink = nil
                notes = NoteStore.list(group: model.activeGroup)
            }
        }
        .alert("New note", isPresented: $creatingNote) {
            TextField("Title (e.g. 425 Park)", text: $newNoteTitle)
            Button("Create") {
                if let note = NoteStore.create(title: newNoteTitle, group: model.activeGroup) {
                    notes = NoteStore.list(group: model.activeGroup)
                    openNote = note
                }
                newNoteTitle = ""
            }
            Button("Cancel", role: .cancel) { newNoteTitle = "" }
        } message: {
            Text("A standing note you keep adding to — it lives in Notes/ inside your transcripts folder.")
        }
    }

    private func reload() {
        rows = model.index?.digest(group: model.activeGroup) ?? []
        notes = NoteStore.list(group: model.activeGroup)
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
                        NoteShelfCard(note: note) { openNote = note }
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

    private var rail: some View {
        VStack(alignment: .leading, spacing: Space.x6) {
            if !scopedPeople.isEmpty {
                VStack(alignment: .leading, spacing: Space.x3) {
                    SectionHeader(title: "People")
                    VStack(spacing: 1) {
                        ForEach(scopedPeople.prefix(8), id: \.name) { person in
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
                        }
                    }
                    .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
                }
            }
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
                    ForEach(row.tags.prefix(6), id: \.self) { CarbonChip(text: $0) }
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

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Space.x2) {
                HStack {
                    CarbonIcon(name: "book", size: 14, color: Carbon.interactive)
                    Text(note.title).font(CarbonFont.medium(14)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                    Spacer()
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
        }
        .buttonStyle(.plain)
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
                                if let call = entry.linkedCall {
                                    Button {
                                        let url = AppSettings.outputFolder.appendingPathComponent("\(call).md")
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
