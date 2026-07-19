import Foundation

/// Locations the app and the MCP server must agree on. Once the app is sandboxed, its
/// Application Support and preferences live inside a private container the server can't see —
/// so everything shared moves to the team App Group container, which both binaries are
/// entitled to. Compiled into both targets (Sources/Shared).
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

    /// The retrieval index. The app writes it; the MCP server reads it (WAL allows both).
    public static var indexDB: URL { supportDirectory.appendingPathComponent("index.db") }

    /// The app→server handoff: `{outputFolderPath, activeGroup, heartbeat}`, heartbeat-refreshed
    /// while the app runs. The server refuses index queries on a stale beat (privacy wall).
    public static var mcpState: URL { supportDirectory.appendingPathComponent("mcp-state.json") }
}
