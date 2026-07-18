import Foundation

/// Deletes transcripts older than the configured retention window, when enabled.
///
/// SAFETY: the output folder may live inside a real Obsidian vault, so this must never
/// touch anything the app didn't create. It only considers `.md` files whose filename matches
/// the shape `TranscriptWriter.uniqueURL` produces AND whose leading frontmatter block carries
/// the `app: call-transcriber` marker on its own line, and it never recurses into subdirectories.
enum RetentionPruner {

    /// The settings the pruner reads. Injected rather than pulled from `AppSettings` directly so the
    /// pruning logic (and its vault-safety guarantees) stays in the dependency-free layer and can be
    /// exercised by the host-less test bundle. The app builds this from `AppSettings` — see the
    /// zero-argument `pruneIfNeeded()` in `RetentionPruner+Live.swift`.
    struct Config {
        var enabled: Bool
        var days: Int
        var folder: URL
    }

    static func pruneIfNeeded(_ config: Config) {
        guard config.enabled else { return }
        let days = max(1, config.days)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let folder = config.folder
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
