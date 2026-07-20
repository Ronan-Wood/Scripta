import SwiftUI

/// The floating Quick Capture panel (idle ⌥⌘N): already listening when it appears, live
/// dictation streams into an editable buffer — type, speak, or both. ⌘Return saves, Escape
/// discards. The voice sibling of `QuickNoteView` — that one jots typed notes into a live
/// recording; this one captures a standalone thought into the workspace's Captures note.
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
                CarbonButton(title: "Save", icon: "microphone", kind: .primary, action: onSave)
                    .disabled(!canSave)
                // A bare Button owns the shortcut: CarbonButton wraps its own Button internally,
                // so a `.keyboardShortcut` applied from outside wouldn't reach the real control.
                // Plain Return must stay free for the editor to insert a newline, hence ⌘Return.
                Button(action: { if canSave { onSave() } }) { EmptyView() }
                    .keyboardShortcut(.return, modifiers: .command)
                    .hidden()
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
            case .starting:
                Text("Starting microphone…")
                    .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
            case .failed(let message):
                Text(message)
                    .font(CarbonFont.body(13)).foregroundStyle(Carbon.danger)
            case .saving:
                Text("Cleaning & saving…")
                    .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
            case .listening:
                // Overlay placeholder: TextEditor has no native placeholder param. Hit-testing
                // is disabled on it so a click always reaches the editor underneath.
                ZStack(alignment: .topLeading) {
                    if session.text.isEmpty {
                        Text("Listening — speak, or click here to type.")
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

    private var canSave: Bool {
        if case .listening = session.state { return session.hasText }
        return false
    }
}
