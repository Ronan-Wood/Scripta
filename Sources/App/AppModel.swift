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
///
/// BOTH SIDES, ATTRIBUTED. It used to be one `[String]` fed by ONE track — the mic in a two-party
/// call — so the live view showed only what YOU said while the other half of the conversation went
/// to the saved transcript and nowhere else. The saved file has had You/Them since `RecordingMode`
/// was written (`labelsSpeakers`); it was the live path that was half-deaf, and `LiveRecall` read
/// that same half, so the vault was being asked about your own sentences rather than the client's.
///
/// MERGED BY ARRIVAL, not by timestamp. Each transcriber republishes its own whole `finalized`
/// array, so a track's growth is the new lines; interleaving them as they land is the ordering a
/// conversation actually has. Two people talking over each other can interleave imperfectly — the
/// SAVED transcript is the record, and this is the live view.
@MainActor
final class LiveTranscriptModel: ObservableObject {
    enum Speaker: Equatable {
        case you
        case them
        /// A conference: one source, deliberately unlabeled — the mic and the system track would
        /// otherwise capture the same speech and double every line.
        case unlabeled

        var label: String? {
            switch self {
            case .you: return "You"
            case .them: return "Them"
            case .unlabeled: return nil
            }
        }
    }

    struct Line: Identifiable, Equatable {
        let id = UUID()
        let speaker: Speaker
        let text: String
    }

    @Published var lines: [Line] = []
    /// One in-progress line PER TRACK — both sides can be mid-utterance at once.
    @Published var partials: [Speaker: String] = [:]

    /// How many finalized lines each track has already contributed.
    private var counts: [Speaker: Int] = [:]

    /// Absorb one track's update. `finalized` is that track's WHOLE array when a line closed, and
    /// nil on a volatile tick — so only the tail beyond what this track already contributed is new.
    func absorb(finalized: [String]?, partial: String, from speaker: Speaker) {
        if let finalized {
            let seen = counts[speaker] ?? 0
            if finalized.count > seen {
                lines.append(contentsOf: finalized[seen...].map { Line(speaker: speaker, text: $0) })
                counts[speaker] = finalized.count
            }
        }
        partials[speaker] = partial
    }

    func reset() {
        lines = []
        partials = [:]
        counts = [:]
    }

    /// Everything said so far, both sides, as one string — what `LiveRecall` asks the vault about
    /// and what `RelatedCallsPanel` searches. Unlabeled on purpose: these are QUERIES, and "You:"
    /// prefixes would be query terms rather than speech.
    var transcriptText: String {
        (lines.map(\.text) + partials.values.filter { !$0.isEmpty })
            .joined(separator: " ")
    }
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
            AskModel.shared.adoptBinding()
            SubstrateLibraryModel.shared.adoptWorkspace()
            // The browser is the third engine surface bound to the workspace, and the one where a
            // missed re-read is worst: Ask showing the old scope's answer is a wrong answer, but a
            // LIST still showing the old workspace's notes is the privacy partition leaking.
            VaultBrowseModel.shared.adoptWorkspace()
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
        // The Calls section follows the recording lifecycle: a call in progress selects the
        // recording lens, and finishing one hands the reader back to the list. Doc 4 §2 retired
        // Home, which used to be where this screen lived.
        CallsLensModel.shared.follow(busy: recordingState != .idle)
        switch recordingState {
        case .recording:
            if startedAt == nil { startedAt = Date() }
            // Reads the live transcript through a closure rather than taking a copy: the words are
            // still arriving, and each tick must ask what has been said BY THEN.
            // BOTH SIDES NOW. This asked the vault about the mic track alone, which in a
            // two-party call is your own sentences — the half least worth looking up. What the
            // other party says is what a recall should be triggered by.
            recall.start { [weak self] in self?.live.transcriptText ?? "" }
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
            // STOPPED HERE, not only at `.idle`. Processing a finished call — transcribe, summarize,
            // caption — runs well past the 20s tick, so the loop fired again AFTER the operator
            // pressed stop and sent the call's closing words to the engine. Recording over is
            // recording over.
            recall.stop()
        case .idle:
            clock?.invalidate(); clock = nil
            startedAt = nil; recordingElapsed = 0; meter.level = 0; isPaused = false; pauseStart = nil
            live.reset()
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

    /// Bring a dropped document in through the ENGINE, and report it inline.
    ///
    /// ONE DOCUMENT PATH (Doc 4 Phase 4b, step 2). This used to run `DocumentImporter` — the app's
    /// own extractor, writing to `Files/`, producing a document only the local index could see. It
    /// now runs `SubstrateLibraryModel.performAdd`, the same three steps the Library rail runs, so
    /// a document dropped on a call lands in the workspace vault where Ask, live recall and the
    /// Vault tab can reach it.
    ///
    /// THE INLINE ROWS STAY (operator's decision, 2026-08-10). Delegating to the rail's
    /// `addDocument()` would have been less code and would have moved this progress to another
    /// screen — a drop reports where the drop happened. So the pipeline is shared and the rendering
    /// is not: this maps the same outcome onto one row that is processing, done, or failed.
    ///
    /// `linkedCall` is not carried through, and that is a real loss rather than an oversight. The
    /// app's importer wrote a `linked_call:` key into its own frontmatter; the engine's ingest has
    /// no such concept, and inventing one would mean a second spine axis nothing reads. The link
    /// belongs in the note's own text or in identity, and until it exists a dropped document is
    /// simply a document in the workspace.
    func importDocument(_ url: URL, linkedCall: URL? = nil) async {
        let job = ImportJob(filename: url.lastPathComponent, state: .processing)
        importJobs.append(job)

        guard let cli = SubstrateEngine.shared.serving?.cli else {
            return setJob(job.id, .failed(
                "The substrate engine is not running, and documents are added through it now. "
                + "Open Library to see what it is doing."))
        }
        // Refused before extraction for the reason the rail states: a document lands in the
        // workspace's vault, and a workspace that slugifies to nothing cannot name one.
        guard (try? ScriptaVault.vault(forScope: activeGroup,
                                       under: AppSettings.outputFolder)) != nil else {
            return setJob(job.id, .failed(
                "This workspace has no usable name, so there is no vault to add the document to. "
                + "Name the workspace first — nothing was extracted."))
        }
        let asked = await SubstrateCLI.ingestSurface(cli)

        let outcome = await SubstrateLibraryModel.performAdd(
            cli: cli, file: url, surface: asked, forceMarkdown: false, docClass: nil,
            domains: "", workspace: activeGroup) { _ in }

        guard outcome.succeeded else {
            return setJob(job.id, .failed(outcome.failure ?? "The document was not added."))
        }
        setJob(job.id, .done)
        NotificationManager.shared.notifyDocumentReady(
            title: url.deletingPathExtension().lastPathComponent,
            revealing: outcome.promoted ?? url)
        // Let the "done" row linger briefly, then clear it.
        try? await Task.sleep(nanoseconds: 4_000_000_000)
        importJobs.removeAll { $0.id == job.id }
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
