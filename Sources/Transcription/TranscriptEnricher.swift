import Foundation
import FoundationModels

/// A generated title + summary + topics for a transcript.
@Generable
struct TranscriptDigest {
    @Guide(description: "A short, specific title describing the conversation — 4 to 8 words, no date or time")
    let title: String
    @Guide(description: "A concise 2–4 sentence summary of what was discussed and any decisions or action items")
    let summary: String
    @Guide(description: "6 to 10 broad topic keywords for retrieval — include the general subject area / domain even when it is never said verbatim (e.g. the sport, the field, the activity), plus specific recurring themes. Lowercase, single words or short phrases.")
    let topics: [String]
}

/// Generates a title and summary from a transcript using Apple's on-device Foundation Models.
/// Fully local (requires Apple Intelligence enabled). Additive only — never alters the
/// transcript itself, so the small model's imprecision can't corrupt the record.
enum TranscriptEnricher {

    /// Whether the on-device model is available (Apple Intelligence enabled on a capable Mac).
    static var isAvailable: Bool {
        if case .available = SystemLanguageModel.default.availability { return true }
        return false
    }

    /// A specific, actionable explanation of why the model isn't usable — or nil when it is.
    /// "Enable it in Settings" is a dead end on an ineligible Mac and wrong while the model is
    /// still downloading, so surface the actual reason.
    static var availabilityMessage: String? {
        switch SystemLanguageModel.default.availability {
        case .available:
            return nil
        case .unavailable(.deviceNotEligible):
            return "This Mac doesn’t support Apple Intelligence, so Ask isn’t available here."
        case .unavailable(.appleIntelligenceNotEnabled):
            return "Turn on Apple Intelligence to use Ask (System Settings › Apple Intelligence & Siri)."
        case .unavailable(.modelNotReady):
            return "The on-device model is still downloading — try again in a few minutes."
        case .unavailable:
            return "On-device answering isn’t available right now."
        }
    }

    /// Generates a digest via the resolved engine (Apple FM by default, or an assigned local
    /// model). Kept as the app-wide entry point so callers don't reach into the engine layer.
    static func enrich(_ transcript: String) async -> TranscriptDigest? {
        await EngineRouter.enrich(transcript)
    }

    /// Trims + lowercases + filters a raw digest; nil when it has no usable summary. Shared by
    /// every enrich engine so their output is normalised identically.
    static func normalize(_ digest: TranscriptDigest) -> TranscriptDigest? {
        let title = digest.title.trimmingCharacters(in: .whitespacesAndNewlines)
        let summary = digest.summary.trimmingCharacters(in: .whitespacesAndNewlines)
        let topics = digest.topics
            .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        guard !summary.isEmpty else { return nil }
        return TranscriptDigest(title: title, summary: summary, topics: topics)
    }
}
