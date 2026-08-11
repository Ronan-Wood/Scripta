import Foundation
import ScriptaCore
import SubstrateKit

/// Reading the vault, in the app (Doc 4 §8).
///
/// THE FOURTH SURFACE. Capture writes calls into the workspace vault, upload ingests documents into
/// it, Ask queries it — and until now nothing could simply LOOK at it. That gap had a shape: the
/// operator's knowledge lived in a corpus the app could answer questions from but could not show.
///
/// IT ASKS THE ENGINE RATHER THAN LISTING THE FOLDER, and the difference is the whole design.
/// A workspace scope INHERITS a curated vault, so the corpus is composed from several vaults in
/// several places and the inheritance is resolved by a manifest chain that lives on none of them.
/// Measured on the live `cbre` scope 2026-08-06: 62 notes, of which 33 are in `core-vault` — a
/// folder listing would have shown 29 and had no way to know the other 33 existed.
///
/// EVERY REFUSAL IS THE ENGINE'S OWN. The one thing this must never do is answer "your vault is
/// empty" when the truth is "the engine is not running", so there is no local fallback path and no
/// cached list to fall back to.
@MainActor
final class VaultBrowseModel: ObservableObject {
    static let shared = VaultBrowseModel()

    /// A scope the reader chose instead of this workspace's own. `nil` follows the workspace.
    ///
    /// ASK HAS ALWAYS HAD THIS AND THE BROWSER DID NOT, which is why the operator could not see
    /// `prism` here at all: every other corpus was one chip away in Ask and unreachable in the one
    /// surface whose entire job is looking at a corpus. Held on the model rather than the view
    /// because `HubContent` rebuilds this pane on every sidebar reselect.
    @Published private(set) var scopeOverride: String?

    /// Look at a different scope, or `nil` to follow the workspace again.
    func look(at scope: String?) {
        guard scope != scopeOverride else { return }
        scopeOverride = scope
        generation &+= 1
        vaultFilter = nil
        refusedInclusion = nil
        loadedScope = scope ?? WorkspaceBindings.active.readsScope
        state = .unasked
        reloadToken &+= 1
    }

    /// The scope this pane is showing: the chosen one, else the workspace's own.
    var activeScope: String? { scopeOverride ?? WorkspaceBindings.active.readsScope }

    enum State {
        /// Nothing asked yet — the pane has not been opened, or the workspace just changed. Draws as
        /// a spinner, because a load is always about to follow it.
        case unasked
        /// Asked for and abandoned. DISTINCT FROM `.unasked` precisely because it draws differently:
        /// nothing is going to follow it on its own, so it offers the control instead of a spinner
        /// that would never stop.
        case idle
        case loading
        /// The workspace reads no scope. NOT an empty list: an unbound workspace has no corpus, and
        /// a blank browser would say the vault is empty about a vault nobody named.
        case unbound
        case listed(Listing)
        case refused(VaultRefusal)
    }

    struct Listing {
        let scope: String
        let documents: [VaultDocument]
        /// How many MATCHED, against how many came back. A short page and a small corpus are
        /// different facts and the surface says which it has.
        let total: Int
        let filters: ExclusionFilter
        /// What the background refresh last managed on this scope. Read WITH the list: a frozen
        /// refresh means these rows are the superseded index's, not the vault's.
        let refresh: WireRefreshReport

        /// Every vault the corpus composed from, in the order the engine returned them, deduped.
        /// The workspace's own vault and the tier it inherits are both in here, which is what the
        /// vault filter is for. STORED, not computed: the filter row reads it on every body pass,
        /// and it is a full sweep of up to a thousand rows.
        let vaults: [String]

        init(scope: String, documents: [VaultDocument], total: Int, filters: ExclusionFilter,
             refresh: WireRefreshReport) {
            self.scope = scope
            self.documents = documents
            self.total = total
            self.filters = filters
            self.refresh = refresh
            var seen = Set<String>(), order: [String] = []
            for document in documents where !document.vault.isEmpty {
                if seen.insert(document.vault).inserted { order.append(document.vault) }
            }
            self.vaults = order
        }
    }

