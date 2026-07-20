import SwiftUI

/// Related passages for any open transcript, note, or document (M18) — generalizes
/// `RelatedCallsPanel`'s live mechanism (index search) to a static item: the query is the item's
/// own content (title + topics/tags) instead of live speech. Raw hits render immediately from
/// retrieval, same as the live panel; a synthesized connective line fills in progressively once
/// ≥2 hits come back — opening an item must never wait on an LLM call for its related rail to
/// appear. Sources stay visible beneath the synthesis (Clovis's own answer-plus-sources
/// discipline): a claimed connection must stay traceable back to what it's grounded in.
struct RelatedItemsPanel: View {
    /// What to search with — title + topics/tags is the default the callers below use.
    let query: String
    /// Excluded from results so an item never shows up as "related" to itself.
    let excludePath: String
    let group: String

    @ObservedObject private var model = AppModel.shared
    @State private var hits: [RelatedHit] = []
    @State private var synthesis: String?
    @State private var loadedQuery: String?

    var body: some View {
        Group {
            if loadedQuery == query && hits.isEmpty {
                EmptyView()
            } else if !hits.isEmpty {
                VStack(alignment: .leading, spacing: Space.x3) {
                    SectionHeader(title: "Related")
                    if let synthesis {
                        Text(synthesis)
                            .font(CarbonFont.body(13)).foregroundStyle(Carbon.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    ForEach(hits) { hit in
                        RelatedHitCard(hit: hit) { model.route = .call(hit.url, ms: hit.startMs) }
                    }
                }
            }
        }
        .task(id: query) { await load() }
    }

    /// `q == query` (comparing a `let`-frozen local snapshot to the view's OWN `query` property)
    /// can never be false within one `load()` invocation — it was a no-op guard, not real
    /// staleness protection (crosscheck). `Task.isCancelled` is the real check: SwiftUI cancels
    /// this `.task(id: query)`'s Task the moment `query` changes, and this function runs AS that
    /// task (not detached), so the flag correctly reflects whether a newer load has superseded
    /// this one — e.g. editing the open item's title/tags mid-synthesis without navigating away
    /// (same view identity, new `query`) must not let a slow, stale result overwrite the fresh one.
    private func load() async {
        synthesis = nil
        hits = []
        guard let store = model.index, query.split(separator: " ").count >= 2 else {
            loadedQuery = query; return
        }
        let q = query, exclude = excludePath, g = group
        let (found, rawHits) = await Task.detached(priority: .utility) { () -> ([RelatedHit], [(title: String, snippet: String)]) in
            var seen = Set<URL>()
            let scored = store.search(q, group: g, limit: 12)
                .filter { $0.path != exclude && $0.score <= RelatedHit.relevanceFloor }
            var built: [RelatedHit] = []
            var raw: [(title: String, snippet: String)] = []
            for hit in scored {
                let url = URL(fileURLWithPath: hit.path)
                guard seen.insert(url).inserted else { continue }
                let title = hit.title.isEmpty ? hit.date : hit.title
                built.append(RelatedHit(url: url, title: title,
                                        snippet: SnippetHighlight.attributed(hit.snippet, accent: Carbon.interactive),
                                        startMs: hit.startMs))
                raw.append((title: title, snippet: hit.snippet))
                if built.count >= 4 { break }
            }
            return (built, raw)
        }.value

        guard !Task.isCancelled else { return }
        hits = found
        loadedQuery = q
        guard rawHits.count >= 2 else { return }
        // The expensive step: only reachable once retrieval already confirmed ≥2 real hits, and
        // skipped outright if a newer query already superseded this load.
        let result = await RelatedSynthesizer.synthesize(current: q, hits: rawHits)
        guard !Task.isCancelled else { return }
        synthesis = result
    }
}
