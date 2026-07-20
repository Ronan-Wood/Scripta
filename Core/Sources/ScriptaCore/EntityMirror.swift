import Foundation
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
public enum EntityMirror {
    static let marker = "call-transcriber-entity"
    private static let begin = "<!-- calltranscriber:entities -->"
    private static let end = "<!-- /calltranscriber:entities -->"

    /// UNGATED: writes stubs into `vault` unconditionally. The app must never call this directly —
    /// consent lives in the app-side `sync(store:)` bridge, which checks the opt-in setting first.
    /// Named so an ungated call site reads as deliberate instead of overload-shadowing the bridge.
    public static func syncUnconditionally(store: IndexStore, vault: URL) {
        let root = vault.appendingPathComponent("Entities", isDirectory: true)
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

    /// Deletes the wiped group's stub notes — the mirror half of the workspace-wipe cascade.
    /// Runs regardless of the mirror toggle: stubs written while mirroring was enabled must not
    /// survive a wipe just because the setting was later turned off (deleting our own files is
    /// always safe; only WRITING into the vault is consent-gated). Reuses the write-side safety:
    /// only files carrying this app's entity marker are touched, so a user note sharing the
    /// folder or a name survives; the folder is removed only if left empty.
    public static func purge(group: String, vault: URL) {
        let safe = safeName(group)
        guard !group.isEmpty, !safe.isEmpty, safe != ".", safe != ".." else { return }
        let folder = vault.appendingPathComponent("Entities", isDirectory: true)
            .appendingPathComponent(safe, isDirectory: true)
        let fm = FileManager.default
        for url in (try? fm.contentsOfDirectory(at: folder, includingPropertiesForKeys: nil)) ?? [] {
            guard url.pathExtension == "md",
                  let content = try? String(contentsOf: url, encoding: .utf8),
                  isOwnStub(content) else { continue }
            try? fm.removeItem(at: url)
        }
        // Atomic "remove only if empty": rmdir(2) fails on a non-empty directory, so a file
        // landing after the stub sweep (sync client, user save) can never be swept up the way a
        // recursive removeItem could. Finder metadata is cleared first so a browsed-but-otherwise
        // empty folder still goes (a surviving folder would leak the wiped workspace's name).
        try? fm.removeItem(at: folder.appendingPathComponent(".DS_Store"))
        _ = rmdir(folder.path)
    }

    /// The ownership predicate shared by the write path (overwrite safety) and the wipe path
    /// (delete safety). Quote-tolerant because Obsidian's properties editor re-serializes
    /// `app: marker` as `app: "marker"` — those are still our stubs, for updating AND for wiping.
    static func isOwnStub(_ content: String) -> Bool {
        guard let split = Frontmatter.split(content) else { return false }
        return split.frontmatter.components(separatedBy: "\n")
            .contains { Frontmatter.isMarkerLine($0, marker: marker) }
    }

    private static func writeStub(at url: URL, entity: (id: String, name: String, kind: String, count: Int),
                                  calls: [SearchHit], group: String) {
        let links = calls.map { "- [[\(($0.path as NSString).lastPathComponent.replacingOccurrences(of: ".md", with: ""))]]" }
        let region = "\(begin)\n\(links.joined(separator: "\n"))\n\(end)"

        if let existing = try? String(contentsOf: url, encoding: .utf8) {
            // Only touch our own stubs; a user note that happens to share the name is left alone.
            guard isOwnStub(existing) else { return }
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
