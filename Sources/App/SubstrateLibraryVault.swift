import CryptoKit
import Foundation
import ScriptaCore

/// The vaults Scripta owns, and the only ones it writes.
///
/// THE OPERATOR'S VAULTS ARE READ-ONLY TO THIS APP, and that is a boundary rather than a caution.
/// `prism`, `research`, `core-vault` and the rest live in OneDrive, are curated by hand, and are
/// composed from a manifest the app did not write. Scripta reads them through the engine and puts
/// nothing into them. What it owns is a separate corpus at a LOCAL, NON-SYNCED path, which is also
/// what Doc 3 §4 requires of the transcript half of it — and which the engine ENFORCES rather than
/// trusting: `transcript_export.assert_not_synced` refuses a destination inside any File Provider
/// root before it writes a byte, so a destination that drifts into a synced folder later fails
/// loudly instead of quietly uploading call transcripts.
///
/// `~/.substrate` is the right home for both. It is where substrate already keeps its machine-local
/// state — the scope registry, the refresh record, the pinned engine — it is a plain dotfolder in
/// `$HOME` rather than under `Library/CloudStorage/*` (where macOS mounts OneDrive, Dropbox, Google
/// Drive and Box) or `Library/Mobile Documents/com~apple~CloudDocs` (iCloud Drive, including the
/// folders "Desktop & Documents Folders" syncs), and it is the example the engine's own refusal
/// message names. `~/Documents` would have been the intuitive choice and is the wrong one: with
/// Desktop & Documents syncing on, macOS presents it through a File Provider with no symlink to
/// give it away — the engine measured `~/Documents/CallTranscriber/…` and its iCloud path as one
/// inode — which is exactly how the app's own transcripts folder came to be synced already.
enum SubstrateLibrary {

    /// Everything Scripta writes for the engine, under one root.
    static var root: URL {
        URL(fileURLWithPath: NSHomeDirectory(), isDirectory: true)
            .appendingPathComponent(".substrate/scripta", isDirectory: true)
    }


    /// Where an ingest's artefacts land BEFORE anything is promoted into the vault.
    ///
    /// STAGING IS NOT A TIDINESS HABIT — it is what stops one bad document freezing the whole
    /// corpus. `compose` refuses the ENTIRE scope when any single note fails to ingest ("a
    /// partially composed scope is a silently-wrong retrieval set"), so a document written straight
    /// into the vault and only then found to fail the class gate would take every other document
    /// in the library down with it, and keep taking it down until someone found the file. Running
    /// `ingest` into here first puts the same three gates — the class policy, the spine contract
    /// and A18 coverage — in front of the vault instead of behind it.
    static var staging: URL { root.appendingPathComponent("staging", isDirectory: true) }

    /// The transcript vault for one Scripta workspace. One vault per workspace, because Doc 3 §4
    /// makes the SCOPE NAME the privacy wall between them.
    static func transcriptVault(workspace: String) -> URL {
        root.appendingPathComponent("transcripts", isDirectory: true)
            .appendingPathComponent(slug(workspace).isEmpty ? "unnamed" : slug(workspace),
                                    isDirectory: true)
    }


    /// The domain every library document carries.
    ///
    /// A FLOOR, for the reason `transcript_export` states about its own: `domains` is what
    /// retrieval filters on, and NOTHING IN THE ENGINE REFUSES a note that declares none — unlike
    /// status, doc_type and confidence, which are gated. So a document whose operator-supplied
    /// domains were empty or unslugifiable would land silently unfilterable under a fully green
    /// compose.
    static let baseDomain = "library"


    // MARK: - Promoting one ingest into the vault

    /// What `promote` needs to know about an ingest that has already succeeded.
    struct Ingested {
        /// The staging directory `ingest --out` wrote.
        let out: URL
        /// The file the operator brought in. Named in the source note so the artefact can be traced
        /// back to something they recognise.
        let origin: URL
        /// Domains the operator typed, before the floor is added.
        let domains: [String]
    }

