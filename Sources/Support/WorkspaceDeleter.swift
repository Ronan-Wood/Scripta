import Foundation
import ScriptaCore

/// Deletes an entire workspace's calls — the "wipe Family before lending the laptop" privacy
/// feature (I6). Destructive and strictly user-initiated (confirmed in the UI with an exact count).
///
/// Safety: only ever touches files that parse as app-authored transcripts (owner marker on its own
/// line, via `TranscriptStore.list()`) AND carry the target group. A user's own vault notes lack
/// the marker, so they can never be caught. Unlike the retention pruner it does NOT also gate on
/// the filename shape — for a privacy wipe, completeness matters (an untitled "Call …" left behind
/// would be a leak), and the marker + explicit group already guarantee app ownership.
///
/// Cascade: removes the Markdown file, the index rows (chunks / FTS / transcript), and the
/// group's sole-provenance registry entities. As the knowledge layer adds tables, extend here —
/// this stays the single call site.
enum WorkspaceDeleter {
    /// Files that would be deleted for `group` ("" = ungrouped) — drives the confirmation count.
    static func candidates(group: String) -> [URL] {
        TranscriptStore.list().filter { $0.group == group }.map(\.url)
    }

    @discardableResult
    static func delete(group: String) -> Int {
        var deleted = 0
        for url in candidates(group: group) {
            try? FileManager.default.removeItem(at: url)
            IndexStore.shared?.remove(path: url.path)   // cascade: transcript row + chunks + FTS
            deleted += 1
        }
        EntityRegistry.shared.purge(group: group)   // registry half of the cascade (I6)
        return deleted
    }
}
