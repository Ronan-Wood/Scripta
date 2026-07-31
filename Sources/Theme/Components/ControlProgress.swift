import SwiftUI

// MARK: - Record & Register: progress
//
// DETERMINATE IS THE DEFAULT. The operation this exists for — ingesting a 600-page textbook —
// runs for minutes, and a spinner running for minutes is indistinguishable from a hang. `value`
// is non-optional at the call site that matters; `nil` is for work whose extent genuinely cannot
// be measured, and it costs the reader the one thing they wanted to know.
//
// MONOCHROME, AND NOT CONFIGURABLY SO. Both types took a `tone` that defaulted to
// `Ink.interactive`, which is rule 2 backwards: a progress bar reports machine-measured work state,
// which is CONTENT MEANING, and you cannot click a progress bar. The parameter is gone rather than
// redefaulted — a default is a suggestion and the next call site is free to pass blue back in.
// `EngineTierMeter` already draws its measured fraction in `textPrimary` on `borderSubtle`; this is
// the same reading and now the same tokens. A meter that ever needs to mark a DEVIATION gets a
// named case here, the way `SpineBadge.Prominence` does it, not a free `Tone`.

/// A labelled progress bar. Pass `value` in 0...1, or `nil` for indeterminate.
///
/// `detail` is the mono register — "412 / 640 pages" is machine-measured fact, and putting it in
/// mono is what stops a count from reading like prose.
struct ProgressTrack: View {
    var value: Double?
    var label: String? = nil
    var detail: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s6) {
            if label != nil || detail != nil || value != nil {
                ProgressCaption(value: value, label: label, detail: detail)
            }
            bar
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private var bar: some View {
        if let value {
            DeterminateBar(value: value)
        } else {
            // The system's own indeterminate bar. Hand-rolling one needs a repeat duration, and
            // `Motion` has no repeating token — inventing a number here to avoid one control is
            // the trade this system exists to refuse.
            ProgressView()
                .progressViewStyle(.linear)
                .tint(Ink.textPrimary.color)
        }
    }
}

/// Inline activity for work that finishes in a beat. Anything a user could sit through takes
/// `ProgressTrack` with a value.
///
/// `textSecondary` and not `textPrimary`: a spinner is an activity mark beside something, where the
/// determinate bar IS the fact being reported. Both are neutrals, which is the part that matters.
struct Spinner: View {
    var body: some View {
        ProgressView()
            .progressViewStyle(.circular)
            .controlSize(.small)
            .tint(Ink.textSecondary.color)
    }
}

// MARK: - Parts

private struct ProgressCaption: View {
    let value: Double?
    let label: String?
    let detail: String?

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Gap.s8) {
            if let label { Text(label).typeface(Register.ui, Ink.textPrimary) }
            Spacer(minLength: Gap.s8)
            if let detail { Text(detail).typeface(Register.mono, Ink.textSecondary) }
            if let value { Text(percent(value)).typeface(Register.mono, Ink.textSecondary) }
        }
    }

    private func percent(_ value: Double) -> String {
        String(format: "%.0f%%", min(max(value, 0), 1) * 100)
    }
}

private struct DeterminateBar: View {
    let value: Double

    /// FLAGGED: `Metrics` has no meter thickness, so the bar reads `Gap.s6`. It is a token value
    /// and the name is the number, but a `Density.meter` would say what it means.
    var body: some View {
        GeometryReader { geo in
            Capsule().fill(Ink.textPrimary).frame(width: geo.size.width * fraction)
        }
        .frame(height: Gap.s6)
        .background(Ink.layerSelected, in: Capsule())
        .animation(Motion.meter, value: value)
    }

    private var fraction: Double { min(max(value, 0), 1) }
}
