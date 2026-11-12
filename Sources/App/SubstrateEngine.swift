import Foundation
import OSLog
import ScriptaCore
import SubstrateKit

/// The substrate engine's process, owned by this app.
///
/// Doc 3 §2, ratified: "The app runs the engine. There is no launchd job for substrate. Run Scripta
/// to have the engine; close Scripta and it stops." The precedent is the MCP servers this operator
/// already runs — atlas-vault and claude-vault reach Obsidian's Local REST API and stop working
/// when Obsidian closes, Docker's MCP needs Docker Desktop. The cost is named there rather than
/// discovered here: Claude Code and Zed gain a dependency they did not have, and lose substrate
/// when Scripta closes. That is accepted.
///
/// THE ENGINE IT SPAWNS IS `substrate serve`, which refreshes every scope itself (`substrate.refresh`);
/// this app schedules no compose of its own. An engine this app spawns still dies with it.
///
/// AN ENGINE ALREADY ANSWERING IS USED, but only when it is the kind this app would have started
/// (`EngineAttach`: read-only, refreshing, not agent mode, indexing this app's note format, on this
/// app's registry). Through 0.3.5 the answer was
/// "reported and never used", because adopting meant the app's lifetime and the engine's had come
/// apart. `substrate serve` running on its own made that the point rather than the hazard. One this
/// app attached to is never stopped or restarted from here; any other occupant is still reported.
///
/// NOT LEAKING A PROCESS IS THE FIRST REQUIREMENT. An orphan on the socket means the next launch
/// cannot start its own engine, and the operator has no way to know why. Three exits have to be
/// covered and only one of them runs our code:
///
///   quit        `AppDelegate.applicationWillTerminate` → `stop()` → SIGTERM to the shim
///   force-quit  SIGKILL. Nothing of ours runs.
///   crash       the same.
///
/// So the child cannot be trusted to be told. `spawn` hands it a stdin pipe whose write end only
/// this process holds, and the shim below blocks on that pipe: the kernel closes the write end when
/// Scripta dies BY ANY MEANS, the read hits EOF, and the shim kills the engine. Measured against all
/// three exits — including `kill -9` on the parent — and each left nothing behind.
@MainActor
final class SubstrateEngine: ObservableObject {

    static let shared = SubstrateEngine()

    private static let log = Logger(subsystem: "com.ronanwood.Scripta", category: "Substrate")

    // MARK: - States

    /// OWNERSHIP ADDS STATES, AND COLLAPSING THEM IS THE FAILURE. The client already models an
    /// unreachable engine, an unknown scope, a schema mismatch and a tool fault; none of those is
    /// any of these. A spawned-but-not-yet-bound engine drawn as "down" is a healthy state drawn as
    /// a fault — the same shape as the cancelled-`URLSession` bug `listScopes` now guards — and a
    /// machine with no engine installed at all is the ORDINARY first-run state, which needs a
    /// different sentence from "it crashed".
    enum Lifecycle {
        /// Launch has not reached the supervisor yet. Momentary: `AppDelegate` starts the engine,
        /// and the vault pane starts it too if it somehow gets there first.
        case idle

        /// Spawned, not yet answering. DISTINCT FROM DOWN: the cross-encoder arm builds its stack
        /// before `serve_unix` binds, so the socket stays closed for seconds by design.
        case starting(Source, since: Date)

        /// Answering JSON-RPC on the socket.
        case serving(Source, since: Date)

        /// There is no engine to spawn. Not a fault — the state every machine that is not the
        /// operator's is in today — and it carries what was looked for so the answer is actionable.
        case notInstalled(searched: [String])

        /// Something else holds the socket and this app will not use it: an engine `EngineAttach`
        /// refuses, one this app cannot read, or something on the path that is not this user's. Each
        /// has a remedy the operator can only apply if they are told.
        case socketBusy(path: String, occupant: Occupant)

        /// Spawned and died, or spawned and never answered. Carries the process's own stderr — a
        /// supervisor that says "could not start" without saying why makes the operator go read
        /// logs it already had in hand.
        case failed(Source, reason: String, stderr: String)

        var isServing: Bool {
            if case .serving = self { return true }
            return false
        }
    }

    /// Who is on the socket when it is not us. Split because the remedies differ: another substrate
    /// engine is quit or left alone, and anything else is in the way of ours.
    enum Occupant {
        /// It spoke JSON-RPC but its roster did not decode or was refused.
        case anEngine
        /// Something of this user's answered, and not in this protocol. The probe WAS sent to it.
        case aStranger(String)
        /// The client refused the socket before writing a byte: its directory is reachable by
        /// another user, or the listener runs as another uid. Split from `aStranger` because only
        /// here is "nothing was sent" true, and the remedy is about ownership, not a port clash.
        case untrusted(String)
        /// An engine that speaks another substrate wire, so it is from another release. Split from
        /// `anEngine` because the remedy is not quitting it: it may be one the operator runs on
        /// purpose, and the fix is updating whichever of the two is older.
        case otherRelease(String)
        /// An engine of this release that is not the kind this app uses (`EngineAttach`): one that
        /// accepts writes, an agent-mode one, or one too old to say. Carries why.
        case unattachable(String)
    }

