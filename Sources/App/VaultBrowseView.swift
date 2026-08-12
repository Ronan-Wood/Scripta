import SubstrateKit
import SwiftUI

// MARK: - Reading the vault
//
// THE THIRD SIBLING of Ask and the Library, drawn in the same family: the same outer gate on the
// engine's lifecycle, the same four cards for it, the same `EngineNote` line, the same rule that a
// healthy state is quiet. Ask reads a scope by asking it a question; the Library writes one; this
// one simply LOOKS at it — the surface Doc 4 §8 named and nothing implemented.
//
// IT IS NOT A FILE BROWSER, and the distinction is the reason it exists. A workspace scope inherits
// a curated vault, so the corpus spans several vaults in several places and the inheritance lives
// in a manifest chain rather than on any one disk. Everything on this screen — including which
// vault a note came from — is the ENGINE's answer about the COMPOSED corpus. Reading the workspace
// folder would show a strict, silent subset.

struct VaultBrowseView: View {
    @ObservedObject var model: VaultBrowseModel
    @ObservedObject private var engine = SubstrateEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) { column }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            .background(Ink.background)
            .task { engine.startIfIdle() }
    }

    /// The supervisor first, the corpus second — the ordering Ask documents. Listing a scope at an
    /// engine that was spawned four seconds ago comes back as a transport failure and would render
    /// as "your vault could not be read", which is a healthy state drawn as a fault.
    @ViewBuilder private var column: some View {
        switch engine.lifecycle {
        case .idle, .starting:
            VaultEngineStarting(lifecycle: engine.lifecycle)
        case .notInstalled, .portBusy, .failed:
            VaultEngineRefusal(lifecycle: engine.lifecycle, restart: engine.restart)
        case .serving:
            VaultBrowseConsole(model: model)
        }
    }
}

private struct VaultBrowseConsole: View {
    @ObservedObject var model: VaultBrowseModel
    @State private var reading: VaultDocument?
    /// Reading a note FILLS the pane rather than sharing it with the list. Not a window — the
    /// reader wanted one screen for one note without leaving the app.
    @State private var full = false
    /// The document a delete is pending on. Held as the whole value because removing one resolves
    /// its source directory through `expand` — the listing deliberately carries no absolute path.
    @State private var removing: VaultDocument?

    var body: some View {
        content
            // ADOPT ON APPEAR, LOAD ON THE TOKEN. Two modifiers because they answer two questions:
            // opening this screen must re-read the binding (a rebind made in Ask changes the scope
            // without changing the workspace), and the load must be keyed on something the loading
            // task itself cannot write — keying it on the scope let the task invalidate its own
            // trigger and spin forever.
            .onAppear { model.adoptWorkspace() }
            .task(id: model.reloadToken) { await model.loadIfNeeded() }
            .confirmationDialog(
                removing.map { "Remove “\($0.title ?? $0.id)” from this workspace's vault?" } ?? "",
                isPresented: Binding(get: { removing != nil },
                                     set: { if !$0 { removing = nil } }),
                presenting: removing
            ) { document in
                Button("Remove", role: .destructive) { remove(document) }
                Button("Cancel", role: .cancel) {}
            } message: { _ in
                Text("This removes the document from this workspace's vault and recomposes the "
                     + "scope without it. The file you imported from is not affected.")
            }
    }

    /// THROUGH THE ENGINE, because that is where the document is — the same path the documents
    /// shelf takes. `remove(source:)` deletes the source directory, constrained to the vault's own
    /// `10-reference/`, and recomposes `--clean`, without which the removed note's ingest directory
    /// survives in the index root and keeps answering.
    private func remove(_ document: VaultDocument) {
        removing = nil
        Task {
            guard let source = await model.sourceDirectory(of: document) else { return }
            SubstrateLibraryModel.shared.remove(source: source)
            await model.load()
        }
    }

    /// The list, and the note beside it. A SPLIT, not a sheet: a modal covered the list it came
    /// from, so comparing two notes meant closing one, and reading is what this surface is for.
    @ViewBuilder private var content: some View {
        if let document = reading, full {
            VaultNoteReader(document: document, model: model, controls: AnyView(readerControls),
                            follow: { reading = $0 })
        } else {
            HStack(spacing: 0) {
                listing
                if let document = reading {
                    Rectangle().fill(Ink.borderSubtle.color).frame(width: 1)
                    VaultNoteReader(document: document, model: model,
                                    controls: AnyView(readerControls),
                                    follow: { reading = $0 })
                        .frame(minWidth: 380, idealWidth: 520, maxWidth: .infinity)
                }
            }
        }
    }

