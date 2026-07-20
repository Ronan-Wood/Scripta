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

    /// FTS5 bm25 is negative (lower = stronger) — same floor `RelatedCallsPanel` uses, so a
    /// thin/no-real-match query shows nothing rather than four unrelated cards.
    private static let relevanceFloor = -0.5

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
                        Button { model.route = .call(hit.url, ms: hit.startMs) } label: {
                            VStack(alignment: .leading, spacing: Space.x1) {
                                Text(hit.title).font(CarbonFont.medium(13)).foregroundStyle(Carbon.interactive).lineLimit(1)
                                Text(hit.snippet).font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary).lineLimit(3)
                            }
                            .padding(Space.x3)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                            .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
                            .contentShape(Rectangle())
                        }.buttonStyle(.plain)
                    }
                }
            }
        }
        .task(id: query) { await load() }
    }

    private func load() async {
        synthesis = nil
        guard let store = model.index, query.split(separator: " ").count >= 2 else {
            hits = []; loadedQuery = query; return
        }
        let q = query, exclude = excludePath, g = group
        let (found, rawHits) = await Task.detached(priority: .utility) { () -> ([RelatedHit], [(title: String, snippet: String)]) in
            var seen = Set<URL>()
            let scored = store.search(q, group: g, limit: 12)
                .filter { $0.path != exclude && $0.score <= Self.relevanceFloor }
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

        guard q == query else { return }   // query changed (fast navigation) — discard a stale load
        hits = found
        loadedQuery = query
        guard rawHits.count >= 2 else { return }
        let result = await RelatedSynthesizer.synthesize(current: query, hits: rawHits)
        guard q == query else { return }   // guard the async gap again — synthesis can take seconds
        synthesis = result
    }
}
