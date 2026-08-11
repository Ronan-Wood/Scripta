import Foundation
import ScriptaCore   // IndexStore, for the operator's own vocabulary glosses
import SubstrateKit

/// Ask. One of them (Doc 4 §2).
///
/// THERE WAS A SECOND ONE AND IT IS GONE. Doc 3 §4 ratified two — Clovis over the local call index,
/// this over composed scopes — on the premise that "substrate holds ZERO Scripta transcript
/// content". Doc 4 §7 withdrew the premise rather than the conclusion: capture now writes calls
/// INTO the workspace vault, so one scope holds the calls AND the curated notes AND the uploaded
/// documents, and the two-brain selector was asking the reader to choose between two halves of one
/// corpus. What survived from Clovis is generation, streaming and persisted conversations; what
/// survived from here is the disclosure contract, the scope binding and the five refusals.
///
/// THE DIRECTION RULE IS THE WHOLE MERGE, and Doc 4 §2 states it because it is easy to get
/// backwards: **`ContextChunk` → `Passage`, never the reverse.** A `Passage` carries `status`,
/// `doc_type`, `confidence`, `document_class`, `vault` and `supersedes`; a `ContextChunk` carries
/// none of them. Converting the other way to reuse Clovis's existing generation path would have
/// been the shorter diff and would have dropped the spine on the way — so generation consumes
/// passages, and `Retriever.context` has no caller left here.
///
/// NOTHING HERE IS RETRIEVAL. Every value the reader sees is one the engine produced or one
/// `SubstrateMapping` derived from it, which is what keeps Doc 3 §6 checkable — an in-app query and
/// the equivalent CLI query must return the same passages, the same capability and the same
/// `index_version` for the same scope, and they can only be compared while this side computes none
/// of the three.
///
/// WHAT WAS DELETED RATHER THAN PORTED: `Grounding`, Clovis's strong/moderate/thin badge. It was
/// computed from `chunks.filter { !$0.isTopic }.count` and a retrieval fallback flag, and NEITHER
/// input exists on this path. Carrying the label across would have meant inventing a new heuristic
/// under a name calibrated for a different one — PRINCIPLES' fourth law exactly. `EngineBar` says
/// what actually ran and what it measured, which is the honest version of the same question.
@MainActor
final class AskModel: ObservableObject {
    /// One instance, so the thread and the bound scope survive a pane switch. The Ask pane is
    /// rebuilt every time `HubContent` reselects the section, and `@State` would drop both.
    static let shared = AskModel()

    /// What became of the most recent run. The THREAD is `messages`; this is the state of the last
    /// attempt at adding to it, which is not the same object — a refusal is not a turn.
    enum Answer {
        case idle
        /// A completed search, INCLUDING one that matched nothing.
        ///
        /// Zero passages is an answer and not a failure: the envelope, the filter block and the
        /// index version are all real. The engine already refuses to answer from an empty index for
        /// exactly this reason — "answering from an empty index is indistinguishable from a genuine
        /// no-match" — and collapsing the two back together up here would undo that.
        case answered
        case refused(VaultRefusal)
    }

    /// The envelope and the applied filters for ONE answered turn.
    ///
    /// LIVE-SESSION ONLY, and the absence on restored history is deliberate rather than an omission
    /// to fix later. `EngineEnvelope` describes a run — which arms fired, the measured tier, the
    /// refresh verdict — and none of that stays true across a relaunch. Persisting it would put a
    /// stale claim about a stack under an answer, which is the failure the envelope exists to
    /// prevent, arriving through the history pane. What IS persisted per answer is `index_version`,
    /// because that is a fact about the index the answer came off and remains one.
    struct TurnDisclosure {
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
        /// WHICH HALF IS RUNNING, and it is held through BOTH. `running` used to be cleared the
        /// moment retrieval returned, which put Stop — the app's only wiring of `stop()`, drawn
        /// inside the run strip — out of reach for the whole of generation. That is the longest
        /// phase and the one that can actually hang, so the control documented as "the answer to a
        /// spinner that never resolves" was absent from exactly the state that produces one.
        var phase: Phase = .retrieving

        enum Phase { case retrieving, answering }
    }

    @Published var query = ""

    // MARK: - The thread

