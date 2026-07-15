import SwiftUI

/// Record-time prompt: what should screen context read from this recording — the frontmost window,
/// the whole screen, one specific window, or nothing. Carbon-styled.
struct ScreenSourcePrompt: View {
    struct WindowOption: Identifiable, Hashable { let id: CGWindowID; let label: String }

    let windows: [WindowOption]
    let onDone: (ScreenChoice) -> Void

    @State private var kind: Kind = .frontmost
    @State private var windowID: CGWindowID?

    enum Kind: Hashable { case frontmost, screen, window, off }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x4) {
            Text("Screen context").font(CarbonFont.semibold(16)).foregroundStyle(Carbon.textPrimary)
            Text("What should the transcript read from your screen? Screenshots are OCR'd on-device, then discarded — only text is kept.")
                .font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
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

            HStack {
                Toggle("Always ask", isOn: Binding(
                    get: { AppSettings.askScreenSourceOnRecord },
                    set: { AppSettings.askScreenSourceOnRecord = $0 }
                )).font(CarbonFont.label(12)).toggleStyle(.checkbox)
                Spacer()
                Button("Cancel") { onDone(.cancel) }.keyboardShortcut(.cancelAction)
                Button("Start") { start() }.keyboardShortcut(.defaultAction).buttonStyle(.borderedProminent)
                    .disabled(kind == .window && windowID == nil)
            }
            .padding(.top, Space.x2)
        }
        .padding(Space.x6)
        .frame(width: 420)
        .background(Carbon.background)
    }

    private func option(_ value: Kind, _ title: String, _ subtitle: String) -> some View {
        Button { kind = value } label: {
            HStack(alignment: .top, spacing: Space.x3) {
                Image(systemName: kind == value ? "largecircle.fill.circle" : "circle")
                    .foregroundStyle(kind == value ? Carbon.interactive : Carbon.iconSecondary)
                VStack(alignment: .leading, spacing: 1) {
                    Text(title).font(CarbonFont.medium(13)).foregroundStyle(Carbon.textPrimary)
                    Text(subtitle).font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary)
                }
                Spacer()
            }
            .padding(Space.x3)
            .background(kind == value ? Carbon.interactive.opacity(0.10) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    private func start() {
        switch kind {
        case .frontmost: onDone(.source(.frontmostWindow))
        case .screen: onDone(.source(.display))
        case .off: onDone(.source(.off))
        case .window:
            if let id = windowID, let label = windows.first(where: { $0.id == id })?.label {
                onDone(.source(.window(id, label)))
            } else {
                onDone(.source(.frontmostWindow))
            }
        }
    }
}