    @Published private(set) var state: State = .unasked

    /// Show only notes from this vault, or all of them. A view filter over what was fetched, NOT a
    /// re-query: the whole page is already here, and asking the engine again to hide rows would
    /// spend a round trip to show less.
    @Published var vaultFilter: String?

    /// Widen past the archived exclusion. OFF by default, matching Ask, so browse and query never
    /// disagree about what is in the vault unless the operator asks them to.
    ///
    /// SUPERSEDED IS NOT IN THIS SET AND CANNOT BE. `retriever.statuses(include_archived: true)`
    /// widens to `{active, complete, archived}` and stops there, so no argument to `documents`
    /// returns a dead note. This flag once claimed otherwise and the screen contradicted itself: a
    /// ticked box promising superseded notes above an exclusion bar reporting them withheld, which
    /// would be read as "my vault has none" — the precise gap-in-the-corpus / gap-in-the-query
    /// confusion the filters block exists to prevent.
    @Published var includesArchived = false {
        didSet { guard oldValue != includesArchived else { return }; Task { await load() } }
    }

    /// The conversation class every captured call is. A SEPARATE FLAG from archived, because they
    /// are separate axes: `retriever.statuses`' own docstring says so, `documents` takes them as two
    /// arguments, and Ask models them as two. Collapsed onto one flag, the two chips drawn side by
    /// side each toggled the same thing — so opening both classes turned both back off.
    @Published var includesSources = false {
        didSet { guard oldValue != includesSources else { return }; Task { await load() } }
    }

    /// Set when the operator clicks an exclusion chip the engine has no argument for. Ask refuses
    /// out loud here rather than no-opping, and so does this — a chip that swallows a click is how
    /// a reader concludes they opened a class they did not.
    @Published private(set) var refusedInclusion: RetrievalClass?

    /// The disclosure chips are live controls, so a click has to do something. Archived and sources
    /// move their own flags; the other three have no argument behind them and say so by name.
    func include(_ klass: RetrievalClass) {
        switch klass {
        case .archived:
            includesArchived.toggle()
        case .sources:
            includesSources.toggle()
        case .superseded, .active, .complete:
            refusedInclusion = klass
            return
        }
        refusedInclusion = nil
    }

    /// One page, at the engine's maximum — asked for exactly, not over it. Asking for more got the
    /// same rows back with a clamp note attached, and that note is drawn in the disclosure strip, so
    /// every single load reported a narrowing that was this app's own doing.
    ///
    /// A vault larger than this shows the first page and says so: the header reads "N of TOTAL",
    /// which is why `total` is on the payload. A silently truncated list is what that exists to
    /// prevent; paging the UI is a real product question and not one to answer by hiding the count.
    private static let pageSize = 500

    private let client = SubstrateClient(timeout: 30)
    private var generation = 0

    /// The scope currently on screen. `@Published` because the PANE keys its load on it: a
    /// `.task` with no id fires once on appear and never again, so a workspace switch left the
    /// browser on a spinner that nothing would ever resolve.
    private(set) var loadedScope: String?

    /// What the pane keys its load on. A COUNTER, and deliberately not `loadedScope` itself.
    ///
    /// Keying `.task(id:)` on the scope put the trigger and the thing the task WRITES on the same
    /// value: the body adopted the binding, `loadedScope` went nil → "cbre", SwiftUI cancelled and
    /// restarted the task, the restart found `state == .loading` and did nothing, and the cancelled
    /// pass reset to `.unasked` with nothing left to fire — the permanent spinner, moved from
    /// workspace-switch to first-open rather than removed. Only `adoptWorkspace` writes this, and it
    /// is never written from inside the task.
    @Published private(set) var reloadToken = 0

    // MARK: - Lifecycle

