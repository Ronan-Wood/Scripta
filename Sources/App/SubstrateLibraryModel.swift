import Foundation
import ScriptaCore
import SubstrateKit

/// The Library: bringing something into the engine, all the way to queryable.
///
/// THE WHOLE CHAIN RUNS IN THE APP. `ingest` writes an extraction, not an index — the engine is
/// explicit that composing and registering are separate acts, and its own `export-transcripts`
/// stops after writing the vault and prints the two commands. That is right for a CLI and wrong for
/// this surface: a Library that hands the operator a terminal command to finish what they started
/// has not shipped the feature, and Doc 3 §5 is emphatic that a note which exists and cannot be
/// found is the silent-absence state. So every job here ends with a compose, and the scope is
/// registered and answering before the surface says it is done.
///
/// PERFORMING THE WORK IS NOT HIDING IT. Every step reports the command it ran and everything the
/// process said, success included — `export-transcripts` exits 0 and warns on stderr when the
/// SOURCE transcripts are in a synced tree, so a surface that showed stderr only on failure would
/// swallow the one warning it exists to carry. A job that fails stops at the step that failed, and
/// the steps after it are drawn as not attempted rather than as passed.
@MainActor
final class SubstrateLibraryModel: ObservableObject {
    static let shared = SubstrateLibraryModel()

    // MARK: - What the engine accepts

    enum Surface {
        case unasked
        case asking
        /// What this build takes, in its own words. An EMPTY format table is reachable and is not
        /// a crash: it means the engine did not enumerate, which the surface says rather than
        /// resolving into a guess.
        case known(SubstrateCLI.IngestSurface)
        /// There is no CLI beside the engine that is serving.
        case noCLI(engine: String)
    }

    // MARK: - A job

    /// One step of a job, and what became of it.
    struct Step: Identifiable {
        let id: String
        /// What this step was for, in the operator's terms.
        let title: String
        /// The subprocess, when there was one. `nil` for a step the app performed itself.
        let run: SubstrateRun?
        /// The app's own failure, for a step it performed itself.
        let appFailure: String?
        /// Not reached, because an earlier step failed. Drawn as absence, never as success.
        let skipped: Bool

        var failed: Bool {
            if skipped { return false }
            if appFailure != nil { return true }
            return !(run?.succeeded ?? true)
        }
    }

    /// A job in flight. Held as its own value so a long ingest can say what it is doing and for how
    /// long — docling loads a layout model before it reads a page, and a one-page PDF measured 36
    /// seconds on this machine, so "it is working" has to be visible or it reads as a hang.
    struct Running {
        let title: String
        let step: String
        let started: Date
        /// Steps already finished, so the report builds up on screen instead of appearing at the end.
        let done: [Step]
    }

    /// A finished job, whatever happened.
    struct Report {
        let title: String
        let steps: [Step]
        /// The scope the engine says it registered — read from compose's own output, not predicted
        /// here. `nil` when the job did not get that far.
        let scope: String?
        /// The vault directory a failed compose left a document in. Its presence is what makes the
        /// remedy reachable: this is precisely the state where a note exists and cannot be found.
        let orphaned: URL?

        var failed: Bool { steps.contains(where: \.failed) }
        var failure: Step? { steps.first(where: \.failed) }
    }

    enum Job {
        case idle
        case running(Running)
        case finished(Report)
    }

    // MARK: - State

    @Published private(set) var surface: Surface = .unasked
    @Published private(set) var job: Job = .idle

    /// The document rail's staged inputs.
    @Published var document: URL?
    /// `nil` means "not chosen". NEVER pre-set to a class: defaulting this is the exact bug the
    /// document-class axis records against itself — an absent declaration that silently became
    /// `reference-frozen` relabelled ~88% of a corpus as a published edition that will not change.
    /// For every format but PDF the engine WANTS this absent, because a file extension is evidence
    /// about the container and not about the document.
    @Published var documentClass: String?
    @Published var domains: String = ""
    /// "Read it as markdown whatever it is named" — the engine's own suggested remedy for an
    /// extension it does not recognise, offered rather than left in a refusal message.
    @Published var forceMarkdown = false

