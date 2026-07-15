import SwiftUI

/// Record-time options prompt: the recording **mode** (Call vs Conference, and which single source
/// a conference captures) and, when screen context is on, what screen area the transcript reads
/// from. Carbon-styled.
struct ScreenSourcePrompt: View {
    struct WindowOption: Identifiable, Hashable { let id: CGWindowID; let label: String }

    let windows: [WindowOption]
    let screenEnabled: Bool
    let onDone: (RecordingChoice) -> Void

    @State private var modeKind: ModeKind
    @State private var conferenceSource: ConferenceSource
    @State private var kind: Kind = .frontmost
    @State private var windowID: CGWindowID?

    enum ModeKind: Hashable { case call, conference }
    enum Kind: Hashable { case frontmost, screen, window, off }

    init(windows: [WindowOption], screenEnabled: Bool, initialMode: RecordingMode,
         onDone: @escaping (RecordingChoice) -> Void) {
        self.windows = windows
        self.screenEnabled = screenEnabled
        self.onDone = onDone
        switch initialMode {
        case .call:
            _modeKind = State(initialValue: .call)
            _conferenceSource = State(initialValue: .system)
        case .conference(let source):
            _modeKind = State(initialValue: .conference)
            _conferenceSource = State(initialValue: source)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            Text("Recording options").font(CarbonFont.semibold(16)).foregroundStyle(Carbon.textPrimary)

            // MARK: Mode
            Picker("", selection: $modeKind) {
                Text("Call").tag(ModeKind.call)
                Text("Conference").tag(ModeKind.conference)
            }
            .pickerStyle(.segmented).labelsHidden()

            Text(modeKind == .call
                 ? "Two people. Your mic is “You”, the other side is “Them”."
                 : "One room. Records a single source so a hybrid meeting — you in the room and joined online — isn’t transcribed twice. No You/Them labels.")
                .font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                .fixedSize(horizontal: false, vertical: true)

            if modeKind == .conference {
                VStack(spacing: Space.x2) {
                    sourceOption(.system, "System audio", "The online meeting mix — everyone on the call.")
                    sourceOption(.microphone, "Microphone", "The room around you.")
                }
            }

            // MARK: Screen context (only when enabled)
            if screenEnabled {
                Rectangle().fill(Carbon.borderSubtle).frame(height: 1).padding(.vertical, Space.x1)
                Text("Screen context").font(CarbonFont.medium(13)).foregroundStyle(Carbon.textPrimary)
                Text("Screenshots are OCR'd on-device, then discarded — only text is kept.")
                    .font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
                VStack(spacing: Space.x2) {
                    option(.frontmost, "Frontmost window", "Follows whatever window you're in.")
                    option(.screen, "Whole screen", "The entire display.")
                    option(.window, "A specific window", windows.isEmpty ? "No windows found." : "Locks to one window.")
                    if kind == .window && !windows.isEmpty {
                        Picker("", selection: $windowID) {
                            Text("Choose…").tag(CGWindowID?.none)
                            ForEach(windows) { Text($0.label).tag(CGWindowID?.some($0.id)) }
                        }
                        .labelsHidden().padding(.leading, Space.x7)
                    }
                    option(.off, "Don't capture screen", "Audio only for this recording.")
                }
            }

            HStack {
                Toggle("Always ask", isOn: Binding(
                    get: { AppSettings.askScreenSourceOnRecord },
                    set: { AppSettings.askScreenSourceOnRecord = $0 }
                )).font(CarbonFont.label(12)).toggleStyle(.checkbox)
                Spacer()
                Button("Cancel") { onDone(.cancel) }.keyboardShortcut(.cancelAction)
                Button("Start") { start() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(screenEnabled && kind == .window && windowID == nil)
            }
            .padding(.top, Space.x2)
        }
        .padding(Space.x6)
        .frame(width: 420)
        .background(Carbon.background)
    }

    private func sourceOption(_ value: ConferenceSource, _ title: String, _ subtitle: String) -> some View {
        radio(isOn: conferenceSource == value, title: title, subtitle: subtitle) { conferenceSource = value }
    }

    private func option(_ value: Kind, _ title: String, _ subtitle: String) -> some View {
        radio(isOn: kind == value, title: title, subtitle: subtitle) { kind = value }
    }

    private func radio(isOn: Bool, title: String, subtitle: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(alignment: .top, spacing: Space.x3) {
                Image(systemName: isOn ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(isOn ? Carbon.interactive : Carbon.iconSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(CarbonFont.medium(13)).foregroundStyle(Carbon.textPrimary)
                    Text(subtitle).font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary)
                }
                Spacer()
            }
            .padding(Space.x3)
            .background(isOn ? Carbon.interactive.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func start() {
        let mode: RecordingMode = modeKind == .call ? .call : .conference(conferenceSource)

        var source: ScreenSource = .off
        if screenEnabled {
            switch kind {
            case .frontmost: source = .frontmostWindow
            case .screen: source = .display
            case .off: source = .off
            case .window:
                if let id = windowID, let label = windows.first(where: { $0.id == id })?.label {
                    source = .window(id, label)
                } else {
                    source = .frontmostWindow
                }
            }
        }
        onDone(.start(mode: mode, screenSource: source))
    }
}

/// Result of the record-time options prompt.
enum RecordingChoice {
    case cancel
    case start(mode: RecordingMode, screenSource: ScreenSource)
}
