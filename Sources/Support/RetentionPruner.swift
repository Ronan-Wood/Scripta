import Foundation

/// Deletes transcripts older than the configured retention window, when enabled.
///
/// SAFETY: the output folder may live inside a real Obsidian vault, so this must never
/// touch anything the app didn't create. It only considers `.md` files whose frontmatter
/// carries the `app: call-transcriber` marker (the authoritative signal), and it never
/// recurses into subdirectories.
enum RetentionPruner {

    static func pruneIfNeeded() {
        guard AppSettings.retentionEnabled else { return }
        let days = max(1, AppSettings.retentionDays)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let folder = AppSettings.outputFolder
        let fileManager = FileManager.default

        // contentsOfDirectory is shallow (non-recursive) by design.
        guard let entries = try? fileManager.contentsOfDirectory(
            at: folder,
            includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return }

        for url in entries {
            guard url.pathExtension == "md",
                  isAppAuthored(url),
                  let date = fileDate(url),
                  date < cutoff
            else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Confirms the file carries our frontmatter marker before it can ever be deleted.
    private static func isAppAuthored(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2048)) ?? Data()
        guard let text = String(data: head, encoding: .utf8) else { return false }
        return text.contains("app: \(TranscriptWriter.ownerMarker)")
    }

    private static func fileDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }
}
