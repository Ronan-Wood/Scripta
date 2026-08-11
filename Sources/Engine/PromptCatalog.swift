import Foundation

/// Prompts keyed by (task, size class) — never by engine identity. The compact assets are the
/// validated ~3B text; the capable assets ask a 7–20B model to synthesise and resolve pronouns.
/// Quarantining the 3B tuning here keeps model workarounds out of shared code.
enum PromptCatalog {

    /// Grounding instructions for the Ask conversation.
    ///
    /// THE CORPUS IS NO LONGER "CALLS". Since Doc 4 §7 one scope holds the recorded calls, the
    /// operator's curated notes and the documents they uploaded, so text telling the model it is
    /// answering about calls made it describe a note as something someone said. Each passage now
    /// arrives labelled with its spine, and the instructions name what those labels MEAN — a
    /// passage marked `from a call` may be reasoning the speaker abandoned four turns later, and
    /// one marked `proposed` was never enacted. That distinction is the reason the spine exists;
    /// carrying it to the screen and not to the model would have been half the job.
    static func askInstructions(_ sizeClass: SizeClass) -> String {
        switch sizeClass {
        case .compact:
            // Derived from the validated 3B strict-grounding text: same shape, same refusal
            // clause, widened corpus plus the two spine rules. Kept short — the measured weak zone.
            return """
            You answer questions about the user's own vault: recorded calls, their notes, and \
            documents they added — using ONLY the provided context passages. Each passage is \
            labelled with where it came from and how settled it is. Treat one marked "from a call" \
            as something someone said, not as a decision, and one marked "proposed" or "inferred" \
            as not settled. You may make reasonable connections between related facts in the \
            context. Cite the passage by name when you answer. If the answer is genuinely not in \
            the context, say you don't have it. Be concise and specific.
            """
        case .capable:
            // Capable/endpoint tier only: permitted ONE clarifying question. The 3B stays
            // answer-only (knowing when/what to ask is inference — its measured weak zone).
            return """
            You answer questions about the user's own vault: recorded calls, their notes, and \
            documents they added — grounded in the provided context passages. Each passage is \
            labelled with its source and status. Weigh them accordingly: a passage marked "from a \
            call" is something that was said and may be reasoning abandoned later in the same \
            conversation, while a note is a considered claim; "proposed" and "inferred" are not \
            settled, "verified" is. Say which kind you are relying on when it matters. Synthesise \
            across passages, resolve pronouns from context, and note when sources disagree — \
            including when a call and a note disagree. Cite each passage by name. If the question \
            is genuinely ambiguous between two sources or two people in the context, ask ONE short \
            clarifying question instead of guessing. If the answer is genuinely not in the \
            context, say you don't have it — do not invent details. Be concise and specific.
            """
        }
    }

    /// Character cap on the transcript fed to enrichment (bigger models take more). Ask budgets its
    /// assembled passage context against this too — a character budget means the same thing whether
    /// the text is one transcript or eight notes, which is why it serves both.
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

    /// The related-items synthesis prompt (M18): given what the user is currently looking at plus
    /// what retrieval already found related to it, explain the connection in a couple of
    /// sentences — the same "ground it, don't invent" discipline as every other generation prompt
    /// here, since a wrong claimed connection is worse than no synthesis at all.
    static func relatedSynthesisPrompt(current: String, hits: [(title: String, snippet: String)]) -> String {
        let list = hits.enumerated()
            .map { i, hit in "[\(i + 1)] \(hit.title): \(hit.snippet)" }
            .joined(separator: "\n")
        return """
        The user is currently looking at: \(current)

        These related passages turned up from their other calls, notes, and documents:
        \(list)

        In 2–3 sentences, explain how they connect to what the user is looking at now — be \
        specific about what was said or decided, not just that they're "related." If the \
        connection is genuinely thin, say so briefly rather than overstating it. Do not invent a \
        connection that isn't actually there in the passages above.
        """
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
