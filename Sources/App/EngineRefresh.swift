import Foundation
import OSLog
import SubstrateKit

/// What this app does about index refresh now that the ENGINE does it (`substrate serve`).
///
/// Through 0.3.5 the schedule lived here (`SubstrateRefresh`): composes ran on a timer while Scripta
/// was open, serialized by an in-process flag. The engine now runs that loop itself, under the vaults
/// lock every compose and embed take, and records each scope's outcome where `list_scopes` reads it.
/// So this type schedules nothing. It does what only the app can:
///
///   * "Refresh now" runs one pass through the same build's CLI (`substrate refresh`), so a press
///     never waits for the engine's next tick. Attached to an engine this app did not start, it asks
///     that engine to bring its next pass forward instead: that engine does the indexing;
///   * once a minute it looks at the engine (`SubstrateScopes.poll`), which notices a pass the
///     engine ran and tells Browse, so changes this app did not make show without a relaunch;
///   * it watches an engine this app ATTACHED to and did not start, and lets it go when it is gone
///     or no longer qualifies (`EngineAttach`), since nothing else supervises it.
///
/// The verdict per scope stays the engine's: `refresh_state.report` rides on every roster row.
@MainActor
final class EngineRefresh: ObservableObject {
    static let shared = EngineRefresh()

    private static let log = Logger(subsystem: "com.ronanwood.Scripta", category: "Refresh")

    /// How often the engine is looked at. One cheap `list_scopes`; the engine's pass runs every 15
    /// minutes, so a minute is prompt enough.
    private static let pollEvery: UInt64 = 60_000_000_000

    enum State {
        case idle
        case running(since: Date)
        /// The last "Refresh now", as it exited. Per-scope verdicts come back through the roster.
        case finished(at: Date, run: SubstrateRun)
        /// The last "Refresh now" asked an attached engine for its next pass, and it said when.
        case requested(at: Date, reply: WireRefreshRequest)
        /// It asked, and the engine did not take the request: the reason, in a sentence.
        case requestFailed(at: Date, reason: String)
    }

    @Published private(set) var state: State = .idle

    private let client = SubstrateClient()

    private var poll: Task<Void, Never>?
    private var pass: Task<Void, Never>?
    private var passToken = UUID()
    private var firstLook: Task<Void, Never>?
    /// One `watch` at a time: two looking at one dead engine would each restart it, and the second
    /// restart would tear down the engine the first had just spawned.
    private var watching = false
    /// When a look at an attached engine first found it gone or not qualifying, since the last
    /// clean one. One such look is not a verdict; a second, a minute or so later, is.
    private var firstStrikeAt: Date?
    private var stopped = false
    /// Since when an attached engine's re-check has had no answer (this app's own
    /// `substrate version`). Missing for a minute is a busy moment; for `strikeWindow`, it is an
    /// engine that cannot be held to the registry check at all, and counts as a strike.
    private var unansweredSince: Date?
    /// The second strike must be this far after the first: the look at serving and the next poll
    /// tick can land seconds apart, across one brief restart of the operator's own engine.
    private static let strikeSpacing: TimeInterval = 50
    /// And no further than this: past it, a second strike starts over as a first.
    private static let strikeWindow: TimeInterval = 300

