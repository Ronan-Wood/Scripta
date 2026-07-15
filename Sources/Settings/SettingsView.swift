import SwiftUI
import AppKit
import EventKit

struct SettingsView: View {
    @State private var outputPath: String = AppSettings.outputFolder.path
    @State private var terms: [String] = AppSettings.domainVocabulary
    @State private var newTerm: String = ""
    @State private var summarizeEnabled: Bool = AppSettings.summarizeEnabled
    @State private var promptForDetails: Bool = AppSettings.promptForDetails
    @State private var showInDock: Bool = AppSettings.showInDock
    @State private var appearance: AppAppearance = AppSettings.appearance
    @State private var globalHotkey: Bool = AppSettings.globalHotkeyEnabled
    @State private var retentionEnabled: Bool = AppSettings.retentionEnabled
    @State private var retentionCount: Int = AppSettings.retentionCount
    @State private var retentionUnit: RetentionUnit = AppSettings.retentionUnit
    @State private var screenEnabled: Bool = AppSettings.screenContextEnabled
    @State private var captureInterval: Int = AppSettings.screenCaptureInterval
    @State private var screenFocus: ScreenFocus = AppSettings.screenFocus
    @State private var askScreenSource: Bool = AppSettings.askScreenSourceOnRecord
    @State private var calendarEnabled: Bool = AppSettings.calendarEnabled
    @State private var calendarAuthorized: Bool = CalendarWatcher.shared.isAuthorized
    @State private var calendars: [EKCalendar] = []
    @State private var watchedIDs: Set<String> = Set(AppSettings.watchedCalendarIDs)
    @State private var calendarGroups: [String: String] = AppSettings.calendarGroups

    var body: some View {
        Form {
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
                Text("Point this at an Obsidian vault or synced folder to get multi-device access for free.")
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
                Text("Domain Vocabulary")
            } footer: {
                Text("Names, submarkets, acronyms, and jargon whisper might otherwise mishear. These bias transcription toward the right spellings.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section {
                Toggle("Title & summarize with Apple Intelligence", isOn: $summarizeEnabled)
                    .onChange(of: summarizeEnabled) { _, newValue in
                        AppSettings.summarizeEnabled = newValue
                    }
                if summarizeEnabled && !TranscriptEnricher.isAvailable {
                    Text("Requires Apple Intelligence — enable it in System Settings › Apple Intelligence & Siri.")
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
                Toggle("Global ⌥⌘R to start/stop recording", isOn: $globalHotkey)
                    .onChange(of: globalHotkey) { _, newValue in
                        AppSettings.globalHotkeyEnabled = newValue
                        HotKeyManager.shared.setEnabled(newValue)
                    }
            } header: {
                Text("Appearance")
            } footer: {
                Text("Theme follows the system by default, or lock it to Light or Dark. Show in Dock adds a Dock icon and ⌘-Tab; off keeps the app in the menu bar (the hub still shows in the Dock while open). ⌥⌘R starts or stops a recording from any app.")
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
                Text("When a recording finishes, prompt for a title and participants. You can skip it, and edit details any time in the transcript viewer. Naming participants is what makes “calls with …” search work.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                    Toggle("Ask what to capture each recording", isOn: $askScreenSource)
                        .onChange(of: askScreenSource) { _, newValue in
                            AppSettings.askScreenSourceOnRecord = newValue
                        }
                }
            } header: {
                Text("Screen Context")
            } footer: {
                Text("Periodically reads text from your frontmost window and adds meaningfully-changed content to the transcript. Screenshots are discarded immediately — only text is kept. Only the window you're actively in is seen, never a second monitor.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

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
                                        TextField("Group tag (optional)", text: groupBinding(for: calendar.calendarIdentifier))
                                            .textFieldStyle(.roundedBorder)
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
                Text("Shows your next Zoom/Teams/Meet events in Meetings. Reads only calendars synced into the macOS Calendar app. Informational only — never auto-starts recording. Give a calendar a group tag to auto-tag calls recorded from it (e.g. tag everything from your “Deals” calendar as “deals”).")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .font(CarbonFont.body(13))
        .scrollContentBackground(.hidden)
        .frame(maxWidth: 660)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(Carbon.background)
        .onAppear {
            if calendarEnabled && calendarAuthorized { calendars = CalendarWatcher.shared.calendars() }
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

    /// Two-way binding for a calendar's group tag, persisted to AppSettings.
    private func groupBinding(for id: String) -> Binding<String> {
        Binding(
            get: { calendarGroups[id] ?? "" },
            set: { value in
                let tag = value.trimmingCharacters(in: .whitespaces).lowercased()
                if tag.isEmpty { calendarGroups[id] = nil } else { calendarGroups[id] = tag }
                AppSettings.calendarGroups = calendarGroups
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
            AppSettings.outputFolder = url
            outputPath = url.path
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