    /// Move one ingested document into `vault`, and return the source directory it now occupies.
    ///
    /// THE APP AUTHORS EXACTLY THREE VALUES, and the shape is what keeps it to three. The engine's
    /// own artefact — `document.md` — already declares `title`, `document_class`, `source_path` and
    /// `source_sha256`, because `markdown/emit.frontmatter` round-trips them so that re-ingesting
    /// the engine's own output recovers what the first pass established. What it does NOT declare
    /// is `status`, `doc_type` and `confidence`: a standalone `ingest` is lenient about the spine
    /// and never writes one, while `compose` requires status and doc_type of every note and refuses
    /// the whole scope otherwise.
    ///
    /// So something has to declare them, and `_meta.md` is the engine's own mechanism for it — the
    /// per-source metadata a passage under `<source>/passages/` inherits, "applied only when the
    /// note declares none" (`vault._source_meta`). The operator's own hand-built `ddia-2e` source
    /// is exactly this shape. Writing the values into `document.md` instead would mean EDITING THE
    /// ENGINE'S ARTEFACT, which breaks the §3b regeneration path — markdown is regenerable from
    /// raw, and a regeneration would silently drop whatever we had added.
    ///
    /// `class:` is deliberately NOT among the three. The note declares its own, chosen by the
    /// operator and written by the engine; restating it here would create a second source of truth
    /// for the one axis whose mislabelling this system cares most about.
    ///
    /// THE WORKSPACE'S VAULT, NOT A SHARED ONE (Doc 4 §7, corrected 2026-08-05). An upload used to
    /// land in a standalone `scripta-library` scope that every workspace could query — which an
    /// audit filed as a missing privacy wall and Doc 4 §8 first justified as correct-by-design for a
    /// shared core tier. Both readings were wrong for the DEFAULT: a confidential document in a
    /// shared vault is visible from every workspace that inherits it, and nothing had asked the
    /// operator whether this one was shareable.
    ///
    /// So an upload lands in the workspace, and moving it to a core vault is a deliberate promotion
    /// — the rule already chosen for notes. The unattended path can only ever write tier 3, and the
    /// default is the walled one, which is the direction a mistake should fail in.
    ///
    /// No manifest is written here: `ScriptaVault.write()` owns that, and a second writer for one
    /// file is how the two come to disagree about `inherits`.
    static func promote(_ ingested: Ingested, into vault: ScriptaVault) throws -> URL {
        let document = ingested.out.appendingPathComponent("document.md")
        let front = frontmatter(of: document)
        guard let title = front["title"], !title.isEmpty else {
            // Unreachable for an ingest that exited 0 — every class policy requires `title` — but a
            // refusal beats writing a source the next compose would fail the whole scope over.
            throw LibraryError.artefactWithoutTitle(document)
        }

        let source = vault.references
            .appendingPathComponent(sourceDirectoryName(title: title, origin: ingested.origin),
                                    isDirectory: true)
        let passages = source.appendingPathComponent("passages", isDirectory: true)

        let manager = FileManager.default
        try manager.createDirectory(at: passages, withIntermediateDirectories: true)
        let note = passages.appendingPathComponent("document.md")
        if manager.fileExists(atPath: note.path) { try manager.removeItem(at: note) }
        try manager.copyItem(at: document, to: note)
        try meta(title: title, domains: ingested.domains, origin: ingested.origin)
            .write(to: source.appendingPathComponent("_meta.md"), atomically: true, encoding: .utf8)
        try vault.write()
        return source
    }


    /// `10-reference/<name>/` — tier 2. The tier is DERIVED FROM LOCATION (`vault._tier_for`), and
    /// this is the location that says "an ingested reference source", which is what a library
    /// document is. The operator's own ingested PDFs live under `10-reference/` in core-vault.
    private static func sourceDirectoryName(title: String, origin: URL) -> String {
        // Keyed on the ORIGIN PATH, not on the content: re-ingesting an edited file has to land on
        // the same source directory and replace it, rather than mint a second one that answers
        // queries beside the first. This is the argument `transcript_export.doc_id_for_transcript`
        // makes about its own key, and it holds here for the same reason.
        let digest = SHA256.hash(data: Data(origin.standardizedFileURL.path.utf8))
            .map { String(format: "%02x", $0) }.joined().prefix(8)
        let readable = slug(title.isEmpty ? origin.deletingPathExtension().lastPathComponent : title)
        return "\(readable.isEmpty ? "document" : readable)-\(digest)"
    }

