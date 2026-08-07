import Foundation

/// The spine a transcript declares about itself: `status`, `doc_type`, `confidence`, `class`.
///
/// WRITTEN AT CAPTURE BECAUSE CAPTURE IS WHAT KNOWS. `substrate compose` refuses a whole SCOPE —
/// not a note — when any note fails to declare `status` and `doc_type`, so something has to state
/// them. Every one of the four was already knowable here: a call that ended is `complete`, a
/// transcript is a `conversation`, and the other two are constants.
///
/// THIS IS NOW THE ONLY AUTHOR. It used to be the second: `transcript_export` called itself a
/// "SPINE AUTHOR", synthesised all four at the boundary, and dropped any the app supplied — a guard
/// worth having while a conversion step existed, because an app build emitting `class: reference`
/// on a transcript would defeat the conversation-class withholding by assertion. That exporter is
/// deleted (Doc 4 §7: capture writes into the vault, so nothing exports into one), and with it the
/// second statement of these four values.
///
/// The guard it provided is replaced rather than dropped. `TranscriptSpineParityTests` no longer
/// compares two declarations — there is one — and instead checks each value against the engine's own
/// vocabulary in `spine.py` and `classes.py`. That is the stronger check: the exporter agreeing with
/// the app never said anything about either agreeing with the engine, and it is the engine that
/// refuses the scope.
///
/// What it buys: a transcript on disk is a self-describing note the moment it is written. Obsidian,
/// `substrate ingest-md` and `compose` all read a real spine, with no conversion step in between.
///
/// `domains` is deliberately NOT here. It derives from `tags`, and `TranscriptMetadataEditor` lets
/// the operator rewrite tags after the fact — so a `domains` written once at capture is a cache that
/// goes stale on the first edit, silently, on the one axis retrieval filters by. The exporter
/// recomputes it from live `tags` on every run, which is correct today. It moves here when the
/// editor learns to maintain it, and not before.
public enum TranscriptSpine {

    /// `complete`, not `active` and not `archived`. A call ended; it will not gain turns, and the
    /// engine's own class policy already marks conversation-class documents frozen — so `complete`
    /// is the status that AGREES with that rather than contradicting it. `archived` would produce
    /// the same observable behaviour (out of default retrieval) for the wrong reason: exclusion has
    /// to come from the class axis alone, or "why did this not come back?" stops being answerable.
    public static let status = "complete"

    /// The vocabulary's lenient value, chosen because the other four each assert something that may
    /// be false of a call.
    public static let docType = "reference"

    /// DECLARED, not omitted, and the difference is the whole point: omitting it stores `unjudged`,
    /// which asserts nobody has judged this note. Somebody did — the judgement is that a transcript
    /// makes no settledness claim of its own, because settledness varies WITHIN one. A passage from
    /// mid-call can be reasoning the speaker abandoned ten minutes later, in the same register as
    /// the conclusion.
    public static let confidence = "unstated"

    /// Substrate withholds conversation-class documents from DEFAULT retrieval for the reason
    /// above. Declaring anything else here is the precise lie the class axis exists to prevent.
    public static let documentClass = "conversation"
}
