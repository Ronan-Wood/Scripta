import Foundation
import ScriptaShared

/// Writes one hand-authored note into a workspace vault's `02-areas/`, carrying the spine the engine
/// requires.
///
/// THE FIELD KNOWLEDGE LIVES HERE, NOT IN THE OPERATOR'S HEAD. That is the whole reason this type
/// exists — see `NoteSpine` for the measurement. A note is otherwise refused twice before it
/// composes, by an engine the writer never sees, after they have already written it.
///
/// IT IS NOT AN EDITOR. It creates a note and never opens, rewrites or deletes one: the file belongs
/// to the operator the moment it lands, and Obsidian is a better editor than anything this app would
/// grow. `write` is the only entry point and it refuses rather than overwrites.
public enum NoteWriter {

    /// Why a note was not written. Every case is surfaced to the operator verbatim — a Create button
    /// that silently does nothing is the failure `AppModel.createWorkspace` records having shipped.
    public enum Failure: LocalizedError, Equatable {
        case titleEmpty
        case titleUnusable(String)
        case unknownDocType(String)
        case unknownConfidence(String)
        case alreadyExists(String)
        case noSharedVault
        case vaultMissing(String)

        public var errorDescription: String? {
            switch self {
            case .titleEmpty:
                return "A note needs a title. It becomes the note's filename and its heading."
            case .titleUnusable(let title):
                return "“\(title)” has no letters or numbers in it, so it cannot become a filename. "
                     + "Use a title with some ASCII text in it."
            case .unknownDocType(let value):
                return "“\(value)” is not a doc_type this engine accepts. The vocabulary is "
                     + NoteSpine.docTypes.map(\.value).sorted().joined(separator: ", ") + "."
            case .unknownConfidence(let value):
                return "“\(value)” is not a confidence this engine accepts. The vocabulary is "
                     + NoteSpine.confidences.map(\.value).sorted().joined(separator: ", ") + "."
            case .alreadyExists(let name):
                return "This vault already has a note called “\(name)”. Open that note and edit it, "
                     + "or choose a different title — two notes answering one question is the state "
                     + "the engine refuses a whole scope over."
            case .noSharedVault:
                return "No shared vault is set, so there is nowhere to put a note every scope "
                     + "inherits. Point Settings → Shared vault at it first."
            case .vaultMissing(let path):
                return "\(path) is not there any more, so the note has nowhere to go. Re-pick it "
                     + "under Settings → Shared vault."
            }
        }
    }

