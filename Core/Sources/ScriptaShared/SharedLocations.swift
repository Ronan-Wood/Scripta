import Foundation

/// Where the app keeps its own support files: the team App Group container (see
/// `Scripta.entitlements` for why the group is kept).
public enum SharedLocations {
    /// macOS App Group IDs are team-ID-prefixed (unlike iOS's "group." form). Deliberately
    /// brand-neutral: this ID must outlive any app rename.
    public static let appGroupID = "6CTH5M9UWZ.com.ronanwood.calltranscriber"

    /// The shared support directory inside the group container. Falls back to the legacy
    /// Application Support path when the group container is unavailable (a build signed
    /// without the entitlement) so a dev build never dead-ends.
    public static var supportDirectory: URL {
        let dir: URL
        if let group = FileManager.default
            .containerURL(forSecurityApplicationGroupIdentifier: appGroupID) {
            dir = group.appendingPathComponent("Library/Application Support/CallTranscriber",
                                               isDirectory: true)
        } else {
            dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                .appendingPathComponent("CallTranscriber", isDirectory: true)
        }
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir
    }

    /// The app's retrieval index.
    public static var indexDB: URL { supportDirectory.appendingPathComponent("index.db") }

    /// The heartbeat 0.1.0 to 0.3.5 published for the engine's workspace guard, and the file every
    /// app-written `guard_state` names.
    public static let retiredHeartbeatName = "mcp-state.json"

    /// Delete that heartbeat. Nothing writes or reads it now, and it held the last output folder
    /// and workspace name.
    public static func removeRetiredHeartbeat(in directory: URL = supportDirectory) {
        try? FileManager.default.removeItem(at: directory.appendingPathComponent(retiredHeartbeatName))
    }
}
