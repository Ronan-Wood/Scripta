import SwiftUI

// MARK: - Record & Register: the passage spine
//
// A passage is one retrieved note, and it has to carry four independent axes — kind, lifecycle,
// document class, and provenance strength — without any of them shouting. Rule 3 is what makes
// that possible: a default-corpus, ACTIVE, VERIFIED passage is ENTIRELY MONOCHROME, so the only
// coloured pixels on a screenful of results are the ones the reader needs to stop at.
//
// Two rules govern how the axes below spend that budget:
//
//   ONE TONE PER AXIS, NOT PER VALUE. `Ink.danger` says "a reader could mistake this for settled
//   fact"; `Ink.stale` says "this is outside the default corpus". Which value triggered it is
//   carried by the WORD, which is always rendered. Colour is redundant reinforcement, never the
//   sole signal — that is what keeps the spine legible to a dichromat and keeps the palette at two.
//
//   ABSENCE IS NOT A LOW VALUE. `unstated` / `unjudged` mean nobody has judged the note yet. Most
//   of the migrated corpus is in that state. It is rendered by REMOVING chrome, not by fading ink
//   toward "weak" — see `SpineBadge.Prominence.absent`.

/// One of the spine's axes: a word, and how loudly the badge says it.
///
/// The protocol is what lets `Passage.spineAxes` be a LIST. A spine assembled from a list cannot
/// omit an axis the passage declares, which is the failure this file already had once — an axis
/// modelled in one component and missing from the one that renders the answer.
protocol PassageAxis {
    /// Always rendered. The word is the signal; colour only says "stop here".
    var label: String { get }
    var prominence: SpineBadge.Prominence { get }
}

/// One class of document a result set can withhold, in the engine's own vocabulary.
///
/// THE ONE LIST. `ExclusionBar` names these to the reader and `Passage.withheldAs` answers for each
/// of them, so a class the engine starts withholding cannot reach the screen unmarked. It arrived
/// as one list because it did not start as one: the bar already modelled conversation-class sources
/// as a first-class axis while `Passage` had no `document_class` field at all, so a transcript
/// passage rendered as settled default-corpus knowledge — and under rule 3 it did so SILENTLY,
/// because silence is what "fine" looks like.
enum RetrievalClass: String, CaseIterable, Identifiable {
    case active
    case complete
    case archived
    case superseded
    /// Conversation-class documents. NOT a status — a separate axis, which is why it is its own
    /// case rather than a fifth status: a transcript has a lifecycle too.
    case sources

    var id: String { rawValue }
    var label: String { rawValue }

    /// MONO. Rule 1's name/value split (see `Register.swift`): this is a VALUE the engine put in a
    /// field and the exact token you would type to ask for it back, not the name of the field.
    /// Declared on the type so a second renderer of this vocabulary cannot pick a different face.
    static let register = Register.mono

    /// What default retrieval searches. The other three are withheld unless the caller asks, which
    /// is why they — and only they — can put a mark on a passage.
    var isDefault: Bool {
        switch self {
        case .active, .complete: return true
        case .archived, .superseded, .sources: return false
        }
    }

    /// The classes a passage can be withheld AS, derived rather than listed a second time.
    static let withheldByDefault: [RetrievalClass] = allCases.filter { !$0.isDefault }

    /// The engine token said in human terms. The chips show the token; this is what the sentence
    /// beneath them translates it into, so the token itself never has to be softened.
    var gloss: String {
        switch self {
        case .active: return "active notes"
        case .complete: return "completed notes"
        case .archived: return "archived notes"
        case .superseded: return "superseded notes"
        case .sources: return "call transcripts"
        }
    }
}

/// Where a note sits in its lifecycle.
///
/// INDEPENDENT of `PassageConfidence`. A note can be `active` and `proposed` at once — a design
/// that is current and was never built — and collapsing the two axes into one "quality" score is
/// exactly how a proposal ends up read as a decision.
enum PassageStatus: String, CaseIterable, Identifiable, PassageAxis {
    case active
    case complete
    case archived
    case superseded

