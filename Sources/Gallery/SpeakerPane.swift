import AppKit
import SwiftUI

/// The speaker ramp and the claim it rests on: that amber/violet sit on the blue–orange axis
/// dichromats keep. The simulation strip is here so the claim is looked at rather than believed.
struct SpeakerPane: View {
    let appearance: GalleryAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s16) {
            SpeakerPairingCard()
            SpeakerTranscriptCard()
            SpokenLineStatesCard()
            DichromacyCard(appearance: appearance)
            SeparationCard(appearance: appearance)
        }
    }
}

enum SpeakerCatalog {
    struct Party: Identifiable {
        let name: String
        let ink: Tone
        let wash: Tone
        var id: String { name }
    }

    /// The four coloured parties, in the order `Ink.speaker.alt(_:)` hands them out.
    static let alt: [Party] = [
        Party(name: "amber", ink: Ink.speaker.amber, wash: Ink.speaker.amberSoft),
        Party(name: "violet", ink: Ink.speaker.violet, wash: Ink.speaker.violetSoft),
        Party(name: "teal", ink: Ink.speaker.teal, wash: Ink.speaker.tealSoft),
        Party(name: "rose", ink: Ink.speaker.rose, wash: Ink.speaker.roseSoft),
    ]

    /// The distance below which two categorical colours stop reading as different colours at a
    /// glance. Fixed at 15 before any number was computed — a threshold chosen after seeing the
    /// results is not a threshold.
    static let separationFloor: Double = 15
}

private struct SpeakerPairingCard: View {
    var body: some View {
        Card(title: "The pairing rule",
             note: "`me` is neutral ink carrying identity in weight. Colour is spent on the other party, so a two-person transcript spends exactly one.") {
            VStack(alignment: .leading, spacing: Gap.s8) {
                HStack(spacing: Gap.s12) {
                    Text("Ronan").typeface(Register.uiEmphasis, Ink.speaker.me)
                    Text("me · uiEmphasis, no hue").typeface(Register.monoMicro, Ink.textHelper)
                }
                ForEach(Array(SpeakerCatalog.alt.enumerated()), id: \.element.id) { index, party in
                    AltPartyRow(index: index, party: party)
                }
            }
        }
    }
}

private struct AltPartyRow: View {
    let index: Int
    let party: SpeakerCatalog.Party

    var body: some View {
        HStack(spacing: Gap.s12) {
            Text("Speaker \(index + 2)").typeface(Register.ui, party.ink)
            Text("alt(\(index)) · \(party.name)").typeface(Register.monoMicro, Ink.textHelper)
        }
    }
}

/// Rule 3 at the row level: a default transcript is monochrome except for the one coloured party.
///
/// This card used to draw a private `TranscriptLine` that stacked the name and stamp above the
/// prose in `Register.monoMicro` — a row the product has never shipped, in the one surface whose
/// job is proving the ramp works. It draws the real `SpokenLine` now, so what is reviewed here is
/// what the reader renders, down to the gutter widths.
private struct SpeakerTranscriptCard: View {
    var body: some View {
        Card(title: "Two parties, one colour",
             note: "The common case. Everything that is not the other speaker's name is ink.") {
            VStack(alignment: .leading, spacing: Gap.s2) {
                SpokenLine(stamp: "[00:14:07]", speaker: "You", mark: .me,
                           text: "We should ship the contrast gate before any component.")
                SpokenLine(stamp: "[00:14:19]", speaker: "Priya", mark: .party(0),
                           text: "Agreed — a component built on a token that fails is work done twice.")
            }
        }
    }
}

/// Every state the row has, because the one that was never reviewable is the one that broke: a
/// highlighted line put the stamp on a blue wash, and `SpokenLine` lived in an app view where no
/// gate and no specimen could see it. It is the last row here, at the size and gutter the reader
/// draws it.
private struct SpokenLineStatesCard: View {
    var body: some View {
        Card(title: "Every state of the row",
             note: "Self, the four ramp slots, a continuation turn with no label, and the search hit.") {
            VStack(alignment: .leading, spacing: Gap.s2) {
                SpokenLine(stamp: "[00:02:11]", speaker: "You", mark: .me,
                           text: "Neutral ink; the weight is the whole signal.")
                ForEach(Array(SpeakerCatalog.alt.enumerated()), id: \.element.id) { slot, party in
                    SpokenLine(stamp: "[00:02:2\(slot)]", speaker: "Sp\(slot + 2)",
                               mark: .party(slot),
                               text: "Slot \(slot) — Ink.speaker.\(party.name), at Register.ui.")
                }
                SpokenLine(stamp: "[00:02:31]",
                           text: "A continuation turn: a stamp, no label, and the prose column starts where every other row's does.")
                SpokenLine(stamp: "[00:02:44]", speaker: "Priya", mark: .party(1),
                           text: "The search hit. The stamp is textSecondary — textHelper on this wash is forbidden, not merely unmeasured.",
                           highlighted: true)
            }
        }
    }
}

