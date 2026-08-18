import AppKit
import ScriptaCore
import SubstrateKit
import SwiftUI
import UniformTypeIdentifiers

// MARK: - The Library
//
// A SIBLING OF ASK, not a second dialect. The same outer gate on the engine's own lifecycle and the
// same four cards for it, the same marker column, the same `EngineNote` line type for a condition
// the engine reported, the same rule that a healthy state is quiet. What is different is the
// direction: Ask reads a scope, this one writes one.
//
// EVERYTHING IT DOES, IT FINISHES. Bring a document in and it is extracted, added to a vault
// Scripta owns, composed and registered — queryable in Ask before this screen says it is done.
// Nothing here tells the operator to go and run a command.
//
// AND EVERYTHING IT DOES, IT SHOWS. Every step names the command it ran and reproduces what the
// process said, on success as well as on failure — `compose` exits 0 and warns on
// stderr when the SOURCE transcripts are already in a cloud-synced tree, which is the single most
// important sentence this surface can carry and would be invisible under "show errors only".

struct SubstrateLibraryView: View {
    @ObservedObject var model: SubstrateLibraryModel
    @ObservedObject private var engine = SubstrateEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            lensPicker
            switch model.lens {
            case .add, .status: column
            // WHOLE, WITH ITS OWN GATE, rather than reaching past it for the console inside. The
            // two gates are the same four cards and the duplication is the point: each surface
            // keeps the reasoning it documents about waiting for the engine, so neither inherits
            // the other's by accident.
            case .vault: VaultBrowseView(model: VaultBrowseModel.shared)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.background)
        .task { engine.startIfIdle() }
    }

    private var lensPicker: some View {
        Picker("", selection: $model.lens) {
            ForEach(SubstrateLibraryModel.Lens.allCases) { Text($0.title).tag($0) }
        }
        .pickerStyle(.segmented)
        .labelsHidden()
        .fixedSize()
        .padding(.horizontal, Metrics.pageGutter)
        .padding(.top, Gap.s12)
    }

    /// THE SAME OUTER GATE AS ASK, and for a sharper reason here. Ask needs the engine because a
    /// query is a request to it; this needs it because the CLI it shells out to must come from the
    /// SAME BUILD that is answering — an index written by the pinned deployment and read by the
    /// developer shim is the `schemaMismatch` refusal, arriving as a consequence of a choice made
    /// on this screen. `SubstrateEngine.Source` carries both halves so they cannot come apart, and
    /// waiting for one to be serving is how we know which.
    @ViewBuilder private var column: some View {
        switch engine.lifecycle {
        case .idle, .starting:
            VaultEngineStarting(lifecycle: engine.lifecycle)
        case .notInstalled, .portBusy, .failed:
            VaultEngineRefusal(lifecycle: engine.lifecycle, restart: engine.restart)
        case .serving(let source, _):
            LibraryConsole(model: model, source: source)
        }
    }
}

private struct LibraryConsole: View {
    @ObservedObject var model: SubstrateLibraryModel
    let source: SubstrateEngine.Source

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Gap.s16) {
                switch model.job {
                case .running(let running):
                    LibraryRunStrip(running: running, cancel: model.cancel)
                case .finished(let report):
                    LibraryReportCard(model: model, report: report)
                case .idle:
                    EmptyView()
                }
                // THE JOB STRIP ABOVE IS ON BOTH, because both lenses start jobs — Add composes
                // what it just wrote, and Status has "Compose and register" and "Refresh now".
                if model.lens == .add {
                    LibraryAddRail(model: model)
                } else {
                    LibraryTranscriptRail(model: model)
                    LibraryScopeRail()
                    LibraryRefreshRail()
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .frame(maxWidth: .infinity)
            .padding(Metrics.pageGutter)
        }
        .task { await model.activate() }
        .onChange(of: source.label) { _, _ in Task { await model.askSurface() } }
    }
}

// MARK: - Bringing a document in

/// WHAT ARE YOU ADDING, THEN WHERE, THEN THE FIELDS FOR IT.
///
/// The page used to open on a document drop target with a class axis and a domains field beside it,
/// which asked the operator to answer a document's questions before establishing that a document was
/// what they had. Notes were not on this page at all — they were behind a button on the reading
/// surface, which is the last place someone goes to WRITE.
///
/// IT IS THE WHOLE PAGE NOW. Call transcripts, scopes and refresh used to sit underneath it — the
/// state of what is ALREADY here, which is a different question from adding to it — and they moved
/// to the Status lens. They were not folded into the chooser either: a chooser listing them would
/// have been a table of contents for the screen rather than a list of things you can add.
private struct LibraryAddRail: View {
    @ObservedObject var model: SubstrateLibraryModel
    @State private var kind = AddKind.document
    @State private var draft = NoteDraft()
    @State private var noteRefusal: String?

    /// The things this page can add. Recording a call is not among them — a call arrives by being
    /// recorded; UPLOADING one you already have is a different act, and is `.transcript`. Where a
    /// recorded call lands is configured under Status.
    private enum AddKind: String, CaseIterable, Identifiable {
        case document, transcript, note
        var id: String { rawValue }

