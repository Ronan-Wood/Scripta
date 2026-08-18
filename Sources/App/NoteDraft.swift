import ScriptaShared
import SwiftUI

/// One note being written, and the fields that write it.
///
/// EXTRACTED SO THERE IS ONE NOTE FORM. It is reached from two places — the Add page's Note kind and
/// the vault browser's New note sheet — and a second copy of these fields is a second place for the
/// `doc_type` vocabulary, the revealed judgement row, and the rule that a workspace note declares no
/// confidence to drift out of agreement with the engine. `NoteWriter` is the single writer; this is
/// the single form in front of it.
struct NoteDraft {
    var title = ""
    var docType = NoteSpine.defaultDocType
    var body = ""
    var destination = NoteDestination.workspace
    var confidence = NoteSpine.defaultConfidence
    var domains = NoteSpine.defaultSharedDomains

    /// What actually gets written, with the two judgement fields dropped for a workspace note.
    ///
    /// THE FIELDS KEEP THEIR VALUES WHILE THE DESTINATION SWITCHES, which is what makes this
    /// necessary: toggling to Shared and back leaves a confidence in state, and sending it would
    /// file a workspace note as judged when the whole point of omitting it is that nobody has.
    var resolvedConfidence: String? { destination.declaresJudgement ? confidence : nil }

    var resolvedDomains: [String] {
        destination.declaresJudgement ? domains.split(separator: ",").map(String.init) : []
    }

    var isWritable: Bool { !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
}

/// The note form. Bindings rather than state, so the owner decides where a draft lives and how long
/// it survives: the sheet holds its own and discards it on dismiss, while the Add page's draft lives
/// on `SubstrateLibraryModel` so leaving the lens does not throw away what was typed.
struct NoteDraftFields: View {
    @Binding var draft: NoteDraft
    let workspace: String
    /// `nil` when Settings names no shared vault. The destination is still OFFERED — the control
    /// then says what to do about it, which teaches more than a control that is not there.
    let sharedVaultName: String?
    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s12) {
            destinationField
            titleField
            typeField
            if draft.destination.declaresJudgement { judgementFields }
            bodyField
        }
        // A MEASURE, NOT THE WINDOW. Every field here ran the full width of a 2000pt window in the
        // first version — a title field a metre long and a body box to match, which is unreadable
        // and reads as an unfinished form. `formMaxWidth` is SHORTER than the prose cap: a field is
        // filled from the left, so width past the longest expected value is empty space.
        .frame(maxWidth: Metrics.formMaxWidth, alignment: .leading)
    }

    /// A RADIO, NOT A DROPDOWN. The two destinations are not two values of one setting — one is this
    /// workspace's own thinking, the other is the tier every context inherits. A menu makes them
    /// look interchangeable and puts the shared vault one mis-click from the default.
    private var destinationField: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text("Where it goes").typeface(Register.micro, Ink.textSecondary)
            Picker("", selection: $draft.destination) {
                Text("This workspace — \(workspace)").tag(NoteDestination.workspace)
                Text("Shared — every scope inherits it").tag(NoteDestination.shared)
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            if draft.destination.declaresJudgement {
                Text(sharedVaultName.map {
                    "Written into \($0). Every scope that inherits it is recomposed, so this note "
                    + "answers from all of them."
                } ?? "No shared vault is set yet — Settings → Shared vault. Add will say so rather "
                    + "than write the note somewhere else.")
                    .proseText(Register.proseSm, sharedVaultName == nil ? Ink.warning : Ink.textHelper)
            }
        }
    }

    private var titleField: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text("Title").typeface(Register.micro, Ink.textSecondary)
            TextField("What the note is about", text: $draft.title)
                .textFieldStyle(.roundedBorder)
        }
    }

    private var typeField: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text("What kind of note").typeface(Register.micro, Ink.textSecondary)
            Picker("", selection: $draft.docType) {
                ForEach(NoteSpine.docTypes) { type in
                    Text(type.label).tag(type.value)
                }
            }
            .labelsHidden()
            .pickerStyle(.menu)
            // THE GLOSS FOR THE SELECTED ONE, not a legend of all five. `doc_type` is the axis the
            // writing standard states as "one note, one job", and a reader picking blind picks the
            // first item every time.
            Text(NoteSpine.docTypes.first { $0.value == draft.docType }?.hint ?? "")
                .proseText(Register.proseSm, Ink.textHelper)
        }
    }

    /// Shown ONLY for the shared destination, which is the whole reason this is a revealed step. A
    /// workspace note omits both deliberately — an absent confidence stores as `unjudged`, the true
    /// statement about a note nobody has judged.
    private var judgementFields: some View {
        HStack(alignment: .top, spacing: Gap.s12) {
            VStack(alignment: .leading, spacing: Gap.s4) {
                Text("How settled").typeface(Register.micro, Ink.textSecondary)
                Picker("", selection: $draft.confidence) {
                    ForEach(NoteSpine.confidences) { level in
                        Text(level.label).tag(level.value)
                    }
                }
                .labelsHidden()
                .pickerStyle(.menu)
                Text(NoteSpine.confidences.first { $0.value == draft.confidence }?.hint ?? "")
                    .proseText(Register.proseSm, Ink.textHelper)
            }
            VStack(alignment: .leading, spacing: Gap.s4) {
                Text("Domains").typeface(Register.micro, Ink.textSecondary)
                TextField("operator, process", text: $draft.domains)
                    .textFieldStyle(.roundedBorder)
            }
        }
    }

    private var bodyField: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text("Note — Markdown, optional").typeface(Register.micro, Ink.textSecondary)
            TextEditor(text: $draft.body)
                .font(.system(size: 12, design: .monospaced))
                .frame(minHeight: 140)
                .overlay(RoundedRectangle(cornerRadius: 4)
                    .stroke(Ink.borderSubtle.color, lineWidth: 1))
        }
    }
}
