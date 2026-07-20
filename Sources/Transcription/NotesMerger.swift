import Foundation
import FoundationModels
import ScriptaCore

/// A generated note body merging mid-call fragments with the transcript.
@Generable
struct MergedNote {
    @Guide(description: "The expanded note as ONE flowing paragraph — no bullet points, no line breaks. Grounded strictly in the transcript, no invented details.")
    let body: String
}

/// The "Granola" interaction (M16): when a call had mid-call notes — the user's own skeleton,
/// typed via the quick-note panel while recording — merges them with the transcript into a
/// structured note. Written as a SEPARATE artifact by the caller (RecordingSession); this type
/// only produces the text. Additive only, like TranscriptEnricher: never touches the transcript.
enum NotesMerger {
    /// nil when there's nothing to merge, FM is unavailable, or the merge produced nothing
    /// usable — every case is a silent no-op, same "additive only, never blocks" contract
    /// TranscriptEnricher.enrich already holds to.
    static func merge(transcript: String, notes: [CallNote]) async -> String? {
        guard !notes.isEmpty else { return nil }
        let notesText = notes
            .map { "[\(TranscriptWriter.formatClock(Double($0.startMs) / 1000.0))] \($0.text)" }
            .joined(separator: "\n")
        return await EngineRouter.mergeNotes(transcript: transcript, notes: notesText)
    }
}
