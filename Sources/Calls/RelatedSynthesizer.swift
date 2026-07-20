import Foundation

/// Turns raw related-item hits into a short connective note (M18) — "Clovis's synthesis step
/// running proactively instead of only on a typed question," per the design discussion. Reuses
/// `EngineRouter.chatEngine(for: .ask)` (Clovis's own engine dispatch — same assigned model, same
/// fallback) rather than adding a 4th capability to `EnrichEngine`, which crosscheck already
/// flagged as trending toward a grab-bag of unrelated per-call tasks. `ChatEngine` only exposes a
/// streaming conversation, not a one-shot call — this just takes the final cumulative snapshot,
/// no new engine-layer plumbing needed.
enum RelatedSynthesizer {
    /// nil below 2 hits (nothing to connect), on any engine failure, or on empty output — every
    /// case a silent no-op, same "additive only" contract every other generation call here holds.
    static func synthesize(current: String, hits: [(title: String, snippet: String)]) async -> String? {
        guard hits.count >= 2 else { return nil }
        let prompt = PromptCatalog.relatedSynthesisPrompt(current: current, hits: hits)
        let chat = EngineRouter.chatEngine(for: .ask).makeChat(
            instructions: "You connect related passages from the user's own past calls, notes, and documents into one short, grounded note. Never invent a connection that isn't genuinely there.")
        var final = ""
        do {
            for try await snapshot in chat.stream(prompt) { final = snapshot }
        } catch {
            return nil
        }
        let trimmed = final.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
