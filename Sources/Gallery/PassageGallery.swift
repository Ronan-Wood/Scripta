import AppKit
import SwiftUI

/// The passage, and the whole status x confidence matrix behind it.
///
/// Rule 3's claim — that a default-corpus, active, verified passage is entirely monochrome — is
/// the one claim in this system that cannot be taken on trust, because every later component
/// inherits it. So it is not asserted here: the matrix draws all 24 combinations, the census
/// counts them from the same `prominence` the component draws with, and the contrast card measures
/// the pairings the passage introduces (including the one that was rejected for failing).
struct PassagePane: View {
    let appearance: GalleryAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s24) {
            MonochromeClaim()
            SpineMatrix()
            IndependentAxes()
            AbsentSignal()
            ExcludedFromCorpus()
            ConversationClass()
            SupersedesList()
            PassageContrast(appearance: appearance)
        }
    }
}

// MARK: - Sections

/// Passages are shown on `Ink.background`, not inside a `Card`: a card is `Ink.layer` and so
/// is a passage, so nesting them would hide the exact edge this component uses to mark exclusion.
private struct PassageSection<Content: View>: View {
    let title: String
    let note: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s10) {
            Text(title).typeface(Register.title3, Ink.textPrimary)
            Text(note).proseText(Register.proseSm, Ink.textSecondary)
            content()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct MonochromeClaim: View {
    var body: some View {
        PassageSection(title: "Rule 3 — the default is silent",
                       note: "Active, verified, reference-frozen, in the default corpus. Every pixel below is a neutral: four grey badges, prose in textPrimary, mono provenance in textSecondary and textHelper. A coloured pixel anywhere in this card is a defect.") {
            VStack(alignment: .leading, spacing: Gap.s10) {
                PassageCard(passage: Sample.canonical)
                MarkCount(passage: Sample.canonical)
            }
        }
    }
}

/// The claim above, counted from the same `prominence` the card drew with rather than asserted
/// beside it. `SystemRuleTests` proves the tokens on this path are achromatic; this proves the path
/// is the one taken.
private struct MarkCount: View {
    let passage: Passage

    private var marks: Int { passage.spineAxes.filter(\.prominence.carriesColour).count }

    var body: some View {
        HStack(spacing: Gap.s8) {
            Text("coloured marks on this card").typeface(Register.caption, Ink.textHelper)
            Spacer(minLength: Gap.s8)
            Text("\(marks)").typeface(Register.mono, Ink.textSecondary)
        }
    }
}

private struct IndependentAxes: View {
    var body: some View {
        PassageSection(title: "Confidence is independent of status",
                       note: "Same status, same doc_type, same corpus. Only confidence differs — a design that is current and was never built. Collapsing the two axes into one quality score is how a proposal gets read as a decision.") {
            VStack(alignment: .leading, spacing: Gap.s10) {
                PassageCard(passage: Sample.canonical)
                PassageCard(passage: Sample.proposed)
                PassageCard(passage: Sample.inferred)
            }
        }
    }
}

private struct AbsentSignal: View {
    var body: some View {
        PassageSection(title: "Absent signal is not low confidence",
                       note: "unstated and unjudged mean nobody has judged the note yet, which is where most of the migrated corpus sits. They lose their chrome rather than their colour — an empty field, not a weak value. The card below is the modal note in the corpus and it is silent.") {
            VStack(alignment: .leading, spacing: Gap.s10) {
                ConfidenceTiers()
                PassageCard(passage: Sample.unjudged)
            }
        }
    }
}

/// All six confidence values in one row, in tier order, so the three-step escalation (no chrome →
/// filled chip → filled chip with a coloured edge) is readable without reading the words.
private struct ConfidenceTiers: View {
    var body: some View {
        Card(title: "The six confidence values",
             note: "Two absent, two judged-and-settled, two judged-and-unsettled. Tier is carried by chrome and text weight as well as by hue, so the ordering survives greyscale.") {
            HStack(spacing: Gap.s6) {
                ForEach(Self.ordered) { value in
                    SpineBadge(label: value.label, prominence: value.prominence)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private static let ordered: [PassageConfidence] =
        [.unjudged, .unstated, .stated, .verified, .inferred, .proposed]
}

private struct ExcludedFromCorpus: View {
    var body: some View {
        PassageSection(title: "Excluded — why is this on screen",
                       note: "Archived and superseded passages appear only when the caller asked to include them, so the card's edge answers the question the reader actually has. Nothing dims: excluded content is still the answer they asked for.") {
            VStack(alignment: .leading, spacing: Gap.s10) {
                PassageCard(passage: Sample.archived)
                PassageCard(passage: Sample.superseded)
            }
        }
    }
}

/// The third exclusion axis, and the one that was missing. It is here rather than folded into
/// `ExcludedFromCorpus` because the two exclusions have opposite REASONS, and a reader who thinks a
/// transcript is withheld for the same reason a superseded note is will include it and read a
/// mid-conversation passage as a conclusion.
private struct ConversationClass: View {
    var body: some View {
        PassageSection(title: "Conversation class — withheld for the opposite reason",
                       note: "A superseded note is withheld because it was REPLACED. A transcript is withheld because retrieval by passage misrepresents it: confidence varies within the conversation, and a passage from the middle surfaces reasoning that was abandoned four turns later, in the same confident register as the conclusion. Same mark, because it is the same question — why is this on screen. The card below is the note that got no mark at all until document_class existed here.") {
            VStack(alignment: .leading, spacing: Gap.s10) {
                PassageCard(passage: Sample.conversation)
                PassageCard(passage: Sample.supersededConversation)
            }
        }
    }
}

private struct SupersedesList: View {
    var body: some View {
        PassageSection(title: "supersedes is a list",
                       note: "Schema v8: one live note can consolidate several dead ones, which the older scalar form could not express. The count leads the ids so a truncated line still reports how many. Provenance is never coloured — it says where a note came from, not that anything is wrong with it.") {
            PassageCard(passage: Sample.consolidating)
        }
    }
}

// MARK: - The matrix

private struct SpineMatrix: View {
    var body: some View {
        Card(title: "Every status x confidence combination",
             note: "Drawn, not asserted. Both badges come from the same `prominence` the passage draws with, and the census below counts the coloured ones from the same source. document_class is not varied here — a conversation-class passage adds exactly one mark to every row below, which is the section further down.") {
            VStack(alignment: .leading, spacing: Gap.s6) {
                Census()
                RowRule()
                ForEach(PassageStatus.allCases) { status in
                    MatrixGroup(status: status)
                }
            }
        }
    }
}

private struct MatrixGroup: View {
    let status: PassageStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            GroupLabel(text: status.label)
            ForEach(PassageConfidence.allCases) { confidence in
                MatrixRow(status: status, confidence: confidence)
            }
        }
    }
}

private struct MatrixRow: View {
    let status: PassageStatus
    let confidence: PassageConfidence

    var body: some View {
        HStack(spacing: Gap.s6) {
            SpineBadge(label: status.label, prominence: status.prominence)
            SpineBadge(label: confidence.label, prominence: confidence.prominence)
            Spacer(minLength: Gap.s8)
            Text(verdict).typeface(Register.monoMicro, Ink.textHelper)
        }
        .frame(minHeight: Density.row)
    }

    private var verdict: String {
        let marks = SpineCensus.marks(status, confidence)
        if marks == 0 { return "monochrome" }
        return marks == 1 ? "1 mark" : "\(marks) marks"
    }
}

/// The matrix is uniform and the corpus is not, which is the number that matters: 8 of 24
/// combinations are silent, and the modal note in the vault — active, unjudged — is one of them.
private struct Census: View {
    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s2) {
            CensusRow(label: "combinations (document_class not varied)",
                      value: "\(SpineCensus.combinations.count)")
            CensusRow(label: "entirely monochrome", value: "\(SpineCensus.count(marks: 0))")
            CensusRow(label: "one coloured mark", value: "\(SpineCensus.count(marks: 1))")
            CensusRow(label: "two coloured marks", value: "\(SpineCensus.count(marks: 2))")
            CensusRow(label: "axes that can withhold a passage",
                      value: "\(RetrievalClass.withheldByDefault.count)")
            CensusRow(label: "hues spent on the whole spine", value: "2")
        }
    }
}

private struct CensusRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: Gap.s8) {
            Text(label).typeface(Register.ui, Ink.textPrimary)
            Spacer(minLength: Gap.s8)
            Text(value).typeface(Register.mono, Ink.textSecondary)
        }
        .frame(minHeight: Density.pill)
    }
}