    /// One process to run, resolved: what to exec, with what leading arguments, from where.
    struct Command {
        let executable: URL
        /// Arguments that come before the caller's own — the deployed pin runs a module.
        let arguments: [String]
        let workingDirectory: URL?
    }

    /// One resolved engine: what to run and where. `label` is what the reader is told ran.
    ///
    /// `executable` and `arguments` are the server alone (`substrate-mcp`): what clients register
    /// (Help), and what is spawned only when `cli` cannot serve (`engineCommand`).
    struct Source {
        let label: String
        let executable: URL
        /// Arguments this engine needs before the serve flags — the deployed pin runs a module.
        let arguments: [String]
        let workingDirectory: URL?

        /// THE SAME BUILD'S CLI, carried on the source rather than discovered a second time.
        ///
        /// `ingest` is refused on the transport (Doc 3 §3), so the one way to write a vault from
        /// this app is to run the command-line tool as a subprocess — and WHICH tool is not a free
        /// choice. A machine can have all three tiers present at once: the pinned deployment in
        /// `~/.substrate/engine` and the developer shim in `~/.local/bin` are different commits, and
        /// an index written by one and read by the other is the `schemaMismatch` refusal arriving as
        /// a consequence of a decision made here. Resolving the CLI independently would let the two
        /// disagree silently, which is precisely the shape this file exists to prevent, so the
        /// ladder picks both halves at once and they cannot come apart.
        ///
        /// Optional because the halves can genuinely be installed separately: `substrate-mcp` is on
        /// PATH without `substrate` on a machine that only ever ran the server. That is a fact to
        /// report, not to paper over with the other tier's CLI.
        let cli: Command?

        /// An engine already answering on the socket that this app did not start, and is using
        /// (`EngineAttach`). The rest of the source is this app's own resolved build, whose CLI the
        /// Library still runs. Such an engine is never restarted or stopped from here.
        var attached = false
    }

    @Published private(set) var lifecycle: Lifecycle = .idle

    /// Bumped by every `start()`, so a caller that awaited across one can tell its engine is gone.
    private(set) var generation = 0

    // MARK: - The socket

    /// The client's own path, so the spawn and the caller cannot disagree about which socket the
    /// engine is on — the disagreement would present as "the engine is down". `nonisolated`: a
    /// constant, and the states it names are drawn from a `Lifecycle` extension that has no actor.
    ///
    /// A UNIX SOCKET, NOT 127.0.0.1:8765. Loopback TCP let every user on the Mac query every scope,
    /// and let any process that bound the port while Scripta was closed be sent every query. The
    /// engine creates the socket's directory 0700, and both sides refuse a peer of another uid
    /// (`UnixSocketHTTP`, `substrate/local_socket.py`).
    nonisolated static var socketPath: String { SubstrateClient.defaultSocketPath }

    /// `--writes=granted` IS STATED, not inherited. The engine runs `ingest` and `amend` on the
    /// socket only for an MCP client the user allowed in Settings → Clients (`substrate grant`), and
    /// stamps each note with that client's name; every other caller is refused, and asked for by name.
    /// Unstated, the socket runs no write at all (Doc 3 §3: a write lands in a real Obsidian vault
    /// that the next refresh serves back as settled knowledge, and any process of this user can
    /// reach the socket), but a default is a thing that can move. Nothing here ever passes
    /// `--no-read-only`, which would run a write for anyone who can reach the socket.
    /// `--rerank-model` IS DELIBERATELY NOT STATED, and this comment exists because stating it is
    /// the obvious-looking mistake. I made it on 2026-08-04, to stop tier 2 and tier 3 disagreeing,
    /// and it cost the one number the UI is required to show.
    ///
    /// `stack.py:31` — "The defaults are the measured stack precisely so that a caller who changes
    /// nothing gets the number, and a caller who changes one model gets an honest None." Passing
    /// `--rerank-model cross` IS changing one model. The 44-case 0.698 configuration stops matching,
    /// `expected_mrr` correctly goes null with `unmeasured_reason: unmeasured_rerank_model`, and
    /// Doc 3 §5's "which tier answered" has nothing to render. Measured cost of the swap:
    /// EXPERIMENTS.md puts the cross-encoder at 0.708 against the default's 0.698 — and bounds even
    /// that, since Ollama exposes no logprobs so it ran as a yes/no FILTER where "most candidates
    /// tie" — for "roughly an order of magnitude slower, consistent with 385ms → 4,558ms".
    ///
    /// So the app states nothing about the reranker or the embedder. `AskModel` requires an in-app
    /// query and the equivalent CLI query to agree, "and they can only be compared while this side
    /// computes none of the three"; a reranker chosen by a Swift constant is this side computing one.
    ///
    /// `--hyde-model` IS THE ONE EXCEPTION, since 2026-11-01, and it is a user's choice rather than
    /// a constant. The engine's HyDE default used to be a pinned tag, and because this app passed
    /// nothing, that tag was every user's model — lost by anyone who had not pulled it, as everyone
    /// did when qwen2.5 left the machine. It now comes from Settings → Search
    /// (`AppSettings.engineSearchModel`): Off, whatever the server; a named local pick only when the
    /// Settings server IS the engine's Ollama and still lists it. Auto, a stale pick and a cloud
    /// pick pass nothing, so the engine's own choice applies: `hyde_model` in the operator's
    /// `~/.substrate/serve.toml` when it sets one and the engine runs as `substrate serve`, else
    /// the engine's Auto — the rule the picker's
    /// label shows, applied to what Ollama lists now. The picker's Auto row shows what the engine
    /// reports it runs, whichever it was. With no file, on Auto the CLI and the app run the same
    /// model by construction. The same file is how an operator moves the reranker; this app
    /// still states neither it nor the embedder.
    ///
    /// The tier disagreement that prompted the change is real and is NOT the app's to fix: it comes
    /// from `~/.local/bin/substrate-mcp` passing `cross` itself, which puts every client of that
    /// shim on the unmeasured arm. That belongs in the shim or in `stack.DEFAULT_RERANK`, where one
    /// value serves the CLI, the MCP and this app alike.
    private static func serveArguments(searchModel: String?) -> [String] {
        // One `--flag=value` element, so a value starting with "-" is a value, never an option.
        ["--socket", socketPath, "--writes=granted"]
            + (searchModel.map { ["--hyde-model=\($0)"] } ?? [])
    }