    /// Fill the pane, tear it off, or close it — the three things a reader wants from a panel.
    private var readerControls: some View {
        HStack(spacing: Gap.s4) {
            IconButton(glyph: full ? .collapse : .expand,
                       label: full ? "Show the list too" : "Fill the pane",
                       action: { full.toggle() })
            IconButton(glyph: .launch, label: "Open in a new window", action: {
                if let document = reading {
                    VaultNoteWindows.show(document, model: model)
                    reading = nil
                    full = false
                }
            })
            IconButton(glyph: .close, label: "Close", action: { reading = nil; full = false })
        }
    }

    @ViewBuilder private var listing: some View {
        switch model.state {
        case .unasked, .loading:
            VaultProbe()
        case .idle:
            VaultBrowseIdle { Task { await model.load() } }
        case .unbound:
            VaultBrowseUnbound()
        case .refused(let refusal):
            ScrollView {
                VaultRefusalCard(refusal: refusal, retryTitle: "Try again") {
                    Task { await model.load() }
                }
                .padding(Metrics.pageGutter)
            }
        case .listed(let listing):
            VaultBrowseListing(listing: listing, model: model,
                               open: { reading = $0 }, confirmRemove: { removing = $0 },
                               reload: { Task { await model.load() } })
        }
    }
}

/// WHICH CORPUS IS ON SCREEN, and every other one that could be. Ask has had this since it was
/// written; the browser had a workspace and no way off it, so a reader with six composed scopes
/// could see exactly one of them in the surface built for looking at scopes.
private struct VaultScopePicker: View {
    @ObservedObject var model: VaultBrowseModel
    @ObservedObject private var scopes = SubstrateScopes.shared

    var body: some View {
        if case .listed(let rows) = scopes.roster, rows.count > 1 {
            HStack(spacing: Gap.s6) {
                Text("scope").typeface(Register.monoMicro, Ink.textHelper)
                VaultChip(title: "this workspace", selected: model.scopeOverride == nil) {
                    model.look(at: nil)
                }
                ForEach(rows.filter(\.indexPresent), id: \.scope) { row in
                    VaultChip(title: row.scope, selected: model.scopeOverride == row.scope) {
                        model.look(at: row.scope)
                    }
                }
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

/// Asked for and abandoned — a reload cancelled by navigating away with nothing already on screen.
/// It draws a CONTROL rather than a spinner: nothing is going to resolve this on its own, and a
/// dead end that looks like progress is the failure the whole state machine is arranged to avoid.
private struct VaultBrowseIdle: View {
    let load: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s12) {
            EngineNoteRow(note: EngineNote(
                id: "idle", marker: "not loaded", tone: Ink.textHelper,
                text: "This vault has not been read yet."))
            VaultRetry(title: "Read the vault", action: load)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.pageGutter)
    }
}

/// A workspace that reads no vault. NAMED, not blank: an empty browser would say "your vault is
/// empty" about a vault nobody has chosen, and the operator's fix is one screen away rather than
/// anywhere in here.
private struct VaultBrowseUnbound: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s12) {
            EngineNoteRow(note: EngineNote(
                id: "unbound", marker: "no vault", tone: Ink.textHelper,
                text: "This workspace does not read a vault yet, so there is nothing here to show. "
                    + "It is not that the vault is empty — no vault has been named. Bind one in "
                    + "Ask and it will appear here, its calls and its notes together."))
                .padding(Metrics.cardPaddingCompact)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(Ink.layer)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(Metrics.pageGutter)
    }
}

// MARK: - The listing

private struct VaultBrowseListing: View {
    let listing: VaultBrowseModel.Listing
    @ObservedObject var model: VaultBrowseModel
    let open: (VaultDocument) -> Void
    /// Asks the console to confirm a removal — the dialog and the `expand` round trip live there,
    /// with the state they need.
    let confirmRemove: (VaultDocument) -> Void
    let reload: () -> Void
    /// Vaults the reader has folded away. BY NAME, not by index, so collapsing `core-vault` and then
    /// changing the filter does not silently fold whichever group slid into that position.
    @State private var collapsed: Set<String> = []