    /// The transcript rail's input. ONE value, because the workspace is the binding (Doc 3 §7) and
    /// everything else about the export is a consequence of it.
    ///
    /// It was two, and they could disagree. `transcriptVault` was a second stored property seeded
    /// from `AppSettings.activeGroup` AT INIT and never recomputed, while `SubstrateLibraryView:387`
    /// binds this one to a free-text field — so typing a different name moved the scope
    /// (`"transcript-" + slug(workspace)`, and the manifest's `scripta-<slug>` under it) while the
    /// destination directory stayed at whatever the active workspace happened to be when the app
    /// launched. Exporting "Personal" wrote a vault declaring `scope = scripta-personal` INTO
    /// `transcripts/cbre`, over CBRE's exported corpus, and the `--clean` compose then dropped
    /// CBRE's index and registered the new name against that path.
    ///
    /// That is the wall Doc 3 §4 calls the privacy boundary between workspaces, reopened on this
    /// side after `transcript_export` closed it on the engine's — and it is the same shape as the
    /// bug there: A NAME AND A LOCATION THAT MUST AGREE, HELD AS TWO INDEPENDENT VALUES. Deriving
    /// one from the other is what makes them unable to come apart, rather than a rule someone has
    /// to remember at each of the two call sites.
    @Published var workspace: String = AppSettings.activeGroup {
        didSet {
            // A NEW WORKSPACE RETIRES THE OVERRIDE. An explicitly chosen directory belongs to the
            // workspace it was chosen for; carrying it across is the same desync in slow motion.
            if workspace != oldValue { vaultOverride = nil }
        }
    }

    /// A destination the operator picked by hand, or `nil` for the derived one. The escape hatch
    /// survives — the engine is what enforces "local and non-synced", not this — but it is now
    /// visibly an override of the binding rather than an equal second source of truth.
    @Published private(set) var vaultOverride: URL?

    /// Where this workspace's transcripts go. Derived, so it cannot disagree with the scope name
    /// that `runExport` builds from the same `workspace`.
    var transcriptVault: URL {
        vaultOverride ?? SubstrateLibrary.transcriptVault(workspace: workspace)
    }

    func chooseVault(_ url: URL) { vaultOverride = url }

    /// Follow the active workspace (Doc 3 §7). Called from `AppModel.activeGroup.didSet`, because
    /// this model is a singleton that outlives the pane and sampling `AppSettings.activeGroup` at
    /// init is what left the rail exporting into the workspace that was active when the app
    /// launched. Refused mid-job: an export names its workspace in the vault manifest it is writing,
    /// and moving the target under a running compose is the desync this pair was just fixed for.
    func adoptWorkspace() {
        guard !isWorking else { return }
        let active = AppSettings.activeGroup
        guard workspace != active else { return }
        workspace = active          // `didSet` retires any hand-picked destination
    }

    /// One job at a time, and it is a real constraint rather than caution: two composes racing on
    /// one `--clean` index root leave the loser asserting over content it did not ingest, which is
    /// the hazard the refresh agent takes a lock for.
    private var task: Task<Void, Never>?

    var isWorking: Bool {
        if case .running = job { return true }
        return false
    }

    // MARK: - Asking what the engine takes

    func activate() async {
        guard case .unasked = surface else { return }
        await askSurface()
    }

    func askSurface() async {
        guard let source = SubstrateEngine.shared.serving else { return }
        guard let cli = source.cli else {
            surface = .noCLI(engine: source.label)
            return
        }
        surface = .asking
        let asked = await SubstrateCLI.ingestSurface(cli)
        guard !Task.isCancelled else {
            surface = .unasked
            return
        }
        surface = .known(asked)
    }