    /// Called once from `applicationDidFinishLaunching`. Idempotent.
    func start() {
        guard poll == nil else { return }
        stopped = false
        poll = Task { [weak self] in
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: Self.pollEvery)
                guard !Task.isCancelled else { return }
                await self?.watch()
            }
        }
    }

    func stop() {
        // A `watch` already past its awaits must not restart the engine during quit.
        stopped = true
        poll?.cancel()
        poll = nil
        firstLook?.cancel()
        firstLook = nil
        pass?.cancel()
        pass = nil
    }

    /// An engine has just started serving, spawned or attached: its first listing is the baseline
    /// the engine's own passes are measured from, so it is taken now, before the pass it runs at
    /// bind can finish unnoticed.
    func engineBecameServing() {
        firstStrikeAt = nil
        unansweredSince = nil
        firstLook?.cancel()
        firstLook = Task { [weak self] in
            // Waits out a look already in flight, which was about the engine before this one.
            while self?.watching == true, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
            guard !Task.isCancelled else { return }
            await self?.watch()
        }
    }

    /// Whether "Refresh now" can do anything. Attached, it needs an engine that takes requests to
    /// bring its pass forward, unless it has not said yet (no listing): then the press asks, and the
    /// answer says; otherwise, this app's CLI.
    var canRefresh: Bool {
        guard let serving = SubstrateEngine.shared.serving else { return false }
        if serving.attached { return SubstrateScopes.shared.server?.refreshRequests != false }
        return serving.cli != nil
    }

    /// ATTACHED, after this app handed the engine a scope to index: ask for its next pass, and show
    /// the answer on the rail as a press would. Nil when the engine takes no requests or did not
    /// answer; the pass then comes on its own schedule. Asked even before a listing says whether it
    /// takes requests, since an engine without the tool only answers "unknown tool".
    func handOff() async -> WireRefreshRequest? {
        guard SubstrateScopes.shared.server?.refreshRequests != false else { return nil }
        guard let reply = await client.requestRefresh().payloadIfOK else { return nil }
        if pass == nil { state = .requested(at: Date(), reply: reply) }
        return reply
    }

    /// The operator asking for a pass now.
    func refreshNow() {
        guard pass == nil, canRefresh else { return }
        let token = UUID()
        passToken = token
        pass = Task { [weak self] in
            await self?.runPass(token: token)
            // Only this pass's own handle: one `stop()` cancelled may finish after a new one began.
            if self?.passToken == token { self?.pass = nil }
        }
    }

    private func runPass(token: UUID) async {
        guard passToken == token, let serving = SubstrateEngine.shared.serving else { return }
        if serving.attached {
            await requestPass(token: token)
            return
        }
        // The same build's CLI, carried on the source, so the pass is the engine this app runs.
        guard let cli = serving.cli else { return }
        state = .running(since: Date())
        let run = await SubstrateCLI.run(cli, ["refresh"])
        // Only this pass may write the state: one `stop()` cancelled can finish after a new one.
        guard !Task.isCancelled, passToken == token else {
            if passToken == token { state = .idle }
            return
        }
        if !run.succeeded {
            Self.log.error("refresh pass exited \(run.status.map(String.init) ?? "on a signal", privacy: .public)")
        }
        VaultBrowseModel.shared.corpusChanged()
        // Listed BEFORE the pass is stamped finished: this pass moves the scopes it reached, and
        // the rail hides a failure once a later move is seen (`SubstrateScopes.lastMoved`).
        _ = await SubstrateScopes.shared.poll()
        guard passToken == token else { return }
        state = .finished(at: Date(), run: run)
    }

    /// ATTACHED: the engine indexes, so this asks it to bring its next pass forward rather than
    /// running one here. Its verdicts come back through the roster as the pass reaches each scope.
    private func requestPass(token: UUID) async {
        state = .running(since: Date())
        let call = await client.requestRefresh()
        guard !Task.isCancelled, passToken == token else {
            if passToken == token { state = .idle }
            return
        }
        switch call {
        case .ok(let reply):
            state = .requested(at: Date(), reply: reply)
        case .toolFault(let text), .rpcError(_, let text):
            Self.log.error("the attached engine did not take a refresh request: \(text, privacy: .public)")
            state = .requestFailed(at: Date(), reason: "The engine did not take the request: \(text)")
        case .transportFailure(let failure):
            Self.log.error("the attached engine did not answer a refresh request: \(failure.description, privacy: .public)")
            state = .requestFailed(at: Date(), reason: "The engine did not answer the request: "
                                       + "\(failure.description)")
        }
    }

    /// One look at the engine: the roster and its arms are refreshed, a pass the engine ran is
    /// noticed (`SubstrateScopes.poll`), and an engine this app ATTACHED to is checked again. One
    /// that has gone, or is now something this app will not use (another release, not this user's,
    /// not qualifying), is let go after two such looks with no clean one between. A look that gets
    /// no answer (a fault, a timeout) counts for nothing either way. `restart()`
    /// then runs the full socket check: it attaches to whatever serves now, reports it, or spawns
    /// this app's own.
    private func watch() async {
        guard !watching else { return }
        watching = true
        defer { watching = false }
        let engine = SubstrateEngine.shared
        guard engine.serving != nil else { return }
        let generation = engine.generation
        let result = await SubstrateScopes.shared.poll()
        // Re-read after every await: a restart in between makes this look about another engine.
        guard engine.generation == generation, engine.serving?.attached == true else {
            firstStrikeAt = nil
            unansweredSince = nil
            return
        }
        let reason: String?
        switch result {
        case .down where stopped:
            return
        case .down:
            // Not at once: an operator restarting their own `substrate serve` leaves the socket
            // shut for a moment, and an engine spawned into that gap would take it from theirs.
            reason = "is gone"
        case .answered(let list):
            let qualifies = await engine.stillAttachable(list)
            guard engine.generation == generation, engine.serving?.attached == true else { return }
            // Unanswered is not a verdict: this app's own `substrate version`, which says which
            // registry the engine is held to, can miss a busy moment. Unanswered for long enough is.
            if let qualifies {
                unansweredSince = nil
                reason = qualifies ? nil : "no longer qualifies"
            } else {
                let since = unansweredSince ?? Date()
                unansweredSince = since
                guard Date().timeIntervalSince(since) >= Self.strikeWindow else { return }
                reason = "cannot be held to this app's registry: its substrate command has not "
                    + "said which one it writes for five minutes"
            }
        case .foreign:
            reason = "is now something this app will not use"
        case .unreadable:
            // A fault or a timeout from what is most likely the same engine, busy. Not a strike,
            // and not a clean look either.
            return
        }
        guard let reason else {
            firstStrikeAt = nil
            return
        }
        // A first strike long ago, with only unanswered looks since, is not half of this verdict.
        guard let first = firstStrikeAt, Date().timeIntervalSince(first) <= Self.strikeWindow else {
            firstStrikeAt = Date()
            return
        }
        guard Date().timeIntervalSince(first) >= Self.strikeSpacing, !stopped else { return }
        firstStrikeAt = nil
        Self.log.notice("the engine this app attached to \(reason, privacy: .public); starting over")
        engine.restart()
    }
}

extension WireRefreshRequest {
    /// The pass the engine brought forward, as a phrase: "its next pass, starting now". One wording
    /// for every place the answer is shown.
    var phrase: String {
        switch nextPass {
        case .now: return "its next pass, starting now"
        case .afterPass: return "the pass after the one it is running"
        case .afterGap: return "its next pass, in \(Int(waitSeconds.rounded(.up))) s"
        }
    }
}
