import SwiftUI
import ScriptaCore
import AppKit

/// Reader for one transcript, used inside the hub's Calls pane. (The old standalone viewer window
/// was retired when the hub took over browsing.)
///
/// The first view on "Record & Register", and the one where the three registers land on a single
/// line: a MONO timestamp (machine-measured), a UI speaker name (chrome), and the words themselves
/// in PROSE (IBM Plex Sans Text, capped at `Metrics.proseMaxWidth`). That is rule 1 stated as a
/// layout rather than as a doc — and the row itself is `SpokenLine`, a system component now, so
/// this view supplies the blocks and the cast and no longer owns the layout or its gutters.
struct TranscriptDetail: View {
    let meta: TranscriptMeta
    /// When set, the reader scrolls to (and briefly flashes) the spoken line at/under this time —
    /// so clicking a search hit or an Ask citation lands on the moment, not the top of the call.
    var scrollToMs: Int? = nil
    let onEdited: () -> Void
    var onDeleted: () -> Void = {}
    @State private var showingEditor = false
    @State private var confirmingDelete = false
    @State private var exportError: String?
    @State private var addingTerm = false
    @State private var termCanonical = ""
    @State private var termAliases = ""
    @State private var termGloss = ""
    @State private var flashIndex: Int?
    // Parsed once per transcript (off the main thread) and cached — re-reading + re-parsing the
    // whole file inside `body` on every invalidation was a large part of the long-transcript lag.
    @State private var blocks: [TranscriptBlock] = []
    /// Resolved with `blocks`, never derived inside `body`: assigning ramp slots is a pass over
    /// every block, and doing it per invalidation would put an O(n) walk on the render path.
    @State private var cast = SpeakerCast([])
    /// A clicked participant's entity page (M21).
    @State private var entitySheetTarget: EntitySheetTarget?

