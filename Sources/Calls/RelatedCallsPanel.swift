import SwiftUI

/// One related-item hit, shared by `RelatedCallsPanel` (live, during recording) and
/// `RelatedItemsPanel` (M18 — any open transcript/note/doc).
struct RelatedHit: Identifiable {
    let id = UUID()
    let url: URL
    let title: String
    let snippet: AttributedString
    let startMs: Int

    /// FTS5 bm25 is negative (lower = stronger); below this floor a hit is too weak to show. An
    /// empty panel costs less trust than four irrelevant cards. Shared so the two panels can't
    /// silently drift to different thresholds (crosscheck: this used to be duplicated).
    static let relevanceFloor = -0.5
}

/// The card both panels render for one hit — actually shared (crosscheck: the previous version
/// claimed this via `RelatedHit` alone while the ~11-line card view stayed copy-pasted in both
/// files). A visual change here reaches every related-item surface, including the notes/docs one
/// SPEC.md defers, without a second copy to keep in sync.
struct RelatedHitCard: View {
    let hit: RelatedHit
    let onSelect: () -> Void

    var body: some View {
        Button(action: onSelect) {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(hit.title).font(CarbonFont.medium(13)).foregroundStyle(Carbon.interactive).lineLimit(1)
                Text(hit.snippet).font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary).lineLimit(3)
            }
            .padding(Space.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay { RoundedRectangle(cornerRadius: Radius.control, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

/// Live "from your other calls" panel: every few seconds it searches the index with the recent
/// live transcript and surfaces related passages from past calls. All local, instant (SQLite).
struct RelatedCallsPanel: View {
    @ObservedObject private var model = AppModel.shared
    @State private var related: [RelatedHit] = []
    @State private var timer: Timer?

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            SectionHeader(title: "From your other calls")
            if related.isEmpty {
                Text("Related calls surface here as topics come up.")
                    .font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(related) { hit in
                    RelatedHitCard(hit: hit) { model.route = .call(hit.url, ms: hit.startMs) }
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
            let hits = store.search(recent, group: AppSettings.activeGroup, limit: 12)
                .filter { $0.startMs > 0 && $0.score <= RelatedHit.relevanceFloor }
            await MainActor.run {
                var seen = Set<URL>()
                related = hits.compactMap { hit in
                    let url = URL(fileURLWithPath: hit.path)
                    guard seen.insert(url).inserted else { return nil }
                    return RelatedHit(url: url, title: hit.title.isEmpty ? hit.date : hit.title,
                                      snippet: SnippetHighlight.attributed(hit.snippet, accent: Carbon.interactive),
                                      startMs: hit.startMs)
                }.prefix(4).map { $0 }
            }
        }
    }
}
