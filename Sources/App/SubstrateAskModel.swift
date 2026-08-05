import Foundation
import SubstrateKit

/// Ask, pointed at a composed substrate scope instead of at the call index.
///
/// ADDITIVE, and the order is the decision (Doc 3 §4). Substrate holds ZERO Scripta transcript
/// content — every composed scope is an Obsidian vault, and `scripta` is this project's own design
/// notes — so this cannot be a swap. Cutting Ask over to the engine would trade working call search
/// for a corpus that cannot answer call questions. `AskModel` keeps the calls on the local index,
/// this keeps the vaults, and the two stores coexist permanently. That is a decision, not a
/// transitional state.
///
/// NOTHING HERE IS RETRIEVAL. Every value the reader sees is one the engine produced or one
/// `SubstrateMapping` derived from it, which is what keeps Doc 3 §6 checkable — an in-app query and
/// the equivalent CLI query must return the same passages, the same capability and the same
/// `index_version` for the same scope, and they can only be compared while this side computes none
/// of the three.
@MainActor
final class SubstrateAskModel: ObservableObject {
    /// One instance, so the chosen brain and the answer on screen survive a pane switch. The Ask
    /// pane is rebuilt every time `HubContent` reselects the section, and a `@State` brain would
    /// silently reset to Calls on the way back — which is the one thing Doc 3 §6 says the reader
    /// must never be wrong about.
    static let shared = SubstrateAskModel()

    /// Which brain the reader is asking.
    ///
    /// Doc 3 §6 makes this the ONE exception to "surface effects, never mechanism". An answer from
    /// the call index and an answer from a vault scope are answers about different corpora, and a
    /// reader who cannot tell which one they asked reads a vault's silence as a fact about their
    /// calls.
    enum Brain: Hashable { case calls, vault }

    enum Answer {
        case idle
        /// A completed search, INCLUDING one that matched nothing.
        ///
        /// Zero passages is an answer and not a failure: the envelope, the filter block and the
        /// index version are all real. The engine already refuses to answer from an empty index for
        /// exactly this reason — "answering from an empty index is indistinguishable from a genuine
        /// no-match" — and collapsing the two back together up here would undo that.
        case answered(Result)
        case refused(VaultRefusal)
    }

    /// One answered query, mapped. Everything on it came off the wire.
    struct Result {
        let scope: String
        let query: String
        /// `v9:2bc0b76971ad` — the fact Doc 3 §6 asks an in-app answer and a CLI answer to agree on.
        let indexVersion: String
        let passages: [Passage]
        let envelope: EngineEnvelope
        let filter: ExclusionFilter
    }

    /// A query in flight. Held beside `answer` rather than as one of its cases so a re-run keeps the
    /// previous answer on screen — a chip tap that blanks the page and then redraws it is how a
    /// reader loses the result they were comparing against.
    struct Running: Equatable {
        let scope: String
        let query: String
        let started: Date
    }

    @Published var brain: Brain = .calls
    @Published var query = ""

    /// The workspace whose binding is on screen. Held so `adoptBinding` can tell a workspace change
    /// from a no-op, and so the unbound copy can name the workspace the operator has to bind.
    @Published private(set) var workspace: String = AppSettings.activeGroup

    /// The vault scope this workspace reads (Doc 3 §7), or `nil` when it is unbound. Never chosen
    /// here — see `adoptBinding`.
    @Published private(set) var scope: String?
    @Published private(set) var answer: Answer = .idle
    @Published private(set) var running: Running?

    /// What the reader asked to see beyond the default corpus. Kept here rather than read back off
    /// the last answer because it is the REQUEST; `Result.filter` is what the engine did with it,
    /// and the two disagreeing is a thing the reader is entitled to see.
    @Published private(set) var includeArchived = false
    @Published private(set) var includeSources = false

    /// The class the reader last asked for that the engine has no argument for. Never silent: see
    /// `include(_:)`.
    @Published private(set) var refusedInclusion: RetrievalClass?

    /// `k`. Deliberately modest — the passage list is read, not scrolled past — and well under the
    /// server's own maximum of 50, so a clamp note in `filters.notes` means something went wrong
    /// here rather than that the reader asked for a lot.
    private static let passageCount = 8

    private let client = SubstrateClient()
    private var task: Task<Void, Never>?

