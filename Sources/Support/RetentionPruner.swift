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
                  hasTranscriptFilename(url),
                  isAppAuthored(url),
                  let date = fileDate(url),
                  date < cutoff
            else { continue }
            try? fileManager.removeItem(at: url)
        }
    }

    /// Matches the "<Title> — yyyy-MM-dd HHmm[ (n)]" filename shape `TranscriptWriter.uniqueURL`
    /// produces. A user's own note can carry the marker text but won't carry this name.
    private static func hasTranscriptFilename(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        return name.range(of: #" — \d{4}-\d{2}-\d{2} \d{4}( \(\d+\))?$"#,
                          options: .regularExpression) != nil
    }

    /// Confirms the marker sits on its own line inside the leading frontmatter block — a note
    /// that merely quotes the marker in its body can never match.
    private static func isAppAuthored(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2048)) ?? Data()
        guard let text = String(data: head, encoding: .utf8) else { return false }
        var lines = text.components(separatedBy: .newlines)[...]
        guard lines.popFirst()?.trimmingCharacters(in: .whitespaces) == "---" else { return false }
        for line in lines {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            if trimmed == "---" || trimmed == "..." { return false }   // frontmatter ended without the marker
            if trimmed == "app: \(TranscriptWriter.ownerMarker)" { return true }
        }
        return false
    }

    private static func fileDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }
}
