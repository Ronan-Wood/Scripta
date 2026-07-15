import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Register the bundled IBM Plex fonts before any UI is built.
        CarbonFont.register()
        AppModel.shared.applyAppearance()
        if AppSettings.showInDock {
            NSApp.setActivationPolicy(.regular)
        }
        // Remove any raw-audio temp directories left behind by a prior crash.
        RecordingSession.sweepOrphans()
        // Prune old transcripts if the user enabled auto-delete.
        RetentionPruner.pruneIfNeeded()
        NotificationManager.shared.configure()
        menuController = MenuController()

        // Reconcile the retrieval index with the transcript folder in the background.
        if let store = IndexStore.shared {
            Task.detached(priority: .utility) { IndexBuilder.reconcile(store: store) }
        }
    }
}
