import SwiftUI

/// A minimal flow layout that wraps its children.
///
/// LIVED IN `HomeView.swift` UNTIL Doc 4 §2 deleted that section, and it never belonged there: six
/// call sites across the Knowledge surfaces used it and none of them was Home. A shared component
/// parked inside the one view that happened to need it first is invisible as a shared component —
/// deleting its host is what surfaced the dependency, and it is here rather than back in an app
/// view so the next deletion does not.
///
/// NOT a Record & Register component: `Sources/Theme/Components` is gated behind a reviewed
/// migration pass, and this is the app's own layout primitive rather than part of that vocabulary.
/// `Metrics.swift` refers to it as "the one custom-layout conformance in the app", which is still
/// true — only the file it sits in has changed.
struct FlexWrap: Layout {
    var spacing: CGFloat = 8

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let maxWidth = proposal.width ?? .infinity
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > maxWidth, x > 0 { x = 0; y += rowHeight + spacing; rowHeight = 0 }
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
        return CGSize(width: maxWidth == .infinity ? x : maxWidth, height: y + rowHeight)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x = bounds.minX, y = bounds.minY, rowHeight: CGFloat = 0
        for sub in subviews {
            let size = sub.sizeThatFits(.unspecified)
            if x + size.width > bounds.maxX, x > bounds.minX { x = bounds.minX; y += rowHeight + spacing; rowHeight = 0 }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(size))
            x += size.width + spacing
            rowHeight = max(rowHeight, size.height)
        }
    }
}
