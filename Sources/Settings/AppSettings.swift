import Foundation

/// Central app configuration, backed by UserDefaults. Milestone 5 adds the Settings UI
/// on top of these; for now they expose sensible defaults so the pipeline can run.
enum AppSettings {
    private static let defaults = UserDefaults.standard

    private enum Keys {
        static let outputFolder = "outputFolderPath"
        static let outputFolderBookmark = "outputFolderBookmark"
        static let firstRunNoticeShown = "firstRunNoticeShown"
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
        static let activeGroup = "activeGroup"
        static let summarizeEnabled = "summarizeEnabled"
        static let promptForDetails = "promptForDetails"
        static let showInDock = "showInDock"
        static let appearance = "appearance"
        static let endpointEnabled = "endpointEnabled"
        static let endpointURL = "endpointURL"
        static let endpointLANConfirmed = "endpointLANConfirmed"
        static let endpointModelAsk = "endpointModelAsk"
        static let endpointModelEnrich = "endpointModelEnrich"
        static let endpointKnownModels = "endpointKnownModels"
        static let appleFMSizeClass = "appleFMSizeClass"
        static let rerankEnabled = "rerankEnabled"
        static let embedModel = "embedModel"
        static let mirrorEnabled = "mirrorEnabled"
        static let visionModel = "visionModel"
        static let sidebarExpanded = "sidebarExpanded"
        static let globalHotkey = "globalHotkey"
        static let liveTranscription = "liveTranscription"
        static let conversationRetentionDays = "conversationRetentionDays"
    }

    /// Auto-delete Clovis conversations older than this many days. 0 = keep forever (default).
    static var conversationRetentionDays: Int {
        get { defaults.integer(forKey: Keys.conversationRetentionDays) }
        set { defaults.set(max(0, newValue), forKey: Keys.conversationRetentionDays) }
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

    /// Folder transcripts are written to. Defaults to ~/Documents/Scripta.
    /// Milestone 5 lets the user point this at an Obsidian vault / synced folder.
    static var outputFolder: URL {
        get {
            if let path = defaults.string(forKey: Keys.outputFolder), !path.isEmpty {
                return URL(fileURLWithPath: path)
            }
            let documents = FileManager.default.urls(for: .documentDirectory, in: .userDomainMask)[0]
            return documents.appendingPathComponent("Scripta", isDirectory: true)
        }
        set { defaults.set(newValue.path, forKey: Keys.outputFolder) }
    }

    /// Security-scoped bookmark for the output folder. Under the App Sandbox a stored path grants
    /// nothing across launches — the bookmark carries the user's folder grant instead.
    static var outputFolderBookmark: Data? {
        get { defaults.data(forKey: Keys.outputFolderBookmark) }
        set { defaults.set(newValue, forKey: Keys.outputFolderBookmark) }
    }

    /// Points the app at a user-chosen folder: stores the path plus a security-scoped bookmark.
    /// The open panel's own grant covers the current session; the bookmark covers every later one.
    static func setOutputFolder(_ url: URL) {
        outputFolder = url
        outputFolderBookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                     includingResourceValuesForKeys: nil,
                                                     relativeTo: nil)
    }

    /// Resolves and activates the stored folder grant. Must run at launch before anything touches
    /// the output folder. The scoped access is held for the app's lifetime — every subsystem
    /// (writer, watcher, pruner, registry, mirror, orphan recovery) rides this one grant.
    /// Returns false when a bookmark existed but no longer resolves (folder deleted/detached);
    /// the bookmark is cleared so the app falls back to the default folder instead of failing forever.
    @discardableResult
    static func restoreOutputFolderAccess() -> Bool {
        guard let data = outputFolderBookmark else { return true }   // default folder — no grant needed
        var stale = false
        guard let url = try? URL(resolvingBookmarkData: data, options: .withSecurityScope,
                                 relativeTo: nil, bookmarkDataIsStale: &stale) else {
            outputFolderBookmark = nil
            return false
        }
        _ = url.startAccessingSecurityScopedResource()
        if stale {
            outputFolderBookmark = try? url.bookmarkData(options: .withSecurityScope,
                                                         includingResourceValuesForKeys: nil,
                                                         relativeTo: nil)
        }
        outputFolder = url   // the folder may have moved; keep the stored path honest
        return true
    }