    /// The engine's read of the staged file: which format it would use, or which refusal it would
    /// give. Both come from `substrate formats`, so a file the engine will not take is named as
    /// such BEFORE a minute-long conversion rather than after it.
    var stagedFormat: SubstrateCLI.IngestFormat? {
        guard case .known(let asked) = surface, let document else { return nil }
        return asked.format(for: document)
    }

    var stagedRefusal: SubstrateCLI.RefusedFormat? {
        guard case .known(let asked) = surface, let document else { return nil }
        return asked.refusal(for: document)
    }

    /// PDF is the one format that requires a declared class, and it always has. Everything else
    /// defaults to absence by the engine's decision, not ours.
    var classRequired: Bool {
        guard case .known(let asked) = surface, let document, !forceMarkdown else { return false }
        return asked.requiresClass(for: document)
    }

    func stage(_ file: URL) {
        document = file
        forceMarkdown = false
        documentClass = nil
        job = .idle
    }

    // MARK: - The document rail

    /// Bring one document all the way in: extract it, put it in the vault, compose the scope.
    func addDocument() {
        guard !isWorking, let document, case .known(let asked) = surface,
              let cli = SubstrateEngine.shared.serving?.cli else { return }
        let chosen = documentClass
        let typed = domains
        let markdown = forceMarkdown
        task = Task { [weak self] in
            await self?.runAdd(cli: cli, file: document, surface: asked, forceMarkdown: markdown,
                               docClass: chosen, domains: typed)
        }
    }

    private func runAdd(cli: SubstrateEngine.Command, file: URL,
                        surface asked: SubstrateCLI.IngestSurface, forceMarkdown: Bool,
                        docClass: String?, domains: String) async {
        let title = "Adding \(file.lastPathComponent)"
        var steps: [Step] = []

        // 1. EXTRACT INTO STAGING, never straight into the vault. `compose` refuses the entire
        //    scope when one note fails to ingest, so a document written into the vault before it
        //    passed the class gate takes every other document down with it — and keeps doing so
        //    until someone finds the file.
        let out = SubstrateLibrary.staging
            .appendingPathComponent(SubstrateLibrary.slug(file.deletingPathExtension()
                .lastPathComponent), isDirectory: true)
        //    HOW THE FILE IS NAMED TO THE ENGINE IS THE ENGINE'S SHAPE, not a constant here.
        //    `ingest` grew a positional `path` and fourteen detected formats while this surface was
        //    being written; a hardcoded `--pdf` would have refused everything the widening added.
        var arguments = ["ingest"]
        if forceMarkdown, let flag = asked.markdownFlag {
            arguments += [flag, file.path]
        } else if asked.usesPositionalPath {
            arguments.append(file.path)
        } else if let flag = asked.inputFlags.first {
            arguments += [flag, file.path]
        } else {
            return finish(title: title, steps: [
                Step(id: "ingest", title: "Extract", run: nil,
                     appFailure: "This engine's `ingest` names no way to pass a file — neither a "
                        + "positional path nor an input flag — so Scripta will not guess at one.",
                     skipped: false)])
        }
        arguments += ["--out", out.path]
        if let docClass { arguments += ["--doc-class", docClass] }

        job = .running(Running(title: title, step: "Extracting", started: Date(), done: steps))
        let extraction = await SubstrateCLI.run(cli, arguments)
        steps.append(Step(id: "ingest", title: "Extract", run: extraction, appFailure: nil,
                          skipped: false))
        guard extraction.succeeded else {
            return finish(title: title, steps: steps + [
                Step(id: "promote", title: "Add to the library vault", run: nil, appFailure: nil,
                     skipped: true),
                Step(id: "compose", title: "Compose and register the scope", run: nil,
                     appFailure: nil, skipped: true)])
        }

        // 2. PROMOTE. The only step the app performs itself, and it writes three spine values the
        //    engine leaves absent — see `SubstrateLibrary.promote` for which and why.
        job = .running(Running(title: title, step: "Adding it to the library vault",
                               started: Date(), done: steps))
        var promoted: URL?
        do {
            promoted = try SubstrateLibrary.promote(
                SubstrateLibrary.Ingested(out: out, origin: file,
                                          domains: domains.split(separator: ",").map(String.init)))
            steps.append(Step(id: "promote", title: "Add to the library vault", run: nil,
                              appFailure: nil, skipped: false))
        } catch {
            return finish(title: title, steps: steps + [
                Step(id: "promote", title: "Add to the library vault", run: nil,
                     appFailure: error.localizedDescription, skipped: false),
                Step(id: "compose", title: "Compose and register the scope", run: nil,
                     appFailure: nil, skipped: true)])
        }

        // 3. COMPOSE. Without this the document is a file in a folder: present, unfindable, and
        //    indistinguishable from one that was never added.
        job = .running(Running(title: title, step: "Composing \(SubstrateLibrary.documentsScope)",
                               started: Date(), done: steps))
        let composed = await compose(cli: cli, vault: SubstrateLibrary.documentsVault,
                                     name: "library", clean: false)
        steps.append(Step(id: "compose", title: "Compose and register the scope", run: composed,
                          appFailure: nil, skipped: false))
        finish(title: title, steps: steps, orphaned: composed.succeeded ? nil : promoted)
    }