    /// What to exec for an engine that SERVES AND REFRESHES: `substrate serve` from the same build's
    /// CLI (`substrate.refresh`), which keeps every scope current on its own timer. The refresh
    /// loop is the engine's, not this app's. A tier with no CLI, or an engine that does not offer
    /// `refresh` (`EngineManifest`), falls back to `substrate-mcp --socket`, which refreshes
    /// nothing, and the Library says so (`SubstrateScopes.server`).
    private static func engineCommand(_ source: Source,
                                      searchModel: String?) -> (URL, [String], URL?) {
        if let cli = source.cli, servesAndRefreshes(cli) {
            return (cli.executable, cli.arguments + ["serve"]
                        + serveArguments(searchModel: searchModel), cli.workingDirectory)
        }
        return (source.executable, source.arguments + serveArguments(searchModel: searchModel),
                source.workingDirectory)
    }

    /// The developer shim runs whatever the repo has checked out, which this app cannot see, so it
    /// is assumed current; an engine root is asked.
    private static func servesAndRefreshes(_ cli: Command) -> Bool {
        guard let root = cli.workingDirectory else { return true }
        return EngineManifest.offers(.refresh, at: root)
    }

    /// The `--hyde-model` the current start passes (nil: none). The engine reads it once, at
    /// startup, so this is what `searchModelChanged` compares against.
    private var launchedSearchModel: String?

    /// How long a cold start may take before it is called a failure. Generous on purpose: the
    /// engine builds its whole retrieval stack — embedder, HyDE and reranker — BEFORE `serve_unix`
    /// binds, so the socket stays shut for as long as the slowest arm takes to load, and the starting
    /// card counts seconds so a long wait looks like a long wait rather than a hang.
    ///
    /// Sized for the arms the ENGINE picks, not for one this app names: `serveArguments` states no
    /// embedder or reranker, so a machine configured onto a heavier reranker must still fit under
    /// this. HyDE's model, the one it can state, is only probed at startup, never loaded, so the
    /// ceiling does not move with it either.
    private static let startupCeiling: TimeInterval = 180

    /// How long a restart waits for the engine it replaced to exit. Above the shim's own ~4s
    /// TERM-then-KILL budget, so the bound is only hit by something this app did not expect.
    private static let retireCeiling: TimeInterval = 10

    /// The shim of an engine of ours that `teardown` signalled, and until when to wait for it.
    private var retiring: Process?
    private var retiringUntil: Date?

    // MARK: - Process

    private var process: Process?
    private var stdin: Pipe?
    private var stderr: Pipe?
    private var tail = StderrTail()
    private var task: Task<Void, Never>?

    private let probe = SubstrateClient(timeout: 5)

    // MARK: - Lifecycle

    /// Called once from `applicationDidFinishLaunching`, and again from the vault pane if it
    /// somehow renders first. Idempotent.
    func startIfIdle() {
        guard case .idle = lifecycle else { return }
        start()
    }

    func start() {
        attachRetries = 0
        begin()
    }

    /// How many times a qualifying-looking engine has been tried again since the last `start()`: one
    /// that faulted on its roster (busy with its own pass, at login), or one refused only because
    /// this app's CLI did not answer. One that stays that way is reported after these.
    private var attachRetries = 0
    private static let attachRetryLimit = 4
    private static let attachRetryDelay: UInt64 = 30_000_000_000
    private var attachRetry: Task<Void, Never>?

