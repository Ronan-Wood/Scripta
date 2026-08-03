import Foundation
import SwiftUI

// MARK: - Record & Register: what this result set left out
//
// Default retrieval withholds conversation-class sources, archived notes and superseded notes. All
// three are correct defaults and none of them may be silent, because the failure they cause is not
// a bad result — it is a CONFIDENT WRONG CONCLUSION. A reader who does not know a class was held
// back reads its absence as proof it does not exist, and then stops looking.
//
// This is the UI face of the CLI's `status filter: active,complete · sources excluded`, and it
// makes one addition the CLI cannot: the control that includes them. A disclosure the reader cannot
// act on just relocates the dead end.
//
// Rule 3 lands on the unusual side here. The DEFAULT (withholding) is monochrome, because
// withholding is the default and colour marks deviation. The DEVIATION is including — a result set
// carrying superseded or archived notes contains content the vault has moved past, and that is
// exactly what `Ink.stale` marks. So the bar gets quieter as it withholds more, and speaks up when
// the reader has opened it out.

// `ExclusionFilter` — the set this bar reads, the chips it draws and the two sentences beneath them
// — is in `SubstrateKit` (Core/Sources/SubstrateKit/ExclusionFilter.swift). It is `RetrievalClass`
// arithmetic over what the engine's `filters` block reported and holds nothing this layer decides,
// so a second renderer of the same disclosure cannot compute a different one. The chips show the
// engine's tokens verbatim; the prose line beneath translates them, so the token is never softened.

struct ExclusionBar: View {
    let filter: ExclusionFilter
    var toggle: (RetrievalClass) -> Void = { _ in }

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s8) {
            ExclusionChipRows(filter: filter, toggle: toggle)
            ExclusionExplanation(filter: filter)
            if !filter.notes.isEmpty { ExclusionNotes(notes: filter.notes) }
        }
        .padding(Metrics.cardPaddingCompact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Ink.layer)
    }
}

/// Two groups, stacked rather than side by side: at four classes plus two labels a single row runs
/// past a sidebar-width panel, and a filter readout that truncates is a filter readout that hides
/// exactly the class the reader needed to know about.
private struct ExclusionChipRows: View {
    let filter: ExclusionFilter
    let toggle: (RetrievalClass) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s6) {
            if !filter.withheld.isEmpty {
                ExclusionGroup(label: "withheld", classes: filter.withheld,
                               included: false, toggle: toggle)
            }
            if !filter.included.isEmpty {
                ExclusionGroup(label: "including", classes: filter.included,
                               included: true, toggle: toggle)
            }
        }
    }
}

private struct ExclusionGroup: View {
    let label: String
    let classes: [RetrievalClass]
    let included: Bool
    let toggle: (RetrievalClass) -> Void

    var body: some View {
        HStack(alignment: .center, spacing: Gap.s8) {
            EnvelopeMarkerLabel(name: label, tone: included ? Ink.stale : Ink.textHelper)
            ForEach(classes) { klass in
                ExclusionChip(klass: klass, included: included, toggle: toggle)
            }
            Spacer(minLength: Gap.s4)
        }
    }
}

/// The control the CLI cannot offer. Tapping a chip moves it between the two groups, which is why
/// the two groups are the same shape: the reader is watching a class move, not reading two lists.
///
/// A `Pill`, and internal rather than private, because both of those were the defect. It was a bare
/// `Button { … }.buttonStyle(.plain)` around `.controlBox` + `.background` + `.hairline` — which is
/// `ControlSkin`'s body with the PHASE removed. The most-clicked control in the answer surface
/// therefore had no hover fill, no `ControlAlpha.pressed`, no `FocusRing`, and — because
/// `focusEffectDisabled()` lives inside `Pressable` — AppKit's own ring at AppKit's radius over a
/// 7pt pill, the exact "two focus indicators that disagree about the corner radius" `ControlState`
/// forbids. Private is what kept it out of `ControlsPane`, and out of the gallery is what kept all
/// of that unreviewable.
struct ExclusionChip: View {
    let klass: RetrievalClass
    let included: Bool
    let toggle: (RetrievalClass) -> Void

    var body: some View {
        Pill(text: klass.label,
             style: included ? .included : .withheld,
             action: { toggle(klass) })
    }
}

/// The two chip faces. `RetrievalClass.register` decides the face and this is not re-decided here:
/// rule 1's name/value split says a status token is a VALUE and therefore mono, and putting that on
/// the type is what stops a second renderer of the same vocabulary from deciding otherwise.
private extension PillStyle {
    /// The withheld chip carries no fill of its own and is delimited by its BORDER. `layerAlt` over
    /// the bar's `layer` bought nothing and cost twice: in dark both resolve to gray80, so
    /// `borderSubtle` on it was 1.00:1 — not a faint edge, the same colour — and helper text on
    /// layerAlt is a recorded 3.48:1 failure there. On `layer` the text clears 4.5 and
    /// `borderStrong` clears 3:1 in both appearances (3.02 light / 3.01 dark).
    ///
    /// `borderStrong` and not `borderSubtle` because a chip is a CONTROL: the gate's own words for
    /// borderSubtle are "decorative separator between adjacent surfaces, not a control boundary".
    static let withheld = PillStyle(label: Ink.textHelper,
                                    fill: Ink.layer,
                                    hover: Ink.layerHover,
                                    border: Ink.borderStrong,
                                    face: RetrievalClass.register,
                                    horizontal: Gap.s8,
                                    vertical: Gap.s2)

    /// The included chip draws its LABEL in `textPrimary`, not in `stale`. `stale` on `staleSoft`
    /// measured 3.94:1 in light against the 4.5 a 12pt label needs — and the ledger already carried
    /// that row rather than treating it as a defect. The fix is not a new token: it is following the
    /// rule this system already has. `SpineBadge.Prominence.deviation` marks a deviation with a wash
    /// FILL and a mark EDGE and draws its text in `textPrimary`, precisely so the signal never has
    /// to be carried by ink that must also stay legible. The chip was tinting its label instead, and
    /// so had to choose between reading as deviation and being readable. It no longer does: fill and
    /// edge carry "included", the label carries the word.
    ///
    /// Hover is the same wash at a higher alpha rather than a `staleSoftHover` invented here: one
    /// ramp step deeper is what every other hover in the system is, and `Ink` has no such token.
    static let included = PillStyle(label: Ink.textPrimary,
                                    fill: Ink.staleSoft,
                                    hover: Ink.stale.opacity(0.20),
                                    border: Ink.stale,
                                    face: RetrievalClass.register,
                                    horizontal: Gap.s8,
                                    vertical: Gap.s2)
}

private struct ExclusionExplanation: View {
    let filter: ExclusionFilter

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s2) {
            Text(filter.withheldSentence).proseText(Register.proseSm, Ink.textSecondary)
            if let inclusion = filter.inclusionSentence {
                Text(inclusion).proseText(Register.proseSm, Ink.stale)
            }
        }
        .padding(.leading, EnvelopeMarker.indent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct ExclusionNotes: View {
    let notes: [String]

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s2) {
            ForEach(notes, id: \.self) {
                Text($0).typeface(Register.monoMicro, Ink.textHelper)
            }
        }
        .padding(.leading, EnvelopeMarker.indent)
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