        var label: String {
            switch self {
            case .document: return "A document"
            case .transcript: return "A call transcript"
            case .note: return "A note"
            }
        }

        var hint: String {
            switch self {
            case .document:
                return "A PDF, Word or Markdown file, read into passages you can ask about."
            case .transcript:
                // WHY IT IS ITS OWN KIND rather than a document with a class picked: filed with the
                // calls, and withheld from answers by default the same way they are.
                return "A recording from somewhere else. Filed with your calls and kept out of "
                     + "answers by default, like they are."
            case .note:
                return "Something you write yourself."
            }
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s12) {
            LibrarySectionHeader(title: "Add", note: nil)
            kindField
            switch kind {
            case .document: fileFields(tier: .reference)
            case .transcript: fileFields(tier: .transcript)
            case .note: noteFields
            }
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Ink.layer)
        .alert("This note could not be written", isPresented: .init(
            get: { noteRefusal != nil }, set: { if !$0 { noteRefusal = nil } })) {
            Button("OK", role: .cancel) { noteRefusal = nil }
        } message: {
            Text(noteRefusal ?? "")
        }
    }

    private var kindField: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text("What are you adding?").typeface(Register.micro, Ink.textSecondary)
            Picker("", selection: $kind) {
                ForEach(AddKind.allCases) { Text($0.label).tag($0) }
            }
            .labelsHidden()
            .pickerStyle(.radioGroup)
            Text(kind.hint).proseText(Register.proseSm, Ink.textHelper)
        }
    }

    // MARK: - A file (a document, or a transcript from somewhere else)

    @ViewBuilder private func fileFields(tier: SubstrateLibrary.PromotionTier) -> some View {
        Text(destinationSentence(tier)).proseText(Register.proseSm, Ink.textHelper)
            .frame(maxWidth: Metrics.formMaxWidth, alignment: .leading)
        LibraryDropTarget(model: model)
            .frame(maxWidth: Metrics.formMaxWidth, alignment: .leading)
        switch model.surface {
        case .unasked, .asking:
            LibraryProbing()
        case .noCLI(let engine):
            LibraryNote(id: "no-cli", marker: "no CLI", tone: Ink.danger,
                        text: "The engine that is running has no `substrate` command beside it, so "
                            + "there is nothing to extract with. Asking still works.")
        case .known(let surface):
            // A TRANSCRIPT ASKS NOTHING ELSE. Its class is decided by what it is, so the axis that
            // exists to stop a document being mislabelled has no question to put — offering it
            // would let someone file a conversation as a published reference.
            if tier == .transcript {
                LibraryDomainsField(model: model)
                    .frame(maxWidth: Metrics.formMaxWidth, alignment: .leading)
            } else {
                LibraryReaders(model: model, surface: surface)
                    .frame(maxWidth: Metrics.formMaxWidth, alignment: .leading)
            }
            LibraryFileAddButton(model: model, tier: tier)
        }
    }

    private func destinationSentence(_ tier: SubstrateLibrary.PromotionTier) -> String {
        let here = model.workspace.isEmpty ? "this workspace" : model.workspace
        switch tier {
        case .reference:
            return "Goes into \(here). Other workspaces will not see it."
        case .transcript:
            return "Filed with \(here)'s calls, and withheld from answers by default the same way "
                 + "they are — ask for calls explicitly to reach it."
        }
    }

    // MARK: - A note

    @ViewBuilder private var noteFields: some View {
        NoteDraftFields(draft: $draft, workspace: model.workspace,
                        sharedVaultName: AppSettings.sharedVault?.lastPathComponent)
        // NO STANDING "you must fill this in" LINE. It sat under the button before anyone had done
        // anything, which is nagging rather than helping — the disabled button already says the
        // form is incomplete, and the title field is the only empty one it can be about.
        HStack(spacing: Gap.s8) {
            ActionButton(title: "Add note", glyph: .add, rank: .primary, action: addNote)
                .disabled(!draft.isWritable || model.isWorking)
            Spacer(minLength: Gap.s4)
        }
        .frame(maxWidth: Metrics.formMaxWidth, alignment: .leading)
    }

    /// CLEARED ONLY ON SUCCESS, like the sheet — a refused note keeps everything typed into it.
    private func addNote() {
        if let reason = model.createNote(title: draft.title, docType: draft.docType,
                                         body: draft.body, destination: draft.destination,
                                         confidence: draft.resolvedConfidence,
                                         domains: draft.resolvedDomains) {
            noteRefusal = reason
        } else {
            draft = NoteDraft()
        }
    }
}

/// Drop or pick. NO FORMAT FILTER, and that is the design rather than laziness: the set `ingest`
/// accepts is being widened, so a picker restricted to what this build was written against would
/// refuse a file the engine would have taken — with the engine's own answer never asked for. What
/// each reader NAMES is shown below instead, and anything else is handed over for the engine to
/// refuse in its own words.
private struct LibraryDropTarget: View {
    @ObservedObject var model: SubstrateLibraryModel
    @State private var over = false

