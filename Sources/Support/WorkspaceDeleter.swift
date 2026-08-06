import Foundation
import ScriptaCore

/// Deletes an entire workspace's calls — the "wipe Family before lending the laptop" privacy
/// feature (I6). Destructive and strictly user-initiated (confirmed in the UI with an exact count).
///
/// Safety: only ever touches files that parse as app-authored transcripts (owner marker on its own
/// line, via `TranscriptStore.list()`) AND belong to the target workspace — by their `group:` in the
/// flat layout, or by sitting inside that workspace's vault (Doc 4 §7). A user's own vault notes
/// lack the marker, so they can never be caught. Unlike the retention pruner it does NOT also gate
/// on the filename shape — for a privacy wipe, completeness matters (an untitled "Call …" left
/// behind would be a leak), and ownership is already established.
///
/// **IT REFUSES RATHER THAN UNDER-REPORTS, and that is the whole difference between this and a
/// wipe that lies.** Both halves of the count used to fail silently to zero: `TranscriptStore.list`
/// returns `[]` when the folder cannot be read (`?? []`), and it is non-recursive, so once
/// transcripts move into vaults a flat listing finds nothing. Either way the confirmation dialog
/// would have said "0 calls", the wipe would have deleted nothing, reported success, and the
/// operator would have handed over the laptop. A privacy feature that cannot establish what it is
/// about to delete must say so — an error is recoverable, a false all-clear is not.
///
/// Cascade: removes the Markdown file, the index rows (chunks / FTS / transcript), and the
/// group's sole-provenance registry entities. As the knowledge layer adds tables, extend here —
/// this stays the single call site.
enum WorkspaceDeleter {

    enum WipeError: LocalizedError {
        /// Some location could not be read, so the set of files is a lower bound.
        case incomplete([String])

        var errorDescription: String? {
            switch self {
            case .incomplete(let reasons):
                return "Cannot list every file in this workspace, so a wipe cannot be shown to be "
                    + "complete: \(reasons.joined(separator: "; ")). Refusing rather than deleting "
                    + "part of it and reporting success — for a privacy wipe an incomplete result "
                    + "is worse than none, because nothing afterwards would say it was incomplete."
            }
        }
    }

    /// Files that would be deleted for `group` ("" = ungrouped) — drives the confirmation count.
    ///
    /// Throws when any location is unreadable. The count this feeds is the operator's evidence that
    /// the wipe covered everything, so a number derived from a partial listing is the failure.
    static func candidates(group: String, in root: URL = AppSettings.outputFolder) throws -> [URL] {
        var failures: [String] = []
        var found: [URL] = []

        // The flat layout: transcripts directly in the root, selected by their own `group:`.
        found += TranscriptStore.list(in: root).filter { $0.group == group }.map(\.url)
        if !directoryIsReadable(root, mustExist: true) {
            failures.append("\(root.lastPathComponent) could not be listed")
        }

        // The vault layout: LOCATION is the partition, so everything under this workspace's vault
        // belongs to it and no `group:` is consulted. That is the point of §7 — a transcript's
        // workspace stops being a field that can disagree with where the file is.
        let located = ScriptaVault.existingVault(forScope: group, under: root)
        failures += located.failures
        if let vault = located.vault {
            let transcripts = ScriptaVault.transcripts(inVaultAt: vault)
            found += TranscriptStore.list(in: transcripts).map(\.url)
            if !directoryIsReadable(transcripts, mustExist: false) {
                failures.append("\(vault.lastPathComponent)'s transcripts could not be listed")
            }
        }

        guard failures.isEmpty else { throw WipeError.incomplete(failures) }
        // Deduplicated by path: a transcript reached through both layouts is one file, and deleting
        // it twice would inflate the count the operator is shown as proof of completeness.
        var seen = Set<String>()
        return found.filter { seen.insert($0.standardizedFileURL.path).inserted }
    }

