import SubstrateKit
import SwiftUI

// MARK: - Ask, over a substrate scope
//
// The first real consumer of `SubstrateKit` and of the four answer surfaces. It renders what the
// engine said and nothing else: `EngineBar` for the capability envelope, `ExclusionBar` for what
// was withheld and the control that includes it, `PassageCard` (and through it `PassageSpine`) for
// each result.
//
// FIVE OUTCOMES ARE REACHABLE FROM THIS SCREEN AND EVERY ONE OF THEM IS LEGIBLE, because "the
// engine is not running" is a normal state here rather than an error: Scripta hosts the engine, so
// nothing-on-the-port is what a machine looks like before it is started. The five are the engine
// down, a scope the engine does not have, an index written by another schema, a tool fault, and a
// healthy answer that matched nothing — and the last of those is emphatically not one of the first
// four, which is why it keeps its envelope and its filter block.
//
// The one thing that is never silent is the scope. Under rule 3 a healthy engine is quiet, so the
// scope row and the bar's own scope segment are the entire discoverability budget: they are what
// tell a reader that this answer came from a NAMED corpus which could have been a different one.

struct SubstrateAskView: View {
    @ObservedObject var model: SubstrateAskModel
    @ObservedObject private var engine = SubstrateEngine.shared

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            column
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.background)
        .task { engine.startIfIdle() }
    }

    /// THE SUPERVISOR IS THE OUTER GATE AND THE ROSTER IS THE INNER ONE, in that order, because
    /// Scripta now owns the engine's process (Doc 3 §2) and the states that ownership adds are not
    /// the states a query has. Listing scopes at an engine that was spawned four seconds ago comes
    /// back as `cannotConnectToHost` and renders as "engine down" — a healthy state drawn as a
    /// fault, the same shape as the cancelled-`URLSession` bug `listScopes` had to guard. So the
    /// roster is not asked at all until the engine answers.
    @ViewBuilder private var column: some View {
        switch engine.lifecycle {
        case .idle, .starting:
            VaultEngineStarting(lifecycle: engine.lifecycle)
        case .notInstalled, .portBusy, .failed:
            VaultEngineRefusal(lifecycle: engine.lifecycle, restart: engine.restart)
        case .serving:
            VaultRoster(model: model)
        }
    }
}

/// The roster, fetched exactly once the engine answers. `.task` lives here rather than on the pane
/// so it fires on the starting → serving transition instead of on first appearance, which is what
/// makes "the engine was still coming up" and "the engine has no scopes" different events.
private struct VaultRoster: View {
    @ObservedObject var model: SubstrateAskModel
    @ObservedObject private var scopes = SubstrateScopes.shared

    var body: some View {
        content.task { await model.activate() }
    }

    @ViewBuilder private var content: some View {
        switch scopes.roster {
        case .unasked, .listing:
            VaultProbe()
        case .refused(let refusal):
            VaultRosterRefusal(refusal: refusal) { Task { await model.listScopes() } }
        case .listed(let rows):
            VaultConsole(model: model, rows: rows)
        }
    }
}

// MARK: - The engine's own states
//
// FOUR STATES OWNERSHIP ADDED, and none of them is `VaultRefusal.engineDown`. That case answers
// "the query found nothing listening"; these answer "what is the process this app is responsible
// for doing right now", and the two were only ever the same thing while nobody owned the process.

/// Spawned, not yet answering. NOT A FAULT and not a bare spinner: the cross-encoder builds its
/// retrieval stack before `serve_http` binds, so seconds of closed port are the design. The counter
/// moves for the same reason `VaultProbe`'s does — a stalled start has to look stalled.
struct VaultEngineStarting: View {
    let lifecycle: SubstrateEngine.Lifecycle

    var body: some View {
        HStack(spacing: Gap.s8) {
            Spinner()
            Text(sentence).proseText(Register.proseSm, Ink.textSecondary)
            if case .starting(_, let since) = lifecycle { VaultElapsed(started: since) }
            Spacer(minLength: Gap.s8)
        }
        .padding(Metrics.pageGutter)
    }

    private var sentence: String {
        guard case .starting(let source, _) = lifecycle else {
            return "Waiting for Scripta to start the substrate engine…"
        }
        return "Starting the substrate engine (\(source.label)). It loads its retrieval stack "
            + "before it binds the port, so this takes a few seconds."
    }
}