private struct DichromacyCard: View {
    let appearance: GalleryAppearance

    var body: some View {
        Card(title: "Simulated dichromacy",
             note: "Viénot–Brettel–Mollon on this appearance's four speaker inks. Read the amber/violet columns first — they are the pair the direction claims.") {
            VStack(alignment: .leading, spacing: Gap.s10) {
                SimulationStrip(kind: nil, appearance: appearance)
                ForEach(Dichromacy.allCases) { kind in
                    SimulationStrip(kind: kind, appearance: appearance)
                }
            }
        }
    }
}

private struct SimulationStrip: View {
    let kind: Dichromacy?
    let appearance: GalleryAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            Text(kind?.rawValue ?? "normal trichromat").microLabel(Ink.textHelper)
            HStack(spacing: Gap.s6) {
                ForEach(SpeakerCatalog.alt) { party in
                    SimulatedSwatch(party: party, kind: kind, appearance: appearance)
                }
            }
        }
    }
}

private struct SimulatedSwatch: View {
    let party: SpeakerCatalog.Party
    let kind: Dichromacy?
    let appearance: GalleryAppearance

    private var shown: NSColor {
        let base = party.ink.resolved(for: appearance.resolved)
        return kind.map { VisionSim.simulate(base, $0) } ?? base
    }

    var body: some View {
        VStack(spacing: Gap.s2) {
            Rectangle()
                .fill(Color(nsColor: shown))
                .frame(height: Specimen.bandHeight)
            Text(party.name).typeface(Register.monoMicro, Ink.textHelper)
        }
        .frame(maxWidth: .infinity)
    }
}

/// The number behind the claim. Contrast ratio says "can it be read"; ΔE2000 says "is it the same
/// colour as its neighbour", which is the only question a categorical ramp asks.
private struct SeparationCard: View {
    let appearance: GalleryAppearance

    var body: some View {
        Card(title: "Mutual separation (ΔE2000)",
             note: "Floor of 15, fixed before measuring. Below it, two parties stop reading as different colours at a glance.") {
            VStack(alignment: .leading, spacing: Gap.s12) {
                ForEach(Dichromacy.allCases) { kind in
                    SeparationBlock(kind: kind, appearance: appearance)
                }
            }
        }
    }
}

private struct SeparationBlock: View {
    let kind: Dichromacy
    let appearance: GalleryAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s2) {
            Text(kind.rawValue).microLabel(Ink.textHelper)
            ForEach(pairs, id: \.label) { entry in
                SeparationRow(label: entry.label, delta: entry.delta)
            }
        }
    }

    private var pairs: [(label: String, delta: Double)] {
        let parties = SpeakerCatalog.alt
        var out: [(String, Double)] = []
        for i in parties.indices {
            for j in parties.indices where j > i {
                let a = VisionSim.simulate(parties[i].ink.resolved(for: appearance.resolved), kind)
                let b = VisionSim.simulate(parties[j].ink.resolved(for: appearance.resolved), kind)
                out.append(("\(parties[i].name) / \(parties[j].name)", Perceptual.deltaE2000(a, b)))
            }
        }
        return out
    }
}

private struct SeparationRow: View {
    let label: String
    let delta: Double

    private var passes: Bool { delta >= SpeakerCatalog.separationFloor }

    var body: some View {
        HStack(spacing: Gap.s8) {
            Text(label).typeface(Register.monoMicro, Ink.textPrimary)
            Spacer(minLength: Gap.s8)
            Text(String(format: "ΔE %.1f", delta)).typeface(Register.monoMicro, Ink.textSecondary)
            Text(passes ? "DISTINCT" : "COLLAPSED")
                .typeface(Register.monoMicro, passes ? Ink.textSecondary : Ink.danger)
        }
        .frame(minHeight: Density.pill)
    }
}
