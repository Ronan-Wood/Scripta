import SwiftUI

/// The central hub. A native macOS translucent sidebar (SF Symbols, system selection) with
/// purpose-built Carbon-accented content on the right. Apple chrome, Carbon soul.
struct HubView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var section: HubSection = .home
    @State private var expanded: Bool = AppSettings.sidebarExpanded
    @State private var focusCall: URL?
    @State private var focusMs: Int?
    @State private var focusTag: String?
    @State private var confirmingWorkspaceDelete = false
    @State private var deleteCandidateCount = 0
    @State private var creatingWorkspace = false
    @State private var newWorkspaceName = ""

    var body: some View {
        VStack(spacing: 0) {
            topBar
            HStack(spacing: 0) {
                sidebar
                Rectangle().fill(Carbon.borderSubtle).frame(width: 1)
                content
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Carbon.background)
            }
        }
        .ignoresSafeArea(.container, edges: .top)   // extend under the transparent system titlebar
        .frame(minWidth: 940, minHeight: 640)
        .onChange(of: model.route) { _, route in handle(route) }
        .confirmationDialog("Delete the “\(model.activeGroup)” workspace?",
                            isPresented: $confirmingWorkspaceDelete, titleVisibility: .visible) {
            Button("Delete \(deleteCandidateCount) call\(deleteCandidateCount == 1 ? "" : "s")", role: .destructive) {
                let group = model.activeGroup
                Task.detached(priority: .userInitiated) {
                    WorkspaceDeleter.delete(group: group)
                    await MainActor.run { model.activeGroup = ""; model.reloadCalls() }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the transcript files for every call in “\(model.activeGroup)”. This can't be undone.")
        }
        .alert("New workspace", isPresented: $creatingWorkspace) {
            TextField("Name (e.g. Deals)", text: $newWorkspaceName)
            Button("Create") {
                let name = newWorkspaceName.trimmingCharacters(in: .whitespaces)
                if !name.isEmpty { model.activeGroup = name }   // becomes active; new recordings land here
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Switches you into the new workspace. Calls you record while it's active are captured into it.")
        }
    }

    // MARK: - Title bar (drawn in-window, per the render: centered title, pills on the right)

    private var topBar: some View {
        ZStack {
            Text("Scripta").font(CarbonFont.semibold(13)).foregroundStyle(Carbon.textPrimary)
            HStack(spacing: 6) {
                Spacer()
                TitleBarPill(icon: "chat", label: "Clovis", tint: Carbon.textSecondary) {
                    model.route = .section(.ask)
                }
                .help("Ask Clovis about your calls")
                Button {
                    let dark = NSApp.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
                    AppSettings.appearance = dark ? .light : .dark
                    model.applyAppearance()
                } label: {
                    Image(systemName: "circle.lefthalf.filled")
                        .font(.system(size: 14))
                        .foregroundStyle(Carbon.iconSecondary)
                        .frame(width: 26, height: 26)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Toggle light/dark appearance")
                recordPill
            }
            .padding(.trailing, 12)
        }
        .frame(height: 40)
        .frame(maxWidth: .infinity)
        .background {
            ZStack {
                VisualEffectView(material: .headerView)
                Carbon.titlebarTint
            }
        }
        .overlay(alignment: .bottom) { Rectangle().fill(Carbon.borderSubtle).frame(height: 1) }
        .gesture(WindowDragGesture())
    }

    @ViewBuilder private var recordPill: some View {
        switch model.recordingState {
        case .idle:
            TitleBarPill(sfIcon: "record.circle", label: "Record", tint: Carbon.danger) {
                model.toggleRecording?()
            }
            .help("Start recording")
        case .recording:
            TitleBarPill(sfIcon: "stop.circle.fill", label: model.elapsedLabel, tint: Carbon.danger) {
                model.toggleRecording?()
            }
            .help("Stop recording")
        case .processing:
            TitleBarPill(sfIcon: "ellipsis.circle", label: "Processing", tint: Carbon.warning) {}
        }
    }

    // MARK: - Sidebar (render spec: 220pt, pad 10/10/12, 34pt rows, rgba sidebar tint;
    // collapses to a 64pt rail showing the colophon mark; collapse control lives at the bottom)

    private var sidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            logoHeader
            groupSwitcher
            Rectangle().fill(Carbon.borderSubtle).frame(height: 1)
                .padding(.horizontal, 2).padding(.vertical, 6)

            ForEach(HubSection.primary, id: \.self) { navItem($0) }
            Spacer()
            ForEach(HubSection.secondary, id: \.self) { navItem($0) }
            collapseRow
        }
        .padding(.top, 10)
        .padding(.horizontal, 10)
        .padding(.bottom, 12)
        .frame(width: expanded ? 220 : 64)
        .background {
            ZStack {
                VisualEffectView()
                Carbon.sidebarTint
            }
        }
    }

    @ViewBuilder private var logoHeader: some View {
        if expanded {
            VStack(alignment: .leading, spacing: 1) {
                Text("Scripta").font(CarbonFont.semibold(15)).foregroundStyle(Carbon.textPrimary)
                Text("verba volant, scripta manent")
                    .font(CarbonFont.label(10.5)).italic().foregroundStyle(Carbon.textHelper)
            }
            .padding(.horizontal, 10)
            .padding(.top, 4)
            .padding(.bottom, 10)
        } else {
            // The colophon mark stands in for the wordmark on the collapsed rail.
            HStack(alignment: .firstTextBaseline, spacing: 3) {
                Text("S").font(CarbonFont.semibold(16)).foregroundStyle(Carbon.textPrimary)
                RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                    .fill(Carbon.interactive).frame(width: 5, height: 5)
            }
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
            .padding(.bottom, 10)
        }
    }

    private var collapseRow: some View {
        Button {
            withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
            AppSettings.sidebarExpanded = expanded
        } label: {
            HStack(spacing: 11) {
                Image(systemName: "sidebar.leading")
                    .font(.system(size: 14)).foregroundStyle(Carbon.iconSecondary)
                    .frame(width: 18)
                if expanded {
                    Text("Collapse").font(CarbonFont.body(13.5)).foregroundStyle(Carbon.textSecondary)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.top, 2)
        .help(expanded ? "Collapse sidebar" : "Expand sidebar")
    }

    /// The active-workspace picker. Search and Ask are hard-scoped to the selection; changing it
    /// reloads every scoped surface (via AppModel.activeGroup's didSet).
    private var groupSwitcher: some View {
        Menu {
            Picker("Workspace", selection: Binding(get: { model.activeGroup }, set: { model.activeGroup = $0 })) {
                Text("Ungrouped").tag("")
                ForEach(model.availableGroups(), id: \.self) { Text($0).tag($0) }
            }
            Button { newWorkspaceName = ""; creatingWorkspace = true } label: { Label("New workspace…", systemImage: "plus") }
            // Destructive: wipe every call in a named workspace (the "before I lend the laptop" case).
            if !model.activeGroup.isEmpty {
                Divider()
                Button(role: .destructive) {
                    deleteCandidateCount = WorkspaceDeleter.candidates(group: model.activeGroup).count
                    confirmingWorkspaceDelete = true
                } label: { Label("Delete “\(model.activeGroup)” workspace…", systemImage: "trash") }
            }
        } label: {
            HStack(spacing: 8) {
                Image(systemName: "folder")
                    .font(.system(size: 13)).foregroundStyle(Carbon.interactive)
                    .frame(width: 18)
                if expanded {
                    Text(model.activeGroup.isEmpty ? "Ungrouped" : model.activeGroup)
                        .font(CarbonFont.medium(13)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .semibold)).foregroundStyle(Carbon.iconSecondary)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .help("Active workspace — search and Ask are scoped to it")
    }

    private func navItem(_ item: HubSection) -> some View {
        let selected = section == item
        return Button {
            // Route-driven focus (open call / tag filter) is one-shot: manual navigation
            // must not resurrect a stale selection on the next visit to Calls.
            focusCall = nil
            focusMs = nil
            focusTag = nil
            section = item
        } label: {
            HStack(spacing: 11) {
                Image(systemName: item.sfIcon)
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Carbon.interactive : Carbon.iconSecondary)
                    .frame(width: 18)
                if expanded {
                    Text(item.title)
                        .font(selected ? CarbonFont.semibold(13.5) : CarbonFont.body(13.5))
                        .foregroundStyle(selected ? Carbon.textPrimary : Carbon.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 34)
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .background(selected ? Carbon.blueSoft : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(item.title)
    }

    @ViewBuilder private var content: some View {
        switch section {
        case .home:
            HomeView()
        case .calls:
            CallsView(focusCall: focusCall, focusMs: focusMs, focusTag: focusTag)
                .id("\(focusCall?.path ?? "")|\(focusMs.map(String.init) ?? "")|\(focusTag ?? "")")
        case .meetings:
            MeetingsView()
        case .ask:
            AskView()
        case .knowledge:
            KnowledgeView()
        case .settings:
            SettingsView()
        case .docs:
            HelpView()
        }
    }

    private func handle(_ route: AppModel.Route?) {
        switch route {
        case .call(let url, let ms): focusCall = url; focusMs = ms; focusTag = nil; section = .calls
        case .tag(let tag): focusTag = tag; focusCall = nil; focusMs = nil; section = .calls
        case .section(let s): section = s
        case nil: return
        }
        model.route = nil
    }
}

enum HubSection: String, CaseIterable {
    case home, calls, meetings, ask, knowledge, settings, docs

    static let primary: [HubSection] = [.home, .calls, .meetings, .ask, .knowledge]
    static let secondary: [HubSection] = [.settings, .docs]

    var title: String {
        switch self {
        case .home: return "Home"
        case .calls: return "Calls"
        case .meetings: return "Meetings"
        case .ask: return "Ask"
        case .knowledge: return "Knowledge"
        case .settings: return "Settings"
        case .docs: return "Docs"
        }
    }

    var sfIcon: String {
        switch self {
        case .home: return "house"
        case .calls: return "doc.text"
        case .meetings: return "calendar"
        case .ask: return "bubble.left.and.bubble.right"
        case .knowledge: return "list.bullet.rectangle"
        case .settings: return "gearshape"
        case .docs: return "book"
        }
    }
}

