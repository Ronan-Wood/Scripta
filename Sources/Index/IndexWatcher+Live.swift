import Foundation
import ScriptaCore

extension IndexWatcher {
    /// The app's watcher over the output folder: reconcile the index, then refresh the hub.
    /// The action is injected here so the watcher itself (in ScriptaCore) stays dependency-free.
    static let shared: IndexWatcher? = IndexStore.shared.map { store in
        IndexWatcher {
            IndexBuilder.reconcile(store: store)
            Task { @MainActor in AppModel.shared.reloadCalls() }
        }
    }
}
