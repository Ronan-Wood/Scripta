import Foundation

/// The spine a transcript declares about itself: `status`, `doc_type`, `confidence`, `class`.
///
/// WRITTEN AT CAPTURE BECAUSE CAPTURE IS WHAT KNOWS. `substrate compose` refuses a whole SCOPE —
/// not a note — when any note fails to declare `status` and `doc_type`, so something has to state
/// them. Until now that something was `transcript_export`, which calls itself a "SPINE AUTHOR" and
/// synthesises all four at the boundary. Every one of them was already knowable here: a call that
/// ended is `complete`, a transcript is a `conversation`, and the other two are constants.
///
/// THE EXPORTER STILL AUTHORS ITS OWN, and that is deliberate rather than a migration left half
/// done. `transcript_export._RESERVED_KEYS` drops a source `status`/`doc_type`/`confidence`/`class`
/// rather than carrying it through, "so the app can never supply a spine value the exporter believes
/// it decided" — a guard worth keeping while an exporter exists, because an app build that started
/// emitting `class: reference` on a transcript would otherwise defeat the conversation-class
/// withholding by assertion. So there are two independent statements of the same four values, and
/// `TranscriptSpineParityTests` reads the Python constants and fails if they disagree. Divergence is
/// a build failure, not a corpus that quietly means something else.
///
/// What this buys before the exporter is deleted (Doc 4 Phase 5): a transcript on disk is a
/// self-describing note. Obsidian, `substrate ingest-md`, and any reader that is not this exporter
/// see a real spine instead of a file that only becomes one after a conversion step.
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
