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
        // Prune old transcripts if the user enabled auto-delete.
        RetentionPruner.pruneIfNeeded()
        NotificationManager.shared.configure()
        menuController = MenuController()

        // Recover any recordings a crash/forced-logout orphaned, then reconcile the retrieval
        // index (which picks up whatever recovery just wrote). Both are background work.
        Task.detached(priority: .utility) {
            await RecordingSession.recoverOrphans()
            if let store = IndexStore.shared {
                IndexBuilder.reconcile(store: store)
                await IndexBuilder.embedPending(store: store)   // best-effort; no-op without an embedder
            }
        }
        // Keep the index fresh against external edits to the (often vault-hosted) output folder.
        IndexWatcher.shared?.start(folder: AppSettings.outputFolder)
        // Publish the active-workspace scope + a heartbeat for the MCP server (which refuses when
        // the beat is stale, so the privacy wall binds LLM clients too).
        MCPStateFile.startHeartbeat()
    }

    /// Quit (menu item, logout, shutdown) must not kill the process mid-recording: the raw
    /// audio would be the only copy of the call, and the next launch's sweep deletes it.
    /// Stop and transcribe first, then let termination proceed.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard let menuController, menuController.isWorking else { return .terminateNow }
        menuController.finishBeforeTermination {
            sender.reply(toApplicationShouldTerminate: true)
        }
        return .terminateLater
    }
}
