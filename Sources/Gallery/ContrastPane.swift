import AppKit
import SwiftUI

/// The contrast gate, rendered. Same math as `ContrastGateTests` in the Core package, run against
/// the live `Tone` values instead of a parse of `Ink.swift` — if the two ever disagree, one of them
/// is reading a stale definition and that is worth seeing.
struct ContrastPane: View {
    let appearance: GalleryAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s16) {
            ContrastLegend()
            ForEach(InkCatalog.surfaces) { surface in
                SurfaceContrastCard(surface: surface, appearance: appearance)
            }
            WashContrastCard(appearance: appearance)
            FillContrastCard(appearance: appearance)
        }
    }
}

private struct ContrastLegend: View {
    var body: some View {
        GalleryCard(title: "Contrast gate",
                    note: "4.5:1 body copy (1.4.3), 3:1 icons, control boundaries and focus rings (1.4.11). Failures are findings, not thresholds to move.") {
            Text("Washes are composited over their base in gamma-encoded sRGB before measuring — the ratio of a translucent token against nothing is a number no screen ever shows.")
                .proseText(Register.proseSm, Ink.textSecondary)
        }
    }
}

private struct SurfaceContrastCard: View {
    let surface: InkToken
    let appearance: GalleryAppearance

    var body: some View {
        GalleryCard(title: "on \(surface.name)") {
            VStack(alignment: .leading, spacing: Gap.s2) {
                ForEach(InkCatalog.foregrounds, id: \.token.id) { entry in
                    ContrastRow(label: entry.token.name,
                                pair: pair(entry.token),
                                required: entry.required,
                                appearance: appearance)
                }
            }
        }
    }

    private func pair(_ foreground: InkToken) -> ContrastPair {
        ContrastPair(foreground: foreground.tone, background: surface.tone, wash: nil)
    }
}

/// A wash is only meaningful over a base, so each one is measured twice — over `background` and
/// over `layer`, the two surfaces a selected or flagged row actually sits on.
private struct WashContrastCard: View {
    let appearance: GalleryAppearance

    private static let bases: [InkToken] = [
        InkToken("background", Ink.background),
        InkToken("layer", Ink.layer),
    ]

    var body: some View {
        GalleryCard(title: "Ink over its own soft wash",
                    note: "The wash lifts the background toward the ink. This is where same-hue pairings lose the contrast they look like they have.") {
            VStack(alignment: .leading, spacing: Gap.s2) {
                ForEach(rows, id: \.0) { row in
                    ContrastRow(label: row.0, pair: row.1, required: Wcag.bodyText, appearance: appearance)
                }
            }
        }
    }

    private var rows: [(String, ContrastPair)] {
        InkCatalog.washes.flatMap { entry in
            Self.bases.map { base in
                ("\(entry.ink.name) / \(entry.wash.name) over \(base.name)",
                 ContrastPair(foreground: entry.ink.tone, background: base.tone, wash: entry.wash.tone))
            }
        }
    }
}

private struct FillContrastCard: View {
    let appearance: GalleryAppearance

    var body: some View {
        GalleryCard(title: "Foreground on a saturated fill",
                    note: "Only the fills the token set names a foreground for. There is no dark-on-colour token, so every fill here has to work under white.") {
            VStack(alignment: .leading, spacing: Gap.s2) {
                ForEach(InkCatalog.fills, id: \.fill.id) { entry in
                    ContrastRow(label: "\(entry.ink.name) on \(entry.fill.name)",
                                pair: ContrastPair(foreground: entry.ink.tone, background: entry.fill.tone, wash: nil),
                                required: Wcag.bodyText,
                                appearance: appearance)
                }
            }
        }
    }
}

struct ContrastPair {
    let foreground: Tone
    let background: Tone
    /// Optional translucent layer between the two.
    let wash: Tone?

    func ratio(in appearance: GalleryAppearance) -> Double {
        let base = background.resolved(for: appearance.resolved)
        let bg = wash.map { Wcag.composite($0.resolved(for: appearance.resolved), over: base) } ?? base
        return Wcag.ratio(foreground.resolved(for: appearance.resolved), bg)
    }
}

struct ContrastRow: View {
    let label: String
    let pair: ContrastPair
    let required: Double?
    let appearance: GalleryAppearance

    var body: some View {
        HStack(spacing: Gap.s8) {
            ContrastSample(pair: pair, appearance: appearance)
            Text(label).typeface(Register.monoMicro, Ink.textPrimary)
            Spacer(minLength: Gap.s8)
            RatioBadge(ratio: pair.ratio(in: appearance), required: required)
        }
        .frame(minHeight: Density.pill)
    }
}

/// The pairing drawn, not just scored. A number without the swatch beside it is a claim about a
/// rendering nobody looked at.
private struct ContrastSample: View {
    let pair: ContrastPair
    let appearance: GalleryAppearance

    var body: some View {
        Text("Aa")
            .typeface(Register.uiEmphasis, pair.foreground)
            .frame(width: Specimen.tileWidth, height: Specimen.chipHeight)
            .background(background, in: Corner.shape(Specimen.corner))
            .hairline(Ink.borderSubtle, radius: Specimen.corner)
    }

    private var background: Color {
        let base = pair.background.resolved(for: appearance.resolved)
        guard let wash = pair.wash else { return Color(nsColor: base) }
        return Color(nsColor: Wcag.composite(wash.resolved(for: appearance.resolved), over: base))
    }
}
