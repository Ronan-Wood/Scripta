import Foundation

/// The pluggable model engine. Apple Foundation Models is the zero-setup default for every AI
/// task; a power user can point the app at an OpenAI-*format* localhost/LAN server (Ollama /
/// LM Studio / MLX — the wire format only, never cloud) and assign a bigger model per task.
///
/// Design invariants (see the ratified design note): everything local; Apple FM is the default and
/// the automatic downward fallback; no SDK deps; the recording pipeline never imports this layer.

/// Rough capability tier a prompt is written for — NOT the engine's identity. `.compact` = today's
/// ~3B Apple FM (strict, literal); `.capable` = a 7–20B local model or a future on-device tier.
enum SizeClass: String { case compact, capable }

/// The AI tasks the app performs. Each can resolve to a different engine.
enum EngineTask: String { case ask, enrich }

// MARK: - Chat

/// One streaming chat turn. Cumulative snapshots (each contains the whole answer so far), so a
/// consumer just assigns the latest to its message text.
protocol ChatConversing: AnyObject {
    func stream(_ prompt: String) -> AsyncThrowingStream<String, Error>
}

/// A chat-capable engine (Ask). `makeChat` opens a multi-turn conversation seeded with grounding
/// instructions; the conversation owns its own history/recovery.
protocol ChatEngine {
    var sizeClass: SizeClass { get }
    /// Short user-facing attribution, e.g. "Apple Intelligence" or "qwen2.5:14b (local)".
    var label: String { get }
    func makeChat(instructions: String) -> ChatConversing
}

// MARK: - Enrichment

/// A title/summary/topics generator (concrete return type — sidesteps the Generable-vs-Codable
/// generic-dispatch problem: Apple FM builds it via @Generable, the endpoint via JSON decode).
/// Also the notes-merge (M16) generator — same "per-call AI enrichment" bucket, same assigned
/// model/settings, just a different-shaped call on the same engine.
protocol EnrichEngine {
    var label: String { get }
    func digest(transcript: String, sizeClass: SizeClass) async -> TranscriptDigest?
    func mergeNotes(transcript: String, notes: String, sizeClass: SizeClass) async -> String?
}

/// Plain decodable shape the endpoint parses JSON-mode output into (TranscriptDigest itself is
/// @Generable, which doesn't give us Codable).
struct DigestDTO: Decodable {
    let title: String
    let summary: String
    let topics: [String]
}

/// Plain decodable shape the endpoint parses notes-merge JSON-mode output into.
struct MergeNotesDTO: Decodable {
    let body: String
}

// MARK: - Reranking + embeddings (gated experiments — see P10 / design phases E, F)

/// Listwise reranker. Apple FM deliberately does NOT conform (measured too weak); only a capable
/// endpoint model does. Returns candidate indices most→least relevant, or nil to fail open.
protocol RerankEngine {
    func rerank(query: String, passages: [(index: Int, text: String)]) async -> [Int]?
}

/// Text embedder for Phase B vector fusion. Only reopened behind a measured eval gate — the
/// on-device NLContextualEmbedding already failed it.
protocol EmbeddingEngine {
    var embedModel: String { get }
    func embed(_ texts: [String]) async -> [[Float]]?
}

// MARK: - Errors

enum EngineError: LocalizedError {
    case notConfigured
    case refusedHost(String)
    case unreachable
    case modelNotFound(String)
    case badResponse
    case timedOut
    case responseTooLarge
    case http(Int)

    var errorDescription: String? {
        switch self {
        case .notConfigured: return "No local model server is configured."
        case .refusedHost(let h): return "“\(h)” isn’t a local address. Only localhost and your local network are allowed."
        case .unreachable: return "Couldn’t reach the local model server."
        case .modelNotFound(let m): return "The assigned model “\(m)” isn’t on the server anymore."
        case .badResponse: return "The local model server returned an unexpected response."
        case .timedOut: return "The local model server timed out."
        case .responseTooLarge: return "The local model server sent an unexpectedly large response."
        case .http(let code): return "The local model server returned HTTP \(code)."
        }
    }
}
