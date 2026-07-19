import Foundation
import ScriptaCore

extension TranscriptWriter {
    /// App entry point: writes into the user's configured output folder. Kept separate so the
    /// writer (and its owner-marker frontmatter contract) stays in the dependency-free layer.
    static func write(
        segments: [TranscriptSegment],
        startedAt: Date,
        duration: TimeInterval,
        participants: [String] = [],
        tags: [String] = ["call"],
        title: String? = nil,
        summary: String? = nil,
        screenSnippets: [ScreenSnippet] = [],
        notes: [CallNote] = [],
        isConference: Bool = false,
        group: String = ""
    ) throws -> URL {
        try write(to: AppSettings.outputFolder, segments: segments, startedAt: startedAt,
                  duration: duration, participants: participants, tags: tags, title: title,
                  summary: summary, screenSnippets: screenSnippets, notes: notes,
                  isConference: isConference, group: group)
    }
}
