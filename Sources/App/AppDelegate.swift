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
        alert.messageText = "Before your first recording"
        alert.informativeText = """
        Call Transcriber records your microphone and your calls' audio entirely on this Mac — \
        nothing is ever sent anywhere. Depending on where you live, recording a conversation may \
        require the other participants' consent; that part is your responsibility. The menu-bar \
        icon always shows when recording is active.

        Transcripts are Markdown files saved to a folder you choose — an Obsidian vault or any \
        synced folder works. You can change it any time in Settings.
        """
        alert.addButton(withTitle: "Choose Transcripts Folder…")
        alert.addButton(withTitle: "Use Default Folder")
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
        Your transcripts folder could not be opened — it may have been moved, deleted, or live \
        on a disconnected volume. New transcripts go to the default folder until you pick a \
        folder again in Settings.
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
