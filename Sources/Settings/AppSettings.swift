import Foundation
import Carbon.HIToolbox

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
        static let workspaceReadScopes = "workspaceReadScopes"
        static let workspaceReadVaults = "workspaceReadVaults"
        static let summarizeEnabled = "summarizeEnabled"
        static let notesMergeEnabled = "notesMergeEnabled"
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
        static let recordHotkeyKeyCode = "recordHotkeyKeyCode"
        static let recordHotkeyModifiers = "recordHotkeyModifiers"
        static let quickCaptureHotkeyKeyCode = "quickCaptureHotkeyKeyCode"
        static let quickCaptureHotkeyModifiers = "quickCaptureHotkeyModifiers"
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

    /// The record-toggle hotkey's combo (M25). Two plain `Int`s, not JSON/Codable — matches this
    /// file's existing storage convention for something this small. Defaults to the historical
    /// ⌥⌘R so nobody's shortcut silently changes on upgrade.
    static var recordHotkeyCombo: HotKeyCombo {
        get {
            // UInt32(exactly:), not UInt32(_:) (crosscheck) — the plain initializer TRAPS on a
            // stored Int outside UInt32's range (negative, or > UInt32.max). Since register() runs
            // unconditionally at every launch when the global hotkey is enabled (the default), a
            // single corrupted UserDefaults value — a stray `defaults write`, a botched sync — would
            // otherwise crash-loop the whole app with no recovery short of Terminal or reinstall.
            let keyCode = defaults.object(forKey: Keys.recordHotkeyKeyCode) as? Int ?? Int(HotKeyCombo.defaultRecord.keyCode)
            let modifiers = defaults.object(forKey: Keys.recordHotkeyModifiers) as? Int ?? Int(HotKeyCombo.defaultRecord.modifiers)
            return HotKeyCombo(
                keyCode: UInt32(exactly: keyCode) ?? HotKeyCombo.defaultRecord.keyCode,
                modifiers: UInt32(exactly: modifiers) ?? HotKeyCombo.defaultRecord.modifiers)
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Keys.recordHotkeyKeyCode)
            defaults.set(Int(newValue.modifiers), forKey: Keys.recordHotkeyModifiers)
        }
    }

    /// The Quick Capture hotkey's combo (M25). Defaults to the historical ⌥⌘N.
    static var quickCaptureHotkeyCombo: HotKeyCombo {
        get {
            // UInt32(exactly:) — see recordHotkeyCombo's getter for why the plain initializer isn't safe here.
            let keyCode = defaults.object(forKey: Keys.quickCaptureHotkeyKeyCode) as? Int ?? Int(HotKeyCombo.defaultQuickCapture.keyCode)
            let modifiers = defaults.object(forKey: Keys.quickCaptureHotkeyModifiers) as? Int ?? Int(HotKeyCombo.defaultQuickCapture.modifiers)
            return HotKeyCombo(
                keyCode: UInt32(exactly: keyCode) ?? HotKeyCombo.defaultQuickCapture.keyCode,
                modifiers: UInt32(exactly: modifiers) ?? HotKeyCombo.defaultQuickCapture.modifiers)
        }
        set {
            defaults.set(Int(newValue.keyCode), forKey: Keys.quickCaptureHotkeyKeyCode)
            defaults.set(Int(newValue.modifiers), forKey: Keys.quickCaptureHotkeyModifiers)
        }
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

    /// Maps a workspace to the ONE vault scope it reads (Doc 3 §7). Absent = unbound, which is a
    /// real state and not a default to fill: Ask refuses rather than picking a scope for you.
    ///
    /// Stored beside `calendarGroups` because that is already the authority on which workspace an
    /// artefact belongs to, and this is the same question asked of the engine's side. The WRITE
    /// scope is deliberately not here — it derives from the workspace name (`WorkspaceBinding`),
    /// so a name and a location cannot come apart.
    static var workspaceReadScopes: [String: String] {
        get { (defaults.dictionary(forKey: Keys.workspaceReadScopes) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Keys.workspaceReadScopes) }
    }

    /// The VAULT PATH of each workspace's bound scope, resolved once when the binding is made.
    ///
    /// A cache of engine state, which normally would not be worth the risk — but the engine
    /// guarantees the thing that makes a cache dangerous cannot happen: `scopes.record` "refuses to
    /// repoint an existing name at a DIFFERENT vault", so a scope name maps to one vault path for
    /// as long as that scope exists. The pair cannot silently diverge.
    ///
    /// Stored because capture needs it where the roster cannot be reached. A workspace vault
    /// declares `inherits = [<bound scope's vault>]`, and that manifest is written by
    /// `RecordingSession.destination(forWorkspace:)` — a `static` running off the main actor as a
    /// call finishes, while `SubstrateScopes` is `@MainActor`. Resolving at bind time is what lets
    /// the write path stay synchronous.
    static var workspaceReadVaults: [String: String] {
        get { (defaults.dictionary(forKey: Keys.workspaceReadVaults) as? [String: String]) ?? [:] }
        set { defaults.set(newValue, forKey: Keys.workspaceReadVaults) }
    }

    /// The workspace the user is currently in. Retrieval is hard-scoped to it (secure by default) —
    /// the LOCAL call store always was, and since Doc 3 §7 the engine pane beside it is too, via
    /// `workspaceReadScopes`. Before that binding existed the comment on this line was true of the
    /// call store and false of the vault Ask, which chose its scope by roster order.
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

    /// Merge mid-call notes with the transcript into a new, call-linked note (M16). Off by
    /// default — like `mirrorEnabled`, this writes a new file into the user's folder each time,
    /// which deserves an explicit opt-in rather than riding along on `summarizeEnabled` (a toggle
    /// whose own description never mentions creating files).
    static var notesMergeEnabled: Bool {
        get { defaults.bool(forKey: Keys.notesMergeEnabled) }
        set { defaults.set(newValue, forKey: Keys.notesMergeEnabled) }
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

/// A hotkey binding (M25) — a Carbon virtual keycode plus modifier bit flags, stored as two plain
/// `Int`s in `AppSettings` the same simple way every other value here persists (no JSON/Codable
/// for something this small).
struct HotKeyCombo: Equatable {
    let keyCode: UInt32
    let modifiers: UInt32

    /// Readable label ("⌥⌘R") for Settings. A static keycode→symbol table, not a full
    /// keyboard-layout-aware lookup (`UCKeyTranslate`/Text Input Source Services) — covers
    /// letters, digits, and the common special keys a global hotkey would realistically use.
    /// Correct regardless of layout for CAPTURE itself (`RegisterEventHotKey` operates on
    /// physical keycodes, not characters) but could show the wrong LETTER on a non-QWERTY layout
    /// — a disclosed v1 limitation (SPEC M25), not a silent gap.
    var label: String {
        var mods = ""
        if modifiers & UInt32(controlKey) != 0 { mods += "⌃" }
        if modifiers & UInt32(optionKey) != 0 { mods += "⌥" }
        if modifiers & UInt32(shiftKey) != 0 { mods += "⇧" }
        if modifiers & UInt32(cmdKey) != 0 { mods += "⌘" }
        return mods + (Self.keyLabels[keyCode] ?? "Key \(keyCode)")
    }

    // Every constant here is copied from Carbon.HIToolbox's Events.h, verified against the SDK
    // header directly rather than typed from memory (a transcription slip in a table this size,
    // this mechanical, would be an easy, hard-to-notice bug — e.g. labeling a bound key "R" when
    // it's actually "T").
    private static let keyLabels: [UInt32: String] = [
        UInt32(kVK_ANSI_A): "A", UInt32(kVK_ANSI_B): "B", UInt32(kVK_ANSI_C): "C", UInt32(kVK_ANSI_D): "D",
        UInt32(kVK_ANSI_E): "E", UInt32(kVK_ANSI_F): "F", UInt32(kVK_ANSI_G): "G", UInt32(kVK_ANSI_H): "H",
        UInt32(kVK_ANSI_I): "I", UInt32(kVK_ANSI_J): "J", UInt32(kVK_ANSI_K): "K", UInt32(kVK_ANSI_L): "L",
        UInt32(kVK_ANSI_M): "M", UInt32(kVK_ANSI_N): "N", UInt32(kVK_ANSI_O): "O", UInt32(kVK_ANSI_P): "P",
        UInt32(kVK_ANSI_Q): "Q", UInt32(kVK_ANSI_R): "R", UInt32(kVK_ANSI_S): "S", UInt32(kVK_ANSI_T): "T",
        UInt32(kVK_ANSI_U): "U", UInt32(kVK_ANSI_V): "V", UInt32(kVK_ANSI_W): "W", UInt32(kVK_ANSI_X): "X",
        UInt32(kVK_ANSI_Y): "Y", UInt32(kVK_ANSI_Z): "Z",
        UInt32(kVK_ANSI_0): "0", UInt32(kVK_ANSI_1): "1", UInt32(kVK_ANSI_2): "2", UInt32(kVK_ANSI_3): "3",
        UInt32(kVK_ANSI_4): "4", UInt32(kVK_ANSI_5): "5", UInt32(kVK_ANSI_6): "6", UInt32(kVK_ANSI_7): "7",
        UInt32(kVK_ANSI_8): "8", UInt32(kVK_ANSI_9): "9",
        UInt32(kVK_Space): "Space", UInt32(kVK_Return): "Return", UInt32(kVK_Tab): "Tab",
        UInt32(kVK_Delete): "Delete", UInt32(kVK_Escape): "Esc",
        UInt32(kVK_LeftArrow): "←", UInt32(kVK_RightArrow): "→", UInt32(kVK_UpArrow): "↑", UInt32(kVK_DownArrow): "↓",
        UInt32(kVK_F1): "F1", UInt32(kVK_F2): "F2", UInt32(kVK_F3): "F3", UInt32(kVK_F4): "F4",
        UInt32(kVK_F5): "F5", UInt32(kVK_F6): "F6", UInt32(kVK_F7): "F7", UInt32(kVK_F8): "F8",
        UInt32(kVK_F9): "F9", UInt32(kVK_F10): "F10", UInt32(kVK_F11): "F11", UInt32(kVK_F12): "F12",
    ]

    /// The historical, hardcoded combos, preserved as the defaults so nobody's shortcut silently
    /// changes on upgrade.
    static let defaultRecord = HotKeyCombo(keyCode: UInt32(kVK_ANSI_R), modifiers: UInt32(cmdKey | optionKey))
    static let defaultQuickCapture = HotKeyCombo(keyCode: UInt32(kVK_ANSI_N), modifiers: UInt32(cmdKey | optionKey))
}