    /// Create the note and return where it landed.
    ///
    /// REFUSES ON COLLISION rather than uniquifying, which is where it deliberately parts from
    /// `TranscriptWriter.uniqueURL`. A transcript is stamped with the minute it started, so a
    /// collision there is two recordings in one minute and a `(2)` suffix is the honest answer. Two
    /// notes given the same title are almost always the operator meaning to edit the first one, and
    /// silently creating `thing-2.md` beside `thing.md` manufactures exactly the duplicate the
    /// engine refuses whole scopes over (`vault.py`, the byte-identity guard).
    ///
    /// - Parameters:
    ///   - vault: the destination vault's ROOT. The tier folder is created if absent.
    ///   - destination: which vault this is, and therefore which folder — and so which TIER, since
    ///     `vault._tier_for` reads the tier off the path.
    ///   - confidence: `nil` for a workspace note, which declares no judgement. Required to be a
    ///     legal value when given.
    ///   - domains: free list; empty is omitted rather than written as `[]`.
    @discardableResult
    public static func write(intoVaultAt vault: URL, destination: NoteDestination = .workspace,
                             title rawTitle: String, docType: String,
                             confidence: String? = nil, domains: [String] = [],
                             body rawBody: String) throws -> URL {
        let title = rawTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !title.isEmpty else { throw Failure.titleEmpty }

        // VALIDATED EVEN THOUGH THE PICKER ONLY OFFERS VALID ONES. The check costs nothing and the
        // alternative is a note that reaches the vault and refuses the scope at the next compose —
        // a failure that arrives detached from the action that caused it.
        guard NoteSpine.docTypes.contains(where: { $0.value == docType }) else {
            throw Failure.unknownDocType(docType)
        }
        if let confidence, !NoteSpine.confidences.contains(where: { $0.value == confidence }) {
            throw Failure.unknownConfidence(confidence)
        }

        // THE DIRECTORY HAS TO STILL BE THERE. The workspace vault is created by this app moments
        // earlier and is known-good; the shared one is a path stored in settings that can go stale
        // between being chosen and being written to — the folder renamed, the drive unmounted, the
        // sync client moved it. Creating `00-operator/` under a path that no longer exists would
        // rebuild the vault as an empty shell somewhere nothing composes.
        //
        // IT DOES NOT CHECK FOR A MANIFEST, and an earlier version did — which refused core-vault,
        // the one vault this destination exists for. `vault.resolve_vaults` states why: "core-vault
        // has no manifest (it is the root) so recursion bottoms out there." A manifest declares what
        // a vault INHERITS; the root of the chain inherits nothing and so declares nothing. Testing
        // for one tests whether a directory is a PROJECT vault, which is the opposite of the
        // question here.
        //
        // Whether any scope inherits this vault is the condition that decides if the note is ever
        // served — and that is the ENGINE's answer, not a property of the folder, so it is asked
        // where the roster lives rather than guessed at here.
        if destination == .shared {
            var isDirectory: ObjCBool = false
            let exists = FileManager.default.fileExists(atPath: vault.path,
                                                        isDirectory: &isDirectory)
            guard exists, isDirectory.boolValue else { throw Failure.vaultMissing(vault.path) }
        }

        // The slug is what makes the filename safe: it keeps ASCII letters and digits and drops
        // everything else, so a title of "../../etc/passwd" reduces to "etc-passwd" and cannot
        // traverse. Containment is asserted below anyway rather than argued from that.
        let slug = ScriptaVault.slug(title)
        guard !slug.isEmpty else { throw Failure.titleUnusable(title) }

        let folder = vault.appendingPathComponent(destination.folderName, isDirectory: true)
        let url = folder.appendingPathComponent("\(slug).md")
        guard url.deletingLastPathComponent().standardizedFileURL == folder.standardizedFileURL else {
            throw Failure.titleUnusable(title)
        }
        guard !FileManager.default.fileExists(atPath: url.path) else {
            throw Failure.alreadyExists("\(slug).md")
        }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        let contents = document(title: title, docType: docType, confidence: confidence,
                                domains: domains, body: rawBody)
        // `.withoutOverwriting` ALONE, and the pairing is not available: Foundation traps outright
        // on `[.atomic, .withoutOverwriting]` — "withoutOverwriting is not supported with atomic" —
        // because atomic writes a temporary and renames it over the target, which is the clobber
        // this must not do. Exclusivity is the property worth having; it makes the check above
        // atomic rather than advisory, so two Create taps racing cannot both pass `fileExists` and
        // have the loser replace the winner's note.
        //
        // The cost is that a write interrupted mid-way leaves a partial note, which would compose as
        // a truncated one. `notes.py` takes the same O_EXCL trade and answers it the same way.
        do {
            try Data(contents.utf8).write(to: url, options: .withoutOverwriting)
        } catch {
            try? FileManager.default.removeItem(at: url)
            throw error
        }
        return url
    }

    /// The file's text: frontmatter, then the title as the H1, then whatever was written.
    ///
    /// THE HEADING AND THE `title:` ARE THE SAME VALUE, which `TranscriptSpineParityTests` had to
    /// assert for transcripts after they came apart once — a note carrying its title in prose and
    /// withholding it as data leaves every reader either regexing the heading or falling back to the
    /// filename.
    ///
    /// No `app:` owner marker, and that is deliberate. The marker authorises deletion — the
    /// retention pruner keys on it — and a note the operator wrote is not this app's to delete. A
    /// call is the app's; a note is seeded by the app and owned by whoever wrote it.
    static func document(title: String, docType: String, confidence: String? = nil,
                         domains: [String] = [], body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        var front = [
            "title: \(yaml(title))",
            "status: \(NoteSpine.status)",
            "doc_type: \(docType)",
        ]
        if let confidence { front.append("confidence: \(confidence)") }
        // OMITTED WHEN EMPTY, not written as `domains: []`. An empty list is a declared claim that
        // this note belongs to no subject at all, and `domains` is what cross-scope filtering runs
        // on — the absent case and the empty case answer differently.
        let cleaned = domains.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                             .filter { !$0.isEmpty }
        if !cleaned.isEmpty {
            front.append("domains: [\(cleaned.joined(separator: ", "))]")
        }
        var text = "---\n" + front.joined(separator: "\n") + "\n---\n\n# \(title)\n"
        if !trimmed.isEmpty { text += "\n\(trimmed)\n" }
        return text
    }

    /// A double-quoted YAML scalar. Quoted ALWAYS rather than only when it looks necessary: a title
    /// beginning `[`, containing `: `, or reading `yes` each parse as something other than a string,
    /// and deciding which titles need it per-title is the check that gets one case wrong.
    private static func yaml(_ value: String) -> String {
        "\"" + value.replacingOccurrences(of: "\\", with: "\\\\")
                    .replacingOccurrences(of: "\"", with: "\\\"") + "\""
    }
}
