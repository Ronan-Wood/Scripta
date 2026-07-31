import Foundation
import SwiftUI

// MARK: - Record & Register: the capability envelope
//
// Which tier answered, what it is measured to be worth, and what departed from the default —
// without nagging, and without ever inventing a number.
//
// Layout is three bands, and the band a reader sees is the band that has something to say:
//
//   1. SCOPE + TIER   always. The scope segment is permanently `interactive` (the one exemption
//                     rule 3 grants) and the tier is a meter against the measured ceiling.
//   2. ARMS           always, monochrome. `ran` shows the model, which is what makes an
//                     Apple-tier answer visibly different from a full-stack one.
//   3. COMMENTARY     only when a fault, an absence, or the honest price has something to say.
//                     A healthy full-stack query renders bands 1 and 2 and stops.
//
// The upgrade carries NO call to action, deliberately. A button in an answer surface is what turns
// a measured fact into an upsell; the fact is stated at its measured price and the place to act on
// it is Settings, where the user went looking. The free tier is 85% of the ceiling and the meter
// says so before the price is ever mentioned.

struct EngineBar: View {
    let envelope: EngineEnvelope
    var selectScope: () -> Void = {}

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s8) {
            EngineTopLine(envelope: envelope, selectScope: selectScope)
            EngineArmsRow(arms: envelope.arms)
            if envelope.hasCommentary { EngineNoteStack(envelope: envelope) }
        }
        .padding(Metrics.cardPaddingCompact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Ink.layer)
    }
}

// MARK: - Band 1: scope and tier

private struct EngineTopLine: View {
    let envelope: EngineEnvelope
    let selectScope: () -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Gap.s12) {
            EngineScopeSegment(scope: envelope.scope, select: selectScope)
            EngineTierMeter(mrr: envelope.expectedMRR, cohort: envelope.cohort)
            Spacer(minLength: Gap.s8)
        }
        .frame(minHeight: Density.pill)
    }
}

/// The one thing that is never silent. Under rule 3 a healthy engine says nothing, which spends the
/// whole discoverability budget here: this segment is what tells a first-time reader that the
/// answer came from a NAMED corpus which could have been a different one. It carries `interactive`
/// permanently because it is genuinely a control, not because it wants attention.
struct EngineScopeSegment: View {
    let scope: EngineScope
    var select: () -> Void = {}

    var body: some View {
        Pressable(action: select) { EngineScopeLabel(scope: scope) }
    }
}

private struct EngineScopeLabel: View {
    let scope: EngineScope

    /// THE FILL DOES NOT MOVE ON HOVER, and that is measured rather than preferred. `interactive`
    /// on `interactiveSubtle` is 4.59:1 in light — the label clears the 4.5 an 11pt word needs by
    /// nine hundredths — so every blue wash a step deeper than the resting one buys a hover by
    /// spending the anchor's legibility. The edge is where the budget is, so the edge is what moves:
    /// the resting 40% hairline goes to full `interactive` under the pointer. `ControlSkin` supplies
    /// the pressed alpha and the focus ring on top of it.
    ///
    /// Disabled drops to `layer` and `borderSubtle` — the one phase where the exemption is not spent,
    /// because a segment that cannot be selected is not an affordance to advertise.
    private static let palette = ControlPalette(idle: Ink.interactiveSubtle,
                                                hover: Ink.interactiveSubtle,
                                                pressed: Ink.interactiveSubtle,
                                                disabledFill: Ink.layer,
                                                label: Ink.interactive,
                                                border: Ink.interactive.opacity(0.4),
                                                hoverBorder: Ink.interactive,
                                                disabledBorder: Ink.borderSubtle)

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.forcedControlPhase) private var forced
    @Environment(\.controlPressed) private var pressed
    @Environment(\.controlFocused) private var focused
    @State private var hovering = false

    private var phase: ControlPhase {
        ControlPhase.resolve(forced: forced, enabled: isEnabled,
                             pressed: pressed, hovering: hovering, focused: focused)
    }

    var body: some View {
        EngineScopePair(name: scope.name, tone: Self.palette.foreground(phase))
            .modifier(ControlSkin(palette: Self.palette, phase: phase,
                                  minHeight: Density.pill,
                                  horizontal: Gap.s10, vertical: Gap.s2))
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: phase)
    }
}