struct VaultEngineRefusal: View {
    let lifecycle: SubstrateEngine.Lifecycle
    let restart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s12) {
            VaultEngineCard(lifecycle: lifecycle, restart: restart)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: Metrics.listMaxWidth, alignment: .leading)
        .padding(Metrics.pageGutter)
    }
}

/// Drawn in the envelope family for the same reason `VaultRefusalCard` is: same `EngineNote` line
/// type, same marker column, same tones, so a supervisor state and a refused query stack as one
/// system rather than as an alert bolted beside a console.
private struct VaultEngineCard: View {
    let lifecycle: SubstrateEngine.Lifecycle
    let restart: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s8) {
            ForEach(lifecycle.notes) { EngineNoteRow(note: $0) }
            if let verbatim = lifecycle.verbatim { VaultVerbatim(text: verbatim) }
            VaultRetry(title: lifecycle.retryTitle, action: restart)
        }
        .padding(Metrics.cardPaddingCompact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Ink.layer)
    }
}

extension SubstrateEngine.Lifecycle {

    var notes: [EngineNote] {
        switch self {
        case .notInstalled:
            return [EngineNote(
                // NOT RED, and for the same reason `engineDown` is not: this is the ORDINARY state
                // of every machine that has not installed an engine yet, which today is every
                // machine but the operator's. "It crashed" and "there is none" need different
                // sentences or the first run reads as a failure.
                id: "absent", marker: "no engine", tone: Ink.textHelper,
                text: "Scripta runs the substrate engine itself, and there is none on this Mac to "
                    + "run. Your calls are on the local index and are unaffected — this is only "
                    + "the vault brain. The paths it looked at are below.")]
        case .portBusy(let port, let occupant):
            return [EngineNote(
                id: "port", marker: "port \(port)", tone: Ink.warning,
                text: occupant.sentence(port: port))]
        case .failed(let source, let reason, _):
            return [EngineNote(
                id: "failed", marker: "failed", tone: Ink.danger,
                text: "\(reason) It was \(source.label). Its own last words are below.")]
        case .idle, .starting, .serving:
            return []
        }
    }

    /// The machine's own words, never this file's paraphrase of them — the searched paths, or the
    /// stderr the process wrote on its way out. A supervisor that reports "could not start" and
    /// keeps the reason to itself sends the operator to a log it already had.
    var verbatim: String? {
        switch self {
        case .notInstalled(let searched):
            return searched.isEmpty ? nil : searched.joined(separator: "\n")
        case .failed(_, _, let stderr):
            return stderr.isEmpty ? nil : stderr
        case .idle, .starting, .serving, .portBusy:
            return nil
        }
    }

    var retryTitle: String {
        if case .notInstalled = self { return "Look again" }
        return "Start the engine"
    }
}

extension SubstrateEngine.Occupant {

    /// Both arms name the port AND the remedy. A stale orphan from a crash and an engine the
    /// operator started by hand are the two things this can be, and Scripta will not adopt either:
    /// an engine it did not spawn is one it cannot promise to stop.
    func sentence(port: Int) -> String {
        let socket = SubstrateEngine.endpoint
        switch self {
        case .anEngine(let scopes):
            let roster = scopes.map { " It answered with \($0) scope\($0 == 1 ? "" : "s")." } ?? ""
            return "A substrate engine is already answering on \(socket), and Scripta did not "
                + "start it.\(roster) It is either one you ran by hand or an orphan a previous "
                + "crash left behind — `lsof -nP -iTCP:\(port) -sTCP:LISTEN` names it. Scripta "
                + "will not adopt a process it cannot promise to stop; quit it and press below."
        case .aStranger(let detail):
            return "Something is listening on \(socket) and it is not a substrate engine, so "
                + "Scripta cannot bind the port its own engine needs: \(detail). "
                + "`lsof -nP -iTCP:\(port) -sTCP:LISTEN` names it. Free the port and press below."
        }
    }
}

// MARK: - Before the first answer

/// Asking the engine which corpora it has. Named, and counting: this is the one moment where a hang
/// and a healthy wait look identical, so the sentence says what is being waited on and the counter
/// beside it keeps moving. A bare spinner is the failure mode, not the loading state.
/// Shared with `VaultBrowseView`: waiting on the engine must look identical wherever
/// it is waited on.
struct VaultProbe: View {
    @State private var started = Date()

