import Foundation
import ScriptaCore

/// Lands a capture in the workspace's rolling "Captures" note — found by title, created on
/// first use — and indexes it immediately so Clovis/search/MCP see it without waiting for a
/// reconcile. Zero filing decisions by design (M14): the destination is never asked.
enum CaptureStore {
    static let noteTitle = "Captures"

    @discardableResult
    static func save(_ text: String, group: String) -> Bool {
        let note = NoteStore.list(group: group).first { $0.title == noteTitle }
            ?? NoteStore.create(title: noteTitle, group: group)
        guard let note,
              let refreshed = NoteStore.append(text, linkedCall: nil, to: note) else { return false }
        if let store = IndexStore.shared {
            let url = refreshed.url
            Task.detached(priority: .utility) { IndexBuilder.indexNote(url, into: store) }
        }
        return true
    }
}
