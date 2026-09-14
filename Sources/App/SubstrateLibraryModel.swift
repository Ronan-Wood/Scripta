import Foundation
import OSLog
import ScriptaCore
import ScriptaShared
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

    /// For the paths with no surface to report on — `composeAfterRecording` writes no `job` by
    /// design, and the drop path's `ImportJob` has no per-step row — so a failure they do not log
    /// is a failure nothing records.
    static let log = Logger(subsystem: "com.ronanwood.Scripta", category: "Library")

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
        /// This step did not run. Usually because an earlier one failed; also, on the removal rail,
        /// because there was nothing left to do. Drawn as absence, never as success or as failure.
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
    /// THREE LENSES, AND `add` MEANS ONLY ADD. It used to carry the scope roster, the refresh record
    /// and the transcript-vault settings underneath the one form anybody opened it for — so adding a
    /// note put a page of engine diagnostics, two identical six-line compose refusals among them, in
    /// front of someone who had come to type a sentence. Those are the state of what is ALREADY
    /// here, which is a different question from adding to it, and they now have their own lens.
    enum Lens: String, CaseIterable, Identifiable {
        case vault, add, status
        var id: String { rawValue }
        var title: String {
            switch self {
            case .vault: return "Vault"
            case .add: return "Add"
            case .status: return "Status"
            }
        }
    }

    /// VAULT FIRST, and it is the default. Looking at the corpus is the everyday act;
    /// adding to it is deliberate and occasional, so the surface opens on the one you reach for.
    @Published var lens: Lens = .vault

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

    /// The Add page's note draft, and which kind is selected.
    ///
    /// ON THE MODEL FOR THE REASON `lens` IS. These were `@State` on the rail, whose identity is
    /// destroyed both by the lens switch and by `HubContent` rebuilding the pane on every sidebar
    /// reselect — so typing a note body, clicking Status to check the engine, and coming back lost
    /// the body. This codebase has already paid for that hazard three times and written it down
    /// each time (`lens` itself, `AskModel`, `CallsLensModel`); a fourth was not needed.
    @Published var noteDraft = NoteDraft()
    @Published var addKind = AddKind.document

    /// The things the Add page can add. Recording a call is not among them — a call arrives by
    /// being recorded; UPLOADING one you already have is a different act, and is `.transcript`.
    enum AddKind: String, CaseIterable, Identifiable {
        case document, transcript, note
        var id: String { rawValue }

        var label: String {
            switch self {
            case .document: return "A document"
            case .transcript: return "A call transcript"
            case .note: return "A note"
            }
        }

        var hint: String {
            switch self {
            case .document:
                return "A PDF, Word or Markdown file, read into passages you can ask about."
            case .transcript:
                return "A recording from somewhere else. Filed with your calls and kept out of "
                     + "answers by default, like they are."
            case .note:
                return "Something you write yourself."
            }
        }
    }

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
    /// - Parameter tier: `.transcript` uploads a conversation into the same directory a recorded
    ///   call lands in, and FORCES `class: conversation` with it. The two must move together: the
    ///   folder gives the passages their tier and the class is what keeps them out of default
    ///   retrieval, so a transcript filed in the right place while declaring itself a reference
    ///   would still arrive uninvited in every query.
    func addDocument(tier: SubstrateLibrary.PromotionTier = .reference) {
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
        let chosen = tier == .transcript ? SubstrateLibrary.conversationClass : documentClass
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
                               docClass: chosen, domains: typed, workspace: intoWorkspace,
                               tier: tier)
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
        /// The WHOLE compose outcome, embed included. Nil when an earlier step failed or the task
        /// was stopped between steps.
        ///
        /// It was `SubstrateRun` — the compose alone — which is how this path came to drop the embed
        /// result: there was nowhere to put it. Carrying the outcome rather than one of its halves
        /// is what lets `runAdd` report the same embed step the note paths do.
        let composed: ComposeOutcome?

        /// KEYED ON THE COMPOSE, not on the embed. A down embedder makes a document harder to find,
        /// not absent — the lexical arm still answers — so it is never a failed add. That is the
        /// same call `composeVault` makes about fatality.
        ///
        /// A caller that reads only this reports a clean add over passages with no vectors, so
        /// `warning` exists beside it and answers that half.
        var succeeded: Bool { composed?.run.succeeded == true }

        /// Something the operator should know that did NOT stop the add.
        ///
        /// SEPARATE FROM `failure` BECAUSE THEY ARE DIFFERENT QUESTIONS, and the engine draws the
        /// same line rather than this being a local convention: `refresh_state` records
        /// `embed_failed` as `success: False, frozen: False` — the pass did not fully succeed, AND
        /// the index still agrees with its vault. `succeeded` here answers "was the document
        /// added", which is yes; this answers "is there anything wrong with it", which is also yes.
        /// The two used to disagree only because the second question had nowhere to be asked, so a
        /// caller had to know to reach into `composed?.embedFailed` — and the one that did not know
        /// reported success.
        var warning: String? {
            guard composed?.embedFailed == true else { return nil }
            return "It was added and the scope composed, but its passages were not vectored — so it "
                 + "is found by exact wording only until this workspace is recomposed with the "
                 + "embedding model reachable."
        }

        /// The first thing that went wrong, in the order the steps run — for a caller with one
        /// line to say it in.
        var failure: String? {
            if let surfaceFailure { return surfaceFailure }
            if let extraction, !extraction.succeeded {
                return extraction.stderr.isEmpty ? "The engine could not extract that file."
                                                 : extraction.stderr
            }
            if let promoteFailure { return promoteFailure }
            if let composed, !composed.run.succeeded {
                return composed.run.stderr.isEmpty
                    ? "It was added to the vault but the scope would not compose, so it is not "
                      + "findable yet." : composed.run.stderr
            }
            return succeeded ? nil : "The document was not added."
        }
    }

    static func performAdd(
        cli: SubstrateEngine.Command, file: URL, surface asked: SubstrateCLI.IngestSurface,
        forceMarkdown: Bool, docClass: String?, domains: String, workspace: String,
        tier: SubstrateLibrary.PromotionTier = .reference,
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
                into: target, tier: tier)
        } catch {
            return AddOutcome(extraction: extraction, surfaceFailure: nil, promoted: nil,
                              vault: nil, promoteFailure: error.localizedDescription,
                              composed: nil)
        }

        // 3. COMPOSE. Without this the document is a file in a folder: present, unfindable, and
        //    indistinguishable from one that was never added.
        await progress(.composing)
        let composedOutcome = await composeVault(cli: cli, vault: target.root, name: target.scope,
                                          clean: false)
        return AddOutcome(extraction: extraction, surfaceFailure: nil, promoted: promoted,
                          vault: target, promoteFailure: nil, composed: composedOutcome)
    }

    /// The rail's rendering of `performAdd` — a step-by-step card.
    ///
    /// Every line here is UI. The pipeline itself moved to `performAdd` so the drop path could run
    /// the same one (Doc 4 Phase 4b); what is left is the mapping from "what happened" to the four
    /// `Step`s this surface shows, including the three that report as SKIPPED when an earlier step
    /// stopped the run — which is what makes a failed add legible rather than just short.
    private func runAdd(cli: SubstrateEngine.Command, file: URL,
                        surface asked: SubstrateCLI.IngestSurface, forceMarkdown: Bool,
                        docClass: String?, domains: String, workspace: String,
                        tier: SubstrateLibrary.PromotionTier) async {
        let title = "Adding \(file.lastPathComponent)"
        var done: [Step] = []

        let outcome = await Self.performAdd(
            cli: cli, file: file, surface: asked, forceMarkdown: forceMarkdown,
            docClass: docClass, domains: domains, workspace: workspace, tier: tier
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

        // THE EMBED IS A STEP NOW, so each path that stops after the pipeline began draws it as
        // skipped. A card showing three steps when the add fails and four when it works reads as
        // two different pipelines, and the skipped rows are what make a stopped run legible rather
        // than just short — the reason the compose row is already drawn this way. Built by
        // `embedStep` like the success row, so both spellings of this step come from one place: a
        // hand-copied title and a second id scheme is the divergence `finish`'s own comment warns
        // about.
        //
        // NOT THE SURFACE REFUSAL ABOVE, which returns the ingest row alone and no skipped rows at
        // all. That one never reached the engine, so there is no pipeline to report the shape of —
        // it is deliberately the short card, and this comment claimed otherwise for a while.
        let embedSkipped = Self.embedStep(scope: outcome.vault?.scope ?? workspace, composed: nil)

        done.append(Step(id: "ingest", title: "Extract", run: outcome.extraction,
                         appFailure: nil, skipped: false))
        guard outcome.extraction?.succeeded == true else {
            return finish(title: title, steps: done + [
                Step(id: "promote", title: "Add to the library vault", run: nil, appFailure: nil,
                     skipped: true),
                Step(id: "compose", title: "Compose and register the scope", run: nil,
                     appFailure: nil, skipped: true),
                embedSkipped])
        }

        done.append(Step(id: "promote", title: "Add to the library vault", run: nil,
                         appFailure: outcome.promoteFailure, skipped: false))
        guard outcome.promoteFailure == nil else {
            return finish(title: title, steps: done + [
                Step(id: "compose", title: "Compose and register the scope", run: nil,
                     appFailure: nil, skipped: true),
                embedSkipped])
        }

        // A compose that never ran is a stop between the steps, not a failure of the compose.
        guard let composed = outcome.composed else {
            return finish(title: title, steps: done + [
                Step(id: "compose", title: "Compose and register the scope", run: nil,
                     appFailure: nil, skipped: true),
                embedSkipped])
        }
        done.append(Step(id: "compose", title: "Compose and register the scope", run: composed.run,
                         appFailure: nil, skipped: false))
        // THE EMBED THIS ADD ALREADY RAN, finally reported. `composeVault` has embedded on every
        // path since the two note paths stopped doing it themselves — but this one took `.run` and
        // discarded the rest, so a document added while the embedder was unreachable showed three
        // green steps over passages findable only by exact word match. Nothing said so, on the rail
        // built to say what happened.
        done.append(Self.embedStep(scope: outcome.vault?.scope ?? workspace, composed: composed))
        finish(title: title, steps: done,
               orphaned: composed.run.succeeded ? nil : outcome.promoted)
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
                // to the vault's own promotion directories, and within them to the directory shape
                // `promote` writes — both halves below, because neither holds on its own.
                let vault = try ScriptaVault.vault(forScope: workspace, under: AppSettings.outputFolder)
                // EITHER PROMOTION DIRECTORY. It was `10-reference/` alone, which made this remedy
                // unreachable for an uploaded transcript — and the orphan row that offers it is
                // drawn unconditionally, so the one state it exists for (a source on disk, in no
                // index, refusing every later compose) ended in `outsideTheLibrary` for exactly the
                // kind this session added.
                // RESOLVED, NOT STANDARDISED, ON BOTH SIDES. `standardizedFileURL` collapses `.`
                // and `..` lexically and deliberately does NOT resolve symlinks — while
                // `removeItem` follows every intermediate component the kernel gives it. So a
                // symlinked ancestor (`10-reference`, `_sources`, or the output folder itself)
                // made the parent STRING match while the delete landed in another tree entirely.
                // Resolving both sides compares what the filesystem will actually walk. A vault
                // that legitimately lives behind a symlink still matches, because both sides
                // resolve to the same real path.
                //
                // The final component is resolved on the ALLOWED side only. `target` keeps its own
                // last component unresolved, because a promoted source that IS a symlink must stay
                // removable as a link — resolving it would compare the thing it points at.
                let allowed = Set(SubstrateLibrary.PromotionTier.allDirectories(in: vault)
                    .map { $0.resolvingSymlinksInPath().path })
                let standardized = source.standardizedFileURL
                let target = standardized.deletingLastPathComponent()
                    .resolvingSymlinksInPath()
                    .appendingPathComponent(standardized.lastPathComponent, isDirectory: true)
                // THE PARENT IS NOT ENOUGH, and widening it to both tiers is what made that matter.
                // `_sources/transcripts/` is now an allowed parent AND the directory capture writes
                // recorded calls into, so a parent-only guard admitted a call to a recursive,
                // trashless unlink. All four clauses below are the answer — the target must BE a
                // promoted source this app wrote: a directory carrying
                // the `<slug>-<8 hex>` name `promote` writes AND the marker file it leaves inside.
                guard allowed.contains(target.deletingLastPathComponent().path),
                      PromotedSource.isDirectoryName(target.lastPathComponent)
                else {
                    throw SubstrateLibrary.LibraryError.outsideTheLibrary(source)
                }
                // `lstat`, NOT `fileExists`. The stat has to answer "is there an entry here",
                // and `fileExists` answers "is there a reachable TARGET here" — it follows
                // symlinks, so a DANGLING one reads as absent. That matters because absent is now
                // the skip-and-recompose branch: a dangling symlink wearing a promoted name would
                // be reported as already removed, finish green, and still be sitting there for the
                // recompose to trip over — the exact orphan the operator pressed the button to
                // clear. `lstat` describes the entry itself, which is also what `removeItem` acts
                // on (it unlinks a symlink rather than following it).
                //
                // A STAT THAT FAILS FOR ANY OTHER REASON IS A REFUSAL, not an absence. ONLY
                // `NSFileReadNoSuchFileError` means "already gone". A permissions failure means we
                // cannot tell, and guessing "gone" there reports a live source as cleared and then
                // recomposes around it. Measured 2026-08-19: a live directory under an unreadable
                // parent throws 257 while genuine absence throws 260 — and `fileExists` returns
                // false for BOTH, which is why an earlier version of this that fell back to it
                // distinguished nothing and contradicted this very comment.
                let exists: Bool
                do {
                    let entry = try FileManager.default.attributesOfItem(atPath: target.path)
                    // A REGULAR FILE wearing a promoted directory's name is the containment case:
                    // `promote` only ever writes directories, so a file of that name is not
                    // something this rail wrote. A SYMLINK IS ADMITTED, deliberately — the stat is
                    // lstat-like, so this is the link itself, and `removeItem` unlinks a link
                    // without following it. Removing it therefore clears an orphan entry and
                    // cannot touch whatever it points at, inside the vault or outside it.
                    let type = entry[.type] as? FileAttributeType
                    guard type == .typeDirectory || type == .typeSymbolicLink else {
                        throw SubstrateLibrary.LibraryError.outsideTheLibrary(source)
                    }
                    // AUTHORSHIP, NOT RESEMBLANCE — the last thing the guard checks and the only
                    // one that is evidence rather than inference. The name proves the SHAPE
                    // `promote` writes, which an operator's own directory can wear by accident:
                    // `my-notes-2026abcd`, `backup-20250101` and `photos-20240704` all pass every
                    // other clause. And the presence of `_meta.md` proves nothing either — that is
                    // the ENGINE's per-source convention, so a hand-built source has one too. What
                    // identifies ours is the line `promote` writes INSIDE it; see
                    // `PromotedSource.isAuthoredDirectory`, which owns both halves. A symlink is
                    // exempt because it has no inside to look in — removing one unlinks the link
                    // and cannot touch what it points at.
                    if type == .typeDirectory {
                        guard PromotedSource.isAuthoredDirectory(at: target) else {
                            throw SubstrateLibrary.LibraryError.notThisAppsSource(source)
                        }
                    }
                    exists = true
                } catch let error as NSError where error.domain == NSCocoaErrorDomain
                                                && error.code == NSFileReadNoSuchFileError {
                    exists = false
                }
                // ABSENT IS NOT A FAILURE, AND IT IS NOT AN EARLY RETURN EITHER. An absent target
                // used to reach `removeItem` and die there on file-not-found, which stopped the
                // job at the delete step and SKIPPED THE RECOMPOSE — the half that actually
                // matters. "The source is gone and the index may still answer from it" is the
                // ORPHAN STATE this rail exists to clear, so failing there stranded the operator
                // in exactly the condition they pressed the button to escape. The removal is a
                // means; the `--clean` recompose below is the remedy. So an absent target is the
                // removal having already happened, and the recompose runs.
                //
                // `skipped` HERE MEANS "NOTHING TO REMOVE", not "an earlier step stopped the run" —
                // the other sense it carries on this rail. Both render as "not run", which is
                // true of this step either way, and neither counts as a failure.
                if exists { try FileManager.default.removeItem(at: target) }
                steps.append(Step(id: "delete", title: "Remove from the library vault",
                                  run: nil, appFailure: nil, skipped: !exists))
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
            steps.append(Step(id: "compose", title: "Recompose the scope", run: composed.run,
                              appFailure: nil, skipped: false))
            // This recompose is `--clean`: the index root is wiped and rebuilt, so the embed after
            // it is doing real work rather than a no-op, and a failure here leaves the whole scope
            // — not just the removed source's neighbours — reachable by exact word match only.
            steps.append(Self.embedStep(scope: vault?.scope ?? "library", composed: composed))
            finish(title: title, steps: steps)
        }
    }

    // MARK: - Writing a note by hand

    /// Write one hand-authored note into this workspace's vault and compose so it can be found.
    ///
    /// THE THIRD WRITER, and the one with an author. Capture writes calls, the library rail writes
    /// ingested documents, and both stamp every field themselves. This one supplies the spine so the
    /// operator does not have to know it — measured 2026-08-17, a note written by hand into a blank
    /// vault is refused twice before it composes, and the app named neither field it wanted.
    ///
    /// NOT `--clean`. A note is additive: nothing was removed, so no ingest directory is stale, and
    /// `--clean` would wipe and rebuild the whole index root to add one file.
    ///
    /// - Returns: a refusal to show the operator, or `nil` when the note was written. Compose
    ///   failures are NOT returned — the note is on disk by then, and the rail reports the compose
    ///   the same way it reports every other one.
    func createNote(title: String, docType: String, body: String,
                    destination: NoteDestination = .workspace,
                    confidence: String? = nil, domains: [String] = []) -> String? {
        guard !isWorking else {
            return "Another library job is running. Wait for it to finish, then add the note."
        }
        guard let cli = SubstrateEngine.shared.serving?.cli else {
            return "The engine is not running yet, so the note could not be composed. Wait for it "
                 + "to start and try again."
        }
        if destination == .shared {
            return createSharedNote(cli: cli, title: title, docType: docType,
                                    confidence: confidence, domains: domains, body: body)
        }
        // THE VAULT IS CREATED IF IT IS NOT THERE, which is the whole first-run case. A workspace
        // that has never recorded a call has no vault on disk, and that is exactly the operator this
        // path exists for — refusing them here would rebuild the dead end it was written to remove.
        // `createWorkspace`'s hazard applies unchanged: `write()` makes the transcripts directory
        // first and the manifest second, so a failure between them burns the name for every later
        // attempt. Cleaned up only when this call is what created the directory.
        let root = AppSettings.outputFolder
        let directory = root.appendingPathComponent(ScriptaVault.slug(workspace), isDirectory: true)
        let preexisting = FileManager.default.fileExists(atPath: directory.path)
        let vault: ScriptaVault
        do {
            let inherits = WorkspaceBindings.binding(for: workspace).contextVaults
            vault = try ScriptaVault.vault(forScope: workspace, under: root, inherits: inherits)
            try vault.write()
        } catch {
            if !preexisting { try? FileManager.default.removeItem(at: directory) }
            return error.localizedDescription
        }

        let url: URL
        do {
            url = try NoteWriter.write(intoVaultAt: vault.root, title: title,
                                       docType: docType, body: body)
        } catch {
            // The vault may have just been created for a note that then failed to write. Left in
            // place deliberately: it is a valid empty workspace vault, and removing it would also
            // remove one that existed before this call.
            return error.localizedDescription
        }

        task = Task { [weak self] in
            guard let self else { return }
            let jobTitle = "Adding \(url.lastPathComponent)"
            let written = Step(id: "write", title: "Write the note into the vault", run: nil,
                               appFailure: nil, skipped: false)
            job = .running(Running(title: jobTitle, step: "Composing", started: Date(),
                                   done: [written]))
            let composed = await Self.composeVault(cli: cli, vault: vault.root,
                                                   name: vault.scope, clean: false)
            var steps = [written, Step(id: "compose", title: "Compose the scope", run: composed.run,
                                       appFailure: nil, skipped: false)]
            steps.append(Self.embedStep(scope: vault.scope, composed: composed))
            finish(title: jobTitle, steps: steps)
        }
        return nil
    }

    /// Write into the vault every scope inherits, then bring all of them back into agreement.
    ///
    /// THE COMPOSE SET IS THE POINT. A workspace note touches one scope; a shared note is inherited
    /// by every scope that names this vault, and each keeps its OWN index. Composing only the active
    /// workspace would leave a note the operator wrote "for everything" answering in exactly one
    /// place — visible from one context, missing from five, with every gate reporting PASS. That is
    /// the silently-narrowed state the engine refuses everywhere else, arrived at by omission.
    ///
    /// The set is taken from the ENGINE's roster rather than from a list here: `sources` is each
    /// scope's resolved inheritance, so a scope that stops inheriting the shared vault drops out of
    /// this automatically, and one that starts inheriting it is picked up without being registered
    /// anywhere in the app.
    private func createSharedNote(cli: SubstrateEngine.Command, title: String, docType: String,
                                  confidence: String?, domains: [String], body: String) -> String? {
        guard let root = AppSettings.sharedVault else {
            return NoteWriter.Failure.noSharedVault.localizedDescription
        }
        let url: URL
        do {
            url = try NoteWriter.write(intoVaultAt: root, destination: .shared, title: title,
                                       docType: docType, confidence: confidence,
                                       domains: domains, body: body)
        } catch {
            return error.localizedDescription
        }

        // The vault's own directory name, which is how a manifest names an inherited vault and so
        // how `sources` reports it.
        let vaultName = root.standardizedFileURL.lastPathComponent
        let affected = SubstrateScopes.shared.rows.filter { row in
            row.indexPresent && (row.sources?.contains(vaultName) ?? false)
        }

        task = Task { [weak self] in
            guard let self else { return }
            let jobTitle = "Adding \(url.lastPathComponent) to \(vaultName)"
            var steps = [Step(id: "write", title: "Write the note into \(vaultName)", run: nil,
                              appFailure: nil, skipped: false)]
            // NAMED, NOT COUNTED, when there are none. An empty roster here means the note is on
            // disk and no index has it — which reads as success unless the report says otherwise.
            guard !affected.isEmpty else {
                return finish(title: jobTitle, steps: steps + [
                    Step(id: "compose", title: "Compose the scopes that inherit it", run: nil,
                         appFailure: "No composed scope inherits \(vaultName), so the note is "
                                   + "written but nothing serves it yet. Compose a scope that "
                                   + "inherits this vault.", skipped: false)])
            }
            for row in affected {
                guard !Task.isCancelled else {
                    return finish(title: jobTitle, steps: steps + [
                        Step(id: "stopped", title: "Compose the remaining scopes", run: nil,
                             appFailure: nil, skipped: true)])
                }
                job = .running(Running(title: jobTitle, step: "Composing \(row.scope)",
                                       started: Date(), done: steps))
                let composed = await Self.composeVault(
                    cli: cli, vault: URL(fileURLWithPath: row.vault, isDirectory: true),
                    name: row.scope, clean: false)
                steps.append(Step(id: "compose-\(row.scope)", title: "Compose \(row.scope)",
                                  run: composed.run, appFailure: nil, skipped: false))
                steps.append(Self.embedStep(scope: row.scope, composed: composed))
            }
            finish(title: jobTitle, steps: steps)
        }
        return nil
    }

    /// Vector the chunks the compose just added.
    ///
    /// WITHOUT THIS A NEW NOTE IS LEXICAL-ONLY. Chunks are content-addressed, so a new note is new
    /// chunks and new chunks have no vectors — the note answers a query that happens to use its
    /// words and is invisible to one that uses different ones. Nothing in this app ran `embed`
    /// before 2026-08-17: only `tools/substrate-refresh` did, which is not running while the app is
    /// (Doc 5 §6, the agent is retired). So every note written here stayed half-indexed until an
    /// operator ran a command they had no reason to know about.
    ///
    /// SKIPPED WHEN THE COMPOSE FAILED, rather than run anyway. A failed compose left the previous
    /// index in place; embedding against it would report vectors for content the operator believes
    /// was just added.
    /// - Parameter composed: `nil` for a run that stopped before composing at all, which draws the
    ///   same skipped row a failed compose does. Taken here rather than spelled out again at each
    ///   early return: the title and the id are this function's to know, and a second builder for
    ///   one row is how the rail comes to call the same step two different things.
    private static func embedStep(scope: String, composed: ComposeOutcome?) -> Step {
        let title = "Vector the new passages"
        guard let composed, composed.run.succeeded else {
            return Step(id: "embed-\(scope)", title: title, run: nil, appFailure: nil, skipped: true)
        }
        // REPORTS WHAT `composeVault` ALREADY DID rather than running its own. The database was
        // looked up here once through `registeredDatabase`, which reads the cached scope roster —
        // and a compose that has just REGISTERED a scope is absent from that cache until `finish`
        // re-lists it, which happens after this. So the first note into a new workspace, the case
        // the whole path exists for, reported "the engine did not register a database" about a
        // scope registered a second earlier.
        //
        // UNREACHABLE, WRITTEN DOWN RATHER THAN FORCE-UNWRAPPED. `composeVault` embeds exactly when
        // the compose succeeded, which the guard above has already established. If that ever stops
        // holding, an unvectored scope reporting green is the outcome this whole path exists to
        // prevent, so it reads as a failure rather than as a skip.
        guard let run = composed.embed else {
            return Step(id: "embed-\(scope)", title: title, run: nil,
                        appFailure: "\(scope) composed but no embed was attempted, so its new "
                                  + "passages may only be findable by exact word match.",
                        skipped: false)
        }
        return Step(id: "embed-\(scope)", title: title, run: run, appFailure: nil, skipped: false)
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
        guard !ScriptaVault.slug(name).isEmpty else {
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
        let slugged = ScriptaVault.slug(scope)
        guard !isWorking, !slugged.isEmpty,
              let cli = SubstrateEngine.shared.serving?.cli,
              let vault = ScriptaVault.existingVault(forScope: scope,
                                                     under: AppSettings.outputFolder).vault
        else { return }
        Task { [weak self] in
            let composed = await Self.composeVault(cli: cli, vault: vault, name: slugged,
                                                   clean: true)
            // QUIET IS NOT SILENT, and this path had taken it to mean silent. It deliberately writes
            // no `job` — a recording finishing must not replace a report the operator is reading —
            // but it also discarded the whole outcome, so every call recorded during an embedder
            // outage became findable by exact word match only, with nothing anywhere saying so. The
            // log is the surface a path with no surface has.
            //
            // ALL THREE OUTCOMES, WORST FIRST. Logging only the embed covered the LEAST damaging
            // one: a failed compose leaves the call out of the index entirely, and a DECLINED
            // compose never attempted it — and declined is not the rare case here, because
            // `composeInFlight` is exactly what a refresh tick or an operator's add holds while a
            // recording is ending. A refresh pass reaches the scope within the quarter hour either
            // way, so this is a record of what happened rather than the remedy.
            // THE STDERR IS `.private`, AND ONLY THE STDERR. `compose` prints one line per failing
            // note as `<absolute path>: <reason>`, and the note that most often fails right after a
            // recording is THAT RECORDING — so a `.public` stderr writes the call's full path, and
            // therefore its title and date, into a system log that survives in sysdiagnose bundles.
            // The scope name stays public so the line is still greppable for triage.
            if composed.declined {
                // DECLINED IS NOT AN ERROR, and logging it as one said something false. Another
                // compose held the lock; this one never ran, so nothing is known to be wrong and
                // the index still holds whatever it held. `SubstrateRefresh` treats the identical
                // condition as `.info` "skipped", and the refresh pass reaches this scope anyway.
                Self.log.info("""
                    compose declined after recording into \(slugged, privacy: .public) — another \
                    compose was in flight; the refresh pass will reach this scope
                    """)
            } else if !composed.run.succeeded {
                // THE WHOLE SCOPE, not just this call. This compose is `--clean`: it wipes the
                // index root and rebuilds it, so a failure part-way leaves everything that scope
                // answers from in doubt, not only the recording that triggered it.
                Self.log.error("""
                    compose failed after recording into \(slugged, privacy: .public) — this is a \
                    --clean rebuild, so the whole scope may be unindexed, not just the new call; \
                    \(composed.run.stderr, privacy: .private)
                    """)
            } else if composed.embedFailed {
                Self.log.error("""
                    embed failed after recording into \(slugged, privacy: .public) — the call is \
                    composed but its passages are not vectored
                    """)
            }
            // The corpus just gained a call. The browse list is told rather than left to notice.
            VaultBrowseModel.shared.corpusChanged()
            // The roster now reports a scope whose index moved, and the tier chips are drawn from
            // it — re-listed so a call recorded seconds ago is askable without a relaunch.
            await SubstrateScopes.shared.listScopes()
        }
    }

    private func runCompose(cli: SubstrateEngine.Command, vault: URL, workspace: String) async {
        let title = "Composing \(workspace)"
        let name = ScriptaVault.slug(workspace)
        // `--clean`, because a call deleted in the app must stop answering. The vault holds only
        // what capture put there, so a stale ingest directory is the one way a deleted call comes
        // back — and `assert_composed` would refuse the next compose over it anyway, after the
        // operator had already deleted it for a reason.
        let composed = await Self.composeVault(cli: cli, vault: vault, name: name, clean: true)
        finish(title: title,
               steps: [Step(id: "compose", title: "Compose and register the scope",
                            run: composed.run, appFailure: nil, skipped: false),
                       Self.embedStep(scope: name, composed: composed)])
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
    /// True while any caller is inside `composeVault`.
    ///
    /// THE LOCK THE AGENT USED TO HOLD. `task`'s comment above names the hazard — two composes over
    /// one `--clean` index root leave the loser asserting over content it did not ingest — and says
    /// it is "the hazard the refresh agent takes a lock for". That agent is no longer run (Doc 5
    /// §6: it cannot work from a bundle), so the lock has to exist here or not at all. `isWorking`
    /// could not serve: it is the VISIBLE rail, and both the recording path and the refresh loop are
    /// deliberately quiet, so neither sets it.
    private(set) static var composeInFlight = false

    /// What one compose did, and what the embed after it did.
    ///
    /// BOTH HALVES ARE THE OUTCOME. Whether a scope composed and whether its passages are
    /// semantically findable are separate facts, and a caller that reports only `run` reports a
    /// green step over a scope answering lexically — which is the precise failure that moving the
    /// embed into `composeVault` was meant to end. It ended it for two of the seven callers; of the
    /// other five, four took `.run` and dropped this on the floor and one discarded the outcome
    /// wholesale.
    ///
    /// The resolved database used to be carried here as well, for a stale-roster lookup in
    /// `embedStep` that stopped existing once the embed's own result was returned. It was written
    /// and never read by anything, so it is gone rather than kept for a reader that never came.
    struct ComposeOutcome {
        let run: SubstrateRun
        /// The embed that followed a successful compose. Nil EXACTLY when `run` did not succeed —
        /// the compose failed, or was declined — because there was nothing new to vector and
        /// embedding against a surviving old index would report vectors for content the operator
        /// believes was just added.
        let embed: SubstrateRun?

        /// The compose worked and the embed did not: current content, no vectors. The one state
        /// that reported as success everywhere it was not explicitly checked for.
        var embedFailed: Bool { run.succeeded && embed?.succeeded != true }

        /// `composeVault` stood down because another compose held the lock — it did not run and did
        /// not fail. DECODED HERE, ONCE. This is a private contract between `composeVault` and its
        /// callers with no compiler link between the places that spell it, so hand-copying
        /// `cancelled && status == nil` is how a decline silently becomes a failure in a log or a
        /// recorded outcome.
        var declined: Bool { run.cancelled && run.status == nil }
    }

    static func composeVault(cli: SubstrateEngine.Command, vault: URL, name: String,
                             clean: Bool) async -> ComposeOutcome {
        // DECLINED, NOT QUEUED, and the caller is told which it was. Queuing would let a refresh
        // tick stack behind a recording's compose and run against a vault that has moved under it;
        // declining lets each caller decide, and both already know how — a recording's compose is
        // skipped because the refresh pass will reach that scope anyway, and a refresh pass records
        // nothing for a scope it did not attempt rather than overwriting a live verdict.
        guard !composeInFlight else {
            return ComposeOutcome(
                run: SubstrateRun(line: "compose \(name)", status: nil, stdout: "",
                                  stderr: "another compose is already running", launchFailure: nil,
                                  cancelled: true),
                embed: nil)
        }
        composeInFlight = true
        defer { composeInFlight = false }
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
        let run = await SubstrateCLI.run(cli, arguments)

        // THE EMBED LIVES HERE, at the one chokepoint every compose in this app goes through, and
        // not on the callers. It was bolted onto the two note paths first, which made whether a
        // passage is semantically findable depend on WHICH BUTTON added it — a PDF, an uploaded
        // transcript, a recorded call and every refresh tick all composed and never vectored.
        // Measured 2026-08-18: `cbre` was serving 1341/1381, forty chunks reachable only by exact
        // word match, with every step reporting success.
        //
        // NON-FATAL, and deliberately so. A down embedder makes content harder to find, not absent
        // — the lexical arm still answers — so this reports and never fails the compose. That
        // matters today: the operator's embedding model lives on an external drive that is
        // currently throwing I/O errors, and a compose that failed because of it would be a working
        // index reported as broken.
        let embed: SubstrateRun?
        if run.succeeded {
            embed = await SubstrateCLI.run(cli, ["embed", "--db", database.path])
        } else {
            embed = nil
        }
        return ComposeOutcome(run: run, embed: embed)
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
        // ANY COMPOSE STEP, not one literally named "compose". `createSharedNote` composes several
        // scopes and ids them `compose-<scope>`, so an exact-match lookup found none of them — a
        // shared note that landed cleanly in six scopes set no `scope`, drew no "it is answering in
        // Ask now" confirmation, and never called `corpusChanged()`. `VaultBrowseView` declines to
        // reload its listing precisely BECAUSE this callback exists, so the browser the note was
        // written from stayed stale. A contract carried in a string id is one a new caller breaks
        // without noticing; matching the prefix is the smallest thing that makes it hold.
        let composes = steps.filter { $0.id == "compose" || $0.id.hasPrefix("compose-") }
        let composed = composes.first { $0.run?.succeeded == true }?.run
        let scope = Self.registeredScope(in: composed)
        job = .finished(Report(title: title, steps: steps, scope: scope, orphaned: orphaned))
        // ONLY WHEN A COMPOSE ACTUALLY LANDED. `scope` is non-nil exactly when compose succeeded and
        // named one, so a refused or failed job does not invalidate a list that is still correct.
        if scope != nil { VaultBrowseModel.shared.corpusChanged() }
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