    var body: some View {
        HStack(spacing: Gap.s12) {
            Icon(.document, Register.title3, over ? Ink.interactive : Ink.iconSecondary)
            VStack(alignment: .leading, spacing: Gap.s2) {
                Text(model.document?.lastPathComponent ?? "Drop a document here")
                    .typeface(Register.bodyUI, Ink.textPrimary)
                if let path = model.document?.deletingLastPathComponent().path {
                    Text(SubstrateCLI.abbreviated(path))
                        .typeface(Register.monoMicro, Ink.textHelper).lineLimit(1)
                }
            }
            Spacer(minLength: Gap.s8)
            ActionButton(title: model.document == nil ? "Choose…" : "Change…", glyph: .folder,
                         rank: .secondary, action: choose)
        }
        .padding(Metrics.cardPaddingCompact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(over ? Ink.interactiveSubtle : Ink.layerAlt, border: Ink.borderSubtle)
        .dropDestination(for: URL.self) { urls, _ in
            // A DOCUMENT ON THIS MACHINE, OR THE DROP IS REFUSED. `dropDestination(for: URL.self)`
            // takes a URL dragged out of a browser as readily as one dragged out of Finder, and
            // `urls.first` handed `https://…` — or a dropped folder — to `ingest` as a path,
            // spending a subprocess to be told there is no such file. That is the one refusal on
            // this screen the engine cannot make well, because the argument never named a document.
            guard let file = urls.first(where: isDocument) else { return false }
            model.stage(file)
            return true
        } isTargeted: { over = $0 }
    }

    /// An existing regular file. Directories are excluded too — `ingest` takes one document — and a
    /// file this app cannot stat is one the subprocess cannot read either, since the CLI runs inside
    /// the same sandbox.
    private func isDocument(_ url: URL) -> Bool {
        guard url.isFileURL else { return false }
        var directory: ObjCBool = false
        let exists = FileManager.default.fileExists(atPath: url.path, isDirectory: &directory)
        return exists && !directory.boolValue
    }

    private func choose() {
        let panel = NSOpenPanel()
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        panel.allowsMultipleSelection = false
        panel.message = "Which document should go into the library?"
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { model.stage(url) }
    }
}

/// What this engine takes, in its own words. ASKED, not assumed: everything below comes from
/// `substrate formats` and `ingest --help` at the point of use, so the fourteen formats the engine
/// grew while this screen was being written appear here without this file changing.
private struct LibraryReaders: View {
    @ObservedObject var model: SubstrateLibraryModel
    let surface: SubstrateCLI.IngestSurface

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s8) {
            if surface.formats.isEmpty {
                LibraryNote(id: "no-formats", marker: "unstated", tone: Ink.stale,
                            text: "This engine did not enumerate its formats, so Scripta cannot "
                                + "say in advance what it takes. Nothing is guessed: the file is "
                                + "handed over and the engine answers in its own words.")
            }
            LibraryVerdictRow(model: model, surface: surface)
            LibraryClassRow(model: model, surface: surface)
            LibraryDomainsField(model: model)
            // The Add button is NOT here any more — `LibraryAddRail` owns it, because it is the only
            // caller that knows which tier the file is being added at.
        }
    }
}

/// What the engine would do with the staged file, BEFORE it is spent.
///
/// The REFUSED half of `substrate formats` is what makes this worth drawing. A `.doc` fails after a
/// conversion attempt with a sentence naming the remedy; showing that sentence up front costs
/// nothing and saves the attempt. The engine still decides — this only repeats what it already
/// published.
private struct LibraryVerdictRow: View {
    @ObservedObject var model: SubstrateLibraryModel
    let surface: SubstrateCLI.IngestSurface

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            if model.document == nil {
                LibraryAcceptedNote(surface: surface)
            } else if let refusal = model.stagedRefusal {
                LibraryNote(id: "refused", marker: "refused", tone: Ink.danger, text: refusal.reason)
                LibraryMarkdownEscape(model: model, surface: surface)
            } else if let format = model.stagedFormat {
                HStack(alignment: .firstTextBaseline, spacing: Gap.s8) {
                    EnvelopeMarkerLabel(name: "format")
                    Text(format.token).typeface(Register.monoMicro, Ink.textSecondary)
                    Spacer(minLength: Gap.s4)
                }
                if !format.note.isEmpty {
                    Text(format.note).proseText(Register.proseSm, Ink.textHelper)
                        .padding(.leading, EnvelopeMarker.indent)
                }
            } else {
                LibraryNote(id: "unknown", marker: "unknown", tone: Ink.warning,
                            text: "This engine's format table does not name this extension. It "
                                + "will be handed over anyway — the engine refuses in a sentence "
                                + "you can act on, and guessing on its behalf would be worse.")
                LibraryMarkdownEscape(model: model, surface: surface)
            }
        }
    }
}

/// Every extension the engine named, so the answer to "what can I put in here" is on screen rather
/// than discovered by dropping things.
private struct LibraryAcceptedNote: View {
    let surface: SubstrateCLI.IngestSurface

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Gap.s8) {
            EnvelopeMarkerLabel(name: "accepts")
            Text(surface.formats.flatMap(\.extensions).joined(separator: " "))
                .typeface(Register.monoMicro, Ink.textHelper)
            Spacer(minLength: Gap.s4)
        }
    }
}

