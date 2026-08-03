import Foundation

// MARK: - The passage spine, as the engine sends it
//
// Doc 3 §6: an in-app query and the equivalent CLI query must return the same passages, the same
// capability and the same `index_version` for the same scope. That is only checkable if the client
// holds no retrieval logic of its own, so everything here is a VALUE the engine produced or a fact
// derivable from one — never a rendering choice.
//
// THE LINE THIS FILE DRAWS, because nothing had drawn it before: `PassageConfidence` is schema — it
// is a value the engine sends, and `unstated` vs `unjudged` is a distinction the engine makes in
// `substrate/spine.py`. `SpineBadge.Prominence` is presentation — it is how we choose to draw one.
// The two lived in one directory because no one had to choose. Presentation re-attaches to these
// types as extensions in `Sources/Theme/Components`; nothing in this module knows a colour, a
// typeface or a badge exists.
//
// The vocabulary is `substrate/substrate/spine.py` and `substrate/substrate/classes.py`, and the
// wire shape is `substrate/substrate/render.py`. Those files are the authority: a value that does
// not appear there is not a value this type may have.

/// One class of document a result set can withhold, in the engine's own vocabulary.
///
/// THE ONE LIST. `ExclusionFilter` names these to the reader and `Passage.withheldAs` answers for
/// each of them, so a class the engine starts withholding cannot reach the screen unmarked. It
/// arrived as one list because it did not start as one: the exclusion bar already modelled
/// conversation-class sources as a first-class axis while `Passage` had no `document_class` field at
/// all, so a transcript passage rendered as settled default-corpus knowledge — and under rule 3 it
/// did so SILENTLY, because silence is what "fine" looks like.
public enum RetrievalClass: String, CaseIterable, Identifiable {
    case active
    case complete
    case archived
    case superseded
    /// Conversation-class documents. NOT a status — a separate axis, which is why it is its own
    /// case rather than a fifth status: a transcript has a lifecycle too.
    case sources

    public var id: String { rawValue }
    public var label: String { rawValue }

    /// What default retrieval searches — `spine.INCLUDED_STATUSES` plus the class partition in
    /// `classes.EXCLUDED_CLASSES`. The other three are withheld unless the caller asks, which is why
    /// they — and only they — can put a mark on a passage.
    public var isDefault: Bool {
        switch self {
        case .active, .complete: return true
        case .archived, .superseded, .sources: return false
        }
    }

    /// The classes a passage can be withheld AS, derived rather than listed a second time.
    public static let withheldByDefault: [RetrievalClass] = allCases.filter { !$0.isDefault }

    /// The engine token said in human terms. A disclosure shows the token; this is what the sentence
    /// beneath it translates the token into, so the token itself never has to be softened.
    public var gloss: String {
        switch self {
        case .active: return "active notes"
        case .complete: return "completed notes"
        case .archived: return "archived notes"
        case .superseded: return "superseded notes"
        case .sources: return "call transcripts"
        }
    }
}

/// Where a note sits in its lifecycle — `spine.STATUSES`.
///
/// INDEPENDENT of `PassageConfidence`. A note can be `active` and `proposed` at once — a design
/// that is current and was never built — and collapsing the two axes into one "quality" score is
/// exactly how a proposal ends up read as a decision.
public enum PassageStatus: String, CaseIterable, Identifiable {
    case active
    case complete
    case archived
    case superseded

    public var id: String { rawValue }
    public var label: String { rawValue }

    /// The class this status is withheld AS, or `nil` for the default corpus. One source for both
    /// the badge and the card edge, so "which statuses are unusual" is answered in one place.
    public var withheldAs: RetrievalClass? {
        switch self {
        case .archived: return .archived
        case .superseded: return .superseded
        case .active, .complete: return nil
        }
    }

    /// Outside the default corpus: these reach the screen only when the caller explicitly asked to
    /// include them. That — not "old" — is what a card edge marks, because the question a reader has
    /// about an unexpected result is "why is this here", not "how old is it".
    public var isExcluded: Bool { withheldAs != nil }
}

/// `document_class` — what KIND of document the passage came out of. The engine's third axis, and
/// independent of both `status` and `doc_type`. The values are the keys of `classes.POLICIES`.
///
/// The exclusion has a different REASON from the status one, and the reason is why it may not be
/// collapsed into status. Superseded content is withheld because it was replaced — nobody wants it.
/// A conversation is withheld for the opposite reason: the whole document is still wanted on ask,
/// but retrieval BY PASSAGE misrepresents it, because confidence varies WITHIN a transcript. A
/// passage from the middle surfaces reasoning the same session abandoned four turns later, in
/// exactly the same confident register as the conclusion. No per-value marker can fix that, which
/// is why the engine withholds the whole class — and why rendering one as settled default-corpus
/// knowledge is the exact lie the spine exists to prevent.
///
/// NOT `RawRepresentable`, and that is the point of the fourth case. `unreported` is the ABSENCE of
/// a class, so it has no token in `classes.POLICIES` and must never be reachable from a wire string
/// — a `String` raw value would hand every caller an `init(rawValue:)` that could conjure it, and
/// `allCases.map(\.rawValue)` would then claim the engine has a fourth class. The wire token and the
/// displayed word are separate properties for the same reason `EngineArmState` splits them.
public enum PassageDocumentClass: CaseIterable, Identifiable, Hashable, Sendable {
    /// A published edition that will not change, and the engine's default when a source says
    /// nothing. Six migrated conversations were relabelled this by a silent default once already.
    case referenceFrozen
    /// A living spec whose passages are only true for a stated version.
    case referenceVersioned
    /// A captured conversation: raw material for notes, never a note itself.
    case conversation

