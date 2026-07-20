import SwiftUI

/// The floating Quick Capture panel (idle ⌥⌘N): already listening when it appears, live text
/// streams in, Return saves, Escape discards. The voice sibling of `QuickNoteView` — that one
/// jots typed notes into a live recording; this one speaks thoughts into the workspace's
/// Captures note when no recording is running.
struct CaptureView: View {
    @ObservedObject var session: CaptureSession
    let onSave: () -> Void
    let onCancel: () -> Void

    @State private var pulsing = false

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

            ScrollView {
                VStack(alignment: .leading, spacing: Space.x2) {
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
                        if session.hasText {
                            Text(session.finalized.joined(separator: " "))
                                .font(CarbonFont.body(14)).foregroundStyle(Carbon.textPrimary)
                            + Text(session.finalized.isEmpty ? "" : " ")
                            + Text(session.partial)
                                .font(CarbonFont.body(14)).foregroundStyle(Carbon.textSecondary)
                        } else {
                            Text("Listening — speak your thought.")
                                .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
            }
            .defaultScrollAnchor(.bottom)
            .frame(minHeight: 60)
            .padding(Space.x3)
            .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                    .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
            }

            HStack {
                Text("↩ save · esc discard")
                    .font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary)
                Spacer()
                CarbonButton(title: "Save", icon: "microphone", kind: .primary, action: onSave)
                    .disabled(!canSave)
                // Return triggers Save without a text field to own the key. Hidden so the
                // Carbon button stays the visible affordance.
                Button(action: { if canSave { onSave() } }) { EmptyView() }
                    .keyboardShortcut(.defaultAction)
                    .hidden()
            }
        }
        .padding(Space.x4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Carbon.background)
        .onExitCommand(perform: onCancel)
    }

    private var canSave: Bool {
        if case .listening = session.state { return session.hasText }
        return false
    }
}