    /// One-time first-launch notice (recording-consent reminder + transcripts-folder choice).
    static var firstRunNoticeShown: Bool {
        get { defaults.bool(forKey: Keys.firstRunNoticeShown) }
        set { defaults.set(newValue, forKey: Keys.firstRunNoticeShown) }
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

    /// Maps a calendar identifier to a group. Calls recorded from that calendar are captured into
    /// that group; a calendar becomes a first-class privacy/workspace partition.
    static var calendarGroups: [String: String] {
        get { (defaults.dictionary(forKey: Keys.calendarGroups) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Keys.calendarGroups) }
    }

    /// The workspace the user is currently in. Retrieval is hard-scoped to it (secure by default).
    /// "" = the ungrouped workspace (also the fresh-install default, so the app behaves as one
    /// bucket until groups exist). The explicit "all groups" action is transient, never persisted.
    static var activeGroup: String {
        get { defaults.string(forKey: Keys.activeGroup) ?? "" }
        set { defaults.set(newValue, forKey: Keys.activeGroup) }
    }

    /// The group captured for a new recording: a calendar's group if tied to one, else the active
    /// workspace. Captured at record time so it's a stable string, not a live calendar reference.
    static func recordingGroup(forCalendarID calendarID: String?) -> String {
        if let calendarID, let group = calendarGroups[calendarID], !group.isEmpty { return group }
        return activeGroup
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

    /// Behave like a normal app: Dock icon, ⌘-Tab, hub window at launch. ON by default —
    /// turning it off makes Scripta a menu-bar-only app (the hub still appears in the Dock
    /// while open, then the app tucks back into the menu bar on close).
    static var showInDock: Bool {
        get { defaults.object(forKey: Keys.showInDock) as? Bool ?? true }
        set { defaults.set(newValue, forKey: Keys.showInDock) }
    }

    // MARK: - Local model endpoint (opt-in; Apple FM is always the default + fallback)

    /// When true, tasks assigned to the endpoint use it. Default false — nothing constructs a
    /// URLSession or makes any network call while this is off.
    static var endpointEnabled: Bool {
        get { defaults.bool(forKey: Keys.endpointEnabled) }
        set { defaults.set(newValue, forKey: Keys.endpointEnabled) }
    }

    /// The local server base URL (e.g. http://localhost:11434/v1). Only loopback/LAN is ever used.
    static var endpointURL: URL? {
        get { (defaults.string(forKey: Keys.endpointURL)).flatMap(URL.init(string:)) }
        set { defaults.set(newValue?.absoluteString, forKey: Keys.endpointURL) }
    }
    static var endpointURLString: String {
        get { defaults.string(forKey: Keys.endpointURL) ?? "" }
        set { defaults.set(newValue, forKey: Keys.endpointURL) }
    }

    /// Set once the user confirms a private-LAN (non-loopback) address. Loopback needs no confirm.
    static var endpointLANConfirmed: Bool {
        get { defaults.bool(forKey: Keys.endpointLANConfirmed) }
        set { defaults.set(newValue, forKey: Keys.endpointLANConfirmed) }
    }

    /// Model ids assigned per task, or nil to use Apple FM for that task.
    static func endpointModel(for task: EngineTask) -> String? {
        let key = task == .ask ? Keys.endpointModelAsk : Keys.endpointModelEnrich
        let value = defaults.string(forKey: key) ?? ""
        return value.isEmpty ? nil : value
    }
    static func setEndpointModel(_ model: String?, for task: EngineTask) {
        defaults.set(model ?? "", forKey: task == .ask ? Keys.endpointModelAsk : Keys.endpointModelEnrich)
    }

    /// Last-seen model ids, so the pickers stay populated when the server is momentarily down.
    static var endpointKnownModels: [String] {
        get { defaults.stringArray(forKey: Keys.endpointKnownModels) ?? [] }
        set { defaults.set(newValue, forKey: Keys.endpointKnownModels) }
    }

    /// Which prompt tier Apple FM gets. `.compact` today; a hidden override lets a newer-silicon
    /// tester flip to `.capable` without brittle CPU brand-string probing.
    static var appleFMSizeClass: SizeClass {
        SizeClass(rawValue: defaults.string(forKey: Keys.appleFMSizeClass) ?? "") ?? .compact
    }

    /// Rerank Ask's retrieved candidates with the assigned local model (gated experiment).
    /// Default off — turn on only if the eval shows it helps on your corpus.
    static var rerankEnabled: Bool {
        get { defaults.bool(forKey: Keys.rerankEnabled) }
        set { defaults.set(newValue, forKey: Keys.rerankEnabled) }
    }

    /// The local embedding model for semantic retrieval (e.g. "nomic-embed-text"). "" = off, so
    /// retrieval stays pure-FTS. Hybrid fusion turns on once chunks are embedded with it.
    static var embedModel: String {
        get { defaults.string(forKey: Keys.embedModel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.embedModel) }
    }

    /// Local vision model for captioning screenshots OCR can't read (e.g. "qwen2.5vl:7b"). "" =
    /// off. Runs only in the post-call pass, never during a meeting.
    static var visionModel: String {
        get { defaults.string(forKey: Keys.visionModel) ?? "" }
        set { defaults.set(newValue, forKey: Keys.visionModel) }
    }

    /// Mirror the entity graph into the vault as `Entities/<Group>/…` stub notes. Default off —
    /// it writes into your vault and (since the vault can't enforce the wall) weakens group privacy.
    static var mirrorEnabled: Bool {
        get { defaults.bool(forKey: Keys.mirrorEnabled) }
        set { defaults.set(newValue, forKey: Keys.mirrorEnabled) }
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
