import SwiftUI

/// One spine axis, rendered. The atom the whole passage is assembled from.
///
/// Three tiers, and only the third spends colour. The tiers are also separated by text tone and by
/// the presence of chrome, so the ordering survives greyscale, a dichromat, and a screenshot:
///
///   absent     no fill, no edge, `textHelper`                    — the field was never filled in
///   record     `layerAlt` fill, `borderSubtle` edge, `textSecondary` — a judged, default value
///   deviation  wash fill, `mark` edge, `textPrimary`              — the one tier that is coloured
///
/// The middle tier's edge is load-bearing, not decoration: its fill alone measured 1.10:1 against
/// the card it sits on, so "separated by the presence of chrome" was false for the step that most
/// needed it. Neutral chrome, because `.record` is the default case and Rule 3 forbids colour there.
///
/// Geometry is identical across all three (`strokeBorder` insets rather than grows), so a matrix of
/// badges stays on its columns and the eye can compare tiers by weight alone.
struct SpineBadge: View {

    /// Making the mark and its wash one case is what stops a badge from ever being drawn with a
    /// `danger` edge over a `stale` wash — the invalid state is not representable.
    enum Prominence {
        /// Absent signal. NOT low confidence: rendered by removing chrome, not by fading ink.
        /// `Ink.textPlaceholder` would be the semantically exact token and is not used, because at
        /// 11pt it measures 2.16:1 on `Ink.layer` in light — an "empty field" a reader cannot read
        /// is worse than one drawn in the same ink as the rest of the provenance line.
        case absent
        /// A judged, default value. Quiet by construction; this is the tier rule 3 protects.
        case record
        case deviation(mark: Tone, wash: Tone)

        /// A reader could take this passage for settled fact. `Ink.warning` is the intuitive
        /// choice and is still wrong, though no longer for the contrast reason: warning now
        /// carries a light-appearance ink (4.53:1 on `Ink.layer`) and would read fine as an edge.
        /// As a FILL it still needs a dark on-colour ink the token layer does not have
        /// (`Ink.textOnColor` is white, 1.68:1 on the dark ink). What settles it is severity:
        /// a proposal read as a decision is a wrong action, not a caution.
        static let unsettled = Prominence.deviation(mark: Ink.danger, wash: Ink.dangerSoft)

        /// Outside the default corpus. `stale` and not `warning` for the same reason the index-is-
        /// moving state uses it: low-chroma slate says "not the current thing" without alarming.
        static let excluded = Prominence.deviation(mark: Ink.stale, wash: Ink.staleSoft)

        /// What the gallery's colour census counts. Derived here so the census cannot drift from
        /// what the badge actually draws.
        var carriesColour: Bool {
            if case .deviation = self { return true }
            return false
        }

        /// `Ink` has no transparent token and `surface` needs a fill, so absence multiplies an
        /// existing token's alpha to zero rather than inventing a `Tone` outside the palette.
        var fill: Tone {
            switch self {
            case .absent: return Ink.layerAlt.opacity(0)
            case .record: return Ink.layerAlt
            case .deviation(_, let wash): return wash
            }
        }

        var edge: Tone? {
            switch self {
            case .absent:
                return nil
            case .record:
                // A HAIRLINE, because the fill alone did not survive its own surface. `.record`
                // filled `layerAlt` on a card of `layer` — 1.10:1 in light, under the system's own
                // 1.15 same-colour floor, and 1.00:1 where the badge is drawn on `background`. So
                // the middle tier of a three-step escalation rendered identically to the lowest,
                // and a JUDGED value read as one nobody ever filled in — the inverse failure this
                // component exists to make impossible.
                //
                // `borderSubtle` and not a tint: `.record` is the DEFAULT case, so Rule 3 forbids
                // colour here. E0E0E0/393939 is R==G==B, so the passage stays achromatic and the
                // three tiers now separate by chrome that survives greyscale — none, neutral
                // hairline, coloured mark — rather than by two fills a reader cannot tell apart.
                return Ink.borderSubtle
            case .deviation(let mark, _):
                return mark
            }
        }

        var text: Tone {
            switch self {
            case .absent: return Ink.textHelper
            case .record: return Ink.textSecondary
            case .deviation: return Ink.textPrimary
            }
        }
    }

    /// Always rendered. The word is the signal; colour only says "stop here".
    let label: String
    let prominence: Prominence

    var body: some View {
        Text(label)
            .typeface(Register.monoMicro, prominence.text)
            .controlBox(Density.pill, horizontal: Gap.s8, vertical: Gap.s2)
            .surface(prominence.fill,
                     radius: Corner.control,
                     border: prominence.edge,
                     width: Elevation.hairline)
    }
}

/// The spine axes in reading order, taken from the passage rather than named here.
///
/// A `ForEach` over `Passage.spineAxes` and not one badge per field: the spine used to name its
/// three axes, which made "the model grew an axis" and "the card draws it" two separate edits with
/// nothing joining them. It only takes one of those to be forgotten for a withheld class to render
/// as default corpus.
///
/// Every axis is always drawn, including the defaults. A badge that disappeared when it held its
/// default value would make "declared active" indistinguishable from "field missing" — the same
/// conflation the confidence axis exists to prevent, applied to status.
struct PassageSpine: View {
    let passage: Passage

    var body: some View {
        HStack(spacing: Gap.s6) {
            ForEach(passage.spineAxes) { SpineBadge(label: $0.label, prominence: $0.prominence) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
