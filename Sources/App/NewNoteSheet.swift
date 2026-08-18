import ScriptaShared
import SwiftUI

/// Write a note by hand, with the spine supplied — the vault browser's door to the same form the Add
/// page draws inline.
///
/// A SHEET HERE, INLINE THERE, ONE FORM BEHIND BOTH. The browser is a reading surface and a note
/// written from it is an interruption that should return you to what you were reading; the Add page
/// is where you go to add something, so it has no reason to cover itself with a modal. The fields
/// live in `NoteDraftFields` so the two cannot drift.
///
/// IT DOES NOT EDIT. Create is the only verb: the file belongs to the operator once it lands, and
/// Obsidian edits it better than anything grown here. See `NoteWriter`.
struct NewNoteSheet: View {
    let workspace: String
    let sharedVaultName: String?
    /// Returns a refusal to show, or `nil` when the note was written.
    let create: (NoteDraft) -> String?

    @Environment(\.dismiss) private var dismiss
    @State private var draft = NoteDraft()
    @State private var refusal: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s12) {
            VStack(alignment: .leading, spacing: Gap.s4) {
                Text("New note").typeface(Register.title3, Ink.textPrimary)
                Text("A Markdown file you can edit anywhere, composed so Ask can find it.")
                    .proseText(Register.proseSm, Ink.textHelper)
            }
            ScrollView {
                NoteDraftFields(draft: $draft, workspace: workspace,
                                sharedVaultName: sharedVaultName)
                    .padding(.trailing, Gap.s4)
            }
            footer
        }
        .padding(Gap.s16)
        .frame(width: 520, height: 620)
        .background(Ink.background)
        .alert("This note could not be written", isPresented: .init(
            get: { refusal != nil }, set: { if !$0 { refusal = nil } })) {
            Button("OK", role: .cancel) { refusal = nil }
        } message: {
            Text(refusal ?? "")
        }
    }

    private var footer: some View {
        HStack(spacing: Gap.s8) {
            Spacer()
            ActionButton(title: "Cancel", rank: .tertiary) { dismiss() }
            ActionButton(title: "Create", glyph: .add, rank: .primary, action: submit)
        }
    }

    /// DISMISSES ONLY ON SUCCESS. A refused note keeps the sheet and everything typed into it —
    /// closing on a collision would discard the body and leave the operator to retype it.
    private func submit() {
        if let reason = create(draft) { refusal = reason } else { dismiss() }
    }
}
