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
        /// The engine's, rendered by the shared card.
        case refused(VaultRefusal)
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

    // MARK: - Lifecycle

    /// Begin following a call. `transcript` is asked for the words so far each tick; it runs on the
    /// main actor because that is where the live transcriber publishes.
    func start(transcript: @escaping @MainActor () -> String) {
        stop()
        guard AppSettings.liveRecallEnabled else { return }
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
        recall = nil
        quiet = nil
        lastAsked = ""
    }

    // MARK: - One pass

    private func tick(_ transcript: String) async {
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
        guard tail != lastAsked else { return }
        lastAsked = tail

        let request = SubstrateSearchRequest(scope: scope, query: tail, k: 3,
                                             // The workspace's OWN past calls are the most valuable
                                             // thing here and are conversation-class, so they are
                                             // asked for explicitly — and they arrive labelled, so
                                             // a passage from mid-call still reads as raw material.
                                             includeSources: true,
                                             fast: true)
        switch await client.search(request) {
        case .ok(let payload):
            do {
                let passages = try payload.passages.map { try $0.mapped() }
                guard !passages.isEmpty else {
                    quiet = recall == nil
                        ? .sentence("Nothing in \(scope) matches what has been said so far.") : nil
                    return
                }
                recall = Recall(prompt: tail, passages: passages,
                                envelope: try payload.mappedEnvelope(), at: Date())
                quiet = nil
            } catch {
                quiet = .refused(.vocabulary("\(error)"))
            }
        case .toolFault(let text):
            quiet = .refused(VaultRefusal.classify(fault: text))
        case .rpcError(let code, let message):
            quiet = .refused(.rpcError(code: code, message: message))
        case .transportFailure(let failure):
            // A cancelled call is this object being stopped, not a fault worth drawing.
            guard !failure.isCancellation else { return }
            quiet = .refused(.of(failure))
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
