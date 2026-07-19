import Foundation
import ScriptaCore
import ScriptaShared

/// Mirrors the entity graph into the Obsidian vault as group-foldered stub notes, so the vault's
/// backlinks/graph reflect it (I2/Fable 7). The app NEVER rewrites transcript bodies — stubs live
/// under `Entities/<Group>/` and point AT transcripts via `[[wikilinks]]`. Opt-in and default-off
/// (enabling it weakens the privacy boundary, since the vault enforces nothing).
///
/// Safety: a distinct marker (`app: call-transcriber-entity`, NOT the transcript marker) so stubs
/// are never indexed as calls; a delimited **managed region** so anything a user adds outside it is
/// preserved; and it only ever overwrites files carrying its own marker (name collisions with a
/// user's note are skipped). Idempotent: an unchanged graph re-runs to a zero diff.
enum EntityMirror {
    static let marker = "call-transcriber-entity"
    private static let begin = "<!-- calltranscriber:entities -->"
    private static let end = "<!-- /calltranscriber:entities -->"

    static func sync(store: IndexStore) {
        guard AppSettings.mirrorEnabled else { return }
        let root = AppSettings.outputFolder.appendingPathComponent("Entities", isDirectory: true)
        var groups = Set(store.groups().map(\.name))
        groups.insert("")   // ungrouped bucket
        for group in groups {
            let entities = store.entities(group: group)
            guard !entities.isEmpty else { continue }
            let folder = root.appendingPathComponent(group.isEmpty ? "Ungrouped" : safeName(group), isDirectory: true)
            try? FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
            for e in entities {
                let calls = store.callsMentioning(entityID: e.id, group: group.isEmpty ? "" : group)
                writeStub(at: folder.appendingPathComponent("\(safeName(e.name)).md"),
                          entity: e, calls: calls, group: group)
            }
        }
    }

    private static func writeStub(at url: URL, entity: (id: String, name: String, kind: String, count: Int),
                                  calls: [SearchHit], group: String) {
        let links = calls.map { "- [[\(($0.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""))]]" }
        let region = "\(begin)\n\(links.joined(separator: "\n"))\n\(end)"

        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            // Only touch our own stubs; a user note that happens to share the name is left alone.
            guard let split = Frontmatter.split(existing),
                  split.frontmatter.components(separatedBy: "\n").contains(where: {
                      $0.trimmingCharacters(in: .whitespaces) == "app: \(marker)"
                  }) else { return }
            let updated = replaceRegion(in: existing, with: region)
            if updated != existing { try? updated.write(to: url, atomically: true, encoding: .utf8) }
        } else {
            let fm = """
            ---
            app: \(marker)
            kind: \(entity.kind)
            group: "\(group)"
            ---
            """
            let content = "\(fm)\n\n# \(entity.name)\n\n\(region)\n"
            try? content.write(to: url, atomically: true, encoding: .utf8)
        }
    }

    /// Replaces the managed region between the markers, preserving everything outside it. If the
    /// markers are missing (a user deleted them), appends a fresh region rather than clobbering.
    private static func replaceRegion(in text: String, with region: String) -> String {
        guard let b = text.range(of: begin), let e = text.range(of: end) else {
            return text + "\n\n" + region + "\n"
        }
        return text.replacingCharacters(in: b.lowerBound..<e.upperBound, with: region)
    }

    private static func safeName(_ s: String) -> String {
        s.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
    }
}
