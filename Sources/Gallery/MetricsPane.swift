import SwiftUI

/// Spacing, control density, corner radii and measure. Every value here is a number the app
/// currently spells as a literal in ~191 places, so the point of the page is that a reviewer can
/// check a render against it without a lookup table.
struct MetricsPane: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s16) {
            GapScaleCard()
            DensityCard()
            CornerCard()
            MeasureCard()
        }
    }
}

private struct GapScaleCard: View {
    private static let steps: [(String, CGFloat)] = [
        ("s2", Gap.s2), ("s4", Gap.s4), ("s6", Gap.s6), ("s8", Gap.s8),
        ("s10", Gap.s10), ("s12", Gap.s12), ("s16", Gap.s16), ("s20", Gap.s20),
        ("s24", Gap.s24), ("s32", Gap.s32), ("s40", Gap.s40), ("s56", Gap.s56),
    ]

    var body: some View {
        GalleryCard(title: "Gap",
                    note: "The name is the value, so adding a step later cannot renumber the existing ones.") {
            VStack(alignment: .leading, spacing: Gap.s2) {
                ForEach(Self.steps, id: \.0) { step in
                    GapRow(name: step.0, value: step.1)
                }
            }
        }
    }
}

private struct GapRow: View {
    let name: String
    let value: CGFloat

    var body: some View {
        HStack(spacing: Gap.s8) {
            Text(name).typeface(Register.mono, Ink.textPrimary)
                .frame(width: Specimen.nameColumn, alignment: .leading)
            Rectangle().fill(Ink.interactive).frame(width: value, height: Specimen.rulerHeight)
            Spacer(minLength: Gap.s8)
            Text("\(Int(value))").typeface(Register.monoMicro, Ink.textHelper)
        }
        .frame(minHeight: Density.pill)
    }
}

/// Minimums, never fixed heights — the whole point of `Density`. Each sample is shown with a label
/// that wraps, because a fixed height is invisible until something needs to grow.
private struct DensityCard: View {
    var body: some View {
        GalleryCard(title: "Density",
                    note: "Minimums. Sized with padding plus .frame(minHeight:), so a wrapped label grows the control instead of clipping it.") {
            VStack(alignment: .leading, spacing: Gap.s8) {
                DensitySample(name: "pill", height: Density.pill, label: "Draft")
                DensitySample(name: "row", height: Density.row, label: "Weekly review with the platform team")
                DensitySample(name: "action", height: Density.action, label: "Rebuild index")
                DensitySample(name: "row (label that must wrap)", height: Density.row,
                              label: "A label long enough that a fixed height would clip it the moment the window narrows")
            }
        }
    }
}

private struct DensitySample: View {
    let name: String
    let height: CGFloat
    let label: String

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text("\(name) · \(Int(height))").typeface(Register.monoMicro, Ink.textHelper)
            Text(label)
                .typeface(Register.ui, Ink.textPrimary)
                .controlBox(height)
                .surface(Ink.field, radius: Corner.field)
        }
    }
}

private struct CornerCard: View {
    private static let radii: [(String, CGFloat)] = [
        ("control", Corner.control), ("field", Corner.field), ("card", Corner.card),
    ]

    var body: some View {
        GalleryCard(title: "Corner",
                    note: "Always .continuous — mixing it with .circular inside one screen is visible at these radii.") {
            HStack(spacing: Gap.s12) {
                ForEach(Self.radii, id: \.0) { entry in
                    CornerSample(name: entry.0, radius: entry.1)
                }
            }
        }
    }
}

private struct CornerSample: View {
    let name: String
    let radius: CGFloat

    var body: some View {
        VStack(spacing: Gap.s4) {
            Corner.shape(radius)
                .fill(Ink.layerSelected)
                .frame(height: Specimen.shapeHeight)
            Text("\(name) · \(Int(radius))").typeface(Register.monoMicro, Ink.textHelper)
        }
        .frame(maxWidth: .infinity)
    }
}

private struct MeasureCard: View {
    var body: some View {
        GalleryCard(title: "Measure",
                    note: "Prose is capped short because a transcript read at full window width loses the line the eye was on.") {
            VStack(alignment: .leading, spacing: Gap.s12) {
                MeasureSample(name: "proseMaxWidth · 720", width: Metrics.proseMaxWidth)
                MeasureSample(name: "listMaxWidth · 900", width: Metrics.listMaxWidth)
            }
        }
    }
}

private struct MeasureSample: View {
    let name: String
    let width: CGFloat

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text(name).typeface(Register.monoMicro, Ink.textHelper)
            Rectangle()
                .fill(Ink.interactiveSoft)
                .frame(maxWidth: width, minHeight: Gap.s10)
                .hairline(Ink.borderSubtle, radius: Specimen.corner)
        }
    }
}
