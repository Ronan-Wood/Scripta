import SwiftUI
import ScriptaCore

// The two sheets KnowledgeView presents. They live in concrete structs, not `@ViewBuilder`
// helpers on KnowledgeView, because the type checker only gets a real inference boundary from a
// separate type: EntityDetailView's init got one field more complex for M21 (entityID/fallbackName
// became @State for in-place retargeting), which was enough to push the surrounding expression on
// `body` past the solver's timeout, and M24's document sheet added a second construction to the
// same already-long modifier chain. A struct per sheet keeps each one out of `body`'s expression
// entirely rather than merely moving it a few lines down the same file.

/// A document's extracted text, opened in-app from the Documents shelf.
struct DocumentSheet: View {
    let target: OpenDocTarget
    @Binding var openDoc: OpenDocTarget?
    @Binding var deleteTarget: KnowledgeView.ItemTarget?

    var body: some View {
        DocumentDetailView(doc: target.meta, mdURL: target.mdURL) {
            openDoc = nil
        } onDelete: {
            deleteTarget = .doc(mdURL: target.mdURL, title: target.meta.title)
            openDoc = nil
        }
    }
}

/// One person/topic's own page (M19), opened from the rail, a commitment owner, or a vocab chip.
struct EntitySheet: View {
    let target: EntitySheetTarget
    @Binding var entitySheetTarget: EntitySheetTarget?
    @Binding var openNote: KnowledgeNote?
    let onCommitmentsChanged: () -> Void
    @ObservedObject var model = AppModel.shared

    var body: some View {
        EntityDetailView(entityID: target.id, group: model.activeGroup, fallbackName: target.fallbackName) {
            entitySheetTarget = nil
        } onCommitmentsChanged: {
            onCommitmentsChanged()
        } onOpenNote: { path in
            if let note = NoteStore.verified(atPath: path, group: model.activeGroup) { openNote = note }
        } onOpenDoc: { path in
            if let url = DocumentImporter.verifiedOriginalURL(atPath: path, group: model.activeGroup) {
                NSWorkspace.shared.open(url)
            }
        }
    }
}
