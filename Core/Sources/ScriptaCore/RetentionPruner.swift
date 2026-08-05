import Foundation
import ScriptaShared

/// Deletes transcripts older than the configured retention window, when enabled.
///
/// SAFETY: the output folder may live inside a real Obsidian vault, so this must never
/// touch anything the app didn't create. It only considers `.md` files whose filename matches
/// the shape `TranscriptWriter.uniqueURL` produces AND whose leading frontmatter block carries
/// the `app: call-transcriber` marker on its own line.
///
/// **STILL NOT A RECURSIVE WALK.** Doc 4 §7 moves transcripts into per-workspace vaults, so the
/// pruner now visits each vault's `_sources/transcripts/` as well as the output root — but it
/// arrives at those directories by asking `ScriptaVault.transcriptLocations` which vaults exist,
/// never by descending into whatever it finds. The distinction is the safety property: an
/// `enumerator` over a folder that sits inside someone's real vault would eventually reach their
/// notes, and only the two content gates would stand between them and deletion. A directory is
/// visited here only if it carries a manifest this app wrote.
///
/// Without this the feature would have failed SILENTLY rather than loudly: the shallow listing
/// still succeeds on a vaults root, finds no `.md`, deletes nothing, and reports nothing — so
/// retention would simply stop happening, with transcripts accumulating past the window the
/// operator configured and no symptom anywhere.
public enum RetentionPruner {

    /// The settings the pruner reads. Injected rather than pulled from `AppSettings` directly so the
    /// pruning logic (and its vault-safety guarantees) stays in the dependency-free layer and can be
    /// exercised by the host-less test bundle. The app builds this from `AppSettings` — see the
    /// zero-argument `pruneIfNeeded()` in `RetentionPruner+Live.swift`.
    public struct Config {
        var enabled: Bool
        var days: Int
        var folder: URL

        public init(enabled: Bool, days: Int, folder: URL) {
            self.enabled = enabled; self.days = days; self.folder = folder
        }
    }

    public static func pruneIfNeeded(_ config: Config) {
        guard config.enabled else { return }
        let days = max(1, config.days)
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        let fileManager = FileManager.default

        // The output root and each workspace vault's transcript directory. NOT a recursive walk —
        // every location is one this app declared by writing a manifest into it.
        let (locations, _) = ScriptaVault.transcriptLocations(under: config.folder)
        for folder in locations {
            // contentsOfDirectory is shallow (non-recursive) by design.
            guard let entries = try? fileManager.contentsOfDirectory(
                at: folder,
                includingPropertiesForKeys: [.creationDateKey, .contentModificationDateKey],
                options: [.skipsHiddenFiles]
            ) else { continue }

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
    }

    private static func fileDate(_ url: URL) -> Date? {
        let values = try? url.resourceValues(forKeys: [.creationDateKey, .contentModificationDateKey])
        return values?.creationDate ?? values?.contentModificationDate
    }
}
