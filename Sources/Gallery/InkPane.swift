import SwiftUI

/// Every `Ink` token, grouped by role, with the value this column's appearance actually resolves.
struct InkPane: View {
    let appearance: GalleryAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s16) {
            ForEach(InkCatalog.groups) { group in
                InkGroupCard(group: group, appearance: appearance)
            }
        }
    }
}

private struct InkGroupCard: View {
    let group: InkGroup
    let appearance: GalleryAppearance

    var body: some View {
        Card(title: group.title, note: group.rule) {
            VStack(alignment: .leading, spacing: Gap.s2) {
                ForEach(group.tokens) { token in
                    TokenRow(name: token.name, tone: token.tone,
                             appearance: appearance, note: token.note)
                }
            }
        }
    }
}