    var body: some View {
        // In-pane action row (not a native `.toolbar`): the hub draws its own in-window title bar
        // and suppresses the system titlebar, so a native toolbar here would hoist these buttons
        // into that suppressed bar and break the top-bar layout only on this pane.
        VStack(spacing: 0) {
            actionBar
            reader
        }
        .alert("Add vocabulary term", isPresented: $addingTerm) {
            TextField("Term (e.g. TIM)", text: $termCanonical)
            TextField("Aliases, comma-separated", text: $termAliases)
            TextField("Meaning (optional)", text: $termGloss)
            Button("Add") {
                let aliases = termAliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                EntityRegistry.shared.addTerm(canonical: termCanonical, aliases: aliases,
                                              gloss: termGloss.isEmpty ? nil : termGloss,
                                              group: AppModel.shared.activeGroup)
                if let store = IndexStore.shared { IndexBuilder.syncTerms(store: store) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Feeds transcription biasing and search — the term and its aliases match each other everywhere.")
        }
        .sheet(isPresented: $showingEditor) {
            TranscriptDetailsEditor(url: meta.url, title: meta.title, participants: meta.participants, tags: meta.tags) { saved in
                showingEditor = false
                if saved {
                    if let store = IndexStore.shared { IndexBuilder.index(meta.url, into: store) }
                    onEdited()
                }
            }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .confirmationDialog("Delete “\(meta.displayTitle)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete transcript", role: .destructive, action: performDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the transcript file. This can't be undone.")
        }
        .sheet(item: $entitySheetTarget) { target in entitySheet(target) }
    }

    /// Split out of `body` for the reason `KnowledgeView.knowledgeContent` documents: the solver's
    /// cost is a THRESHOLD in modifier DEPTH, not a per-modifier rate, so re-basing on a shallow
    /// opaque type buys back the whole chain above it. Five presentations sit on `body` and nothing
    /// else does.
    ///
    /// TWO seams, not one, and the second was measured rather than assumed: with the scroll stack
    /// inline here this getter alone cost 102-114ms across four clean builds — under the limit
    /// twice and over it twice, which is a threshold you are sitting on rather than one you have
    /// cleared. Re-basing the `LazyVStack` as `transcriptStack` dropped this one under 15ms and
    /// left 28 there, which is the whole chain accounted for and nothing near the limit.
    private var reader: some View {
        ScrollViewReader { proxy in
            ScrollView { transcriptStack }
                .task(id: meta.url) { await loadBlocks(); scrollToTarget(proxy) }
                .onChange(of: scrollToMs) { _, _ in scrollToTarget(proxy) }
        }
    }

    private var transcriptStack: some View {
        // Lazy: only on-screen blocks are realized/laid out. A non-lazy VStack built every block of
        // an hour-long call up front (and re-laid them on each scroll tick).
        LazyVStack(alignment: .leading, spacing: Gap.s8) {
            header
            Hairline()
            ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                BlockView(block: block, cast: cast, highlighted: offset == flashIndex).id(offset)
            }
            RelatedItemsPanel(query: relatedQuery, excludePath: meta.url.path, group: meta.group)
        }
        .padding(Metrics.pageGutter)
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
    }

    /// Title + topics as the query: cheap, always-available, and exactly the holistic-concept
    /// surface the index's own topic-fusion search already leans on (M18) — no need to re-read/
    /// parse the body for a summary.
    ///
    /// Hoisted out of the view builder as well as named: `+` on `String` is one of the most
    /// heavily overloaded operators in the language, and the solver was paying for it inside a
    /// result builder.
    private var relatedQuery: String {
        meta.title + " " + meta.tags.joined(separator: " ")
    }

    // Extracted (not inline in the modifier chain above): a very similar addition to KnowledgeView
    // pushed its own already-long `body` past the type checker's timeout — isolating the
    // construction here keeps this chain from risking the same thing.
    @ViewBuilder
    private func entitySheet(_ target: EntitySheetTarget) -> some View {
        EntityDetailView(entityID: target.id, group: meta.group, fallbackName: target.fallbackName) {
            entitySheetTarget = nil
        } onOpenNote: { path in
            // Same group re-check KnowledgeView's own onOpenNote does (crosscheck) — this sheet
            // has no in-app note surface to open into, but "no richer surface" isn't a reason to
            // skip the check, just a reason the resulting action is "open externally" instead of
            // "present a sheet."
            if let note = NoteStore.verified(atPath: path, group: meta.group) {
                NSWorkspace.shared.open(note.url)
            }
        } onOpenDoc: { path in
            if let url = DocumentImporter.verifiedOriginalURL(atPath: path, group: meta.group) {
                NSWorkspace.shared.open(url)
            }
        }
    }

    /// Reads + parses the transcript off the main thread, then swaps the cached blocks in. Runs
    /// on first appearance and whenever the selected call changes (`.task(id:)`).
    private func loadBlocks() async {
        let url = meta.url
        let parsed = await Task.detached(priority: .userInitiated) {
            TranscriptParser.parse(TranscriptStore.body(of: url))
        }.value
        cast = SpeakerCast(parsed)
        blocks = parsed
    }

    /// Scrolls to the last spoken line at/under `scrollToMs` and flashes it briefly.
    @MainActor private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let ms = scrollToMs, !blocks.isEmpty else { return }
        var target: Int?
        for (i, block) in blocks.enumerated() {
            if case let .audioLine(stamp, _, _) = block, let bms = Indexing.parseStamp(stamp), bms <= ms {
                target = i
            }
        }
        guard let target else { return }
        withAnimation { proxy.scrollTo(target, anchor: .center) }
        flashIndex = target
        Task {
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            if flashIndex == target { flashIndex = nil }
        }
    }

    private var fileName: String {
        meta.displayTitle.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.isEmpty ? "(none)" : text, forType: .string)
    }