    /// Bumped whenever the visible question changes. An in-flight run captures it and abandons its
    /// writes if it moved, so a reply that arrives after the reader switched scope cannot be
    /// rendered under the new one — the same guard `AskModel` runs for a mid-stream conversation
    /// switch, and needed here for the same reason: a search with the cross-encoder takes seconds.
    private var epoch = 0

    // MARK: - Scopes

    /// The roster itself lives in `SubstrateScopes` — it is a fact about the engine, and the
    /// Library needs the same one. What lives here is which scope THIS WORKSPACE reads, and since
    /// Doc 3 §7 that is not this surface's to choose.
    ///
    /// AUTO-ADOPTION IS GONE, and its removal is the point rather than a side effect. This model
    /// used to take "the first scope with an index" whenever its selection was absent or no longer
    /// listed, which made "which corpus am I asking" a question about ROSTER ORDER. A workspace
    /// called Personal read whichever vault the engine happened to list first, and that scope's
    /// silence about a topic read as a fact about Personal. §7 replaces the choice with a binding:
    /// the workspace names the scope, and an unbound workspace refuses with the remedy named rather
    /// than answering from a corpus nobody chose.

    /// First appearance only. A refused roster stays refused until the reader retries, because
    /// re-listing on every appearance would turn "the engine is not running" into a flicker.
    func activate() async {
        await SubstrateScopes.shared.activate()
        adoptBinding()
    }

    func listScopes() async {
        await SubstrateScopes.shared.listScopes()
        adoptBinding()
    }

    /// Re-read the active workspace's binding. Called on appearance, after a roster listing, and
    /// whenever the workspace changes — switching workspace is a query parameter change, not a
    /// recompose, so it is instant by design (§7).
    func adoptBinding() {
        let bound = WorkspaceBindings.active
        guard bound.workspace != workspace || bound.readsScope != scope else { return }
        workspace = bound.workspace
        scope = bound.readsScope
        refusedInclusion = nil
        answer = .idle
        running = nil
        task?.cancel()
        epoch &+= 1
    }

    /// Whether the bound scope is one the engine still lists. `nil` when the roster has not been
    /// listed yet or there is no binding — absence of a verdict, not a verdict of absence.
    ///
    /// A STALE BINDING IS REPORTED, NEVER REPAIRED. Silently falling back to another scope is the
    /// auto-adoption above, reintroduced through the back door, and it would answer a question
    /// about one corpus out of another without saying so.
    var bindingResolves: Bool? {
        guard let scope else { return nil }
        guard case .listed(let rows) = SubstrateScopes.shared.roster else { return nil }
        return rows.contains { $0.scope == scope }
    }

    /// Bind the ACTIVE WORKSPACE to a scope, and re-ask the standing question against it.
    ///
    /// This is an edit to the binding, not a transient selection, and that is what keeps §7's "the
    /// control that names it is the workspace" true while a scope control still exists on screen.
    /// There is no precedence rule between the two: the workspace picker chooses which binding is
    /// live, this chooses what that binding points at, and the pair answers one question once.
    func bind(scope name: String) {
        guard scope != name else { return }
        // The scope's VAULT PATH is captured here, from the roster, because this is where it is
        // knowable: capture writes the workspace vault's `inherits` off the main actor, where
        // `SubstrateScopes` cannot be reached (Doc 4 §8).
        WorkspaceBindings.bind(workspace, reads: name,
                               vault: SubstrateScopes.shared.rows.first { $0.scope == name }?.vault)
        scope = name
        refusedInclusion = nil
        let standing = standingQuery
        answer = .idle
        if let standing { start(query: standing) }
    }

    // MARK: - Asking

    func search() { start(query: query) }

    /// Cancels the run without touching `answer`. The epoch moves first: a cancelled `URLSession`
    /// call comes back as `.unreachable(code: .cancelled)`, and rendering that would report the
    /// engine as down because the reader pressed Stop.
    func stop() {
        epoch &+= 1
        task?.cancel()
        task = nil
        running = nil
    }

    /// Re-run whatever produced what is on screen — after a filter change, or from a retry control.
    func rerun() {
        guard let standing = standingQuery else { return }
        start(query: standing)
    }

    /// The question the reader is looking at, which is not necessarily the one in the field: a
    /// filter chip re-asks the question that produced these results, not the half-typed one above
    /// them.
    private var standingQuery: String? {
        if case .answered(let result) = answer { return result.query }
        let typed = query.trimmingCharacters(in: .whitespacesAndNewlines)
        return typed.isEmpty ? nil : typed
    }

