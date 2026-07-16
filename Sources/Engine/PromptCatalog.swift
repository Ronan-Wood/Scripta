import Foundation

/// Prompts keyed by (task, size class) — never by engine identity. The compact assets are the
/// validated ~3B text; the capable assets ask a 7–20B model to synthesise and resolve pronouns.
/// Quarantining the 3B tuning here keeps model workarounds out of shared code.
enum PromptCatalog {

    /// Grounding instructions for the Ask conversation.
    static func askInstructions(_ sizeClass: SizeClass) -> String {
        switch sizeClass {
        case .compact:
            // The validated 3B strict-grounding text, verbatim.
            return """
            You answer questions about the user's own recorded calls, using ONLY the provided \
            context passages. You may make reasonable connections between related facts in the \
            context. Cite the call by name when you answer. If the answer is genuinely not in the \
            context, say you don't have it in these calls. Be concise and specific.
            """
        case .capable:
            return """
            You answer questions about the user's own recorded calls, grounded in the provided \
            context passages. Synthesise across passages and calls, resolve pronouns from context, \
            and note when calls disagree. Cite each call by name and date. If the answer is \
            genuinely not in the context, say you don't have it in these calls — do not invent \
            details. Be concise and specific.
            """
        }
    }

    /// How many retrieved context chunks to feed Ask (bigger models take more).
    static func askContextChunks(_ sizeClass: SizeClass) -> Int {
        sizeClass == .compact ? 6 : 14
    }

    /// Character cap on the transcript fed to enrichment (bigger models take more).
    static func enrichCharCap(_ sizeClass: SizeClass) -> Int {
        sizeClass == .compact ? 8_000 : 24_000
    }

    /// The enrichment prompt. `schema` is appended only for the endpoint (JSON mode); Apple FM
    /// uses @Generable so it ignores it.
    static func enrichPrompt(_ transcript: String, sizeClass: SizeClass, jsonSchema: String? = nil) -> String {
        let capped = String(transcript.prefix(enrichCharCap(sizeClass)))
        var prompt = """
        Below is a transcript of a conversation. Produce a short descriptive title (4–8 words, no \
        date or time), a concise summary, and a list of 6–10 broad topic keywords for search — \
        include the general subject area even if it is never stated outright. Focus on substance: \
        topics discussed, decisions, and any action items. Do not invent details not in the transcript.
        """
        if sizeClass == .capable {
            prompt += " In the summary, state any decisions and action items explicitly."
        }
        if let jsonSchema {
            prompt += "\n\nRespond with ONLY a JSON object of this shape, no prose:\n\(jsonSchema)"
        }
        prompt += "\n\n\(capped)"
        return prompt
    }

    /// The JSON shape the endpoint is asked to emit for enrichment.
    static let digestJSONSchema = #"{"title": string, "summary": string, "topics": [string]}"#
}