    var id: String { rawValue }
    var label: String { rawValue }

    /// The class this status is withheld AS, or `nil` for the default corpus. One source for both
    /// the badge and the card edge, so "which statuses are unusual" is answered in one place.
    var withheldAs: RetrievalClass? {
        switch self {
        case .archived: return .archived
        case .superseded: return .superseded
        case .active, .complete: return nil
        }
    }

    /// Outside the default corpus: these reach the screen only when the caller explicitly asked to
    /// include them. That — not "old" — is what `PassageCard`'s edge marks, because the question a
    /// reader has about an unexpected result is "why is this here", not "how old is it".
    var isExcluded: Bool { withheldAs != nil }

    /// `complete` is silent alongside `active`: a finished note is a healthy note, and spending
    /// colour on it would leave nothing left to mark the results that are genuinely unusual.
    var prominence: SpineBadge.Prominence { isExcluded ? .excluded : .record }
}

/// `document_class` — what KIND of document the passage came out of. The engine's third axis, and
/// independent of both `status` and `doc_type`.
///
/// The exclusion has a different REASON from the status one, and the reason is why it may not be
/// collapsed into status. Superseded content is withheld because it was replaced — nobody wants it.
/// A conversation is withheld for the opposite reason: the whole document is still wanted on ask,
/// but retrieval BY PASSAGE misrepresents it, because confidence varies WITHIN a transcript. A
/// passage from the middle surfaces reasoning the same session abandoned four turns later, in
/// exactly the same confident register as the conclusion. No per-value marker can fix that, which
/// is why the engine withholds the whole class — and why rendering one as settled default-corpus
/// knowledge is the exact lie the spine exists to prevent.
enum PassageDocumentClass: String, CaseIterable, Identifiable, PassageAxis {
    /// A published edition that will not change, and the engine's default when a source says
    /// nothing. Six migrated conversations were relabelled this by a silent default once already.
    case referenceFrozen = "reference-frozen"
    /// A living spec whose passages are only true for a stated version.
    case referenceVersioned = "reference-versioned"
    /// A captured conversation: raw material for notes, never a note itself.
    case conversation

    var id: String { rawValue }
    var label: String { rawValue }

    var withheldAs: RetrievalClass? {
        switch self {
        case .conversation: return .sources
        case .referenceFrozen, .referenceVersioned: return nil
        }
    }

    /// Marked with `stale` and not `danger`, matching the status axis and `ExclusionBar`: "outside
    /// the default corpus" is one reason and gets one tone, whichever axis carried it there.
    var prominence: SpineBadge.Prominence { withheldAs == nil ? .record : .excluded }
}

/// How strongly the note's claim is backed.
///
/// The two-way split that matters is NOT strong/weak. It is judged/unjudged first, and only then
/// settled/unsettled inside the judged half.
enum PassageConfidence: String, CaseIterable, Identifiable, PassageAxis {
    case proposed
    case inferred
    case stated
    case verified
    case unstated
    case unjudged

    var id: String { rawValue }
    var label: String { rawValue }

    /// `unstated` and `unjudged` are ABSENT SIGNAL — the field was never filled in, which is the
    /// state most bulk-migrated notes are in. Treating them as "uncertain" invents a judgement the
    /// corpus never made, and would light up two thirds of a normal result set.
    var isJudged: Bool {
        switch self {
        case .unstated, .unjudged: return false
        case .proposed, .inferred, .stated, .verified: return true
        }
    }

    /// The values a reader can mistake for settled fact. `proposed` was never enacted; `inferred`
    /// was derived rather than asserted by anyone. Acting on either as though it were a decision is
    /// the specific failure this axis exists to prevent, so both must be visible ON the passage.
    ///
    /// `stated` is deliberately NOT here: an author asserting something is a normal, judged,
    /// healthy value, and marking it would make three of four judged values deviations.
    var isUnsettled: Bool {
        switch self {
        case .proposed, .inferred: return true
        case .stated, .verified, .unstated, .unjudged: return false
        }
    }

