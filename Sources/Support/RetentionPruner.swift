import Foundation

/// Deletes transcripts older than the configured retention window, when enabled.
///
/// SAFETY: the output folder may live inside a real Obsidian vault, so this must never
/// touch anything the app didn't create. It only considers `.md` files whose filename matches
/// the shape `TranscriptWriter.uniqueURL` produces AND whose leading frontmatter block carries
/// the `app: call-transcriber` marker on its own line, and it never recurses into subdirectories.
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
                  RetentionGate.hasTranscriptFilename(url),
                  RetentionGate.isAppAuthored(url),
                  let date = fileDate(url),
                  date < cutoff
            else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    private static func fileDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }
}