    /// Re-read the active workspace's binding, and ask for a reload if it moved.
    ///
    /// IT BUMPS THE GENERATION, and that is the point rather than bookkeeping. Without it a switch
    /// made while a request was in flight left the reply valid: the guard in `load()` still matched,
    /// and the PREVIOUS workspace's notes landed on the new workspace's screen. That is the privacy
    /// partition leaking, not a stale view, and it is what `AskModel.adoptBinding` spends
    /// its `epoch` on.
    func adoptWorkspace() {
        // A CHOSEN SCOPE SURVIVES A WORKSPACE SWITCH — it was chosen, not inherited. The privacy
        // partition is unaffected: the reader picked this corpus by name from the roster, which is
        // what Ask's chips have always allowed.
        guard scopeOverride == nil else { return }
        let scope = WorkspaceBindings.active.readsScope
        guard scope != loadedScope else { return }
        generation &+= 1
        loadedScope = scope
        vaultFilter = nil
        refusedInclusion = nil
        state = .unasked
        reloadToken &+= 1
    }

    /// Load if nothing has been loaded yet. It does NOT adopt — the pane adopts on appear, so the
    /// binding is re-read every time this screen is opened (which is what catches a rebind made in
    /// Ask) without the loading task being able to invalidate its own trigger.
    func loadIfNeeded() async {
        if case .unasked = state { await load() }
    }

    func load() async {
        guard let scope = activeScope else {
            // Invalidated here too: a workspace can lose its binding while a request is in flight,
            // and that reply must not land on a screen that now says there is no vault.
            generation &+= 1
            loadedScope = nil
            state = .unbound
            return
        }
        // `loadedScope` is NOT written here. `adoptWorkspace` is its only writer, which is what keeps
        // `reloadToken` a trigger this task cannot pull on itself.
        generation &+= 1
        let mine = generation
        state = .loading

        let request = SubstrateDocumentsRequest(scope: scope,
                                                includeArchived: includesArchived,
                                                includeSources: includesSources,
                                                limit: Self.pageSize)
        let outcome = await client.documents(request)
        // A workspace switched mid-flight must not have the old scope's corpus land on it.
        guard mine == generation else { return }

        switch outcome {
        case .ok(let payload):
            do {
                let listing = Listing(scope: scope,
                                      documents: try payload.mappedDocuments(),
                                      total: payload.total,
                                      filters: try payload.filters.mapped(),
                                      refresh: payload.refresh)
                // A FILTER THE NEW LISTING CANNOT SATISFY IS DROPPED. `Listing.vaults` is derived
                // from the rows that came back, and the chip row — including the "All vaults"
                // escape — only draws when there is more than one. So a filter naming a vault this
                // listing has none of produced an empty list, the words "clear the filter", and no
                // control on screen that clears it.
                if let filter = vaultFilter, !listing.vaults.contains(filter) { vaultFilter = nil }
                state = .listed(listing)
            } catch {
                // A spine word this build has no case for. Refused by name rather than dropped:
                // a list quietly missing the rows it could not read understates the corpus.
                state = .refused(.vocabulary("\(error)"))
            }
        case .toolFault(let text):
            state = .refused(VaultRefusal.classify(fault: text))
        case .rpcError(let code, let message):
            state = .refused(.rpcError(code: code, message: message))
        case .transportFailure(let failure):
            // A CANCELLED REQUEST IS NOT A FAULT. SwiftUI tearing down the pane's `.task` returns
            // `URLError -999`, which classifies as a transport failure and drew a red card about a
            // healthy engine — and because this model outlives the view, that card SURVIVED coming
            // back. Same defect `SubstrateScopes.listScopes` records. `.unasked` rather than
            // leaving the old state, so the next `loadIfNeeded` retries instead of latching.
            guard !failure.isCancellation, !Task.isCancelled else {
                // A listing already on screen SURVIVES a cancelled reload — discarding it made the
                // reader lose what they were reading to a navigation they did not think of as
                // destructive. With nothing to keep, fall back to `.idle`, which draws a control
                // rather than a spinner: `.unasked` renders identically to `.loading`, so every
                // dead end reached that way was invisible.
                if case .listed = state { return }
                state = .idle
                return
            }
            state = .refused(.of(failure))
        }
    }

    // MARK: - Uploaded documents, for the Knowledge shelf

