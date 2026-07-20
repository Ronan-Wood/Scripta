import Foundation
import FoundationModels
import ScriptaCore

/// The cleaned form of a dictated capture.
@Generable
struct CleanedCapture {
    @Guide(description: "The dictated note, cleaned: self-corrections applied (keep only the speaker's final version), fillers and false starts removed, punctuation fixed. The speaker's own wording — nothing added, nothing summarized. One paragraph.")
    let text: String
}

/// Cleans a dictated capture for saving. Deterministic first (FillerCleaner always runs), then
/// an optional FM intent pass — course-correction is legitimate HERE because a capture is the
/// user's intent, not a record; the same pass is never applied to transcripts (M14 vs the
/// verbatim invariant). Any FM failure falls back to the deterministic result: a capture must
/// never be lost to model unavailability.
enum CaptureCleaner {

    /// Above this, skip the FM pass (small-model context) — the deterministic clean still applies.
    private static let fmCharCap = 4000

    static func clean(_ raw: String) async -> String {
        let base = FillerCleaner.clean(raw)
        guard TranscriptEnricher.isAvailable, base.count <= fmCharCap, !base.isEmpty else { return base }
        do {
            let session = LanguageModelSession()
            let cleaned = try await session.respond(
                to: PromptCatalog.captureCleanPrompt(base),
                generating: CleanedCapture.self
            ).content.text.trimmingCharacters(in: .whitespacesAndNewlines)
            // Guard the small model: reject empty or runaway output rather than trust it.
            guard !cleaned.isEmpty, cleaned.count <= base.count * 2 else { return base }
            return cleaned
        } catch {
            return base
        }
    }
}
