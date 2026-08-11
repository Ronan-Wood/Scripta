import Foundation
import ScriptaShared   // ChatHistoryBudget — the retention rule, kept where a test can reach it

/// A local OpenAI-format server as a model engine. Chat streams via SSE; enrichment uses JSON mode.
final class EndpointEngine: ChatEngine, EnrichEngine {
    let model: String
    let sizeClass: SizeClass
    private let wire: OpenAIWire

    var label: String { "\(model) (local)" }

    init(baseURL: URL, model: String, lanConfirmed: Bool) {
        self.model = model
        self.wire = OpenAIWire(baseURL: baseURL, lanConfirmed: lanConfirmed)
        self.sizeClass = Self.inferSizeClass(model)
    }

    func makeChat(instructions: String) -> ChatConversing {
        EndpointChat(wire: wire, model: model, system: instructions)
    }

    func digest(transcript: String, sizeClass: SizeClass) async -> TranscriptDigest? {
        let user = PromptCatalog.enrichPrompt(transcript, sizeClass: sizeClass, jsonSchema: PromptCatalog.digestJSONSchema)
        do {
            let raw = try await wire.complete(
                model: model,
                messages: [["role": "system", "content": "You extract structured metadata from transcripts. Respond with JSON only."],
                           ["role": "user", "content": user]],
                jsonMode: true, timeout: 240)
            let json = Self.extractJSON(raw)
            guard let dto = try? JSONDecoder().decode(DigestDTO.self, from: Data(json.utf8)) else { return nil }
            return TranscriptEnricher.normalize(TranscriptDigest(title: dto.title, summary: dto.summary, topics: dto.topics))
        } catch {
            return nil
        }
    }

    func mergeNotes(transcript: String, notes: String, sizeClass: SizeClass) async -> String? {
        let user = PromptCatalog.notesMergePrompt(transcript: transcript, notes: notes, sizeClass: sizeClass,
                                                   jsonSchema: PromptCatalog.mergeNotesJSONSchema)
        do {
            let raw = try await wire.complete(
                model: model,
                messages: [["role": "system", "content": "You merge rough notes with a transcript into one grounded paragraph. Respond with JSON only."],
                           ["role": "user", "content": user]],
                jsonMode: true, timeout: 240)
            let json = Self.extractJSON(raw)
            guard let dto = try? JSONDecoder().decode(MergeNotesDTO.self, from: Data(json.utf8)) else { return nil }
            let body = dto.body.trimmingCharacters(in: .whitespacesAndNewlines)
            return body.isEmpty ? nil : body
        } catch {
            return nil
        }
    }

    func extractCommitments(transcript: String, sizeClass: SizeClass) async -> [ExtractedCommitment]? {
        let user = PromptCatalog.commitmentsPrompt(transcript: transcript, sizeClass: sizeClass,
                                                    jsonSchema: PromptCatalog.commitmentsJSONSchema)
        do {
            let raw = try await wire.complete(
                model: model,
                messages: [["role": "system", "content": "You extract explicit commitments from a transcript. Respond with JSON only."],
                           ["role": "user", "content": user]],
                jsonMode: true, timeout: 240)
            let json = Self.extractJSON(raw)
            guard let dto = try? JSONDecoder().decode(CommitmentsDTO.self, from: Data(json.utf8)) else { return nil }
            return dto.commitments.map { ExtractedCommitment(owner: $0.owner, text: $0.text) }
        } catch {
            return nil
        }
    }

    /// Parameter-count heuristic on the model id — default `.capable`, but obviously small models
    /// get the compact (strict) prompts.
    static func inferSizeClass(_ model: String) -> SizeClass {
        let id = model.lowercased()
        for small in ["0.5b", "1.5b", "1b", "2b", "3b", "phi", "gemma:2", "tinyllama"] where id.contains(small) {
            return .compact
        }
        return .capable
    }

