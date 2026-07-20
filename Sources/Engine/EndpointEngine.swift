import Foundation

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

    func stream(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        messages.append(["role": "user", "content": prompt])
        let outgoing = messages
        return AsyncThrowingStream { continuation in
            Task {
                var final = ""
                do {
                    for try await snapshot in wire.stream(model: model, messages: outgoing) {
                        final = snapshot
                        continuation.yield(snapshot)
                    }
                    if !final.isEmpty { messages.append(["role": "assistant", "content": final]) }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }
}
