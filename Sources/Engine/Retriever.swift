import Foundation
import OSLog
import ScriptaCore

/// Retrieval facade above the (untouched, synchronous) IndexStore. When the reranker is enabled
/// and available, it pulls a wider BM25 candidate set and reorders it with a listwise LLM pass;
/// otherwise it returns the store's ranking directly. Fail-open: any rerank failure falls back to
/// BM25 order. Only the Ask path uses this — ⌘F search stays a direct <50ms FTS call.
enum Retriever {
    private static let log = Logger(subsystem: "com.ronanwood.Scripta", category: "Retrieval")

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
            var hybrid = store.contextForChunkIDs(fused, limit: reranker != nil ? 40 : k)
            // The chunk/vector path can't see topic-only matches (documents, notes, concept-tag
            // calls) — they have no chunks or vectors. Fold them in, or embeddings silently hide
            // every imported document and every knowledge note from Ask.
            let topics = store.topicMatches(for: query, group: group, limit: 3)
            hybrid += topics.filter { t in !hybrid.contains { $0.path == t.path } }
            candidates = hybrid
        } else {
            // Widen the candidate pool only when we're going to rerank it. Pure FTS already folds
            // in topic matches via IndexStore.context.
            candidates = store.context(for: query, group: group, limit: reranker != nil ? 40 : k)
        }
        guard let reranker, candidates.count > k else { return Array(candidates.prefix(k)) }

        let passages = candidates.enumerated().map { (index: $0.offset, text: String($0.element.text.prefix(350))) }
        guard let order = await reranker.rerank(query: query, passages: passages) else {
            return Array(candidates.prefix(k))   // fail-open to BM25 order
        }

        // A REORDERING, NOT A SELECTION — and the difference was load-bearing. This used to accept
        // any non-empty result, so a reply of `{"ranking":[3]}` returned ONE passage where the
        // caller asked for `k`. The fail-open below only caught a ranking that was entirely empty
        // or entirely out of range; a ranking that was merely SHORT read as a complete answer, and
        // a listwise LLM truncating its own output is the ordinary way this fails.
        //
        // The cost landed downstream, not here. `AskModel:243-245` computes its grounding label
        // from the SIZE of this array — `passages >= 3` is "Well grounded" — and it cannot tell
        // "retrieval found little" from "the reranker replied badly". Its one honesty escape,
        // `usedFallback`, tracks the QUERY retry and never sees this. So a reply truncated to three
        // indices presented as "Well grounded" over three chunks of a requested eight.
        //
        // Backfilled rather than rejected. The model's opinion about the passages it DID rank is
        // still worth having, and dropping the whole reply would throw that away over a truncation;
        // returning short would be the bug. So the reply orders the front of the list and the
        // BM25/RRF order fills the rest, which is exactly what an absent reranker would have
        // returned. The result is always `k` when `k` candidates exist.
        var chosen: [Int] = []
        var seen = Set<Int>()
        for i in order where candidates.indices.contains(i) && seen.insert(i).inserted {
            chosen.append(i)
            if chosen.count >= k { break }
        }
        let ranked = chosen.count
        if ranked < k {
            for i in candidates.indices where seen.insert(i).inserted {
                chosen.append(i)
                if chosen.count >= k { break }
            }
            // Visible, because a reranker that silently half-answers every query is a quality
            // regression with no symptom: the answers stay plausible and the ranking quietly
            // becomes BM25's below position \(ranked).
            log.info("rerank returned \(ranked) usable of \(k) requested over \(candidates.count) candidates; backfilled from lexical order")
        }
        return chosen.map { candidates[$0] }
    }
}
