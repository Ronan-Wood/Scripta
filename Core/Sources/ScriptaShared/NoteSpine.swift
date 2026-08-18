import Foundation

/// What a note written BY HAND declares, and the one field the operator picks.
///
/// THE TWO REQUIRED FIELDS, NAMED WHERE THE APP CAN WRITE THEM. Measured 2026-08-17 against a blank
/// vault: a plain markdown note is refused at compose with `SpineError: no status`, and adding a
/// status alone is refused again with `no doc_type`. Both refusals are correct — the engine will not
/// default a note into the live retrieval set — but nothing in the app said so. Help runs to 25
/// sections and names neither field, so the first note a new operator wrote by hand could not
/// compose, and the reason arrived from the engine afterwards rather than from the surface that
/// asked for the note.
///
/// This is the counterpart to `TranscriptSpine`, and the split is the point: a recorded call is
/// stamped entirely by the app, so every field there is a decision made once. A hand-written note
/// has an author, so exactly one field is theirs to choose and the rest are supplied.
public enum NoteSpine {

    /// `active` — live, and inside the statuses default retrieval searches.
    ///
    /// It must stay in the engine's `INCLUDED_STATUSES` or a note would compose cleanly and never
    /// answer, which reads as an empty vault rather than as a bug. `TranscriptSpine` carries the
    /// same constraint for the same reason; `NoteSpineParityTests` holds both to it.
    ///
    /// A call is `complete` because it ended and will gain no turns. A note is `active` because the
    /// operator is writing it now — the divergence is real, not an oversight.
    public static let status = "active"

    /// FOUR FIELDS ARE DOCUMENTED, TWO ARE REQUIRED, AND A WORKSPACE NOTE WRITES THE TWO.
    ///
    /// `confidence` and `domains` are omitted there deliberately. The engine requires neither, and
    /// an omitted confidence stores as `unjudged` — the true statement about a note nobody has
    /// judged yet. Writing `unstated` would assert a judgement was made and came back empty, which
    /// is the distinction `classes.py` was rewritten to preserve.
    ///
    /// A SHARED note declares both, because the tier every scope inherits is ranked and filtered on
    /// them, and because that is what every note already in core-vault carries.
    public static let declaredFields = ["status", "doc_type"]

    /// The engine's `spine.CONFIDENCES` plus its declared no-claim token, which is a legal value and
    /// not a member of the judged set. Offered only on the shared destination.
    ///
    /// The order is weakest-claim first, so the list reads as a scale rather than as a menu.
    public static let confidences: [NoteConfidence] = [
        NoteConfidence(value: "proposed", label: "Proposed",
                       hint: "Put forward, not yet tested."),
        NoteConfidence(value: "inferred", label: "Inferred",
                       hint: "Reasoned from something else, not observed directly."),
        NoteConfidence(value: "stated", label: "Stated",
                       hint: "Asserted from experience. No measurement behind it."),
        NoteConfidence(value: "verified", label: "Verified",
                       hint: "Checked against the thing itself — a run, a measurement, a source."),
        NoteConfidence(value: "unstated", label: "Not judged",
                       hint: "Deliberately makes no settledness claim."),
    ]

    /// `stated` — the honest default for something the operator just wrote down. `verified` claims a
    /// check that has not happened, and `proposed` understates a note someone bothered to write.
    public static let defaultConfidence = "stated"

    /// What `domains:` starts as on a shared note, matching `99-templates/operator-note.md`.
    public static let defaultSharedDomains = "operator"

    /// The default offered in the picker.
    ///
    /// `explanation` because it is the value least likely to be a lie about a note whose author has
    /// not thought about the axis yet. `decision` asserts something was chosen, `how-to` that steps
    /// follow, `digest` that this note summarises OTHERS and holds none of them itself — each is a
    /// claim a first note usually cannot support.
    public static let defaultDocType = "explanation"

    /// The engine's `spine.DOC_TYPES`, with the gloss the picker shows.
    ///
    /// ALL FIVE, and `NoteSpineParityTests` asserts the set matches the engine's EXACTLY rather than
    /// merely being a subset. A picker quietly missing a type the engine accepts is a vocabulary the
    /// operator cannot reach from the app; an extra one is a note refused at compose. Set equality
    /// is the only check that catches both, and it fails loudly when the engine's vocabulary moves.
    public static let docTypes: [NoteDocType] = [
        NoteDocType(value: "explanation", label: "Explanation",
                    hint: "How something works, or why it is the way it is."),
        NoteDocType(value: "decision", label: "Decision",
                    hint: "A choice that was made, and what it was made against."),
        NoteDocType(value: "reference", label: "Reference",
                    hint: "Facts to look up — values, names, shapes."),
        NoteDocType(value: "how-to", label: "How-to",
                    hint: "Steps that get something done."),
        NoteDocType(value: "digest", label: "Digest",
                    hint: "A summary that POINTS at other notes and holds none of them."),
    ]
}

/// One `doc_type` and how it is offered. `value` is the engine's word; the rest is for the operator.
public struct NoteDocType: Identifiable, Hashable, Sendable {
    public let value: String
    public let label: String
    public let hint: String

    public var id: String { value }

    public init(value: String, label: String, hint: String) {
        self.value = value
        self.label = label
        self.hint = hint
    }
}

/// One `confidence`. Same shape as `NoteDocType`; a distinct type so the two pickers cannot be
/// wired to each other's vocabulary, which is a mistake the compiler should catch rather than a
/// reviewer.
public struct NoteConfidence: Identifiable, Hashable, Sendable {
    public let value: String
    public let label: String
    public let hint: String

    public var id: String { value }

    public init(value: String, label: String, hint: String) {
        self.value = value
        self.label = label
        self.hint = hint
    }
}

/// Which vault a note is written into — and it is a two-case enum rather than a path because the two
/// destinations differ in more than location.
///
/// THE TIER IS THE FOLDER. `vault._tier_for` reads it off the path: `00-operator/` is tier 1,
/// `10-reference/` tier 2, everything else tier 3. So writing a shared note into `02-areas/` would
/// file operator knowledge as project thinking — the note would compose, answer, and be ranked as
/// the wrong kind of thing, with nothing anywhere reporting a fault.
public enum NoteDestination: String, CaseIterable, Identifiable, Sendable {
    /// The active workspace's own vault. Tier 3, and only this scope sees it.
    case workspace
    /// The vault every scope inherits. Tier 1.
    ///
    /// `notes.py` states the rule this sits inside: "nothing AUTO-writes into it — promoting
    /// something to the tier every context inherits is a deliberate manual act." The MCP `ingest`
    /// tool still refuses this destination outright and must keep refusing it; a model reaching
    /// core is the case that rule exists for. An operator choosing it here IS the deliberate manual
    /// act, which is why this path is the operator's and not the engine's.
    case shared

    public var id: String { rawValue }

    /// Where in the vault the note lands. Not the engine's `notes.WRITABLE_FOLDERS` — those are the
    /// three a PROJECT vault takes, and core-vault has a different layout entirely.
    public var folderName: String {
        switch self {
        case .workspace: return "02-areas"
        case .shared: return "00-operator"
        }
    }

    /// Whether this destination declares the two extra spine fields.
    public var declaresJudgement: Bool { self == .shared }
}
