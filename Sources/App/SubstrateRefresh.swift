import Foundation
import OSLog

/// Index refresh, on launch and on a timer while Scripta is open.
///
/// Doc 3 §2: "Index refresh | in-app, on launch and on a timer while open", and the launchd job
/// `com.ronanwood.substrate-refresh` is deleted. This is the in-app half. THE CRON IS NOT TOUCHED
/// FROM HERE — removing it is the operator's act and is sequenced after this works, because until
/// then it is the only thing keeping any index current.
///
/// WHAT MOVED IN-APP IS THE SCHEDULE, NOT THE WORK. The agent this runs is `tools/substrate-refresh`
/// out of the same tier as the engine (see `SubstrateEngine.Source.refreshAgent`), and rewriting it
/// in Swift would have meant a second implementation of its refusals — every one of which exists
/// because of an incident:
///
///   * it verifies the pinned deployment before composing anything, and records `engine_unverified`
///     for every scope when it cannot. That outcome exists because a 900-second job exec'd the
///     working tree and an uncommitted v8→v9 schema bump reached six live scopes inside one tick.
///     A retry here would be papering over the one refusal that stopped that happening twice.
///   * it checks the embedding daemon FIRST, because `compose --clean` drops the index and rebuilds
///     it without vectors and `embed` puts them back — a tick that ran between those two with
///     Ollama down would leave a scope 0-vector and every query against it degraded.
///   * it classifies drift into three shapes and refuses to read two of them as clean.
///   * it records an outcome on EVERY path, because a path that returns without recording turns
///     freshness a human used to check into freshness a human assumes.
///
/// SO THE STATUS MODEL IS THE ENGINE'S. This type does not interpret a pass; `refresh_state.report`
/// does, and it already rides on every `list_scopes` row as `WireScopeRow.refresh` — `outcome`,
/// `attempted`, `succeeded`, the tri-state `frozen` and `frozen_since`. The surface reads that.
/// What is kept here is only what the engine cannot know: whether THIS app has an agent to run, and
/// how the last invocation exited.
@MainActor
final class SubstrateRefresh: ObservableObject {
    static let shared = SubstrateRefresh()

    private static let log = Logger(subsystem: "com.ronanwood.Scripta", category: "Refresh")

    /// The cron's cadence, kept. It was chosen to match the vault sync — "an index refreshed on a
    /// slower cadence than the vault syncs would answer from notes the Mac had already pulled down"
    /// — and a quiet tick costs about 2.5s and logs nothing.
    private static let interval: TimeInterval = 900

    /// How long the first pass waits for the engine to finish coming up. The engine loads a
    /// cross-encoder before it binds, and starting a compose into that is contention on the one
    /// event the operator is watching. Bounded rather than open-ended: an engine that never serves
    /// must not mean an index that is never refreshed, because the agent does not need the port.
    private static let settle: TimeInterval = 60

    enum State {
        case idle
        /// There is no refresh agent beside the engine this app resolved.
        case unavailable(engine: String)
        case running(since: Date)
        /// The last pass, as it exited. The agent redirects its own output to
        /// `~/Library/Logs/substrate-refresh.log`, so an exit status and that path is genuinely all
        /// a caller gets from the process — the per-scope verdict comes back through the engine.
        case finished(at: Date, run: SubstrateRun)
    }

    @Published private(set) var state: State = .idle

