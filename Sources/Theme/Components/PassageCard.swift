import SwiftUI

/// One retrieved passage: spine, snippet, provenance.
///
/// The card divides the four axes between two surfaces, which is what keeps four signals from
/// reading as four alarms:
///
///   THE EDGE answers "should this be on screen at all". Only corpus membership moves it, so a
///   `stale` edge in a result list means exactly one thing — you asked for a class default
///   retrieval withholds and here is one. Measured 4.56:1 against the card fill in light and
///   6.37:1 in dark; `Ink.borderSubtle` at 1.20:1 is the default it replaces.
///
///   THE BADGES answer "what is it". Kind, lifecycle and provenance strength, each a word, at most
///   one of which is ever coloured on a real note.
///
/// Nothing dims for an archived passage. Excluded content is still the answer the reader asked
/// for; greying the prose would punish them for including it.
///
/// Sets no measure of its own — `Metrics.proseMaxWidth` is the caller's call, because a card in a
/// result column and the same card in a drawer want different ones.
struct PassageCard: View {
    let passage: Passage
    /// A result list caps the snippet so ten passages fit a screen; a detail view passes `nil`.
    /// Held as a parameter rather than a constant because the cap is the caller's context, and a
    /// baked-in 4 is how a component ends up forked to remove one number.
    var snippetLines: Int? = 4

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s10) {
            PassageSpine(passage: passage)
            Text(passage.snippet).proseText().lineLimit(snippetLines)
            PassageProvenance(passage: passage)
        }
        .padding(Metrics.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Ink.layer, border: edge)
    }

    /// Reads the whole withheld set, not `status` alone: a conversation-class passage is outside
    /// the default corpus for a reason status cannot express, and an edge that only watched status
    /// gave it the same edge as a settled note.
    private var edge: Tone { passage.withheldAs.isEmpty ? Ink.borderSubtle : Ink.stale }
}

/// Everything below the snippet is machine-generated fact, so all of it is MONO and none of it is
/// ever coloured — provenance says where a note came from, not that anything is wrong with it.
private struct PassageProvenance: View {
    let passage: Passage

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s2) {
            HStack(spacing: Gap.s8) {
                Text(source).typeface(Register.monoMicro, Ink.textSecondary)
                if !passage.domains.isEmpty {
                    Text(domains).typeface(Register.monoMicro, Ink.textHelper)
                }
            }
            .lineLimit(1)
            if !passage.supersedes.isEmpty {
                Text(replaced).typeface(Register.monoMicro, Ink.textHelper).lineLimit(1)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var source: String { "\(passage.vault) · \(passage.citation)" }

    private var domains: String { passage.domains.map { "#\($0)" }.joined(separator: " ") }

    /// The count leads the ids so a truncated line still says how many notes were consolidated —
    /// the fact schema v8 changed `supersedes` to a list in order to record.
    private var replaced: String {
        "supersedes \(passage.supersedes.count) · " + passage.supersedes.joined(separator: ", ")
    }
}