    var body: some View {
        HStack(spacing: Gap.s8) {
            Spinner()
            Text("Asking the engine which scopes it has…")
                .proseText(Register.proseSm, Ink.textSecondary)
            VaultElapsed(started: started)
            Spacer(minLength: Gap.s8)
        }
        .padding(Metrics.pageGutter)
    }
}

private struct VaultRosterRefusal: View {
    let refusal: VaultRefusal
    let retry: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s12) {
            VaultRefusalCard(refusal: refusal, retryTitle: "Try again", retry: retry)
            Spacer(minLength: 0)
        }
        .frame(maxWidth: Metrics.listMaxWidth, alignment: .leading)
        .padding(Metrics.pageGutter)
    }
}

// MARK: - The console

private struct VaultConsole: View {
    @ObservedObject var model: SubstrateAskModel
    let rows: [WireScopeRow]

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s12) {
            VaultScopeRow(model: model, rows: rows)
            VaultComposer(model: model)
            if let running = model.running {
                VaultRunStrip(running: running, stop: model.stop)
            }
            VaultAnswerScroll(model: model)
        }
        .frame(maxWidth: Metrics.listMaxWidth, alignment: .leading)
        .frame(maxWidth: .infinity)
        .padding(Metrics.pageGutter)
    }
}

/// Which brain, permanently on screen. Doc 3 §6 makes this the one exception to "surface effects,
/// never mechanism", so it is a row of real chips rather than a menu: a reader has to be able to
/// see that the answer could have come from six other corpora without opening anything.
private struct VaultScopeRow: View {
    @ObservedObject var model: SubstrateAskModel
    let rows: [WireScopeRow]

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s6) {
            VaultScopeChips(model: model, rows: rows)
            if let row = selected, let note = VaultScopeHealth.note(for: row) {
                VaultScopeNote(note: note)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var selected: WireScopeRow? { rows.first { $0.scope == model.scope } }
}

private struct VaultScopeChips: View {
    @ObservedObject var model: SubstrateAskModel
    let rows: [WireScopeRow]

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: Gap.s6) {
                EnvelopeMarkerLabel(name: "scope")
                ForEach(rows, id: \.scope) { row in
                    Pill(text: row.scope,
                         style: VaultScopeHealth.style(row, selected: row.scope == model.scope),
                         action: { model.bind(scope: row.scope) })
                }
            }
        }
    }
}

/// A scope's own condition, before any query touches it. `scopes_payload` lists a scope whose
/// inheritance no longer resolves WITH its fault rather than omitting it — an omitted scope reads
/// as one that was never composed — so a chip for a scope that cannot answer is drawn and marked
/// rather than hidden.
enum VaultScopeHealth {
    static func style(_ row: WireScopeRow, selected: Bool) -> PillStyle {
        if selected { return .selected }
        if row.error != nil { return .danger }
        if !row.indexPresent || row.refresh.frozen == .frozen { return .stale }
        return .neutral
    }

    /// The selected scope's fault, said out loud before a query is spent on it.
    static func note(for row: WireScopeRow) -> EngineNote? {
        if let error = row.error {
            return EngineNote(id: "scope-error", marker: "scope", tone: Ink.danger,
                              text: "This scope's inheritance no longer resolves: \(error)")
        }
        if !row.indexPresent {
            return EngineNote(id: "scope-index", marker: "no index", tone: Ink.danger,
                              text: "This scope is registered but has no index on disk. Compose it "
                                  + "before asking it anything.")
        }
        if row.refresh.frozen == .frozen {
            return EngineNote(id: "scope-frozen", marker: "frozen", tone: Ink.warning,
                              text: "The vault changed and the last recompose refused, so answers "
                                  + "from this scope come from superseded content.")
        }
        return nil
    }
}

struct VaultScopeNote: View {
    let note: EngineNote

    var body: some View {
        EngineNoteRow(note: note)
            .padding(Metrics.cardPaddingCompact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(Ink.layer)
    }
}

private struct VaultComposer: View {
    @ObservedObject var model: SubstrateAskModel

