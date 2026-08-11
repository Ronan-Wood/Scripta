import Foundation
import ScriptaCore
import SubstrateKit

/// The Library: bringing something into the engine, all the way to queryable.
///
/// THE WHOLE CHAIN RUNS IN THE APP. `ingest` writes an extraction, not an index — the engine is
/// explicit that composing and registering are separate acts, and its own compose
/// stops after writing the vault and prints the two commands. That is right for a CLI and wrong for
/// this surface: a Library that hands the operator a terminal command to finish what they started
/// has not shipped the feature, and Doc 3 §5 is emphatic that a note which exists and cannot be
/// found is the silent-absence state. So every job here ends with a compose, and the scope is
/// registered and answering before the surface says it is done.
///
/// PERFORMING THE WORK IS NOT HIDING IT. Every step reports the command it ran and everything the
/// process said, success included — `compose` exits 0 and warns on stderr when the
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

    /// Which direction of the scope relationship is on screen. Doc 4 §2 folds the vault browser in
    /// here rather than leaving it a section of its own, because the two are one relationship read
    /// both ways: this surface is the only thing that WRITES a scope, and browsing is what the
    /// scope then HOLDS. `VaultBrowseView`'s own header already called itself "the third sibling of
    /// Ask and the Library"; this is that sibling landing where it belongs.
    ///
    /// ON THE MODEL, NOT THE VIEW, and it moved here for the reason its previous host recorded:
    /// `HubContent` rebuilds this pane every time the sidebar reselects the section, so a `@State`
    /// lens silently resets to Add on the way back.
    enum Lens: String, CaseIterable, Identifiable {
        case add, vault
        var id: String { rawValue }
        var title: String {
            switch self {
            case .add: return "Add"
            case .vault: return "Vault"
            }
        }
    }

    @Published var lens: Lens = .add

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
    /// side after the engine closed it on its own — and it is the same shape as the
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
    /// Where this workspace's calls actually live. THE REAL ONE — this returned
    /// `SubstrateLibrary.transcriptVault`, a local non-synced path the export step used to fill and
    /// capture stopped writing to at §7, so the Library screen named a directory the operator would
    /// have found empty while every call landed somewhere else.
    var transcriptVault: URL? {
        vaultOverride ?? WorkspaceBindings.binding(for: workspace).transcriptVault
    }

    func chooseVault(_ url: URL) { vaultOverride = url }

    /// Follow the active workspace (Doc 3 §7). Called from `AppModel.activeGroup.didSet`, because
    /// this model is a singleton that outlives the pane and sampling `AppSettings.activeGroup` at
    /// init is what left the rail exporting into the workspace that was active when the app
    /// launched. Deferred mid-job: an export names its workspace in the vault manifest it is
    /// writing, and moving the target under a running compose is the desync this pair was just
    /// fixed for.
    ///
    /// DEFERRED, NOT DROPPED — the distinction is the whole of the second fix. Refusing outright
    /// left the rail bound to the workspace the operator had already left, permanently: nothing
    /// asks again, so the "It stays in X" sentence, the destination path and the scope this rail
    /// would compose all named a workspace that stopped being active mid-job. `finish` replays it.
    func adoptWorkspace() {
        guard !isWorking else { missedWorkspaceChange = true; return }
        let active = AppSettings.activeGroup
        guard workspace != active else { return }
        workspace = active          // `didSet` retires any hand-picked destination
    }

    /// That a change was missed, and deliberately NOT which one. By the time a job ends the active
    /// workspace may have moved again, and replaying a captured name would adopt a workspace the
    /// operator has since left — so the flag says only "ask again", and `adoptWorkspace` re-reads
    /// the authority.
    private var missedWorkspaceChange = false

    // MARK: - Transcripts that belong to no workspace

    /// The transcripts that will refuse the next export, and the remedy the engine names.
    ///
    /// `export_workspace` aborts the WHOLE export over any untagged transcript rather than skipping
    /// it — filing it under the workspace being exported asserts a claim nothing supports, and
    /// dropping it leaves a call in no scope at all. So one missing field blocks the corpus, and
    /// until this the only way to act on the refusal was to hand-edit YAML.
    @Published private(set) var untagged: [TranscriptGroupRepair.Untagged] = []

    /// Surfaced by the rail on appearance and after every repair. Cheap — a directory listing and a
    /// frontmatter read per file, over one non-recursive folder.
    func refreshUntagged() {
        // `nil` means the folder could not be read — NOT that there is nothing to repair. Shown
        // as an empty list, the rail would tell the operator their corpus is clean when it was
        // never looked at, which is the state this rail exists to make visible.
        if let found = TranscriptGroupRepair.untagged(in: AppSettings.outputFolder) {
            untagged = found
            repairFailure = nil
        } else {
            untagged = []
            repairFailure = "Could not read \(AppSettings.outputFolder.lastPathComponent), so "
                + "whether any transcripts need a workspace is unknown — this is not a report that "
                + "none do."
        }
    }

    /// File one untagged transcript under `workspace`. THE OPERATOR NAMES IT: nothing here infers a
    /// workspace from a filename, a date or the active selection, which is the same reason the
    /// engine refuses rather than guessing.
    func assign(_ transcript: TranscriptGroupRepair.Untagged) {
        let name = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !name.isEmpty else { return }
        // HELD, THEN PUBLISHED AFTER THE REFRESH. `refreshUntagged` clears `repairFailure` as its
        // own "this attempt is over" reset, and it runs at the end of every repair — so a failure
        // written here was wiped by the line meant to follow it, and the rail's red note could not
        // appear for the one thing it exists to report. The report has to outlive the refresh.
        var failure: String?
        do {
            try TranscriptGroupRepair.assign(name, to: transcript.url)
            // AND THEN IT MOVES. Stamping `group:` alone left the call in the flat output folder,
            // in no vault, therefore in no scope — visible in the app and unreachable by any query,
            // which is the state a repair is supposed to END. `substrate export-transcripts` used
            // to be the thing that moved it and no longer exists.
            let inherits = WorkspaceBindings.binding(for: name).contextVaults
            let filed = try TranscriptGroupRepair.file(transcript.url, into: name,
                                                       under: AppSettings.outputFolder,
                                                       inherits: inherits)
            // The local index partitions on `group` too, so a repair that only touched the file
            // would leave the call filed one way on disk and another in every in-app surface. The
            // index is pointed at the NEW location; indexing the old path would write a row naming
            // a file that is no longer there.
            if let store = IndexStore.shared {
                if filed != transcript.url { store.remove(path: transcript.url.path) }
                IndexBuilder.index(filed, into: store)
            } else {
                // AND A MISSING STORE IS THAT DIVERGENCE, NOT AN EXEMPTION FROM IT. `IndexStore` is
                // `try? IndexStore()`, so nil means the database would not open; skipping quietly
                // leaves the file carrying the workspace and every in-app surface still filing the
                // call the old way, with nothing to re-index it until the transcript changes on
                // disk again. Reported as a partial repair rather than as a failure, because the
                // half that the export and the engine read did land.
                failure = "\(transcript.title) has been filed into \(name)'s vault on disk, but "
                    + "the local index would not open — so Calls and search still file it the old "
                    + "way until you Rebuild Index in Settings. The vault holds the file itself, "
                    + "so composing that workspace will pick it up regardless."
            }
        } catch {
            failure = error.localizedDescription
        }
        refreshUntagged()
        if let failure { repairFailure = failure }
    }

    /// The last repair that failed, for the rail to show. Cleared by the next attempt.
    @Published var repairFailure: String?

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
        // DOMAINS BELONG TO THE DOCUMENT THEY WERE TYPED FOR. This is the class argument one axis
        // over: `domains` is what retrieval FILTERS on, so carrying the last document's over files
        // this one under a claim nobody made about it — and unlike a wrong class, a wrong domain is
        // invisible in the note itself. Cleared here and in `dismiss` because those are the two
        // moments a new document takes the rail; retyping four characters is cheaper than finding a
        // mislabelled source later.
        domains = ""
        job = .idle
    }

    // MARK: - The document rail

    /// Bring one document all the way in: extract it, put it in the vault, compose the scope.
    func addDocument() {
        guard !isWorking, let document, case .known(let asked) = surface,
              let cli = SubstrateEngine.shared.serving?.cli else { return }
        // REFUSED BEFORE THE INGEST, NOT AFTER IT. A document lands in the workspace's vault, and
        // `ScriptaVault` refuses a workspace that slugifies to nothing — which `""`, the
        // fresh-install default, does. Without this guard the first drop on a new machine ran a
        // full Docling extraction (the comment below measures a one-page PDF at 36 seconds) and
        // then died at the promote step. `composeWorkspace` already refuses up front for the same
        // reason; the upload path had no ungrouped story at all.
        guard (try? ScriptaVault.vault(forScope: workspace, under: AppSettings.outputFolder)) != nil
        else {
            job = .finished(Report(
                title: "Adding \(document.lastPathComponent)",
                steps: [Step(id: "workspace", title: "Choose a workspace", run: nil,
                             appFailure: "A document is added to a workspace's vault, and this "
                                 + "workspace has no usable name. Name the workspace first — "
                                 + "nothing was extracted, so nothing was wasted.",
                             skipped: false)],
                scope: nil, orphaned: nil))
            return
        }
        let chosen = documentClass
        let typed = domains
        let markdown = forceMarkdown
        // CAPTURED WITH ITS NEIGHBOURS. `workspace` was the one input read INSIDE the task, after a
        // multi-minute extraction — and the field stays editable while a job runs, so renaming the
        // workspace mid-extraction landed the document in a different vault (and a different
        // `inherits`) than the pre-flight guard validated and the rail's "It stays in X" sentence
        // named. The other three were already captured; this one was not, and nothing said so.
        let intoWorkspace = workspace
        task = Task { [weak self] in
            await self?.runAdd(cli: cli, file: document, surface: asked, forceMarkdown: markdown,
                               docClass: chosen, domains: typed, workspace: intoWorkspace)
        }
    }

    // MARK: - The three steps every document takes
    //
    // EXTRACTED SO THERE IS ONE DOCUMENT PATH (Doc 4 Phase 4b, step 2). `AppModel.importDocument`
    // used to run the app's own `DocumentImporter` — a second extractor, a second store under
    // `Files/`, and a document only the local index could see. It now runs THIS, so a document
    // dropped on a call and a document added from the Library rail take the same three steps and
    // land in the same place.
    //
    // WHAT IS NOT HERE IS THE UI, and that is the whole reason it is separate. The rail reports a
    // step-by-step card built from `[Step]`; the drop path reports one inline row that is
    // processing, done, or failed. Both are honest renderings of the same outcome, and neither is
    // the other's business — so this returns what happened and calls `progress` as it moves,
    // rather than owning a `job`.

    enum AddPhase { case extracting, promoting, composing }

    /// What the three steps produced. Every field is what the caller needs to say what happened —
    /// a run for each engine step, and the app's own failure for the one step the app performs.
    struct AddOutcome {
        /// Nil when this engine's `ingest` names no way to pass a file, which is refused before
        /// anything runs. `surfaceFailure` carries the sentence in that case.
        let extraction: SubstrateRun?
        let surfaceFailure: String?
        let promoted: URL?
        let vault: ScriptaVault?
        let promoteFailure: String?
        /// Nil when an earlier step failed or the task was stopped between steps.
        let composed: SubstrateRun?

        var succeeded: Bool { composed?.succeeded == true }

        /// The first thing that went wrong, in the order the steps run — for a caller with one
        /// line to say it in.
        var failure: String? {
            if let surfaceFailure { return surfaceFailure }
            if let extraction, !extraction.succeeded {
                return extraction.stderr.isEmpty ? "The engine could not extract that file."
                                                 : extraction.stderr
            }
            if let promoteFailure { return promoteFailure }
            if let composed, !composed.succeeded {
                return composed.stderr.isEmpty
                    ? "It was added to the vault but the scope would not compose, so it is not "
                      + "findable yet." : composed.stderr
            }
            return succeeded ? nil : "The document was not added."
        }
    }

    static func performAdd(
        cli: SubstrateEngine.Command, file: URL, surface asked: SubstrateCLI.IngestSurface,
        forceMarkdown: Bool, docClass: String?, domains: String, workspace: String,
        progress: @escaping @MainActor (AddPhase) -> Void
    ) async -> AddOutcome {
        // 1. EXTRACT INTO STAGING, never straight into the vault. `compose` refuses the entire
        //    scope when one note fails to ingest, so a document written into the vault before it
        //    passed the class gate takes every other document down with it — and keeps doing so
        //    until someone finds the file.
        //    AND THE EXTRACTION DOES NOT OUTLIVE THE JOB. It is the document's full text in
        //    cleartext and it has no reader once `promote` has copied it into the vault.
        let out = SubstrateLibrary.stagingRun(for: file)
        defer { try? FileManager.default.removeItem(at: out) }

        //    HOW THE FILE IS NAMED TO THE ENGINE IS THE ENGINE'S SHAPE, not a constant here.
        var arguments = ["ingest"]
        if forceMarkdown, let flag = asked.markdownFlag {
            arguments += [flag, file.path]
        } else if asked.usesPositionalPath {
            arguments.append(file.path)
        } else if let flag = asked.inputFlags.first {
            arguments += [flag, file.path]
        } else {
            return AddOutcome(
                extraction: nil,
                surfaceFailure: "This engine's `ingest` names no way to pass a file — neither a "
                    + "positional path nor an input flag — so Scripta will not guess at one.",
                promoted: nil, vault: nil, promoteFailure: nil, composed: nil)
        }
        arguments += ["--out", out.path]
        if let docClass { arguments += ["--doc-class", docClass] }

        await progress(.extracting)
        let extraction = await SubstrateCLI.run(cli, arguments)
        // STOPPED IS CHECKED BETWEEN THE STEPS, because neither of the two below can be stopped
        // once begun: promote is a file copy, and a compose launched into an already-cancelled
        // task is a subprocess started only to be killed.
        guard extraction.succeeded, !Task.isCancelled else {
            return AddOutcome(extraction: extraction, surfaceFailure: nil, promoted: nil,
                              vault: nil, promoteFailure: nil, composed: nil)
        }

        // 2. PROMOTE. The only step the app performs itself, and it writes three spine values the
        //    engine leaves absent — see `SubstrateLibrary.promote` for which and why.
        await progress(.promoting)
        let promoted: URL
        let target: ScriptaVault
        do {
            // THE WORKSPACE'S VAULT (Doc 4 §7, corrected): an upload is walled by default and
            // promoted to a shared core vault deliberately, the same rule notes follow.
            target = try ScriptaVault.vault(forScope: workspace, under: AppSettings.outputFolder,
                                            inherits: WorkspaceBindings.binding(for: workspace)
                                                .contextVaults)
            promoted = try SubstrateLibrary.promote(
                SubstrateLibrary.Ingested(out: out, origin: file,
                                          domains: domains.split(separator: ",").map(String.init)),
                into: target)
        } catch {
            return AddOutcome(extraction: extraction, surfaceFailure: nil, promoted: nil,
                              vault: nil, promoteFailure: error.localizedDescription,
                              composed: nil)
        }

        // 3. COMPOSE. Without this the document is a file in a folder: present, unfindable, and
        //    indistinguishable from one that was never added.
        await progress(.composing)
        let composed = await composeVault(cli: cli, vault: target.root, name: target.scope,
                                          clean: false)
        return AddOutcome(extraction: extraction, surfaceFailure: nil, promoted: promoted,
                          vault: target, promoteFailure: nil, composed: composed)
    }

    /// The rail's rendering of `performAdd` — a step-by-step card.
    ///
    /// Every line here is UI. The pipeline itself moved to `performAdd` so the drop path could run
    /// the same one (Doc 4 Phase 4b); what is left is the mapping from "what happened" to the four
    /// `Step`s this surface shows, including the two that report as SKIPPED when an earlier step
    /// stopped the run — which is what makes a failed add legible rather than just short.
    private func runAdd(cli: SubstrateEngine.Command, file: URL,
                        surface asked: SubstrateCLI.IngestSurface, forceMarkdown: Bool,
                        docClass: String?, domains: String, workspace: String) async {
        let title = "Adding \(file.lastPathComponent)"
        var done: [Step] = []

        let outcome = await Self.performAdd(
            cli: cli, file: file, surface: asked, forceMarkdown: forceMarkdown,
            docClass: docClass, domains: domains, workspace: workspace
        ) { [weak self] phase in
            guard let self else { return }
            let step: String
            switch phase {
            case .extracting: step = "Extracting"
            case .promoting: step = "Adding it to the library vault"
            case .composing: step = "Composing the scope"
            }
            job = .running(Running(title: title, step: step, started: Date(), done: done))
        }

        // The surface refusal never reached the engine, so it is the app's failure on the first
        // step rather than a run that came back badly.
        if let surfaceFailure = outcome.surfaceFailure {
            return finish(title: title, steps: [
                Step(id: "ingest", title: "Extract", run: nil, appFailure: surfaceFailure,
                     skipped: false)])
        }

        done.append(Step(id: "ingest", title: "Extract", run: outcome.extraction,
                         appFailure: nil, skipped: false))
        guard outcome.extraction?.succeeded == true else {
            return finish(title: title, steps: done + [
                Step(id: "promote", title: "Add to the library vault", run: nil, appFailure: nil,
                     skipped: true),
                Step(id: "compose", title: "Compose and register the scope", run: nil,
                     appFailure: nil, skipped: true)])
        }

        done.append(Step(id: "promote", title: "Add to the library vault", run: nil,
                         appFailure: outcome.promoteFailure, skipped: false))
        guard outcome.promoteFailure == nil else {
            return finish(title: title, steps: done + [
                Step(id: "compose", title: "Compose and register the scope", run: nil,
                     appFailure: nil, skipped: true)])
        }

        // A compose that never ran is a stop between the steps, not a failure of the compose.
        guard let composed = outcome.composed else {
            return finish(title: title, steps: done + [
                Step(id: "compose", title: "Compose and register the scope", run: nil,
                     appFailure: nil, skipped: true)])
        }
        done.append(Step(id: "compose", title: "Compose and register the scope", run: composed,
                         appFailure: nil, skipped: false))
        finish(title: title, steps: done,
               orphaned: composed.succeeded ? nil : outcome.promoted)
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
                // THE GUARD MOVED WITH THE DESTINATION. This recursively removes a directory, and
                // until documents were promoted into the workspace vault it only ever operated
                // inside `~/.substrate` — a folder this app owns outright. It now operates inside
                // the OPERATOR'S output folder, where a wrong URL deletes their work. Constrained
                // to the vault's own `10-reference/`, so nothing outside the directory this app
                // writes documents into can be passed to it.
                let vault = try ScriptaVault.vault(forScope: workspace, under: AppSettings.outputFolder)
                let references = vault.references.standardizedFileURL.path
                let target = source.standardizedFileURL
                guard target.deletingLastPathComponent().path == references else {
                    throw SubstrateLibrary.LibraryError.outsideTheLibrary(source)
                }
                try FileManager.default.removeItem(at: target)
                steps.append(Step(id: "delete", title: "Remove from the library vault", run: nil,
                                  appFailure: nil, skipped: false))
            } catch {
                return finish(title: title, steps: [
                    Step(id: "delete", title: "Remove from the library vault", run: nil,
                         appFailure: error.localizedDescription, skipped: false),
                    Step(id: "compose", title: "Recompose the scope", run: nil, appFailure: nil,
                         skipped: true)])
            }
            // A STOP IS HONOURED BEFORE THE RECOMPOSE, NOT DURING IT. This compose is `--clean`:
            // launching it into a cancelled task means SIGTERM arriving somewhere inside a wipe of
            // the index root. The scope is left answering from a note that is no longer on disk,
            // which the next compose refuses over loudly (`assert_composed`) rather than serving
            // quietly — the right way round for a job the operator stopped halfway.
            guard !Task.isCancelled else {
                return finish(title: title, steps: steps + [
                    Step(id: "compose", title: "Recompose the scope", run: nil, appFailure: nil,
                         skipped: true)])
            }
            job = .running(Running(title: title, step: "Recomposing", started: Date(), done: steps))
            // Recomposed against the workspace vault the document was promoted into. `--clean`
            // because a removal must leave no ingest directory behind still answering queries.
            let vault = try? ScriptaVault.vault(forScope: workspace, under: AppSettings.outputFolder)
            let composed = await Self.composeVault(cli: cli,
                                         vault: vault?.root ?? AppSettings.outputFolder,
                                         name: vault?.scope ?? "library", clean: true)
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
    /// Make this workspace's vault answerable: compose it and register its scope.
    ///
    /// THERE IS NOTHING TO EXPORT ANY MORE. This rail used to run `substrate export-transcripts`,
    /// which rendered the flat output folder's transcripts into a vault — and Doc 4 §7 removed the
    /// premise by having capture write into the vault directly. The exporter is gone; what is left
    /// is the half that was always doing the real work.
    ///
    /// It had also stopped being able to run at all. The vault now lives under the operator's own
    /// output folder, so `assert_not_overlapping` refused the destination for containing the
    /// source, and `assert_not_synced` refused it for being in OneDrive — a rule §7 explicitly
    /// withdrew (location is the operator's). The button could produce nothing but a refusal
    /// arguing from a retired decision.
    func composeWorkspace() {
        guard !isWorking, let cli = SubstrateEngine.shared.serving?.cli else { return }
        let name = workspace.trimmingCharacters(in: .whitespacesAndNewlines)
        // SLUGIFIABLE, NOT MERELY NON-EMPTY. A name carrying no ASCII letter or digit — "研究",
        // "———", an emoji — passes a non-empty test and slugifies to nothing, and every other holder
        // of this value already refuses it: `ScriptaVault.init` throws `unnameableScope`,
        // `TranscriptGroupRepair.assign` refuses the repair. Refused here for the reason
        // `addDocument` states: nothing is spent.
        guard !SubstrateLibrary.slug(name).isEmpty else {
            job = .finished(Report(
                title: "Composing \(name.isEmpty ? "this workspace" : name)",
                steps: [Step(id: "workspace", title: "Name the workspace", run: nil,
                             appFailure: "A workspace's calls live in a vault named after it and "
                                 + "compose under a scope named after it, and "
                                 + "\(name.isEmpty ? "an unnamed workspace" : "\"\(name)\"") "
                                 + "reduces to nothing that can name either — the engine and the "
                                 + "vault layout both take ASCII letters and digits only. Give the "
                                 + "workspace a name with at least one ASCII letter or digit; the "
                                 + "calls themselves are untouched either way.",
                             skipped: false)],
                // Nothing composed, so nothing registered — and no document was left anywhere.
                scope: nil, orphaned: nil))
            return
        }

        // The vault is READ, not created. Capture writes it, and a rail that constructed one here
        // would be a second author for the layout — the shape §7 spent the whole migration removing.
        let root = AppSettings.outputFolder
        let (existing, failures) = ScriptaVault.existingVault(forScope: name, under: root)
        guard let vault = existing else {
            job = .finished(Report(
                title: "Composing \(name)",
                steps: [Step(id: "vault", title: "Find the workspace's vault", run: nil,
                             appFailure: "There is no vault for \"\(name)\" under \(root.path) "
                                 + "yet. One is written the first time a call is recorded into "
                                 + "this workspace, so record a call — or switch to the workspace "
                                 + "whose vault you meant."
                                 + (failures.isEmpty ? ""
                                    : "\n\nSome directories could not be read: "
                                      + failures.joined(separator: "; ")),
                             skipped: false)],
                scope: nil, orphaned: nil))
            return
        }
        task = Task { [weak self] in
            await self?.runCompose(cli: cli, vault: vault, workspace: name)
        }
    }

    /// Compose the active workspace's vault after a call lands in it, without taking over the
    /// Library's job strip.
    ///
    /// QUIET BY DESIGN. `composeWorkspace` drives the visible rail and refuses when another job is
    /// running, which is right for a button and wrong here: a recording finishing must not depend on
    /// whether the operator happens to be uploading a document, and it must not replace a report
    /// they are reading. This runs its own task, writes no `job`, and is skipped rather than queued
    /// when the rail is busy — the refresh agent still comes round, so the cost of skipping is
    /// freshness, not content.
    func composeAfterRecording() {
        let name = AppSettings.activeGroup.trimmingCharacters(in: .whitespacesAndNewlines)
        let scope = name.isEmpty ? ScriptaVault.defaultScope : name
        guard !isWorking, !SubstrateLibrary.slug(scope).isEmpty,
              let cli = SubstrateEngine.shared.serving?.cli,
              let vault = ScriptaVault.existingVault(forScope: scope,
                                                     under: AppSettings.outputFolder).vault
        else { return }
        Task { [weak self] in
            _ = await Self.composeVault(cli: cli, vault: vault,
                                        name: SubstrateLibrary.slug(scope), clean: true)
            // The roster now reports a scope whose index moved, and the tier chips are drawn from
            // it — re-listed so a call recorded seconds ago is askable without a relaunch.
            await SubstrateScopes.shared.listScopes()
        }
    }

    private func runCompose(cli: SubstrateEngine.Command, vault: URL, workspace: String) async {
        let title = "Composing \(workspace)"
        let name = SubstrateLibrary.slug(workspace)
        // `--clean`, because a call deleted in the app must stop answering. The vault holds only
        // what capture put there, so a stale ingest directory is the one way a deleted call comes
        // back — and `assert_composed` would refuse the next compose over it anyway, after the
        // operator had already deleted it for a reason.
        let composed = await Self.composeVault(cli: cli, vault: vault, name: name, clean: true)
        finish(title: title,
               steps: [Step(id: "compose", title: "Compose and register the scope", run: composed,
                            appFailure: nil, skipped: false)])
    }

    /// Where a scope's index ALREADY lives, when it is already registered.
    ///
    /// A COMPOSE MUST NOT MOVE AN INDEX. `scopes.record` refuses to repoint a name at a different
    /// VAULT and permits a different db, so composing with this app's own default silently
    /// relocated an existing scope's database — and the refresh agent does not read the registry.
    /// It recomposes `$DATA/<scope>.db` on its own schedule, so after a move the agent maintains a
    /// file nothing resolves to and every query answers from an index that has quietly stopped
    /// being refreshed. Nothing reports that: the scope still answers, with content ageing out.
    ///
    /// Reproduced on the operator's `cbre` 2026-08-07 and restored the same way — recompose at the
    /// path the roster names.
    private static func registeredDatabase(named scope: String) -> URL? {
        guard case .listed(let rows) = SubstrateScopes.shared.roster,
              let row = rows.first(where: { $0.scope == scope }), !row.db.isEmpty else { return nil }
        return URL(fileURLWithPath: row.db)
    }

    // MARK: - Compose

    /// The step that makes a vault answerable, with the index kept where indexes belong.
    ///
    /// `--index-root` and `--db` are STATED rather than left to default. `compose` resolves both
    /// against the working directory (`out-vault/index`, `out-vault/index.db`), so a run from an
    /// app whose cwd is the engine's export would write the operator's index tree into the pinned
    /// deployment. Both land under `~/.substrate/scripta/index`, which is the disposable layer the
    /// flag's own help says to keep off cloud-sync.
    static func composeVault(cli: SubstrateEngine.Command, vault: URL, name: String,
                             clean: Bool) async -> SubstrateRun {
        // AN ALREADY-REGISTERED SCOPE KEEPS ITS OWN LOCATION, and the lookup is HERE rather than at
        // each call site so no caller can forget it. All three compose the workspace's own scope
        // now — the transcript rail and both document paths — so all three could move it.
        let database: URL
        let indexRoot: URL
        if let existingDatabase = Self.registeredDatabase(named: name) {
            database = existingDatabase
            indexRoot = existingDatabase.deletingLastPathComponent()
                .appendingPathComponent("\(name)-index", isDirectory: true)
        } else {
            let root = SubstrateLibrary.root.appendingPathComponent("index", isDirectory: true)
            database = root.appendingPathComponent("\(name).db")
            indexRoot = root.appendingPathComponent(name, isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: database.deletingLastPathComponent(),
                                                 withIntermediateDirectories: true)
        var arguments = ["compose", vault.path,
                         "--index-root", indexRoot.path,
                         "--db", database.path]
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
        // ONLY A COMPOSE THAT SUCCEEDED REGISTERED ANYTHING. The registration line is printed
        // DURING the run, so a compose that named the scope and then exited non-zero — or was
        // stopped after printing it — would have put "it is composed and registered, so it is
        // answering in Ask now" on screen beside a refused step. Read from a failed run, the line is
        // a claim about a state the engine did not reach; absent, the card says nothing about
        // registration, which is what an unverified one is worth. This is the single gate rather
        // than a second condition in the card, because compose is always the last step: a report
        // whose compose succeeded has no failure after it to contradict.
        let composed = steps.first { $0.id == "compose" }?.run
        let scope = composed?.succeeded == true ? Self.registeredScope(in: composed) : nil
        job = .finished(Report(title: title, steps: steps, scope: scope, orphaned: orphaned))
        task = nil
        // The workspace change this job refused, taken now that it can be. Re-asked rather than
        // replayed — see `missedWorkspaceChange`.
        if missedWorkspaceChange {
            missedWorkspaceChange = false
            adoptWorkspace()
        }
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
        domains = ""   // for the reason `stage` gives: this field is per-document, like the class
    }
}