    /// Take one source back out of the library and recompose without it.
    ///
    /// The remedy for the one state this rail can leave behind: a document that passed extraction,
    /// entered the vault, and whose compose then refused. It is `--clean`, and it has to be — a
    /// removed note's ingest directory survives in the index root otherwise, and reconcile keeps
    /// answering from it.
    func remove(source: URL) {
        guard !isWorking, let cli = SubstrateEngine.shared.serving?.cli else { return }
        task = Task { [weak self] in
            guard let self else { return }
            let title = "Removing \(source.lastPathComponent)"
            var steps: [Step] = []
            job = .running(Running(title: title, step: "Removing it from the vault",
                                   started: Date(), done: steps))
            do {
                try FileManager.default.removeItem(at: source)
                steps.append(Step(id: "delete", title: "Remove from the library vault", run: nil,
                                  appFailure: nil, skipped: false))
            } catch {
                return finish(title: title, steps: [
                    Step(id: "delete", title: "Remove from the library vault", run: nil,
                         appFailure: error.localizedDescription, skipped: false),
                    Step(id: "compose", title: "Recompose the scope", run: nil, appFailure: nil,
                         skipped: true)])
            }
            job = .running(Running(title: title, step: "Recomposing", started: Date(), done: steps))
            let composed = await compose(cli: cli, vault: SubstrateLibrary.documentsVault,
                                         name: "library", clean: true)
            steps.append(Step(id: "compose", title: "Recompose the scope", run: composed,
                              appFailure: nil, skipped: false))
            finish(title: title, steps: steps)
        }
    }

    // MARK: - The transcript rail

    /// Recorded calls into a scope of their own, the same way a document goes in.
    ///
    /// The destination is enforced by the ENGINE, not checked here. `assert_not_synced` compares
    /// `(st_dev, st_ino)` against every File Provider root rather than testing a path prefix, which
    /// is the only check that catches `~/Documents` when "Desktop & Documents Folders" is syncing —
    /// measured on this machine as the same inode as its iCloud path. A second, weaker copy of that
    /// rule in Swift would disagree with the one that decides, and the refusal arrives before a
    /// single byte is written.
    func exportTranscripts() {
        guard !isWorking, let cli = SubstrateEngine.shared.serving?.cli else { return }
        let name = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        let destination = transcriptVault
        let source = AppSettings.outputFolder
        task = Task { [weak self] in
            await self?.runExport(cli: cli, source: source, vault: destination, workspace: name)
        }
    }

