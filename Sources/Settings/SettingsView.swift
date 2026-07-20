import SwiftUI
import ScriptaCore
import AppKit
import EventKit

/// The render's two-column Settings: a category sub-sidebar (General / Output / Intelligence /
/// Recording / Calendar / Privacy & retention / Local model / Index) beside grouped-form content.
/// Every control predates the redesign — this file only reorganizes them into categories.
enum SettingsCategory: String, CaseIterable, Identifiable {
    case general, output, intelligence, recording, calendar, privacy, localModel, index

    var id: String { rawValue }

    var title: String {
        switch self {
        case .general: return "General"
        case .output: return "Output"
        case .intelligence: return "Intelligence"
        case .recording: return "Recording"
        case .calendar: return "Calendar"
        case .privacy: return "Privacy & retention"
        case .localModel: return "Local model"
        case .index: return "Index"
        }
    }

    var sfIcon: String {
        switch self {
        case .general: return "gearshape"
        case .output: return "folder"
        case .intelligence: return "sparkles"
        case .recording: return "record.circle"
        case .calendar: return "calendar"
        case .privacy: return "eye.slash"
        case .localModel: return "cpu"
        case .index: return "doc.text.magnifyingglass"
        }
    }
}

struct SettingsView: View {
    @State private var category: SettingsCategory = .general

    @State private var outputPath: String = AppSettings.outputFolder.path
    @State private var terms: [String] = AppSettings.domainVocabulary
    @State private var newTerm: String = ""
    @State private var summarizeEnabled: Bool = AppSettings.summarizeEnabled
    @State private var promptForDetails: Bool = AppSettings.promptForDetails
    @State private var showInDock: Bool = AppSettings.showInDock
    @State private var appearance: AppAppearance = AppSettings.appearance
    @State private var globalHotkey: Bool = AppSettings.globalHotkeyEnabled
    @State private var conversationRetention: Int = AppSettings.conversationRetentionDays
    @State private var retentionEnabled: Bool = AppSettings.retentionEnabled
    @State private var retentionCount: Int = AppSettings.retentionCount
    @State private var retentionUnit: RetentionUnit = AppSettings.retentionUnit
    @State private var screenEnabled: Bool = AppSettings.screenContextEnabled
    @State private var captureInterval: Int = AppSettings.screenCaptureInterval
    @State private var screenFocus: ScreenFocus = AppSettings.screenFocus
    @State private var askScreenSource: Bool = AppSettings.askScreenSourceOnRecord
    @State private var defaultMode: String = AppSettings.defaultRecordingMode.storageValue
    @State private var calendarEnabled: Bool = AppSettings.calendarEnabled
    @State private var calendarAuthorized: Bool = CalendarWatcher.shared.isAuthorized
    @State private var calendars: [EKCalendar] = []
    @State private var watchedIDs: Set<String> = Set(AppSettings.watchedCalendarIDs)
    @State private var indexStats: (calls: Int, passages: Int, bytes: Int) = (0, 0, 0)
    @State private var rebuilding = false
    @State private var backfillPending = 0
    @State private var backfilling = false
    @State private var backfillProgress = ""
    @State private var endpointEnabled = AppSettings.endpointEnabled
    @State private var endpointURLText = AppSettings.endpointURLString
    @State private var endpointModels: [String] = AppSettings.endpointKnownModels
    @State private var askModel = AppSettings.endpointModel(for: .ask) ?? ""
    @State private var enrichModel = AppSettings.endpointModel(for: .enrich) ?? ""
    @State private var endpointStatus = ""
    @State private var endpointOK: Bool?
    @State private var testingEndpoint = false
    @State private var confirmLAN = false
    @State private var rerankEnabled = AppSettings.rerankEnabled
    @State private var embedModel = AppSettings.embedModel
    @State private var mirrorEnabled = AppSettings.mirrorEnabled
    @State private var visionModel = AppSettings.visionModel