    /// What else goes when the workspace's vault goes: uploaded documents and notes.
    ///
    /// THE WIPE TAKES THE WHOLE VAULT, and it should — "wipe Family before lending the laptop" that
    /// left Family's documents on disk would be a privacy feature with a hole in it. But the
    /// confirmation counted CALLS and said "the transcript files for every call", so widening what
    /// is deleted without widening what is disclosed would have had the operator confirm "Delete 3
    /// calls" and lose every document and note in that workspace too.
    ///
    /// Counted separately rather than folded into the call count, because they are different kinds
    /// of loss and one of them the operator may not have thought of.
    ///
    /// **COUNTS THE WHOLE TREE, not two named subdirectories.** The first version counted the
    /// immediate children of `10-reference/` and `02-areas/` — but `delete` removes the vault
    /// ENTIRE, so `00-index/`, `03-references/`, `04-synthesis/`, anything non-transcript under
    /// `_sources/`, a compose run's leftover index, and anything the operator dropped in the folder
    /// all went unmentioned. A disclosure that is a strict subset of the destruction is the same
    /// defect it was written to fix, just smaller. Recursive for the same reason: a `10-reference/`
    /// holding forty sources across three directories counted as three.
    static func collateral(group: String, in root: URL = AppSettings.outputFolder)
        -> (documents: Int, other: Int) {
        guard let vault = ScriptaVault.existingVault(forScope: group, under: root).vault
        else { return (0, 0) }
        let layout = ScriptaVault(rootOfExistingVault: vault)
        let manager = FileManager.default

        func files(under directory: URL) -> Set<String> {
            guard let walker = manager.enumerator(at: directory,
                                                  includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: [.skipsHiddenFiles]) else { return [] }
            var out: Set<String> = []
            for case let url as URL in walker
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                out.insert(url.standardizedFileURL.path)
            }
            return out
        }

        let everything = files(under: vault)
        let documents = files(under: layout.references)
        // Transcripts are already in the call count the operator confirms; the manifest is this
        // app's own. Everything else is what they have not been told about yet.
        let transcripts = files(under: layout.transcripts)
        let manifest = layout.manifestURL.standardizedFileURL.path
        let other = everything.subtracting(documents).subtracting(transcripts).subtracting([manifest])
        return (documents.count, other.count)
    }

    /// Distinguishes "no transcripts here" from "could not look", which `TranscriptStore.list`
    /// collapses into an empty array. An absent directory is readable-and-empty, not a failure —
    /// a workspace with no vault yet is an ordinary state.
    /// `mustExist` mirrors `IndexBuilder.mdFiles`, and the two disagreeing was a bug: a MISSING
    /// output root returned `true` here, so an unmounted volume or a folder that was renamed after
    /// the sandbox flip produced zero candidates with no failure — "Delete 0 calls", confirmed,
    /// reported successful, transcripts all still on disk. The indexer already treats that exact
    /// directory as `mustExist: true` because "its disappearance means the volume or the grant went
    /// away, never that the user deleted every call"; a privacy wipe needs the same reading more,
    /// not less.
    private static func directoryIsReadable(_ url: URL, mustExist: Bool) -> Bool {
        if !FileManager.default.fileExists(atPath: url.path) { return !mustExist }
        return (try? FileManager.default.contentsOfDirectory(
            at: url, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) != nil
    }

    @discardableResult
    static func delete(group: String) throws -> Int {
        // Capture BOTH switchable globals once: a vault switch (repoint) landing mid-cascade must
        // not split the halves — files from vault A but stubs/registry purged in vault B.
        let root = AppSettings.outputFolder
        let registry = EntityRegistry.shared
        var deleted = 0
        // Enumerated BEFORE anything is removed, and the throw happens here — so a refusal leaves
        // the workspace untouched rather than half-wiped.
        let doomed = try candidates(group: group, in: root)
        for url in doomed {
            try? FileManager.default.removeItem(at: url)
            IndexStore.shared?.remove(path: url.path)   // cascade: transcript row + chunks + FTS
            deleted += 1
        }
        // The workspace's vault directory goes with its contents — otherwise a wiped workspace
        // leaves a manifest naming a scope, which the engine would still compose (to nothing) and
        // which still names the workspace on disk. Only ever the vault for THIS scope, and only one
        // that was actually discovered under the root.
        if let vault = ScriptaVault.existingVault(forScope: group, under: root).vault {
            try? FileManager.default.removeItem(at: vault)
        }
        // Knowledge cascade — named workspaces only: "" is BOTH the ungrouped bucket here and the
        // registry's GLOBAL sentinel for vocabulary (terms/termVocab treat groups == [""] as
        // visible in every workspace — people entities are not globalized), so purging "" would
        // destroy global vocabulary that feeds every workspace's ASR bias. Ungrouped files still
        // delete above; only the registry/mirror halves are skipped.
        if !group.isEmpty {
            // The binding goes with the workspace. `AppSettings.workspaceReadScopes` and
            // `workspaceReadVaults` hold the workspace's name and the FILESYSTEM PATH of the vault
            // it read, in plaintext preferences — for a feature whose scenario is "wipe Family
            // before lending the laptop", that is the residue it exists to remove. It also stops a
            // later workspace of the same name silently re-adopting a wiped one's binding.
            WorkspaceBindings.forget(group)
            registry.purge(group: group)
            // Vault stubs (Entities/<group>/) go too, toggle or no toggle — marker-gated inside.
            EntityMirror.purge(group: group, vault: root)
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