    /// The three values, each with the argument that chose it, written into the vault where the
    /// next reader will find them.
    private static func meta(title: String, domains: [String], origin: URL) -> String {
        let all = ([baseDomain] + domains.map { slug($0) }).filter { !$0.isEmpty }
        var seen = Set<String>()
        let unique = all.filter { seen.insert($0).inserted }
        return """
        ---
        title: \(scalar(title))
        status: active
        doc_type: reference
        confidence: unstated
        domains: [\(unique.joined(separator: ", "))]
        ---

        # Source metadata — written by Scripta

        The document beside this was extracted by the substrate engine, which declared its own
        `title`, `class` and `source_sha256`. Those are not restated here: this file carries only
        the three axes a standalone ingest leaves absent and `compose` requires, so there is exactly
        one declaration of each.

        `status: active` — the source is in the library and current. It says nothing about the
        content, which is the point: a document that has just been brought in has no lifecycle yet.

        `doc_type: reference` — `spine.DEFAULT_DOC_TYPE`, the vocabulary's own lenient value, chosen
        for exactly this case. The other four each assert something that may be false: `decision`
        claims something was decided, `explanation` claims the document explains, `how-to` claims a
        procedure, `digest` claims it points at atomic notes and contains none. `reference` claims
        it is lookup material, which is true of anything you brought into a library.

        `confidence: unstated` — DECLARED, not omitted, and the difference is the whole point.
        Omitting it stores `unjudged`, which asserts that nobody has judged this note. Someone did:
        the judgement is that an ingested source makes no settledness claim of its own, because
        settledness varies within it.

        Brought in from `\(origin.lastPathComponent)`.
        """
    }

    // MARK: - Reading the engine's artefact

    /// The frontmatter of a note the ENGINE wrote, in the delimiter-line, flow-list form
    /// `markdown/emit.frontmatter` emits and `markdown/reader._parse_frontmatter` reads back.
    ///
    /// Deliberately not a general YAML parser. This reads one key out of one file this app just
    /// caused to be written, in a format whose emitter documents itself as matching
    /// `ScriptaShared/Frontmatter.swift` precisely so the Swift side can read it without a second
    /// parser. Anything richer would be inventing a contract.
    private static func frontmatter(of file: URL) -> [String: String] {
        guard let text = try? String(contentsOf: file, encoding: .utf8) else { return [:] }
        var lines = text.replacingOccurrences(of: "\r\n", with: "\n").components(separatedBy: "\n")
        guard lines.first == "---" else { return [:] }
        lines.removeFirst()
        var out: [String: String] = [:]
        for line in lines {
            if line == "---" { break }
            guard let separator = line.firstIndex(of: ":") else { continue }
            let key = String(line[line.startIndex..<separator]).trimmingCharacters(in: .whitespaces)
            var value = String(line[line.index(after: separator)...])
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            out[key] = value
        }
        return out
    }

    // MARK: - Shapes the engine's parsers accept

    /// Lowercase ASCII slug — the shape `markdown/reader._DOMAIN` admits, and the one
    /// `transcript_export._slug` produces. A domain that does not match is DROPPED SILENTLY by the
    /// engine's list parser, so anything the operator types is put into this shape before it is
    /// written rather than discovered missing at query time.
    static func slug(_ text: String, limit: Int = 48) -> String {
        var out = ""
        var pendingSeparator = false
        for character in text.lowercased() {
            if character.isASCII, character.isLetter || character.isNumber {
                if pendingSeparator, !out.isEmpty { out.append("-") }
                pendingSeparator = false
                out.append(character)
            } else {
                pendingSeparator = true
            }
            if out.count >= limit { break }
        }
        while out.hasSuffix("-") { out.removeLast() }
        return out
    }

    /// A frontmatter scalar the engine's own parser reads back unchanged — the rules
    /// `transcript_export._scalar` states: quote a value containing a colon (nothing else marks
    /// where the value begins), leave one that already contains a quote alone (the parser does no
    /// unescaping), and never emit a control byte, because a frontmatter line with no colon stops
    /// the block being treated as frontmatter AT ALL and turns the whole spine into body text.
    private static func scalar(_ value: String) -> String {
        let cleaned = String(value.map { $0.isNewline || ($0.asciiValue.map { $0 < 0x20 } ?? false)
                                        ? " " : $0 })
            .trimmingCharacters(in: .whitespaces)
        if cleaned.contains("\"") { return cleaned }
        if cleaned.contains(":") || cleaned.isEmpty { return "\"\(cleaned)\"" }
        return cleaned
    }

    enum LibraryError: LocalizedError {
        case artefactWithoutTitle(URL)

        var errorDescription: String? {
            switch self {
            case .artefactWithoutTitle(let url):
                return "The engine's ingest at \(url.path) declares no title, so it cannot be "
                    + "promoted into the vault — the next compose would refuse the whole library "
                    + "over it."
            }
        }
    }
}
