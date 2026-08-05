import Foundation
import ScriptaShared

/// Finds app-authored transcripts that belong to no workspace, and assigns them one.
///
/// THE ENGINE REFUSES AND NAMES THE REMEDY; THIS IS THE REMEDY. `transcript_export.export_workspace`
/// aborts the WHOLE export when any transcript carries no `group:` — deliberately, because filing an
/// untagged call under the workspace being exported asserts a claim nothing on disk supports, and
/// dropping it leaves a call in no scope at all. Its message ends "add `group: "<workspace>"` to
/// each transcript's frontmatter", and until now the only way to do that was to hand-edit YAML.
///
/// So one missing field could block every downstream corpus permanently, and the app — which owns
/// the folder grant and knows the workspaces — offered nothing. The refusal is right. Having no way
/// to act on it is not.
///
/// **This assigns; it does not guess.** Nothing here infers a workspace from a filename, a date or
/// the active selection. The caller supplies the name because the operator is the only one who
/// knows it — which is the same reason the exporter refuses in the first place.
public enum TranscriptGroupRepair {

    /// One transcript with no workspace, and what a chooser needs to show about it.
    public struct Untagged: Identifiable, Equatable {
        public let url: URL
        public let title: String
        public let date: String
        public var id: URL { url }
    }

    /// Every app-authored transcript directly in `folder` that declares no `group:`.
    ///
    /// NOT RECURSIVE, matching `RetentionPruner`'s own rule and for the same reason: the output
    /// folder may live inside a real vault, and `Notes/`, `Files/` and `Entities/` are this app's
    /// other artefact types — none of them transcripts. The owner marker is checked too, so a
    /// foreign markdown file that happens to sit at the root is never rewritten.
    public static func untagged(in folder: URL) -> [Untagged] {
        let entries = (try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles])) ?? []
        return entries
            .filter { $0.pathExtension == "md" }
            .compactMap { url -> Untagged? in
                guard let text = try? String(contentsOf: url, encoding: .utf8),
                      let split = Frontmatter.split(text),
                      Frontmatter.hasOwnerMarker(split.frontmatter),
                      group(in: split.frontmatter)?.isEmpty ?? true else { return nil }
                return Untagged(url: url,
                                title: value("title", in: split.frontmatter) ?? url.deletingPathExtension().lastPathComponent,
                                date: value("date", in: split.frontmatter) ?? "")
            }
            .sorted { $0.date == $1.date ? $0.title < $1.title : $0.date < $1.date }
    }

    /// Write `group:` into one transcript, in place.
    ///
    /// Inserted immediately BEFORE the `app:` line rather than appended or placed by offset: every
    /// app-authored transcript has that line — the marker check above guarantees it — so the anchor
    /// always exists, and the resulting key order matches what `TranscriptWriter` emits for a call
    /// recorded with a workspace. A repaired file is then byte-comparable with a freshly written
    /// one instead of merely equivalent.
    ///
    /// Replaces an existing empty `group:` rather than adding a second, because two keys of one
    /// name is a frontmatter whose meaning depends on which parser reads it.
    public static func assign(_ workspace: String, to url: URL) throws {
        let raw = TranscriptWriter.sanitizeScalar(workspace)
        guard !raw.isEmpty else { throw RepairError.emptyWorkspace }

        let content = try String(contentsOf: url, encoding: .utf8)
        guard let split = Frontmatter.split(content),
              Frontmatter.hasOwnerMarker(split.frontmatter) else {
            throw RepairError.notATranscript(url)
        }

        var lines = split.frontmatter.components(separatedBy: "\n")
        lines.removeAll { $0.trimmingCharacters(in: .whitespaces).hasPrefix("group:") }
        let line = "group: \"\(raw)\""
        if let anchor = lines.firstIndex(where: { $0.trimmingCharacters(in: .whitespaces).hasPrefix("app:") }) {
            lines.insert(line, at: anchor)
        } else {
            lines.append(line)   // unreachable while the marker check above holds
        }

        let result = "---\n" + lines.joined(separator: "\n") + "\n---\n" + split.body
        try result.write(to: url, atomically: true, encoding: .utf8)
    }

    public enum RepairError: LocalizedError {
        case emptyWorkspace
        case notATranscript(URL)

        public var errorDescription: String? {
            switch self {
            case .emptyWorkspace:
                return "A workspace name is required. The ungrouped workspace has no name, and "
                    + "`substrate export-transcripts` refuses a workspace whose name slugifies to "
                    + "nothing — so an untagged call cannot be repaired by filing it as ungrouped."
            case .notATranscript(let url):
                return "\(url.lastPathComponent) is not a Scripta transcript."
            }
        }
    }

    // MARK: - Frontmatter reads

    /// The declared `group:`, or nil when the key is absent. An EMPTY string is a present-but-empty
    /// key, which the exporter treats identically to absence — both are returned as untagged above,
    /// and the distinction is preserved here only so this function means what its name says.
    private static func group(in frontmatter: String) -> String? { value("group", in: frontmatter) }

    private static func value(_ key: String, in frontmatter: String) -> String? {
        for line in frontmatter.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("\(key):") else { continue }
            var v = String(trimmed.dropFirst(key.count + 1)).trimmingCharacters(in: .whitespaces)
            if v.count >= 2, v.hasPrefix("\""), v.hasSuffix("\"") { v = String(v.dropFirst().dropLast()) }
            return v
        }
        return nil
    }
}
