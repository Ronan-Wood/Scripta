import SwiftUI
import Combine
import AppKit

/// Single source of truth the hub observes: recording state, the call list, and cross-view
/// navigation. Recording is still driven through `MenuController` (which owns the capture
/// pipeline and AppKit presentation); this model is the shared bridge so any surface — the hub's
/// Home button or the menu bar — reflects and triggers the same state.
@MainActor
final class AppModel: ObservableObject {
    static let shared = AppModel()

    enum RecordingState { case idle, recording, processing }

    @Published var recordingState: RecordingState = .idle {
        didSet { syncRecordingClock() }
    }
    @Published var recordingElapsed: TimeInterval = 0
    @Published var micLevel: Float = 0
    @Published var isPaused = false
    @Published var liveFinalized: [String] = []
    @Published var livePartial: String = ""
    @Published var calls: [TranscriptMeta] = []

    /// Set by MenuController; pauses/resumes the in-progress recording.
    var togglePause: (() -> Void)?

    private var clock: Timer?
    private var startedAt: Date?
    private var pauseStart: Date?

    /// Reflects a pause/resume: freezes the elapsed clock and mic meter while paused, and shifts
    /// the start forward on resume so elapsed excludes the paused time.
    func applyPaused(_ paused: Bool) {
        if paused {
            pauseStart = Date()
            micLevel = 0
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
            guard clock == nil else { return }
            clock = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
                Task { @MainActor in
                    guard let self, !self.isPaused, let start = self.startedAt else { return }
                    self.recordingElapsed = Date().timeIntervalSince(start)
                }
            }
        case .processing:
            clock?.invalidate(); clock = nil
            micLevel = 0; isPaused = false; pauseStart = nil
        case .idle:
            clock?.invalidate(); clock = nil
            startedAt = nil; recordingElapsed = 0; micLevel = 0; isPaused = false; pauseStart = nil
            liveFinalized = []; livePartial = ""
        }
    }

    /// Cross-view navigation the hub reads: jump to Calls with a preselected call or filter.
    @Published var route: Route?

    enum Route: Equatable {
        case call(URL)
        case tag(String)
        case section(HubSection)
    }

    /// Set by MenuController; toggles start/stop through the real capture pipeline.
    var toggleRecording: (() -> Void)?
    /// Set by MenuController; starts recording tied to a specific calendar event.
    var recordMeeting: ((UpcomingCall) -> Void)?

    private init() {}

    func reloadCalls() {
        calls = TranscriptStore.list()
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