    @Published private(set) var conversations: [AskConversation] = []
    @Published private(set) var currentID: UUID?
    @Published private(set) var messages: [AskMessage] = []
    /// Set while a generator is producing an answer and no token has arrived yet.
    @Published private(set) var thinking = false
    /// Per-turn disclosure for answers produced in THIS session — see `TurnDisclosure`.
    @Published private(set) var disclosures: [UUID: TurnDisclosure] = [:]

    /// Bumped whenever `messages` is swapped to another conversation or workspace, and whenever a
    /// run is abandoned. An in-flight `send()` captures it and abandons its writes if it moved, so a
    /// mid-stream switch cannot stream into — or persist into — the wrong conversation (audit H3),
    /// and a reply that arrives after the reader changed scope cannot be rendered under the new one.
    private var epoch = 0

    /// The workspace `messages` currently belong to (nil until the first `activate`). Tracked so a
    /// workspace switch flushes the OUTGOING conversation under its own name — `AppSettings`
    /// has already advanced to the destination by the time `adoptBinding` runs (audit H3,
    /// invariant 5).
    private var loadedWorkspace: String?

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

    /// ON BY DEFAULT IN THIS APP, and the default is the whole argument.
    ///
    /// The engine withholds `conversation`-class notes from default retrieval because a passage cut
    /// out of a transcript misrepresents it — confidence varies WITHIN a conversation, and a
    /// mid-call sentence may be reasoning the speaker abandoned ten minutes later. That is right for
    /// a shared corpus of curated notes, and it is exactly wrong here: Scripta records calls, its
    /// calls ARE conversation-class, and a reader asking this app about a call they just had was
    /// getting the engine's polite silence about the one document they meant.
    ///
    /// The withholding is not lost, only re-defaulted: the exclusion bar still reports that sources
    /// are included and still toggles them off, so a reader who wants the curated layer alone can
    /// have it — and knows they asked.
    @Published private(set) var includeSources = true

    /// The class the reader last asked for that the engine has no argument for. Never silent: see
    /// `include(_:)`.
    @Published private(set) var refusedInclusion: RetrievalClass?

    /// What the NEXT question will ask for, as the disclosure bar draws it.
    ///
    /// THE REQUEST, NOT THE RESULT, and keeping the two apart is the point of building it here.
    /// `TurnDisclosure.filter` is what the engine reports it actually applied, and the two
    /// disagreeing — a guard withholding a vault nobody deselected — is a thing the reader is
    /// entitled to see. Derived from the two toggles rather than stored, so it cannot drift from
    /// what `run` will actually send.
    var requestedFilter: ExclusionFilter {
        var searched = ExclusionFilter.defaultClasses
        if includeArchived { searched.insert(.archived) }
        if includeSources { searched.insert(.sources) }
        return ExclusionFilter(searched: searched)
    }

    /// Which tiers of the composed chain to ask. EMPTY MEANS ALL, and that is the only encoding
    /// that behaves: a scope inherits, the set of vaults is discovered from the roster rather than
    /// chosen here, and a reader who has selected nothing means "do not narrow" — not "return
    /// nothing", which is what an empty list would tell the engine and what the engine refuses.
    @Published private(set) var selectedVaults: Set<String> = []

    /// The scope's composed chain, newest tier last, as the engine resolved it. Read off the roster
    /// rather than derived from an answer's passages: the answer only names vaults that MATCHED, so
    /// a chip row built from it would lose a tier the moment it stopped being relevant — and the
    /// reader would not know it had ever been askable.
    var vaultChain: [String] {
        guard let scope, case .listed(let rows) = SubstrateScopes.shared.roster,
              let row = rows.first(where: { $0.scope == scope }) else { return [] }
        return row.sources ?? []
    }

    /// Narrow to one tier, or widen back. A second tap on the only selected chip clears the filter,
    /// which is what makes "all" reachable without a separate control.
    ///
    /// IT DOES NOT RE-ASK, and that changed with the merge. These controls used to rewrite the one
    /// result on screen; a thread has turns, and silently re-running would replace an answer with
    /// one generated over a different corpus while the question above it stayed the same. They
    /// describe the NEXT question now — see `rerun`.
    func toggleVault(_ vault: String) {
        if selectedVaults.contains(vault) {
            selectedVaults.remove(vault)
        } else {
            selectedVaults.insert(vault)
        }
    }

    func clearVaultFilter() {
        guard !selectedVaults.isEmpty else { return }
        selectedVaults.removeAll()
    }

