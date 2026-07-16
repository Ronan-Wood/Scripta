import SwiftUI

/// The hub's Home dashboard: record, what's coming up, what's recent, and the topic index —
/// everything at a glance. Purpose-built Carbon, driven by the shared AppModel.
struct HomeView: View {
    @ObservedObject var model = AppModel.shared
    @State private var topics: [(name: String, count: Int)] = []

    var body: some View {
        Group {
            if model.recordingState == .recording {
                recordingScreen
            } else {
                dashboard
            }
        }
        .background(Carbon.background)
        .onAppear {
            model.reloadCalls()
            topics = Array((model.index?.tags() ?? []).prefix(12))
        }
    }

    private var dashboard: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Space.x6) {
                Text("Home").font(CarbonFont.headingLg).foregroundStyle(Carbon.textPrimary)

                recordCard
                if !model.upcomingMeetings.isEmpty { meetingsSection }

                HStack(alignment: .top, spacing: Space.x5) {
                    recentCallsSection.frame(maxWidth: .infinity, alignment: .leading)
                    topicsSection.frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding(Space.x7)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Recording screen

    private var recordingScreen: some View {
        VStack(spacing: Space.x5) {
            recordCard
            NoteComposer()
            HStack(alignment: .top, spacing: Space.x5) {
                LiveTranscriptPane(title: liveTitle).frame(maxWidth: .infinity, maxHeight: .infinity)
                RelatedCallsPanel().frame(width: 300)
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
        CarbonCard {
            HStack(spacing: Space.x5) {
                statusDot
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
        }
    }

    private var statusDot: some View {
        Circle()
            .fill(model.isPaused ? Carbon.warning :
                    model.recordingState == .recording ? Carbon.danger :
                    model.recordingState == .processing ? Carbon.warning : Carbon.borderStrong)
            .frame(width: 10, height: 10)
    }
    private var statusTitle: String {
        switch model.recordingState {
        case .idle: return "Ready to record"
        case .recording: return model.isPaused ? "Paused" : "Recording…"
        case .processing: return "Transcribing…"
        }
    }
    private var statusSubtitle: String {
        switch model.recordingState {
        case .idle: return "Captures both sides on-device. Nothing leaves your Mac."
        case .recording: return "Mic and system audio are being captured."
        case .processing: return "Transcribing and writing the note."
        }
    }

    // MARK: - Meetings

    private var meetingsSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            SectionHeader(title: "Upcoming meetings")
            VStack(spacing: 1) {
                ForEach(model.upcomingMeetings.prefix(3)) { meeting in
                    HStack(spacing: Space.x4) {
                        CarbonIcon(name: "calendar", size: 16, color: Carbon.iconSecondary)
                        VStack(alignment: .leading, spacing: Space.x1) {
                            Text(meeting.title).font(CarbonFont.medium(14)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                            Text("\(relative(meeting.start)) · \(meeting.service)")
                                .font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                        }
                        Spacer()
                        if model.recordingState == .idle {
                            CarbonButton(title: "Record this", icon: "recording", kind: .secondary) {
                                model.recordMeeting?(meeting)
                            }
                        }
                    }
                    .padding(Space.x4)
                    .background(Carbon.layer)
                }
            }
            .clipShape(RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.card, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
        }
    }

    // MARK: - Recent calls

    private var recentCallsSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            SectionHeader(title: "Recent calls")
            if model.calls.isEmpty {
                Text("No calls yet.").font(CarbonFont.label(13)).foregroundStyle(Carbon.textSecondary)
            } else {
                VStack(spacing: 1) {
                    ForEach(model.calls.prefix(6)) { meta in
                        Button { model.route = .call(meta.url) } label: {
                            VStack(alignment: .leading, spacing: Space.x1) {
                                Text(meta.displayTitle).font(CarbonFont.medium(14))
                                    .foregroundStyle(Carbon.textPrimary).lineLimit(1)
                                if !meta.subtitle.isEmpty {
                                    Text(meta.subtitle).font(CarbonFont.label(12))
                                        .foregroundStyle(Carbon.textSecondary).lineLimit(1)
                                }
                            }
                            .padding(Space.x4)
                            .frame(maxWidth: .infinity, alignment: .leading)
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

    // MARK: - Topics

    private var topicsSection: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            SectionHeader(title: "Recent topics")
            if topics.isEmpty {
                Text("Topics appear as calls are tagged.").font(CarbonFont.label(13)).foregroundStyle(Carbon.textSecondary)
            } else {
                FlowChips(topics: topics) { model.route = .tag($0) }
            }
        }
    }

    private func relative(_ date: Date) -> String {
        let mins = Int(date.timeIntervalSinceNow / 60)
        if mins <= 0 { return "now" }
        if mins < 60 { return "in \(mins) min" }
        let fmt = DateFormatter(); fmt.dateFormat = "h:mm a"
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

/// Simple wrapping chip layout.
private struct FlowChips: View {
    let topics: [(name: String, count: Int)]
    let onTap: (String) -> Void

    var body: some View {
        FlexWrap(spacing: Space.x2) {
            ForEach(topics, id: \.name) { t in
                CarbonChip(text: t.name) { onTap(t.name) }
            }
        }
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
