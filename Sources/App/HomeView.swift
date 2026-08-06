import SwiftUI
import ScriptaCore

/// The hub's Home dashboard: greeting + the week at a glance, record, what's recent, and
/// what's coming up. Purpose-built Carbon, driven by the shared AppModel; all call data
/// comes from the index digest so nothing here re-reads transcript files.
struct HomeView: View {
    @ObservedObject var model = AppModel.shared
    @State private var rows: [IndexStore.DigestRow] = []
    @State private var openCommitments = 0

    var body: some View {
        Group {
            if model.recordingState == .recording {
                recordingScreen
            } else {
                dashboard
            }
        }
        .background(Carbon.background)
        .onAppear(perform: reload)
        .onChange(of: model.activeGroup) { _, _ in reload() }
        .onChange(of: model.calls) { _, _ in reload() }
    }

    private func reload() {
        model.reloadCalls()   // loads off the main actor internally (audit M7)
        // Digest is SQLite under the store's lock (can block behind a background upsert) — off-main.
        let group = model.activeGroup
        let store = model.index
        Task.detached(priority: .userInitiated) {
            let rows = store?.digest(group: group) ?? []
            let commitments = store?.commitmentCount(group: group) ?? 0
            await MainActor.run {
                guard group == model.activeGroup else { return }   // discard a stale load after a switch
                self.rows = rows
                self.openCommitments = commitments
            }
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x6) {
                greetingHeader
                statTiles

                HStack(alignment: .top, spacing: Space.x6) {
                    VStack(alignment: .leading, spacing: Space.x6) {
                        recordCard
                        recentCallsSection
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)

                    VStack(alignment: .leading, spacing: Space.x6) {
                        if !model.upcomingMeetings.isEmpty { upNextSection }
                        topicsSection
                    }
                    .frame(width: 300)
                }
            }
            .padding(Space.x7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Greeting + stats

    private var greetingHeader: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            Text(greeting).font(CarbonFont.semibold(26)).foregroundStyle(Carbon.textPrimary)
            Text(greetingSubtitle).font(CarbonFont.label(13)).foregroundStyle(Carbon.textSecondary)
        }
    }

    private var greeting: String {
        switch Calendar.current.component(.hour, from: Date()) {
        case 5..<12: return "Good morning"
        case 12..<17: return "Good afternoon"
        default: return "Good evening"
        }
    }

    private var greetingSubtitle: String {
        let fmt = DateFormatter()
        fmt.dateFormat = "EEEE, MMMM d"
        let day = fmt.string(from: Date())
        let workspace = model.activeGroup.isEmpty ? "Ungrouped" : model.activeGroup
        return "\(day) · \(workspace) workspace"
    }

    private var statTiles: some View {
        HStack(spacing: Space.x5) {
            StatTile(label: "Calls this week", value: "\(callsThisWeek)")
            StatTile(label: "Hours transcribed", value: hoursTranscribed, unit: "hrs")
            StatTile(label: "People tracked", value: "\(peopleTracked)")
            StatTile(label: "Open commitments", value: "\(openCommitments)")
        }
    }

    private var callsThisWeek: Int {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let weekStart = Calendar.current.dateInterval(of: .weekOfYear, for: Date())?.start
        else { return 0 }
        return rows.filter { parser.date(from: $0.date).map { $0 >= weekStart } ?? false }.count
    }

    /// Total recorded time across the workspace, from the frontmatter durations ("M:SS" / "H:MM:SS").
    private var hoursTranscribed: String {
        let seconds = rows.reduce(0) { total, row -> Int in
            let parts = row.duration.split(separator: ":").compactMap { Int($0) }
            switch parts.count {
            case 3: return total + parts[0] * 3600 + parts[1] * 60 + parts[2]
            case 2: return total + parts[0] * 60 + parts[1]
            default: return total
            }
        }
        return String(format: "%.1f", Double(seconds) / 3600)
    }

    private var peopleTracked: Int {
        Set(rows.flatMap(\.participants).map { $0.lowercased() }).count
    }

    // MARK: - Recording screen