    /// `document_class: null` — this index row carries no class at all.
    ///
    /// THE HONEST ABSENCE, and the narrow thing it claims. It does NOT mean "the note declared
    /// nothing": the markdown reader defaults an undeclared `class:` to `reference-frozen` at
    /// ingest, so that distinction is already gone by the time a passage exists. It means the row
    /// itself was written without a class, which `render.passage` reaches only for a document built
    /// outside the reader. Defaulting THAT to `reference-frozen` would be a second copy of the bug
    /// that relabelled the six, one layer further from the evidence.
    case unreported

    /// The key this class has in `classes.POLICIES`, or `nil` for the case that is not a class.
    /// `RenderContractTests` pins the non-nil ones against the engine's own dict.
    public var wireToken: String? {
        switch self {
        case .referenceFrozen: return "reference-frozen"
        case .referenceVersioned: return "reference-versioned"
        case .conversation: return "conversation"
        case .unreported: return nil
        }
    }

    /// Always a word, because the badge always draws one. `unreported` is not softened into a blank
    /// — an axis drawn empty is indistinguishable from an axis nobody rendered.
    public var label: String { wireToken ?? "unreported" }
    public var id: String { label }

    /// The class the engine sent, or `nil` for a token this build has no class for. `unreported` is
    /// unreachable through here by construction: it has no token to match.
    public static func named(_ token: String) -> PassageDocumentClass? {
        allCases.first { $0.wireToken == token }
    }

    /// The tokens a wire value may take, for a refusal that can name what it knows.
    public static let wireTokens: [String] = allCases.compactMap(\.wireToken)

    /// `nil` for `unreported` DELIBERATELY, and it is an under-report rather than a claim: with no
    /// class on the row we can say neither that this passage is a withheld conversation nor that it
    /// is not. The axis still speaks — the spine draws `unreported` with `absent` prominence — but
    /// the card edge, which asserts membership, stays silent rather than asserting either way.
    public var withheldAs: RetrievalClass? {
        switch self {
        case .conversation: return .sources
        case .referenceFrozen, .referenceVersioned, .unreported: return nil
        }
    }
}

/// How strongly the note's claim is backed — `spine.STORED_CONFIDENCES`.
///
/// The two-way split that matters is NOT strong/weak. It is judged/unjudged first, and only then
/// settled/unsettled inside the judged half.
public enum PassageConfidence: String, CaseIterable, Identifiable {
    case proposed
    case inferred
    case stated
    case verified
    case unstated
    case unjudged

    public var id: String { rawValue }
    public var label: String { rawValue }

    /// `unstated` and `unjudged` are ABSENT SIGNAL — the field was never filled in, which is the
    /// state most bulk-migrated notes are in (530 of 657 distinct notes, measured 2026-07-28).
    /// Treating them as "uncertain" invents a judgement the corpus never made, and would light up
    /// two thirds of a normal result set.
    public var isJudged: Bool {
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
    public var isUnsettled: Bool {
        switch self {
        case .proposed, .inferred: return true
        case .stated, .verified, .unstated, .unjudged: return false
        }
    }
}

/// What kind of note this is — `spine.DOC_TYPES`. Never a deviation: every note declares one, and
/// none of the five is unusual.
public enum PassageDocType: String, CaseIterable, Identifiable {
    case decision
    case explanation
    case reference
    case howTo = "how-to"
    /// A maintained per-area summary that points at atomic notes and contains none of them.
    case digest

    public var id: String { rawValue }
    public var label: String { rawValue }
}

/// One retrieved note, as the engine hands it over.
public struct Passage: Identifiable {
    public let id: String
    /// Human language. The one piece of prose on a passage.
    public let snippet: String
    /// Machine-generated fact: a path.
    public let citation: String
    public let vault: String
    public let status: PassageStatus
    public let docType: PassageDocType
    /// The third exclusion axis. NO DEFAULT on the initialiser below: the default used to be
    /// `referenceFrozen`, which is the value that reads as settled, so every caller that had nothing
    /// to say silently said the one thing this axis exists to stop them saying. A caller that does
    /// not know now passes `unreported`, which is a word on screen rather than a plausible one.
    public let documentClass: PassageDocumentClass
    public let confidence: PassageConfidence
    public let domains: [String]
    /// A LIST since schema v8 — one note can consolidate several, which the older scalar form could
    /// not express. `[]` when none.
    public let supersedes: [String]

    public init(id: String,
                snippet: String,
                citation: String,
                vault: String,
                status: PassageStatus,
                docType: PassageDocType,
                confidence: PassageConfidence,
                documentClass: PassageDocumentClass,
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

    /// Which withheld classes this passage is a member of — the question the card edge answers, and
    /// the reason it is a list rather than a `Bool`: a superseded transcript is both.
    ///
    /// The `switch` is exhaustive over `RetrievalClass` ON PURPOSE. A class added to the engine's
    /// default filter stops this compiling until the passage says whether it can be one, which is
    /// the gate that was missing when `sources` was withheld by the engine, modelled by the
    /// exclusion bar, and unknown to the card. It moved into this module intact, and it is the
    /// reason `RetrievalClass` had to move with `Passage` rather than stay beside the bar that
    /// draws it — the gate only exists where the two meet.
    public var withheldAs: [RetrievalClass] {
        RetrievalClass.withheldByDefault.filter { klass in
            switch klass {
            case .archived, .superseded: return status.withheldAs == klass
            case .sources: return documentClass.withheldAs == klass
            case .active, .complete: return false
            }
        }
    }
}