/// The engine's OWN suggested remedy, as a control. Its unknown-extension refusal ends "Use --md to
/// read it as markdown anyway" — advice the operator would otherwise have to retype as a flag they
/// cannot reach from here.
private struct LibraryMarkdownEscape: View {
    @ObservedObject var model: SubstrateLibraryModel
    let surface: SubstrateCLI.IngestSurface

    var body: some View {
        if let flag = surface.markdownFlag {
            HStack(spacing: Gap.s8) {
                Spacer().frame(width: EnvelopeMarker.column)
                Pill(text: "read it as markdown anyway (\(flag))",
                     style: model.forceMarkdown ? .selected : .neutral,
                     action: { model.forceMarkdown.toggle() })
                Spacer(minLength: Gap.s4)
            }
        }
    }
}

/// The class, and NOTHING PRESELECTED. This axis records its own worst failure: an absent
/// declaration used to default to `reference-frozen` — the value that reads as settled — so ~88% of
/// a corpus arrived claiming to be a published edition that will not change. A pre-ticked chip here
/// would be that bug with a mouse pointer in front of it.
///
/// ABSENCE IS AN OPTION AND USUALLY THE RIGHT ONE. The engine defaults every detected format but
/// PDF to absence, on the grounds that a file extension is evidence about the container and not
/// about the document, so the "leave it undeclared" chip is a real answer rather than a way out.
private struct LibraryClassRow: View {
    @ObservedObject var model: SubstrateLibraryModel
    let surface: SubstrateCLI.IngestSurface

    /// PLAIN LANGUAGE FOR THE ENGINE'S WORDS, keyed by them rather than replacing them. The chip
    /// keeps the engine's token because that token is written into the document's frontmatter and
    /// the operator will meet it again in the corpus; relabelling the control would leave them
    /// looking up a word this screen invented.
    ///
    /// A DICTIONARY WITH A FALLBACK, not a fixed list, so the "asked, not assumed" property of this
    /// screen survives: the classes come from `substrate formats` at the point of use, and one this
    /// build has never heard of still gets a chip — just without a gloss.
    private static let glosses = [
        "reference-frozen": "Published and finished — a book, a paper, a report that will not be "
            + "revised. Passages are quoted as settled.",
        "reference-versioned": "Something that gets revised — a spec, a standard, living docs. The "
            + "version matters, and a later one supersedes this.",
        "conversation": "A record of people talking. Withheld from answers by default, because "
            + "what someone said mid-discussion is not a conclusion.",
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text("What kind of document is it?").typeface(Register.micro, Ink.textSecondary)
            HStack(spacing: Gap.s6) {
                EnvelopeMarkerLabel(name: "class")
                if !model.classRequired {
                    Pill(text: "undeclared",
                         style: model.documentClass == nil ? .selected : .neutral,
                         action: { model.documentClass = nil })
                }
                ForEach(surface.docClasses, id: \.self) { name in
                    Pill(text: name, style: model.documentClass == name ? .selected : .neutral,
                         action: { model.documentClass = name })
                }
                Spacer(minLength: Gap.s4)
            }
            Text(sentence)
                .proseText(Register.proseSm, Ink.textHelper)
                .padding(.leading, EnvelopeMarker.indent)
        }
    }

    /// WHAT THE CURRENT CHOICE MEANS, not why the control is shaped this way. The rationale it
    /// replaced — that an absent class used to default to `reference-frozen` and so ~88% of a corpus
    /// claimed to be a published edition — is a real and load-bearing fact, but it is a fact about
    /// this codebase's history. It belongs in the comment above, where it now lives, rather than in
    /// front of someone trying to file a PDF.
    private var sentence: String {
        if let chosen = model.documentClass {
            return Self.glosses[chosen]
                ?? "This engine names a class this build has no description for. It is passed "
                 + "through as you picked it."
        }
        if model.classRequired {
            return "This format needs you to choose. Nothing is preselected on purpose — the wrong "
                 + "guess here makes a draft look like a published source."
        }
        return "Leaving it undeclared is the normal answer, and the engine's own default. A file "
             + "extension says what the container is, not what the document is. It stays fully "
             + "searchable either way."
    }
}

private struct LibraryDomainsField: View {
    @ObservedObject var model: SubstrateLibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text("What subjects is it about? — optional")
                .typeface(Register.micro, Ink.textSecondary)
            InputField(prompt: "e.g. databases, hiring", text: $model.domains, glyph: .tag)
            // WHAT IT BUYS THEM, then the one mechanical fact they can act on. The paragraph this
            // replaced explained that unslugifiable domains are dropped silently by the engine's
            // parser and that Scripta pre-shapes them to avoid it — true, and a thing this code
            // does, not a thing the operator does.
            Text("Used to narrow answers when you ask across several workspaces. Comma-separated. "
                 + "Scripta files everything here under `\(SubstrateLibrary.baseDomain)` as well, "
                 + "so a document is never left with no subject at all.")
                .proseText(Register.proseSm, Ink.textHelper)
        }
    }
}