    /// A view filter over what was already fetched — no round trip to show fewer rows.
    private var shown: [VaultDocument] {
        guard let vault = model.vaultFilter else { return listing.documents }
        return listing.documents.filter { $0.vault == vault }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Gap.s16) {
                controls
                rows
            }
            // NO `listMaxWidth` HERE. That cap exists so a paragraph does not run to a 2000pt
            // measure, and these are CARDS — a title, a meta line and a count. Capping them left
            // two thirds of a widened window empty while the list it was hiding scrolled on.
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Metrics.pageGutter)
        }
    }

    /// Split from `rows` because the solver charges for DEPTH, not for modifier identity — the same
    /// threshold `CallsDigestLens` records. One expression here failed to type-check at all.
    @ViewBuilder private var controls: some View {
        VaultScopePicker(model: model)
        header
        if let note = frozenNote { VaultScopeNote(note: note) }
        VaultFilterRow(listing: listing, model: model)
        ExclusionBar(filter: listing.filters, toggle: model.include)
        if let refused = model.refusedInclusion {
            Text(AskModel.refusalSentence(for: refused))
                .typeface(Register.micro, Ink.textHelper)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private var rows: some View {
                if shown.isEmpty {
                    VaultBrowseEmpty(listing: listing, filtered: model.vaultFilter != nil)
                } else {
                    // GROUPED BY VAULT, which is the question this screen exists to answer. A flat
                    // scroll of seventy-six cards from three vaults cannot say which corpus you are
                    // looking through, and `vault` + `tier` are exactly the two fields a directory
                    // listing could never carry — the reason the engine sends them at all.
                    ForEach(groups) { group in
                        VaultGroupHeader(vault: group.vault, tier: group.tier,
                                         count: group.documents.count,
                                         open: !collapsed.contains(group.vault)) {
                            if collapsed.contains(group.vault) { collapsed.remove(group.vault) }
                            else { collapsed.insert(group.vault) }
                        }
                        ForEach(collapsed.contains(group.vault) ? [] : group.documents) { document in
                            VaultDocumentCard(document: document,
                                              open: { open(document) },
                                              // Only what this app wrote, and only tier 2 — an
                                              // inherited note is not ours to remove, so it gets no
                                              // control rather than one that refuses.
                                              remove: model.isRemovable(document)
                                                  ? { confirmRemove(document) } : nil)
                        }
                    }
                }
    }

    /// One vault's rows, ordered by TIER — shared knowledge first, this project's own last, which
    /// is the order the chain composes in and the order a reader builds context in.
    private var groups: [VaultGroup] {
        // A NAMED TYPE, not a tuple. The tuple-returning `Dictionary(grouping:).map.sorted` chain
        // defeated the type checker outright — "unable to type-check in reasonable time" — and the
        // fix is the same one the codebase keeps recording: give the solver a boundary.
        let byVault: [String: [VaultDocument]] = Dictionary(grouping: shown, by: { $0.vault })
        var built: [VaultGroup] = []
        for (vault, documents) in byVault {
            let tier = documents.compactMap(\.tier).min() ?? 9
            built.append(VaultGroup(vault: vault, tier: tier, documents: documents))
        }
        built.sort { $0.tier != $1.tier ? $0.tier < $1.tier : $0.vault < $1.vault }
        return built
    }

    /// COUNTS, BOTH OF THEM. `shown` is what is on screen after the vault filter; `total` is what
    /// the engine matched. Reporting only the first would make a filtered view look like the whole
    /// corpus, which is the browse surface's version of a silent exclusion.
    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Gap.s8) {
            VStack(alignment: .leading, spacing: Gap.s4) {
                Text(listing.scope).typeface(Register.title3, Ink.textPrimary)
                Text(countSentence).typeface(Register.micro, Ink.textHelper)
            }
            Spacer(minLength: Gap.s8)
            // The list re-reads on every appearance now, so this is for the case that does not
            // involve leaving: a compose finishing, or a call landing, while the screen is open.
            ActionButton(title: "Refresh", glyph: .refresh, rank: .tertiary, action: reload)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var countSentence: String {
        let noun = listing.total == 1 ? "note" : "notes"
        if shown.count == listing.total { return "\(listing.total) \(noun)" }
        return "\(shown.count) of \(listing.total) \(noun)"
    }

    /// The refresh verdict, drawn with the same words Ask's scope chip uses. A frozen refresh means
    /// these rows describe the SUPERSEDED index rather than the vault, which a list read as current
    /// would quietly misreport.
    private var frozenNote: EngineNote? {
        guard listing.refresh.frozen == .frozen else { return nil }
        return EngineNote(id: "browse-frozen", marker: "frozen", tone: Ink.warning,
                          text: "The vault changed and the last recompose refused, so this list is "
                              + "what the superseded index holds rather than what is in the vault "
                              + "now.")
    }
}

/// The two controls: which vault, and whether the withheld classes are shown.
private struct VaultFilterRow: View {
    let listing: VaultBrowseModel.Listing
    @ObservedObject var model: VaultBrowseModel

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s8) {
            if listing.vaults.count > 1 || model.vaultFilter != nil {
                HStack(spacing: Gap.s6) {
                    VaultChip(title: "All vaults", selected: model.vaultFilter == nil) {
                        model.vaultFilter = nil
                    }
                    ForEach(listing.vaults, id: \.self) { vault in
                        VaultChip(title: vault, selected: model.vaultFilter == vault) {
                            model.vaultFilter = vault
                        }
                    }
                }
            }
            Toggle("Include archived notes", isOn: $model.includesArchived)
            Toggle("Include calls", isOn: $model.includesSources)
                .toggleStyle(.checkbox)
                .typeface(Register.micro, Ink.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct VaultChip: View {
    let title: String
    let selected: Bool
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title).typeface(Register.monoMicro, selected ? Ink.textPrimary : Ink.textSecondary)
        }
        .buttonStyle(.plain)
        .controlBox(Density.pill, horizontal: Gap.s8, vertical: Gap.s2)
        .surface(selected ? Ink.layerSelected : Ink.layer,
                 radius: Corner.control,
                 border: selected ? Ink.interactive : Ink.borderSubtle,
                 width: Elevation.hairline)
    }
}

