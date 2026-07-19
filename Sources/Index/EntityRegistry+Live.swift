import Foundation
import ScriptaCore

extension EntityRegistry {
    /// Shared instance rooted in the output folder (vault). Re-pointed by the folder-change
    /// flows (SettingsView.chooseFolder, first-run chooser) alongside the watcher and index.
    /// Lives app-side so the registry itself (in ScriptaCore) never reads AppSettings.
    static var shared = EntityRegistry(
        url: AppSettings.outputFolder.appendingPathComponent(".calltranscriber-registry.json"))
}
