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
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }

        return entries
            .filter { $0.pathExtension == "md" }
            .compactMap(parseMeta)   // parseMeta returns nil for files without our marker
            .sorted { ($0.date, $0.time) > ($1.date, $1.time) }   // newest first, from frontmatter
    }

    static func body(of url: URL) -> String {
        (try? String(contentsOf: url, encoding: .utf8)) ?? ""
    }

    /// Frontmatter metadata for a single transcript, or nil if it isn't an app-authored file.
    static func meta(of url: URL) -> TranscriptMeta? {
        parseMeta(url)
    }

    /// Full-text (case-insensitive) match against a transcript's contents.
    static func matches(_ meta: TranscriptMeta, query: String) -> Bool {
        let q = query.trimmingCharacters(in: .whitespaces).lowercased()
        guard !q.isEmpty else { return true }
        if meta.displayTitle.lowercased().contains(q) { return true }
        if meta.subtitle.lowercased().contains(q) { return true }
        return body(of: meta.url).lowercased().contains(q)
    }

    // MARK: - Frontmatter parsing

    private static func parseMeta(_ url: URL) -> TranscriptMeta? {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let split = Frontmatter.split(content),
              Frontmatter.hasOwnerMarker(split.frontmatter) else { return nil }
        let frontmatter = split.frontmatter

        func field(_ key: String) -> String {
            for line in frontmatter.split(separator: "\n") {
                let trimmed = line.trimmingCharacters(in: .whitespaces)
                if trimmed.hasPrefix("\(key):") {
                    return String(trimmed.dropFirst(key.count + 1))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \"[]"))
                }
            }
            return ""
        }

        func listField(_ key: String) -> [String] {
            field(key)
                .split(separator: ",")
                .map { $0.trimmingCharacters(in: CharacterSet(charactersIn: " \"")) }
                .filter { !$0.isEmpty }
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
}