    var body: some View {
        HStack(spacing: Gap.s8) {
            InputField(prompt: prompt, text: $model.query, glyph: .search,
                       onSubmit: model.search)
            ActionButton(title: "Search", glyph: .send, rank: .primary, action: model.search)
                .disabled(model.query.trimmingCharacters(in: .whitespaces).isEmpty)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// Names the corpus in the prompt as well as on the chip. The prompt is decorative by the
    /// system's own rule, which is why the chip above carries the same fact.
    private var prompt: String {
        "Ask the \(model.scope ?? "vault") notes…"
    }
}

/// The answer to "a spinner that never resolves". The elapsed count moves, so a stalled request
/// looks stalled, and Stop is beside it so the reader is never left with only the spinner.
private struct VaultRunStrip: View {
    let running: SubstrateAskModel.Running
    let stop: () -> Void

    var body: some View {
        HStack(spacing: Gap.s8) {
            Spinner()
            Text("searching \(running.scope)").typeface(Register.ui, Ink.textPrimary)
            // The question, in mono, because it is the argument that was sent — and because a
            // re-run from a filter chip re-asks the ANSWERED question, not whatever is in the field.
            Text(running.query).typeface(Register.monoMicro, Ink.textHelper).lineLimit(1)
            VaultElapsed(started: running.started)
            Spacer(minLength: Gap.s8)
            ActionButton(title: "Stop", rank: .tertiary, action: stop)
        }
        .padding(Metrics.cardPaddingCompact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Ink.layer)
    }
}

struct VaultElapsed: View {
    let started: Date

    var body: some View {
        TimelineView(.periodic(from: started, by: 1)) { context in
            Text(elapsed(at: context.date)).typeface(Register.monoMicro, Ink.textSecondary)
        }
    }

    private func elapsed(at now: Date) -> String {
        String(format: "%.0fs", max(0, now.timeIntervalSince(started)))
    }
}

// MARK: - The answer

private struct VaultAnswerScroll: View {
    @ObservedObject var model: SubstrateAskModel

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: Gap.s12) {
                body_content
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.bottom, Gap.s24)
        }
    }

    @ViewBuilder private var body_content: some View {
        switch model.answer {
        case .idle:
            // Suppressed under a run strip: "ask the notes" beneath a live spinner reads as though
            // nothing was asked.
            if model.running == nil { VaultIdle(scope: model.scope) }
        case .refused(let refusal):
            VaultRefusalCard(refusal: refusal, scope: model.scope,
                             retryTitle: "Ask again", retry: model.rerun)
        case .answered(let result):
            VaultResultView(model: model, result: result)
        }
    }
}

private struct VaultIdle: View {
    let scope: String?

    var body: some View {
        EmptyState(glyph: .search,
                   title: "Ask the \(scope ?? "vault") notes",
                   message: "This is the vault brain, not the call index. It answers from your "
                       + "composed notes; your calls stay where they were and are still asked the "
                       + "same way.")
    }
}

