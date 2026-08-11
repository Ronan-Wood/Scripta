import SwiftUI
import ScriptaCore

/// Unified Calls page: browse and search are one surface. An empty query lists every call
/// (newest first); typing ranks calls by the holistic index; People/Tags act as filters. The
/// selected call opens in the transcript reader on the right. Carbon-styled.
struct CallsView: View {
    @State private var query = ""
    @State private var participant: String?
    @State private var tag: String?
    @State private var entity: (id: String, name: String)?   // entity-anchored browse
    @State private var rows: [CallRow] = []
    @State private var selection: URL?
    @State private var selectionMs: Int?
    /// Transient, non-sticky: an explicit "search all workspaces" that resets on any navigation
    /// (CallsView is recreated with a fresh @State), so it can never become a lingering default.
    @State private var allGroups = false
    @ObservedObject private var appModel = AppModel.shared

    init(focusCall: URL? = nil, focusMs: Int? = nil, focusTag: String? = nil) {
        _tag = State(initialValue: focusTag)
        _selection = State(initialValue: focusCall)
        _selectionMs = State(initialValue: focusMs)
    }

    private var store: IndexStore? { IndexStore.shared }

    struct CallRow: Identifiable {
        let id: URL
        let title: String
        let subtitle: String
        let snippet: AttributedString?
        var startMs: Int?
    }

