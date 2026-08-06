import SubstrateKit
import SwiftUI

/// What the vault knows about what is being said, drawn beside the live transcript (Doc 4 §8).
///
/// IT SITS NEXT TO `RelatedCallsPanel` AND IS NOT IT. That panel searches the LOCAL index for other
/// calls; this asks the workspace's composed scope, which is calls AND curated notes AND uploaded
/// documents in one query. The visual family is deliberately shared — same card shape, same
/// restraint about weak hits — because to the operator they are the same gesture; what differs is
/// the corpus, and the marker line says which.
///
/// THE WEAKER RANKING IS ON SCREEN. A live recall runs the fast arm, so its `expected_mrr` is null
/// and that null is rendered as absence rather than hidden — Doc 3 §5's rule, and it matters most
/// here because this is the surface most likely to be glanced at and believed.
struct LiveRecallPanel: View {
    @ObservedObject private var recall = AppModel.shared.recall

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            header
            if let hit = recall.recall {
                ForEach(hit.passages) { LiveRecallCard(passage: $0) }
                footer(hit)
            }
            // NOT AN `else`. A refusal used to be reachable only while nothing had been recalled
            // yet, so an engine that went down mid-call showed as a frozen hit with a counting-up
            // age — the stale-read-as-current failure, wearing the badge that was meant to prevent
            // it. The hit stays (it was true when it arrived) and the refusal is drawn beneath it.
            if let quiet = recall.quiet {
                switch quiet {
                case .sentence(let text):
                    Text(text)
                        .font(CarbonFont.label(12))
                        .foregroundStyle(Carbon.textHelper)
                        .fixedSize(horizontal: false, vertical: true)
                case .refused(let scope, let refusal):
                    // The same card every other engine surface draws a refusal with, so "the engine
                    // is down" reads identically here and in Ask — and carrying the scope, because
                    // nothing else on this screen names the corpus that refused.
                    VaultRefusalCard(refusal: refusal, scope: scope, retryTitle: nil, retry: nil)
                }
            }
            Spacer(minLength: 0)
        }
    }

    private var header: some View { SectionHeader(title: "From your vault") }

    /// WHAT RAN, AND WHEN. Both are load-bearing: the arm because a fast answer is a weaker one and
    /// must not be read as the measured stack's, and the time because a recall is up to twenty
    /// seconds behind the conversation and a stale hit read as current is the panel misleading
    /// rather than helping.
    private func footer(_ hit: LiveRecall.Recall) -> some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(verbatim: "fast retrieval · ranking unmeasured")
            // SELF-UPDATING, and on its OWN LINE. Computed against `Date()` at render time it froze
            // during exactly the stretch it matters in: when the room goes quiet the tail stops
            // changing, the dedup guard returns before any publish, nothing re-renders, and a
            // five-minute-old hit sat under a footer still reading "0s ago". `.relative` counts up
            // on its own — it is also multi-unit and unbounded, which is why it does not share a row
            // with the arm in a 300pt column.
            HStack(spacing: Space.x1) {
                Text(verbatim: "asked")
                Text(hit.at, style: .relative)
                Text(verbatim: "ago")
            }
        }
        .font(CarbonFont.label(11))
        .foregroundStyle(Carbon.textHelper)
        .fixedSize(horizontal: false, vertical: true)
    }
}

/// One recalled passage. Carries its spine, because a passage from a past CALL is raw material and
/// one from a curated note is a settled claim — and mid-conversation is exactly when that
/// difference stops being read carefully unless it is written down.
private struct LiveRecallCard: View {
    let passage: Passage

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x1) {
            Text(passage.citation)
                .font(CarbonFont.medium(12)).foregroundStyle(Carbon.textPrimary).lineLimit(2)
            if !passage.snippet.isEmpty {
                Text(passage.snippet)
                    .font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary).lineLimit(4)
            }
            Text(spine)
                .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper).lineLimit(1)
        }
        .padding(Space.x3)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
        }
    }

    /// `conversation` is named FIRST when present. It is the one label that changes how the passage
    /// should be read — a mid-call sentence can be reasoning the speaker abandoned ten minutes
    /// later — and burying it behind status/doc_type would be the class axis existing and not
    /// arriving.
    private var spine: String {
        var parts: [String] = []
        if passage.documentClass == .conversation { parts.append("from a call") }
        parts.append(passage.status.label)
        parts.append(passage.confidence.label)
        return parts.joined(separator: " · ")
    }
}