    private func runExport(cli: SubstrateEngine.Command, source: URL, vault: URL,
                           workspace: String) async {
        let title = "Exporting \(workspace) transcripts"
        var steps: [Step] = []

        job = .running(Running(title: title, step: "Writing the transcript vault", started: Date(),
                               done: steps))
        let exported = await SubstrateCLI.run(cli, ["export-transcripts", source.path, vault.path,
                                                   "--workspace", workspace])
        steps.append(Step(id: "export", title: "Write the transcript vault", run: exported,
                          appFailure: nil, skipped: false))
        guard exported.succeeded else {
            return finish(title: title, steps: steps + [
                Step(id: "compose", title: "Compose and register the scope", run: nil,
                     appFailure: nil, skipped: true)])
        }

        job = .running(Running(title: title, step: "Composing the transcript scope",
                               started: Date(), done: steps))
        // `--clean` because the exporter PRUNES: a transcript deleted in the app leaves no note
        // behind in the vault, and without this its ingest directory would keep answering.
        // NAMESPACED, so a workspace called "Library" cannot land its index on the document
        // library's. The two would otherwise share `index/library.db`, and compose writes the
        // database BEFORE it registers — so the collision would overwrite one corpus's index and
        // only then fail at registration, where `scopes.record` refuses to repoint a name at a
        // different vault. The refusal is right; arriving after the damage is not.
        let composed = await compose(cli: cli, vault: vault,
                                     name: "transcript-" + SubstrateLibrary.slug(workspace),
                                     clean: true)
        steps.append(Step(id: "compose", title: "Compose and register the scope", run: composed,
                          appFailure: nil, skipped: false))
        finish(title: title, steps: steps)
    }

    // MARK: - Compose

    /// The step that makes a vault answerable, with the index kept where indexes belong.
    ///
    /// `--index-root` and `--db` are STATED rather than left to default. `compose` resolves both
    /// against the working directory (`out-vault/index`, `out-vault/index.db`), so a run from an
    /// app whose cwd is the engine's export would write the operator's index tree into the pinned
    /// deployment. Both land under `~/.substrate/scripta/index`, which is the disposable layer the
    /// flag's own help says to keep off cloud-sync.
    private func compose(cli: SubstrateEngine.Command, vault: URL, name: String,
                         clean: Bool) async -> SubstrateRun {
        let root = SubstrateLibrary.root.appendingPathComponent("index", isDirectory: true)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        var arguments = ["compose", vault.path,
                         "--index-root", root.appendingPathComponent(name, isDirectory: true).path,
                         "--db", root.appendingPathComponent("\(name).db").path]
        if clean { arguments.append("--clean") }
        return await SubstrateCLI.run(cli, arguments)
    }

    /// The scope compose says it registered. READ FROM THE ENGINE'S OWN LINE rather than derived
    /// from the manifest this app wrote: `scopes.record` refuses to repoint an existing name at a
    /// different vault, so the name that ends up registered is the engine's answer and not ours to
    /// predict. Its last line is `  scope: 'name' registered in <path>`.
    private static func registeredScope(in run: SubstrateRun?) -> String? {
        guard let text = run?.stdout,
              let match = text.range(of: "scope: '[^']+' registered", options: .regularExpression)
        else { return nil }
        return String(text[match].dropFirst("scope: '".count).dropLast("' registered".count))
    }

    private func finish(title: String, steps: [Step], orphaned: URL? = nil) {
        let scope = Self.registeredScope(in: steps.first { $0.id == "compose" }?.run)
        job = .finished(Report(title: title, steps: steps, scope: scope, orphaned: orphaned))
        task = nil
        // The roster is what every scope chip and every refresh verdict is drawn from, and a job
        // that just registered a scope has changed it. Re-listed rather than patched locally: the
        // engine is the authority on what exists, and a locally-appended row would be this client
        // asserting a composition it only asked for.
        Task { await SubstrateScopes.shared.listScopes() }
    }

    func cancel() {
        task?.cancel()
        task = nil
    }

    /// Clear a finished report so the rail is ready for the next document.
    func dismiss() {
        guard case .finished = job else { return }
        job = .idle
        document = nil
        documentClass = nil
        forceMarkdown = false
    }
}
