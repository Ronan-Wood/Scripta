import AppKit

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuController: MenuController?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // Re-activate the user's folder grant before anything touches the output folder
        // (pruner, orphan recovery, reconcile, watcher all ride this one grant).
        let folderRestored = AppSettings.restoreOutputFolderAccess()
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

        presentFirstRunIfNeeded()
        if !folderRestored { presentFolderLostAlert() }

        RecordingSession.sweepPendingCaptions()   // clear screenshots a crash may have orphaned
        // Recover any recordings a crash/forced-logout orphaned, then reconcile the retrieval
        // index (which picks up whatever recovery just wrote). Both are background work.
        Task.detached(priority: .utility) {
            await RecordingSession.recoverOrphans()
            if let store = IndexStore.shared {
                IndexBuilder.reconcile(store: store)
                await IndexBuilder.embedPending(store: store)   // best-effort; no-op without an embedder
                EntityMirror.sync(store: store)                 // opt-in; no-op unless enabled
            }
        }
        // Keep the index fresh against external edits to the (often vault-hosted) output folder.
        IndexWatcher.shared?.start(folder: AppSettings.outputFolder)
        // Publish the active-workspace scope + a heartbeat for the MCP server (which refuses when
        // the beat is stale, so the privacy wall binds LLM clients too).
        MCPStateFile.startHeartbeat()
    }

    /// One-time first-launch notice: the recording-consent reminder (App Review expects apps
    /// that record to say this once; consent itself stays the user's responsibility) plus the
    /// transcripts-folder choice — under the sandbox the default folder lives in the app's
    /// container, so pointing at a real folder is a deliberate first step, not a Settings dig.
    private func presentFirstRunIfNeeded() {
        guard !AppSettings.firstRunNoticeShown else { return }
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Welcome to Scripta"
        alert.informativeText = """
        Recordings are transcribed on your Mac and never leave it. The menu bar icon shows \
        when recording is active.

        Recording laws vary by location — some require consent from everyone on the call. \
        Obtaining consent is your responsibility.

        Where should your transcripts be saved?
        """
        alert.addButton(withTitle: "Choose Folder…")
        alert.addButton(withTitle: "Use Default")
        let response = alert.runModal()
        AppSettings.firstRunNoticeShown = true
        guard response == .alertFirstButtonReturn else { return }
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.message = "Where should your call transcripts live?"
        if panel.runModal() == .OK, let url = panel.url {
            AppSettings.setOutputFolder(url)
        }
    }

    /// The stored folder bookmark stopped resolving (folder deleted, volume gone). The app has
    /// already fallen back to the default folder; tell the user instead of failing quietly.
    private func presentFolderLostAlert() {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Transcripts folder unavailable"
        alert.informativeText = """
        Your transcripts folder couldn't be found — it may have been moved or deleted. New \
        transcripts will go to the default folder until you pick one again in Settings.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
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
