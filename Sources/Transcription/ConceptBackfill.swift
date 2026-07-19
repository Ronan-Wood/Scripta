import Foundation
import ScriptaCore

/// One-time enrichment pass that adds concept topic tags to transcripts recorded before the topics
/// feature (or otherwise left untagged). Topics only — title, summary, and participants are never
/// touched. User-triggered because it runs the on-device model (battery), and idempotent: it only
/// considers calls whose topic tags are empty, so re-running is safe.
enum ConceptBackfill {
    /// Transcripts that would gain topics — those with no tag beyond the implicit "call".
    static func pending() -> [URL] {
        TranscriptStore.list()
            .filter { $0.tags.filter { $0 != "call" }.isEmpty }
            .map(\.url)
    }

    /// Enriches each pending transcript, writes its topics into frontmatter, and reindexes.
    /// `progress(done, total)` is invoked on the main actor after each. Returns the number tagged.
    @discardableResult
    static func run(progress: @escaping @MainActor (_ done: Int, _ total: Int) -> Void = { _, _ in }) async -> Int {
        guard TranscriptEnricher.isAvailable else { return 0 }
        let urls = pending()
        var tagged = 0
        for (i, url) in urls.enumerated() {
            if let meta = TranscriptStore.meta(of: url),
               let digest = await TranscriptEnricher.enrich(TranscriptStore.body(of: url)) {
                let topics = digest.topics.filter { $0 != "call" }
                if !topics.isEmpty {
                    let merged = Array(Set(meta.tags + topics)).sorted()
                    try? TranscriptMetadataEditor.update(url: url, title: meta.title,
                                                         participants: meta.participants, tags: merged)
                    if let store = IndexStore.shared { IndexBuilder.index(url, into: store) }
                    tagged += 1
                }
            }
            await MainActor.run { progress(i + 1, urls.count) }
        }
        return tagged
    }
}
