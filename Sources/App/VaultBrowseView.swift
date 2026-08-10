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

    var body: some View {
        content
            // ADOPT ON APPEAR, LOAD ON THE TOKEN. Two modifiers because they answer two questions:
            // opening this screen must re-read the binding (a rebind made in Ask changes the scope
            // without changing the workspace), and the load must be keyed on something the loading
            // task itself cannot write — keying it on the scope let the task invalidate its own
            // trigger and spin forever.
            .onAppear { model.adoptWorkspace() }
            .task(id: model.reloadToken) { await model.loadIfNeeded() }
            .sheet(item: $reading) { VaultNoteSheet(document: $0, model: model) }
    }

    @ViewBuilder private var content: some View {
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
            VaultBrowseListing(listing: listing, model: model) { reading = $0 }
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
        .frame(maxWidth: Metrics.listMaxWidth, alignment: .leading)
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
        .frame(maxWidth: Metrics.listMaxWidth, alignment: .leading)
        .padding(Metrics.pageGutter)
    }
}

// MARK: - The listing

private struct VaultBrowseListing: View {
    let listing: VaultBrowseModel.Listing
    @ObservedObject var model: VaultBrowseModel
    let open: (VaultDocument) -> Void

    /// A view filter over what was already fetched — no round trip to show fewer rows.
    private var shown: [VaultDocument] {
        guard let vault = model.vaultFilter else { return listing.documents }
        return listing.documents.filter { $0.vault == vault }
    }

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Gap.s16) {
                VaultScopePicker(model: model)
                header
                if let note = frozenNote { VaultScopeNote(note: note) }
                VaultFilterRow(listing: listing, model: model)
                ExclusionBar(filter: listing.filters, toggle: model.include)
                if let refused = model.refusedInclusion {
                    Text(SubstrateAskModel.refusalSentence(for: refused))
                        .typeface(Register.micro, Ink.textHelper)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if shown.isEmpty {
                    VaultBrowseEmpty(listing: listing, filtered: model.vaultFilter != nil)
                } else {
                    ForEach(shown) { document in
                        VaultDocumentCard(document: document) { open(document) }
                    }
                }
            }
            .frame(maxWidth: Metrics.listMaxWidth, alignment: .leading)
            .padding(Metrics.pageGutter)
        }
    }

    /// COUNTS, BOTH OF THEM. `shown` is what is on screen after the vault filter; `total` is what
    /// the engine matched. Reporting only the first would make a filtered view look like the whole
    /// corpus, which is the browse surface's version of a silent exclusion.
    private var header: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text(listing.scope).typeface(Register.title3, Ink.textPrimary)
            Text(countSentence).typeface(Register.micro, Ink.textHelper)
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

    var body: some View {
        Button(action: open) {
            VStack(alignment: .leading, spacing: Gap.s6) {
                HStack(alignment: .firstTextBaseline, spacing: Gap.s8) {
                    Text(title).typeface(Register.uiEmphasis, Ink.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(provenance).typeface(Register.monoMicro, Ink.textHelper)
                }
                PassageSpine(passage: spine)
                if !document.domains.isEmpty {
                    Text(document.domains.joined(separator: " · "))
                        .typeface(Register.micro, Ink.textHelper)
                }
                if let line = supersessionLine {
                    Text(line).typeface(Register.micro, Ink.textHelper)
                }
            }
            .padding(Metrics.cardPaddingCompact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(Ink.layer)
        }
        .buttonStyle(.plain)
        .disabled(document.expandRef == nil)
        .opacity(document.expandRef == nil ? 0.6 : 1)
    }

    /// The note's own title, or its id — VISIBLY the id, not dressed up as a title. A title is a
    /// claim the note makes about itself and an id is one the engine makes about the file.
    private var title: String { document.title ?? document.id }

    /// Which vault, and how big. `passage_count` rather than a snippet: there was no query, so any
    /// sentence picked from the note would be an arbitrary one presented as its gist.
    private var provenance: String {
        let size = document.expandRef == nil
            ? "empty" : "\(document.passageCount) passage\(document.passageCount == 1 ? "" : "s")"
        return document.vault.isEmpty ? size : "\(document.vault) · \(size)"
    }

    private var supersessionLine: String? {
        if let by = document.supersededBy { return "superseded by \(by)" }
        guard !document.supersedes.isEmpty else { return nil }
        return "replaces \(document.supersedes.joined(separator: ", "))"
    }

    /// The spine, borrowed through `Passage` so `PassageSpine` can draw it. Empty text and citation
    /// because neither is drawn — the alternative is a second spine component to keep in step with
    /// the first, which is the duplication this delegation exists to avoid.
    private var spine: Passage {
        Passage(id: document.id, snippet: "", citation: "", vault: document.vault,
                status: document.status, docType: document.docType,
                confidence: document.confidence, documentClass: document.documentClass,
                domains: document.domains, supersedes: document.supersedes)
    }
}

/// The note itself, read from the vault. Its text arrives with a freshness verdict, and the verdict
/// is on screen: `expand` reads the SOURCE file, so it can report that the note has moved on since
/// the index was built — the one thing a reader of a search result cannot otherwise know.
/// Shared with the Knowledge Documents shelf: a vault document opened from there is the same
/// content read the same way, and a second reader would be a second place for the freshness
/// verdict to be got wrong.
struct VaultNoteSheet: View {
    let document: VaultDocument
    @ObservedObject var model: VaultBrowseModel
    @Environment(\.dismiss) private var dismiss
    @State private var outcome: VaultBrowseModel.Reading?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            body(for: outcome)
        }
        .frame(minWidth: 620, minHeight: 480)
        .background(Ink.background)
        .task { outcome = await model.read(document) }
    }

    private var header: some View {
        HStack(alignment: .firstTextBaseline, spacing: Gap.s8) {
            VStack(alignment: .leading, spacing: Gap.s2) {
                Text(document.title ?? document.id).typeface(Register.title3, Ink.textPrimary)
                if !document.vault.isEmpty {
                    Text(document.vault).typeface(Register.monoMicro, Ink.textHelper)
                }
            }
            Spacer(minLength: Gap.s8)
            Button("Done") { dismiss() }.keyboardShortcut(.defaultAction)
        }
        .padding(Metrics.cardPaddingCompact)
    }

    @ViewBuilder private func body(for outcome: VaultBrowseModel.Reading?) -> some View {
        switch outcome {
        case nil:
            VaultProbe()
        case .refused(let refusal):
            ScrollView {
                VaultRefusalCard(refusal: refusal, retryTitle: nil, retry: nil)
                    .padding(Metrics.pageGutter)
            }
        case .note(let note):
            ScrollView {
                VStack(alignment: .leading, spacing: Gap.s12) {
                    if let line = freshness(note) {
                        EngineNoteRow(note: line)
                            .padding(Metrics.cardPaddingCompact)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .surface(Ink.layer)
                    }
                    Text(note.text)
                        .typeface(Register.proseSm, Ink.textPrimary)
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    Text(note.path).typeface(Register.monoMicro, Ink.textHelper)
                        .textSelection(.enabled)
                }
                .padding(Metrics.pageGutter)
            }
        }
    }

    /// Only when there is something to say. A note that matches the index is the healthy state and
    /// rule 3 keeps it quiet; the other two verdicts are not the same as each other and neither is
    /// the same as silence.
    private func freshness(_ note: WireNote) -> EngineNote? {
        switch note.stale {
        case .matches:
            return nil
        case .stale:
            return EngineNote(id: "stale", marker: "changed", tone: Ink.warning,
                              text: "This note has been edited since the index was built. You are "
                                  + "reading the vault's current text; a search would still answer "
                                  + "from the older one until the scope is recomposed.")
        case .uncheckable:
            return EngineNote(id: "unverifiable", marker: "unverified", tone: Ink.textHelper,
                              text: "Whether this note has changed cannot be told from the index — "
                                  + "its stored checksum names a source file rather than the note "
                                  + "itself. This is the vault's current text either way.")
        }
    }
}
