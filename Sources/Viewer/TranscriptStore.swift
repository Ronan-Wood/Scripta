import Foundation

/// Lightweight metadata for one transcript, parsed from its YAML frontmatter.
struct TranscriptMeta: Identifiable, Hashable {
    let url: URL
    let title: String
    let date: String
    let time: String
    let duration: String
    let participants: [String]
    let tags: [String]

    var id: URL { url }

    private var stamp: String { [date, time].filter { !$0.isEmpty }.joined(separator: " ") }

    var displayTitle: String {
        if !title.isEmpty { return title }
        return stamp.isEmpty ? url.deletingPathExtension().lastPathComponent : stamp
    }
    var subtitle: String {
        var parts: [String] = []
        if !title.isEmpty && !stamp.isEmpty { parts.append(stamp) }
        if !participants.isEmpty { parts.append(participants.joined(separator: ", ")) }
        if !duration.isEmpty { parts.append(duration) }
        return parts.joined(separator: " · ")
    }
}

/// Reads app-authored transcripts from the configured output folder.
enum TranscriptStore {

    /// All app-authored transcripts, newest first.
    static func list() -> [TranscriptMeta] {
        let folder = AppSettings.outputFolder
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: [.contentModificationDateKey], options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { $0.pathExtension == "md" }
            .compactMap(meta(of:))   // nil for files without our marker
            .sorted { ($0.date, $0.time) > ($1.date, $1.time) }   // newest first, from frontmatter
    }

    static func body(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Frontmatter metadata for a single transcript, or nil if it isn't an app-authored file.
    /// Cached by (path, mtime): list() runs on the main thread from several views, and the
    /// reader re-resolves the selection per invalidation — neither should re-read files.
    static func meta(of url: URL) -> TranscriptMeta? {
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
        let frontmatter = split.frontmatter

        func rawField(_ key: String) -> String {
            for line in frontmatter.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("\(key):") {
                    return String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
                }
            }
            return ""
        }

        func field(_ key: String) -> String {
            rawField(key).trimmingCharacters(in: CharacterSet(charactersIn: " \"[]"))
        }

        func listField(_ key: String) -> [String] {
            parseList(rawField(key))
        }

        return TranscriptMeta(
            url: url,
            title: field("title"),
            date: field("date"),
            time: field("time"),
            duration: field("duration"),
            participants: listField("participants"),
            tags: listField("tags").filter { $0 != TranscriptWriter.ownerMarker }
        )
    }

    /// Parses a frontmatter flow list. Quoted items are taken verbatim — a "Last, First" name
    /// is ONE participant, not two; unquoted values (hand-edited files) fall back to commas.
    static func parseList(_ raw: String) -> [String] {
        var value = raw.trimmingCharacters(in: .whitespaces)
        if value.hasPrefix("[") { value.removeFirst() }
        if value.hasSuffix("]") { value.removeLast() }
        guard value.contains("\"") else {
            return value.split(separator: ",")
                .map { $0.trimmingCharacters(in: .whitespaces) }
                .filter { !$0.isEmpty }
        }
        var items: [String] = []
        var current = ""
        var inQuote = false
        for ch in value {
            if ch == "\"" {
                if inQuote {
                    let item = current.trimmingCharacters(in: .whitespaces)
                    if !item.isEmpty { items.append(item) }
                    current = ""
                }
                inQuote.toggle()
            } else if inQuote {
                current.append(ch)
            }
        }
        return items
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
