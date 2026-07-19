import Foundation
import ScriptaCore

extension TranscriptStore {
    /// All app-authored transcripts in the configured output folder, newest first.
    static func list() -> [TranscriptMeta] {
        list(in: AppSettings.outputFolder)
    }
}
