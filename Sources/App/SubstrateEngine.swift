import Foundation
import OSLog
import SubstrateKit

/// The substrate engine's process, owned by this app.
///
/// Doc 3 §2, ratified: "The app runs the engine. There is no launchd job for substrate. Run Scripta
/// to have the engine; close Scripta and it stops." The precedent is the MCP servers this operator
/// already runs — prism-vault and claude-vault reach Obsidian's Local REST API and stop working
/// when Obsidian closes, Docker's MCP needs Docker Desktop. The cost is named there rather than
/// discovered here: Claude Code and Zed gain a dependency they did not have, and lose substrate
/// when Scripta closes. That is accepted.
///
/// THERE IS NO ADOPT PATH, and its absence is the design rather than an omission. A port that is
/// already answering is reported (`portBusy`) and never used: adopting it would mean the app's
/// lifetime and the engine's had come apart, which is the one property this type exists to keep.
///
/// NOT LEAKING A PROCESS IS THE FIRST REQUIREMENT. An orphan on the port means the next launch
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
        /// before `serve_http` binds, so the port stays closed for seconds by design.
        case starting(Source, since: Date)

        /// Answering JSON-RPC on the port.
        case serving(Source, since: Date)

        /// There is no engine to spawn. Not a fault — the state every machine that is not the
        /// operator's is in today — and it carries what was looked for so the answer is actionable.
        case notInstalled(searched: [String])

        /// Something else holds the port. An ANOMALY, surfaced rather than adopted or swallowed:
        /// it is either a stale orphan from a previous crash or an engine started by hand, and
        /// both have a remedy the operator can only apply if they are told.
        case portBusy(port: Int, occupant: Occupant)

        /// Spawned and died, or spawned and never answered. Carries the process's own stderr — a
        /// supervisor that says "could not start" without saying why makes the operator go read
        /// logs it already had in hand.
        case failed(Source, reason: String, stderr: String)

        var isServing: Bool {
            if case .serving = self { return true }
            return false
        }
    }

    /// Who is on the port when it is not us. Split because the remedies differ: another substrate
    /// engine is quit or left alone, an unrelated listener is a port conflict.
    enum Occupant {
        /// It answered JSON-RPC. `scopes` is the roster size when the answer decoded.
        case anEngine(scopes: Int?)
        /// Something is listening and it is not this protocol.
        case aStranger(String)
    }

    /// One process to run, resolved: what to exec, with what leading arguments, from where.
    struct Command {
        let executable: URL
        /// Arguments that come before the caller's own — the deployed pin runs a module.
        let arguments: [String]
        let workingDirectory: URL?
    }

    /// One resolved engine: what to run and where. `label` is what the reader is told ran.
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

        /// `tools/substrate-refresh` — the unattended refresh agent, from the same tier again.
        ///
        /// RUN, NOT REIMPLEMENTED. Doc 3 §2 moves index refresh in-app and deletes the launchd job,
        /// and the obvious reading of that is "write a refresh loop in Swift". It is the wrong one.
        /// That script is ~260 lines of refusal: it verifies the pinned deployment before composing
        /// anything and records `engine_unverified` for every scope when it cannot (the outcome that
        /// exists because an uncommitted schema bump reached six live scopes inside one tick), it
        /// checks the embedding daemon FIRST so a `--clean` compose can never leave a scope
        /// 0-vector, it classifies three drift shapes where two of them must not read as clean, and
        /// it records an outcome on every path because a path that returns without recording puts
        /// assumed freshness back. A Swift copy would be a second implementation of all of that,
        /// diverging silently, and the operator's own instruction is to match the existing
        /// discipline rather than invent a parallel one. What moves in-app is the SCHEDULE.
        let refreshAgent: Command?
    }

    @Published private(set) var lifecycle: Lifecycle = .idle

    // MARK: - The port

    /// Derived from the client's own endpoint so the spawn and the caller cannot disagree about
    /// which socket the engine is on — the disagreement would present as "the engine is down".
    /// `nonisolated`: these are three reads of a constant URL, and the states they name are drawn
    /// from a `Lifecycle` extension that has no actor of its own.
    nonisolated static var port: Int { SubstrateClient.defaultEndpoint.port ?? 8765 }
    nonisolated static var host: String { SubstrateClient.defaultEndpoint.host ?? "127.0.0.1" }
    /// What the operator has to type into `lsof` to see for themselves.
    nonisolated static var endpoint: String { "\(host):\(port)" }

    /// `--read-only` IS STATED, not inherited. It already defaults on under `--http` (Doc 3 §3:
    /// `ingest` writes notes into real Obsidian vaults that the next refresh serves back as settled
    /// knowledge, and any local process can reach a loopback port), but a default is a thing that
    /// can move. Nothing here ever passes `--no-read-only`.
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
    /// So the app states NOTHING about retrieval. `AskModel` requires an in-app query and
    /// the equivalent CLI query to agree, "and they can only be compared while this side computes
    /// none of the three"; a reranker chosen by a Swift constant is this side computing one.
    ///
    /// The tier disagreement that prompted the change is real and is NOT the app's to fix: it comes
    /// from `~/.local/bin/substrate-mcp` passing `cross` itself, which puts every client of that
    /// shim on the unmeasured arm. That belongs in the shim or in `stack.DEFAULT_RERANK`, where one
    /// value serves the CLI, the MCP and this app alike.
    private static var serveArguments: [String] {
        ["--http", endpoint, "--read-only"]
    }

    /// How long a cold start may take before it is called a failure. Generous on purpose: the
    /// engine builds its whole retrieval stack — embedder, HyDE and reranker — BEFORE `serve_http`
    /// binds, so the port stays shut for as long as the slowest arm takes to load, and the starting
    /// card counts seconds so a long wait looks like a long wait rather than a hang.
    ///
    /// Sized for the arms the ENGINE picks, not for one this app names: `serveArguments` states no
    /// models, so a machine configured onto a heavier reranker must still fit under this. The
    /// ceiling therefore does not move when the measured default does.
    private static let startupCeiling: TimeInterval = 180

    // MARK: - Process

    private var process: Process?
    private var stdin: Pipe?
    private var stderr: Pipe?
    private var tail = StderrTail()
    private var task: Task<Void, Never>?

    private let probe = SubstrateClient(endpoint: SubstrateClient.defaultEndpoint, timeout: 5)

    // MARK: - Lifecycle

    /// Called once from `applicationDidFinishLaunching`, and again from the vault pane if it
    /// somehow renders first. Idempotent.
    func startIfIdle() {
        guard case .idle = lifecycle else { return }
        start()
    }

    func start() {
        teardown()
        let (source, searched) = Self.discover()
        guard let source else {
            let looked = searched.joined(separator: ", ")
            Self.log.info("no engine to spawn; looked at \(looked, privacy: .public)")
            lifecycle = .notInstalled(searched: searched)
            return
        }
        lifecycle = .starting(source, since: Date())
        task = Task { [weak self] in await self?.bringUp(source) }
    }

    /// The remedy every non-serving card offers. `start()` already tears down and re-runs discovery
    /// and the port check, so this also covers "I quit the thing that was holding the port" and "I
    /// installed the engine" — it is named separately because that is what the button means.
    func restart() { start() }

    /// Quit path. The shim's EOF watchdog covers force-quit and crash; this is the fast, ordinary
    /// one, and it runs before the app's own exit so the port is free by the time the next launch
    /// looks at it.
    func stop() {
        teardown()
        lifecycle = .idle
    }

    // MARK: - Bringing it up

    private func bringUp(_ source: Source) async {
        // THE PORT CHECK COMES FIRST, and what it finds is never used. A busy port before we have
        // spawned anything means a previous engine outlived its Scripta or the operator started one
        // by hand; either way a second bind would fail and the first is not ours to own.
        let state = await Self.portState(probe)
        guard !Task.isCancelled else { return }
        if case .held(let occupant) = state {
            Self.log.error("port \(Self.port) is already held; refusing to start a second engine")
            lifecycle = .portBusy(port: Self.port, occupant: occupant)
            return
        }
        do {
            try spawn(source)
        } catch {
            lifecycle = .failed(source, reason: "The engine could not be launched: \(error).",
                                stderr: "")
            return
        }
        await waitUntilAnswering(source)
    }

    private func spawn(_ source: Source) throws {
        let child = Process()
        child.executableURL = URL(fileURLWithPath: "/bin/sh")
        child.arguments = ["-c", Self.shim, "substrate-engine", source.executable.path]
            + source.arguments + Self.serveArguments
        if let directory = source.workingDirectory { child.currentDirectoryURL = directory }

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
        Self.log.info("spawned \(source.executable.path, privacy: .public) as \(source.label)")
    }

    /// READINESS IS "IT ANSWERED", not "the process is alive". The engine builds its retrieval
    /// stack before it binds, so a live process proves nothing; and the socket is open only inside
    /// `serve_http`, so an answer is decisive.
    private func waitUntilAnswering(_ source: Source) async {
        let endpoint = Self.endpoint
        let deadline = Date().addingTimeInterval(Self.startupCeiling)
        while !Task.isCancelled {
            if case .held(.anEngine) = await Self.portState(probe) {
                guard !Task.isCancelled else { return }
                lifecycle = .serving(source, since: Date())
                Self.log.info("engine answering on \(endpoint, privacy: .public)")
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

    /// The engine went away while Scripta is still running. Reported rather than restarted: a
    /// supervisor that silently respawns a crashing process turns one legible failure into a loop
    /// nobody sees, and the card this produces carries the stderr and a Restart control.
    private func childExited(status: Int32) {
        guard let source = runningSource else { return }
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
    /// build that may be about to land in `.failed` with its reason on stderr. Waiting for the port
    /// costs seconds and turns that into a legible refusal.
    var serving: Source? {
        if case .serving(let source, _) = lifecycle { return source }
        return nil
    }

    /// What the ladder resolves to, whatever the process is doing.
    ///
    /// For the one caller that genuinely does not need the port: the refresh agent composes indexes
    /// directly and never speaks to the server, so an engine that failed to bind — or a Scripta
    /// whose engine is still loading its reranker — is no reason to leave every scope unrefreshed.
    /// Everything that reads a RESULT goes through `serving` instead, because a result implies
    /// something answered.
    static var resolved: Source? { discover().0 }

    private static func exitReason(_ status: Int32) -> String {
        status == 0
            ? "The engine exited on its own without reporting an error."
            : "The engine exited with status \(status)."
    }

    private func teardown() {
        task?.cancel()
        task = nil
        process?.terminationHandler = nil
        if let process, process.isRunning { process.terminate() }
        stderr?.fileHandleForReading.readabilityHandler = nil
        // Closing our write end is the other half of the same signal: the shim's `cat` sees EOF and
        // kills the engine's process group even if the SIGTERM above was somehow missed.
        try? stdin?.fileHandleForWriting.close()
        process = nil
        stdin = nil
        stderr = nil
        tail = StderrTail()
    }

    // MARK: - Who is on the port

    private enum PortState {
        case free
        case held(Occupant)
    }

    /// Asked with a real `list_scopes`, not a bare TCP connect, because the answer decides the
    /// SENTENCE as well as the fact: "an engine is already answering" and "something that is not a
    /// substrate engine is listening" have different remedies and the operator needs the right one.
    private static func portState(_ client: SubstrateClient) async -> PortState {
        switch await client.listScopes() {
        case .ok(let list):
            return .held(.anEngine(scopes: list.scopes.count))
        case .toolFault, .rpcError:
            // It spoke the protocol and refused this particular call. Still an engine.
            return .held(.anEngine(scopes: nil))
        case .transportFailure(let failure):
            // A cancelled probe is not evidence of anything; the caller's `Task.isCancelled` guard
            // is what acts on it, so this must not read as "the port is free and yours to take".
            if failure.isCancellation { return .free }
            if case .undecodablePayload = failure { return .held(.anEngine(scopes: nil)) }
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
        //    ship with Scripta; nothing puts them here yet and that packaging work is not in this
        //    pass, so today this is the slot rather than a path that resolves.
        if let root = Bundle.main.resourceURL?.appendingPathComponent("substrate-engine") {
            let bin = root.appendingPathComponent("bin")
            let bundled = bin.appendingPathComponent("substrate-mcp")
            searched.append(bundled.path)
            if isRunnable(bundled) {
                return (Source(label: "bundled with Scripta", executable: bundled, arguments: [],
                               workingDirectory: bin,
                               cli: command(bin.appendingPathComponent("substrate"), from: bin),
                               refreshAgent: command(
                                   root.appendingPathComponent("tools/substrate-refresh"),
                                   from: root)), searched)
            }
        }

        // 2. THE PINNED DEPLOYMENT. `substrate/tools/substrate-deploy` exports one commit to
        //    ~/.substrate/engine and primes its environment with `uv sync --frozen`, so the venv's
        //    python is a direct entry point — one process, no `uv` in the middle to forward signals.
        let deployed = home.appendingPathComponent(".substrate/engine", isDirectory: true)
        let python = deployed.appendingPathComponent(".venv/bin/python")
        searched.append(python.path)
        if isRunnable(python), exists(deployed.appendingPathComponent("substrate/mcp/server.py")) {
            // `python -m substrate.cli` out of the SAME venv and the same working directory — one
            // export, one set of pinned dependencies, one schema. `substrate/cli.py` is checked
            // because the deployment could in principle export the server without it.
            let cli = exists(deployed.appendingPathComponent("substrate/cli.py"))
                ? Command(executable: python, arguments: ["-m", "substrate.cli"],
                          workingDirectory: deployed)
                : nil
            return (Source(label: "the pinned deployment in ~/.substrate/engine",
                           executable: python, arguments: ["-m", "substrate.mcp.server"],
                           workingDirectory: deployed, cli: cli,
                           refreshAgent: command(
                               deployed.appendingPathComponent("tools/substrate-refresh"),
                               from: deployed)), searched)
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
                           cli: command(bin.appendingPathComponent("substrate")),
                           refreshAgent: command(
                               bin.appendingPathComponent("substrate-refresh"))), searched)
        }

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
    /// leaves a process chewing the machine with no window to close and nothing on the port to
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
