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
        /// The set was known, but some of it could not be removed. Reported AFTER the fact — unlike
        /// `incomplete`, this one cannot be a refusal, because the rest is already gone.
        case survived([String])

        var errorDescription: String? {
            switch self {
            case .incomplete(let reasons):
                return "Cannot list every file in this workspace, so a wipe cannot be shown to be "
                    + "complete: \(reasons.joined(separator: "; ")). Refusing rather than deleting "
                    + "part of it and reporting success — for a privacy wipe an incomplete result "
                    + "is worse than none, because nothing afterwards would say it was incomplete."
            case .survived(let reasons):
                return "The wipe ran, but \(reasons.count) item(s) could not be removed and are "
                    + "still on disk: \(reasons.joined(separator: "; ")). Everything else in this "
                    + "workspace was deleted. Do not treat this workspace as wiped."
            }
        }
    }

    /// Everything one wipe will do, resolved ONCE.
    ///
    /// `candidates`, `collateral` and `delete` each ran their own `existingVault` scan, so the tree
    /// whose contents the operator was shown was not provably the tree that got removed — a vault
    /// appearing, vanishing or changing between the three made the count a description of a
    /// different state than the action. And `collateral` reported `(0, 0)` when its own scan failed,
    /// so a transient listing error turned the disclosure into "nothing else" for an action whose
    /// next step is `removeItem` on a directory tree.
    ///
    /// One scan, one plan, and the plan is what gets confirmed and then executed.
    struct Plan {
        let group: String
        /// The transcripts to remove, deduplicated.
        let calls: [URL]
        /// The workspace's vault, when it has one. Removed entire.
        let vault: URL?
        /// Uploaded documents inside that vault.
        let documents: Int
        /// Everything else inside it — hidden files included, since the tree goes.
        let other: Int
    }

    /// Resolve the whole wipe. Throws when anything could not be listed, so a plan is either
    /// complete or absent — never a lower bound presented as a total.
    static func plan(group: String, in root: URL = AppSettings.outputFolder) throws -> Plan {
        let located = ScriptaVault.existingVault(forScope: group, under: root)
        let calls = try candidates(group: group, in: root, vault: located)
        let counts = try collateral(vault: located.vault)
        return Plan(group: group, calls: calls, vault: located.vault,
                    documents: counts.documents, other: counts.other)
    }

    /// Files that would be deleted for `group` ("" = ungrouped) — drives the confirmation count.
    ///
    /// Throws when any location is unreadable. The count this feeds is the operator's evidence that
    /// the wipe covered everything, so a number derived from a partial listing is the failure.
    private static func candidates(group: String, in root: URL,
                                   vault located: (vault: URL?, failures: [String])) throws -> [URL] {
        var failures: [String] = []
        var found: [URL] = []

        // ONE READ PER LOCATION, and its own success is what is recorded. This used to list the
        // directory and then probe its readability SEPARATELY: a listing that failed followed by a
        // probe that succeeded recorded no failure at all, and the wipe offered "Delete 0 calls" —
        // the lying wipe, reached through the gap between two reads of the same folder.
        if let flat = TranscriptStore.listOrFail(in: root) {
            found += flat.filter { $0.group == group }.map(\.url)
        } else {
            failures.append("\(root.lastPathComponent) could not be listed")
        }

        // The vault layout: LOCATION is the partition, so everything under this workspace's vault
        // belongs to it and no `group:` is consulted. That is the point of §7 — a transcript's
        // workspace stops being a field that can disagree with where the file is. The vault is
        // resolved by `plan` and passed in, so the directory counted is the directory deleted.
        failures += located.failures
        if let vault = located.vault {
            let transcripts = ScriptaVault.transcripts(inVaultAt: vault)
            // A DISCOVERED VAULT ALWAYS HAS THIS DIRECTORY — `ScriptaVault.write()` creates it — so
            // its absence means it was removed, not that the workspace has no calls yet. Read as
            // "empty", a vault whose subtree lost its grant produced zero candidates and zero
            // failures for a workspace full of calls.
            if let inVault = TranscriptStore.listOrFail(in: transcripts) {
                found += inVault.map(\.url)
            } else {
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
    private static func collateral(vault: URL?) throws -> (documents: Int, other: Int) {
        guard let vault else { return (0, 0) }
        let layout = ScriptaVault(rootOfExistingVault: vault)
        let manager = FileManager.default

        func files(under directory: URL) -> Set<String>? {
            // NO `.skipsHiddenFiles`. `delete` removes the tree, so a dotfile is destroyed just as
            // surely as a visible one — `.obsidian/`, `.git/`, a compose run's hidden index — and
            // excluding them made the disclosure a strict subset of the destruction again, one
            // commit after that was supposed to be fixed.
            guard let walker = manager.enumerator(at: directory,
                                                  includingPropertiesForKeys: [.isRegularFileKey],
                                                  options: []) else { return nil }
            var out: Set<String> = []
            for case let url as URL in walker
            where (try? url.resourceValues(forKeys: [.isRegularFileKey]))?.isRegularFile == true {
                out.insert(url.standardizedFileURL.path)
            }
            return out
        }
        // A directory that is absent has nothing in it; one that cannot be WALKED is unknown, and
        // an unknown count under an action that removes the tree is the disclosure failing quietly.
        func known(_ directory: URL) throws -> Set<String> {
            if !manager.fileExists(atPath: directory.path) { return [] }
            guard let found = files(under: directory) else {
                throw WipeError.incomplete(["\(directory.lastPathComponent) could not be walked"])
            }
            return found
        }

        let everything = try known(vault)
        let documents = try known(layout.references)
        // Transcripts are already in the call count the operator confirms; the manifest is this
        // app's own. Everything else is what they have not been told about yet.
        let transcripts = try known(layout.transcripts)
        let manifest = layout.manifestURL.standardizedFileURL.path
        let other = everything.subtracting(documents).subtracting(transcripts).subtracting([manifest])
        return (documents.count, other.count)
    }


    /// Execute a plan. Takes the SAME resolution the operator confirmed rather than recomputing it,
    /// so the tree removed is the tree they were shown.
    @discardableResult
    static func delete(_ plan: Plan) async throws -> Int {
        let group = plan.group
        // Capture BOTH switchable globals once: a vault switch (repoint) landing mid-cascade must
        // not split the halves — files from vault A but stubs/registry purged in vault B.
        let root = AppSettings.outputFolder
        let registry = EntityRegistry.shared
        var deleted = 0
        let doomed = plan.calls
        // COUNTED ONLY IF IT WENT. `try?` discarded the error while the count and the index removal
        // both proceeded, so a locked or permission-denied transcript stayed on disk, vanished from
        // the index — putting it beyond `reconcile`'s reach — and was reported to the operator as
        // wiped. For a privacy feature that is the worst of the three outcomes.
        var undeleted: [String] = []
        for url in doomed {
            do {
                try FileManager.default.removeItem(at: url)
                IndexStore.shared?.remove(path: url.path)   // cascade: transcript row + chunks + FTS
                deleted += 1
            } catch {
                undeleted.append("\(url.lastPathComponent): \(error.localizedDescription)")
            }
        }
        // The workspace's vault directory goes with its contents — otherwise a wiped workspace
        // leaves a manifest naming a scope, which the engine would still compose (to nothing) and
        // which still names the workspace on disk. Only ever the vault for THIS scope, and only one
        // that was actually discovered under the root.
        if let vault = plan.vault {
            // INDEX ROWS FOR THE WHOLE TREE, not just the counted calls. `removeItem` takes
            // everything under the vault, but only `doomed` had its row removed — so any `.md` the
            // indexer held and `TranscriptStore.list` skipped (it marker-gates, the indexer does
            // not) kept its full verbatim body in FTS after a privacy wipe, recoverable only if a
            // later reconcile happened to run with every listing succeeding.
            if let store = IndexStore.shared {
                let prefix = vault.standardizedFileURL.path + "/"
                for path in store.indexedPaths().keys where path.hasPrefix(prefix) {
                    store.remove(path: path)
                }
            }
            do { try FileManager.default.removeItem(at: vault) }
            catch { undeleted.append("the \(vault.lastPathComponent) vault: \(error.localizedDescription)") }
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
            // The vault is gone, so the switcher's roster is stale. `availableGroups()` folds in
            // vaults found on disk and caches the scan; without this the wiped workspace keeps
            // appearing — selectable, and pointing at nothing — until the app restarts.
            await MainActor.run { AppModel.shared.invalidateVaultWorkspaces() }
            registry.purge(group: group)
            // AND UNDER THE SLUG. `IndexBuilder` falls back to indexing and registering entities
            // under the vault's slug when no known workspace matches it — a renamed or de-listed
            // workspace — so a purge that only ever used the display name would leave those behind.
            // Purging a name that was never used is a no-op; missing one is the wipe not wiping.
            let slug = ScriptaVault.slug(group)
            if slug != group { registry.purge(group: slug) }
            // Vault stubs (Entities/<group>/) go too, toggle or no toggle — marker-gated inside.
            EntityMirror.purge(group: group, vault: root)
            if let store = IndexStore.shared {
                IndexBuilder.syncTerms(store: store, registry: registry)
            }
        }
        // CHAT HISTORY, and deliberately OUTSIDE the `!group.isEmpty` block above. That gate exists
        // because `""` is the EntityRegistry's global vocabulary sentinel, so purging it would
        // destroy terms every workspace uses. For conversations `""` is just the Ungrouped
        // workspace — a real partition with real threads — so gating this the same way would leave
        // Ungrouped's chat history behind on every wipe of it.
        //
        // Threads carry verbatim passage snippets since Phase 5, so this is the residue the "wipe
        // before lending the laptop" scenario is about. It also stops a later workspace of the same
        // name silently re-adopting them, which is the argument `WorkspaceBindings.forget` already
        // makes above and which was never applied here.
        await MainActor.run { AskModel.shared.forget(workspace: group) }
        if let store = IndexStore.shared {
            store.pruneOrphanedEntities()   // registry-independent — runs for "" wipes too
            // Truncate the WAL: the wiped calls' verbatim text must not linger in index.db-wal at
            // laptop-handoff time. (Bytes in main-DB free pages are a separate, parked decision.)
            store.checkpoint()
        }
        // THROWN LAST, after the cascade, because the rest of the wipe is already done and must
        // still complete — but the operator must not be told this workspace is clean when part of
        // it is on disk. `incomplete` is a refusal before anything is touched; this is a report
        // after everything else was.
        guard undeleted.isEmpty else { throw WipeError.survived(undeleted) }
        return deleted
    }
}
