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
    static func candidates(group: String, in vault: URL = AppSettings.outputFolder) -> [URL] {
        TranscriptStore.list(in: vault).filter { $0.group == group }.map(\.url)
    }

    @discardableResult
    static func delete(group: String) -> Int {
        // Capture BOTH switchable globals once: a vault switch (repoint) landing mid-cascade must
        // not split the halves — files from vault A but stubs/registry purged in vault B.
        let vault = AppSettings.outputFolder
        let registry = EntityRegistry.shared
        var deleted = 0
        for url in candidates(group: group, in: vault) {
            try? FileManager.default.removeItem(at: url)
            IndexStore.shared?.remove(path: url.path)   // cascade: transcript row + chunks + FTS
            deleted += 1
        }
        // Knowledge cascade — named workspaces only: "" is BOTH the ungrouped bucket here and the
        // registry's GLOBAL sentinel for vocabulary (terms/termVocab treat groups == [""] as
        // visible in every workspace — people entities are not globalized), so purging "" would
        // destroy global vocabulary that feeds every workspace's ASR bias. Ungrouped files still
        // delete above; only the registry/mirror halves are skipped.
        if !group.isEmpty {
            registry.purge(group: group)
            // Vault stubs (Entities/<group>/) go too, toggle or no toggle — marker-gated inside.
            EntityMirror.purge(group: group, vault: vault)
            if let store = IndexStore.shared {
                IndexBuilder.syncTerms(store: store, registry: registry)
            }
        }
        if let store = IndexStore.shared {
            store.pruneOrphanedEntities()   // registry-independent — runs for "" wipes too
            // Truncate the WAL: the wiped calls' verbatim text must not linger in index.db-wal at
            // laptop-handoff time. (Bytes in main-DB free pages are a separate, parked decision.)
            store.checkpoint()
        }
        return deleted
    }
}