/// Envelope, then disclosure, then passages — the order the reader needs them in. Which tier
/// answered and what was withheld both change how the passages should be read, so both come first.
private struct VaultResultView: View {
    @ObservedObject var model: SubstrateAskModel
    let result: SubstrateAskModel.Result

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s12) {
            // `selectScope` re-lists the corpora rather than opening a picker, and the divergence
            // from the parameter's name is deliberate: the picker is already permanently on screen
            // two rows up, so "choose a different scope" has no destination to offer. What the
            // segment can still usefully do is re-ask which corpora exist — the roster is fetched
            // once and carries each scope's `index_present` and refresh verdict, both of which move.
            EngineBar(envelope: result.envelope) { Task { await model.listScopes() } }
            ExclusionBar(filter: result.filter, toggle: model.include)
            if let klass = model.refusedInclusion { VaultInclusionRefusal(klass: klass) }
            VaultPassages(result: result)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A chip the engine has no argument for, answered rather than ignored. `ExclusionBar` offers a
/// control for all five retrieval classes; `search` accepts two of them. A click that did nothing
/// is how a reader concludes they opened up a class they did not.
private struct VaultInclusionRefusal: View {
    let klass: RetrievalClass

    var body: some View {
        EngineNoteRow(note: note)
            .padding(Metrics.cardPaddingCompact)
            .frame(maxWidth: .infinity, alignment: .leading)
            .surface(Ink.layer)
    }

    private var note: EngineNote {
        EngineNote(id: "inclusion", marker: klass.label, tone: Ink.stale,
                   text: SubstrateAskModel.refusalSentence(for: klass), dotted: true)
    }
}

private struct VaultPassages: View {
    let result: SubstrateAskModel.Result

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s10) {
            VaultResultCount(result: result)
            if result.passages.isEmpty {
                VaultNoMatch(result: result)
            } else {
                ForEach(result.passages) { PassageCard(passage: $0) }
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// The count and the index version, in mono, because both are machine-generated fact — and because
/// `index_version` is the value Doc 3 §6 asks an in-app answer and a CLI answer to agree on, so it
/// has to be on screen to be comparable at all.
private struct VaultResultCount: View {
    let result: SubstrateAskModel.Result

    var body: some View {
        HStack(spacing: Gap.s8) {
            EnvelopeMarkerLabel(name: "passages")
            Text("\(result.passages.count)").typeface(Register.monoMicro, Ink.textSecondary)
            Text(result.indexVersion).typeface(Register.monoMicro, Ink.textHelper)
            Spacer(minLength: Gap.s4)
        }
    }
}

/// A HEALTHY ANSWER WITH NOTHING IN IT, and it must not look like any of the four failures. The
/// envelope and the exclusion bar are still above this — the engine ran, reported its stack and
/// reported what it withheld — so what is left to say is only that the corpus had no match, and
/// that the withheld classes above are where to look next.
private struct VaultNoMatch: View {
    let result: SubstrateAskModel.Result

    var body: some View {
        EmptyState(glyph: .info,
                   title: "No passage in \(result.scope) matched",
                   message: "The engine answered — the stack above is what ran, and the bar above "
                       + "names what it did not search. Nothing here is evidence the answer is not "
                       + "in a class that was withheld, or in another scope.")
    }
}

// MARK: - Refusals

/// A query that produced no answer, drawn in the envelope family rather than as an alert.
///
/// NOT AN `EngineBar`, and the omission is deliberate. The bar's three bands are claims about a
/// stack that RAN — arms, a measured tier, a refresh verdict — and a refused query has none of
/// them. Synthesising an envelope to reuse the component would put three fabricated fields on
/// screen in order to render one true sentence, which is the exact trade the envelope exists to
/// refuse. What it does share is the family: the same `EngineNote` line type, the same marker
/// column, the same tones — so a refusal stacks under a scope row looking like the same system.
/// Shared with `LiveRecallPanel`: a refusal must read identically wherever it lands, so this is
/// internal rather than private to this file.
struct VaultRefusalCard: View {
    let refusal: VaultRefusal
    var scope: String? = nil
    var retryTitle: String? = nil
    var retry: (() -> Void)? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s8) {
            if let scope { VaultRefusalScope(name: scope) }
            ForEach(refusal.notes) { EngineNoteRow(note: $0) }
            if let verbatim = refusal.verbatim { VaultVerbatim(text: verbatim) }
            if let retryTitle, let retry { VaultRetry(title: retryTitle, action: retry) }
        }
        .padding(Metrics.cardPaddingCompact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Ink.layer)
    }
}

/// The anchor, still. A refused query is still a claim about a NAMED corpus, and dropping the name
/// because the query failed is how a reader ends up unsure which scope was even asked.
///
/// Drawn as a plain pair rather than as `EngineScopeSegment`: the segment is a control, and here
/// there is nothing behind it — the scope chips are two rows up and already selectable.
private struct VaultRefusalScope: View {
    let name: String

    var body: some View {
        HStack(spacing: Gap.s6) {
            Text("scope").microLabel(Ink.textHelper)
            Text(name).typeface(Register.mono, Ink.textSecondary)
            Spacer(minLength: Gap.s4)
        }
    }
}

/// The engine's own sentence, unedited and selectable. Every recognised refusal is a PROMOTION of
/// this string into better words; keeping the original beneath them is what makes a classifier that
/// stops matching degrade into a rendered engine sentence rather than into silence.
struct VaultVerbatim: View {
    let text: String

    var body: some View {
        Text(text)
            .typeface(Register.monoMicro, Ink.textHelper)
            .textSelection(.enabled)
            .padding(.leading, EnvelopeMarker.indent)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct VaultRetry: View {
    let title: String
    let action: () -> Void

    var body: some View {
        HStack(spacing: Gap.s8) {
            Spacer().frame(width: EnvelopeMarker.column)
            ActionButton(title: title, glyph: .refresh, rank: .secondary, action: action)
            Spacer(minLength: Gap.s4)
        }
    }
}

// MARK: - How a refusal is drawn
//
// The vocabulary is in `VaultRefusal`; this is the other half, and the split is the one the whole
// design system makes — a condition the engine reported is schema, the tone it is drawn in is a
// choice. `EngineNote` is reused rather than re-declared so a refusal line and an envelope line
// share the marker column they stack against.

extension VaultRefusal {

    var notes: [EngineNote] {
        switch self {
        case .engineDown:
            return [EngineNote(
                id: "down", marker: "engine down", tone: Ink.textHelper,
                // STILL NOT RED, and the reason has moved rather than gone. It used to be "this is
                // what a machine looks like before you start it". Scripta now starts it, so the
                // remaining way to reach this from a query is an engine that went away between the
                // roster and the search — and the supervisor is already flipping the pane to its
                // own `failed` card, which carries the stderr. Colouring it would put a second,
                // louder and less informative report of one event on screen.
                text: "Nothing is listening on "
                    + "\(SubstrateClient.defaultEndpoint.absoluteString). Scripta runs the engine "
                    + "itself, so it stopped underneath this query; the pane is about to say why. "
                    + "Your calls are on the local index and are unaffected.")]
        case .transport(let failure):
            return [EngineNote(
                id: "transport", marker: "transport", tone: Ink.danger,
                text: "The engine answered, but not with a JSON-RPC response: \(failure).")]
        case .unknownScope(let registered, _):
            return [EngineNote(
                id: "scope", marker: "scope", tone: Ink.danger,
                text: registered.isEmpty
                    ? "The engine does not have this scope. It did not say which it does have."
                    : "The engine does not have this scope. It has: "
                        + registered.joined(separator: ", ") + ".")]
        case .schemaMismatch(let found, let expected, _):
            return [EngineNote(
                id: "schema", marker: "schema", tone: Ink.danger,
                text: "The index on disk is \(found); this engine reads \(expected). It refused "
                    + "rather than migrating, because migration is drop-and-rebuild. Recompose the "
                    + "scope before trusting anything from it.")]
        case .emptyIndex:
            return [EngineNote(
                id: "empty", marker: "empty", tone: Ink.danger,
                // The distinction this line exists to keep: an empty index answers zero passages,
                // which is byte-identical to a genuine no-match. The engine refuses rather than
                // answering, and this says which of the two happened.
                text: "This scope's index has no passages at all, so the engine refused to answer "
                    + "from it — an empty index returns nothing, which is indistinguishable from a "
                    + "genuine no-match. Recompose it.")]
        case .indexMissing:
            return [EngineNote(
                id: "missing", marker: "no index", tone: Ink.danger,
                text: "The registry points at an index file that is not there. The engine refuses "
                    + "to create one on a read, so nothing has been damaged — compose the scope.")]
        case .toolFault:
            return [EngineNote(
                id: "fault", marker: "fault", tone: Ink.danger,
                text: "The engine reported a condition it expects the caller to act on. Its own "
                    + "words are below.")]
        case .rpcError(let code, let message):
            return [EngineNote(
                id: "rpc", marker: "rpc", tone: Ink.danger,
                text: "The call never reached a tool — JSON-RPC \(code): \(message).")]
        case .vocabulary:
            return [EngineNote(
                id: "vocabulary", marker: "vocabulary", tone: Ink.danger,
                // The whole result set is withheld rather than the offending passage, and saying so
                // is the point: a reader who is shown seven of eight passages with no note has been
                // handed a silently incomplete answer.
                text: "The engine sent a value this build has no vocabulary for, so the whole "
                    + "result set was withheld rather than rendered with one passage silently "
                    + "missing. This build is older than the engine.")]
        }
    }

    /// The engine's sentence, where there is one. Absent for the states this side observed rather
    /// than was told about.
    var verbatim: String? {
        switch self {
        case .engineDown(let reason): return reason
        case .transport: return nil
        case .unknownScope(_, let sentence): return sentence
        case .schemaMismatch(_, _, let sentence): return sentence
        case .emptyIndex(let sentence): return sentence
        case .indexMissing(let sentence): return sentence
        case .toolFault(let sentence): return sentence
        case .rpcError: return nil
        case .vocabulary(let detail): return detail
        }
    }
}
