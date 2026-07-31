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
        GalleryCard(title: "The pairing rule",
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
private struct SpeakerTranscriptCard: View {
    var body: some View {
        GalleryCard(title: "Two parties, one colour",
                    note: "The common case. Everything that is not the other speaker's name is ink.") {
            VStack(alignment: .leading, spacing: Gap.s10) {
                TranscriptLine(speaker: "Ronan", tone: Ink.speaker.me, emphasised: true,
                               stamp: "00:14:07",
                               line: "We should ship the contrast gate before any component.")
                TranscriptLine(speaker: "Priya", tone: Ink.speaker.amber, emphasised: false,
                               stamp: "00:14:19",
                               line: "Agreed — a component built on a token that fails is work done twice.")
            }
        }
    }
}

private struct TranscriptLine: View {
    let speaker: String
    let tone: Tone
    let emphasised: Bool
    let stamp: String
    let line: String

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s2) {
            HStack(spacing: Gap.s8) {
                Text(speaker).typeface(emphasised ? Register.uiEmphasis : Register.ui, tone)
                Text(stamp).typeface(Register.monoMicro, Ink.textHelper)
            }
            Text(line).proseText(Register.prose, Ink.textPrimary)
        }
    }
}

private struct DichromacyCard: View {
    let appearance: GalleryAppearance

    var body: some View {
        GalleryCard(title: "Simulated dichromacy",
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
        GalleryCard(title: "Mutual separation (ΔE2000)",
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
                .typeface(Register.monoMicro, passes ? Ink.success : Ink.danger)
        }
        .frame(minHeight: Density.pill)
    }
}
