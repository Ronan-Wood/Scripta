import AppKit
import ScriptaCore
import SwiftUI   // NSHostingController, for the Help window

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuController: MenuController?
    /// Held so ⌘? reopens the same window instead of stacking a new one each time.
    private var helpWindow: NSWindow?

    func applicationDidFinishLaunching(_ notification: Notification) {
        // FIRST, BEFORE ANY SETTING IS READ. The sandbox came off (Doc 3 §1), and a sandboxed app's
        // preferences live in its container while an unsandboxed one's live in ~/Library/Preferences
        // — so without this the first launch after the flip reads an empty defaults domain, writes
        // to ~/Documents/Scripta, and lets `IndexBuilder.reconcile` remove every indexed path that
        // is not in that empty folder. The index survives the flip (it is in the App Group
        // container, which is not a sandbox artefact); it is the SETTINGS that do not.
        let carried = ContainerPreferences.adopt()
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
        MainMenu.install(settingsTarget: self, settingsAction: #selector(openSettings),
                         helpAction: #selector(openHelp))
        menuController = MenuController()

        if case .blocked(let plist) = carried { presentSettingsUnreachableAlert(plist) }
        presentFirstRunIfNeeded()
        if !folderRestored { presentFolderLostAlert() }

        // Normal-app mode (the default): show the hub like any app shows its window.
        // Menu-bar-only mode (Settings) launches quietly into the status item instead.
        if AppSettings.showInDock {
            menuController?.showHub()
        }

        RecordingSession.sweepPendingCaptions()   // clear screenshots a crash may have orphaned
        // Recover any recordings a crash/forced-logout orphaned, then reconcile the retrieval
        // index (which picks up whatever recovery just wrote). Both are background work.
        Task.detached(priority: .utility) {
            await RecordingSession.recoverOrphans()
            if let store = IndexStore.shared {
                IndexBuilder.syncTerms(store: store)   // vocabulary cache before anything queries
                IndexBuilder.reconcile(store: store)
                await AppModel.shared.reconcileCalendarGroupCasing()   // needs reconcile's fresh group list
                await IndexBuilder.embedPending(store: store)   // best-effort; no-op without an embedder
                EntityMirror.sync(store: store)                 // opt-in; no-op unless enabled
            }
        }
        // Keep the index fresh against external edits to the (often vault-hosted) output folder.
        IndexWatcher.shared?.start(folder: AppSettings.outputFolder)
        // Publish the active-workspace scope + a heartbeat for the MCP server (which refuses when
        // the beat is stale, so the privacy wall binds LLM clients too).
        MCPStateFile.startHeartbeat()
        // Doc 3 §2: the app RUNS the engine. There is no launchd job for substrate — run Scripta to
        // have the engine, close Scripta and it stops. `applicationWillTerminate` is only the
        // ordinary half of that; see `SubstrateEngine` for the half that survives a force-quit.
        SubstrateEngine.shared.start()
        // Doc 3 §2: "Index refresh | in-app, on launch and on a timer while open". The first pass
        // waits for the engine to stop coming up before it runs — a compose competing with the
        // cross-encoder's model load is contention on the one event the operator is watching — and
        // the work itself is the deployed refresh agent, not a Swift reimplementation of it.
        SubstrateRefresh.shared.start()
    }

    /// One-time first-launch notice: the recording-consent reminder (kept after the App Store was
    /// dropped — saying it once is right regardless of who reviews the app; consent itself stays
    /// the user's responsibility) plus the transcripts-folder choice, which stays a deliberate
    /// first step rather than a Settings dig because the default is ~/Documents/Scripta and almost
    /// nobody wants their transcripts there.
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
            // The global record hotkey is live during this modal and reads the registry (ASR
            // bias via confirmedAliases), which would lazy-bind shared to the default folder —
            // so re-point explicitly. Idempotent when the lazy binding never happened.
            EntityRegistry.repoint(toFolder: url)
        }
    }

    /// The sandbox container is there and unreadable, so this launch is about to look like a fresh
    /// install to an operator who has years of settings. Said out loud because the alternative is a
    /// silent reset: the app would write to a new folder and reconcile the index against it.
    private func presentSettingsUnreachableAlert(_ plist: URL) {
        NSApp.activate(ignoringOtherApps: true)
        let alert = NSAlert()
        alert.messageText = "Your settings could not be carried over"
        alert.informativeText = """
        Scripta no longer runs in a sandbox, so its settings moved out of the app container. The \
        old ones are still at:

        \(plist.path)

        They could not be read, so this launch starts from defaults — including the transcripts \
        folder. Check Settings before recording, and quit now if you would rather investigate first.
        """
        alert.addButton(withTitle: "OK")
        alert.runModal()
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

    /// ⌘, from the main menu: the hub with Settings selected.
    @MainActor @objc private func openSettings() {
        AppModel.shared.route = .section(.settings)
        menuController?.showHub()
    }

    /// ⌘? from the Help menu: the docs, in their own window rather than as a hub section (Doc 4 §2).
    ///
    /// ITS OWN WINDOW, NOT A ROUTE, and the difference is the reason it left the sidebar: help is
    /// read BESIDE the thing it explains. A hub section replaced the surface the reader was stuck
    /// on with the page describing it, which is the one arrangement documentation must not have.
    @MainActor @objc private func openHelp() {
        if helpWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HelpView()))
            window.title = "Scripta Help"
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
            window.setContentSize(NSSize(width: 720, height: 640))
            window.isReleasedWhenClosed = false   // reopened from the menu; do not free it on close
            window.center()
            helpWindow = window
        }
        NSApp.activate(ignoringOtherApps: true)
        helpWindow?.makeKeyAndOrderFront(nil)
    }

    /// Clicking the Dock icon with no window open reopens the hub — normal-app behavior.
    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows: Bool) -> Bool {
        if !hasVisibleWindows { menuController?.showHub() }
        return true
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

    /// The engine dies with the app (Doc 3 §2). This is the ordinary exit and the only one that
    /// runs any of our code — force-quit and crash are covered inside `SubstrateEngine` by the
    /// child's own parent-death watch, because nothing here executes on either.
    func applicationWillTerminate(_ notification: Notification) {
        // Refresh first: its pass is a subprocess of ours, and stopping the loop before the engine
        // means the timer cannot start one into a teardown that is already under way.
        SubstrateRefresh.shared.stop()
        SubstrateEngine.shared.stop()
    }
}
