import SwiftUI

/// Small form for naming a call and its participants. Writes straight to the transcript's
/// frontmatter via `TranscriptMetadataEditor`. Used both as the post-record prompt and from the
/// viewer's "Edit Details" action. Editing is limited to metadata — the transcript body is never
/// touched here (the viewer stays read-only for content).
struct TranscriptDetailsEditor: View {
    let url: URL
    @State private var title: String
    @State private var participants: String   // comma-separated, free text
    @State private var tags: String           // comma-separated, free text
    @State private var errorMessage: String?

    /// Called when the form is dismissed; `saved` is true only if changes were written.
    let onDone: (_ saved: Bool) -> Void

    init(url: URL, title: String, participants: [String], tags: [String], onDone: @escaping (_ saved: Bool) -> Void) {
        self.url = url
        _title = State(initialValue: title)
        _participants = State(initialValue: Self.joined(participants))
        _tags = State(initialValue: Self.joined(tags))
        self.onDone = onDone
    }

    /// Comma-joined normally; semicolon-joined when any item itself contains a comma
    /// ("Last, First" Exchange attendees), so the round-trip keeps names whole.
    private static func joined(_ items: [String]) -> String {
        items.contains { $0.contains(",") } ? items.joined(separator: "; ") : items.joined(separator: ", ")
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s16) {
            Text("Call Details").typeface(Register.title3, Ink.textPrimary)

            EditorField(label: "Title", prompt: "Untitled call", text: $title, onSubmit: save)

            EditorField(label: "Participants", prompt: "e.g. Chris Dempsey, Jane Doe",
                        text: $participants, onSubmit: save,
                        help: "Separate names with commas — or semicolons if a name contains a comma. Used for “calls with …” search.")

            EditorField(label: "Tags", prompt: "e.g. pricing, lease, hiring",
                        text: $tags, onSubmit: save,
                        help: "Topics for search and the tag index (auto-suggested from the call; edit freely).")

            if let errorMessage {
                Text(errorMessage).typeface(Register.caption, Ink.danger)
            }

            // Native `Button`s, deliberately. `.cancelAction` / `.defaultAction` are what give a
            // modal form Escape, Return, the pulsing default and VoiceOver's "default button" —
            // and nothing has established that `.keyboardShortcut` survives `Pressable`'s
            // `Button` → `.pressReporter` → `.focusEffectDisabled()` chain. Trading a working
            // Return-to-save for a typeface is the wrong side of that bet; see the migration's
            // gap list.
            HStack {
                Spacer()
                Button("Cancel") { onDone(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        // `Gap.s20` and not `Metrics.pageGutter`: a 400pt modal is not a content pane, and `Metrics`
        // has no dialog measurement at all — neither its inset nor its width.
        .padding(Gap.s20)
        .frame(width: 400)
    }

    private func save() {
        func list(_ s: String) -> [String] {
            let separator: Character = s.contains(";") ? ";" : ","
            return s.split(separator: separator).map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
        }
        do {
            try TranscriptMetadataEditor.update(url: url, title: title,
                                                participants: list(participants), tags: list(tags))
            onDone(true)
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}

/// A labelled field with optional help text.
///
/// The label is outside the field because `InputField` requires it to be: its prompt is decorative
/// and may not be the only place a field's meaning appears (the gate scores `textPlaceholder` on
/// `field` at 2.16:1). The help line is PROSE — a sentence someone wrote about how the field
/// behaves — which is the same call `Card`'s `note` makes, and the register is what tells a reader
/// it is explanation rather than another control.
private struct EditorField: View {
    let label: String
    let prompt: String
    @Binding var text: String
    var onSubmit: () -> Void = {}
    var help: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text(label).microLabel()
            InputField(prompt: prompt, text: $text, onSubmit: onSubmit)
            if let help {
                Text(help).proseText(Register.proseSm, Ink.textHelper)
            }
        }
    }
}