    /// The agent's own log. Named rather than read: it is the file the agent writes its reasons to,
    /// and a refusal to compose says why there and nowhere else.
    static var logPath: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent("Library/Logs/substrate-refresh.log")
    }

    private var loop: Task<Void, Never>?
    private var pass: Task<Void, Never>?

    /// Called once from `applicationDidFinishLaunching`. Idempotent.
    func start() {
        guard loop == nil else { return }
        loop = Task { [weak self] in
            await self?.settleThenLoop()
        }
    }

    func stop() {
        loop?.cancel()
        loop = nil
        pass?.cancel()
        pass = nil
    }

    /// The operator asking for one now.
    func refreshNow() {
        guard pass == nil else { return }
        pass = Task { [weak self] in
            await self?.runPass()
            self?.pass = nil
        }
    }

    private func settleThenLoop() async {
        let deadline = Date().addingTimeInterval(Self.settle)
        while !Task.isCancelled, Date() < deadline, isComingUp {
            try? await Task.sleep(nanoseconds: 2_000_000_000)
        }
        while !Task.isCancelled {
            await runPass()
            // SLEEP AFTER, NOT BEFORE. The loop is serial by construction, so a pass that overruns
            // the interval delays the next one rather than stacking a second on top of it — which
            // is the stampede a `Timer` firing into a still-running compose would produce.
            try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
        }
    }

    private var isComingUp: Bool {
        switch SubstrateEngine.shared.lifecycle {
        case .idle, .starting: return true
        case .serving, .notInstalled, .portBusy, .failed: return false
        }
    }

    /// One tick: compose every registered scope, and record an outcome for each.
    ///
    /// THE AGENT IS NOT RUN, AND THIS IS NOT A PORT OF IT. `tools/substrate-refresh` cannot refresh
    /// a bundled engine — it hard-exits on a missing `~/.local/bin/substrate`, and where it does run
    /// it composes through `$ENGINE`/`$UV` read out of a user-writable deployment record, which is
    /// arbitrary execution inside a notarized process. Doc 5 §6 decided the loop instead.
    ///
    /// What each of its refusals is worth here, one by one, because "we replaced it" is not an
    /// argument:
    ///
    ///   * VERIFY THE DEPLOYMENT — moot. That outcome exists because a 900-second job exec'd a
    ///     working tree and an uncommitted schema bump reached six scopes in one tick. The engine is
    ///     now the signed bundle; there is no pin to prove and no tree to drift.
    ///   * CHECK THE EMBEDDING DAEMON FIRST — moot for the same reason it existed. It guarded the
    ///     window between `compose --clean` dropping the index and `embed` restoring vectors. This
    ///     composes with `clean: false`, so no vectors are dropped and there is no window.
    ///   * CLASSIFY DRIFT INTO THREE SHAPES — COARSENED, and stated rather than hidden: a successful
    ///     compose is recorded `refreshed` whether or not anything changed. Both leave the scope
    ///     verified, so the tri-state `frozen` is unaffected; what is lost is the quiet/noisy
    ///     distinction, not a health signal.
    ///   * RECORD AN OUTCOME ON EVERY PATH — KEPT, and it is the load-bearing one. A compose that
    ///     fails records `compose_failed`, which is the freeze: without it the scope keeps serving
    ///     its last healthy verdict and `refresh.frozen` reads `false` — freshness a human used to
    ///     check becoming freshness a human assumes, which is the whole subject of PRINCIPLES.
    ///
    /// The per-scope verdict still belongs to the engine: this writes outcomes and re-lists, and
    /// `refresh_state.report` is what interprets them.
    private func runPass() async {
        guard let source = SubstrateEngine.shared.serving ?? SubstrateEngine.resolved else {
            state = .unavailable(engine: "none — there is no engine on this Mac")
            return
        }
        guard let cli = source.cli else {
            state = .unavailable(engine: source.label)
            return
        }
        // A ROSTER IS REQUIRED, not assumed: on the first pass nothing has listed yet, and a loop
        // over an empty roster would silently refresh nothing while reporting a clean pass.
        if SubstrateScopes.shared.rows.isEmpty { await SubstrateScopes.shared.listScopes() }
        let rows = SubstrateScopes.shared.rows
        guard !rows.isEmpty else {
            state = .unavailable(engine: "\(source.label) — no scopes are registered")
            return
        }

        state = .running(since: Date())
        var firstFailure: SubstrateRun?
        var last: SubstrateRun?
        for row in rows {
            if Task.isCancelled { break }
            // A scope whose inheritance no longer resolves is listed WITH its fault and has no
            // vault to compose. Recording `compose_failed` is right: it is frozen, and saying so is
            // the difference between a scope that is broken and one that reads as fine.
            guard row.error == nil, !row.vault.isEmpty else {
                await record(cli: cli, scope: row.scope, outcome: "compose_failed")
                continue
            }
            let vault = URL(fileURLWithPath: row.vault, isDirectory: true)
            let run = await SubstrateLibraryModel.composeVault(cli: cli, vault: vault,
                                                              name: row.scope, clean: false)
            // DECLINED IS NOT FAILED. `composeVault` refuses while another compose is in flight —
            // a recording's, or the operator's — and recording an outcome for a scope this pass did
            // not attempt would overwrite a live verdict with the news that a duplicate stood down.
            if run.cancelled && run.status == nil {
                Self.log.info("skipped \(row.scope, privacy: .public) — a compose was in flight")
                continue
            }
            await record(cli: cli, scope: row.scope,
                         outcome: run.succeeded ? "refreshed" : "compose_failed")
            if !run.succeeded, firstFailure == nil { firstFailure = run }
            last = run
        }

        guard !Task.isCancelled else {
            state = .idle
            return
        }
        // THE FIRST FAILURE IS WHAT THE CARD SHOWS, if there was one. The surface has room for a
        // single run and reads `succeeded` off it, so showing the last would let one healthy scope
        // at the end of the roster hide a refusal earlier in it.
        if let representative = firstFailure ?? last {
            state = .finished(at: Date(), run: representative)
        }
        Self.log.info("refresh pass composed \(rows.count) scope(s)")
        // This pass is the ONE path that sees changes this app did not make — an Obsidian edit, a
        // Claude session writing a note — so the browse list is invalidated here rather than
        // waiting to be reopened.
        VaultBrowseModel.shared.corpusChanged()
        // Re-listed rather than inferred: `refresh_state.report` is the only thing that knows how to
        // read an outcome, including the freeze carried forward when a pass checked nothing.
        await SubstrateScopes.shared.listScopes()
    }

    /// Write one scope's outcome. Failing to record is itself reported, because the recorder is the
    /// signal path: a pass whose verdict never lands leaves the scope asserting its last healthy
    /// one, and that is the state this whole mechanism exists to make impossible.
    private func record(cli: SubstrateEngine.Command, scope: String, outcome: String) async {
        let run = await SubstrateCLI.run(
            cli, ["refresh-record", "--scope", scope, "--outcome", outcome, "--quiet"])
        if !run.succeeded {
            Self.log.error("could not record \(outcome, privacy: .public) for \(scope, privacy: .public)")
        }
    }
}
