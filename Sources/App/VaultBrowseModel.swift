import Foundation
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

    enum State {
        /// Nothing asked yet — the pane has not been opened, or the workspace just changed.
        case unasked
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
        /// vault filter is for.
        var vaults: [String] {
            var seen = Set<String>(), order: [String] = []
            for document in documents where !document.vault.isEmpty {
                if seen.insert(document.vault).inserted { order.append(document.vault) }
            }
            return order
        }
    }

    @Published private(set) var state: State = .unasked

    /// Show only notes from this vault, or all of them. A view filter over what was fetched, NOT a
    /// re-query: the whole page is already here, and asking the engine again to hide rows would
    /// spend a round trip to show less.
    @Published var vaultFilter: String?

    /// Include the notes the engine withholds by default — archived, superseded, and the
    /// conversation class that every captured call is. OFF by default, matching Ask, so browse and
    /// query never disagree about what is in the vault unless the operator asks them to.
    @Published var showsWithheld = false {
        didSet { guard oldValue != showsWithheld else { return }; Task { await load() } }
    }

    /// One page. The engine clamps at 1000 and reports a clamp in `filters.notes`; this asks for the
    /// clamp rather than paging, because a vault that has outgrown one page is a real product
    /// question and a silently truncated list is not the way to discover it.
    private static let pageSize = 1000

    private let client = SubstrateClient(timeout: 30)
    private var loadedScope: String?
    private var generation = 0

    // MARK: - Lifecycle

    /// Re-read the active workspace's binding. Called when the workspace changes, exactly as the
    /// Ask and Library models are — a browser still showing the previous workspace's corpus is the
    /// privacy partition leaking, not a stale view.
    func adoptWorkspace() {
        let scope = WorkspaceBindings.active.readsScope
        guard scope != loadedScope else { return }
        loadedScope = scope
        vaultFilter = nil
        state = .unasked
    }

    /// Load if nothing has been loaded yet. The pane's `.task` calls this, so navigating back to it
    /// does not re-fetch a list that is already on screen.
    func loadIfNeeded() async {
        if case .unasked = state { await load() }
    }

    func load() async {
        guard let scope = WorkspaceBindings.active.readsScope else {
            loadedScope = nil
            state = .unbound
            return
        }
        loadedScope = scope
        generation &+= 1
        let mine = generation
        state = .loading

        let request = SubstrateDocumentsRequest(scope: scope,
                                                includeArchived: showsWithheld,
                                                includeSources: showsWithheld,
                                                limit: Self.pageSize)
        let outcome = await client.documents(request)
        // A workspace switched mid-flight must not have the old scope's corpus land on it.
        guard mine == generation else { return }

        switch outcome {
        case .ok(let payload):
            do {
                state = .listed(Listing(scope: scope,
                                        documents: try payload.mappedDocuments(),
                                        total: payload.total,
                                        filters: try payload.filters.mapped(),
                                        refresh: payload.refresh))
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
            state = .refused(.of(failure))
        }
    }

    // MARK: - Reading one note

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