    /// Deletes the transcript file, removes it from the index, and refreshes the call list.
    private func performDelete() {
        try? FileManager.default.removeItem(at: meta.url)
        IndexStore.shared?.remove(path: meta.url.path)
        AppModel.shared.reloadCalls()
        onDeleted()
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: Gap.s8) {
            titleRow
            metaRow
            if !meta.tags.isEmpty { tagRow }
        }
    }

    private var titleRow: some View {
        HStack(spacing: Gap.s8) {
            Text(meta.displayTitle).typeface(Register.title2, Ink.textPrimary)
            // Neutral, not the orange it used to wear. "Conference" is a CLASSIFICATION of the
            // call, and rule 3 spends colour on deviation, not on categories — and the orange in
            // question is now the first speaker slot, which is exactly the overload this system
            // exists to prevent. The word carries the fact; nothing else has to.
            if meta.isConference { Pill(text: "Conference", style: .neutral) }
        }
    }

    private var metaRow: some View {
        HStack(spacing: Gap.s12) {
            if !meta.duration.isEmpty { durationLabel }
            if !meta.participants.isEmpty { participantsRow }
        }
    }

    /// MONO: a duration is a number the machine measured. Rule 1's name/value split has no visible
    /// name here — the clock glyph is the name half — so the whole label is the value.
    private var durationLabel: some View {
        HStack(spacing: Gap.s4) {
            Icon(.time, Register.mono, Ink.iconSecondary)
            Text(meta.duration).typeface(Register.mono, Ink.textSecondary)
        }
    }

    /// Participants, individually clickable to their entity page (M21) — the gap M19 itself
    /// disclosed and deferred at the time. Keeps the same icon-plus-comma-separated LOOK the
    /// single joined Label had, just per-name now, so each is its own tap target instead of one
    /// opaque string.
    private var participantsRow: some View {
        HStack(spacing: Gap.s4) {
            Icon(.people, Register.caption, Ink.iconSecondary)
            ForEach(Array(meta.participants.enumerated()), id: \.offset) { index, name in
                // `Pressable` rather than a bare `Button(.plain)`: it is the system's hit target
                // and publishes pressed/focused state, so this stays one control vocabulary even
                // where the control draws nothing of its own.
                Pressable(action: { openParticipant(name) }) {
                    Text(index == meta.participants.count - 1 ? name : "\(name),")
                        .typeface(Register.caption, Ink.textSecondary)
                }
            }
        }
    }

    private var tagRow: some View {
        HStack(spacing: Gap.s6) {
            ForEach(meta.tags, id: \.self) { tag in
                // M21: matches the People rail's tag chips, which already navigate — this was the
                // one tag surface left that didn't. Named `action:` deliberately: `Pill`'s trailing
                // closure position is `onRemove`, so a trailing closure here would silently build
                // an inert pill with a remove affordance.
                Pill(text: tag, style: .neutral, action: { AppModel.shared.route = .tag(tag) })
            }
        }
    }

    /// Resolves a participant's name to their registry entity, matching the fallback shape used
    /// everywhere else this pattern already exists (e.g. KnowledgeView's People rail) — never
    /// allocates (`resolveConfirmed`), since this is a read-only surface, not a place that should
    /// mint a new identity from a name it merely displays. Falls back to opening the page by raw
    /// name when nothing confirmed matches — the page still shows correctly (M17's own commitment-
    /// owner fallback already exercises this exact path), it just won't resolve to a tracked entity.
    private func openParticipant(_ name: String) {
        let id = EntityRegistry.shared.resolveConfirmed(surface: name, kind: "person", group: meta.group) ?? name
        entitySheetTarget = EntitySheetTarget(id: id, fallbackName: name)
    }

    // MARK: - Action row

    /// Sized by its content, not declared: six `Density.pill` (28) controls plus `Gap.s6` above and
    /// below land the bar on the 40 the hub's other in-window bars use, while staying a MINIMUM —
    /// the same 40 spelled as `.frame(height:)` clips the moment anything in it grows.
    private var actionBar: some View {
        HStack(spacing: Gap.s2) {
            Spacer()
            IconButton(glyph: .edit, label: "Edit details") { showingEditor = true }
            IconButton(glyph: .document, label: "Open in external editor") {
                NSWorkspace.shared.open(meta.url)
            }
            IconButton(glyph: .folder, label: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([meta.url])
            }
            shareMenu
            IconButton(glyph: .book, label: "Add to vocabulary",
                       help: "Add to vocabulary — teach a term once; transcription and search "
                           + "learn it everywhere") {
                termCanonical = ""; termAliases = ""; termGloss = ""
                addingTerm = true
            }
            IconButton(glyph: .trash, label: "Delete transcript") { confirmingDelete = true }
        }
        .controlBox(Density.action, horizontal: Gap.s16, vertical: Gap.s6)
        .background(Ink.background)
        .overlay(alignment: .bottom) { Hairline() }
    }

    /// Hand-built rather than an `IconButton`: a `Menu` owns its own label view, and nesting a
    /// button inside it gives the row two overlapping hit targets. The geometry is copied from
    /// `IconButtonSkin` so it lines up with the five real buttons beside it; the hover feedback
    /// `ControlSkin` would have given it is what this costs.
    private var shareMenu: some View {
        Menu {
            Button("Copy summary") { copy(TranscriptExporter.summary(of: meta.url)) }
            Button("Copy transcript") { copy(TranscriptExporter.plainText(of: meta.url)) }
            Divider()
            Button("Export as PDF…") {
                TranscriptExporter.savePanel(suggestedName: fileName, ext: "pdf") { url in
                    do { try TranscriptExporter.exportPDF(meta, to: url) }
                    catch { exportError = error.localizedDescription }
                }
            }
            Button("Export as text…") {
                TranscriptExporter.savePanel(suggestedName: fileName, ext: "txt") { url in
                    do { try TranscriptExporter.exportText(meta, to: url) }
                    catch { exportError = error.localizedDescription }
                }
            }
            Divider()
            Button("Attach document to this call…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.allowsMultipleSelection = true
                panel.prompt = "Attach"
                panel.message = "The file's text is analyzed on-device and linked to this call."
                guard panel.runModal() == .OK else { return }
                for url in panel.urls {
                    Task { await AppModel.shared.importDocument(url, linkedCall: meta.url) }
                }
            }
        } label: {
            // `textPrimary` to match its five neighbours. `IconButtonSkin` draws
            // `rank.palette.foreground(phase)`, which at the default `.tertiary` rank is
            // `textPrimary` — so this hand-built menu label, which copied that skin's GEOMETRY and
            // not its TONE, was the only icon in the row a different colour. Before the migration
            // all six matched; this mismatch was introduced by copying half a component.
            Icon(.share, Register.bodyUI, Ink.textPrimary)
                .frame(minWidth: Gap.s16, minHeight: Gap.s16)
                .controlBox(Density.pill, horizontal: Gap.s6)
                .contentShape(Corner.shape(Corner.control))
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Share, export, or attach a document")
    }
}

