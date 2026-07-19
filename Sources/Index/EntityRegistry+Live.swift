import Foundation
import ScriptaCore

extension EntityRegistry {
    /// Shared instance rooted in the output folder (vault) as of first access. A mid-session
    /// folder change does NOT re-point it today — writes keep landing in the old folder until
    /// relaunch (tracked gap; the folder-change flow re-points only the watcher and index).
    /// Lives app-side so the registry itself (in ScriptaCore) never reads AppSettings.
    static var shared = EntityRegistry(
        url: AppSettings.outputFolder.appendingPathComponent(".calltranscriber-registry.json"))
}