private enum SpineCensus {
    static let combinations: [(status: PassageStatus, confidence: PassageConfidence)] =
        PassageStatus.allCases.flatMap { status in
            PassageConfidence.allCases.map { (status: status, confidence: $0) }
        }

    static func marks(_ status: PassageStatus, _ confidence: PassageConfidence) -> Int {
        (status.prominence.carriesColour ? 1 : 0) + (confidence.prominence.carriesColour ? 1 : 0)
    }

    static func count(marks target: Int) -> Int {
        combinations.filter { marks($0.status, $0.confidence) == target }.count
    }
}

// MARK: - The pairings this component introduces

/// Measured live, in this column's appearance, through the same `ContrastPair` the gate uses. The
/// last two rows are the marks this component REJECTED, kept on screen with their numbers. Only
/// one of them is still a contrast failure: `warning` has since gained a light-appearance ink and
/// now clears both levels, so its rejection rests on severity alone — a proposal read as a
/// decision is a wrong action, not a caution — and the row says so instead of implying a number.
private struct PassageContrast: View {
    let appearance: GalleryAppearance

    var body: some View {
        Card(title: "Pairings the passage introduces",
             note: "3:1 for an edge (1.4.11), 4.5:1 for 11pt mono and prose (1.4.3). Washes are composited over the card fill before measuring.") {
            VStack(alignment: .leading, spacing: Gap.s2) {
                ForEach(Self.rows, id: \.label) { row in
                    ContrastRow(label: row.label,
                                pair: row.pair,
                                required: row.required,
                                appearance: appearance)
                }
            }
        }
    }

