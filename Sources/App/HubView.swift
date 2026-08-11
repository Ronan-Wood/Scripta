import SwiftUI

/// The central hub. A native macOS translucent sidebar (SF Symbols, system selection) with
/// purpose-built Carbon-accented content on the right. Apple chrome, Carbon soul.
struct HubView: View {
    @ObservedObject private var model = AppModel.shared
    @StateObject private var navigator = Navigator()
    @State private var expanded: Bool = AppSettings.sidebarExpanded
    @State private var confirmingWorkspaceDelete = false
    /// Why a wipe was refused, when it was. Non-nil drives an alert — a privacy feature that cannot
    /// prove it covered everything says so rather than showing a confident zero.
    @State private var wipeRefusal: String?
    /// The resolved wipe, held between the confirmation and the action so both describe one state.
    @State private var wipePlan: WorkspaceDeleter.Plan?

    /// Everything the wipe removes, in the operator's terms.
    private var wipeMessage: String {
        var sentence = "This permanently deletes the transcript files for every call in "
            + "“\(model.activeGroup)”"
        var extras: [String] = []
        if (wipePlan?.documents ?? 0) > 0 {
            let n = wipePlan?.documents ?? 0
            extras.append("\(n) uploaded document" + (n == 1 ? "" : "s"))
        }
        if (wipePlan?.other ?? 0) > 0 {
            let n = wipePlan?.other ?? 0
            extras.append("\(n) other file" + (n == 1 ? "" : "s"))
        }
        if !extras.isEmpty {
            sentence += ", along with \(extras.joined(separator: " and ")) in this workspace's vault"
        }
        return sentence + ". It also removes people and vocabulary known only in this workspace. "
            + "This can't be undone."
    }
    @State private var creatingWorkspace = false
    @State private var newWorkspaceName = ""
    @State private var workspaceHovering = false
    @State private var clovisDrawerOpen = false