    private func begin() {
        generation += 1
        teardown()
        // A new engine is about to answer; what the last one said about its arms no longer holds.
        SubstrateScopes.shared.forgetArms()
        linkLegacySocket()
        let (source, searched) = Self.discover()
        guard let source else {
            let looked = searched.joined(separator: ", ")
            Self.log.info("no engine to spawn; looked at \(looked, privacy: .public)")
            lifecycle = .notInstalled(searched: searched)
            return
        }
        lifecycle = .starting(source, since: Date())
        // Read and recorded HERE, before anything async: a second change arriving during the socket
        // check must compare against what this start will launch, not what the last one did.
        let searchModel = AppSettings.engineSearchModel
        launchedSearchModel = searchModel
        task = Task { [weak self] in await self?.bringUp(source, searchModel: searchModel) }
    }

    /// The remedy every non-serving card offers. `start()` already tears down and re-runs discovery
    /// and the socket check, so this also covers "I quit the thing that was holding the socket" and
    /// "I installed the engine" — it is named separately because that is what the button means.
    func restart() { start() }

    /// Settings changed something search resolves from — the binding, the server, or its catalog.
    /// The engine reads its HyDE model only at launch, so an engine that is up or coming up is
    /// restarted, and ONLY when the argument actually differs: a restart rebuilds every arm and
    /// leaves search unavailable while it does. An engine that is down picks the new value up on
    /// its next start.
    func searchModelChanged() {
        switch lifecycle {
        case .starting: break
        case .serving(let source, _):
            // NOT OURS TO RESTART. An engine this app attached to runs on its own launch arguments,
            // and Settings says the Search pick does not reach it.
            guard !source.attached else { return }
        default: return
        }
        guard AppSettings.engineSearchModel != launchedSearchModel else { return }
        Self.log.info("search model changed; restarting the engine")
        restart()
    }

    /// Quit path. The shim's EOF watchdog covers force-quit and crash; this is the fast, ordinary
    /// one, and it runs before the app's own exit so the socket is free by the time the next launch
    /// looks at it.
    func stop() {
        teardown()
        SubstrateScopes.shared.forgetArms()
        lifecycle = .idle
    }

    // MARK: - Bringing it up

