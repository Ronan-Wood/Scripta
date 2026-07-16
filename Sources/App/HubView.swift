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

    var body: some View {
        HStack(spacing: 0) {
            sidebar
            Rectangle().fill(Carbon.borderSubtle).frame(width: 1)
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Carbon.background)
        }
        .frame(minWidth: 940, minHeight: 640)
        .onChange(of: model.route) { _, route in handle(route) }
        .toolbar { ToolbarItem(placement: .primaryAction) { recordToolbarButton } }
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
    }

    /// Global record control in the window toolbar — present on every section, which also keeps
    /// the titlebar a consistent height everywhere.
    @ViewBuilder private var recordToolbarButton: some View {
        Button {
            if model.recordingState != .processing { model.toggleRecording?() }
        } label: {
            switch model.recordingState {
            case .idle:
                Label("Record", systemImage: "record.circle").foregroundStyle(Carbon.danger)
            case .recording:
                Label("Stop", systemImage: "stop.circle.fill").foregroundStyle(Carbon.danger)
            case .processing:
                Label("Processing", systemImage: "ellipsis.circle").foregroundStyle(Carbon.warning)
            }
        }
        .help(model.recordingState == .recording ? "Stop recording" : "Start recording")
        .disabled(model.recordingState == .processing)
    }

    // MARK: - Sidebar (collapses to an icon rail — never fully hidden)

    private var sidebar: some View {
        VStack(spacing: Space.x1) {
            HStack {
                Button {
                    withAnimation(.easeInOut(duration: 0.16)) { expanded.toggle() }
                    AppSettings.sidebarExpanded = expanded
                } label: {
                    Image(systemName: "sidebar.leading")
                        .font(.system(size: 15)).foregroundStyle(Carbon.iconSecondary)
                        .frame(width: 24, height: 32)
                }
                .buttonStyle(.plain)
                .help(expanded ? "Collapse sidebar" : "Expand sidebar")
                if expanded { Spacer() }
            }
            .padding(.horizontal, Space.x3)
            .padding(.top, Space.x2)

            groupSwitcher
            Rectangle().fill(Carbon.borderSubtle).frame(height: 1).padding(.horizontal, Space.x3).padding(.vertical, Space.x1)

            ForEach(HubSection.primary, id: \.self) { navItem($0) }
            Spacer()
            ForEach(HubSection.secondary, id: \.self) { navItem($0) }
        }
        .padding(.bottom, Space.x3)
        .frame(width: expanded ? 216 : 60)
        .background(VisualEffectView())
    }

    /// The active-workspace picker. Search and Ask are hard-scoped to the selection; changing it
    /// reloads every scoped surface (via AppModel.activeGroup's didSet).
    private var groupSwitcher: some View {
        Menu {
            Picker("Workspace", selection: Binding(get: { model.activeGroup }, set: { model.activeGroup = $0 })) {
                Text("Ungrouped").tag("")
                ForEach(model.availableGroups(), id: \.self) { Text($0).tag($0) }
            }
            // Destructive: wipe every call in a named workspace (the "before I lend the laptop" case).
            if !model.activeGroup.isEmpty {
                Divider()
                Button(role: .destructive) {
                    deleteCandidateCount = WorkspaceDeleter.candidates(group: model.activeGroup).count
                    confirmingWorkspaceDelete = true
                } label: { Label("Delete “\(model.activeGroup)” workspace…", systemImage: "trash") }
            }
        } label: {
            HStack(spacing: Space.x2) {
                Image(systemName: "square.stack.3d.up.fill")
                    .font(.system(size: 13)).foregroundStyle(Carbon.interactive)
                if expanded {
                    Text(model.activeGroup.isEmpty ? "Ungrouped" : model.activeGroup)
                        .font(CarbonFont.medium(13)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                    Spacer()
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 9)).foregroundStyle(Carbon.iconSecondary)
                }
            }
            .padding(.horizontal, Space.x3).padding(.vertical, Space.x2)
            .frame(maxWidth: .infinity, alignment: .leading)
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .padding(.horizontal, Space.x3)
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
            HStack(spacing: Space.x3) {
                Image(systemName: item.sfIcon)
                    .font(.system(size: 16))
                    .foregroundStyle(selected ? Carbon.interactive : Carbon.iconSecondary)
                    .frame(width: 24)
                if expanded {
                    Text(item.title)
                        .font(CarbonFont.body(14))
                        .foregroundStyle(selected ? Carbon.textPrimary : Carbon.textSecondary)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                }
            }
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .padding(.horizontal, Space.x3)
            .frame(height: 34)
            .background(selected ? Carbon.interactive.opacity(0.16) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.horizontal, Space.x3)
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
    case home, calls, meetings, ask, settings, docs

    static let primary: [HubSection] = [.home, .calls, .meetings, .ask]
    static let secondary: [HubSection] = [.settings, .docs]

    var title: String {
        switch self {
        case .home: return "Home"
        case .calls: return "Calls"
        case .meetings: return "Meetings"
        case .ask: return "Ask your calls"
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
        case .settings: return "gearshape"
        case .docs: return "book"
        }
    }
}