private struct LibraryFileAddButton: View {
    @ObservedObject var model: SubstrateLibraryModel
    let tier: SubstrateLibrary.PromotionTier

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            HStack(spacing: Gap.s8) {
                ActionButton(title: tier == .transcript ? "Add transcript" : "Add document",
                             glyph: .add, rank: .primary,
                             action: { model.addDocument(tier: tier) })
                    .disabled(!ready)
                Spacer(minLength: Gap.s4)
            }
            // WHY IT IS OFF, WHENEVER IT IS OFF. A disabled primary button with no explanation is
            // the control this codebase keeps writing cards to apologise for — and the two reasons
            // it disables are both fixable by the operator in the same breath.
            if let blocked {
                Text(blocked).proseText(Register.proseSm, Ink.textHelper)
            }
        }
        .padding(.top, Gap.s2)
    }

    private var blocked: String? {
        if model.isWorking { return "Waiting for the job above to finish." }
        if model.document == nil { return "Choose or drop a document first." }
        if tier != .transcript, model.classRequired, model.documentClass == nil {
            return "This format needs a kind — pick one above."
        }
        return nil
    }

    /// Enabled even for a file the engine's table refuses, and that is deliberate. The table is a
    /// published list, not the gate; the gate is `spec_for`, and a client that pre-refused would be
    /// substituting its own reading of a table for the engine's reading of the file. What the
    /// refusal note above buys is that the operator knows before they press it.
    private var ready: Bool {
        guard !model.isWorking, model.document != nil else { return false }
        return tier == .transcript || !model.classRequired || model.documentClass != nil
    }
}

// MARK: - Transcripts

private struct LibraryTranscriptRail: View {
    @ObservedObject var model: SubstrateLibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s10) {
            LibrarySectionHeader(
                title: "Call transcripts",
                note: "One scope per workspace, and the scope name is the privacy wall (Doc 3 §4). "
                    + "The engine writes the vault as `class: conversation`, which default "
                    + "retrieval withholds — a passage from mid-call can be reasoning the speaker "
                    + "abandoned ten minutes later, in the same register as the conclusion.")
            LibraryPathRow(marker: "from", path: AppSettings.outputFolder, choose: nil)
            // NO DESTINATION IS SHOWN FOR A WORKSPACE THAT CANNOT HAVE ONE. The derived path is
            // `transcripts/<slug>`, and a name with no ASCII letter or digit has no slug — so what
            // this row used to draw was a directory the export will never write to, for a workspace
            // the engine refuses. Naming the refusal is the only thing here that is true.
            if SubstrateLibrary.slug(named).isEmpty {
                LibraryNote(id: "unnameable", marker: "no destination", tone: Ink.warning,
                            text: "A vault directory and a scope name are ASCII letters and digits, "
                                + "and this workspace's name reduces to neither — so there is "
                                + "nowhere for its transcripts to go and nothing to register them "
                                + "under. The field below is where to fix it.")
            } else if let destination = model.transcriptVault {
                LibraryPathRow(marker: "into", path: destination, choose: chooseVault)
            }
            LibraryNote(
                id: "local", marker: "the source", tone: Ink.textHelper,
                text: "This one vault is where every call in this workspace is written — it is the "
                    + "source. Everything else the workspace answers from is pulled in for context "
                    + "through the vaults it inherits, and never written to.")
            LibraryUntaggedRow(model: model)
            LibraryWorkspaceRow(model: model)
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Ink.layer)
    }

    private var named: String { model.workspace.trimmingCharacters(in: .whitespacesAndNewlines) }

    private func chooseVault() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.canCreateDirectories = true
        panel.message = "Where should the exported transcript vault live? It must be local and "
            + "not inside iCloud, OneDrive, Dropbox or Box."
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { model.chooseVault(url) }
    }
}

/// The engine's refusal, with the fix attached.
///
/// `export_workspace` aborts the whole export over one untagged transcript and its message ends
/// "add `group: "<workspace>"` to each transcript's frontmatter". That is the right refusal — an
/// untagged call belongs to no workspace, and both guessing and dropping it are worse. But the only
/// way to act on it was to hand-edit YAML, so one missing field could block the corpus forever while
/// the app that owns the folder grant offered nothing.
private struct LibraryUntaggedRow: View {
    @ObservedObject var model: SubstrateLibraryModel

