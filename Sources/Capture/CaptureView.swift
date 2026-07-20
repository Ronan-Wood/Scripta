import SwiftUI

/// The floating Quick Capture panel (idle ⌥⌘N): already listening when it appears, live
/// dictation streams into an editable buffer — type, speak, or both. Typing works even if the
/// mic is still starting or failed outright (`.saving` is the only state without it, since
/// finish() has already read the buffer by then). ⌘Return saves, Escape discards. The voice
/// sibling of `QuickNoteView` — that one jots typed notes into a live recording; this one
/// captures a standalone thought into the workspace's Captures note.
struct CaptureView: View {
    @ObservedObject var session: CaptureSession
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var pulsing = false
    @FocusState private var editorFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack(spacing: Space.x2) {
                SectionHeader(title: "Quick Capture")
                if case .listening = session.state {
                    Circle()
                        .fill(Carbon.danger)
                        .frame(width: 7, height: 7)
                        .opacity(pulsing ? 0.25 : 1)
                        .animation(.easeInOut(duration: 0.9).repeatForever(autoreverses: true), value: pulsing)
                        .onAppear { pulsing = true }
                }
                Spacer()
                if !session.group.isEmpty {
                    Text(session.group)
                        .font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary)
                }
            }

            card

            HStack {
                Text("⌘↩ save · esc discard")
                    .font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary)
                Spacer()
                // .disabled(!canSave) already proves modifiers reach CarbonButton's inner
                // Button (that's the same mechanism .keyboardShortcut uses), so the shortcut
                // lives directly here — no hidden-button workaround needed.
                CarbonButton(title: "Save", icon: "microphone", kind: .primary, action: onSave)
                    .disabled(!canSave)
                    .keyboardShortcut(.return, modifiers: .command)
            }
        }
        .padding(Space.x4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Carbon.background)
        .onExitCommand(perform: onCancel)
    }

    @ViewBuilder private var card: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            switch session.state {
            case .saving:
                // The only state with no editor: finish() has already read `text` by the time
                // this shows, so further typing here wouldn't be reflected in what gets saved.
                Text("Cleaning & saving…")
                    .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
            default:
                if case .starting = session.state {
                    Text("Starting microphone — you can type while it warms up.")
                        .font(CarbonFont.body(12)).foregroundStyle(Carbon.textSecondary)
                } else if case .failed(let message) = session.state {
                    Text(message)
                        .font(CarbonFont.body(12)).foregroundStyle(Carbon.danger)
                }
                // Overlay placeholder: TextEditor has no native placeholder param. Hit-testing
                // is disabled on it so a click always reaches the editor underneath.
                ZStack(alignment: .topLeading) {
                    if session.text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        Text(placeholderText)
                            .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
                            .padding(.top, 8).padding(.leading, 5)
                            .allowsHitTesting(false)
                    }
                    TextEditor(text: $session.text)
                        .font(CarbonFont.body(14))
                        .foregroundStyle(Carbon.textPrimary)
                        .scrollContentBackground(.hidden)
                        .focused($editorFocused)
                        .onAppear { editorFocused = true }
                }
                .frame(minHeight: 60)
                if !session.partial.isEmpty {
                    Text(session.partial)
                        .font(CarbonFont.body(12)).foregroundStyle(Carbon.textSecondary)
                        .lineLimit(2)
                }
            }
        }
        .frame(maxWidth: .infinity, minHeight: 60, alignment: .topLeading)
        .padding(Space.x3)
        .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
        }
    }

    private var placeholderText: String {
        switch session.state {
        case .listening: return "Listening — speak, or click here to type."
        case .starting: return "Type here — or wait for the mic."
        case .failed: return "Microphone unavailable — you can still type."
        case .saving: return ""
        }
    }

    private var canSave: Bool {
        if case .saving = session.state { return false }
        return session.hasText
    }
}
