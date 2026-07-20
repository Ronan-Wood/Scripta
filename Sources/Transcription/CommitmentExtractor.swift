import Foundation
import FoundationModels
import ScriptaCore

/// One extracted commitment (M17). `owner` is either the literal "you" or a participant name,
/// exactly as the FM read it from the transcript — resolved against `EntityRegistry` by the
/// caller, never here (this type is pure extraction output).
@Generable
struct ExtractedCommitment {
    @Guide(description: "Who owes this: the literal word \"you\" if the transcript's own user owes it, otherwise the other person's name exactly as it appears in the transcript.")
    let owner: String
    @Guide(description: "A short, specific description of what was promised — the exact commitment, not a paraphrase of the whole discussion.")
    let text: String
}

@Generable
struct ExtractedCommitments {
    @Guide(description: "Every commitment, promise, or action item explicitly agreed to in the call. Empty if none — do not invent commitments that weren't stated.")
    let commitments: [ExtractedCommitment]
}

/// Commitment extraction (M17): bounded generation only, deterministic-first rule — this never
/// acts on what it finds, only names it. Additive, like TranscriptEnricher/NotesMerger: the
/// caller patches frontmatter and indexes; nothing here touches the transcript body.
enum CommitmentExtractor {
    /// Formatted as "<owner>: <text>" per commitment, ready for `TranscriptMetadataEditor
    /// .applyCommitments`'s frontmatter flow-list encoding. Empty array (not nil) when there's
    /// nothing to extract or FM is unavailable — the caller's own emptiness check gates the write.
    static func extract(transcript: String) async -> [String] {
        guard let commitments = await EngineRouter.extractCommitments(transcript: transcript) else { return [] }
        return commitments.compactMap { item in
            let owner = item.owner.trimmingCharacters(in: .whitespaces)
            let text = item.text.trimmingCharacters(in: .whitespaces)
            // IndexBuilder decodes by splitting on the FIRST ": " — an owner that itself contains
            // that delimiter (e.g. a hallucinated "Name: Title") would silently corrupt the split,
            // truncating the owner and bleeding the rest into the shown commitment text. Drop
            // rather than mangle: a lost extraction is much cheaper than a misattributed one.
            guard !owner.isEmpty, !text.isEmpty, !owner.contains(": ") else { return nil }
            return "\(owner): \(text)"
        }
    }
}