    private struct Entry {
        let label: String
        let pair: ContrastPair
        let required: Double
    }

    private static let rows: [Entry] = [
        Entry(label: "stale edge / card fill (excluded card)",
              pair: ContrastPair(foreground: Ink.stale, background: Ink.layer, wash: nil),
              required: Wcag.largeOrUI),
        Entry(label: "stale edge / background",
              pair: ContrastPair(foreground: Ink.stale, background: Ink.background, wash: nil),
              required: Wcag.largeOrUI),
        Entry(label: "borderSubtle edge / card fill (default card)",
              pair: ContrastPair(foreground: Ink.borderSubtle, background: Ink.layer, wash: nil),
              required: Wcag.largeOrUI),
        Entry(label: "danger edge / dangerSoft badge (unsettled)",
              pair: ContrastPair(foreground: Ink.danger, background: Ink.layer, wash: Ink.dangerSoft),
              required: Wcag.largeOrUI),
        Entry(label: "stale edge / staleSoft badge (excluded)",
              pair: ContrastPair(foreground: Ink.stale, background: Ink.layer, wash: Ink.staleSoft),
              required: Wcag.largeOrUI),
        Entry(label: "textPrimary / dangerSoft badge",
              pair: ContrastPair(foreground: Ink.textPrimary, background: Ink.layer, wash: Ink.dangerSoft),
              required: Wcag.bodyText),
        Entry(label: "textPrimary / staleSoft badge",
              pair: ContrastPair(foreground: Ink.textPrimary, background: Ink.layer, wash: Ink.staleSoft),
              required: Wcag.bodyText),
        Entry(label: "textSecondary / layerAlt (record badge)",
              pair: ContrastPair(foreground: Ink.textSecondary, background: Ink.layerAlt, wash: nil),
              required: Wcag.bodyText),
        Entry(label: "textHelper / card fill (absent badge, provenance)",
              pair: ContrastPair(foreground: Ink.textHelper, background: Ink.layer, wash: nil),
              required: Wcag.bodyText),
        Entry(label: "textPrimary / card fill (snippet)",
              pair: ContrastPair(foreground: Ink.textPrimary, background: Ink.layer, wash: nil),
              required: Wcag.bodyText),
        Entry(label: "REJECTED on severity, not contrast — warning edge / card fill",
              pair: ContrastPair(foreground: Ink.warning, background: Ink.layer, wash: nil),
              required: Wcag.largeOrUI),
        Entry(label: "REJECTED — textPlaceholder / card fill (absent badge)",
              pair: ContrastPair(foreground: Ink.textPlaceholder, background: Ink.layer, wash: nil),
              required: Wcag.bodyText),
    ]
}

// MARK: - Specimens

