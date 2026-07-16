import SwiftUI

/// Live "from your other calls" panel: every few seconds it searches the index with the recent
/// live transcript and surfaces related passages from past calls. All local, instant (SQLite).
struct RelatedCallsPanel: View {
    @ObservedObject private var model = AppModel.shared
    @State private var related: [Related] = []
    @State private var timer: Timer?

    /// FTS5 bm25 is negative (lower = stronger); below this floor a hit is too weak to show. An
    /// empty panel costs less trust than four irrelevant cards. Tune empirically.
    private static let relevanceFloor = -0.5

    struct Related: Identifiable {
        let id = UUID()
        let url: URL
        let title: String
        let snippet: AttributedString
        let startMs: Int
    }

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            SectionHeader(title: "From your other calls")
            if related.isEmpty {
                Text("Related calls surface here as topics come up.")
                    .font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(related) { hit in
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
            Spacer(minLength: 0)
        }
        .onAppear {
            refresh()
            timer = Timer.scheduledTimer(withTimeInterval: 5, repeats: true) { _ in
                Task { @MainActor in refresh() }
            }
        }
        .onDisappear { timer?.invalidate(); timer = nil }
    }

    /// Searches the index with the most recent live text, deduped to distinct calls. The FTS
    /// query runs off the main actor — it contends on the store's lock with background upserts,
    /// which must not stall the recording UI.
    private func refresh() {
        let recent = AppModel.shared.live.finalized.suffix(4).joined(separator: " ")
        guard recent.split(separator: " ").count >= 4, let store = model.index else { return }
        Task.detached(priority: .utility) {
            // Passage-only (a real spoken moment) and above the relevance floor — show nothing
            // rather than weak topic/filler cards fed by raw live speech.
            let hits = store.search(recent, limit: 12)
                .filter { $0.startMs > 0 && $0.score <= Self.relevanceFloor }
            await MainActor.run {
                var seen = Set<URL>()
                related = hits.compactMap { hit in
                    let url = URL(fileURLWithPath: hit.path)
                    guard seen.insert(url).inserted else { return nil }
                    return Related(url: url, title: hit.title.isEmpty ? hit.date : hit.title,
                                   snippet: SnippetHighlight.attributed(hit.snippet, accent: Carbon.interactive),
                                   startMs: hit.startMs)
                }.prefix(4).map { $0 }
            }
        }
    }
}
