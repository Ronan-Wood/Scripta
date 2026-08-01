import ScriptaCore
import SwiftUI

/// Which speaker ramp slot each party in one transcript holds.
///
/// This replaces the collision the design system was written to end: `CarbonTheme` declared
/// `Carbon.orange` as "Them" while the reader drew that same speaker in SYSTEM `Color.orange` —
/// two different oranges for one concept — and drew the self party in `Color.accentColor`, a blue
/// carrying content meaning. Both are gone. The self party is NEUTRAL ink and its identity is
/// carried entirely by weight (`Register.uiEmphasis`); hue is spent only on the other parties, so
/// the ordinary two-person call spends exactly one colour.
///
/// Slots are handed out in order of first appearance and resolved ONCE per transcript, not per
/// row: a party whose colour depended on which blocks happened to be realized would change hue as
/// a `LazyVStack` scrolled.
struct SpeakerCast {

    /// The labels that are the operator's own side rather than another party.
    ///
    /// `Note:` lines are emitted by `TranscriptWriter` in the same `**[stamp] Label:**` shape as a
    /// speaker turn, but they are typed, not spoken — the operator writing, not a third person in
    /// the room. Spending a ramp colour on one would cost the common You/Them call its "exactly
    /// one colour" property in exchange for marking something that is not a speaker at all. The
    /// word "Note" is always rendered, which is where the distinction lives.
    private static let selfLabels: Set<String> = ["You", "Note"]

    /// Non-self speakers only. A label absent from this map is the self party.
    private let slots: [String: Int]

    init(_ blocks: [TranscriptBlock]) {
        var slots: [String: Int] = [:]
        var next = 0
        for block in blocks {
            guard case let .audioLine(_, speaker?, _) = block,
                  !Self.selfLabels.contains(speaker),
                  slots[speaker] == nil
            else { continue }
            slots[speaker] = next
            next += 1
        }
        self.slots = slots
    }

    /// Slot assignment is all this owns. Which ink and which weight that slot draws in is
    /// `SpeakerMark`'s — the system states the pairing rule once, and both the reader and the PDF
    /// exporter read it from there rather than each spelling out "neutral means weight".
    ///
    /// Optional in, because a continuation turn has a stamp and no label: no name, no mark.
    func mark(for speaker: String?) -> SpeakerMark {
        guard let speaker, let slot = slots[speaker] else { return .me }
        return .party(slot)
    }
}