    var prominence: SpineBadge.Prominence {
        guard isJudged else { return .absent }
        return isUnsettled ? .unsettled : .record
    }
}

/// What kind of note this is. Never a deviation — every note declares one, and none of the five is
/// unusual enough to be worth a colour under rule 3.
enum PassageDocType: String, CaseIterable, Identifiable, PassageAxis {
    case decision
    case explanation
    case reference
    case howTo = "how-to"
    /// A maintained per-area summary that points at atomic notes and contains none of them.
    case digest

    var id: String { rawValue }
    var label: String { rawValue }

    var prominence: SpineBadge.Prominence { .record }
}

/// An axis flattened to what the badge needs. A struct rather than an existential so the spine
/// stays a plain `ForEach` and the four enums keep their own types and their own reasons.
struct SpineAxis: Identifiable {
    /// The envelope field, which is also the `ForEach` identity — two axes can share a word
    /// (`reference` is a doc_type and half of two document classes) and must not share a row.
    let field: String
    let label: String
    let prominence: SpineBadge.Prominence

    var id: String { field }

    init(_ field: String, _ value: some PassageAxis) {
        self.field = field
        self.label = value.label
        self.prominence = value.prominence
    }
}

/// One retrieved note, as the engine hands it over.
struct Passage: Identifiable {
    let id: String
    /// Human language — rendered in the PROSE register, the only prose on the card.
    let snippet: String
    /// Machine-generated fact: a path. MONO, like everything else below the snippet.
    let citation: String
    let vault: String
    let status: PassageStatus
    let docType: PassageDocType
    /// The third exclusion axis. Defaulted, because the engine defaults it — and the default is the
    /// one that reads as settled, so the card has to say which one it is rather than imply it.
    let documentClass: PassageDocumentClass
    let confidence: PassageConfidence
    let domains: [String]
    /// A LIST since schema v8 — one note can consolidate several, which the older scalar form could
    /// not express. `[]` when none, and the card renders nothing at all in that case.
    let supersedes: [String]

    init(id: String,
         snippet: String,
         citation: String,
         vault: String,
         status: PassageStatus,
         docType: PassageDocType,
         confidence: PassageConfidence,
         documentClass: PassageDocumentClass = .referenceFrozen,
         domains: [String] = [],
         supersedes: [String] = []) {
        self.id = id
        self.snippet = snippet
        self.citation = citation
        self.vault = vault
        self.status = status
        self.docType = docType
        self.documentClass = documentClass
        self.confidence = confidence
        self.domains = domains
        self.supersedes = supersedes
    }

    /// Every axis the spine draws, in reading order: what kind of note, where it sits, what corpus
    /// it came out of, how well it is backed. `PassageSpine` renders THIS and nothing else, so an
    /// axis added to the model reaches every card without anyone remembering to add a badge.
    var spineAxes: [SpineAxis] {
        [SpineAxis("doc_type", docType),
         SpineAxis("status", status),
         SpineAxis("document_class", documentClass),
         SpineAxis("confidence", confidence)]
    }

    /// Which withheld classes this passage is a member of — the question `PassageCard`'s edge
    /// answers, and the reason it is a list rather than a `Bool`: a superseded transcript is both.
    ///
    /// The `switch` is exhaustive over `RetrievalClass` ON PURPOSE. A class added to the engine's
    /// default filter stops this compiling until the passage says whether it can be one, which is
    /// the gate that was missing when `sources` was withheld by the engine, modelled by the
    /// exclusion bar, and unknown to the card.
    var withheldAs: [RetrievalClass] {
        RetrievalClass.withheldByDefault.filter { klass in
            switch klass {
            case .archived, .superseded: return status.withheldAs == klass
            case .sources: return documentClass.withheldAs == klass
            case .active, .complete: return false
            }
        }
    }
}
