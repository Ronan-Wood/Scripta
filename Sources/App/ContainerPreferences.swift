import Foundation
import OSLog

/// Carries the sandboxed app's preferences forward the one time the sandbox comes off.
///
/// THIS IS THE ONLY DATA-LOSS-SHAPED PART OF DROPPING THE SANDBOX, and it is silent without this
/// file. `cfprefsd` redirects a sandboxed app's preference domain into its container, so every
/// setting the operator has ever made lives in
///
///     ~/Library/Containers/<bundle id>/Data/Library/Preferences/<bundle id>.plist
///
/// and `UserDefaults.standard` in an unsandboxed build of the same app reads
/// `~/Library/Preferences/<bundle id>.plist`, which does not exist. Measured on this machine before
/// the flip: the container plist holds `outputFolderPath`, `activeGroup`, the calendar map and
/// `firstRunNoticeShown`; the home-directory plist is absent entirely.
///
/// WHAT THAT COSTS IF NOBODY CARRIES IT. `AppSettings.outputFolder` falls back to ~/Documents/Scripta
/// — an empty folder — while the retrieval index survives untouched in the App Group container,
/// because the group container is not a sandbox artefact. `IndexBuilder.reconcile` then removes
/// every indexed path that is not on disk (`IndexBuilder.reconcile`, the removal pass), so the
/// first unsandboxed launch would delete the operator's entire index against a folder that never
/// held their transcripts. The transcripts themselves survive; the index, the workspace and the
/// calendar wiring do not.
///
/// THIS IS STILL THE FIX FOR THAT, and `IndexBuilder.Listing` is not a replacement for it. That
/// guard refuses the removal pass when a folder cannot be LISTED, which now also covers an
/// `outputFolderPath` pointing at a directory that does not exist — but a fallback folder that
/// exists and is genuinely empty lists fine, and removals correctly proceed against it. Carrying
/// the settings is what stops the app looking at the wrong folder in the first place; the listing
/// guard stops it acting on a folder it could not read. Two different failures, both real.
///
/// THE BOOKMARK IS DELIBERATELY LEFT BEHIND, and that is not an oversight. A security-scoped
/// bookmark written under the sandbox does NOT resolve outside it — measured here, it comes back as
/// NSCocoaErrorDomain 259, "the file couldn't be opened because it isn't in the correct format".
/// Carrying it would make `AppSettings.restoreOutputFolderAccess()` fail, clear it and return false,
/// which fires the "transcripts folder unavailable" alert about a folder that is fine. Unsandboxed,
/// the stored PATH is the grant, and that is what this copies. `setOutputFolder` keeps writing
/// bookmarks and they keep resolving — one created outside the sandbox round-trips normally, also
/// measured — so only this one crossing is broken, and only once.
enum ContainerPreferences {

    private static let log = Logger(subsystem: "com.ronanwood.Scripta", category: "Migration")

    enum Outcome {
        /// Either there is nothing to carry, or it was carried on an earlier launch.
        case notNeeded
        case adopted(keys: Int, from: URL)
        /// The container is there and could not be read. Said out loud rather than treated as
        /// absence: absence and refusal look identical here and only one of them is harmless.
        case blocked(URL)
    }

    /// Keys that describe the sandbox rather than the operator. `NSOSPLastRootDirectory` and
    /// `NSNavPanelExpandedSizeForOpenMode` are AppKit's own open-panel state — the first is another
    /// scoped bookmark — and `com.apple.*` is framework bookkeeping.
    private static func carried(_ key: String) -> Bool {
        key != "outputFolderBookmark" && !key.hasPrefix("NS") && !key.hasPrefix("com.apple")
    }

    /// Runs before anything reads a setting. Guarded on `firstRunNoticeShown` rather than on a
    /// migration flag of its own: the app already writes that key the first time it is used, so it
    /// is exactly "this install has been through a first launch" and needs no second bookkeeping
    /// value that could disagree with it.
    @discardableResult
    static func adopt() -> Outcome {
        let defaults = UserDefaults.standard
        guard defaults.object(forKey: "firstRunNoticeShown") == nil else { return .notNeeded }
        guard let bundleID = Bundle.main.bundleIdentifier else { return .notNeeded }
        let plist = URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Containers/\(bundleID)/Data/Library/Preferences")
            .appendingPathComponent("\(bundleID).plist")
        guard FileManager.default.fileExists(atPath: plist.path) else { return .notNeeded }
        guard let stored = NSDictionary(contentsOf: plist) as? [String: Any] else {
            log.error("container preferences exist and could not be read")
            return .blocked(plist)
        }

        var moved = 0
        for (key, value) in stored where carried(key) && defaults.object(forKey: key) == nil {
            defaults.set(value, forKey: key)
            moved += 1
        }
        log.info("carried \(moved) preference keys out of the sandbox container")
        return moved == 0 ? .notNeeded : .adopted(keys: moved, from: plist)
    }
}