private struct EngineScopePair: View {
    let name: String
    /// From `ControlPalette.foreground(_:)`, not spelled here. Both halves take the same tone, so a
    /// disabled segment goes quiet as one thing rather than half-blue.
    let tone: Tone

    /// No empty-string guard here, and that is the point: `EngineScope` cannot hold one, so this
    /// view has nothing left to check. A guard here would have been a second place to forget.
    var body: some View {
        HStack(spacing: Gap.s6) {
            // Rule 1's name/value split: "scope" is the field, UI. The token beside it is what the
            // engine returned and what you would type to ask for it again, so it is mono.
            Text("scope").microLabel(tone)
            Text(name).typeface(Register.mono, tone)
        }
    }
}

/// A measured tier drawn against the measured ceiling, so 0.593 and 0.698 differ by LENGTH before
/// they differ by a decimal place — and so the floor reads as "most of the way there" rather than
/// as "not full", which is the difference between an honest readout and a nag.
struct EngineTierMeter: View {
    let mrr: Double?
    let cohort: String

    var body: some View {
        HStack(alignment: .center, spacing: Gap.s8) {
            EngineMeterTrack(mrr: mrr)
            EngineTierValue(mrr: mrr, cohort: cohort)
        }
    }
}

private struct EngineMeterTrack: View {
    let mrr: Double?

    var body: some View {
        if let mrr {
            EngineMeterFill(fraction: EngineTier.fractionOfCeiling(mrr))
        } else {
            // Absence keeps the SLOT and draws it dotted. An empty solid track is a zero-length
            // fill, and a zero-length fill is a number — the exact fabrication this refuses.
            // `offset: 0` because the token's default clears text descenders and there is no text.
            Color.clear
                .frame(width: Gap.s56, height: Gap.s4)
                .staleUnderline(Ink.stale, offset: 0)
        }
    }
}

private struct EngineMeterFill: View {
    let fraction: Double

    var body: some View {
        Corner.shape(Gap.s2)
            .fill(Ink.borderSubtle)
            .frame(width: Gap.s56, height: Gap.s4)
            .overlay(alignment: .leading) {
                Corner.shape(Gap.s2)
                    .fill(Ink.textPrimary)
                    .frame(width: Gap.s56 * CGFloat(fraction), height: Gap.s4)
            }
    }
}

private struct EngineTierValue: View {
    let mrr: Double?
    let cohort: String

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Gap.s6) {
            Text(value).typeface(Register.mono, mrr == nil ? Ink.stale : Ink.textPrimary)
            Text(caption).typeface(Register.monoMicro, Ink.textHelper)
        }
    }

    /// The word, not a dash. "—" is read as zero, "n/a" is read as broken; "unmeasured" is the
    /// only one of the three that says what actually happened.
    private var value: String {
        guard let mrr else { return "unmeasured" }
        return String(format: "%.3f", mrr)
    }

    private var caption: String {
        guard let mrr else { return "no measured tier" }
        let percent = EngineTier.percentOfCeiling(mrr)
        return percent >= 100 ? "measured ceiling · \(cohort)" : "\(percent)% of ceiling · \(cohort)"
    }
}

// MARK: - Band 2: the arms

struct EngineArmsRow: View {
    let arms: [EngineArm]

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Gap.s12) {
            ForEach(arms) { EngineArmChip(arm: $0) }
            Spacer()
        }
    }
}

/// `embed` / `hyde` / `rank` are FIELD NAMES and take the UI register; the model id or state word
/// beside each one is what the engine put in that field and stays mono. That is rule 1's name/value
/// split, and this row is where it was being read the other way — the arm name was mono because it
/// looked like engine vocabulary, which is true of both halves and decides nothing.
private struct EngineArmChip: View {
    let arm: EngineArm

