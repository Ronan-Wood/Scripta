import AppKit
import SwiftUI
import Combine

@MainActor
final class MenuController: NSObject, NSMenuDelegate, NSWindowDelegate {
    private enum UIState {
        case idle, recording, processing
        var appState: AppModel.RecordingState {
            switch self {
            case .idle: return .idle
            case .recording: return .recording
            case .processing: return .processing
            }
        }
    }

    private let statusItem: NSStatusItem
    private var hubWindow: NSWindow?
    private var quickNotePanel: NSPanel?

    private var session: RecordingSession?
    private var recordingStartedAt: Date?
    private var tiedMeeting: UpcomingCall?
    private var uiState: UIState = .idle {
        didSet { AppModel.shared.recordingState = uiState.appState }
    }
    private var isStarting = false
    private var isTerminating = false
    private var pauseTask: Task<Void, Never>?
    private var proximityTimer: Timer?
    private var cancellables = Set<AnyCancellable>()

    private static let timeFormatter: DateFormatter = {
        let formatter = DateFormatter()
        formatter.dateFormat = "h:mm a"
        return formatter
    }()

    override init() {
        // Variable length so the running-time title can appear next to the icon while recording.
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        super.init()

        statusItem.button?.imagePosition = .imageLeading
        statusItem.button?.font = .monospacedDigitSystemFont(ofSize: 12, weight: .medium)

        let menu = NSMenu()
        menu.delegate = self
        statusItem.menu = menu
        updateIcon()

        // Let the hub drive the same recording pipeline and see the same call list.
        AppModel.shared.toggleRecording = { [weak self] in self?.toggleRecording() }
        AppModel.shared.recordMeeting = { [weak self] meeting in
            // Ignore while a recording is live (e.g. a calendar-grid click mid-recording) —
            // starting a second session would orphan the first one's audio.
            guard let self, self.uiState == .idle, !self.isStarting else { return }
            self.startRecording(tiedTo: meeting)
        }
        AppModel.shared.togglePause = { [weak self] in self?.togglePause() }
        AppModel.shared.addNote = { [weak self] text in self?.jotNote(text) }
        AppModel.shared.reloadCalls()

        // Global ⌥⌘R start/stop, ⌥⌘N quick note.
        HotKeyManager.shared.onTrigger = { [weak self] in self?.toggleRecording() }
        HotKeyManager.shared.onNote = { [weak self] in self?.showQuickNote() }
        HotKeyManager.shared.setEnabled(AppSettings.globalHotkeyEnabled)

        // Show the running time next to the menu-bar icon while recording. DispatchQueue, not
        // RunLoop: RunLoop.main delivery pauses in the default mode while the menu is held open,
        // freezing the timer text.
        AppModel.shared.$recordingElapsed
            .combineLatest(AppModel.shared.$recordingState)
            .receive(on: DispatchQueue.main)
            .sink { [weak self] _, state in
                self?.statusItem.button?.title = state == .recording ? " \(AppModel.shared.elapsedLabel)" : ""
            }
            .store(in: &cancellables)

        // Refresh the upcoming-call proximity badge periodically (.common so it ticks while
        // the status menu is open).
        let proximity = Timer(timeInterval: 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.updateIcon() }
        }
        RunLoop.main.add(proximity, forMode: .common)
        proximityTimer = proximity
    }

    // MARK: - Icon state

    private func updateIcon() {
        guard let button = statusItem.button else { return }
        switch uiState {
        case .recording where AppModel.shared.isPaused:
            button.image = coloredSymbol("pause.circle.fill", color: .systemYellow, description: "Recording paused")
        case .recording:
            button.image = coloredSymbol("record.circle.fill", color: .systemRed, description: "Recording")
        case .processing:
            button.image = coloredSymbol("ellipsis.circle.fill", color: .systemOrange, description: "Processing transcript")
        case .idle:
            if let proximity = nextCallProximity() {
                // Tint the base to the menu bar color, then badge it with the proximity dot.
                let tint: NSColor = menuBarIsDark(button) ? .white : .black
                button.image = badged(ScriptaMark.statusIcon(tint: tint), dotColor: proximity.color)
            } else {
                button.image = ScriptaMark.statusIcon()   // template = adapts to menu bar light/dark
            }
        }
    }

    /// How imminent the next upcoming call is, if within the 30-minute warning window.
    private enum CallProximity {
        case soon       // ≤30 min — white
        case near       // ≤15 min — yellow
        case imminent   // ≤5 min  — green
        var color: NSColor {
            switch self {
            case .soon: return .white
            case .near: return .systemYellow
            case .imminent: return .systemGreen
            }
        }
    }

    private func nextCallProximity() -> CallProximity? {
        guard AppSettings.calendarEnabled, CalendarWatcher.shared.isAuthorized,
              let next = CalendarWatcher.shared.upcomingCalls(within: 1).first else { return nil }
        let minutes = next.start.timeIntervalSinceNow / 60
        guard minutes >= 0 else { return nil }
        if minutes <= 5 { return .imminent }
        if minutes <= 15 { return .near }
        if minutes <= 30 { return .soon }
        return nil
    }

    private func menuBarIsDark(_ button: NSStatusBarButton) -> Bool {
        button.effectiveAppearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
    }

    /// Draws a colored dot in the bottom-right corner of the icon.
    private func badged(_ base: NSImage?, dotColor: NSColor) -> NSImage? {
        guard let base else { return nil }
        let size = base.size
        let result = NSImage(size: size)
        result.lockFocus()
        base.draw(in: NSRect(origin: .zero, size: size))
        let diameter = size.height * 0.42
        let rect = NSRect(x: size.width - diameter, y: 0, width: diameter, height: diameter)
        dotColor.setFill()
        NSBezierPath(ovalIn: rect).fill()
        result.unlockFocus()
        result.isTemplate = false
        return result
    }

    /// A colored (non-template) status-bar symbol. Palette-colored symbols must be
    /// non-template, or the system flattens them to monochrome.
    private func coloredSymbol(_ name: String, color: NSColor, description: String) -> NSImage? {
        let config = NSImage.SymbolConfiguration(paletteColors: [color])
        let image = NSImage(systemSymbolName: name, accessibilityDescription: description)?
            .withSymbolConfiguration(config)
        image?.isTemplate = false
        return image
    }

    // MARK: - Menu

    func menuNeedsUpdate(_ menu: NSMenu) {
        menu.removeAllItems()

        // Upcoming calls — informational only, never auto-starts recording.
        if AppSettings.calendarEnabled, CalendarWatcher.shared.isAuthorized {
            let calls = CalendarWatcher.shared.upcomingCalls()
            if !calls.isEmpty {
                for call in calls.prefix(2) {
                    let time = Self.timeFormatter.string(from: call.start)
                    let item = NSMenuItem(title: "Upcoming: \(call.title) · \(time) (\(call.service))",
                                          action: nil, keyEquivalent: "")
                    item.isEnabled = false
                    menu.addItem(item)
                }
                menu.addItem(.separator())
            }
        }

        let toggleTitle: String
        switch uiState {
        case .processing: toggleTitle = "Processing…"
        case .recording: toggleTitle = "Stop Recording"
        case .idle: toggleTitle = "Start Recording"
        }
        let toggle = NSMenuItem(title: toggleTitle, action: #selector(toggleRecording), keyEquivalent: "")
        toggle.target = self
        if uiState == .processing { toggle.action = nil }   // disabled while working
        menu.addItem(toggle)

        if uiState == .recording {
            let pause = NSMenuItem(title: AppModel.shared.isPaused ? "Resume Recording" : "Pause Recording",
                                   action: #selector(pauseRecording), keyEquivalent: "")
            pause.target = self
            menu.addItem(pause)
        }

        menu.addItem(.separator())

        let hub = NSMenuItem(title: "Open Hub", action: #selector(openHub), keyEquivalent: "o")
        hub.target = self
        menu.addItem(hub)

        menu.addItem(.separator())

        let quit = NSMenuItem(title: "Quit Scripta",
                              action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    // MARK: - Termination

    /// True while a recording is live or a transcript is still being produced — terminating
    /// during either would lose the call (the next launch sweeps the raw audio).
    var isWorking: Bool { uiState != .idle }

    /// Stops any in-progress recording, waits for the transcript pipeline to finish, then calls
    /// `completion`. Interactive follow-ups (details prompt, Finder reveal) are skipped — the
    /// app is on its way out; only the transcript itself matters.
    func finishBeforeTermination(completion: @escaping () -> Void) {
        isTerminating = true
        if uiState == .recording {
            guard session != nil else { uiState = .idle; completion(); return }
            stopRecording()
        }
        guard uiState != .idle else { completion(); return }
        AppModel.shared.$recordingState
            .receive(on: RunLoop.main)
            .filter { $0 == .idle }
            .first()
            .sink { _ in completion() }
            .store(in: &cancellables)
    }

    // MARK: - Actions

    @objc private func toggleRecording() {
        switch uiState {
        case .idle: startRecording()
        case .recording: stopRecording()
        case .processing: break
        }
    }

    /// `meeting` ties the recording to a calendar event; it is stored only once the session
    /// actually starts, so an aborted attempt can never mislabel the next recording.
    private func startRecording(tiedTo meeting: UpcomingCall? = nil) {
        guard uiState == .idle, !isStarting else { return }
        isStarting = true
        Task {
            defer { isStarting = false }

            guard await Permissions.requestMicrophone() else {
                presentAlert(
                    title: "Microphone Access Needed",
                    message: "Enable Scripta under System Settings › Privacy & Security › Microphone, then try again."
                )
                return
            }

            // Decide the recording mode (Call vs Conference) and what screen context reads from —
            // optionally asking each time via one pre-record prompt.
            let mode: RecordingMode
            let screenSource: ScreenSource
            if AppSettings.askScreenSourceOnRecord {
                let windows = AppSettings.screenContextEnabled
                    ? await ScreenContextCapturer.availableWindows()
                        .map { ScreenSourcePrompt.WindowOption(id: $0.id, label: $0.label) }
                    : []
                switch askRecordingOptions(windows: windows) {
                case .cancel: return
                case .start(let m, let s): mode = m; screenSource = s
                }
            } else {
                mode = AppSettings.defaultRecordingMode
                screenSource = AppSettings.screenContextEnabled ? .frontmostWindow : .off
            }
            AppSettings.defaultRecordingMode = mode   // remember the last choice as next time's default

            let newSession = RecordingSession()
            newSession.onSystemAudioFailure = { [weak self] error in
                self?.handleSystemAudioFailure(error, in: newSession)
            }
            do {
                // Capture the group at record time (calendar's group if tied, else the active
                // workspace) — a stable string, per the partition's record-time-capture rule.
                let group = AppSettings.recordingGroup(forCalendarID: meeting?.calendarID)
                // Bias ASR toward names known for this workspace (the contextualStrings loop —
                // free, source-level fix for mangled names). Confirmed-only, so unreviewed junk
                // never steers future transcription.
                let vocab = EntityRegistry.shared.confirmedAliases(group: group)
                try await newSession.start(mode: mode, screenSource: screenSource, group: group, extraVocab: vocab)
                session = newSession
                tiedMeeting = meeting
                recordingStartedAt = Date()
                AppModel.shared.recordingModeName = mode == .call ? nil : mode.displayName
                uiState = .recording
                updateIcon()
            } catch {
                newSession.cleanup()
                presentAlert(
                    title: "Couldn't Start Recording",
                    message: "\(error.localizedDescription)\n\nIf this is about screen recording, enable Scripta under System Settings › Privacy & Security › Screen Recording, then try again."
                )
            }
        }
    }

    /// A mid-call SCStream death (display reconfigure, sleep, permission revoked) would otherwise
    /// leave the session showing "recording" while the system track silently captures nothing —
    /// stop now so everything captured so far still becomes a transcript.
    private func handleSystemAudioFailure(_ error: Error, in failed: RecordingSession) {
        guard session === failed, uiState == .recording else { return }
        stopRecording()
        presentAlert(
            title: "System Audio Stopped",
            message: "System-audio capture failed mid-recording: \(error.localizedDescription)\n\nThe recording was stopped; everything captured so far is being transcribed."
        )
    }

    // MARK: - Notes

    /// Records a manual note against the live recording and bumps the shared count on success.
    private func jotNote(_ text: String) {
        guard let session, uiState == .recording else { return }
        if session.addNote(text) { AppModel.shared.noteCount += 1 }
    }

    /// Shows the floating quick-note input (⌥⌘N). Only meaningful while recording — a note has
    /// nowhere to go otherwise, so it's a silent no-op when idle. Reuses the panel if already open.
    private func showQuickNote() {
        guard uiState == .recording else { return }
        if let panel = quickNotePanel {
            NSApp.activate(ignoringOtherApps: true)
            panel.makeKeyAndOrderFront(nil)
            return
        }
        let view = QuickNoteView(
            onSubmit: { [weak self] text in self?.jotNote(text) },
            onClose: { [weak self] in self?.closeQuickNote() }
        )
        let panel = NSPanel(contentViewController: NSHostingController(rootView: view))
        panel.styleMask = [.titled, .closable, .hudWindow]
        panel.title = "Add Note"
        panel.isFloatingPanel = true
        panel.level = .floating
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        panel.delegate = self
        panel.setContentSize(NSSize(width: 380, height: 150))
        if let screen = NSScreen.main {
            let frame = panel.frame
            panel.setFrameOrigin(NSPoint(x: screen.frame.midX - frame.width / 2,
                                         y: screen.frame.maxY - frame.height - 140))
        }
        quickNotePanel = panel
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private func closeQuickNote() { quickNotePanel?.close() }

    @objc private func pauseRecording() { togglePause() }

    private func togglePause() {
        guard let current = session, uiState == .recording else { return }
        let nowPaused = !AppModel.shared.isPaused
        // Chained, not fire-and-forget: a rapid pause→resume must apply in order, or the
        // capture flags can land reversed and both tracks silently stop writing.
        let previous = pauseTask
        pauseTask = Task {
            await previous?.value
            nowPaused ? await current.pause() : await current.resume()
        }
        AppModel.shared.applyPaused(nowPaused)
        updateIcon()
    }

    private func stopRecording() {
        guard let current = session else { return }
        closeQuickNote()   // notes have nowhere to land once we leave the recording state
        // The recording window closes now (stop() then spends time transcribing).
        let window = recordingStartedAt.map { ($0, Date()) }
        recordingStartedAt = nil
        // Cleared here, not in the success path — a failed stop must not leak the tie into
        // the next unrelated recording.
        let tied = tiedMeeting
        tiedMeeting = nil
        // Reflect processing immediately — the heavy work happens inside stop().
        uiState = .processing
        updateIcon()
        Task {
            do {
                let transcriptURL = try await current.stop()

                // Post-call screen captioning (app layer, uses the vision model) — patches the
                // transcript's Screen Context, then deletes the ephemeral screenshots.
                if let captionDir = current.pendingCaptionDir {
                    Task.detached(priority: .utility) {
                        await ScreenCaptionPatcher.run(transcriptURL: transcriptURL, imageDir: captionDir)
                    }
                }

                // The group is now captured into frontmatter at record time (see start()), so no
                // stop-time group tagging is needed.

                // Optional post-record prompt to name the call + participants (modal, skippable).
                if AppSettings.promptForDetails && !isTerminating {
                    presentDetailsEditor(for: transcriptURL, window: window, tiedTitle: tied?.title)
                }
                // Add the finished transcript (with whatever metadata it now has) to the index.
                if let store = IndexStore.shared {
                    let url = transcriptURL
                    Task.detached(priority: .utility) { IndexBuilder.index(url, into: store) }
                }
                AppModel.shared.reloadCalls()
                // Hands-off finish: the notification's Reveal action (and the reader's Reveal
                // button) are the ways into Finder — no window steals focus after a call.
                NotificationManager.shared.notifyTranscriptReady(url: transcriptURL)
            } catch {
                // Raw audio is intentionally left for the launch-time sweep, not deleted here.
                presentAlert(title: "Transcription Failed", message: error.localizedDescription)
            }
            session = nil
            uiState = .idle
            updateIcon()
        }
    }

    /// Launch-time entry (normal-app mode shows the hub like any app shows its window).
    func showHub() { openHub() }

    @objc private func openHub() {
        if hubWindow == nil {
            let window = NSWindow(contentViewController: NSHostingController(rootView: HubView()))
            window.title = "Scripta"
            // The title bar is drawn inside HubView (per the render) — the system chrome is
            // transparent and full-size so only the traffic lights remain, over our bar.
            window.styleMask = [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView]
            window.titlebarAppearsTransparent = true
            window.titleVisibility = .hidden
            window.setContentSize(NSSize(width: 1100, height: 720))
            window.isReleasedWhenClosed = false
            window.delegate = self
            window.center()
            hubWindow = window
        }
        // Behave like a proper windowed app while the hub is open (Dock + ⌘-Tab).
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        hubWindow?.makeKeyAndOrderFront(nil)
        if let hubWindow { centerTrafficLights(hubWindow) }
    }

    /// The render puts close/minimize/zoom on the SAME line as the title and pills — vertically
    /// centered in the 40pt in-window bar. The system lays them out for a 28pt titlebar, so nudge
    /// them down; reapplied after resizes/fullscreen because AppKit re-lays them out.
    private func centerTrafficLights(_ window: NSWindow) {
        let barHeight: CGFloat = 40
        for (i, type) in [NSWindow.ButtonType.closeButton, .miniaturizeButton, .zoomButton].enumerated() {
            guard let button = window.standardWindowButton(type),
                  let container = button.superview else { continue }
            let y = container.frame.height - (barHeight - button.frame.height) / 2 - button.frame.height
            button.setFrameOrigin(NSPoint(x: 13 + CGFloat(i) * 20, y: y))   // absolute = idempotent
        }
    }

    func windowDidResize(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === hubWindow else { return }
        centerTrafficLights(window)
    }

    func windowDidBecomeKey(_ notification: Notification) {
        guard let window = notification.object as? NSWindow, window === hubWindow else { return }
        centerTrafficLights(window)
    }

    func windowWillClose(_ notification: Notification) {
        let closing = notification.object as? NSWindow
        if closing === quickNotePanel {
            // Break the panel → hosting → view → closure → controller retain cycle.
            quickNotePanel?.contentViewController = nil
            quickNotePanel = nil
            return
        }
        guard closing === hubWindow else { return }
        // Revert to menu-bar-only unless the user opted into a permanent Dock icon.
        if !AppSettings.showInDock {
            NSApp.setActivationPolicy(.accessory)
        }
    }

    /// Modal pre-record prompt for the recording mode (Call/Conference) and screen source, shown
    /// as recording starts. Returns the choice or `.cancel`. No close button — Cancel/Start are
    /// the only exits, so the modal session can't be stranded.
    private func askRecordingOptions(windows: [ScreenSourcePrompt.WindowOption]) -> RecordingChoice {
        var result: RecordingChoice = .cancel
        var window: NSWindow!
        let view = ScreenSourcePrompt(windows: windows,
                                      screenEnabled: AppSettings.screenContextEnabled,
                                      initialMode: AppSettings.defaultRecordingMode) { choice in
            result = choice
            NSApp.stopModal()
            window.close()
        }
        window = NSWindow(contentViewController: NSHostingController(rootView: view))
        window.title = "Recording Options"
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: window)
        // Break the window → hosting → view → onDone-closure → window cycle, or every
        // recording leaks the window + hosting pair.
        window.contentViewController = nil
        return result
    }

    /// Appends a tag to a transcript's frontmatter (idempotent), then reindexes.
    private func appendTag(_ tag: String, to url: URL) {
        guard let meta = TranscriptStore.meta(of: url),
              !meta.tags.contains(where: { $0.caseInsensitiveCompare(tag) == .orderedSame }) else { return }
        try? TranscriptMetadataEditor.update(url: url, title: meta.title,
                                             participants: meta.participants, tags: meta.tags + [tag])
    }

    private func presentDetailsEditor(for url: URL, window recordingWindow: (start: Date, end: Date)?, tiedTitle: String?) {
        let meta = TranscriptStore.meta(of: url)
        // Pre-fill people (and, absent an AI title, the call name) from the overlapping calendar event.
        let calendar = recordingWindow.flatMap { CalendarWatcher.shared.callContext(from: $0.start, to: $0.end) }
        let initialTitle = (meta?.title).flatMap { $0.isEmpty ? nil : $0 } ?? calendar?.title ?? tiedTitle ?? ""
        let initialParticipants = (meta?.participants).flatMap { $0.isEmpty ? nil : $0 } ?? calendar?.participants ?? []

        var window: NSWindow!
        let editor = TranscriptDetailsEditor(
            url: url,
            title: initialTitle,
            participants: initialParticipants,
            tags: meta?.tags ?? []
        ) { _ in
            NSApp.stopModal()
            window.close()
        }
        window = NSWindow(contentViewController: NSHostingController(rootView: editor))
        window.title = "Call Details"
        window.styleMask = [.titled]
        window.isReleasedWhenClosed = false
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        NSApp.runModal(for: window)
        window.contentViewController = nil   // same cycle as askRecordingOptions
    }

    private func presentAlert(title: String, message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.alertStyle = .warning
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
