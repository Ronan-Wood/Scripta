import AppKit
import SwiftUI

// MARK: - Gallery chrome
//
// The gallery is built out of the system it reviews — if a card, a label or a row cannot be made
// from `Ink` / `Register` / `Metrics` / `Surface` alone, that is a gap in the system, not a licence
// to reach for a literal. The one deliberate exception is `Specimen`, below.

/// The gallery's one sanctioned exemption from `Density`'s "never `.frame(height:)`", named once
/// instead of spelled as a literal at eight call sites.
///
/// The rule it bends is about CONTENT: a fixed height clips the moment a label wraps or a locale
/// runs long. Nothing here has content. Every value is a MEASURING INSTRUMENT — a swatch, a band, a
/// ruler, a radius sample — whose whole job is to be exactly one size in both appearance columns so
/// the two can be compared by eye. Anything with a word in it takes `.controlBox(_:)` and a minimum
/// like the rest of the system, and `SystemRuleTests.testFixedHeightsAreNamedAndJustified` is what
/// stops "it is only a swatch" from being claimed about a row that does have words in it.
enum Specimen {
    /// The two-half token chip: `ShapeStyle` path on the left, pre-resolved on the right.
    static let chipWidth: CGFloat = 56
    /// A single-colour tile beside a contrast or border row.
    static let tileWidth: CGFloat = 34
    static let chipHeight: CGFloat = 22
    /// A colour band wide enough to judge a hue by, in the dichromacy strips.
    static let bandHeight: CGFloat = 34
    /// A shape sample, where the point is the corner and not the box.
    static let shapeHeight: CGFloat = 56
    /// A ruler drawn AT a token's value: tall enough to see, never tall enough to read as a block.
    static let rulerHeight: CGFloat = 10
    /// The travelling mark on a motion track.
    static let markWidth: CGFloat = 22
    static let markHeight: CGFloat = 14
    /// Label gutters, so a column of names lines up against the samples beside it.
    static let nameColumn: CGFloat = 40
    static let curveColumn: CGFloat = 54
    /// Swatch corner. Smaller than `Corner.control`, because at 22pt tall a 7pt radius is a pill.
    static let corner: CGFloat = 4
}

struct GalleryCard<Content: View>: View {
    let title: String
    var note: String?
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s12) {
            CardHeader(title: title, note: note)
            content()
        }
        .padding(Metrics.cardPadding)
        .surface(Ink.layer)
    }
}

private struct CardHeader: View {
    let title: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text(title).typeface(Register.title3, Ink.textPrimary)
            if let note { Text(note).proseText(Register.proseSm, Ink.textSecondary) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

struct GroupLabel: View {
    let text: String

    var body: some View {
        Text(text)
            .microLabel(Ink.textHelper)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.top, Gap.s6)
    }
}

/// A two-part chip: the left half is filled through the `ShapeStyle` path a real view would use,
/// the right half is the same token pre-resolved for this column's appearance. Identical halves
/// mean appearance plumbing reached the dynamic `NSColor`; a visible seam means this column is
/// showing the other theme's value and every number beside it is wrong.
struct SwatchChip: View {
    let tone: Tone
    let appearance: GalleryAppearance
    var width: CGFloat = Specimen.chipWidth

    var body: some View {
        HStack(spacing: 0) {
            Rectangle().fill(tone)
            Rectangle().fill(Color(nsColor: tone.resolved(for: appearance.resolved)))
        }
        .frame(width: width, height: Specimen.chipHeight)
        .background(Ink.background, in: Corner.shape(Specimen.corner))
        .clipShape(Corner.shape(Specimen.corner))
        .hairline(Ink.borderSubtle, radius: Specimen.corner)
    }
}

struct TokenRow: View {
    let name: String
    let tone: Tone
    let appearance: GalleryAppearance
    var note: String?

    var body: some View {
        // .center, not .firstTextBaseline: the chip is a shape with no baseline, so a baseline
        // alignment would silently fall back to its bottom edge and skew every row.
        HStack(alignment: .center, spacing: Gap.s10) {
            SwatchChip(tone: tone, appearance: appearance)
            TokenRowText(name: name, note: note)
            Spacer(minLength: Gap.s8)
            Text(Hex.string(tone.resolved(for: appearance.resolved)))
                .typeface(Register.monoMicro, Ink.textHelper)
        }
        .frame(minHeight: Density.pill, alignment: .center)
    }
}

private struct TokenRowText: View {
    let name: String
    let note: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(name).typeface(Register.mono, Ink.textPrimary)
            if let note { Text(note).typeface(Register.caption, Ink.textHelper) }
        }
    }
}

/// PASS / FAIL against a stated WCAG level. The ratio is always shown, passing or not — a gate
/// that only prints its failures cannot be audited for the pairs it decided not to test.
struct RatioBadge: View {
    let ratio: Double
    let required: Double?

    private var passes: Bool { required.map { ratio >= $0 } ?? true }
    private var tone: Tone { required == nil ? Ink.stale : (passes ? Ink.success : Ink.danger) }

    var body: some View {
        HStack(spacing: Gap.s6) {
            Text(String(format: "%.2f:1", ratio)).typeface(Register.monoMicro, Ink.textSecondary)
            Text(label).typeface(Register.monoMicro, tone)
        }
    }

    private var label: String {
        guard let required else { return "n/a" }
        return passes ? "PASS" : String(format: "FAIL <%.1f", required)
    }
}

struct SpecimenRow<Content: View>: View {
    let name: String
    let detail: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            HStack(spacing: Gap.s8) {
                Text(name).typeface(Register.monoMicro, Ink.textSecondary)
                Text(detail).typeface(Register.monoMicro, Ink.textHelper)
            }
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.vertical, Gap.s4)
    }
}

/// Separates rows without spending a `Divider`, which draws a full-width line the token layer has
/// no opinion about.
///
/// SOLID, and it was dotted. The dotted texture is `Surface.swift`'s reserved mark for "we have no
/// basis for a verdict" — the one thing in the system that says an absence is not a value. Spending
/// it as a row separator inside the surface that REVIEWS that claim teaches the texture as
/// decoration, and a texture the reader has learned to skip cannot carry a claim two pages later.
struct RowRule: View {
    var body: some View {
        Rectangle()
            .fill(Ink.borderSubtle)
            .frame(height: Elevation.hairline)
    }
}
