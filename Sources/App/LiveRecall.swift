import Foundation
import SubstrateKit

/// What the vault knows about what is being said right now (Doc 4 §8).
///
/// The fifth surface, and the only one that reads the corpus WITHOUT being asked. Capture writes a
/// call into the workspace vault; this is what makes the next call able to see it — "you agreed
/// something different about this in March", while the sentence that prompted it is still in the
/// room.
///
/// PASSAGES, NOT PROSE. The operator chose passages by default with generation only on request, and
/// the reason is what a wrong answer costs here: a retrieved passage that misses is visibly a
/// passage that misses, while a generated suggestion is a confident sentence arriving mid-call with
/// no time to check it. Nothing here calls a model. SPEC's invariant that FM features are bounded
/// generation only is kept by construction rather than by care.
///
/// IT ASKS FOR THE FAST ARM AND SAYS SO. Measured 2026-08-06 against the live engine: 17,274ms with
/// the generator arms, 286ms without. Seventeen seconds is not a suggestion, it is a memory. The
/// reply carries `hyde=off · rerank=off` and a null `expected_mrr`, and the surface must render that
/// null as absence — a live hit that wore the measured stack's number would be the exact
/// fabrication Doc 3 §5 exists to prevent, arriving faster.
@MainActor
final class LiveRecall: ObservableObject {

    /// One retrieval against the words spoken recently.
    struct Recall {
        /// The text that was asked — kept so a hit can be read against what prompted it.
        let prompt: String
        let passages: [Passage]
        /// What actually ran. Always reported: this is the surface most likely to be trusted
        /// casually, so the weaker ranking has to travel with the result.
        let envelope: EngineEnvelope
        let at: Date
    }

    @Published private(set) var recall: Recall?
    /// Why there is nothing, when there is nothing. NEVER SILENT: an empty recall panel during a
    /// call reads as "the vault knows nothing about this", which is a claim — and it must not be
    /// made by an unbound workspace or an engine that is down.
    ///
    /// A refusal is kept as a VALUE rather than flattened to a string, so the surface can draw it
    /// with the same `VaultRefusalCard` every other engine surface uses. A live panel inventing its
    /// own vocabulary for "the engine is down" is a second thing to keep true.
    enum Quiet {
        /// This app's own reason — nothing has been said yet, nothing matched, no binding.
        case sentence(String)
        /// The engine's, rendered by the shared card. The SCOPE travels with it: a refused query is
        /// still a claim about a named corpus, and this surface has no scope chip anywhere else, so
        /// dropping the name leaves a refusal that names nothing.
        case refused(scope: String?, VaultRefusal)
    }

    @Published private(set) var quiet: Quiet?

    /// How often the running transcript is re-asked. Slower than speech on purpose — a query per
    /// utterance would spend the engine on half-sentences and redraw the panel faster than anyone
    /// can read it. A recall is worth having a few seconds late; it is worthless if it flickers.
    private static let interval: TimeInterval = 20

    /// How much of the tail is asked. Long enough to carry a topic, short enough that a topic which
    /// has moved on stops matching — the panel should follow the conversation, not accumulate it.
    private static let tailCharacters = 600

    /// The shortest tail worth asking about. Below this the query is a fragment and the answer is
    /// noise dressed as recall.
    private static let minimumCharacters = 80

    private let client = SubstrateClient(timeout: 20)
    private var task: Task<Void, Never>?
    private var lastAsked = ""

    /// Bumped by `stop()`. Cancellation aborts a request in flight, but NOT one whose reply has
    /// already arrived and whose continuation is queued behind `stop()` on the main actor — that one
    /// resumes and writes `recall` after the panel was cleared. The next call then opens beside the
    /// previous call's passages.
    private var generation = 0

    // MARK: - Lifecycle

    /// Begin following a call. `transcript` is asked for the words so far each tick; it runs on the
    /// main actor because that is where the live transcriber publishes.
    func start(transcript: @escaping @MainActor () -> String) {
        stop()
        // OFF IS A STATE THAT SAYS SO. Returning silently left the panel a bare header for the whole
        // call, which is exactly the reading `Quiet` exists to prevent: an empty panel beside a live
        // conversation is taken as "the vault knows nothing about this".
        //
        // The loop is armed EITHER WAY and `tick` re-reads the switch, so this sentence is the state
        // on entry rather than a decision for the whole call. With live transcription off there is
        // nothing to recall from at all, and that one IS decided here: no words will ever arrive.
        guard AppSettings.liveTranscriptionEnabled else {
            quiet = .sentence("Live transcription is off, so there are no words to look anything up "
                              + "with. The call is still being recorded.")
            return
        }
        task = Task { [weak self] in
            while !Task.isCancelled {
                await self?.tick(transcript())
                try? await Task.sleep(nanoseconds: UInt64(Self.interval * 1_000_000_000))
            }
        }
    }

