import SwiftUI
import ScriptaCore

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
        }
    }
}
