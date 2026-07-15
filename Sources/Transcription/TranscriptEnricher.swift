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

    static func enrich(_ transcript: String) async -> TranscriptDigest? {
        guard isAvailable else { return nil }

        // Cap input to stay within the model's context window.
        let input = String(transcript.prefix(8000))
        guard input.count > 20 else { return nil }

        let prompt = """
        Below is a transcript of a conversation. Produce a short descriptive title, a concise \
        summary, and a list of broad topic keywords for search. For the topics, include the \
        general subject area even if it is never stated outright. Focus on substance — topics \
        discussed, decisions, and any action items. Do not invent details that aren't in the transcript.

        \(input)
        """

        do {
            let session = LanguageModelSession()
            let response = try await session.respond(to: prompt, generating: TranscriptDigest.self)
            let digest = response.content
            let title = digest.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let summary = digest.summary.trimmingCharacters(in: .whitespacesAndNewlines)
            let topics = digest.topics
                .map { $0.lowercased().trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
            guard !summary.isEmpty else { return nil }
            return TranscriptDigest(title: title, summary: summary, topics: topics)
        } catch {
            return nil
        }
    }
}
