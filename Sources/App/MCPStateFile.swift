import Foundation
import ScriptaCore
import ScriptaShared

/// The app vouching for its own workspace, so the ENGINE will answer from it.
///
/// IT OUTLIVED THE SERVER IT WAS WRITTEN FOR. This bridged the app to the bundled `scripta-mcp`
/// helper, which was spawned by an LLM client and shared no session with the app — so the app
/// published `{activeGroup, heartbeat}` and the helper refused rather than trust a stale scope.
/// That helper is deleted (Doc 4 Phase 3); the wall it enforced is not, because §7 moved the calls
/// into vaults the engine composes and any local process can reach those.
///
/// So the same file now vouches to the engine instead. A workspace vault's manifest declares
/// `guard_state` pointing here (`ScriptaVault.manifest()`), and `substrate/guard.py` withholds that
/// vault's own notes unless this heartbeat is fresh AND `activeScope` names the scope being asked
/// for. Same contract, one reader further out — and the engine learns nothing about Scripta: it
/// enforces a shape a vault asked it to enforce.
///
/// `activeScope` is the SLUG, published beside the display name, so the engine compares two strings
/// rather than acquiring this app's slug rule.
enum MCPStateFile {
    static var url: URL { SharedLocations.mcpState }

    static func write() {
        let state: [String: Any] = [
            "activeGroup": AppSettings.activeGroup,
            // THE SLUG, BESIDE THE DISPLAY NAME. A scope is named by `slug(workspace)` — "CBRE"
            // composes as `cbre` — and the engine's guard compares against the SCOPE it was asked
            // for. Publishing only the display name would have made the engine slugify, which is
            // this app's rule living in the engine; publishing both keeps the rule here and leaves
            // the guard comparing two strings.
            "activeScope": ScriptaVault.slug(AppSettings.activeGroup),
            "heartbeat": Date().timeIntervalSince1970,
            // Published here rather than read out of the app's preferences. That started as a
            // sandbox necessity and outlived it: the beat and the folder have to move together,
            // because a server that reads a fresh path beside a stale heartbeat is reading a
            // workspace the privacy wall no longer vouches for.
            "outputFolderPath": AppSettings.outputFolder.path,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static var timer: Timer?

    /// Writes now and every 20s while the app runs. On quit the beat goes stale within the
    /// engine's 60s window (`guard.STALE_AFTER_SECONDS`), at which point the guarded vault's own
    /// notes stop answering — while everything the scope inherits keeps working.
    @MainActor static func startHeartbeat() {
        write()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in write() }
    }
}
