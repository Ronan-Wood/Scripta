import Foundation
import ScriptaCore

extension EntityMirror {
    /// App entry point: gated on the opt-in mirror setting, rooted in the configured vault.
    /// No-op unless mirroring is enabled.
    static func sync(store: IndexStore) {
        guard AppSettings.mirrorEnabled else { return }
        sync(store: store, vault: AppSettings.outputFolder)
    }
}