    private func bringUp(_ source: Source, searchModel: String?) async {
        // FIRST, an engine of OURS that is retiring is waited out. `teardown` signals it and does
        // not wait, and until it is gone it still holds the socket's lifetime lock — so a new
        // engine spawned now exits "already serving", and one still answering reads as an occupant
        // below. Either strands a Settings-driven restart on a card asking the user to restart.
        //
        // Keyed on the retiring SHIM exiting, not on the socket going quiet: the shim exits only
        // after the engine's whole process group is gone (see `shim`), which is what releases both
        // the socket and the lock, whereas a listener can stop answering while its process still
        // holds the lock. Bounded by `retiringUntil`, kept on the instance so a second restart
        // arriving mid-wait still waits for the same engine.
        if let until = retiringUntil {
            while retiring?.isRunning == true, Date() < until, !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 100_000_000)
            }
        }
        guard !Task.isCancelled else { return }
        // THE SOCKET CHECK COMES NEXT. A live socket before we have spawned anything means an
        // engine already runs: one started on its own, by hand, or an orphan. A second bind would
        // fail, so it is attached to when `EngineAttach` allows and reported when not. A crashed
        // engine's socket file refuses connections, reads as free here, and the engine replaces it.
        let state = await Self.socketState(probe)
        guard !Task.isCancelled else { return }
        switch state {
        case .free:
            break
        case .held(let occupant):
            Self.log.error("the engine socket is already held; refusing to start a second engine")
            lifecycle = .socketBusy(path: Self.socketPath, occupant: occupant)
            // An engine that spoke the protocol and faulted on its roster may only be busy (its own
            // pass, at login): looked at again. Another release, a stranger or a socket that is not
            // this user's is a verdict, and stays.
            if case .anEngine = occupant { scheduleAttachRetry() }
            return
        case .engine where retiring?.isRunning == true:
            // This app's own previous engine, still answering past `retireCeiling`. Attaching would
            // keep it, and whatever the restart was for (a new search model) would never apply.
            Self.log.error("the engine this app is retiring is still answering; not attaching to it")
            lifecycle = .socketBusy(path: Self.socketPath, occupant: .unattachable(
                "it is the engine Scripta is replacing, and it has not exited yet"))
            scheduleAttachRetry()
            return
        case .engine(let list):
            // AN ENGINE ALREADY ANSWERING IS USED when it is the kind this app would have started
            // (`EngineAttach`): `substrate serve` run on its own, read-only, on this app's registry,
            // indexing this app's note format. It is not spawned, so this app never stops it, and
            // while attached this app writes notes only: that engine does the indexing.
            let expected = await Self.expectation(source)
            guard !Task.isCancelled else { return }
            switch EngineAttach.verdict(list, expecting: expected) {
            case .attach:
                var attachedSource = source
                attachedSource.attached = true
                attachRetries = 0
                Self.log.info("attached to an engine already serving on the socket")
                lifecycle = .serving(attachedSource, since: Date())
                keepLinkingLegacySocket()
                Task { await SubstrateScopes.shared.refreshArms() }
                EngineRefresh.shared.engineBecameServing()
            case .refuse(let why):
                Self.log.error("an engine is on the socket and cannot be used: \(why, privacy: .public)")
                lifecycle = .socketBusy(path: Self.socketPath, occupant: .unattachable(why))
                // Unanswered is not a verdict: an engine that is the right kind of server, refused
                // only because this app's own CLI did not say which registry it writes, is looked
                // at again, a few times, before the card stays. A registry that IS known and
                // differs is a verdict, and is not retried.
                let filled = EngineAttach.Expectation(registry: expected.registry ?? list.registry)
                if expected.registry == nil, source.cli != nil,
                   EngineAttach.verdict(list, expecting: filled) == .attach {
                    scheduleAttachRetry()
                }
            }
            return
        }
        do {
            try spawn(source, searchModel: searchModel)
        } catch {
            lifecycle = .failed(source, reason: "The engine could not be launched: \(error).",
                                stderr: "")
            return
        }
        await waitUntilAnswering(source)
    }

    private func scheduleAttachRetry() {
        guard attachRetries < Self.attachRetryLimit else { return }
        attachRetries += 1
        attachRetry = Task { [weak self] in
            try? await Task.sleep(nanoseconds: Self.attachRetryDelay)
            guard !Task.isCancelled else { return }
            self?.begin()
        }
    }

    /// Whether the engine this app attached to still qualifies, asked again on every poll: the one on
    /// the socket can be replaced by another without this app seeing it go. Both halves are asked
    /// again, this app's CLI included, since a redeploy or a checkout can change what it writes.
    /// Nil when that cannot be told: this app's CLI did not answer, or this app is no longer
    /// attached.
    func stillAttachable(_ list: WireScopeList) async -> Bool? {
        guard let source = serving, source.attached else { return nil }
        // What the roster says is decided first: a replacement that is the wrong kind of server is
        // let go whatever this app's CLI says.
        guard EngineAttach.qualifiesByRoster(list) else { return false }
        // A missing answer from this app's CLI is not a verdict on its own; one that stays missing
        // is (`EngineRefresh.watch`).
        let expected = await Self.expectation(source)
        guard expected.registry != nil else { return nil }
        return EngineAttach.verdict(list, expecting: expected) == .attach
    }

    /// This app's own build, as its CLI reports it (`substrate version`): the registry it resolves.
    /// Asked of the CLI rather than worked out here, because the CLI is what records scopes. No CLI,
    /// or one that predates the command, and there is nothing to attach by.
    private static func expectation(_ source: Source) async -> EngineAttach.Expectation {
        guard let cli = source.cli else { return EngineAttach.Expectation(registry: nil) }
        let run = await SubstrateCLI.run(cli, ["version"])
        guard run.succeeded,
              let object = try? JSONSerialization.jsonObject(with: Data(run.stdout.utf8))
                  as? [String: Any] else {
            return EngineAttach.Expectation(registry: nil)
        }
        return EngineAttach.Expectation(registry: object["registry"] as? String)
    }

    private func spawn(_ source: Source, searchModel: String?) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        let (executable, arguments, directory) = Self.engineCommand(source, searchModel: searchModel)
        child.arguments = ["-c", Self.shim, "substrate-engine", executable.path] + arguments
        if let directory { child.currentDirectoryURL = directory }

        // The parent-death pipe. Never written to and never closed while the engine should live —
        // its only job is to become EOF when this process goes away.
        let input = Pipe()
        let errors = Pipe()
        child.standardInput = input
        child.standardError = errors
        child.standardOutput = FileHandle.nullDevice

        let sink = StderrTail()
        // Drained CONTINUOUSLY, not read at failure time: a 64 KB pipe that nobody empties blocks
        // the writer, and the writer here is a long-lived server that logs.
        errors.fileHandleForReading.readabilityHandler = { handle in
            let data = handle.availableData
            guard !data.isEmpty, let text = String(data: data, encoding: .utf8) else { return }
            sink.append(text)
        }
        // Identity-checked rather than flag-guarded: a handler already in flight when `teardown`
        // ran would otherwise land on the NEXT process's lifecycle and report a healthy restart as
        // a crash. Only the process this app currently holds is allowed to report its own death.
        child.terminationHandler = { [weak self] finished in
            Task { @MainActor [weak self] in
                guard let self, self.process === finished else { return }
                self.childExited(status: finished.terminationStatus)
            }
        }

        try child.run()
        process = child
        stdin = input
        stderr = errors
        tail = sink
        let argv = ([executable.path] + arguments).joined(separator: " ")
        Self.log.info("spawned \(argv, privacy: .public) as \(source.label)")
    }

    /// READINESS IS "IT ANSWERED", not "the process is alive". The engine builds its retrieval
    /// stack before it binds, so a live process proves nothing; and the socket is open only inside
    /// `serve_unix`, so an answer is decisive.
    private func waitUntilAnswering(_ source: Source) async {
        let endpoint = Self.socketPath
        let deadline = Date().addingTimeInterval(Self.startupCeiling)
        while !Task.isCancelled {
            if Self.answers(await Self.socketState(probe)) {
                guard !Task.isCancelled else { return }
                lifecycle = .serving(source, since: Date())
                Self.log.info("engine answering on \(endpoint, privacy: .public)")
                // Again once serving: an old engine still exiting at `start` held the old path.
                keepLinkingLegacySocket()
                // What this engine runs, which Settings' Search row draws (`SubstrateScopes.arms`).
                Task { await SubstrateScopes.shared.refreshArms() }
                EngineRefresh.shared.engineBecameServing()
                // This app's own engine: any index still in this app's old folder is rebuilt in
                // the engine's (`relocateLegacyIndexes`).
                Task { await SubstrateLibraryModel.shared.relocateLegacyIndexes() }
                return
            }
            guard !Task.isCancelled else { return }
            if let process, !process.isRunning {
                lifecycle = .failed(source, reason: Self.exitReason(process.terminationStatus),
                                    stderr: tail.current)
                return
            }
            if Date() >= deadline {
                let seconds = Int(Self.startupCeiling)
                let stderr = tail.current
                teardown()
                lifecycle = .failed(source, reason: "The engine started but never answered on "
                                    + "\(endpoint) within \(seconds)s.", stderr: stderr)
                return
            }
            try? await Task.sleep(nanoseconds: 500_000_000)
        }
    }

    /// Clients registered through 0.3.4 hold the socket's old path; it links to the new one
    /// (`LegacyEngineSocket`). Run at every start, and again once serving.
    @discardableResult
    private func linkLegacySocket() -> LegacyEngineSocket.Outcome {
        let outcome = LegacyEngineSocket.link(to: Self.socketPath)
        switch outcome {
        case .linked, .noLegacyFolder:
            break
        case .liveListener:
            Self.log.notice("""
                the socket's old path is in use (an engine on it, or another Scripta linking it); \
                not linked yet
                """)
        case .foreignFile, .failed:
            Self.log.error("""
                clients registered with the socket's old path cannot reach the engine: \
                \(String(describing: outcome), privacy: .public)
                """)
        }
        return outcome
    }

    /// How often, and how many times, a still-held old path is tried again once serving. An engine
    /// of 0.3.4 that is exiting lets go within seconds. One started by hand on the old path may
    /// never let go, and is not waited on past this.
    private static let legacyRetryInterval: UInt64 = 15_000_000_000
    private static let legacyRetries = 8
    private var legacyLink: Task<Void, Never>?

    private func keepLinkingLegacySocket() {
        legacyLink?.cancel()
        legacyLink = Task { [weak self] in
            for attempt in 0...Self.legacyRetries {
                if attempt > 0 { try? await Task.sleep(nanoseconds: Self.legacyRetryInterval) }
                guard !Task.isCancelled, let self else { return }
                guard self.linkLegacySocket() == .liveListener else { return }
            }
        }
    }

    /// The engine went away while Scripta is still running. Reported rather than restarted: a
    /// supervisor that silently respawns a crashing process turns one legible failure into a loop
    /// nobody sees, and the card this produces carries the stderr and a Restart control.
    private func childExited(status: Int32) {
        guard let source = runningSource else { return }
        SubstrateScopes.shared.forgetArms()
        task?.cancel()
        task = nil
        process = nil
        lifecycle = .failed(source, reason: Self.exitReason(status), stderr: tail.current)
    }

    private var runningSource: Source? {
        switch lifecycle {
        case .starting(let source, _), .serving(let source, _): return source
        default: return nil
        }
    }

    /// The engine that is ANSWERING, for a caller that has to run something out of the same build.
    ///
    /// Narrower than `runningSource` on purpose: a `.starting` engine has a resolved source but has
    /// not proved it can run, and the Library's first act would be a minutes-long ingest against a
    /// build that may be about to land in `.failed` with its reason on stderr. Waiting for the socket
    /// costs seconds and turns that into a legible refusal.
    var serving: Source? {
        if case .serving(let source, _) = lifecycle { return source }
        return nil
    }

    /// What the ladder resolves to, whatever the process is doing. For Help, which shows the command
    /// a client registers and needs no answer from the socket. Everything that reads a RESULT goes
    /// through `serving` instead, because a result implies something answered.
    static var resolved: Source? { discover().0 }

    private static func exitReason(_ status: Int32) -> String {
        status == 0
            ? "The engine exited on its own without reporting an error."
            : "The engine exited with status \(status)."
    }

    private func teardown() {
        task?.cancel()
        task = nil
        attachRetry?.cancel()
        attachRetry = nil
        legacyLink?.cancel()
        legacyLink = nil
        process?.terminationHandler = nil
        if let process, process.isRunning {
            process.terminate()
            retiring = process
            retiringUntil = Date().addingTimeInterval(Self.retireCeiling)
        }
        stderr?.fileHandleForReading.readabilityHandler = nil
        // Closing our write end is the other half of the same signal: the shim's `cat` sees EOF and
        // kills the engine's process group even if the SIGTERM above was somehow missed.
        try? stdin?.fileHandleForWriting.close()
        process = nil
        stdin = nil
        stderr = nil
        tail = StderrTail()
    }

    // MARK: - Who is on the socket

    private enum SocketState {
        case free
        case held(Occupant)
        /// An engine answered `list_scopes`, so it serves this app's wire; whether to use it is
        /// `EngineAttach`'s.
        case engine(WireScopeList)
    }

    /// Whether the engine this app spawned is up. Its roster may fail to decode or be refused, which
    /// still means it bound and answers; `start` already found the socket free before the spawn.
    private static func answers(_ state: SocketState) -> Bool {
        switch state {
        case .engine, .held(.anEngine): return true
        default: return false
        }
    }

    /// Asked with a real `list_scopes`, not a bare TCP connect, because the answer decides the
    /// SENTENCE as well as the fact: "an engine is already answering" and "something that is not a
    /// substrate engine is listening" have different remedies and the operator needs the right one.
    private static func socketState(_ client: SubstrateClient) async -> SocketState {
        switch await client.listScopes() {
        case .ok(let list):
            return .engine(list)
        case .toolFault, .rpcError:
            // It spoke the protocol and refused this particular call. Still an engine.
            return .held(.anEngine)
        case .transportFailure(let failure):
            // A cancelled probe is not evidence of anything; the caller's `Task.isCancelled` guard
            // is what acts on it, so this must not read as "the socket is free and yours to take".
            if failure.isCancellation { return .free }
            if case .undecodablePayload = failure { return .held(.anEngine) }
            if case .wireMismatch(let why) = failure { return .held(.otherRelease(why)) }
            if case .untrusted(let why) = failure { return .held(.untrusted(why)) }
            // The one mapping of URLError codes to "nothing is listening" lives in `VaultRefusal`;
            // duplicating the set here is how the two drift.
            if case .engineDown = VaultRefusal.of(failure) { return .free }
            return .held(.aStranger(failure.description))
        }
    }

    // MARK: - What to spawn

    private static var home: URL { URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true) }

    /// Three candidates, most-shipped first, and the order is the decision: the day packaging lands,
    /// the engine inside the bundle must win over whatever the machine that built it happens to
    /// have. Returns the paths it looked at either way — `notInstalled` renders them, because "no
    /// engine" without "here is where one goes" is a fact with no action attached.
    private static func discover() -> (Source?, [String]) {
        var searched: [String] = []

        // 1. THE ENGINE THAT SHIPS WITH THE APP. Doc 3 §2 says the runtime and its dependencies
        //    ship with Scripta, and the engine's `tools/build-bundled-engine` now puts them here as a
        //    post-build phase on the `Scripta` target: a relocated python-build-standalone under
        //    `runtime/`, its `.venv`, the engine package, and the two shims below.
        //
        //    THE WORKING DIRECTORY IS THE ENGINE ROOT, matching the pinned deployment below. It was
        //    `bin` — harmless today, because both shims `cd` to the root themselves before exec'ing,
        //    and precisely because it is harmless it would have survived until something relied on
        //    cwd and then differed from every path that was ever tested.
        if let root = Bundle.main.resourceURL?.appendingPathComponent("substrate-engine") {
            let bin = root.appendingPathComponent("bin")
            let bundled = bin.appendingPathComponent("substrate-mcp")
            searched.append(bundled.path)
            if isRunnable(bundled) {
                return (Source(label: "bundled with Scripta", executable: bundled, arguments: [],
                               workingDirectory: root,
                               cli: command(bin.appendingPathComponent("substrate"), from: root)),
                        searched)
            }
        }

        // TIERS 2 AND 3 ARE DEBUG-ONLY, and packaging is what forced the line. Both resolve out of
        // the user's HOME, which is writable by anything running as that user and — for a copy in
        // /Applications — by any admin without an authentication prompt. Files under
        // `Contents/Resources` are sealed into `CodeResources` and checked by `codesign --verify`,
        // NOT by the kernel at spawn, so deleting the bundled `bin/` does not stop the app launching;
        // it just demotes it to the next rung. Planting `~/.local/bin/substrate-mcp` — a plain 755
        // script — then gets arbitrary code spawned inside a notarized, unsandboxed process holding
        // this app's microphone and calendar attribution. The hardened runtime exists to prevent
        // exactly that outcome and does not cover exec of a path we chose ourselves.
        //
        // Doc 5 §4.5 already calls this: `substrate-deploy` becomes a DEVELOPER tool rather than an
        // install step. A release build resolves the bundled engine or reports `notInstalled` with
        // the paths it searched — it does not quietly run something out of $HOME.
        #if DEBUG
        // 2. THE PINNED DEPLOYMENT. The engine's `tools/substrate-deploy` exports one commit to
        //    ~/.substrate/engine and primes its environment with `uv sync --frozen`, so the venv's
        //    python is a direct entry point — one process, no `uv` in the middle to forward signals.
        let deployed = home.appendingPathComponent(".substrate/engine", isDirectory: true)
        let python = deployed.appendingPathComponent(".venv/bin/python")
        searched.append(python.path)
        if isRunnable(python), EngineManifest.offers(.serve, at: deployed) {
            // `python -m substrate.cli` out of the SAME venv and the same working directory — one
            // export, one set of pinned dependencies, one schema. `substrate/cli.py` is checked
            // because the deployment could in principle export the server without it.
            let cli = exists(deployed.appendingPathComponent("substrate/cli.py"))
                ? Command(executable: python, arguments: ["-m", "substrate.cli"],
                          workingDirectory: deployed)
                : nil
            return (Source(label: "the pinned deployment in ~/.substrate/engine",
                           executable: python, arguments: ["-m", "substrate.mcp.server"],
                           workingDirectory: deployed, cli: cli), searched)
        }

        // 3. THE DEVELOPER SHIM — the fallback, and on a machine with nothing deployed the only one
        //    that resolves. It execs `uv run` out of the REPO TREE, so what it serves is whatever is
        //    checked out rather than a pinned commit: correct while developing, and the reason it
        //    ranks last. Its registry is the operator's, which is also what `--registry` defaults to
        //    (`scopes.DEFAULT_REGISTRY`), so all three tiers see the same six scopes; the reranker
        //    they share is stated in `serveArguments` rather than inherited from this one.
        let shim = home.appendingPathComponent(".local/bin/substrate-mcp")
        searched.append(shim.path)
        if isRunnable(shim) {
            let bin = home.appendingPathComponent(".local/bin", isDirectory: true)
            return (Source(label: "the developer shim in ~/.local/bin", executable: shim,
                           arguments: [], workingDirectory: nil,
                           cli: command(bin.appendingPathComponent("substrate"))), searched)
        }
        #endif

        return (nil, searched)
    }

    /// A sibling tool, or nothing. `nil` rather than a fallback to another tier's copy: the whole
    /// point of resolving these together is that they cannot come from different commits.
    private static func command(_ executable: URL, from directory: URL? = nil) -> Command? {
        guard isRunnable(executable) else { return nil }
        return Command(executable: executable, arguments: [], workingDirectory: directory)
    }

    private static func isRunnable(_ url: URL) -> Bool {
        FileManager.default.isExecutableFile(atPath: url.path)
    }

    private static func exists(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: url.path)
    }

    // MARK: - The shim

    /// A shell between Scripta and the engine, and every line of it is there for the leak.
    ///
    /// `set -m` puts the engine in ITS OWN PROCESS GROUP. That is what makes `kill -TERM -$engine`
    /// safe and sufficient: the developer shim execs `uv run`, which forks python as a grandchild,
    /// so signalling the direct child alone would rely on `uv` forwarding — it does forward SIGTERM,
    /// measured, but it cannot forward SIGKILL. A group kill reaches both. A group kill is only
    /// safe BECAUSE of `set -m`; without it the engine shares Scripta's process group and the
    /// negative pid would signal Scripta itself.
    ///
    /// `cat` reads the stdin pipe whose write end only Scripta holds. EOF therefore means "Scripta
    /// is gone" for every way it can go, including the two that never run our code.
    ///
    /// `wait "$engine"` is the other direction: when the engine dies on its own the shim exits, so
    /// `Process.isRunning` and `terminationHandler` report the ENGINE rather than the shell wrapping
    /// it — which is what lets `failed` be a real state instead of a timeout.
    ///
    /// SHARED WITH THE CLI RUNNER (`SubstrateCLI`), not copied. The leak this closes is not special
    /// to the server: a docling ingest holds a torch stack for minutes, and a force-quit during one
    /// leaves a process chewing the machine with no window to close and nothing on the socket to
    /// explain it. Same three exits, same EOF watchdog, same group kill — and a second copy of this
    /// script is a second thing to get right.
    static let shim = """
    set -m
    "$@" </dev/null &
    engine=$!
    ( cat >/dev/null; kill -TERM $$ 2>/dev/null ) &
    reader=$!
    set +m
    stop() { kill -TERM -"$engine" 2>/dev/null; }
    trap stop TERM INT HUP
    wait "$engine"
    status=$?
    stop
    n=0
    while kill -0 -"$engine" 2>/dev/null && [ "$n" -lt 40 ]; do sleep 0.1; n=$((n+1)); done
    kill -KILL -"$engine" 2>/dev/null
    kill -KILL -"$reader" 2>/dev/null
    exit "$status"
    """
}

/// The child's stderr, drained on the pipe's own queue and kept to a tail. Locked rather than
/// actor-isolated because the reader is a `readabilityHandler` that cannot await, and the whole
/// value is a few kilobytes of text.
private final class StderrTail: @unchecked Sendable {
    private let lock = NSLock()
    private var text = ""

    func append(_ chunk: String) {
        lock.lock()
        defer { lock.unlock() }
        text += chunk
        if text.count > 4096 { text = String(text.suffix(4096)) }
    }

    var current: String {
        lock.lock()
        defer { lock.unlock() }
        return text.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
