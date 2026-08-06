import SwiftUI
import ScriptaCore
import Combine
import AppKit

/// Single source of truth the hub observes: recording state, the call list, and cross-view
/// navigation. Recording is still driven through `MenuController` (which owns the capture
/// pipeline and AppKit presentation); this model is the shared bridge so any surface — the hub's
/// Home button or the menu bar — reflects and triggers the same state.
/// The mic level ticks ~12×/s while recording; isolated so only the meter view re-renders.
@MainActor
final class MicMeterModel: ObservableObject {
    @Published var level: Float = 0
}

/// The live transcript updates on every volatile speech result; isolated so the rest of the
/// hub isn't invalidated per spoken word.
@MainActor
final class LiveTranscriptModel: ObservableObject {
    @Published var finalized: [String] = []
    @Published var partial = ""
}

@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum RecordingState { case idle, recording, processing }

    @Published var recordingState: RecordingState = .idle {
        didSet { syncRecordingClock() }
    }
    @Published var recordingElapsed: TimeInterval = 0
    @Published var isPaused = false
    @Published var calls: [TranscriptMeta] = []

    /// Non-nil while recording in a non-default mode (e.g. "Conference · System audio"), for the UI.
    @Published var recordingModeName: String?

    /// The active workspace (the privacy partition). Retrieval is hard-scoped to it. Persisted, and
    /// republished to the MCP heartbeat so LLM clients honor the same scope.
    @Published var activeGroup: String = AppSettings.activeGroup {
        didSet {
            guard oldValue != activeGroup else { return }
            AppSettings.activeGroup = activeGroup
            MCPStateFile.write()
            reloadCalls()
            // Doc 3 §7: the workspace binds the engine side too, and "switching workspaces is
            // instant — reading a different scope is a query parameter, recompose is only needed
            // when content changes, never when the reader changes." Both engine surfaces re-read
            // their binding here rather than sampling `activeGroup` at init, which is what left the
            // Library pointing at launch-time's workspace (bc950f1).
            SubstrateAskModel.shared.adoptBinding()
            SubstrateLibraryModel.shared.adoptWorkspace()
        }
    }

    /// Workspaces available in the switcher: configured calendar groups ∪ groups present in the
    /// corpus (plus the active one). "" (Ungrouped) is offered separately by the UI.
    func availableGroups() -> [String] {
        var set = Set(AppSettings.calendarGroups.values.filter { !$0.isEmpty })
        IndexStore.shared?.groups().forEach { set.insert($0.name) }
        if !activeGroup.isEmpty { set.insert(activeGroup) }
        return set.sorted()
    }

    /// Launch-time repair (crosscheck, Settings calendar Picker): a calendar assignment saved by
    /// the old free-text Settings field was force-lowercased on write, silently diverging from
    /// the real (properly-cased) workspace name everywhere else — every exact-match group scope
    /// (search, notes, the privacy-wipe deleter) then treats "property prism" and "Property
    /// Prism" as two unrelated workspaces. Folds a stored value back onto its real-cased
    /// counterpart when exactly one case-insensitive match exists; ambiguous (two workspaces
    /// that are already only-case-different) is left alone rather than guessed at. Idempotent,
    /// so it's safe to just run on every launch rather than gating it behind a one-time flag.
    func reconcileCalendarGroupCasing() {
        var canonical = Set((IndexStore.shared?.groups() ?? []).map(\.name))
        if !activeGroup.isEmpty { canonical.insert(activeGroup) }
        var groups = AppSettings.calendarGroups
        var changed = false
        for (id, value) in groups where !canonical.contains(value) {
            let matches = canonical.filter { $0.caseInsensitiveCompare(value) == .orderedSame }
            if matches.count == 1, let match = matches.first {
                groups[id] = match
                changed = true
            }
        }
        if changed { AppSettings.calendarGroups = groups }
    }

    // High-frequency recording surfaces, split out of this object (see M12): observing
    // AppModel must not mean re-rendering at mic-buffer rate.
    let meter = MicMeterModel()
    let live = LiveTranscriptModel()

    /// What the workspace's vault knows about what is being said (Doc 4 §8). Owned here because it
    /// follows the RECORDING lifecycle rather than a view's: the panel showing it is on a screen
    /// that can be navigated away from mid-call, and a recall that stopped because somebody opened
    /// Settings would be a feature that only works while watched.
    let recall = LiveRecall()

    /// App-lifetime Ask conversation: clicking a citation (or any tab switch) swaps the hub's
    /// content view, which must not wipe the messages or the in-flight LanguageModelSession.
    let ask = AskModel()

    /// Set by MenuController; pauses/resumes the in-progress recording.
    var togglePause: (() -> Void)?

    /// Set by MenuController; records a manual note against the live recording. No-op when idle.
    var addNote: ((String) -> Void)?

    /// Bumped each time a note is accepted, so recording surfaces can show a lightweight
    /// "N notes this call" confirmation without reaching into the session.
    @Published var noteCount = 0

    private var clock: Timer?
    private var startedAt: Date?
    private var pauseStart: Date?

    /// Reflects a pause/resume: freezes the elapsed clock and mic meter while paused, and shifts
    /// the start forward on resume so elapsed excludes the paused time.
    func applyPaused(_ paused: Bool) {
        if paused {
            pauseStart = Date()
            meter.level = 0
        } else if let start = pauseStart {
            startedAt = startedAt?.addingTimeInterval(Date().timeIntervalSince(start))
            pauseStart = nil
        }
        isPaused = paused
    }

    /// Formatted running time while recording (M:SS or H:MM:SS).
    var elapsedLabel: String {
        let t = Int(recordingElapsed)
        let h = t / 3600, m = (t % 3600) / 60, s = t % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, s) : String(format: "%d:%02d", m, s)
    }

    private func syncRecordingClock() {
        switch recordingState {
        case .recording:
            if startedAt == nil { startedAt = Date() }
            // Reads the live transcript through a closure rather than taking a copy: the words are
            // still arriving, and each tick must ask what has been said BY THEN.
            recall.start { [weak self] in
                guard let self else { return "" }
                return (self.live.finalized + [self.live.partial]).joined(separator: " ")
            }
            guard clock == nil else { return }
            // .common mode: the elapsed clock must keep ticking while the status menu is open.
            let timer = Timer(timeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isPaused, let start = self.startedAt else { return }
                    self.recordingElapsed = Date().timeIntervalSince(start)
                }
            }
            RunLoop.main.add(timer, forMode: .common)
            clock = timer
        case .processing:
            clock?.invalidate(); clock = nil
            meter.level = 0; isPaused = false; pauseStart = nil
        case .idle:
            clock?.invalidate(); clock = nil
            startedAt = nil; recordingElapsed = 0; meter.level = 0; isPaused = false; pauseStart = nil
            live.finalized = []; live.partial = ""
            recordingModeName = nil; noteCount = 0
            recall.stop()
        }
    }

    /// Cross-view navigation inbox: any surface posts a request here and the hub's `Navigator`
    /// resolves it into a `Destination`, then clears this back to nil.
    @Published var route: Route?

    /// Set by MenuController; toggles start/stop through the real capture pipeline.
    var toggleRecording: (() -> Void)?
    /// Set by MenuController; starts recording tied to a specific calendar event.
    var recordMeeting: ((UpcomingCall) -> Void)?

    private init() {}

    private var callsReloadGeneration = 0
    func reloadCalls() {
        // TranscriptStore.list() scans the output folder and head-reads every file. Run it off the
        // main actor so the many callers (recording-complete, delete, index change, view appear)
        // don't block the UI (audit M7); the @Published assignment lands back on the main actor.
        // A generation token makes it latest-wins, so an older overlapping scan can't overwrite a
        // newer one (e.g. a stale list flashing a just-deleted call back).
        callsReloadGeneration &+= 1
        let generation = callsReloadGeneration
        Task.detached(priority: .userInitiated) {
            let loaded = TranscriptStore.list()
            await MainActor.run {
                guard AppModel.shared.callsReloadGeneration == generation else { return }
                AppModel.shared.calls = loaded
            }
        }
    }

    // MARK: - Document import (lives here, not in a view, so it survives navigating away and
    // its progress is observable app-wide).

    struct ImportJob: Identifiable, Equatable {
        let id = UUID()
        let filename: String
        var state: State
        enum State: Equatable { case processing, done, failed(String) }
        var isFailed: Bool { if case .failed = state { return true }; return false }
    }

    /// In-flight and recently-finished imports. Done jobs self-remove; failed jobs stay until
    /// dismissed so the reason is visible.
    @Published var importJobs: [ImportJob] = []

    /// Copies a document in, extracts its text on-device, and indexes it as kind='doc'. Job state
    /// drives the Documents shelf rows; a notification fires on completion (mirrors recordings).
    func importDocument(_ url: URL, linkedCall: URL? = nil) async {
        let job = ImportJob(filename: url.lastPathComponent, state: .processing)
        importJobs.append(job)
        do {
            let imported = try await DocumentImporter.importFile(url, group: activeGroup, linkedCall: linkedCall)
            // Backgrounded (crosscheck): this ran synchronously on @MainActor when indexDoc was a
            // cheap frontmatter-parse-plus-upsert; M20 added a full NLTagger pass over the whole
            // extracted body, which would otherwise freeze the UI for the duration of every import.
            if let store = index {
                let mdURL = imported.mdURL
                Task.detached(priority: .utility) { IndexBuilder.indexDoc(mdURL, into: store) }
            }
            setJob(job.id, .done)
            NotificationManager.shared.notifyDocumentReady(
                title: imported.title,
                revealing: DocumentImporter.folder.appendingPathComponent(imported.fileName))
            // Let the "done" row linger briefly, then clear it.
            try? await Task.sleep(nanoseconds: 4_000_000_000)
            importJobs.removeAll { $0.id == job.id }
        } catch {
            setJob(job.id, .failed(error.localizedDescription))
        }
    }

    func dismissImportJob(_ id: UUID) {
        importJobs.removeAll { $0.id == id }
    }

    private func setJob(_ id: UUID, _ state: ImportJob.State) {
        if let i = importJobs.firstIndex(where: { $0.id == id }) { importJobs[i].state = state }
    }

    /// Applies the saved Light/Dark/System preference app-wide. The Carbon tokens already adapt,
    /// so overriding `NSApp.appearance` flips the whole UI (hub + menus + modals).
    func applyAppearance() {
        switch AppSettings.appearance {
        case .system: NSApp.appearance = nil
        case .light: NSApp.appearance = NSAppearance(named: .aqua)
        case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
        }
    }

    var index: IndexStore? { IndexStore.shared }
    var upcomingMeetings: [UpcomingCall] {
        AppSettings.calendarEnabled ? CalendarWatcher.shared.upcomingCalls() : []
    }
}