    var body: some View {
        Group {
            if !model.untagged.isEmpty {
                VStack(alignment: .leading, spacing: Gap.s6) {
                    // REWRITTEN with the exporter it named. There is no export to block: these
                    // transcripts sit in the output folder rather than in a vault, so they are in
                    // no scope and nothing can retrieve them — which is the real cost and the one
                    // the sentence now states.
                    LibraryNote(
                        id: "untagged", marker: "in no vault", tone: Ink.warning,
                        text: "\(model.untagged.count) transcript\(model.untagged.count == 1 ? "" : "s") "
                            + "\(model.untagged.count == 1 ? "is" : "are") in the output folder "
                            + "rather than in a workspace vault, so \(model.untagged.count == 1 ? "it is" : "they are") "
                            + "in no scope and Ask cannot reach "
                            + "\(model.untagged.count == 1 ? "it" : "them"). Filing moves the file "
                            + "into that workspace's vault. Which workspace is the operator's call, "
                            + "not the app's — these are filed under the name in the field below.")
                    ForEach(model.untagged) { transcript in
                        HStack(spacing: Gap.s8) {
                            Text(transcript.date).typeface(Register.micro, Ink.textHelper)
                            Text(transcript.title).proseText(Register.proseSm, Ink.textSecondary)
                                .lineLimit(1)
                            // What this app recorded for it before §7, when it recorded one. Shown
                            // rather than acted on: it is a suggestion the operator confirms by
                            // typing that name, which keeps "assigning is the operator's call" true.
                            if let declared = transcript.declaredWorkspace, !declared.isEmpty {
                                Text(verbatim: "was \(declared)")
                                    .typeface(Register.monoMicro, Ink.textHelper)
                            }
                            Spacer(minLength: Gap.s8)
                            ActionButton(title: named.isEmpty ? "Name a workspace first"
                                                             : "File under \(named)",
                                         glyph: .people, rank: .secondary) {
                                model.assign(transcript)
                            }
                            .disabled(named.isEmpty || model.isWorking)
                        }
                    }
                    if let failure = model.repairFailure {
                        LibraryNote(id: "repair-failed", marker: "not repaired", tone: Ink.danger,
                                    text: failure)
                    }
                }
            }
        }
        .task { model.refreshUntagged() }
    }

    private var named: String { model.workspace.trimmingCharacters(in: .whitespacesAndNewlines) }
}

private struct LibraryWorkspaceRow: View {
    @ObservedObject var model: SubstrateLibraryModel

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            HStack(spacing: Gap.s8) {
                InputField(prompt: "Workspace name", text: $model.workspace, glyph: .people)
                ActionButton(title: "Compose and register", glyph: .arrowRight, rank: .primary,
                             action: model.composeWorkspace)
                    .disabled(model.isWorking || SubstrateLibrary.slug(named).isEmpty)
            }
            if named.isEmpty {
                Text("The ungrouped workspace has no name, and the scope name is the wall between "
                     + "workspaces — so this one needs a name before it can have a scope.")
                    .proseText(Register.proseSm, Ink.textHelper)
            } else if SubstrateLibrary.slug(named).isEmpty {
                // NAMED AND UNNAMEABLE ARE DIFFERENT STATES. "研究", "———" and an emoji are all
                // non-empty and all slugify to nothing, so the sentence above would have read as
                // wrong to someone looking at a name they had just typed. The engine refuses this
                // value in the same words, and so does the vault layout.
                Text("\"\(named)\" reduces to nothing once slugified, and both the vault directory "
                     + "and the scope name are built from that slug — the engine's own refusal is "
                     + "\"slugifies to nothing; give it a name\". Add at least one ASCII letter or "
                     + "digit; the calls themselves are untouched either way.")
                    .proseText(Register.proseSm, Ink.warning)
            }
            // REWRITTEN with the exporter. This described a selection step — "the engine selects on
            // each transcript's own workspace, the rest are left in place" — that no longer happens
            // anywhere: each workspace has its own vault directory, so there is nothing to select
            // FROM. Describing a privacy filter that has been replaced by a partition would be the
            // more flattering sentence and the less true one.
            Text("\(named.isEmpty ? "This workspace" : named)'s calls already live in their own "
                 + "vault — recording puts them there. This composes that vault into a scope so "
                 + "Ask and the Vault tab can read it, and names the scope when it is done.")
                .proseText(Register.proseSm, Ink.textHelper)
        }
    }

    private var named: String { model.workspace.trimmingCharacters(in: .whitespacesAndNewlines) }
}

// MARK: - What exists, and whether it is being maintained

/// The scopes, drawn from the roster the engine hands back. Every verdict on this row is
/// `refresh_state.report`'s — `outcome`, the tri-state `frozen`, and its own note — because nothing
/// else knows how to read a carried freeze that the latest pass neither confirmed nor cleared.
private struct LibraryScopeRail: View {
    @ObservedObject private var scopes = SubstrateScopes.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s10) {
            LibrarySectionHeader(title: "Scopes", note: nil)
            switch scopes.roster {
            case .unasked, .listing:
                HStack(spacing: Gap.s8) {
                    Spinner()
                    Text("Asking the engine which scopes it has…")
                        .proseText(Register.proseSm, Ink.textSecondary)
                    Spacer(minLength: Gap.s8)
                }
            case .refused(let refusal):
                ForEach(refusal.notes) { EngineNoteRow(note: $0) }
            case .listed(let rows):
                ForEach(rows, id: \.scope) { LibraryScopeLine(row: $0) }
            }
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Ink.layer)
        .task { await scopes.activate() }
    }
}

