import Foundation
import ScriptaShared

/// The pure predicates that decide whether the retention pruner may delete a file — the guard that
/// keeps a user's surrounding Obsidian vault from ever losing a file the app didn't create. Kept
/// dependency-free (only `Frontmatter`) so it is unit-testable in isolation (see `Tests/`).
public enum RetentionGate {
    /// Matches the "<Title> — yyyy-MM-dd HHmm[ (n)]" filename shape `TranscriptWriter.uniqueURL`
    /// produces. A user's own note can carry the marker text but won't carry this name.
    public static func hasTranscriptFilename(_ url: URL) -> Bool {
        let name = url.deletingPathExtension().lastPathComponent
        return name.range(of: #" — \d{4}-\d{2}-\d{2} \d{4}( \(\d+\))?$"#,
                          options: .regularExpression) != nil
    }

    /// Confirms the owner marker sits on its own line inside the leading frontmatter block — a note
    /// that merely quotes the marker in its body can never match. Reads only the first 2 KB, so a
    /// file whose frontmatter block runs longer than that fails closed (is treated as not app-authored
    /// and therefore never pruned).
    public static func isAppAuthored(_ url: URL) -> Bool {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return false }
        defer { try? handle.close() }
        let head = (try? handle.read(upToCount: 2048)) ?? Data()
        // Decode leniently (like TranscriptStore.headText): a 2 KB cut can split a multi-byte
        // character, and a strict decode would then wrongly treat a genuine transcript as
        // not-app-authored. The marker check is still exact, so no foreign file can match.
        guard let split = Frontmatter.split(String(decoding: head, as: UTF8.self)) else { return false }
        return Frontmatter.hasOwnerMarker(split.frontmatter)
    }
}
