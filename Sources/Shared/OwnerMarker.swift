import Foundation

/// The `app: call-transcriber` frontmatter marker value that identifies files this app owns.
/// Lives in the shared layer so retrieval code (compiled into the app, the MCP, and the eval
/// harness) can reference it without dragging in the writer/UI.
enum OwnerMarker {
    static let value = "call-transcriber"
}
