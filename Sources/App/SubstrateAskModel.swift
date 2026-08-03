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

    /// The scope list, and its own failure modes — which are NOT the query's.
    ///
    /// Separate from `Answer` on purpose: the engine can be down before a question is ever asked,
    /// and that is the state a fresh machine is in. Merging the two would make "the engine is not
    /// running" reachable only by asking a question first, which is the wrong order to learn it in.
    enum Roster {
        case unasked
        case listing
        /// The rows verbatim, faults included. `scopes_payload` lists a scope whose inheritance no
        /// longer resolves WITH its error rather than omitting it, because an omitted scope reads
        /// as one that was never composed — so this keeps every row it was handed.
        case listed([WireScopeRow])
        case refused(VaultRefusal)

        var isListed: Bool {
            if case .listed = self { return true }
            return false
        }
    }

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
    @Published private(set) var roster: Roster = .unasked
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

    /// First appearance only. A refused roster stays refused until the reader retries, because
    /// re-listing on every appearance would turn "the engine is not running" into a flicker.
    func activate() async {
        guard case .unasked = roster else { return }
        await listScopes()
    }

    func listScopes() async {
        // A roster that is already on screen stays there while it refreshes. This call is reachable
        // from the bar's own scope segment, and dropping to `.listing` would blank the answer the
        // reader was looking at in order to re-fetch a list of seven names.
        if !roster.isListed { roster = .listing }
        let call = await client.listScopes()
        switch call {
        case .ok(let list):
            roster = .listed(list.scopes)
            adoptScope(from: list.scopes)
        case .toolFault(let text):
            roster = .refused(VaultRefusal.classify(fault: text))
        case .rpcError(let code, let message):
            roster = .refused(.rpcError(code: code, message: message))
        case .transportFailure(let failure):
            // CANCELLATION IS NOT A REFUSAL, and this is the one path where that mattered without
            // being guarded. `listScopes` runs under SwiftUI's `.task`, which cancels itself when
            // the view goes away — tapping the Calls chip, or leaving Ask entirely. A cancelled
            // URLSession comes back as URLError -999, which no refusal case recognises, so it fell
            // to the transport arm and drew `Ink.danger`: "the engine answered, but not with a
            // JSON-RPC response", about an engine that is running perfectly.
            //
            // Worse than a wrong frame: `activate()` only re-lists from `.unasked`, and this model
            // outlives the view, so the red card SURVIVED coming back to the vault brain and sat
            // there until someone pressed Try again.
            //
            // `stop()` already writes this rule down for the search path — "rendering that would
            // report the engine as down because the reader pressed Stop" — and `run()` honours it
            // with an epoch-and-cancellation guard. The roster had neither. Returning to `.unasked`
            // rather than to a refusal is what makes the next `activate()` retry instead of
            // inheriting a verdict about an event that never happened.
            if failure.isCancellation || Task.isCancelled {
                roster = .unasked
                return
            }
            roster = .refused(.of(failure))
        }
    }

    /// Keeps the selection if the engine still lists it, otherwise takes the first scope that can
    /// actually answer. A scope with no index or a broken inheritance stays SELECTABLE — the reader
    /// has to be able to look at it to find out what is wrong with it — it is just not the one we
    /// land on unasked.
    private func adoptScope(from rows: [WireScopeRow]) {
        if let scope, rows.contains(where: { $0.scope == scope }) { return }
        scope = rows.first(where: { $0.indexPresent && $0.error == nil })?.scope ?? rows.first?.scope
        answer = .idle
    }

    /// Ask the other brain. Re-runs the standing question, which is the whole gesture: the same
    /// words against a different corpus is how a reader finds out that an absence was the scope's
    /// and not the world's.
    func select(scope name: String) {
        guard scope != name else { return }
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
