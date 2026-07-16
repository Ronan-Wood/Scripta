import Foundation

/// Retrieval facade above the (untouched, synchronous) IndexStore. When the reranker is enabled
/// and available, it pulls a wider BM25 candidate set and reorders it with a listwise LLM pass;
/// otherwise it returns the store's ranking directly. Fail-open: any rerank failure falls back to
/// BM25 order. Only the Ask path uses this — ⌘F search stays a direct <50ms FTS call.
enum Retriever {
    static func context(for query: String, group: String?, limit k: Int) async -> [ContextChunk] {
        guard let store = IndexStore.shared else { return [] }
        let reranker = EngineRouter.rerankEngine()
        // Widen the candidate pool only when we're going to rerank it.
        let candidates = store.context(for: query, group: group, limit: reranker != nil ? 40 : k)
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
