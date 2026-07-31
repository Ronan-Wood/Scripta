import SwiftUI

/// Elevation, borders, texture and motion — the parts of the system that are shapes rather than
/// values, and therefore the parts a table cannot review.
struct SurfacePane: View {
    let appearance: GalleryAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s16) {
            SurfaceRecipesCard()
            BorderVisibilityCard(appearance: appearance)
            StaleTextureCard()
            MotionCard()
        }
    }
}

private struct SurfaceRecipesCard: View {
    var body: some View {
        GalleryCard(title: "Surfaces",
                    note: "Hairline over shadow is the house style; the shadow is reserved for things that genuinely float.") {
            VStack(alignment: .leading, spacing: Gap.s12) {
                SurfaceSample(label: "surface() — layer + borderSubtle") {
                    SampleBlock().surface()
                }
                SurfaceSample(label: "surface(Ink.layerAlt, border: nil)") {
                    SampleBlock().surface(Ink.layerAlt, border: nil)
                }
                SurfaceSample(label: "hairline() over the page background") {
                    SampleBlock().hairline()
                }
                SurfaceSample(label: "surface(Ink.layerAlt) + overlayShadow()") {
                    SampleBlock().surface(Ink.layerAlt).overlayShadow()
                }
                SurfaceSample(label: "focus — borderFocus at 1pt") {
                    SampleBlock().hairline(Ink.borderFocus, radius: Corner.field)
                }
            }
        }
    }
}

private struct SampleBlock: View {
    var body: some View {
        Text("Corner.card · Elevation.hairline")
            .typeface(Register.monoMicro, Ink.textSecondary)
            .padding(Metrics.cardPaddingCompact)
            .frame(maxWidth: .infinity, minHeight: Density.action, alignment: .leading)
    }
}

private struct SurfaceSample<Content: View>: View {
    let label: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text(label).typeface(Register.monoMicro, Ink.textHelper)
            content()
        }
        .padding(.bottom, Gap.s4)
    }
}

/// `borderSubtle` and `layerAlt` resolve to the same ramp step in dark, so a card stacked on
/// `layerAlt` has a border that is not merely low-contrast but literally invisible. Measured here
/// rather than asserted in prose.
private struct BorderVisibilityCard: View {
    let appearance: GalleryAppearance

    private static let combinations: [(String, Tone, Tone)] = [
        ("borderSubtle on background", Ink.borderSubtle, Ink.background),
        ("borderSubtle on layer", Ink.borderSubtle, Ink.layer),
        ("borderSubtle on layerAlt", Ink.borderSubtle, Ink.layerAlt),
        ("borderStrong on background", Ink.borderStrong, Ink.background),
        ("borderStrong on layer", Ink.borderStrong, Ink.layer),
        ("borderStrong on layerAlt", Ink.borderStrong, Ink.layerAlt),
    ]

    var body: some View {
        GalleryCard(title: "Is the border there at all?",
                    note: "1.00:1 means the two tokens resolve to the same colour. That is a drawing bug before it is a WCAG one.") {
            VStack(alignment: .leading, spacing: Gap.s2) {
                ForEach(Self.combinations, id: \.0) { entry in
                    BorderRow(label: entry.0, border: entry.1, surface: entry.2, appearance: appearance)
                }
            }
        }
    }
}

private struct BorderRow: View {
    let label: String
    let border: Tone
    let surface: Tone
    let appearance: GalleryAppearance

    private var ratio: Double {
        Wcag.ratio(border.resolved(for: appearance.resolved), surface.resolved(for: appearance.resolved))
    }

    var body: some View {
        HStack(spacing: Gap.s8) {
            BorderSwatch(border: border, surface: surface)
            Text(label).typeface(Register.monoMicro, Ink.textPrimary)
            Spacer(minLength: Gap.s8)
            RatioBadge(ratio: ratio, required: Wcag.largeOrUI)
        }
        .frame(minHeight: Density.pill)
    }
}

private struct BorderSwatch: View {
    let border: Tone
    let surface: Tone

    var body: some View {
        Corner.shape(Specimen.corner)
            .fill(surface)
            .frame(width: Specimen.tileWidth, height: Specimen.chipHeight)
            .hairline(border, radius: Specimen.corner)
    }
}

private struct StaleTextureCard: View {
    var body: some View {
        GalleryCard(title: "Stale — texture, not alarm",
                    note: "A value computed against an index that has since moved. Normal for a minute after every ingest, so it must not read as a warning.") {
            VStack(alignment: .leading, spacing: Gap.s12) {
                StaleSample(label: "fresh", stale: false)
                StaleSample(label: "stale", stale: true)
            }
        }
    }
}

private struct StaleSample: View {
    let label: String
    let stale: Bool

    var body: some View {
        HStack(spacing: Gap.s12) {
            Text(label).typeface(Register.caption, Ink.textHelper)
            StaleValue(stale: stale)
        }
    }
}

private struct StaleValue: View {
    let stale: Bool

    var body: some View {
        if stale {
            Text("1 284 passages").typeface(Register.mono, Ink.textPrimary).staleUnderline()
        } else {
            Text("1 284 passages").typeface(Register.mono, Ink.textPrimary)
        }
    }
}

/// Motion is the one part of the system that cannot be reviewed from a still. The toggle drives
/// every curve at once so they are compared against each other rather than remembered.
private struct MotionCard: View {
    @State private var moved = false

    var body: some View {
        GalleryCard(title: "Motion",
                    note: "Named by intent, not duration. Tap to run all four against each other.") {
            VStack(alignment: .leading, spacing: Gap.s8) {
                MotionTrack(name: "hover", animation: Motion.hover, moved: moved)
                MotionTrack(name: "state", animation: Motion.state, moved: moved)
                MotionTrack(name: "drawer", animation: Motion.drawer, moved: moved)
                MotionTrack(name: "meter", animation: Motion.meter, moved: moved)
                MotionTrigger(moved: $moved)
            }
        }
    }
}

private struct MotionTrack: View {
    let name: String
    let animation: Animation
    let moved: Bool

    var body: some View {
        HStack(spacing: Gap.s8) {
            Text(name).typeface(Register.monoMicro, Ink.textHelper)
                .frame(width: Specimen.curveColumn, alignment: .leading)
            Corner.shape(Specimen.corner).fill(Ink.interactive)
                .frame(width: Specimen.markWidth, height: Specimen.markHeight)
                .frame(maxWidth: .infinity, alignment: moved ? .trailing : .leading)
                .animation(animation, value: moved)
        }
        .frame(minHeight: Density.pill)
    }
}

private struct MotionTrigger: View {
    @Binding var moved: Bool

    var body: some View {
        Button("Run") { moved.toggle() }
            .buttonStyle(.plain)
            .typeface(Register.uiEmphasis, Ink.onInteractive)
            .controlBox(Density.action)
            .background(Ink.interactive, in: Corner.controlShape)
    }
}
