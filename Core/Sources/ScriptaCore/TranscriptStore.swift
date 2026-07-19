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

    /// All app-authored transcripts in `folder`, newest first.
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