/// Nothing to show — and WHY there is nothing, which is never "the vault is empty" unless it is.
private struct VaultBrowseEmpty: View {
    let listing: VaultBrowseModel.Listing
    let filtered: Bool

    var body: some View {
        EngineNoteRow(note: EngineNote(id: "empty", marker: "nothing", tone: Ink.textHelper,
                                       text: sentence))
            .padding(Metrics.cardPaddingCompact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(Ink.layer)
    }

    private var sentence: String {
        if filtered {
            return "No notes from that vault on this page. The other vaults in this scope still "
                + "have theirs — clear the filter to see them."
        }
        if listing.total > 0 {
            return "The engine matched \(listing.total) notes and none of them arrived, which is a "
                + "fault rather than an empty vault. Reload, and if it persists the index and the "
                + "reader disagree."
        }
        return "This scope composed no notes. Its vault is empty, or its manifest points somewhere "
            + "that is."
    }
}

// MARK: - One note

/// A row. The spine is drawn with the SAME component every passage card uses, so a note reads the
/// same in a list as it does in an answer — and an axis added to the model reaches both without
/// anyone remembering to add a badge here.
private struct VaultDocumentCard: View {
    let document: VaultDocument
    let open: () -> Void
    /// `nil` for a document this app may not remove — see `VaultBrowseModel.isRemovable`.
    var remove: (() -> Void)?

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Gap.s2) {
                HStack(alignment: .firstTextBaseline, spacing: Gap.s8) {
                    Text(title).typeface(Register.uiEmphasis, Ink.textPrimary)
                        .lineLimit(1)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(provenance).typeface(Register.monoMicro, Ink.textHelper)
                }
                // ONE META LINE, AND ONLY WHAT VARIES. The full `PassageSpine` drew four badges on
                // every row — and `active` and `unclassified` are what almost every note IS, so two
                // of the four carried no information and cost a line of height each. That is rule 3
                // again: a healthy default should be quiet. `doc_type` stays because it genuinely
                // varies, and status/confidence speak only when they deviate.
                HStack(spacing: Gap.s8) {
                    Text(meta).typeface(Register.monoMicro, Ink.textHelper).lineLimit(1)
                    Spacer(minLength: Gap.s4)
                }
                if let line = supersessionLine {
                    Text(line).typeface(Register.micro, Ink.textHelper).lineLimit(1)
                }
            }
            .padding(.horizontal, Gap.s12).padding(.vertical, Gap.s8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(Ink.layer)
        }
        .buttonStyle(.plain)
        .disabled(document.expandRef == nil)
        .opacity(document.expandRef == nil ? 0.6 : 1)
        // A CONTEXT MENU, because the card IS the button. A trailing control nested inside it would
        // be swallowed by the outer `Button` on macOS, and the conversation rows in Ask already take
        // this shape for the same reason. Absent entirely on a document this app may not remove.
        .contextMenu {
            if let remove {
                Button("Remove from this vault…", role: .destructive, action: remove)
            }
        }
    }

    /// The note's own title, or its id — VISIBLY the id, not dressed up as a title. A title is a
    /// claim the note makes about itself and an id is one the engine makes about the file.
    private var title: String { document.title ?? document.id }

    /// What this note IS, plus anything unusual about it. Deviations only — see the body.
    private var meta: String {
        var parts = [document.docType.label]
        if document.status != .active { parts.append(document.status.label) }
        if document.confidence.isJudged || document.confidence == .unjudged {
            parts.append(document.confidence.label)
        }
        if document.documentClass == .conversation { parts.append("from a call") }
        parts.append(contentsOf: document.domains)
        return parts.joined(separator: " · ")
    }

    /// Which vault, and how big. `passage_count` rather than a snippet: there was no query, so any
    /// sentence picked from the note would be an arbitrary one presented as its gist.
    /// The vault name is NOT repeated here any more — the group header above these rows says it
    /// once, and printing it on all thirty-three of them was the same fact thirty-three times.
    private var provenance: String {
        document.expandRef == nil
            ? "empty" : "\(document.passageCount) passage\(document.passageCount == 1 ? "" : "s")"
    }

    private var supersessionLine: String? {
        if let by = document.supersededBy { return "superseded by \(by)" }
        guard !document.supersedes.isEmpty else { return nil }
        return "replaces \(document.supersedes.joined(separator: ", "))"
    }

    /// The spine, borrowed through `Passage` so `PassageSpine` can draw it. Empty text and citation
    /// because neither is drawn — the alternative is a second spine component to keep in step with
    /// the first, which is the duplication this delegation exists to avoid.
}