    /// Extracts the first {...} object — models sometimes wrap JSON in prose or code fences.
    static func extractJSON(_ text: String) -> String {
        guard let start = text.firstIndex(of: "{"), let end = text.lastIndex(of: "}"), start < end else { return text }
        return String(text[start...end])
    }
}

extension EndpointEngine: RerankEngine {
    /// One JSON-mode call: number the passages and ask for a relevance ordering of their indices.
    func rerank(query: String, passages: [(index: Int, text: String)]) async -> [Int]? {
        let numbered = passages.map { "[\($0.index)] \($0.text)" }.joined(separator: "\n")
        let user = """
        Query: \(query)

        Passages:
        \(numbered)

        Return ONLY JSON {"ranking": [indices]} ordering the passage indices from most to least \
        relevant to the query. Include every index exactly once.
        """
        do {
            let raw = try await wire.complete(
                model: model,
                messages: [["role": "system", "content": "You rank passages by relevance. Respond with JSON only."],
                           ["role": "user", "content": user]],
                jsonMode: true, timeout: 10)
            struct Ranking: Decodable { let ranking: [Int] }
            guard let r = try? JSONDecoder().decode(Ranking.self, from: Data(Self.extractJSON(raw).utf8)) else { return nil }
            return r.ranking
        } catch {
            return nil
        }
    }
}

extension EndpointEngine: EmbeddingEngine {
    var embedModel: String { model }
    func embed(_ texts: [String]) async -> [[Float]]? {
        (try? await wire.embeddings(model: model, input: texts))
    }
}

/// One endpoint conversation. Keeps message history app-side so multi-turn context is preserved
/// (the server is stateless per request).
private final class EndpointChat: ChatConversing {
    private let wire: OpenAIWire
    private let model: String
    private var messages: [OpenAIWire.Message]

    init(wire: OpenAIWire, model: String, system: String) {
        self.wire = wire
        self.model = model
        self.messages = [["role": "system", "content": system]]
    }

    /// How much conversation to carry, in characters of message content.
    ///
    /// A CEILING, NOT A MODEL LIMIT, and the distinction is why it is stated rather than tuned. The
    /// endpoint is whatever the operator pointed at, so its real window is unknown here; what IS
    /// known is that history grew without bound while each Ask turn now carries up to
    /// `PromptCatalog.enrichCharCap` of retrieved passage text (24k for the capable tier). Four
    /// turns of that exceeds a 32k-token window on their own, and `EndpointChat` had no equivalent
    /// of `AppleFMChat`'s rebuild-on-`exceededContextWindowSize`, so the thread simply began failing
    /// and surfaced "Something went wrong — try again."
    ///
    /// ~48k characters is roughly 12k tokens, which leaves room for a reply on the 16k-32k windows
    /// local builds usually ship. It is a guard against unbounded growth, not a promise the endpoint
    /// accepts exactly this much.
    private static let historyCharBudget = 48_000

    func stream(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        messages.append(["role": "user", "content": prompt])
        trimHistory()
        let outgoing = messages
        return AsyncThrowingStream { continuation in
            let task = Task {
                var final = ""
                do {
                    for try await snapshot in wire.stream(model: model, messages: outgoing) {
                        final = snapshot
                        continuation.yield(snapshot)
                    }
                    // A cancelled loop exits here too (gracefully, not via catch), with `final`
                    // holding only a partial snapshot — must not commit that into history as if it
                    // were a complete reply (crosscheck).
                    if !Task.isCancelled, !final.isEmpty { messages.append(["role": "assistant", "content": final]) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Consumer stopped iterating → cancel, cascading into wire.stream()'s own onTermination
            // instead of leaking the HTTP request until the server finishes on its own (audit L10).
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    /// The rule itself is `ChatHistoryBudget`, in the package, where a test can reach it.
    private func trimHistory() {
        ChatHistoryBudget.trim(&messages, budget: Self.historyCharBudget)
    }
}