    var body: some View {
        HStack(spacing: Gap.s4) {
            Text(arm.label).microLabel(Ink.textHelper)
            Text(arm.detail).typeface(Register.monoMicro, arm.state.tone)
        }
    }
}

// MARK: - Band 3: commentary

/// Column the markers share, composed from tokens rather than eyeballed. Measured, not estimated:
/// laid out in the bundled IBMPlexSans-Medium at `Register.micro` (11pt) with
/// `Register.microTracking` and uppercased, the widest markers are `ENGINE DOWN` at 81.4pt and
/// `UNMEASURED` at 77.5pt. 80 clipped the widest one — `minWidth` does not truncate, so the row
/// simply pushed its prose out of the column every other row keeps. 88 clears it by 6.6.
///
/// Shared with `ExclusionBar`, which stacks directly beneath this one — the two are one family and
/// a marker column that only lined up within a single component would be worse than none.
enum EnvelopeMarker {
    static let column: CGFloat = Gap.s56 + Gap.s32
    /// Hanging indent for a line that continues under the marker column, spacing included.
    static let indent: CGFloat = column + Gap.s8
}

/// The marker column, drawn once. Everything that occupies it is a FIELD NAME — `unavailable`,
/// `frozen`, `full stack`, `withheld` — so it is the UI register by rule 1's name/value split, and
/// having one renderer is what keeps that decision from being re-made per row. Three call sites
/// spelled the same two modifiers before this existed, in two files that stack directly on top of
/// each other and therefore have to agree to the point.
struct EnvelopeMarkerLabel: View {
    let name: String
    var tone: Tone = Ink.textHelper

    var body: some View {
        Text(name)
            .microLabel(tone)
            .frame(minWidth: EnvelopeMarker.column, alignment: .leading)
    }
}

private struct EngineNoteStack: View {
    let envelope: EngineEnvelope

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s6) {
            ForEach(envelope.notes) { EngineNoteRow(note: $0) }
            if let upgrade = envelope.upgrade { EngineUpgradeRow(upgrade: upgrade) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EngineNoteRow: View {
    let note: EngineNote

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Gap.s8) {
            EngineNoteMarker(note: note)
            Text(note.text).proseText(Register.proseSm, Ink.textSecondary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct EngineNoteMarker: View {
    let note: EngineNote

    var body: some View {
        if note.dotted {
            // Dotted marker = we have no basis for a verdict. Texture rather than hue, so an
            // unknown never shouts louder than a measured fault sitting above it.
            EnvelopeMarkerLabel(name: note.marker, tone: note.tone).staleUnderline(note.tone)
        } else {
            EnvelopeMarkerLabel(name: note.marker, tone: note.tone)
        }
    }
}

/// The price of the rest of the ceiling, in the units it was measured in. Monochrome by rule 3 —
/// a configuration that is 85% of the best measured stack is not a deviation, and colouring it
/// would say it was.
private struct EngineUpgradeRow: View {
    let upgrade: EngineUpgrade

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s2) {
            EngineUpgradePrice(upgrade: upgrade)
            Text(phrase)
                .proseText(Register.proseSm, Ink.textHelper)
                .padding(.leading, EnvelopeMarker.indent)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// "Sharper ranking on hard queries" — what the measurement actually showed. Not "unlock real
    /// search": the tier below it answers 85% of the same cases, and copy that implies otherwise
    /// is false about our own numbers before it is manipulative.
    private var phrase: String {
        let claim = "Sharper ranking on hard queries."
        guard let lead = upgrade.lead else { return claim }
        return "\(lead) \(claim)"
    }
}

private struct EngineUpgradePrice: View {
    let upgrade: EngineUpgrade

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Gap.s8) {
            EnvelopeMarkerLabel(name: "full stack")
            Text(price).typeface(Register.monoMicro, Ink.textSecondary)
            Spacer(minLength: Gap.s4)
        }
    }

    private var price: String {
        String(format: "+%.3f mrr · about %.1f of %d cases",
               upgrade.delta, upgrade.cases, upgrade.caseCount)
    }
}