    /// `k`. Deliberately modest — the passage list is read, not scrolled past — and well under the
    /// server's own maximum of 50, so a clamp note in `filters.notes` means something went wrong
    /// here rather than that the reader asked for a lot.
    private static let passageCount = 8

    private let client = SubstrateClient()
    private var task: Task<Void, Never>?

    /// The generator, resolved once per conversation (multi-turn history lives inside the chat).
    private var chat: ChatConversing?
    private var sizeClass: SizeClass = .compact
    private var engineLabel: String?
    private var usingEndpoint = false

    init() {
        conversations = Self.load()
        pruneExpiredConversations()
        // BOUND AT INIT, NOT ON THE PANE'S APPEARANCE. `adoptBinding` reads only `AppSettings`,
        // `WorkspaceBindings` and the store on disk — it needs no engine — but it used to be
        // reachable only from `activate()`, which `VaultRoster` calls under `case .serving`. So
        // until someone opened Ask AND the engine was up, `scope`, `messages` and `loadedWorkspace`
        // were all unset. That was invisible while this model backed one pane; it stopped being
        // invisible when the Clovis drawer started sharing it, because the drawer is reachable from
        // the title bar on every screen and showed an empty thread with a live send button that
        // did nothing.
        adoptBinding()
    }

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
        let workspaceChanged = bound.workspace != workspace || loadedWorkspace == nil
        guard workspaceChanged || bound.readsScope != scope else { return }
        // FLUSHED UNDER ITS OWN NAME, before `workspace` advances. The outgoing thread belongs to
        // the workspace it was typed in, and writing it after the switch files a private
        // conversation under the destination — the privacy wall applies to chat history too.
        if workspaceChanged { syncCurrent(into: loadedWorkspace ?? workspace) }
        workspace = bound.workspace
        scope = bound.readsScope
        refusedInclusion = nil
        // A NEW SCOPE HAS A NEW CHAIN. Carrying a selection naming the old scope's vaults would ask
        // for tiers this one does not compose — which the engine answers with nothing, correctly,
        // and the reader would read as an empty corpus.
        selectedVaults.removeAll()
        answer = .idle
        running = nil
        thinking = false
        task?.cancel()
        epoch &+= 1
        if workspaceChanged { loadThread(for: bound.workspace) }
    }

    // MARK: - Conversations (persisted, workspace-scoped)

    /// Conversations belonging to one workspace, newest first.
    func conversations(in workspace: String) -> [AskConversation] {
        conversations.filter { $0.workspace == workspace }.sorted { $0.created > $1.created }
    }

    /// Resume this workspace's latest thread, or start empty.
    private func loadThread(for workspace: String) {
        if let latest = conversations(in: workspace).first {
            currentID = latest.id
            messages = latest.messages
        } else {
            currentID = nil
            messages = []
        }
        // A FRESH MODEL SESSION. The transcript above is display history; replaying it into a new
        // chat would double every turn the generator already holds.
        chat = nil
        disclosures.removeAll()
        loadedWorkspace = workspace
    }

    func select(_ id: UUID) {
        guard id != currentID else { return }
        syncCurrent(into: workspace)
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        epoch &+= 1   // only after we know we are actually reassigning `messages`
        thinking = false
        running = nil
        task?.cancel()
        currentID = conversation.id
        messages = conversation.messages
        disclosures.removeAll()
        answer = .idle
        chat = nil
    }

    func newConversation() {
        epoch &+= 1
        thinking = false
        running = nil
        task?.cancel()
        syncCurrent(into: workspace)
        currentID = nil
        messages = []
        disclosures.removeAll()
        answer = .idle
        query = ""
        chat = nil
    }

    func delete(_ id: UUID) {
        conversations.removeAll { $0.id == id }
        if currentID == id {
            epoch &+= 1
            thinking = false
            running = nil
            task?.cancel()
            answer = .idle
            currentID = conversations(in: workspace).first?.id
            messages = conversations.first(where: { $0.id == currentID })?.messages ?? []
            disclosures.removeAll()
            chat = nil
        }
        Self.save(conversations)
    }

    /// Drops conversations older than the user's retention window (Settings). 0 = keep forever.
    /// `nowProvider` is injectable for tests; the app passes the real clock.
    func pruneExpiredConversations(now: Date = Date()) {
        let days = AppSettings.conversationRetentionDays
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let before = conversations.count
        conversations.removeAll { $0.created < cutoff }
        if conversations.count != before {
            if !conversations.contains(where: { $0.id == currentID }) {
                // Clear the model session and workspace too, or a later `adoptBinding` for the same
                // workspace early-returns on the stale `loadedWorkspace` and keeps the pruned
                // conversation's `chat` context.
                //
                // AND THE RUN, which this was the only epoch-bumping path to forget. Bumping the
                // epoch abandons an in-flight run's WRITES but does not stop it or clear `running`,
                // and `running == nil` gates `start()` and both send buttons — so a prune landing
                // mid-question left Ask permanently unable to ask anything, with a run strip
                // spinning on a query whose results are already being discarded.
                currentID = nil; messages = []; epoch &+= 1; loadedWorkspace = nil
                task?.cancel(); task = nil; running = nil
                chat = nil; thinking = false; disclosures.removeAll(); answer = .idle
            }
            Self.save(conversations)
        }
    }

    /// Writes the working transcript back into its conversation (creating one on first use) and
    /// persists. Cheap: called on send completion and thread switches.
    private func syncCurrent(into workspace: String) {
        defer { Self.save(conversations) }
        guard !messages.isEmpty else { return }
        if let index = conversations.firstIndex(where: { $0.id == currentID }) {
            conversations[index].messages = messages
            return
        }
        var conversation = AskConversation(workspace: workspace, messages: messages)
        if let first = messages.first(where: { $0.fromUser })?.text {
            conversation.title = String(first.prefix(44))
        }
        conversations.insert(conversation, at: 0)
        currentID = conversation.id
    }

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scripta", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.json")
    }

    private static func load() -> [AskConversation] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        return (try? JSONDecoder().decode([AskConversation].self, from: data)) ?? []
    }

    private static func save(_ conversations: [AskConversation]) {
        if let data = try? JSONEncoder().encode(conversations) {
            try? data.write(to: storeURL, options: .atomic)
        }
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

    /// Point the ACTIVE WORKSPACE at a different scope. It does NOT ask anything — see below.
    ///
    /// This is an edit to the binding, not a transient selection, and that is what keeps §7's "the
    /// control that names it is the workspace" true while a scope control still exists on screen.
    /// There is no precedence rule between the two: the workspace picker chooses which binding is
    /// live, and this chooses what that binding points at.
    func bind(scope name: String) {
        guard scope != name else { return }
        // The scope's VAULT PATH is captured here, from the roster, because this is where it is
        // knowable: capture writes the workspace vault's `inherits` off the main actor, where
        // `SubstrateScopes` cannot be reached (Doc 4 §8).
        WorkspaceBindings.bind(workspace, reads: name,
                               vault: SubstrateScopes.shared.rows.first { $0.scope == name }?.vault)
        scope = name
        refusedInclusion = nil
        answer = .idle
        // FENCED, exactly as `adoptBinding` fences a workspace change. Rebinding is the OTHER door
        // onto the same fact, and leaving the epoch alone let a run started against the previous
        // scope survive its own guard and append — an answer generated over `cbre` landing on the
        // thread while every control on screen said `prism`, permanently, because a turn records
        // its `index_version` and not its scope. That is the one axis Doc 3 §6 says the reader must
        // never be wrong about.
        running = nil
        thinking = false
        task?.cancel()
        epoch &+= 1
        // THE GENERATOR SESSION GOES TOO, and it was the one thing this fence forgot. `chat` holds
        // every prior prompt — each carrying that scope's whole expanded `Context:` block — so a
        // session carried across a rebind lets the model answer out of the OLD corpus while every
        // control on screen names the new one. Fencing the epoch stops a stale REPLY landing;
        // without this, the next reply is generated from stale MATERIAL, which nothing on screen
        // could reveal. Every other thread and scope transition here clears it; this was the one
        // that did not.
        chat = nil
        // A NEW SCOPE HAS A NEW CHAIN — the same reason `adoptBinding` clears it. A selection naming
        // the old scope's vaults asks this one for tiers it does not compose, which the engine
        // answers with nothing and the reader reads as an empty corpus. Worse here than there: no
        // chip renders selected, so the narrowing is invisible while it is being applied.
        selectedVaults.removeAll()
    }

    // MARK: - Asking

    /// Ask what is in the field. One turn: retrieve, then answer over what came back.
    func send() { start(query: query, clearField: true) }

    /// Cancels the run without touching the thread. The epoch moves first: a cancelled
    /// `URLSession` call comes back as `.unreachable(code: .cancelled)`, and rendering that would
    /// report the engine as down because the reader pressed Stop.
    func stop() {
        // Read BEFORE the flags are cleared: `finishInterruptedTurn` must not touch a completed
        // answer, and "was something running" is the only thing that tells the two apart.
        let wasRunning = running != nil || thinking
        epoch &+= 1
        task?.cancel()
        task = nil
        running = nil
        thinking = false
        guard wasRunning else { return }
        finishInterruptedTurn()
    }

    /// What Stop leaves behind, which used to be nothing.
    ///
    /// THE EPOCH BUMP IS WHY THIS IS NEEDED. Stopping moves the epoch, so `run` returns at its next
    /// guard — before the interrupted marker, before `syncCurrent`. The turn was therefore left
    /// exactly as the stream had got to: partial text with nothing saying it was cut, or an empty
    /// bubble if no token had arrived, and the next successful turn persisted both to disk. A
    /// truncated answer that reads as a complete one is the failure this project keeps naming — an
    /// output missing its conditions is indistinguishable from one that had none.
    ///
    /// Two outcomes because there are two states: text that exists is KEPT and marked, because the
    /// reader may want it; text that never arrived is REMOVED, because an empty bubble is not a
    /// partial answer, it is a claim that the model replied with nothing.
    private func finishInterruptedTurn() {
        switch InterruptedTurn.close(&messages, marker: Self.stoppedMarker) {
        case .nothingToClose:
            return
        case .removed(let id):
            disclosures.removeValue(forKey: id)
        case .marked:
            break
        }
        syncCurrent(into: workspace)
    }

    static let stoppedMarker = "\n\n_(Stopped — send again to retry.)_"

    /// Re-ask the last question — from the retry control on a refusal.
    ///
    /// A RE-ASK IS A NEW TURN, never an edit to an old one. A filter change that rewrote the answer
    /// above it would make the transcript disagree with what actually ran: each answered turn
    /// records the passages and the disclosure of the run that produced it, and a record that is
    /// mutated by a later control is not a record. This is also why `includeArchived`, the tier
    /// chips and `includeSources` no longer re-run on toggle — they describe the NEXT question.
    func rerun() {
        // REUSES THE TURN rather than asking again underneath it. A refusal leaves the question as
        // the last thing on the thread with nothing under it, so appending a second copy of it
        // would make the transcript read as though the reader asked twice.
        guard let last = messages.last, last.fromUser else { return }
        start(query: last.text, clearField: false, reusingTurn: true)
    }

    private func start(query raw: String, clearField: Bool, reusingTurn: Bool = false) {
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let scope, !text.isEmpty, !thinking, running == nil else { return }
        if clearField { query = "" }
        epoch &+= 1
        let token = epoch
        task?.cancel()
        // A refused inclusion is about the answer on screen. A new question retires it rather than
        // carrying a note about the old one onto the next.
        refusedInclusion = nil
        answer = .idle
        if !reusingTurn { messages.append(AskMessage(fromUser: true, text: text)) }
        running = Running(scope: scope, query: text, started: Date())
        task = Task { [weak self] in await self?.run(scope: scope, query: text, token: token) }
    }

    /// One turn, end to end. `await` suspends this actor and runs each request on the client's —
    /// nothing below blocks the main actor, which matters because the cross-encoder arm takes
    /// seconds and generation takes more.
    private func run(scope: String, query: String, token: Int) async {
        let request = SubstrateSearchRequest(scope: scope,
                                             query: query,
                                             k: Self.passageCount,
                                             includeArchived: includeArchived,
                                             includeSources: includeSources,
                                             // `nil`, never `[]` — the engine refuses an empty
                                             // list rather than widening, and "nothing selected"
                                             // means every vault here.
                                             vaults: selectedVaults.isEmpty
                                                 ? nil : selectedVaults.sorted())
        let call = await client.search(request)
        guard token == epoch, !Task.isCancelled else { return }

        let retrieved: Retrieved
        switch Self.outcome(of: call) {
        case .failure(let refusal):
            running = nil
            answer = .refused(refusal)
            syncCurrent(into: workspace)
            return
        case .success(let value):
            retrieved = value
        }

        // A HEALTHY ANSWER WITH NOTHING IN IT is not a failure and does not get a generated turn:
        // spending an inference on an empty context is how a source-less sentence gets written.
        guard !retrieved.passages.isEmpty else {
            running = nil
            answer = .answered
            append(answer: Self.nothingMatched(scope: scope),
                   passages: [], retrieved: retrieved, label: nil)
            return
        }

        // CHECKED BEFORE EXPANDING, not after: with no generator there is nothing to feed, and k
        // expand round trips whose only consumer is a prompt nobody will build is work done to
        // produce a value that is discarded.
        guard available else {
            // RETRIEVAL WORKED AND GENERATION DID NOT, and those are separately reportable now that
            // one is the engine's and the other is the device's. The passages are real and are
            // shown; only the sentence over them is missing.
            running = nil
            answer = .answered
            append(answer: Self.generationUnavailable(), passages: retrieved.passages,
                   retrieved: retrieved, label: nil)
            return
        }

        // FULL TEXT, NOT SNIPPETS. `search` returns a cut snippet and says so (`truncated`);
        // generating over ~200 characters a passage would ground the answer in the part of the note
        // that happened to match rather than in what it says. Expanded concurrently, so k round
        // trips cost about one.
        let texts = await expand(retrieved.passages)
        guard token == epoch, !Task.isCancelled else { return }
        answer = .answered
        running?.phase = .answering

        ensureChat()
        let prompt = Self.prompt(question: query, passages: retrieved.passages, texts: texts,
                                 charCap: PromptCatalog.enrichCharCap(sizeClass),
                                 glossary: Self.glossary(question: query,
                                                         passages: retrieved.passages,
                                                         texts: texts, workspace: workspace))
        let index = messages.count
        thinking = true
        // THE CITATIONS GO ON AT BIRTH, not after the stream finishes. They are a property of the
        // RETRIEVAL, not of whether generation completed — and assigning them afterwards meant every
        // early return (a thread switch mid-stream, which `select` persists BEFORE it bumps the
        // epoch) wrote a half-finished answer to disk carrying `passages: []` and
        // `citationsNotCarried: false`. That renders identically to an answer that genuinely stood
        // on nothing, which is the exact conflation that flag exists to prevent.
        messages.append(AskMessage(fromUser: false, text: "",
                                   passages: retrieved.passages.map(StoredPassage.init),
                                   engineLabel: engineLabel,
                                   indexVersion: retrieved.indexVersion))
        record(disclosure: retrieved, for: messages[index].id)
        let firstAnswer = messages.filter { !$0.fromUser && !$0.text.isEmpty }.isEmpty

        do {
            try await stream(prompt, into: index, token: token)
        } catch {
            guard token == epoch, index < messages.count else { return }
            // First message → fall back to Apple FM with a notice, and the answer still arrives.
            // Mid-conversation → no silent swap: keep the partial text, hint at retry.
            if firstAnswer && usingEndpoint {
                resetToAppleFM()
                messages[index].text = ""
                messages[index].engineLabel = engineLabel
                do {
                    try await stream(prompt, into: index, token: token)
                } catch {
                    guard token == epoch, index < messages.count else { return }
                    messages[index].text = Self.errorText(error)
                }
            } else if messages[index].text.isEmpty {
                messages[index].text = Self.errorText(error)
            } else {
                messages[index].text += "\n\n_(Interrupted — send again to retry.)_"
            }
        }
        guard token == epoch else { return }
        thinking = false
        running = nil
        syncCurrent(into: workspace)
    }

    /// Whether a generator is available at all — the endpoint assigned to Ask, or Apple Intelligence.
    var available: Bool { EngineRouter.usesEndpoint(for: .ask) || TranscriptEnricher.isAvailable }

    /// One answered search, mapped. Everything on it came off the wire.
    struct Retrieved {
        let indexVersion: String
        let passages: [Passage]
        let envelope: EngineEnvelope
        let filter: ExclusionFilter
    }

    private enum Outcome {
        case success(Retrieved)
        case failure(VaultRefusal)
    }

    private static func outcome(of call: SubstrateCall<WireSearchResult>) -> Outcome {
        switch call {
        case .ok(let payload):
            return mapped(payload)
        case .toolFault(let text):
            return .failure(VaultRefusal.classify(fault: text))
        case .rpcError(let code, let message):
            return .failure(.rpcError(code: code, message: message))
        case .transportFailure(let failure):
            return .failure(.of(failure))
        }
    }

    /// THE WHOLE ANSWER IS REFUSED when one passage speaks a word this build does not know, and
    /// that is `SubstrateMapping`'s stance carried through rather than softened here. Dropping the
    /// offending passage and rendering the other seven would be a result set silently missing the
    /// one row whose vocabulary was new — the failure the refusal exists to prevent, moved one
    /// layer up where it is quieter. It matters more now than it did: the surviving passages would
    /// also be the ones an ANSWER got written over.
    private static func mapped(_ payload: WireSearchResult) -> Outcome {
        do {
            return .success(Retrieved(indexVersion: payload.indexVersion,
                                      passages: try payload.passages.map { try $0.mapped() },
                                      envelope: try payload.mappedEnvelope(),
                                      filter: try payload.mappedFilter()))
        } catch let refusal as SubstrateMappingRefusal {
            return .failure(.vocabulary(refusal.description))
        } catch {
            return .failure(.vocabulary("\(error)"))
        }
    }

    /// Full text per passage, keyed by `Passage.id` (which IS the expand ref). A passage whose
    /// expansion fails keeps its snippet rather than dropping out of the context: a citation shown
    /// on screen that the generator never saw would be the disclosure lying in the other direction.
    private func expand(_ passages: [Passage]) async -> [String: String] {
        let client = self.client
        return await withTaskGroup(of: (String, String?).self) { group in
            for passage in passages {
                group.addTask {
                    let call = await client.expand(
                        SubstrateExpandRequest(expandRef: passage.id, mode: "passage"))
                    guard case .ok(let payload) = call else { return (passage.id, nil) }
                    return (passage.id, payload.passage.text)
                }
            }
            var texts: [String: String] = [:]
            for await (id, text) in group {
                if let text { texts[id] = text }
            }
            return texts
        }
    }

    // MARK: - Generation

    /// Resolves the Ask engine once per conversation (multi-turn history lives inside the chat).
    private func ensureChat() {
        guard chat == nil else { return }
        let engine = EngineRouter.chatEngine(for: .ask)
        sizeClass = engine.sizeClass
        engineLabel = engine.label
        usingEndpoint = EngineRouter.usesEndpoint(for: .ask)
        chat = engine.makeChat(instructions: PromptCatalog.askInstructions(sizeClass))
    }

    private func resetToAppleFM() {
        let engine = AppleFMEngine()
        sizeClass = engine.sizeClass
        engineLabel = "\(engine.label) (fallback)"
        usingEndpoint = false
        chat = engine.makeChat(instructions: PromptCatalog.askInstructions(sizeClass))
    }

    /// Streams cumulative snapshots into the placeholder so tokens appear as they generate. After
    /// every `await`, re-check the token before touching `messages[index]`: a mid-stream thread or
    /// workspace switch reassigns `messages`, so a stale index write would corrupt (and persist
    /// into) the wrong conversation — or crash out of bounds (audit H3).
    private func stream(_ prompt: String, into index: Int, token: Int) async throws {
        for try await snapshot in chat!.stream(prompt) {
            guard token == epoch, index < messages.count else { return }
            messages[index].text = snapshot
            thinking = false   // the first token has arrived
        }
    }

    /// The context block, built from PASSAGES. Each one is labelled with its citation and its
    /// spine, because "this came out of a call" and "this is a decision someone verified" change
    /// what the sentence over them is allowed to claim — and a model that cannot see the difference
    /// writes them in the same confident register. This is what `ContextChunk` could not carry.
    ///
    /// BUDGETED PER PASSAGE, NEVER BY DROPPING ONE. `k` is 8 whole notes now rather than 8 cut
    /// chunks, which is a much larger block than the old path ever assembled and more than a 3B
    /// window holds — so it is capped. The cap is spent EVENLY and every retrieved passage
    /// contributes: dropping the tail to fit would leave passages cited on screen that the
    /// generator never saw, which is the disclosure lying in the direction that is hardest to
    /// notice. `enrichCharCap` is the existing per-size-class budget and is reused rather than a
    /// second set of numbers being invented beside it.
    static func prompt(question: String, passages: [Passage], texts: [String: String],
                       charCap: Int, glossary: String = "") -> String {
        let budget = max(400, charCap / max(1, passages.count))
        let context = passages.map { passage -> String in
            let body = texts[passage.id] ?? passage.snippet
            let trimmed = body.count > budget ? String(body.prefix(budget)) + "…" : body
            return "[\(passage.citation) · \(spine(of: passage))]\n\(trimmed)"
        }.joined(separator: "\n\n")
        return (glossary.isEmpty ? "" : "Glossary (the user's own definitions):\n\(glossary)\n\n")
            + "Context:\n\(context)\n\nQuestion: \(question)"
    }

    /// Gloss lines for vocabulary terms present in the question or the retrieved text (capped at 6).
    ///
    /// KEPT ACROSS THE MERGE, and it nearly was not. It is the operator's own confirmed vocabulary
    /// from the entity registry — the thing that stops a model fumbling domain jargon — and it is
    /// app-side by construction (Doc 4 §5 keeps the identity layer here deliberately), so nothing
    /// on the engine path would have reported its absence. A silently dropped feature is the one
    /// kind of regression a passing build and a green suite both agree is fine.
    private static func glossary(question: String, passages: [Passage],
                                 texts: [String: String], workspace: String) -> String {
        guard let store = IndexStore.shared else { return "" }
        let glosses = store.termGlosses(group: workspace)
        guard !glosses.isEmpty else { return "" }
        let body = passages.map { texts[$0.id] ?? $0.snippet }.joined(separator: " ")
        let haystack = (question + " " + body).lowercased()
        return glosses
            .filter { haystack.contains($0.term.lowercased()) }
            .prefix(6)
            .map { "\($0.term) — \($0.gloss)" }
            .joined(separator: "\n")
    }

    /// `conversation` FIRST when present, exactly as `LiveRecallPanel` names it first: it is the one
    /// label that changes how the passage should be read, and burying it behind status would be the
    /// class axis existing and not arriving.
    private static func spine(of passage: Passage) -> String {
        var parts: [String] = []
        if passage.documentClass == .conversation { parts.append("from a call") }
        parts.append(passage.status.label)
        parts.append(passage.confidence.label)
        if !passage.vault.isEmpty { parts.append("@\(passage.vault)") }
        return parts.joined(separator: " · ")
    }

    private static func errorText(_ error: Error) -> String {
        (error as? EngineError)?.errorDescription ?? "Something went wrong — try again."
    }

    /// SCOPED AND TRUTHFUL. It never claims "nothing in your vault", which is false across the
    /// partition, and it points at the classes the disclosure says were withheld rather than at
    /// nothing.
    ///
    /// "BELOW", because in a thread the answer is drawn FIRST and its disclosure after it. This
    /// said "above", which was true of the single-answer console this sentence came from and false
    /// the moment turns stacked — a refusal to conclude anything from an empty result is worth very
    /// little if it sends the reader to the wrong end of the card for the evidence.
    private static func nothingMatched(scope: String) -> String {
        "No passage in \(scope) matched. The bar below names what was not searched — an answer in a "
            + "withheld class, or in another scope, would not have appeared here."
    }

    /// Why there is no answer over these passages.
    ///
    /// THE SYSTEM'S OWN REASON FIRST. `TranscriptEnricher.availabilityMessage` distinguishes four
    /// states, and one fixed sentence telling every one of them to "enable Apple Intelligence"
    /// prints a remedy that CANNOT BE PERFORMED on a device-ineligible Mac and is a no-op on a
    /// model that is still downloading. PRINCIPLES' fourth law, item (4): a refusal is complete
    /// only when its remedy has been executed against the state that triggers it. The fixed
    /// sentence survives only as the fallback for the case that message has no opinion on — an
    /// endpoint assigned for Ask that is not answering.
    private static func generationUnavailable() -> String {
        let reason = TranscriptEnricher.availabilityMessage
            ?? "There is no answering model available for Ask."
        return "These passages are what the vault returned, but nothing wrote an answer over them. "
            + reason + " You can also assign a local endpoint for Ask in Settings."
    }

    /// Appends an answer this app wrote itself — no generator ran, so no engine label.
    private func append(answer text: String, passages: [Passage],
                        retrieved: Retrieved, label: String?) {
        let message = AskMessage(fromUser: false, text: text,
                                 passages: passages.map(StoredPassage.init),
                                 engineLabel: label, indexVersion: retrieved.indexVersion)
        messages.append(message)
        record(disclosure: retrieved, for: message.id)
        syncCurrent(into: workspace)
    }

    private func record(disclosure retrieved: Retrieved, for id: UUID) {
        disclosures[id] = TurnDisclosure(envelope: retrieved.envelope, filter: retrieved.filter)
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
        // Describes the next question, not the answer above it — see `toggleVault`.
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
