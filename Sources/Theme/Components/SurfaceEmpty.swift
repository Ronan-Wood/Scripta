import SwiftUI

// MARK: - Record & Register: the empty state
//
// The app has several ad-hoc ones and they disagree about everything — icon size, whether there is
// an icon, whether the message is prose or chrome, whether there is a way out. This is the one.

/// Nothing here yet, and what to do about it.
///
/// `message` is PROSE and `title` is UI, which is the register distinction doing real work: the
/// heading is a label on a region, the sentence beneath it is something a person wrote. An empty
/// state whose message is set in chrome type reads as an error dialog.
struct EmptyState: View {
    let glyph: Glyph
    let title: String
    var message: String? = nil
    var actionTitle: String? = nil
    var action: (() -> Void)? = nil

    var body: some View {
        VStack(spacing: Gap.s12) {
            Icon(glyph, Register.title1, Ink.textPlaceholder)
            EmptyStateText(title: title, message: message)
            if let actionTitle, let action {
                ActionButton(title: actionTitle, rank: .secondary, action: action)
            }
        }
        .padding(.vertical, Gap.s40)
        .frame(maxWidth: Metrics.proseMaxWidth)
        .frame(maxWidth: .infinity, alignment: .center)
    }
}

private struct EmptyStateText: View {
    let title: String
    let message: String?

    var body: some View {
        VStack(spacing: Gap.s4) {
            Text(title).typeface(Register.title3, Ink.textPrimary)
            if let message {
                Text(message).proseText(Register.proseSm, Ink.textSecondary)
            }
        }
        .multilineTextAlignment(.center)
    }
}
