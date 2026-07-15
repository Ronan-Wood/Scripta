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
        _participants = State(initialValue: participants.joined(separator: ", "))
        _tags = State(initialValue: tags.joined(separator: ", "))
        self.onDone = onDone
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Call Details").font(.headline)

            VStack(alignment: .leading, spacing: 5) {
                Text("Title").font(.caption).foregroundStyle(.secondary)
                TextField("Untitled call", text: $title)
                    .textFieldStyle(.roundedBorder)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Participants").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. Chris Dempsey, Jane Doe", text: $participants)
                    .textFieldStyle(.roundedBorder)
                Text("Separate names with commas — used for “calls with …” search.")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            VStack(alignment: .leading, spacing: 5) {
                Text("Tags").font(.caption).foregroundStyle(.secondary)
                TextField("e.g. pricing, lease, hiring", text: $tags)
                    .textFieldStyle(.roundedBorder)
                Text("Topics for search and the tag index (auto-suggested from the call; edit freely).")
                    .font(.caption2).foregroundStyle(.tertiary)
            }

            if let errorMessage {
                Text(errorMessage).font(.caption).foregroundStyle(.red)
            }

            HStack {
                Spacer()
                Button("Cancel") { onDone(false) }
                    .keyboardShortcut(.cancelAction)
                Button("Save") { save() }
                    .keyboardShortcut(.defaultAction)
                    .buttonStyle(.borderedProminent)
            }
        }
        .padding(20)
        .frame(width: 400)
    }

    private func save() {
        func list(_ s: String) -> [String] {
            s.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
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
