import Foundation
import ScriptaCore

extension EntityRegistry {
    /// Shared instance rooted in the current output folder (vault). Recreated when the folder moves.
    /// Lives app-side so the registry itself (in ScriptaCore) never reads AppSettings.
    static var shared = EntityRegistry(
        url: AppSettings.outputFolder.appendingPathComponent(".calltranscriber-registry.json"))
}
