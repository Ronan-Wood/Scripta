import Foundation
import ScriptaCore

extension EntityRegistry {
    private static let sharedLock = NSLock()
    private static var _shared: EntityRegistry?

    /// Shared instance rooted in the output folder (vault); lazily bound on first access, swapped
    /// only via `repoint(toFolder:)`. The lock makes the reference hand-off safe for background
    /// readers (watcher reconcile, detached enrich passes) — they snapshot it once per pass and
    /// may finish against the old instance, which is the accepted, benign staleness.
    /// Lives app-side so the registry itself (in ScriptaCore) never reads AppSettings.
    static var shared: EntityRegistry {
        sharedLock.lock(); defer { sharedLock.unlock() }
        if let existing = _shared { return existing }
        let created = EntityRegistry(url: registryURL(in: AppSettings.outputFolder))
        _shared = created
        return created
    }

    /// The one folder-change ritual: flush pending state to the old file, then rebind to the new
    /// folder's registry. Adopts whatever `.calltranscriber-registry.json` already exists there —
    /// registry-follows-vault by design (the wall is between workspaces inside a vault, not
    /// between vaults); nothing migrates from the old file.
    static func repoint(toFolder folder: URL) {
        sharedLock.lock(); defer { sharedLock.unlock() }
        _shared?.save()
        _shared = EntityRegistry(url: registryURL(in: folder))
    }

    private static func registryURL(in folder: URL) -> URL {
        folder.appendingPathComponent(".calltranscriber-registry.json")
    }

    /// The one place the confirmed-only ASR recognition bias set is composed: domain vocabulary
    /// (user-entered jargon) + confirmed aliases + term vocab, scoped to the workspace, trimmed
    /// and deduped. Recording and Quick Capture both call this — never assemble it inline, or a
    /// vocab source added here (M15's correction loop) won't reach every caller.
    static func recognitionVocab(group: String) -> [String] {
        let raw = AppSettings.domainVocabulary
            + EntityRegistry.shared.confirmedAliases(group: group)
            + EntityRegistry.shared.termVocab(group: group)
        return Array(Set(raw.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }))
    }

    /// Resolves a commitment's raw frontmatter owner string the SAME way for every caller
    /// (`IndexBuilder` when building `action_items`, `TranscriptMetadataEditor` when matching an
    /// entry to mark done) — shared so a mark-done match can never silently drift from how the
    /// row it's targeting was actually built. "you" is a sentinel, never resolved; anything else
    /// resolves ONLY against a CONFIRMED person (never allocates), falling back to the raw string.
    static func resolveCommitmentOwner(_ raw: String, group: String) -> String {
        raw.caseInsensitiveCompare("you") == .orderedSame
            ? "you" : (EntityRegistry.shared.resolveConfirmed(surface: raw, kind: "person", group: group) ?? raw)
    }
}