/// One note in a sheet — the documents shelf's presentation, where a modal is right: that shelf is
/// a list of a workspace's own uploads inside a digest, not a browse surface, so there is nothing
/// beside it worth keeping visible.
///
/// A WRAPPER, NOT A SECOND READER. It had its own copy of the header, the freshness verdict and the
/// body; `VaultNoteReader` owns all three now, so the sheet and the Library's panel cannot render
/// the same note two ways.
struct VaultNoteSheet: View {
    let document: VaultDocument
    @ObservedObject var model: VaultBrowseModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VaultNoteReader(document: document, model: model,
                        controls: AnyView(Button("Done") { dismiss() }
                                            .keyboardShortcut(.defaultAction)))
            .frame(minWidth: 620, minHeight: 480)
    }
}

/// Which vault the rows beneath came from, and what that MEANS.
///
/// The name alone does not tell a reader whether `core-vault` is theirs, this project's, or shared
/// with everything — and that is the distinction the whole browse surface exists for. The tier says
/// it, so the tier is spelled out in words rather than printed as the number the engine uses.
private struct VaultGroupHeader: View {
    let vault: String
    let tier: Int
    let count: Int
    let open: Bool
    let toggle: () -> Void

    var body: some View {
        Button(action: toggle) {
            VStack(alignment: .leading, spacing: Gap.s2) {
                HStack(spacing: Gap.s8) {
                    Icon(open ? .chevronDown : .chevronRight, Register.monoMicro, Ink.textHelper)
                    Text(vault).typeface(Register.uiEmphasis, Ink.textPrimary)
                    Text("\(count) note\(count == 1 ? "" : "s")")
                        .typeface(Register.monoMicro, Ink.textHelper)
                    Spacer(minLength: Gap.s4)
                }
                // The role line folds with the rows: collapsed, the point is to scan vault NAMES,
                // and three explanatory sentences between them defeats that.
                if open {
                    Text(role).typeface(Register.micro, Ink.textHelper)
                        .padding(.leading, Gap.s16)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Gap.s8)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    /// Doc 4 §7's two vault roles, said in the reader's terms. Tier 3 is the workspace vault — the
    /// one capture and upload write, the only one an unattended path can reach.
    private var role: String {
        switch tier {
        case 1: return "Shared with every project — your own knowledge, inherited here."
        case 2: return "Reference — documents added to this project."
        default: return "This project — its calls and its notes."
        }
    }
}

/// One vault's rows in the browse list.
struct VaultGroup: Identifiable {
    let vault: String
    /// The shallowest tier any of its notes sits at — a vault composes at one tier in practice, and
    /// `min` keeps the ordering stable if that ever stops being true.
    let tier: Int
    let documents: [VaultDocument]

    var id: String { vault }
}
