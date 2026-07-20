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
            // Capable/endpoint tier only: permitted ONE clarifying question. The 3B stays
            // answer-only (knowing when/what to ask is inference — its measured weak zone).
            return """
            You answer questions about the user's own recorded calls, grounded in the provided \
            context passages. Synthesise across passages and calls, resolve pronouns from context, \
            and note when calls disagree. Cite each call by name and date. If the question is \
            genuinely ambiguous between two calls or two people in the context, ask ONE short \
            clarifying question instead of guessing. If the answer is genuinely not in the \
            context, say you don't have it in these calls — do not invent details. Be concise \
            and specific.
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

    /// The JSON shape the endpoint is asked to emit for notes-merge.
    static let mergeNotesJSONSchema = #"{"body": string}"#

    /// The notes-merge prompt (M16): expands the user's own mid-call fragments into a structured
    /// note, grounded in the transcript. Additive only, like enrichment — never rewrites the
    /// transcript itself, so this must never be pointed at the transcript as something to alter.
    /// Single flowing paragraph, not bullets/multi-paragraph: the output lands as one timestamped
    /// entry via `NoteStore.append`, which stores (and `sanitizeEntryText` collapses) a single
    /// logical line — asking for structure the storage layer can't represent would come back
    /// mangled (list markers surviving as stray characters after line breaks are flattened).
    static func notesMergePrompt(transcript: String, notes: String, sizeClass: SizeClass, jsonSchema: String? = nil) -> String {
        let capped = String(transcript.prefix(enrichCharCap(sizeClass)))
        var prompt = """
        Below are two things: notes someone jotted down DURING a call (rough, incomplete — just \
        what they flagged as worth remembering), and the call's transcript. Expand the notes into \
        a clear note: for each point flagged, add the relevant detail from the transcript. Write it \
        as ONE flowing paragraph (no bullet points, no line breaks — this is stored as a single \
        line). Stay grounded in what the transcript actually says — do not invent details, \
        decisions, or numbers that aren't there. If a jotted note doesn't clearly map to anything \
        in the transcript, keep it as written rather than guessing at what it meant.
        """
        if let jsonSchema {
            prompt += "\n\nRespond with ONLY a JSON object of this shape, no prose:\n\(jsonSchema)"
        }
        prompt += """


        NOTES:
        \(notes)

        TRANSCRIPT:
        \(capped)
        """
        return prompt
    }

    /// The JSON shape the endpoint is asked to emit for commitment extraction.
    static let commitmentsJSONSchema = #"{"commitments": [{"owner": string, "text": string}]}"#

    /// The commitment-extraction prompt (M17): bounded generation, extraction only — never asked
    /// to act on what it finds (deterministic-first rule). `owner` must resolve either to the
    /// literal "you" or a name `EntityRegistry.resolve` can match against known people; asking
    /// for exact transcript wording rather than a paraphrase keeps that match reliable.
    static func commitmentsPrompt(transcript: String, sizeClass: SizeClass, jsonSchema: String? = nil) -> String {
        let capped = String(transcript.prefix(enrichCharCap(sizeClass)))
        var prompt = """
        Below is a call transcript. List every commitment, promise, or action item someone \
        explicitly agreed to or said they would do — not things that were merely discussed or \
        might happen. For each one, give the owner (the literal word "you" if the transcript's \
        own user — the "You:" speaker — owes it, otherwise the other person's name exactly as it \
        appears in the transcript) and a short, specific description of what was promised. If \
        there are none, return an empty list — do not invent commitments that weren't stated.
        """
        if let jsonSchema {
            prompt += "\n\nRespond with ONLY a JSON object of this shape, no prose:\n\(jsonSchema)"
        }
        prompt += "\n\n\(capped)"
        return prompt
    }

    /// The Quick Capture cleanup prompt (M14). Intent-tier editing — self-corrections applied,
    /// nothing added — is allowed here because a capture is the user's intent, not a record;
    /// this prompt must never be pointed at transcript text.
    static func captureCleanPrompt(_ text: String) -> String {
        """
        Below is a note someone dictated out loud. Clean it up: when the speaker revises \
        themselves ("actually", "wait", "no, make that"), keep only their final version. Remove \
        filler words and false starts. Fix punctuation and capitalization. Keep their own \
        wording and every detail — do not summarize, do not add anything, do not comment. \
        Return it as a single paragraph.

        \(text)
        """
    }
}