    private var recordingScreen: some View {
        VStack(spacing: Space.x5) {
            recordCard
            NoteComposer()
            HStack(alignment: .top, spacing: Space.x5) {
                LiveTranscriptPane(title: liveTitle).frame(maxWidth: .infinity, maxHeight: .infinity)
                // The vault first, then the local index. Both answer "what do I already know about
                // this", and the vault's corpus is the larger one — calls, curated notes and
                // uploads together — so it is the one worth reading before the eye moves on.
                ScrollView {
                    VStack(alignment: .leading, spacing: Space.x5) {
                        LiveRecallPanel()
                        RelatedCallsPanel()
                    }
                }
                .frame(width: 300)
                .scrollIndicators(.never)
            }
        }
        .padding(Space.x7)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    /// The live pane's header — "(you)" only for a two-party call; a conference is unlabeled.
    private var liveTitle: String {
        if !AppSettings.liveTranscriptionEnabled { return "Live transcript off" }
        return model.recordingModeName == nil ? "Live transcript (you)" : "Live transcript"
    }

    // MARK: - Record

    private var recordCard: some View {
        HStack(spacing: Space.x5) {
            micBadge
            VStack(alignment: .leading, spacing: Space.x2) {
                HStack(spacing: Space.x3) {
                    Text(statusTitle).font(CarbonFont.medium(16)).foregroundStyle(Carbon.textPrimary)
                    if model.recordingState == .recording {
                        Text(model.elapsedLabel).font(CarbonFont.monospace(15)).foregroundStyle(Carbon.danger)
                    }
                    if let modeName = model.recordingModeName {
                        Text(modeName)
                            .font(CarbonFont.label(11))
                            .padding(.horizontal, 6).padding(.vertical, 1)
                            .background(Carbon.warning.opacity(0.16), in: Capsule())
                            .foregroundStyle(Carbon.warning)
                    }
                }
                if model.recordingState == .recording {
                    LevelPane()
                } else {
                    Text(statusSubtitle).font(CarbonFont.label(13)).foregroundStyle(Carbon.textSecondary)
                }
            }
            Spacer()
            switch model.recordingState {
            case .idle:
                CarbonButton(title: "Start recording", icon: "recording-filled", kind: .danger) {
                    model.toggleRecording?()
                }
            case .recording:
                CarbonButton(title: model.isPaused ? "Resume" : "Pause",
                             icon: model.isPaused ? "play-filled" : "pause-filled", kind: .secondary) {
                    model.togglePause?()
                }
                CarbonButton(title: "Stop recording", icon: "stop-filled-alt", kind: .danger) {
                    model.toggleRecording?()
                }
            case .processing:
                CarbonButton(title: "Processing…", kind: .secondary) {}
            }
        }
        .padding(Space.x5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(recordCardBackground, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(model.recordingState == .idle ? Carbon.interactive.opacity(0.25) : Carbon.borderSubtle,
                              lineWidth: 1)
        }
    }

    /// Idle = the render's tinted "ready" card; recording/processing keep a neutral surface.
    private var recordCardBackground: Color {
        model.recordingState == .idle ? Carbon.interactive.opacity(0.07) : Carbon.layer
    }

    private var micBadge: some View {
        ZStack {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .fill(Carbon.background)
                .frame(width: 40, height: 40)
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
                }
            if model.recordingState == .recording {
                Circle().fill(Carbon.danger).frame(width: 10, height: 10)
            } else {
                CarbonIcon(name: "microphone", size: 18, color: Carbon.interactive)
            }
        }
    }

    private var statusTitle: String {
        switch model.recordingState {
        case .idle: return "Ready to record"
        case .recording: return model.isPaused ? "Paused" : "Recording…"
        case .processing: return "Transcribing…"
        }
    }
    private var statusSubtitle: String {
        var parts = [modeLabel, "captures on-device"]
        if AppSettings.globalHotkeyEnabled { parts.append("⌥⌘R") }
        switch model.recordingState {
        case .idle: return parts.joined(separator: " · ")
        case .recording: return "Mic and system audio are being captured."
        case .processing: return "Transcribing and writing the note."
        }
    }
    private var modeLabel: String {
        switch AppSettings.defaultRecordingMode {
        case .call: return "Call mode"
        case .conference: return "Conference mode"
        }
    }

    // MARK: - Recent calls

    private var recentCallsSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack {
                SectionHeader(title: "Recent calls")
                Spacer()
                Button {
                    model.route = .section(.calls)
                } label: {
                    Text("View all").font(CarbonFont.label(12)).foregroundStyle(Carbon.interactive)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            if rows.isEmpty {
                Text("No calls yet.").font(CarbonFont.label(13)).foregroundStyle(Carbon.textSecondary)
            } else {
                VStack(spacing: 1) {
                    ForEach(rows.prefix(5), id: \.path) { row in
                        RecentCallRow(row: row) {
                            model.route = .call(URL(fileURLWithPath: row.path))
                        }
                    }
                }
                .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
            }
        }
    }

    // MARK: - Up next + topics

    private var upNextSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            SectionHeader(title: "Up next")
            VStack(spacing: Space.x3) {
                ForEach(model.upcomingMeetings.prefix(3)) { meeting in
                    HStack(spacing: Space.x4) {
                        CarbonIcon(name: "calendar", size: 16, color: Carbon.interactive)
                        VStack(alignment: .leading, spacing: Space.x1) {
                            Text(meeting.title).font(CarbonFont.medium(13)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                            Text("\(relative(meeting.start)) · \(meeting.service)")
                                .font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary)
                        }
                        Spacer()
                        if model.recordingState == .idle {
                            Button {
                                model.recordMeeting?(meeting)
                            } label: {
                                CarbonIcon(name: "recording", size: 15, color: Carbon.danger)
                                    .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .help("Record this meeting")
                        }
                    }
                    .padding(Space.x4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
                    .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
                }
            }
        }
    }

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            SectionHeader(title: "Topics")
            let topics = scopedTopics
            if topics.isEmpty {
                Text("Topics appear as calls are tagged.").font(CarbonFont.label(13)).foregroundStyle(Carbon.textSecondary)
            } else {
                FlexWrap(spacing: Space.x2) {
                    ForEach(topics.prefix(12), id: \.self) { topic in
                        CarbonChip(text: topic) { model.route = .tag(topic) }
                    }
                }
            }
        }
    }

    /// Workspace-scoped topics by frequency, from the digest already in hand.
    private var scopedTopics: [String] {
        var counts: [String: Int] = [:]
        for row in rows { for tag in Set(row.tags) { counts[tag, default: 0] += 1 } }
        return counts.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }.map(\.key)
    }

    private func relative(_ date: Date) -> String {
        let mins = Int(date.timeIntervalSinceNow / 60)
        if mins <= 0 { return "now" }
        if mins < 60 { return "in \(mins) min" }
        let fmt = DateFormatter(); fmt.dateFormat = "h:mm a"
        return fmt.string(from: date)
    }
}