    var body: some View {
        VStack(spacing: 0) {
            topBar
            ZStack(alignment: .trailing) {
                HStack(spacing: 0) {
                    sidebar
                    Rectangle().fill(Carbon.borderSubtle).frame(width: 1)
                    HubContent(destination: navigator.destination,
                               searchScopeGeneration: navigator.searchScopeGeneration)
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                        .background(Carbon.background)
                }
                // The assistant floats over the content (render behavior) instead of squeezing it:
                // scrim behind, drawer sliding from the trailing edge, tap-out or ✕ to dismiss.
                if clovisDrawerOpen {
                    Carbon.scrim
                        .transition(.opacity)
                        .onTapGesture { closeClovisDrawer() }
                    ClovisDrawerView(close: closeClovisDrawer)
                        .shadow(color: .black.opacity(0.28), radius: 36, x: -8, y: 12)
                        .transition(.move(edge: .trailing))
                }
            }
        }
        .ignoresSafeArea(.container, edges: .top)   // extend under the transparent system titlebar
        .frame(minWidth: 940, minHeight: 640)
        .onChange(of: model.route) { _, route in
            guard let route else { return }
            navigator.follow(route)
            model.route = nil   // one-shot: the inbox is emptied as it is consumed
        }
        .confirmationDialog("Delete the “\(model.activeGroup)” workspace?",
                            isPresented: $confirmingWorkspaceDelete, titleVisibility: .visible) {
            Button("Delete \(wipePlan?.calls.count ?? 0) call\((wipePlan?.calls.count ?? 0) == 1 ? "" : "s")", role: .destructive) {
                guard let plan = wipePlan else { return }
                Task.detached(priority: .userInitiated) {
                    do {
                        try await WorkspaceDeleter.delete(plan)
                        await MainActor.run { model.activeGroup = ""; model.reloadCalls() }
                    } catch {
                        // Either the plan could not be executed at all, or part of it survived —
                        // `WipeError.survived` says which, and reports AFTER the rest is gone. Both
                        // must reach the operator: a workspace they believe is wiped and is not is
                        // the failure this whole feature exists to avoid.
                        await MainActor.run { wipeRefusal = error.localizedDescription
                                              model.reloadCalls() }
                    }
                }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            // NAMES EVERYTHING THAT GOES. The wipe deletes the workspace's whole vault — correctly,
            // since one that left documents behind would be a privacy feature with a hole in it —
            // but this said only "the transcript files for every call", so the operator would have
            // confirmed a call count and lost their uploads and notes with it.
            Text(wipeMessage)
        }
        .alert("This workspace cannot be wiped", isPresented: .init(
            get: { wipeRefusal != nil }, set: { if !$0 { wipeRefusal = nil } })) {
            Button("OK", role: .cancel) { wipeRefusal = nil }
        } message: {
            Text(wipeRefusal ?? "")
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

    private func closeClovisDrawer() {
        withAnimation(.easeInOut(duration: 0.22)) { clovisDrawerOpen = false }
    }

    // MARK: - Title bar (drawn in-window, per the render: centered title, pills on the right)

    private var topBar: some View {
        ZStack {
            Text("Scripta").font(CarbonFont.semibold(13)).foregroundStyle(Carbon.textPrimary)
            HStack(spacing: 6) {
                Spacer()
                TitleBarPill(icon: "chat", label: "Clovis", tint: Carbon.textSecondary,
                             active: clovisDrawerOpen) {
                    withAnimation(.easeInOut(duration: 0.22)) { clovisDrawerOpen.toggle() }
                }
                .help("Ask Clovis — slides out the assistant")
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

            ForEach(HubSection.primary, id: \.self) {
                SidebarNavItem(section: $0, navigator: navigator, expanded: expanded)
            }
            Spacer()
            ForEach(HubSection.secondary, id: \.self) {
                SidebarNavItem(section: $0, navigator: navigator, expanded: expanded)
            }
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
                // Wordmark A1: opening quote (spoken) · Scripta · square end-mark (written).
                HStack(alignment: .firstTextBaseline, spacing: 3) {
                    Text("“").font(CarbonFont.semibold(17)).foregroundStyle(Carbon.interactive)
                    Text("Scripta").font(CarbonFont.semibold(15)).foregroundStyle(Carbon.textPrimary)
                    RoundedRectangle(cornerRadius: 1.5, style: .continuous)
                        .fill(Carbon.interactive).frame(width: 5, height: 5)
                }
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
            // Calendars recorded while this workspace's meetings are live land here automatically.
            if !model.activeGroup.isEmpty, AppSettings.calendarEnabled, CalendarWatcher.shared.isAuthorized {
                Divider()
                Menu("Assign calendars to “\(model.activeGroup)”") {
                    ForEach(CalendarWatcher.shared.calendars(), id: \.calendarIdentifier) { cal in
                        let mapped = AppSettings.calendarGroups[cal.calendarIdentifier] == model.activeGroup
                        Button {
                            var groups = AppSettings.calendarGroups
                            groups[cal.calendarIdentifier] = mapped ? nil : model.activeGroup
                            AppSettings.calendarGroups = groups
                        } label: {
                            if mapped {
                                Label(cal.title, systemImage: "checkmark")
                            } else {
                                Text(cal.title)
                            }
                        }
                    }
                }
            }
            // Destructive: wipe every call in a named workspace (the "before I lend the laptop" case).
            if !model.activeGroup.isEmpty {
                Divider()
                Button(role: .destructive) {
                    // A REFUSAL INSTEAD OF A DIALOG. The count is the operator's evidence that the
                    // wipe covered everything, so a number taken from a listing that failed is
                    // worse than no dialog at all — they would confirm "0 calls", see success, and
                    // hand over the laptop.
                    // ONE resolution, held and then executed — so the tree described in the
                    // confirmation is provably the tree that gets removed.
                    do {
                        wipePlan = try WorkspaceDeleter.plan(group: model.activeGroup)
                        confirmingWorkspaceDelete = true
                    } catch {
                        wipeRefusal = error.localizedDescription
                    }
                } label: { Label("Delete “\(model.activeGroup)” workspace…", systemImage: "trash") }
            }
        } label: {
            HStack(spacing: 7) {
                Image(systemName: "folder")
                    .font(.system(size: 12.5)).foregroundStyle(Carbon.iconSecondary)
                    .frame(width: 18)
                if expanded {
                    Text(model.activeGroup.isEmpty ? "Ungrouped" : model.activeGroup)
                        .font(CarbonFont.medium(13)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                    Spacer(minLength: 0)
                    // The click affordance: a selector glyph pinned to the row's right edge.
                    Image(systemName: "chevron.up.chevron.down")
                        .font(.system(size: 8.5, weight: .semibold)).foregroundStyle(Carbon.textHelper)
                }
            }
            .padding(.horizontal, 10)
            .frame(height: 30)
            .frame(maxWidth: .infinity, alignment: expanded ? .leading : .center)
            .background(workspaceHovering ? Carbon.layerHover : Color.clear,
                        in: RoundedRectangle(cornerRadius: 7, style: .continuous))
            .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .frame(maxWidth: .infinity)   // stretch the Menu control itself, so collapsed centering works
        .onHover { workspaceHovering = $0 }
        .help("Active workspace — search and Ask are scoped to it")
    }

}

/// One sidebar row. Concrete struct rather than a `some View` helper: the sidebar stack is long
/// enough that inlining seven of these puts the whole thing in one expression for the solver.
private struct SidebarNavItem: View {
    let section: HubSection
    @ObservedObject var navigator: Navigator
    let expanded: Bool

    private var selected: Bool { navigator.destination.section == section }

    var body: some View {
        Button {
            navigator.select(section)
        } label: {
            HStack(spacing: 11) {
                Image(systemName: section.sfIcon)
                    .font(.system(size: 15))
                    .foregroundStyle(selected ? Carbon.interactive : Carbon.iconSecondary)
                    .frame(width: 18)
                if expanded {
                    Text(section.title)
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
        .help(section.title)
    }
}