    /// The documents this workspace has UPLOADED, as opposed to everything its scope composes.
    ///
    /// TIER 2 AND THE WORKSPACE'S OWN VAULT, which together are exactly what `promote` writes:
    /// `10-reference/<source>/passages/` inside the workspace vault, and `vault._tier_for` reads
    /// `10-reference` as tier 2. Calls are tier 3 conversation-class in `_sources/`; inherited
    /// curated notes come from a DIFFERENT vault. So this needs no new engine concept and no new
    /// frontmatter — the two fields the browse row already carries separate the three.
    ///
    /// Returns an empty list rather than a refusal: this feeds a shelf that also shows locally
    /// imported documents, and a workspace with no engine running should show those rather than an
    /// error where its documents were. The Vault lens is where an engine fault is reported.
    func uploadedDocuments() async -> [VaultDocument] {
        guard let scope = WorkspaceBindings.active.readsScope else { return [] }
        let ownVault = ScriptaVault.slug(AppSettings.activeGroup)
        guard !ownVault.isEmpty else { return [] }

        let request = SubstrateDocumentsRequest(scope: scope, vault: ownVault, limit: Self.pageSize)
        guard case .ok(let payload) = await client.documents(request),
              let documents = try? payload.mappedDocuments() else { return [] }
        return documents.filter(isRemovable)
    }

    /// Whether THIS app may remove the document — the same two fields `uploadedDocuments` selects
    /// on, named once so the shelf and the browser cannot drift apart about it.
    ///
    /// IT GATES THE AFFORDANCE, not just the action. `SubstrateLibraryModel.remove(source:)` already
    /// refuses anything outside the workspace vault's `10-reference/`, so a wrong tap is safe — but
    /// a delete button that refuses is the control this codebase keeps writing cards to apologise
    /// for. An inherited `core-vault` note is not this app's to remove and must not look like it is.
    func isRemovable(_ document: VaultDocument) -> Bool {
        let own = ScriptaVault.slug(AppSettings.activeGroup)
        return !own.isEmpty && document.vault == own && document.tier == 2
    }

    // MARK: - Reading one note

    /// The source directory a promoted document lives in — what `remove(source:)` takes.
    ///
    /// RESOLVED THROUGH `expand`, NOT FROM THE LISTING. `VaultDocument` carries no `source_path`
    /// on purpose: a browse hands back every note in a scope, and every note's absolute path with
    /// it is the operator's whole directory layout in one call. Asking for ONE document by name is
    /// the same rule honoured — and it is only ever asked at the moment the reader acts on that
    /// document.
    ///
    /// Up two components, because `promote` writes `<source>/passages/document.md` and the unit
    /// that is added and removed is `<source>` — the directory holding the note AND its `_meta.md`.
    func sourceDirectory(of document: VaultDocument) async -> URL? {
        guard case .note(let note) = await read(document) else { return nil }
        return URL(fileURLWithPath: note.path)
            .deletingLastPathComponent()
            .deletingLastPathComponent()
    }

    /// The outcome of reading one note. Its own enum rather than a `Result`: `VaultRefusal` is
    /// deliberately not an `Error` — it is a report the surface DRAWS, with its own card, and
    /// making it throwable would invite it being caught and flattened to a string somewhere.
    enum Reading {
        case note(WireNote)
        case refused(VaultRefusal)
    }

    /// The whole note, read from the VAULT rather than from the index — `expand` reads the source
    /// file, so it also reports whether the note has changed since the index was built.
    func read(_ document: VaultDocument) async -> Reading {
        guard let expandRef = document.expandRef else {
            return .refused(.vocabulary(
                "This note has no passages, so there is nothing for the engine to read. It is in "
                + "the corpus — that is why it is in this list — but its file is empty or its text "
                + "could not be extracted."))
        }
        switch await client.expand(SubstrateExpandRequest(expandRef: expandRef, mode: "note")) {
        case .ok(let payload):
            guard let note = payload.note else {
                return .refused(.vocabulary(
                    "The engine returned the passage but not the note behind it."))
            }
            return .note(note)
        case .toolFault(let text):
            return .refused(VaultRefusal.classify(fault: text))
        case .rpcError(let code, let message):
            return .refused(.rpcError(code: code, message: message))
        case .transportFailure(let failure):
            return .refused(.of(failure))
        }
    }
}
