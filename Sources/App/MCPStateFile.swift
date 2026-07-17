import Foundation

/// Bridges the app's active workspace to the bundled MCP server. The server is spawned by the LLM
/// client, not the app, so they share no session — instead the app writes `{activeGroup, heartbeat}`
/// here and the server reads it. A stale heartbeat means the app isn't running, and the server
/// **refuses** rather than trust a stale scope: the privacy wall binds LLM clients too, and a
/// silently-wrong active group would leak a private workspace to the model.
enum MCPStateFile {
    static var url: URL { SharedLocations.mcpState }

    static func write() {
        let state: [String: Any] = [
            "activeGroup": AppSettings.activeGroup,
            "heartbeat": Date().timeIntervalSince1970,
            // The server can't read the sandboxed app's preferences, so the output-folder
            // path is published here instead of the old shared prefs domain.
            "outputFolderPath": AppSettings.outputFolder.path,
        ]
        if let data = try? JSONSerialization.data(withJSONObject: state) {
            try? data.write(to: url, options: .atomic)
        }
    }

    private static var timer: Timer?

    /// Writes now and every 20s while the app runs. On quit the beat goes stale within the
    /// server's ~60s freshness window, at which point the server refuses.
    @MainActor static func startHeartbeat() {
        write()
        timer = Timer.scheduledTimer(withTimeInterval: 20, repeats: true) { _ in write() }
    }
}
