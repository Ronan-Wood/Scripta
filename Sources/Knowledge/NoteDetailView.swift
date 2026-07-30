import SwiftUI
import ScriptaCore

/// The note itself: the accumulated entries, and the composer that appends the next one.
/// Presented as a sheet; `pendingLink` carries "this came from that call" when the flow
/// started on a digest card.
struct NoteDetailView: View {
    let note: KnowledgeNote
    let pendingLink: URL?
    let onChanged: (KnowledgeNote) -> Void
    let onClose: () -> Void
    let onDelete: () -> Void

    @ObservedObject var model = AppModel.shared
    @State private var draft = ""
    @FocusState private var composerFocused: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(note.title).font(CarbonFont.semibold(18)).foregroundStyle(Carbon.textPrimary)
                    Text("Started \(note.created) · Notes/\(note.url.lastPathComponent)")
                        .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                }
                Spacer()
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13)).foregroundStyle(Carbon.danger)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete this note")
                CarbonButton(title: "Done", kind: .secondary, action: onClose)
            }
            .padding(Space.x6)

            Divider().overlay(Carbon.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.x4) {
                    if note.entries.isEmpty {
                        Text("Nothing here yet — add the first entry below.")
                            .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
                    }
                    ForEach(Array(note.entries.enumerated()), id: \.offset) { _, entry in
                        VStack(alignment: .leading, spacing: Space.x1) {
                            HStack(spacing: Space.x3) {
                                Text(entry.stamp).font(CarbonFont.monospace(11)).foregroundStyle(Carbon.textHelper)
                                if let call = entry.linkedCall, !call.contains("/") {
                                    Button {
                                        let url = AppSettings.outputFolder.appendingPathComponent("\(call).md")
                                        // `call` comes from parsing freeform entry text (M14
                                        // crosscheck, security lens): the "/" reject above blocks
                                        // path components, this re-confirms the resolved file
                                        // still resolves inside outputFolder before navigating.
                                        let base = AppSettings.outputFolder.standardizedFileURL.path
                                        guard url.standardizedFileURL.path.hasPrefix(base + "/") else { return }
                                        onClose()
                                        model.route = .call(url)
                                    } label: {
                                        HStack(spacing: 2) {
                                            CarbonIcon(name: "document", size: 10, color: Carbon.interactive)
                                            Text(call).font(CarbonFont.label(11)).foregroundStyle(Carbon.interactive).lineLimit(1)
                                        }
                                        .contentShape(Rectangle())
                                    }
                                    .buttonStyle(.plain)
                                }
                            }
                            Text(entry.text).font(CarbonFont.body(14)).foregroundStyle(Carbon.textPrimary)
                                .fixedSize(horizontal: false, vertical: true)
                                .textSelection(.enabled)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                .padding(Space.x6)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)

            Divider().overlay(Carbon.borderSubtle)

            VStack(alignment: .leading, spacing: Space.x2) {
                if let pendingLink {
                    HStack(spacing: Space.x2) {
                        CarbonIcon(name: "document", size: 11, color: Carbon.interactive)
                        Text("Will link to \(pendingLink.deletingPathExtension().lastPathComponent)")
                            .font(CarbonFont.label(11)).foregroundStyle(Carbon.textSecondary).lineLimit(1)
                    }
                }
                HStack(spacing: Space.x3) {
                    TextField("Add to this note…", text: $draft, axis: .vertical)
                        .textFieldStyle(.plain)
                        .font(CarbonFont.body(14))
                        .foregroundStyle(Carbon.textPrimary)
                        .lineLimit(1...4)
                        .focused($composerFocused)
                        .onSubmit(submit)
                    CarbonButton(title: "Add", kind: .primary, action: submit)
                }
            }
            .padding(Space.x5)
            .background(Carbon.layer)
        }
        .frame(width: 560, height: 520)
        .background(Carbon.background)
        .onAppear { composerFocused = true }
    }

    private func submit() {
        guard let refreshed = NoteStore.append(draft, linkedCall: pendingLink, to: note) else { return }
        draft = ""
        onChanged(refreshed)
    }
}