    var body: some View {
        HStack(spacing: 0) {
            categorySidebar
            Rectangle().fill(Carbon.borderSubtle).frame(width: 1)
            content
        }
        .background(Carbon.background)
        .onAppear {
            if calendarEnabled && calendarAuthorized { calendars = CalendarWatcher.shared.calendars() }
            refreshIndexInfo()
        }
        .alert("Allow this local network address?", isPresented: $confirmLAN) {
            Button("Cancel", role: .cancel) {}
            Button("Allow") { AppSettings.endpointLANConfirmed = true; runEndpointTest() }
        } message: {
            Text("\(endpointURLText) is on your local network. The app will connect to it directly. Public internet addresses are never allowed.")
        }
    }

    // MARK: - Category sidebar (render: SETTINGS header + icon rows with selection pills)

    private var categorySidebar: some View {
        VStack(alignment: .leading, spacing: 2) {
            SectionHeader(title: "Settings")
                .padding(.horizontal, 10)
                .padding(.top, Space.x5)
                .padding(.bottom, Space.x3)
            ForEach(SettingsCategory.allCases) { item in
                let selected = category == item
                Button {
                    category = item
                } label: {
                    HStack(spacing: 11) {
                        Image(systemName: item.sfIcon)
                            .font(.system(size: 14))
                            .foregroundStyle(selected ? Carbon.interactive : Carbon.iconSecondary)
                            .frame(width: 18)
                        Text(item.title)
                            .font(selected ? CarbonFont.semibold(13) : CarbonFont.body(13))
                            .foregroundStyle(selected ? Carbon.textPrimary : Carbon.textSecondary)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                    }
                    .padding(.horizontal, 10)
                    .frame(height: 34)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(selected ? Carbon.blueSoft : Color.clear,
                                in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
        .padding(.horizontal, 10)
        .frame(width: 210)
        .background(Carbon.layer.opacity(0.4))
    }

    // MARK: - Content

    private var content: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(category.title)
                .font(CarbonFont.semibold(22)).foregroundStyle(Carbon.textPrimary)
                .padding(.horizontal, Space.x7)
                .padding(.top, Space.x7)
                .padding(.bottom, Space.x2)
            Form {
                switch category {
                case .general: generalSections
                case .output: outputSections
                case .intelligence: intelligenceSections
                case .recording: recordingSections
                case .calendar: calendarSections
                case .privacy: privacySections
                case .localModel: localModelSections
                case .index: indexSections
                }
            }
            .formStyle(.grouped)
            .font(CarbonFont.body(13))
            .scrollContentBackground(.hidden)
            .frame(maxWidth: 680, alignment: .leading)
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
    }

    // MARK: - General (appearance + shortcuts + call details)

    @ViewBuilder private var generalSections: some View {
        Section {
            Picker("Theme", selection: $appearance) {
                ForEach(AppAppearance.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .onChange(of: appearance) { _, newValue in
                AppSettings.appearance = newValue
                AppModel.shared.applyAppearance()
            }
            Toggle("Show in Dock", isOn: $showInDock)
                .onChange(of: showInDock) { _, newValue in
                    AppSettings.showInDock = newValue
                    // Only promote here. This toggle lives inside the hub, so demoting to
                    // .accessory now would deactivate the very window the user is in —
                    // the hub's windowWillClose applies the preference on close.
                    if newValue { NSApp.setActivationPolicy(.regular) }
                }
        } header: {
            Text("Appearance")
        } footer: {
            Text("Theme follows the system by default, or lock it to Light or Dark. Show in Dock (the default) makes Scripta behave like a normal app — Dock icon, ⌘-Tab, window at launch; turn it off for a quiet menu-bar-only app.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section {
            Toggle("Global ⌥⌘R to start/stop recording", isOn: $globalHotkey)
                .onChange(of: globalHotkey) { _, newValue in
                    AppSettings.globalHotkeyEnabled = newValue
                    HotKeyManager.shared.setEnabled(newValue)
                }
        } header: {
            Text("Shortcuts")
        } footer: {
            Text("⌥⌘R starts or stops a recording from any app; ⌥⌘N adds a timestamped note during one.")
                .font(.caption).foregroundStyle(.secondary)
        }

        Section {
            Toggle("Name the call after recording", isOn: $promptForDetails)
                .onChange(of: promptForDetails) { _, newValue in
                    AppSettings.promptForDetails = newValue
                }
        } header: {
            Text("Call Details")
        } footer: {
            Text("When a recording finishes, prompt for a title and participants. You can skip it, and edit details any time in the reader. Naming participants is what makes “calls with …” search work.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Picker("Delete conversations", selection: $conversationRetention) {
                Text("Never").tag(0)
                Text("After 7 days").tag(7)
                Text("After 30 days").tag(30)
                Text("After 90 days").tag(90)
            }
            .onChange(of: conversationRetention) { _, newValue in
                AppSettings.conversationRetentionDays = newValue
                AppModel.shared.ask.pruneExpiredConversations()
            }
        } header: {
            Text("Clovis")
        } footer: {
            Text("Automatically delete Clovis chat conversations older than this. Off by default (kept until you delete them). Your calls and notes are never affected.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Output

    @ViewBuilder private var outputSections: some View {
        Section {
            LabeledContent("Transcripts folder") {
                HStack(spacing: 8) {
                    Text(prettyPath)
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.secondary)
                    Button("Choose…", action: chooseFolder)
                }
            }
        } header: {
            Text("Output")
        } footer: {
            Text("Point this at an Obsidian vault or synced folder to get multi-device access for free. Knowledge notes live in a Notes/ subfolder alongside your transcripts.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Intelligence (AI features + ASR vocabulary)

    @ViewBuilder private var intelligenceSections: some View {
        Section {
            Toggle("Title & summarize new calls", isOn: $summarizeEnabled)
                .onChange(of: summarizeEnabled) { _, newValue in
                    AppSettings.summarizeEnabled = newValue
                }
            if summarizeEnabled && !TranscriptEnricher.isAvailable && !endpointEnabled {
                Text("Requires Apple Intelligence — enable it in System Settings › Apple Intelligence & Siri, or set up a local model server under Local model.")
                    .font(.caption).foregroundStyle(.orange)
            }
        } header: {
            Text("Intelligence")
        } footer: {
            Text("Generates a descriptive title and short summary for each transcript, on-device. Filler words (um, uh) are always removed. Your transcript wording is never rewritten — only the title and summary are AI-generated.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            if terms.isEmpty {
                Text("No terms yet.")
                    .foregroundStyle(.secondary)
            } else {
                ForEach(terms, id: \.self) { term in
                    HStack {
                        Text(term)
                        Spacer()
                        Button {
                            remove(term)
                        } label: {
                            Image(systemName: "minus.circle.fill")
                                .foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .help("Remove")
                    }
                }
            }
            HStack {
                TextField("Add a term…", text: $newTerm)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTerm)
                Button("Add", action: addTerm)
                    .disabled(newTerm.trimmingCharacters(in: .whitespaces).isEmpty)
            }
        } header: {
            Text("Transcription Bias")
        } footer: {
            Text("Names and jargon transcription might otherwise mishear — these bias it toward the right spellings. For terms with aliases and meanings that also power search (\"TIM\" finding \"tenants in the market\"), use Vocabulary in the Knowledge pane.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Recording (mode + screen context)

    @ViewBuilder private var recordingSections: some View {
        Section {
            Picker("Default mode", selection: $defaultMode) {
                Text("Call").tag("call")
                Text("Conference · System audio").tag("conference-system")
                Text("Conference · Microphone").tag("conference-microphone")
            }
            .onChange(of: defaultMode) { _, newValue in
                AppSettings.defaultRecordingMode = RecordingMode(storageValue: newValue)
            }
            Toggle("Choose mode & screen before each recording", isOn: $askScreenSource)
                .onChange(of: askScreenSource) { _, newValue in
                    AppSettings.askScreenSourceOnRecord = newValue
                }
        } header: {
            Text("Recording")
        } footer: {
            Text("Call records both sides and labels You/Them. Conference records a single source — use it when you're both in the room and joined online, so the meeting isn't transcribed twice. With the prompt off, new recordings just use the default mode.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Toggle("Capture screen context", isOn: $screenEnabled)
                .onChange(of: screenEnabled) { _, newValue in
                    AppSettings.screenContextEnabled = newValue
                }
            if screenEnabled {
                Picker("Capture every", selection: $captureInterval) {
                    ForEach(5...10, id: \.self) { seconds in
                        Text("\(seconds) seconds").tag(seconds)
                    }
                }
                .onChange(of: captureInterval) { _, newValue in
                    AppSettings.screenCaptureInterval = newValue
                }
                Picker("Focus", selection: $screenFocus) {
                    ForEach(ScreenFocus.allCases) { level in
                        Text(level.label).tag(level)
                    }
                }
                .onChange(of: screenFocus) { _, newValue in
                    AppSettings.screenFocus = newValue
                }
            }
        } header: {
            Text("Screen Context")
        } footer: {
            Text("Periodically reads text from your frontmost window and adds meaningfully-changed content to the transcript. Screenshots are discarded immediately — only text is kept. Only the window you're actively in is seen, never a second monitor.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Calendar

    @ViewBuilder private var calendarSections: some View {
        Section {
            Toggle("Show upcoming calls", isOn: $calendarEnabled)
                .onChange(of: calendarEnabled) { _, enabling in
                    AppSettings.calendarEnabled = enabling
                    if enabling { enableCalendar() }
                }
            if calendarEnabled {
                if calendarAuthorized {
                    if calendars.isEmpty {
                        Text("No calendars found.").foregroundStyle(.secondary)
                    } else {
                        // Computed once for the whole list, not per row: availableGroups() reads
                        // through to a lock-acquiring SQL query, and every other derived list in
                        // this file (calendars, terms, endpointModels) is already fetched once
                        // rather than inside a ForEach.
                        let workspaces = AppModel.shared.availableGroups()
                        ForEach(calendars, id: \.calendarIdentifier) { calendar in
                            VStack(alignment: .leading, spacing: 6) {
                                Toggle(isOn: watchBinding(for: calendar.calendarIdentifier)) {
                                    HStack(spacing: 8) {
                                        Circle()
                                            .fill(Color(cgColor: calendar.cgColor))
                                            .frame(width: 9, height: 9)
                                        VStack(alignment: .leading, spacing: 1) {
                                            Text(calendar.title)
                                            Text(calendar.source.title)
                                                .font(.caption)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                }
                                if isWatched(calendar.calendarIdentifier) {
                                    // A closed set, not free text: the sidebar's own workspace
                                    // switcher (HubView.groupSwitcher) offers the identical
                                    // "Ungrouped" + known-workspaces choice, and typing a name by
                                    // hand here risked a silent near-duplicate workspace (a typo,
                                    // or a casing mismatch — see groupBinding). New workspaces are
                                    // still created in one place: the sidebar's "New workspace…".
                                    Picker("Workspace", selection: groupBinding(for: calendar.calendarIdentifier)) {
                                        Text("Ungrouped").tag("")
                                        ForEach(workspaces, id: \.self) { Text($0).tag($0) }
                                    }
                                    .labelsHidden()
                                    .padding(.leading, 18)
                                }
                            }
                        }
                    }
                } else {
                    Text("Grant access in System Settings › Privacy & Security › Calendars, then reopen Settings.")
                        .font(.caption).foregroundStyle(.secondary)
                }
            }
        } header: {
            Text("Calendar")
        } footer: {
            Text("Shows your next Zoom/Teams/Meet events in Meetings. Reads only calendars synced into the macOS Calendar app. Informational only — never auto-starts recording. Assign a calendar a workspace to record its meetings straight into it (also available from the workspace menu in the sidebar).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Privacy & retention

    @ViewBuilder private var privacySections: some View {
        Section {
            Picker("Keep transcripts", selection: $retentionEnabled) {
                Text("Forever").tag(false)
                Text("For a set time").tag(true)
            }
            .onChange(of: retentionEnabled) { _, newValue in
                AppSettings.retentionEnabled = newValue
            }
            if retentionEnabled {
                LabeledContent("Delete after") {
                    HStack(spacing: 8) {
                        TextField("", value: $retentionCount, format: .number)
                            .frame(width: 56)
                            .textFieldStyle(.roundedBorder)
                            .onChange(of: retentionCount) { _, newValue in
                                AppSettings.retentionCount = max(1, newValue)
                            }
                        Picker("", selection: $retentionUnit) {
                            ForEach(RetentionUnit.allCases) { unit in
                                Text(unit.label).tag(unit)
                            }
                        }
                        .labelsHidden()
                        .frame(width: 110)
                        .onChange(of: retentionUnit) { _, newValue in
                            AppSettings.retentionUnit = newValue
                        }
                    }
                }
            }
        } header: {
            Text("Retention")
        } footer: {
            Text("Auto-deletes only transcripts this app created (identified by a marker inside the file), never other files in the folder. Checked at launch. Raw audio is always deleted immediately, regardless of this setting.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }

        Section {
            Toggle("Mirror entities into the vault", isOn: $mirrorEnabled)
                .onChange(of: mirrorEnabled) { _, v in
                    AppSettings.mirrorEnabled = v
                    if v, let store = IndexStore.shared {
                        Task.detached(priority: .utility) { EntityMirror.sync(store: store) }
                    }
                }
        } header: {
            Text("Vault Mirror")
        } footer: {
            Text("Writes entity stub notes (people, companies) into Entities/ inside your folder, wikilinked to their calls. Off by default: the vault can't enforce workspace privacy, so mirroring weakens the wall.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Local model

    @ViewBuilder private var localModelSections: some View {
        Section {
            Toggle("Use a local model server", isOn: $endpointEnabled)
                .onChange(of: endpointEnabled) { _, v in AppSettings.endpointEnabled = v }
            if endpointEnabled {
                TextField("http://localhost:11434/v1", text: $endpointURLText)
                    .textFieldStyle(.roundedBorder)
                    .onChange(of: endpointURLText) { _, v in
                        AppSettings.endpointURLString = v.trimmingCharacters(in: .whitespaces)
                        // Editing the endpoint invalidates any prior LAN confirmation — the new
                        // address must be confirmed again before it's used (audit L1).
                        AppSettings.endpointLANConfirmed = false
                    }
                HStack(spacing: 8) {
                    Button(testingEndpoint ? "Testing…" : "Test connection") { testEndpoint() }
                        .disabled(testingEndpoint || endpointURLText.isEmpty)
                    if let ok = endpointOK {
                        Circle().fill(ok ? Color.green : Color.red).frame(width: 8, height: 8)
                    }
                    Text(endpointStatus).font(.caption).foregroundStyle(.secondary).lineLimit(2)
                }
                Picker("Ask your calls", selection: $askModel) {
                    Text("Apple Intelligence (default)").tag("")
                    ForEach(endpointModels, id: \.self) { Text($0).tag($0) }
                    if !askModel.isEmpty && !endpointModels.contains(askModel) {
                        Text("\(askModel) (not on server)").tag(askModel)
                    }
                }
                .onChange(of: askModel) { _, v in AppSettings.setEndpointModel(v.isEmpty ? nil : v, for: .ask) }
                Picker("Titles & summaries", selection: $enrichModel) {
                    Text("Apple Intelligence (default)").tag("")
                    ForEach(endpointModels, id: \.self) { Text($0).tag($0) }
                    if !enrichModel.isEmpty && !endpointModels.contains(enrichModel) {
                        Text("\(enrichModel) (not on server)").tag(enrichModel)
                    }
                }
                .onChange(of: enrichModel) { _, v in AppSettings.setEndpointModel(v.isEmpty ? nil : v, for: .enrich) }
                Picker("Semantic search (embeddings)", selection: $embedModel) {
                    Text("Off — keyword only").tag("")
                    ForEach(endpointModels, id: \.self) { Text($0).tag($0) }
                    if !embedModel.isEmpty && !endpointModels.contains(embedModel) {
                        Text("\(embedModel) (not on server)").tag(embedModel)
                    }
                }
                .onChange(of: embedModel) { _, v in AppSettings.embedModel = v }
                Picker("Screen captioning (vision)", selection: $visionModel) {
                    Text("Off — OCR text only").tag("")
                    ForEach(endpointModels, id: \.self) { Text($0).tag($0) }
                    if !visionModel.isEmpty && !endpointModels.contains(visionModel) {
                        Text("\(visionModel) (not on server)").tag(visionModel)
                    }
                }
                .onChange(of: visionModel) { _, v in AppSettings.visionModel = v }
                if !askModel.isEmpty {
                    Toggle("Rerank Ask results (experimental)", isOn: $rerankEnabled)
                        .onChange(of: rerankEnabled) { _, v in AppSettings.rerankEnabled = v }
                }
            }
        } header: {
            Text("Local Model (advanced)")
        } footer: {
            Text("Point the app at an OpenAI-compatible server on this Mac or your LAN (Ollama, LM Studio) and assign a bigger model per task. Apple Intelligence stays the default and the automatic fallback. Only localhost and private addresses are ever contacted — never the public internet. Setup: `brew install ollama`, then e.g. `ollama pull qwen2.5:14b` (≈9 GB, smarter) or `qwen2.5:7b` (≈4.5 GB, faster).")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Index

    @ViewBuilder private var indexSections: some View {
        Section {
            LabeledContent("Search index",
                           value: "\(indexStats.calls) calls · \(indexStats.passages) passages · \(byteString(indexStats.bytes))")
            Button(rebuilding ? "Rebuilding…" : "Rebuild Index") { rebuildIndex() }
                .disabled(rebuilding)
            if backfillPending > 0 {
                Button(backfilling
                       ? "Adding topic tags… \(backfillProgress)"
                       : "Add topic tags to \(backfillPending) older call\(backfillPending == 1 ? "" : "s")") { runBackfill() }
                    .disabled(backfilling || !TranscriptEnricher.isAvailable)
            }
        } header: {
            Text("Index")
        } footer: {
            Text("The search index is a rebuildable cache derived from your transcripts — never your notes. Rebuild it if search or Ask results look wrong. Topic tags let a call surface by subject even when the word was never spoken; older calls can be tagged in one on-device pass.")
                .font(.caption)
                .foregroundStyle(.secondary)
        }
    }

    // MARK: - Endpoint plumbing

    private func testEndpoint() {
        guard let url = URL(string: endpointURLText.trimmingCharacters(in: .whitespaces)), url.host != nil else {
            endpointOK = false; endpointStatus = "Invalid URL"; return
        }
        switch Locality.classify(url) {
        case .refused:
            endpointOK = false; endpointStatus = "Not a local address — only localhost/LAN is allowed"
        case .lan where !AppSettings.endpointLANConfirmed:
            confirmLAN = true
        default:
            runEndpointTest()
        }
    }

    private func runEndpointTest() {
        testingEndpoint = true; endpointStatus = "Connecting…"; endpointOK = nil
        Task {
            guard let url = AppSettings.endpointURL else { testingEndpoint = false; return }
            let wire = OpenAIWire(baseURL: url, lanConfirmed: AppSettings.endpointLANConfirmed)
            let started = Date()
            do {
                let models = try await wire.models(timeout: 3)
                let ms = Int(Date().timeIntervalSince(started) * 1000)
                AppSettings.endpointKnownModels = models
                endpointModels = models
                endpointOK = true
                endpointStatus = "Connected — \(models.count) model\(models.count == 1 ? "" : "s"), \(ms) ms"
            } catch {
                endpointOK = false
                endpointStatus = (error as? EngineError)?.errorDescription ?? "Couldn’t connect"
            }
            testingEndpoint = false
        }
    }

    private func byteString(_ bytes: Int) -> String {
        ByteCountFormatter.string(fromByteCount: Int64(bytes), countStyle: .file)
    }

    private func refreshIndexInfo() {
        indexStats = IndexStore.shared?.stats() ?? (0, 0, 0)
        backfillPending = ConceptBackfill.pending().count
    }

    private func rebuildIndex() {
        rebuilding = true
        Task.detached(priority: .userInitiated) {
            IndexStore.shared?.clear()
            if let store = IndexStore.shared {
                IndexBuilder.syncTerms(store: store)
                IndexBuilder.reconcile(store: store)
                // Re-embed here too: clear() wiped chunk_vectors, and embedPending otherwise only runs
                // at launch — so a manual rebuild would leave vectors empty until the next launch.
                // No-op unless an embedder is configured. EntityMirror mirrors the launch order.
                await IndexBuilder.embedPending(store: store)
                EntityMirror.sync(store: store)   // no-op unless mirroring is enabled
            }
            await MainActor.run {
                AppModel.shared.reloadCalls()
                rebuilding = false
                refreshIndexInfo()
            }
        }
    }

    private func runBackfill() {
        backfilling = true
        Task {
            _ = await ConceptBackfill.run { done, total in backfillProgress = "\(done)/\(total)" }
            AppModel.shared.reloadCalls()
            backfilling = false
            refreshIndexInfo()
        }
    }

    private func enableCalendar() {
        Task {
            let granted = await CalendarWatcher.shared.requestAccess()
            calendarAuthorized = granted
            if granted { calendars = CalendarWatcher.shared.calendars() }
        }
    }

    /// A calendar is watched if none are explicitly chosen (empty = all) or it's in the set.
    private func watchBinding(for id: String) -> Binding<Bool> {
        Binding(
            get: { watchedIDs.isEmpty || watchedIDs.contains(id) },
            set: { isOn in
                var ids = watchedIDs.isEmpty ? Set(calendars.map(\.calendarIdentifier)) : watchedIDs
                if isOn { ids.insert(id) } else { ids.remove(id) }
                watchedIDs = ids
                AppSettings.watchedCalendarIDs = Array(ids)
            }
        )
    }

    private func isWatched(_ id: String) -> Bool {
        watchedIDs.isEmpty || watchedIDs.contains(id)
    }

    /// Two-way binding for a calendar's workspace, persisted to AppSettings. Reads/writes
    /// `AppSettings.calendarGroups` directly (no locally-cached snapshot, unlike most other
    /// bindings in this file) because the sidebar's own "Assign calendars to <workspace>" menu
    /// (HubView.groupSwitcher) can write the same dictionary while Settings is open — a cached
    /// copy would go stale, and worse, a later edit here would clobber the sidebar's change on
    /// write-back (crosscheck: this is exactly what the old cached version did). Values only
    /// ever come from the Picker's own tags — existing workspace names, or "" for none — never
    /// re-typed, so this must NOT re-normalize the string (it used to lowercase on write, which
    /// silently diverged from workspace names created via the sidebar's "New workspace…" flow).
    private func groupBinding(for id: String) -> Binding<String> {
        Binding(
            get: { AppSettings.calendarGroups[id] ?? "" },
            set: { value in
                var groups = AppSettings.calendarGroups
                groups[id] = value.isEmpty ? nil : value
                AppSettings.calendarGroups = groups
            }
        )
    }

    private var prettyPath: String {
        outputPath.replacingOccurrences(of: NSHomeDirectory(), with: "~")
    }

    // MARK: - Actions

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.canCreateDirectories = true
        panel.prompt = "Choose"
        panel.directoryURL = URL(fileURLWithPath: outputPath)
        if panel.runModal() == .OK, let url = panel.url {
            AppSettings.setOutputFolder(url)
            MCPStateFile.write()   // publish the new path to the MCP server promptly
            outputPath = url.path
            // Re-point the watcher, registry, and index — otherwise they keep pointing at the
            // old corpus/registry until the next launch.
            IndexWatcher.shared?.start(folder: url)
            EntityRegistry.repoint(toFolder: url)
            Task.detached(priority: .utility) {
                if let store = IndexStore.shared {
                    // Terms mirror first: the old vault's vocabulary must not keep driving alias
                    // expansion/glosses against the new corpus for the rest of the session.
                    IndexBuilder.syncTerms(store: store)
                    IndexBuilder.reconcile(store: store)
                }
                await MainActor.run { AppModel.shared.reloadCalls(); refreshIndexInfo() }
            }
        }
    }

    private func addTerm() {
        let trimmed = newTerm.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !terms.contains(trimmed) else { newTerm = ""; return }
        terms.append(trimmed)
        AppSettings.domainVocabulary = terms
        newTerm = ""
    }

    private func remove(_ term: String) {
        terms.removeAll { $0 == term }
        AppSettings.domainVocabulary = terms
    }
}
