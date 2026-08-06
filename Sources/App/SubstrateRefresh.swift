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

    /// One tick. Never throws, never retries: a refusal is a verdict this app is not entitled to
    /// overrule, and the agent has already recorded it against every scope by the time it exits.
    private func runPass() async {
        guard let source = SubstrateEngine.shared.serving ?? SubstrateEngine.resolved else {
            state = .unavailable(engine: "none — there is no engine on this Mac")
            return
        }
        guard let agent = source.refreshAgent else {
            state = .unavailable(engine: source.label)
            return
        }
        // ALREADY RUNNING SOMEWHERE ELSE is a normal outcome, not a case to force. The agent takes
        // `~/.substrate/refresh.lock` and `substrate-deploy` takes the same one; a second invocation
        // sees it, logs that it skipped, and deliberately records NOTHING — because writing an
        // outcome would overwrite a live pass's result with the news that a duplicate declined.
        // Running it and letting it make that decision is the discipline; deciding here would be a
        // second lock protocol beside the one that already exists.
        state = .running(since: Date())
        let run = await SubstrateCLI.run(agent, [])
        guard !Task.isCancelled else {
            state = .idle
            return
        }
        state = .finished(at: Date(), run: run)
        Self.log.info("refresh pass exited \(run.status ?? -1)")
        // The verdict per scope lives on the roster, which the surface draws from. Re-listed rather
        // than inferred: `refresh_state.report` is the only thing that knows how to read an outcome,
        // including the freeze that is carried forward when the latest pass checked nothing.
        await SubstrateScopes.shared.listScopes()
    }
}