// Every hand-written note here carries `.unclassified`, and it is a correction rather than a
// choice. These specimens are vault notes — `02-areas/`, `03-references/`, `04-synthesis/` — and a
// vault note declares no class, so `.referenceFrozen` was this file reproducing the exact mislabel
// the engine stopped producing: 83 of the operator's 684 notes declare a class. A proof surface
// showing a shape the engine rarely sends proves the wrong thing. The two `_sources/` specimens
// keep `.conversation`, which those notes really do declare.
//
// It moves no census. `.absent` and `.record` both return false from `carriesColour`, so the
// monochrome baseline and every mark count below are unchanged; what changes is that the badge now
// draws with its chrome removed, which is what absence is supposed to look like.
private enum Sample {
    static let canonical = Passage(
        id: "adr-031",
        snippet: "Blue marks interaction and nothing else. An accent that also carries content meaning drifts the moment a second author needs it — which is how one speaker ended up declared in a token and drawn, elsewhere, in a different orange.",
        citation: "02-areas/record-and-register.md",
        vault: "prism",
        status: .active,
        docType: .decision,
        confidence: .verified,
        documentClass: .unclassified,
        domains: ["design-system", "color"])

    static let proposed = Passage(
        id: "adr-044",
        snippet: "A per-scope refresh budget would let a large vault rebuild incrementally instead of refusing the whole pass. Sketched against the v8 envelope; never built, and the refresh path has changed twice since.",
        citation: "02-areas/refresh-budget.md",
        vault: "prism",
        status: .active,
        docType: .decision,
        confidence: .proposed,
        documentClass: .unclassified,
        domains: ["retrieval", "indexing"])

    static let inferred = Passage(
        id: "note-0912",
        snippet: "Retrieval is strongest when the question is worded like the note. Paraphrased questions were roughly even odds on the pre-migration corpus, so rephrasing before giving up is worth a try.",
        citation: "04-synthesis/retrieval-shape.md",
        vault: "prism",
        status: .active,
        docType: .explanation,
        confidence: .inferred,
        documentClass: .unclassified,
        domains: ["retrieval"])

    static let unjudged = Passage(
        id: "note-0331",
        snippet: "find does not follow symlinks without -L, so a plain find over a symlinked vault tree reports it empty. That is how several hundred notes stayed invisible through two coverage checks.",
        citation: "03-references/find-symlinks.md",
        vault: "prism",
        status: .active,
        docType: .reference,
        confidence: .unjudged,
        documentClass: .unclassified,
        domains: ["shell", "migration"])

    static let archived = Passage(
        id: "adr-008",
        snippet: "Speakers are assigned from a four-colour rotation on first appearance. Retired: the rotation gave the self party a hue, which spent a colour on the one participant weight could carry for free.",
        citation: "02-areas/speaker-rotation.md",
        vault: "prism",
        status: .archived,
        docType: .decision,
        confidence: .verified,
        documentClass: .unclassified,
        domains: ["design-system", "transcript"])

    static let superseded = Passage(
        id: "adr-014",
        snippet: "supersedes names the single note this one replaced. Replaced by the v8 envelope, where it became a list — a consolidation of several notes had to be written in prose, where nothing could read it.",
        citation: "02-areas/envelope-v7.md",
        vault: "prism",
        status: .superseded,
        docType: .decision,
        confidence: .stated,
        documentClass: .unclassified,
        domains: ["schema"])

    static let conversation = Passage(
        id: "call-0714",
        snippet: "…so my instinct is we drop the reranker entirely and lean on the embedder. Cheaper, and the gate hardly fires anyway.",
        citation: "_sources/2026-07-14-platform-sync.md",
        vault: "scripta",
        status: .active,
        docType: .reference,
        confidence: .stated,
        documentClass: .conversation,
        domains: ["retrieval"])

    /// Both axes at once, which is why `withheldAs` is a list: the edge has one job and two reasons
    /// can send it there, and a card that could only report one of them would report the wrong one.
    static let supersededConversation = Passage(
        id: "call-0621",
        snippet: "We agreed the envelope carries one supersedes id. Superseded by the v8 discussion three weeks later, where it became a list.",
        citation: "_sources/2026-06-21-schema-review.md",
        vault: "scripta",
        status: .superseded,
        docType: .reference,
        confidence: .stated,
        documentClass: .conversation,
        domains: ["schema"])

    static let consolidating = Passage(
        id: "adr-052",
        snippet: "One envelope, one schema version, one refresh verdict. Folds the three separate per-scope descriptions into a single shape so a caller can tell a frozen index from an absent one.",
        citation: "02-areas/envelope-v8.md",
        vault: "prism",
        status: .active,
        docType: .decision,
        confidence: .verified,
        documentClass: .unclassified,
        domains: ["schema", "retrieval"],
        supersedes: ["adr-014", "adr-021", "note-0774"])
}
