import Foundation

/// The app-facing entry point: prunes using the user's live retention settings. Kept separate from
/// `RetentionPruner.swift` so the pure pruning logic links into the host-less test bundle without
/// dragging in `AppSettings` (which pulls the Vision + engine graphs). The app-target `Sources`
/// glob picks this file up automatically; the test target lists only the pure file.
extension RetentionPruner {
    static func pruneIfNeeded() {
        pruneIfNeeded(Config(enabled: AppSettings.retentionEnabled,
                             days: AppSettings.retentionDays,
                             folder: AppSettings.outputFolder))
    }
}