    /// Three readings of this workspace's calls. Doc 4 §2 folds Meetings and the Knowledge digest in
    /// here; the lens lives on a shared model because `HubContent`'s `switch` destroys this branch
    /// whenever the reader leaves the section — see `CallsLensModel`.
    @ObservedObject private var lens = CallsLensModel.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            lensPicker
            switch lens.lens {
            case .recording: CallsRecordingScreen()
            case .list: listAndDetail
            case .calendar: CallsCalendarLens()
            case .digest: CallsDigestLens()
            }
        }
        .background(Carbon.background)
        // ON THE OUTER VIEW, NOT ON `listAndDetail`. The cross-workspace widening is `@State` here
        // and the lens `switch` does not destroy it, so a reset that only exists while the list
        // lens is mounted misses a workspace change made from the Calendar or Digest lens — and
        // "search all workspaces" becomes the lingering default this file's own comment says it can
        // never become.
        .onChange(of: appModel.activeGroup) { _, _ in allGroups = false; refresh() }
    }

    private var lensPicker: some View {
        Picker("", selection: $lens.lens) {
            ForEach(CallsLensModel.available(recording: appModel.recordingState == .recording)) {
                Text($0.title).tag($0)
            }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.horizontal, Space.x5)
        .padding(.top, Space.x4)
    }

    private var listAndDetail: some View {
        HStack(spacing: 0) {
            listColumn.frame(width: 340)
            Rectangle().fill(Carbon.borderSubtle).frame(width: 1)
            detailColumn.frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .onAppear(perform: refresh)
    }

    private var scopeName: String {
        allGroups ? "all workspaces" : (appModel.activeGroup.isEmpty ? "Ungrouped" : appModel.activeGroup)
    }

    // MARK: - List column

    private var listColumn: some View {
        VStack(spacing: 0) {
            HStack(spacing: Space.x3) {
                CarbonIcon(name: "search", size: 16, color: Carbon.iconSecondary)
                TextField("Search calls, people, topics", text: $query)
                    .textFieldStyle(.plain)
                    .font(CarbonFont.body(14))
                    .foregroundStyle(Carbon.textPrimary)
                    .onChange(of: query) { _, _ in refresh() }
                if !query.isEmpty {
                    Button { query = ""; refresh() } label: {
                        CarbonIcon(name: "close", size: 14, color: Carbon.iconSecondary)
                    }.buttonStyle(.plain)
                }
                filterMenu
            }
            .padding(.horizontal, Space.x4)
            .frame(height: 34)
            .background(Carbon.field, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.field, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
            .padding(.horizontal, Space.x4).padding(.top, Space.x4)

            // Scope indicator — always visible so the active workspace is never a hidden default.
            HStack(spacing: Space.x2) {
                CarbonIcon(name: "folder", size: 11, color: Carbon.iconSecondary)
                Text(scopeName).font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary)
                if !allGroups {
                    Text("· \(store?.count(group: appModel.activeGroup) ?? 0) calls")
                        .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                }
                Spacer()
                if allGroups {
                    Button("Back to workspace") { allGroups = false; refresh() }
                        .buttonStyle(.plain).font(CarbonFont.label(11)).foregroundStyle(Carbon.interactive)
                }
            }
            .padding(.horizontal, Space.x5).padding(.top, Space.x2).padding(.bottom, Space.x1)

            if participant != nil || tag != nil || entity != nil {
                HStack(spacing: Space.x2) {
                    if let participant { filterChip("user", participant) { self.participant = nil; refresh() } }
                    if let tag { filterChip("tag", tag) { self.tag = nil; refresh() } }
                    if let entity { filterChip("user", "mentions \(entity.name)") { self.entity = nil; refresh() } }
                    Spacer()
                }
                .padding(.horizontal, Space.x5).padding(.vertical, Space.x3)
            }

            if rows.isEmpty {
                VStack(spacing: Space.x3) {
                    CarbonIcon(name: "document", size: 28, color: Carbon.iconSecondary)
                    Text(query.isEmpty ? "No calls in \(scopeName)" : "No matches in \(scopeName)")
                        .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
                    // Blind affordance: offer to widen WITHOUT revealing whether other workspaces
                    // actually contain matches (the privacy wall must not leak via the no-result path).
                    if !query.isEmpty && !allGroups && !appModel.availableGroups().isEmpty {
                        Button("Search all workspaces") { allGroups = true; refresh() }
                            .buttonStyle(.borderedProminent).controlSize(.small)
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ScrollView {
                    LazyVStack(spacing: Space.x1) {
                        ForEach(rows) { row in callRow(row) }
                    }
                    .padding(.vertical, Space.x2)
                }
            }
        }
        .background(Carbon.background)
    }

    private var filterMenu: some View {
        Menu {
            let people = store?.people() ?? []
            let tags = store?.tags() ?? []
            if !people.isEmpty {
                Menu("Person") {
                    ForEach(people, id: \.name) { p in
                        Button("\(p.name) (\(p.count))") { participant = p.name; refresh() }
                    }
                }
            }
            if !tags.isEmpty {
                Menu("Tag") {
                    ForEach(tags, id: \.name) { t in
                        Button("\(t.name) (\(t.count))") { tag = t.name; refresh() }
                    }
                }
            }
            let entities = store?.entities(group: appModel.activeGroup) ?? []
            if !entities.isEmpty {
                Menu("Entity") {
                    ForEach(entities, id: \.id) { e in
                        Button("\(e.name) (\(e.count))") { entity = (e.id, e.name); refresh() }
                    }
                }
            }
            if people.isEmpty && tags.isEmpty && entities.isEmpty {
                Text("No people, tags, or entities yet")
            }
        } label: {
            Image(systemName: "list.bullet")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(Carbon.iconSecondary)
                .frame(width: 24, height: 24)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Filter by person, tag, or entity")
    }

    private func callRow(_ row: CallRow) -> some View {
        let selected = selection == row.id
        return Button {
            selection = row.id
            selectionMs = row.startMs   // jump the reader to the matched passage
        } label: {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(row.title).font(CarbonFont.medium(14))
                    .foregroundStyle(selected ? Carbon.textOnColor : Carbon.textPrimary).lineLimit(1)
                Text(row.subtitle).font(CarbonFont.label(12))
                    .foregroundStyle(selected ? Carbon.textOnColor.opacity(0.85) : Carbon.textSecondary).lineLimit(1)
                if let snippet = row.snippet {
                    Text(snippet).font(CarbonFont.label(12))
                        .foregroundStyle(selected ? Carbon.textOnColor.opacity(0.85) : Carbon.textHelper).lineLimit(2)
                }
            }
            .padding(.vertical, Space.x3)
            .padding(.horizontal, Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Carbon.interactive : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .padding(.horizontal, Space.x3)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func filterChip(_ icon: String, _ text: String, remove: @escaping () -> Void) -> some View {
        HStack(spacing: Space.x2) {
            CarbonIcon(name: icon, size: 12, color: Carbon.textSecondary)
            Text(text).font(CarbonFont.label(12)).foregroundStyle(Carbon.textPrimary)
            Button(action: remove) { CarbonIcon(name: "close", size: 12, color: Carbon.iconSecondary) }
                .buttonStyle(.plain)
        }
        .padding(.horizontal, Space.x3).padding(.vertical, Space.x2)
        .background(Carbon.layerSelected, in: Capsule())
    }

    // MARK: - Detail column

    @ViewBuilder private var detailColumn: some View {
        if let selection, let meta = TranscriptStore.meta(of: selection) {
            TranscriptDetail(meta: meta, scrollToMs: selectionMs, onEdited: refresh, onDeleted: {
                self.selection = nil
                refresh()
            }).id(selection)
        } else {
            VStack(spacing: Space.x3) {
                CarbonIcon(name: "document", size: 40, color: Carbon.iconSecondary)
                Text("Select a call").font(CarbonFont.body(14)).foregroundStyle(Carbon.textSecondary)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    // MARK: - Data

    private func refresh() {
        let trimmed = query.trimmingCharacters(in: .whitespaces)
        // Hard-scoped to the active workspace; nil only under the explicit, transient all-groups.
        let group: String? = allGroups ? nil : appModel.activeGroup
        if let entity, let store {
            // Entity-anchored: every call that mentions this person/org (mode 3, group-scoped).
            rows = store.callsMentioning(entityID: entity.id, group: group).map { hit in
                CallRow(id: URL(fileURLWithPath: hit.path),
                        title: hit.title.isEmpty ? hit.date : hit.title, subtitle: hit.date, snippet: nil)
            }
        } else if !trimmed.isEmpty, let store {
            var seen = Set<URL>()
            rows = store.search(trimmed, participant: participant, tag: tag, group: group, limit: 60).compactMap { hit in
                let url = URL(fileURLWithPath: hit.path)
                guard seen.insert(url).inserted else { return nil }
                // startMs 0 = a topic-only match (no passage to scroll to).
                return CallRow(id: url, title: hit.title.isEmpty ? hit.date : hit.title,
                               subtitle: hit.date,
                               snippet: SnippetHighlight.attributed(hit.snippet, accent: Carbon.interactive),
                               startMs: hit.startMs > 0 ? hit.startMs : nil)
            }
        } else {
            rows = TranscriptStore.list().filter { meta in
                (group.map { meta.group == $0 } ?? true)   // the privacy wall on the browse list (nil = all)
                && (participant.map { p in meta.participants.contains { $0.range(of: p, options: .caseInsensitive) != nil } } ?? true)
                && (tag.map { t in meta.tags.contains { $0.range(of: t, options: .caseInsensitive) != nil } } ?? true)
            }.map { CallRow(id: $0.url, title: $0.displayTitle, subtitle: $0.subtitle, snippet: nil) }
        }
        if selection == nil || !rows.contains(where: { $0.id == selection }) {
            selection = rows.first?.id
        }
    }
}