    func stop() {
        task?.cancel()
        task = nil
        generation &+= 1
        recall = nil
        quiet = nil
        lastAsked = ""
    }

    // MARK: - One pass

    private func tick(_ transcript: String) async {
        // RE-READ EVERY TICK. It was read once in `start()`, so switching the feature off mid-call
        // left the loop sending live speech to the engine for the rest of the call — a privacy
        // control that only took effect on the NEXT recording, in the one case where it is being
        // used deliberately.
        //
        // THE LOOP KEEPS RUNNING; only the QUERY stops. Calling `stop()` here killed the loop, so
        // turning the switch back on mid-call did nothing until the next recording — and `stop()`
        // clears `quiet`, so the sentence explaining the blank panel was wiped by the same call
        // that was supposed to produce it. Nothing is sent while this is off, which is the whole
        // requirement; a sleeping 20-second loop costs nothing.
        guard AppSettings.liveRecallEnabled else {
            recall = nil
            quiet = .sentence("Live recall is off, so the vault is not being consulted during this "
                              + "call. Turn it on under Settings › Intelligence.")
            lastAsked = ""
            return
        }
        let binding = WorkspaceBindings.active
        guard let scope = binding.readsScope else {
            // NAMED, NOT BLANK. An unbound workspace has no corpus to recall from, and a panel that
            // simply stayed empty would be indistinguishable from one that looked and found nothing.
            quiet = .sentence("This workspace reads no vault yet, so there is nothing to recall "
                              + "from. Bind it to a scope in Ask.")
            return
        }

        let tail = Self.tail(of: transcript)
        guard tail.count >= Self.minimumCharacters else {
            quiet = recall == nil
                ? .sentence("Listening — not enough has been said yet to look anything up.") : nil
            return
        }
        // The same words twice is the same answer twice. Skipped rather than re-asked, so a pause in
        // the conversation does not spend the engine redrawing what is already on screen.
        //
        // COMMITTED ON SUCCESS, not here. Committing before the call meant a tail whose query failed
        // counted as asked: one engine blip during a lull drew a refusal, the words stopped changing,
        // and every later tick returned at this guard — leaving a red card up for the rest of the
        // call with no retry on it, long after the engine recovered.
        guard tail != lastAsked else { return }
        let mine = generation

        let request = SubstrateSearchRequest(scope: scope, query: tail, k: 3,
                                             // The workspace's OWN past calls are the most valuable
                                             // thing here and are conversation-class, so they are
                                             // asked for explicitly — and they arrive labelled, so
                                             // a passage from mid-call still reads as raw material.
                                             includeSources: true,
                                             fast: true)
        let outcome = await client.search(request)
        // The reply may have arrived after `stop()` ran. Cancellation cannot catch that one.
        guard mine == generation, !Task.isCancelled else { return }

        switch outcome {
        case .ok(let payload):
            do {
                let passages = try payload.passages.map { try $0.mapped() }
                guard !passages.isEmpty else {
                    quiet = recall == nil
                        ? .sentence("Nothing in \(scope) matches what has been said so far.") : nil
                    lastAsked = tail
                    return
                }
                recall = Recall(prompt: tail, passages: passages,
                                envelope: try payload.mappedEnvelope(), at: Date())
                quiet = nil
                lastAsked = tail
            } catch {
                // COMMITTED, unlike the transport failures below. A vocabulary refusal is
                // deterministic — an unknown spine token fails identically every time — so leaving
                // this tail un-asked would re-send the same words to the same certain failure every
                // twenty seconds for the rest of the call. The engine blip the other branches retry
                // for is a different thing entirely.
                lastAsked = tail
                quiet = .refused(scope: scope, .vocabulary("\(error)"))
            }
        case .toolFault(let text):
            quiet = .refused(scope: scope, VaultRefusal.classify(fault: text))
        case .rpcError(let code, let message):
            quiet = .refused(scope: scope, .rpcError(code: code, message: message))
        case .transportFailure(let failure):
            // A cancelled call is this object being stopped, not a fault worth drawing.
            guard !failure.isCancellation else { return }
            quiet = .refused(scope: scope, .of(failure))
        }
    }

    /// The last `tailCharacters` of what has been said, cut at a word boundary so the query does not
    /// open mid-token.
    static func tail(of transcript: String) -> String {
        let flat = transcript.replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        guard flat.count > tailCharacters else { return flat }
        let cut = flat.index(flat.endIndex, offsetBy: -tailCharacters)
        let tail = flat[cut...]
        guard let space = tail.firstIndex(of: " ") else { return String(tail) }
        return String(tail[tail.index(after: space)...])
    }
}
