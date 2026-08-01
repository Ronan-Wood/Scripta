import SwiftUI

// MARK: - Record & Register: a stamped, attributed line of speech
//
// The most-repeated row in the product, and until now the one row the system had no component for.
// `Passage` renders substrate retrieval and `ListRow` is a title/subtitle pair; neither is close, so
// the reader's migration built this locally in the view — while `SpeakerPane` carried a private
// `TranscriptLine` doing the same job in a DIFFERENT layout. The pane whose whole purpose is proving
// the speaker ramp works was demonstrating a row the product does not draw.
//
// One component, one layout, drawn by both. What the gallery shows is now what ships.
//
// WHY THE THREE-COLUMN FORM WON. It is the one that shipped, but that is evidence rather than the
// argument. The argument is that this row is where rule 1 becomes visible: a MONO stamp (the machine
// measured it), a UI name (chrome), and PROSE words (a person said them) on ONE baseline. Stacking
// the stamp above the prose — the gallery's form — turns the first two registers into a caption over
// a paragraph, which is a shape the system already has in `ListRow`. It also demotes the stamp to
// `Register.monoMicro`, and an 11pt mono label is exactly the size that pushed the gallery toward
// `Ink.textHelper` and off the wash below.

/// The reader's two fixed columns. WIDTHS, not heights: `Density`'s minimum rule is about content
/// that can grow, and these exist precisely so it cannot — every line of speech has to start on the
/// same left edge or the prose column reads as ragged.
///
/// `Metrics` has no column token, so both are measured rather than guessed. Plex Mono's advance is
/// 0.6em, so the widest stamp `TranscriptWriter` emits — "[1:02:33]", nine characters of
/// `Register.mono` at 12 — is 64.8pt.
enum ReaderGutter {
    static let stamp: CGFloat = 66
    /// "Them" / "Note" at `Register.uiEmphasis`, with room for a longer label than the writer
    /// emits today.
    static let speaker: CGFloat = 44
}

/// Who is speaking, expressed as the pairing rule rather than as a colour.
///
/// The rule is "weight for the self party, hue for everyone else, never both on one name", and this
/// is what makes breaking it unrepresentable: a tone and an emphasis flag as two parameters can
/// disagree, a case cannot. It also keeps an arbitrary `Tone` out of a speaker name — a component
/// that accepted one would permit `Ink.interactive` on a person, which is rule 2's failure mode.
enum SpeakerMark: Equatable {
    /// Neutral ink, identity carried entirely by WEIGHT. Callers in another medium pick their own
    /// emphasis face from this — `Register.uiEmphasis` on screen, Plex Sans Medium in print —
    /// because the two size type differently but must not disagree about who is neutral.
    case me
    /// A coloured party by ramp slot. Wraps past four, matching `Ink.speaker.alt(_:)` and
    /// `PillStyle.speaker(_:)`: a fifth non-self party is a rendering problem, not a crash.
    case party(Int)

    var tone: Tone {
        switch self {
        case .me: return Ink.speaker.me
        case .party(let slot): return Ink.speaker.alt(slot)
        }
    }

    var face: Typeface {
        self == .me ? Register.uiEmphasis : Register.ui
    }
}

/// One spoken turn, and the only place in the app where all three registers sit on one line.
///
/// The highlight wash is `interactiveSoft` — rule 2's sanctioned blue, because "the line you
/// searched for" is selection state and not a property of what was said. It is painted without
/// changing the row's padding, so a flash does not nudge every line beneath it sideways mid-scroll.
struct SpokenLine: View {
    let stamp: String
    /// Absent on a continuation turn, where the writer emits a stamp and no label.
    var speaker: String? = nil
    var mark: SpeakerMark = .me
    let text: String
    /// The search hit or citation this reader was scrolled to.
    var highlighted: Bool = false

    var body: some View {
        HStack(alignment: .firstTextBaseline, spacing: Gap.s8) {
            // `textSecondary`, NOT `textHelper`. When this row is the search hit it sits on the
            // `interactiveSoft` wash, where `textHelper` measures 4.11:1 / 3.77:1 light and
            // 4.16:1 / 3.46:1 dark against the 4.5 a 12pt label needs — so the timestamp on the one
            // line the reader just searched for would be the least legible thing on screen. That
            // pairing is now forbidden in `ForbiddenInk` rather than argued for here, which is the
            // whole reason this row is a component and not a private struct in an app view.
            Text(stamp)
                .typeface(Register.mono, Ink.textSecondary)
                .frame(width: ReaderGutter.stamp, alignment: .trailing)
            if let speaker {
                Text(speaker)
                    .typeface(mark.face, mark.tone)
                    .frame(width: ReaderGutter.speaker, alignment: .leading)
            }
            Text(text)
                .proseText(Register.prose, Ink.textPrimary)
                .frame(maxWidth: Metrics.proseMaxWidth, alignment: .leading)
        }
        .padding(.vertical, Gap.s4)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(highlighted ? Ink.interactiveSoft : .clear, radius: Corner.control, border: nil)
    }
}