    private func start(query raw: String) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scope, !text.isEmpty else { return }
        epoch &+= 1
        let token = epoch
        task?.cancel()
        // A refused inclusion is about the result on screen. A new question retires it rather than
        // carrying a note about the old answer onto the next one.
        refusedInclusion = nil
        running = Running(scope: scope, query: text, started: Date())
        task = Task { [weak self] in await self?.run(scope: scope, query: text, token: token) }
    }

    /// The only place a search is issued. `await` here suspends this actor and runs the request on
    /// the client's — nothing below blocks the main actor, which matters because the cross-encoder
    /// arm takes seconds.
    private func run(scope: String, query: String, token: Int) async {
        let request = SubstrateSearchRequest(scope: scope,
                                             query: query,
                                             k: Self.passageCount,
                                             includeArchived: includeArchived,
                                             includeSources: includeSources)
        let call = await client.search(request)
        guard token == epoch, !Task.isCancelled else { return }
        running = nil
        answer = Self.outcome(of: call, scope: scope, query: query)
    }

    private static func outcome(of call: SubstrateCall<WireSearchResult>,
                                scope: String, query: String) -> Answer {
        switch call {
        case .ok(let payload):
            return mapped(payload, scope: scope, query: query)
        case .toolFault(let text):
            return .refused(VaultRefusal.classify(fault: text))
        case .rpcError(let code, let message):
            return .refused(.rpcError(code: code, message: message))
        case .transportFailure(let failure):
            return .refused(.of(failure))
        }
    }

    /// THE WHOLE ANSWER IS REFUSED when one passage speaks a word this build does not know, and
    /// that is `SubstrateMapping`'s stance carried through rather than softened here. Dropping the
    /// offending passage and rendering the other seven would be a result set silently missing the
    /// one row whose vocabulary was new — the failure the refusal exists to prevent, moved one
    /// layer up where it is quieter.
    private static func mapped(_ payload: WireSearchResult,
                               scope: String, query: String) -> Answer {
        do {
            return .answered(Result(scope: scope,
                                    query: query,
                                    indexVersion: payload.indexVersion,
                                    passages: try payload.passages.map { try $0.mapped() },
                                    envelope: try payload.mappedEnvelope(),
                                    filter: try payload.mappedFilter()))
        } catch let refusal as SubstrateMappingRefusal {
            return .refused(.vocabulary(refusal.description))
        } catch {
            return .refused(.vocabulary("\(error)"))
        }
    }

    // MARK: - What was withheld

    /// The include control `ExclusionBar` offers, mapped onto what `search` actually accepts.
    ///
    /// THREE OF THE FIVE CLASSES HAVE NO ARGUMENT, and none of the three is an oversight on this
    /// side. The tool takes `include_archived` and `include_sources` and nothing else: `superseded`
    /// is refused deliberately — the tool's own schema calls those "dead facts, surfaced only as the
    /// `supersedes` link on their replacement" — and `active`/`complete` ARE default retrieval, so
    /// there is nothing to switch off.
    ///
    /// A tap on one of those three therefore SAYS SO. A chip that quietly ignores a click is how a
    /// reader concludes they opened up a class they did not, which is the same wrong conclusion the
    /// whole disclosure exists to prevent — reached through the control instead of through the copy.
    func include(_ klass: RetrievalClass) {
        switch klass {
        case .archived:
            includeArchived.toggle()
        case .sources:
            includeSources.toggle()
        case .superseded, .active, .complete:
            refusedInclusion = klass
            return
        }
        refusedInclusion = nil
        rerun()
    }

    /// What to say when the engine has no argument for a class. Worded per class because the two
    /// reasons are genuinely different, and a single "cannot be included" would let a reader assume
    /// the same thing about both.
    static func refusalSentence(for klass: RetrievalClass) -> String {
        switch klass {
        case .superseded:
            return "Superseded notes cannot be included. The engine holds them as dead facts and "
                + "surfaces them only as the supersedes link on the note that replaced them — so "
                + "their absence here is not evidence they do not exist."
        case .active, .complete:
            return "\(klass.gloss.capitalized) are what default retrieval searches. There is no "
                + "argument to withhold them, so this chip reports the default rather than "
                + "offering a switch."
        case .archived, .sources:
            return ""
        }
    }
}