private struct LibraryScopeLine: View {
    let row: WireScopeRow
    /// FOLDED BY DEFAULT, EVEN WHEN BROKEN. The engine's refusal is long by design — it explains a
    /// partly-rewritten index and what to run — and drawing it inline put two identical
    /// six-line paragraphs on a screen someone opened to add a note. A broken scope still SAYS it is
    /// broken on its one line; the paragraph is one click away for whoever is actually fixing it.
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            HStack(spacing: Gap.s8) {
                Pill(text: row.scope, style: VaultScopeHealth.style(row, selected: false))
                Text(row.refresh.outcome ?? "unrecorded")
                    .typeface(Register.monoMicro, tone)
                if hasDetail {
                    Button(expanded ? "Hide detail" : "Why") { expanded.toggle() }
                        .buttonStyle(.link)
                        .typeface(Register.monoMicro, Ink.textHelper)
                }
                Spacer(minLength: Gap.s4)
                Text(SubstrateCLI.abbreviated(row.vault))
                    .typeface(Register.monoMicro, Ink.textHelper).lineLimit(1)
            }
            if expanded {
                // The engine's own sentence about this scope's maintenance, not a paraphrase.
                if let note = row.refresh.note {
                    Text(note).proseText(Register.proseSm, Ink.textHelper)
                        .padding(.leading, EnvelopeMarker.indent)
                }
                if let health = VaultScopeHealth.note(for: row) { VaultScopeNote(note: health) }
            }
        }
    }

    private var hasDetail: Bool {
        row.refresh.note != nil || VaultScopeHealth.note(for: row) != nil
    }

    /// Tri-state, drawn as three things. `noBasis` is ABSENT EVIDENCE and must not take the colour
    /// of either verdict — a scope nobody has recorded is not a healthy one.
    private var tone: Tone {
        switch row.refresh.frozen {
        case .frozen: return Ink.danger
        case .current: return Ink.textSecondary
        case .noBasis: return Ink.stale
        }
    }
}

// MARK: - Refresh

/// Doc 3 §2 moves index refresh in-app: on launch, and on a timer while Scripta is open. This is
/// what says so out loud, because a maintenance job nobody can see is the state the whole refresh
/// record exists to end.
private struct LibraryRefreshRail: View {
    @ObservedObject private var refresh = SubstrateRefresh.shared

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s8) {
            HStack(spacing: Gap.s8) {
                EnvelopeMarkerLabel(name: "refresh")
                content
                Spacer(minLength: Gap.s4)
                ActionButton(title: "Refresh now", glyph: .refresh, rank: .tertiary,
                             action: refresh.refreshNow)
                    .disabled(isRunning)
            }
            if case .finished(_, let run) = refresh.state, !run.succeeded {
                LibraryNote(
                    id: "refresh-failed", marker: "refused", tone: Ink.warning,
                    text: "The last pass exited \(run.status.map(String.init) ?? "on a signal"). "
                        + "The agent writes its reasons to its own log, and it records an outcome "
                        + "against every scope on every path — the rows above are that record. A "
                        + "refusal is not retried here: the one it refuses over is an engine it "
                        + "could not verify, and retrying that is the failure it exists to stop.")
                Text(SubstrateCLI.abbreviated(SubstrateRefresh.logPath.path))
                    .typeface(Register.monoMicro, Ink.textHelper)
                    .textSelection(.enabled)
                    .padding(.leading, EnvelopeMarker.indent)
            }
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Ink.layer)
    }

    private var isRunning: Bool {
        if case .running = refresh.state { return true }
        return false
    }

    @ViewBuilder private var content: some View {
        switch refresh.state {
        case .idle:
            Text("on launch, then every 15 minutes while Scripta is open")
                .proseText(Register.proseSm, Ink.textSecondary)
        case .unavailable(let engine):
            Text("no refresh agent beside \(engine) — nothing is maintaining these indexes")
                .proseText(Register.proseSm, Ink.warning)
        case .running(let since):
            HStack(spacing: Gap.s8) {
                Spinner()
                Text("refreshing").proseText(Register.proseSm, Ink.textSecondary)
                VaultElapsed(started: since)
            }
        case .finished(let at, let run):
            Text(run.succeeded ? "last pass finished \(Self.stamp(at))"
                               : "last pass refused at \(Self.stamp(at))")
                .proseText(Register.proseSm, run.succeeded ? Ink.textSecondary : Ink.warning)
        }
    }

    private static func stamp(_ date: Date) -> String {
        date.formatted(date: .omitted, time: .shortened)
    }
}

// MARK: - A job, while it runs and after it stops

private struct LibraryRunStrip: View {
    let running: SubstrateLibraryModel.Running
    let cancel: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s8) {
            HStack(spacing: Gap.s8) {
                Spinner()
                Text(running.title).typeface(Register.uiEmphasis, Ink.textPrimary)
                Text(running.step).typeface(Register.monoMicro, Ink.textHelper)
                VaultElapsed(started: running.started)
                Spacer(minLength: Gap.s8)
                ActionButton(title: "Stop", rank: .tertiary, action: cancel)
            }
            // The counter is not decoration. A layout model loads before the first page is read —
            // a one-page PDF measured 36 seconds on this machine — so a long wait has to look like
            // a long wait rather than a hang.
            ForEach(running.done) { LibraryStepRow(step: $0) }
        }
        .padding(Metrics.cardPaddingCompact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Ink.layer)
    }
}

