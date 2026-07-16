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

    static func embedQuery(_ text: String) async -> [Float]? {
        guard let engine = EngineRouter.embeddingEngine() else { return nil }
        return await engine.embed(["search_query: \(text)"])?.first
    }
}

/// Reciprocal-rank fusion — parameter-free, and the right choice because BM25 and cosine scores
/// live on incomparable scales (weight-tuning at small N just overfits the ruler).
enum RRF {
    static func fuse(_ lists: [[Int64]], k: Int = 60, limit: Int) -> [Int64] {
        var score: [Int64: Double] = [:]
        for list in lists {
            for (rank, id) in list.enumerated() { score[id, default: 0] += 1.0 / Double(k + rank + 1) }
        }
        return score.sorted { $0.value != $1.value ? $0.value > $1.value : $0.key < $1.key }
            .prefix(limit).map(\.key)
    }
}
