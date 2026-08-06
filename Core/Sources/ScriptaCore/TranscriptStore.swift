import Foundation
import ScriptaShared

/// Lightweight metadata for one transcript, parsed from its YAML frontmatter.
public struct TranscriptMeta: Identifiable, Hashable {
    public let url: URL
    public let title: String
    public let date: String
    public let time: String
    public let duration: String
    public let participants: [String]
    public let tags: [String]
    /// Extracted commitments (M17), each "<owner>: <text>" — "you" or a participant name as the
    /// FM named them. Empty until extraction runs (gated on `summarizeEnabled`, deferred like
    /// digest) or if the call had none.
    public var commitments: [String] = []
    /// Recorded in Conference mode (single source, unlabeled) rather than a two-party call.
    public var isConference: Bool = false
    /// The privacy/workspace partition this call belongs to. "" = ungrouped.
    public var group: String = ""

    public var id: URL { url }

    private var stamp: String { [date, time].filter { !$0.isEmpty }.joined(separator: " ") }

    public var displayTitle: String {
        if !title.isEmpty { return title }
        return stamp.isEmpty ? url.deletingPathExtension().lastPathComponent : stamp
    }
    public var subtitle: String {
        var parts: [String] = []
        if !title.isEmpty && !stamp.isEmpty { parts.append(stamp) }
        if !participants.isEmpty { parts.append(participants.joined(separator: ", ")) }
        if !duration.isEmpty { parts.append(duration) }
        return parts.joined(separator: " · ")
    }
}

/// Reads app-authored transcripts from the configured output folder.
public enum TranscriptStore {

    /// Every app-authored transcript under `root`, across BOTH layouts, newest first.
    ///
    /// This is what every reading surface should call. `list(in:)` below is the single-directory
    /// primitive and sees only what is directly in the folder it is given — which was the whole
    /// app's view of its own corpus, and would have become an empty one the moment a transcript
    /// moved into a vault (Doc 4 §7). The audit of that move traced 21 surfaces to this one
    /// function, every one of them failing to ZERO rather than to an error: the calls list, the
    /// menu, Meetings, concept backfill, the MCP server, the retention pruner.
    ///
    /// Both layouts, for the same reason `IndexBuilder.reconcile` reads both: during a migration a
    /// transcript is in exactly one of them, and a reader that knows only one place reports the
    /// other half of the corpus as missing.
    ///
    /// The two location sets cannot overlap — the root listing is non-recursive and vault
    /// transcripts are nested — so nothing is deduplicated here. If that ever stops being true this
    /// needs a dedupe, or a call appears twice in every list in the app.
    public static func list(under root: URL) -> [TranscriptMeta] {
        let (locations, _) = ScriptaVault.transcriptLocations(under: root)
        // Failures are DELIBERATELY not surfaced here: this feeds display surfaces, where showing
        // what could be read beats showing nothing. The callers that must not act on a partial set
        // — `WorkspaceDeleter`, `IndexBuilder`'s removal pass — ask for the failures themselves and
        // refuse. Splitting it that way keeps "I could not look" load-bearing exactly where acting
        // on it would destroy something.
        return locations.flatMap { list(in: $0) }
            .sorted { ($0.date, $0.time) > ($1.date, $1.time) }
    }

    /// All app-authored transcripts directly in `folder`, or `nil` when the folder could not be
    /// read. Non-recursive.
    ///
    /// For a caller that must not treat "I could not look" as "there is nothing here" — and must
    /// not establish those as two SEPARATE reads either. `WorkspaceDeleter` called `list(in:)` and
    /// then a second, independent readability probe: if the listing failed and the probe then
    /// succeeded, no failure was recorded and the wipe offered "Delete 0 calls". One read, one
    /// answer, so the thing proved is the thing acted on.
    public static func listOrFail(in folder: URL) -> [TranscriptMeta]? {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey],
            options: [.skipsHiddenFiles]
        ) else { return nil }
        return entries
            .filter { $0.pathExtension == "md" }
            .compactMap(meta(of:))
            .sorted { ($0.date, $0.time) > ($1.date, $1.time) }
    }

    /// All app-authored transcripts directly in `folder`, newest first. Non-recursive.
    public static func list(in folder: URL) -> [TranscriptMeta] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { $0.pathExtension == "md" }
            .compactMap(meta(of:))   // nil for files without our marker
            .sorted { ($0.date, $0.time) > ($1.date, $1.time) }   // newest first, from frontmatter
    }

    public static func body(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Frontmatter metadata for a single transcript, or nil if it isn't an app-authored file.
    /// Cached by (path, mtime): list() runs on the main thread from several views, and the
    /// reader re-resolves the selection per invalidation — neither should re-read files.
    public static func meta(of url: URL) -> TranscriptMeta? {
        let mtime = (try? url.resourceValues(forKeys: [.contentModificationDateKey]))?
            .contentModificationDate ?? .distantPast
        cacheLock.lock()
        if let cached = metaCache[url.path], cached.mtime == mtime {
            let meta = cached.meta
            cacheLock.unlock()
            return meta
        }
        cacheLock.unlock()
        let parsed = parseMeta(url)
        cacheLock.lock()
        metaCache[url.path] = (mtime, parsed)
        cacheLock.unlock()
        return parsed
    }

    private static var metaCache: [String: (mtime: Date, meta: TranscriptMeta?)] = [:]
    private static let cacheLock = NSLock()

    // MARK: - Frontmatter parsing

    /// Frontmatter lives in the first bytes — reading whole transcripts to list them made
    /// every Calls/Home visit scale with total library size.
    private static let headByteCount = 4096

    private static func parseMeta(_ url: URL) -> TranscriptMeta? {
        guard let head = headText(of: url) else { return nil }
        var split = Frontmatter.split(head)
        if split == nil, head.utf8.count >= headByteCount - 4 {
            // Frontmatter longer than the head (rare) — fall back to a full read.
            split = (try? String(contentsOf: url, encoding: .utf8)).flatMap(Frontmatter.split)
        }
        guard let split, Frontmatter.hasOwnerMarker(split.frontmatter) else { return nil }
        let fm = split.frontmatter
        func field(_ key: String) -> String { Frontmatter.field(fm, key) }
        func list(_ key: String) -> [String] { Frontmatter.list(fm, key) }

        return TranscriptMeta(
            url: url,
            title: field("title"),
            date: field("date"),
            time: field("time"),
            duration: field("duration"),
            participants: list("participants"),
            tags: list("tags").filter { $0 != TranscriptWriter.ownerMarker },
            commitments: list("commitments"),
            isConference: field("mode") == "conference",
            group: field("group")
        )
    }

    /// First bytes of the file, decoded leniently (a cut mid-character only mangles the tail,
    /// which is past the frontmatter we parse).
    private static func headText(of url: URL) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let data = try? handle.read(upToCount: headByteCount) else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
