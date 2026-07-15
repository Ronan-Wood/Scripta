import SwiftUI

/// The central hub. A native macOS translucent sidebar (SF Symbols, system selection) with
/// purpose-built Carbon-accented content on the right. Apple chrome, Carbon soul.
struct HubView: View {
    @ObservedObject private var model = AppModel.shared
    @State private var section: HubSection = .home
    @State private var expanded: Bool = AppSettings.sidebarExpanded
    @State private var focusCall: URL?
    @State private var focusTag: String?

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

            ForEach(HubSection.primary, id: \.self) { navItem($0) }
            Spacer()
            ForEach(HubSection.secondary, id: \.self) { navItem($0) }
        }
        .padding(.bottom, Space.x3)
        .frame(width: expanded ? 216 : 60)
        .background(VisualEffectView())
    }

    private func navItem(_ item: HubSection) -> some View {
        let selected = section == item
        return Button {
            // Route-driven focus (open call / tag filter) is one-shot: manual navigation
            // must not resurrect a stale selection on the next visit to Calls.
            focusCall = nil
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
            CallsView(focusCall: focusCall, focusTag: focusTag)
                .id("\(focusCall?.path ?? "")|\(focusTag ?? "")")
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
        case .call(let url): focusCall = url; focusTag = nil; section = .calls
        case .tag(let tag): focusTag = tag; focusCall = nil; section = .calls
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