/// One row in Recent calls: title, one-line summary, meta line — the render's list style.
private struct RecentCallRow: View {
    let row: IndexStore.DigestRow
    let open: () -> Void

    var body: some View {
        Button(action: open) {
            HStack(alignment: .center, spacing: Space.x4) {
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(row.title.isEmpty ? "\(row.date) \(row.time)" : row.title)
                        .font(CarbonFont.medium(14)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                    if !row.summary.isEmpty {
                        Text(row.summary).font(CarbonFont.label(12))
                            .foregroundStyle(Carbon.textSecondary).lineLimit(1)
                    }
                    Text(metaLine).font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.system(size: 10, weight: .semibold)).foregroundStyle(Carbon.textHelper)
            }
            .padding(Space.x4)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Carbon.layer)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private var metaLine: String {
        var parts: [String] = []
        if !row.date.isEmpty { parts.append(shortDate) }
        if !row.duration.isEmpty { parts.append(row.duration) }
        if !row.participants.isEmpty {
            parts.append(row.participants.prefix(2).map { $0.components(separatedBy: " @ ").first ?? $0 }
                .joined(separator: ", "))
        }
        return parts.joined(separator: " · ")
    }

    private var shortDate: String {
        let parser = DateFormatter()
        parser.locale = Locale(identifier: "en_US_POSIX")
        parser.dateFormat = "yyyy-MM-dd"
        guard let date = parser.date(from: row.date) else { return row.date }
        let fmt = DateFormatter(); fmt.dateFormat = "MMM d"
        return fmt.string(from: date)
    }
}

/// Inline note entry shown on the recording screen. Timestamps the note against the current
/// point in the call (the model routes it to the live session); ⌥⌘N does the same from anywhere.
private struct NoteComposer: View {
    @ObservedObject var model = AppModel.shared
    @State private var text = ""

    var body: some View {
        HStack(spacing: Space.x3) {
            CarbonIcon(name: "edit", size: 16, color: Carbon.iconSecondary)
            TextField("Add a note at this point in the call…  (⌥⌘N from anywhere)", text: $text)
                .textFieldStyle(.plain)
                .font(CarbonFont.body(14))
                .foregroundStyle(Carbon.textPrimary)
                .onSubmit(submit)
            if model.noteCount > 0 {
                Text("\(model.noteCount) note\(model.noteCount == 1 ? "" : "s")")
                    .font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
            }
            CarbonButton(title: "Add note", icon: "edit", kind: .secondary, action: submit)
        }
        .padding(Space.x4)
        .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
        }
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return }
        model.addNote?(trimmed)
        text = ""
    }
}

/// Observes only the recording level meter, so its ~12 Hz updates re-render this view alone.
/// Driven by whichever track is the live source (mic, or system for a system-audio conference).
private struct LevelPane: View {
    @ObservedObject var meter = AppModel.shared.meter
    var body: some View { LevelMeter(level: meter.level) }
}

/// Observes only the live transcript model; per-word volatile updates stay inside this pane.
private struct LiveTranscriptPane: View {
    let title: String
    @ObservedObject var live = AppModel.shared.live

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            SectionHeader(title: title)
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.x3) {
                        if live.finalized.isEmpty && live.partial.isEmpty {
                            Text("Listening…").font(CarbonFont.body(14)).foregroundStyle(Carbon.textSecondary)
                        }
                        // Indices are stable ids here: the array is append-only during a recording.
                        ForEach(live.finalized.indices, id: \.self) { i in
                            Text(live.finalized[i]).font(CarbonFont.body(15)).foregroundStyle(Carbon.textPrimary)
                        }
                        if !live.partial.isEmpty {
                            Text(live.partial).font(CarbonFont.body(15)).foregroundStyle(Carbon.textSecondary)
                        }
                        Color.clear.frame(height: 1).id("live-bottom")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(Space.x5)
                }
                .onChange(of: live.finalized.count) { _, _ in withAnimation { proxy.scrollTo("live-bottom", anchor: .bottom) } }
                .onChange(of: live.partial) { _, _ in proxy.scrollTo("live-bottom", anchor: .bottom) }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
        }
        .frame(maxHeight: .infinity)
    }
}

/// A minimal flow layout that wraps its children.
struct FlexWrap: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
