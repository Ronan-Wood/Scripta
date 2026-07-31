import SwiftUI

// MARK: - Record & Register: cards
//
// `CarbonCard` exists and has ONE call site. The same construction — layer fill, hairline border,
// `Corner.card`, 16 of padding — is written inline 32 more times. Nothing about those 32 is
// different; they were faster to type than to find. This one is the only card.

/// A hairline-bordered surface. Hairline over shadow is the house style and stays that way: a
/// hairline reads at any window opacity and over vibrancy, where a shadow becomes a grey smear.
///
/// `floating` is the exception the style names — drawers, popovers and sheets genuinely leave the
/// layout, and they are the only things that get the one real elevation.
struct Card<Content: View>: View {
    var title: String? = nil
    var note: String? = nil
    /// `Metrics.cardPaddingCompact` instead of `cardPadding`. For cards inside a drawer or sidebar,
    /// where 16 costs a column of text.
    var compact: Bool = false
    var floating: Bool = false
    var fill: Tone = Ink.layer
    @ViewBuilder var content: () -> Content

    @ViewBuilder
    var body: some View {
        if floating {
            core.overlayShadow()
        } else {
            core
        }
    }

    private var core: some View {
        VStack(alignment: .leading, spacing: Gap.s12) {
            if title != nil || note != nil { CardHeading(title: title, note: note) }
            content()
        }
        .padding(compact ? Metrics.cardPaddingCompact : Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(fill, radius: Corner.card)
    }
}

private struct CardHeading: View {
    let title: String?
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s2) {
            if let title { Text(title).typeface(Register.title3, Ink.textPrimary) }
            // Prose, not UI: a card's note is a sentence a person wrote, and the register is what
            // tells a reader that before they read a word of it.
            if let note { Text(note).proseText(Register.proseSm, Ink.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// A statistic. Mono numerals so a row of these column-aligns, which is the one thing a row of
/// stat tiles actually needs and the reason `Register.numeral` is not Sans SemiBold.
struct StatCard: View {
    let label: String
    let value: String
    var unit: String? = nil
    var tone: Tone = Ink.textPrimary

    var body: some View {
        Card {
            VStack(alignment: .leading, spacing: Gap.s6) {
                Text(label).microLabel()
                StatValue(value: value, unit: unit, tone: tone)
            }
        }
    }
}

private struct StatValue: View {
    let value: String
    let unit: String?
    let tone: Tone

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Gap.s4) {
            Text(value).typeface(Register.numeral, tone)
            if let unit { Text(unit).typeface(Register.mono, Ink.textSecondary) }
        }
    }
}
