import Foundation

/// Retrieval facade above the (untouched, synchronous) IndexStore. When the reranker is enabled
/// and available, it pulls a wider BM25 candidate set and reorders it with a listwise LLM pass;
/// otherwise it returns the store's ranking directly. Fail-open: any rerank failure falls back to
/// BM25 order. Only the Ask path uses this — ⌘F search stays a direct <50ms FTS call.
enum Retriever {
    static func context(for query: String, group: String?, limit k: Int) async -> [ContextChunk] {
        guard let store = IndexStore.shared else { return [] }
        let reranker = EngineRouter.rerankEngine()

        // Hybrid path: fuse lexical (FTS) + semantic (cosine) candidate lists via RRF when the
        // corpus is embedded with the active model. Falls back to pure FTS otherwise (endpoint off,
        // no embedder, or embeddings not built) — the reliability story.
        let candidates: [ContextChunk]
        if !AppSettings.embedModel.isEmpty,
           store.hasVectors(model: AppSettings.embedModel),
           let qvec = await Embedder.embedQuery(query) {
            let fts = store.ftsCandidates(query, group: group, limit: 40)
            let vec = store.vectorCandidates(vector: qvec, group: group, model: AppSettings.embedModel, limit: 40)
            let fused = RRF.fuse([fts, vec], limit: (reranker != nil ? 40 : k))
            candidates = store.contextForChunkIDs(fused, limit: reranker != nil ? 40 : k)
        } else {
            // Widen the candidate pool only when we're going to rerank it.
            candidates = store.context(for: query, group: group, limit: reranker != nil ? 40 : k)
        }
        guard let reranker, candidates.count > k else { return Array(candidates.prefix(k)) }

        let passages = candidates.enumerated().map { (index: $0.offset, text: String($0.element.text.prefix(350))) }
        if let order = await reranker.rerank(query: query, passages: passages) {
            var out: [ContextChunk] = []
            var seen = Set<Int>()
            for i in order where candidates.indices.contains(i) && seen.insert(i).inserted {
                out.append(candidates[i])
                if out.count >= k { break }
            }
            if !out.isEmpty { return out }
        }
        return Array(candidates.prefix(k))   // fail-open to BM25 order
    }
}
