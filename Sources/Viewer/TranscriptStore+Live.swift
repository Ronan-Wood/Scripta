import Foundation
import ScriptaCore

extension TranscriptStore {
    /// All app-authored transcripts under the configured output folder, newest first — the flat
    /// layout AND every workspace vault beneath it (Doc 4 §7).
    ///
    /// `list(under:)` rather than `list(in:)`, and the difference is the whole corpus: the
    /// single-directory version sees only what sits directly in the folder, so every surface in the
    /// app would have gone silently empty the first time a transcript was written into a vault.
    static func list() -> [TranscriptMeta] {
        list(under: AppSettings.outputFolder)
    }
}
