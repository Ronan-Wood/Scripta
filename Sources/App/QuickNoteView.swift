import SwiftUI

/// The floating quick-note input the ⌥⌘N hotkey shows during a recording. Return adds the note,
/// Escape (or the close button) dismisses. Purpose-built Carbon so it matches the hub.
struct QuickNoteView: View {
    let onSubmit: (String) -> Void
    let onClose: () -> Void

    @ObservedObject private var model = AppModel.shared
    @State private var text = ""
    @FocusState private var focused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack {
                SectionHeader(title: "Add note")
                Spacer()
                if model.noteCount > 0 {
                    Text("\(model.noteCount) this call")
                        .font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary)
                }
            }
            TextField("Jot a note for this call…", text: $text)
                .textFieldStyle(.plain)
                .font(CarbonFont.body(15))
                .foregroundStyle(Carbon.textPrimary)
                .focused($focused)
                .onSubmit(submit)
                .padding(Space.x3)
                .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                .overlay {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
                }
            HStack {
                Text("↩ add · esc close").font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary)
                Spacer()
                CarbonButton(title: "Add", icon: "edit", kind: .primary, action: submit)
            }
        }
        .padding(Space.x4)
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        .background(Carbon.background)
        .onAppear { focused = true }
        .onExitCommand(perform: onClose)
    }

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { onClose(); return }
        onSubmit(trimmed)
        text = ""
        onClose()
    }
}