/// The system's separator: a solid hairline in `Ink.borderSubtle`. `Surface.swift` states that rule
/// and ships only `DottedRule`, whose texture is reserved for "no verdict was possible" — so the
/// ordinary case has no view and gets spelled out here.
private struct Hairline: View {
    var body: some View {
        Rectangle().fill(Ink.borderSubtle).frame(height: Elevation.hairline)
    }
}

private struct BlockView: View {
    let block: TranscriptBlock
    let cast: SpeakerCast
    var highlighted: Bool = false

    var body: some View {
        switch block {
        case .section(let title):
            // A section heading is chrome naming a region, not something anyone said.
            Text(title).typeface(Register.title3, Ink.textPrimary).padding(.top, Gap.s8)
        case .audioLine(let stamp, let speaker, let text):
            SpokenLine(stamp: stamp, speaker: speaker, mark: cast.mark(for: speaker),
                       text: text, highlighted: highlighted)
        case .screenMarker(let stamp):
            Text(stamp).typeface(Register.monoMicro, Ink.textHelper).padding(.top, Gap.s4)
        case .table(let rows):
            // Mono for the column alignment the pre-formatted rows were written against.
            Text(rows.joined(separator: "\n"))
                .typeface(Register.mono, Ink.textSecondary)
                .padding(Gap.s10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(Ink.layer, radius: Corner.card)
        case .paragraph(let text):
            Text(text)
                .proseText(Register.prose, Ink.textSecondary)
                .frame(maxWidth: Metrics.proseMaxWidth, alignment: .leading)
        case .divider:
            Hairline()
        }
    }
}
