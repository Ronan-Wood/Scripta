import Foundation

/// Embeds text via the assigned local embedding model (e.g. Ollama `nomic-embed-text`). Adds the
/// `search_document:` / `search_query:` prefixes nomic needs — omitting them silently tanks recall,
/// exactly the bug a live eval catches and a frozen fixture doesn't (Fable). Returns nil (graceful
/// FTS-only degradation) whenever no embedder is configured or the endpoint is unreachable.
enum Embedder {
    static var model: String { AppSettings.embedModel }
    static var isConfigured: Bool { EngineRouter.embeddingEngine() != nil }

    static func embedDocuments(_ texts: [String]) async -> [[Float]]? {
        guard let engine = EngineRouter.embeddingEngine() else { return nil }
        return await engine.embed(texts.map { "search_document: \($0)" })
    }
}