private struct LibraryReportCard: View {
    @ObservedObject var model: SubstrateLibraryModel
    let report: SubstrateLibraryModel.Report

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s8) {
            HStack(spacing: Gap.s8) {
                Text(report.title).typeface(Register.uiEmphasis, Ink.textPrimary)
                Spacer(minLength: Gap.s8)
                ActionButton(title: "Done", rank: .tertiary, action: model.dismiss)
            }
            ForEach(report.steps) { LibraryStepRow(step: $0) }
            if let scope = report.scope {
                LibraryNote(id: "registered", marker: "registered", tone: Ink.textHelper,
                            text: "`\(scope)` is composed and registered, so it is answering in "
                                + "Ask now. That is the whole point of composing here rather than "
                                + "leaving it: a note that exists and cannot be found is the "
                                + "silent-absence state.")
            }
            if let orphaned = report.orphaned { LibraryOrphanRow(model: model, source: orphaned) }
        }
        .padding(Metrics.cardPaddingCompact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Ink.layer)
    }
}

/// THE ONE STATE THIS RAIL CAN LEAVE BEHIND, and it is named rather than tidied away. The document
/// passed extraction, entered the vault, and the compose then refused — so it is on disk, it is not
/// in any index, and until it is resolved every later compose of this scope will refuse over the
/// same note. Rolling it back automatically would hide both facts.
private struct LibraryOrphanRow: View {
    @ObservedObject var model: SubstrateLibraryModel
    let source: URL

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s6) {
            EngineNoteRow(note: EngineNote(
                id: "orphan", marker: "not indexed", tone: Ink.danger,
                text: "The document is in the library vault and the compose refused, so it exists "
                    + "and cannot be found — and the whole scope is refused while it is there, "
                    + "because a partially composed scope is a silently-wrong retrieval set. The "
                    + "engine's reason is above."))
            Text(SubstrateCLI.abbreviated(source.path))
                .typeface(Register.monoMicro, Ink.textHelper)
                .textSelection(.enabled)
                .padding(.leading, EnvelopeMarker.indent)
            HStack(spacing: Gap.s8) {
                Spacer().frame(width: EnvelopeMarker.column)
                ActionButton(title: "Take it back out and recompose", glyph: .trash,
                             rank: .destructive) { model.remove(source: source) }
                    .disabled(model.isWorking)
                Spacer(minLength: Gap.s4)
            }
        }
    }
}

/// One step: what it was, whether it happened, the command, and everything the process said.
///
/// The transcript is shown for a step that SUCCEEDED as well as one that failed, and that is not
/// verbosity. `compose` exits 0 and writes a warning to stderr when the source
/// transcripts are already inside a cloud-synced tree — the export is local and the originals are
/// not, so Doc 3 §4's condition is half met. Under "errors only" that sentence never appears.
private struct LibraryStepRow: View {
    let step: SubstrateLibraryModel.Step
    @State private var expanded = false

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            HStack(alignment: .firstTextBaseline, spacing: Gap.s8) {
                EnvelopeMarkerLabel(name: marker, tone: tone)
                Text(step.title).proseText(Register.proseSm, Ink.textSecondary)
                Spacer(minLength: Gap.s4)
                if step.run != nil || step.appFailure != nil {
                    Pill(text: expanded ? "hide" : "detail", style: .neutral,
                         action: { expanded.toggle() })
                }
            }
            if let failure = step.appFailure {
                Text(failure).proseText(Register.proseSm, Ink.danger)
                    .padding(.leading, EnvelopeMarker.indent)
            }
            if expanded, let run = step.run {
                VaultVerbatim(text: run.line)
                if !run.transcript.isEmpty { VaultVerbatim(text: run.transcript) }
            } else if step.failed, let run = step.run, !run.transcript.isEmpty {
                // A failure never needs to be opened to be read. The engine writes an actionable
                // sentence — `FATAL (class policy): reference-frozen: missing required field(s)
                // ['title']` — and hiding it behind a disclosure would make the operator hunt for
                // the one thing they need.
                VaultVerbatim(text: run.transcript)
            }
        }
    }

    private var marker: String {
        if step.skipped { return "not run" }
        if step.failed { return "refused" }
        return "done"
    }

    private var tone: Tone {
        if step.skipped { return Ink.stale }
        return step.failed ? Ink.danger : Ink.textHelper
    }
}

// MARK: - Small parts

private struct LibrarySectionHeader: View {
    let title: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text(title).typeface(Register.title3, Ink.textPrimary)
            if let note { Text(note).proseText(Register.proseSm, Ink.textHelper) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct LibraryPathRow: View {
    let marker: String
    let path: URL
    let choose: (() -> Void)?

    var body: some View {
        HStack(spacing: Gap.s8) {
            EnvelopeMarkerLabel(name: marker)
            Text(SubstrateCLI.abbreviated(path.path))
                .typeface(Register.monoMicro, Ink.textSecondary)
                .textSelection(.enabled)
                .lineLimit(1)
            Spacer(minLength: Gap.s4)
            if let choose {
                ActionButton(title: "Choose…", rank: .tertiary, action: choose)
            }
        }
    }
}

private struct LibraryNote: View {
    let id: String
    let marker: String
    let tone: Tone
    let text: String

    var body: some View {
        EngineNoteRow(note: EngineNote(id: id, marker: marker, tone: tone, text: text))
    }
}

private struct LibraryProbing: View {
    var body: some View {
        HStack(spacing: Gap.s8) {
            Spinner()
            Text("Asking the engine which documents it takes…")
                .proseText(Register.proseSm, Ink.textSecondary)
            Spacer(minLength: Gap.s8)
        }
    }
}
