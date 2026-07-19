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
}
