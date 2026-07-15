import Foundation

/// Central app configuration, backed by UserDefaults. Milestone 5 adds the Settings UI
/// on top of these; for now they expose sensible defaults so the pipeline can run.
enum AppSettings {
    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let outputFolder = "outputFolderPath"
        static let domainVocab = "domainVocabulary"
        static let language = "transcriptionLanguage"
        static let retentionEnabled = "retentionEnabled"
        static let retentionCount = "retentionCount"
        static let retentionUnit = "retentionUnit"
        static let screenContextEnabled = "screenContextEnabled"
        static let screenCaptureInterval = "screenCaptureInterval"
        static let screenFocus = "screenFocus"
        static let askScreenSourceOnRecord = "askScreenSourceOnRecord"
        static let defaultRecordingMode = "defaultRecordingMode"
        static let calendarEnabled = "calendarEnabled"
        static let watchedCalendarIDs = "watchedCalendarIDs"
        static let calendarGroups = "calendarGroups"
        static let summarizeEnabled = "summarizeEnabled"
        static let promptForDetails = "promptForDetails"
        static let showInDock = "showInDock"
        static let appearance = "appearance"
        static let sidebarExpanded = "sidebarExpanded"
        static let globalHotkey = "globalHotkey"
        static let liveTranscription = "liveTranscription"
    }

    /// Show a live transcript (and related-calls) while recording. On by default.
    static var liveTranscriptionEnabled: Bool {
        get { defaults.object(forKey: Keys.liveTranscription) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.liveTranscription) }
    }

    /// Global ⌥⌘R hotkey to start/stop recording from anywhere. On by default.
    static var globalHotkeyEnabled: Bool {
        get { defaults.object(forKey: Keys.globalHotkey) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.globalHotkey) }
    }

    /// Whether the hub sidebar shows labels (true) or collapses to an icon-only rail (false).
    static var sidebarExpanded: Bool {
        get { defaults.object(forKey: Keys.sidebarExpanded) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.sidebarExpanded) }
    }

    /// Light / Dark / follow the system.
    static var appearance: AppAppearance {
        get { AppAppearance(rawValue: defaults.string(forKey: Keys.appearance) ?? "") ?? .system }
        set { defaults.set(newValue.rawValue, forKey: Keys.appearance) }
    }

    /// Folder transcripts are written to. Defaults to ~/Documents/CallTranscriber.
    /// Milestone 5 lets the user point this at an Obsidian vault / synced folder.
    static var outputFolder: URL {
        get {
            if let path = defaults.string(forKey: Keys.outputFolder), !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return documents.appendingPathComponent("CallTranscriber", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: Keys.outputFolder) }
    }

    /// Domain vocabulary (CRE terms, submarkets, deal jargon) fed to whisper's
    /// initial prompt to bias transcription. Empty by default.
    static var domainVocabulary: [String] {
        get { defaults.stringArray(forKey: Keys.domainVocab) ?? [] }
        set { defaults.set(newValue, forKey: Keys.domainVocab) }
    }

    /// Transcription language code (e.g. "en"), or "auto" to detect. Defaults to English.
    static var language: String {
        get { defaults.string(forKey: Keys.language) ?? "en" }
        set { defaults.set(newValue, forKey: Keys.language) }
    }


    /// When true, transcripts older than `retentionDays` are pruned. Off by default
    /// (keep forever). Raw audio/screenshots are always ephemeral regardless of this.
    static var retentionEnabled: Bool {
        get { defaults.bool(forKey: Keys.retentionEnabled) }
        set { defaults.set(newValue, forKey: Keys.retentionEnabled) }
    }

    /// The count portion of the retention window (the "30" in "30 days"). Defaults to 30.
    static var retentionCount: Int {
        get { let value = defaults.integer(forKey: Keys.retentionCount); return value > 0 ? value : 30 }
        set { defaults.set(max(1, newValue), forKey: Keys.retentionCount) }
    }

    /// The unit portion of the retention window (days/weeks/months). Defaults to days.
    static var retentionUnit: RetentionUnit {
        get { RetentionUnit(rawValue: defaults.string(forKey: Keys.retentionUnit) ?? "") ?? .days }
        set { defaults.set(newValue.rawValue, forKey: Keys.retentionUnit) }
    }

    /// Retention window expressed in days, used by the pruner.
    static var retentionDays: Int { retentionCount * retentionUnit.dayMultiplier }

    /// Whether to capture periodic screen context (frontmost window OCR) during recording.
    /// On by default. Turning it off records audio only.
    static var screenContextEnabled: Bool {
        get { defaults.object(forKey: Keys.screenContextEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.screenContextEnabled) }
    }

    /// Seconds between screen-context captures. Clamped to 5–10s. Defaults to 7.
    static var screenCaptureInterval: Int {
        get { let value = defaults.integer(forKey: Keys.screenCaptureInterval); return value > 0 ? min(10, max(5, value)) : 7 }
        set { defaults.set(min(10, max(5, newValue)), forKey: Keys.screenCaptureInterval) }
    }

    /// How aggressively to filter captured screen text. Defaults to trimming chrome.
    static var screenFocus: ScreenFocus {
        get { ScreenFocus(rawValue: defaults.string(forKey: Keys.screenFocus) ?? "") ?? .trimChrome }
        set { defaults.set(newValue.rawValue, forKey: Keys.screenFocus) }
    }

    /// Show the pre-record options prompt (recording mode + screen source) each time recording
    /// starts. On by default; when off, recording uses `defaultRecordingMode` and, if screen
    /// context is on, follows the frontmost window without prompting.
    static var askScreenSourceOnRecord: Bool {
        get { defaults.object(forKey: Keys.askScreenSourceOnRecord) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.askScreenSourceOnRecord) }
    }

    /// The recording mode used when not prompting, and the initial selection in the prompt.
    /// Updated to whatever was last chosen, so a run of conference recordings stays sticky.
    static var defaultRecordingMode: RecordingMode {
        get { RecordingMode(storageValue: defaults.string(forKey: Keys.defaultRecordingMode) ?? "call") }
        set { defaults.set(newValue.storageValue, forKey: Keys.defaultRecordingMode) }
    }

    /// Whether to surface upcoming video-call events in the menu. Off by default (needs
    /// calendar permission). Informational only — never auto-starts recording.
    static var calendarEnabled: Bool {
        get { defaults.bool(forKey: Keys.calendarEnabled) }
        set { defaults.set(newValue, forKey: Keys.calendarEnabled) }
    }

    /// Calendar identifiers to watch. Empty means all synced calendars.
    static var watchedCalendarIDs: [String] {
        get { defaults.stringArray(forKey: Keys.watchedCalendarIDs) ?? [] }
        set { defaults.set(newValue, forKey: Keys.watchedCalendarIDs) }
    }

    /// Maps a calendar identifier to a group tag. Calls recorded from that calendar are auto-tagged
    /// with it, so a calendar becomes a grouping dimension in search and the tag index.
    static var calendarGroups: [String: String] {
        get { (defaults.dictionary(forKey: Keys.calendarGroups) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Keys.calendarGroups) }
    }

    /// Generate an on-device title + summary for each transcript (needs Apple Intelligence).
    /// On by default.
    static var summarizeEnabled: Bool {
        get { defaults.object(forKey: Keys.summarizeEnabled) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.summarizeEnabled) }
    }

    /// After a recording finishes, prompt to name the call and its participants. On by default;
    /// the prompt is trivially skippable, and details are always editable later in the viewer.
    /// Naming participants is what makes the MCP's "calls with X" filters return anything.
    static var promptForDetails: Bool {
        get { defaults.object(forKey: Keys.promptForDetails) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.promptForDetails) }
    }

    /// Show a Dock icon (full app in ⌘-Tab). Off by default keeps the menu-bar-only feel; the hub
    /// still appears in the Dock while open regardless, then reverts on close.
    static var showInDock: Bool {
        get { defaults.bool(forKey: Keys.showInDock) }
        set { defaults.set(newValue, forKey: Keys.showInDock) }
    }
}

/// App appearance preference.
enum AppAppearance: String, CaseIterable, Identifiable {
    case system, light, dark
    var id: String { rawValue }
    var label: String {
        switch self {
        case .system: return "System"
        case .light: return "Light"
        case .dark: return "Dark"
        }
    }
}

/// A retention-window unit.
enum RetentionUnit: String, CaseIterable, Identifiable {
    case days, weeks, months

    var id: String { rawValue }

    var label: String {
        switch self {
        case .days: return "Days"
        case .weeks: return "Weeks"
        case .months: return "Months"
        }
    }

    var dayMultiplier: Int {
        switch self {
        case .days: return 1
        case .weeks: return 7
        case .months: return 30
        }
    }
}
