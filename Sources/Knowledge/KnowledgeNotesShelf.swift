import SwiftUI
import ScriptaCore

/// The notes shelf — the living documents you work out of, plus the two ways new ones arrive
/// (import a file, start a note).
struct KnowledgeNotesShelf: View {
    let notes: [KnowledgeNote]
    @Binding var openNote: KnowledgeNote?
    @Binding var deleteTarget: KnowledgeView.ItemTarget?
    let onImport: () -> Void
    let onNewNote: () -> Void
    let onRename: (KnowledgeView.ItemTarget) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack {
                SectionHeader(title: "Your notes")
                Spacer()
                CarbonButton(title: "Import file", icon: "document", kind: .secondary,
                             action: onImport)
                    .help("PDF, PowerPoint, Word, images — analyzed on-device, searchable everywhere. Or just drop files anywhere on this pane.")
                CarbonButton(title: "New note", icon: "edit", kind: .secondary, action: onNewNote)
            }
            if notes.isEmpty {
                Text("Standing notes you keep adding to — a deal, a project, a person. Create one, or add a call to a note from the digest below.")
                    .font(CarbonFont.label(13)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                let columns = [GridItem(.adaptive(minimum: 240), spacing: Space.x4)]
                LazyVGrid(columns: columns, alignment: .leading, spacing: Space.x4) {
                    ForEach(notes) { note in
                        NoteShelfCard(note: note, open: { openNote = note },
                                      onRename: { onRename(.note(note)) },
                                      onDelete: { deleteTarget = .note(note) })
                    }
                }
            }
        }
    }
}

/// A standing note on the shelf: title, freshness, last entry.
private struct NoteShelfCard: View {
    let note: KnowledgeNote
    let open: () -> Void
    let onRename: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x2) {
            HStack(spacing: Space.x2) {
                CarbonIcon(name: "book", size: 14, color: Carbon.interactive)
                Text(note.title).font(CarbonFont.medium(14)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                Spacer()
                ItemMenu(open: open, openLabel: "Open", onRename: onRename, onDelete: onDelete)
            }
            if let last = note.entries.last {
                Text(last.text).font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary).lineLimit(2)
            }
            Text("\(note.entries.count) entr\(note.entries.count == 1 ? "y" : "ies") · updated \(note.updated)")
                .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
        }
        .padding(Space.x4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: open)
    }
}
