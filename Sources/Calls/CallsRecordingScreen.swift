import SwiftUI
import ScriptaCore

/// The call in progress: transport, note entry, the live transcript, and what the vault and the
/// local index already know about what is being said.
///
/// RESCUED FROM `HomeView`, WHICH DELETED IT. Doc 4 §2 retires Home as "Swift aggregates over the
/// local index" — true of its dashboard and false of this, which was the other half of the same
/// file and the only host `LiveTranscriptPane`, `NoteComposer`, `LevelPane`, `RelatedCallsPanel`
/// and `LiveRecallPanel` had. Deleting the file deleted the recording surface, and NOTHING WENT
/// RED: an unreferenced SwiftUI view compiles perfectly, so the build stayed green while the app
/// lost the screen it shows during a call. `FlexWrap` was the same failure in the same file and the
/// compiler caught that one, which is the only reason it looked like the whole risk.
///
/// IT LIVES IN CALLS BECAUSE IT IS ONE. A call being recorded is not a section of its own — it is
/// the newest row of the list beside it, before it has finished — so it is a lens of Calls that
/// selects itself when recording starts and is offered only while one is running.
struct CallsRecordingScreen: View {
    @ObservedObject private var model = AppModel.shared

    var body: some View {
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

    // MARK: - Transport

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
        switch model.recordingState {
        case .idle: return "⌥⌘R from anywhere, or the Record pill above."
        case .recording: return ""
        case .processing: return "Writing the transcript into this workspace's vault."
        }
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
