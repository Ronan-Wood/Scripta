import Foundation

/// A workspace, as a substrate vault on disk.
///
/// Doc 4 §7: the workspace concept retires. A vault IS the partition; a scope is what a vault
/// composes to. This type owns the layout — where a call goes, where a note goes, what the manifest
/// says — so that "which workspace does this belong to" is answered by LOCATION rather than by a
/// `group:` field and four `app:` markers that every reader had to agree about.
///
/// THE ENGINE ALREADY DERIVES TIER FROM THESE EXACT PATHS. `vault._tier_for` reads `00-operator` as
/// tier 1, `10-reference` as tier 2 and everything else as tier 3; `SubstrateLibraryVault.promote`
/// already writes the `10-reference/<source>/passages/` shape. Nothing here is a new convention —
/// it is the engine's, applied on the write side so an export step stops being needed to reach it.
///
/// LOCATION IS THE OPERATOR'S, and that is `vault.py`'s own rule: "The engine has an opinion on
/// SHAPE, none on LOCATION (Doc 2 §0)." Doc 3 §4 used to require a local, non-synced path and
/// `transcript_export.assert_not_synced` enforced it as a refusal; Doc 4 §7 withdraws both. Whether
/// a vault syncs is a consequence of where the operator put it, not a rule this app imposes — so
/// nothing here inspects File Provider roots or refuses a destination.
public struct ScriptaVault: Equatable {

    /// The vault's root directory. Everything below is relative to it.
    public let root: URL

    /// The scope this vault composes as — the manifest's `name`, and the name the engine registers.
    public let scope: String

    /// Vaults this one composes on top of, as ABSOLUTE paths.
    ///
    /// Absolute because `vault._resolve_inherit` honours an absolute entry as given and resolves
    /// anything else against the PROJECT VAULT'S PARENT — so a bare name would silently mean "a
    /// sibling directory", which is not what a curated vault in OneDrive is. The engine documents
    /// the absolute form as the supported one for exactly this case: "a cloud-synced core-vault, a
    /// NAS mount."
    public let inherits: [URL]

    /// A VAULT WITH NO NAME CANNOT BE CONSTRUCTED, and the guard is here rather than at the call
    /// sites because of what the missing one did.
    ///
    /// `URL.appendingPathComponent("")` returns the RECEIVER — measured, not assumed — so
    /// `vault(forScope: "", under: outputFolder)` produced a vault whose root WAS the operator's
    /// output folder. `""` is `AppSettings.activeGroup`'s fresh-install default and every
    /// unslugifiable name ("———", whitespace) reaches the same place, so the first launch on a new
    /// machine was the likeliest way to hit it. `write()` would then drop `.substrate.toml` at the
    /// root of the operator's folder, and §7's "delete the vault directory" would resolve to
    /// `removeItem(at: outputFolder)`.
    ///
    /// The engine refuses the same thing for the same reason — `transcript_export.scope_name` raises
    /// "workspace {!r} slugifies to nothing; give it a name" — and this side simply did not. Throwing
    /// rather than returning an optional so the reason travels with the refusal, and validating in
    /// `init` rather than in the factory so there is no second way to build the bad value.
    public init(root: URL, scope: String, inherits: [URL] = []) throws {
        let name = Self.slug(scope)
        guard !name.isEmpty else { throw VaultError.unnameableScope(scope) }
        self.root = root
        self.scope = name
        self.inherits = inherits
    }

    public enum VaultError: LocalizedError, Equatable {
        case unnameableScope(String)

        public var errorDescription: String? {
            switch self {
            case .unnameableScope(let raw):
                return "A workspace named \(raw.isEmpty ? "\"\"" : "\"\(raw)\"") has no usable "
                    + "directory or scope name — it reduces to nothing once slugified. Name the "
                    + "workspace before recording into it. (The engine refuses the same value: "
                    + "`substrate export-transcripts` raises \"slugifies to nothing; give it a "
                    + "name\".)"
            }
        }
    }

    // MARK: - Where things go

    /// Calls. `_sources/` is where every conversation-class note in the operator's vaults already
    /// lives, and `transcript_export` writes to the same place — so a transcript written here is
    /// byte-for-byte where the exporter would have put it, which is what lets the exporter be
    /// deleted rather than merely bypassed.
    public var transcripts: URL { Self.transcripts(inVaultAt: root) }

    /// The same location, for a caller that has a directory and no scope name — the indexer walking
    /// the vaults root, which must not have to construct a `ScriptaVault` (and so must not have to
    /// guess a scope) just to know where to look. One definition, so a layout change cannot move
    /// the writer without moving the reader.
    public static func transcripts(inVaultAt root: URL) -> URL {
        root.appendingPathComponent("_sources/transcripts", isDirectory: true)
    }

    /// Whether a directory is a vault: it carries a manifest. That is the only discriminator that
    /// works, because the vaults root also holds this app's OTHER directories — `Notes/`, `Files/`,
    /// `Entities/` — and a name-based check would have to be kept in step with all of them.
    public static func isVault(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(manifestName).path)
    }

    /// Every directory that may hold transcripts under `root`: the root itself, plus each vault
    /// beneath it. Second element is non-empty when discovery could not be completed.
    ///
    /// BOTH LAYOUTS, DELIBERATELY. Transcripts used to sit directly in the output folder; §7 moves
    /// them into `<root>/<scope>/_sources/transcripts/`. A reader that looked only at the new
    /// location would see every not-yet-moved transcript as deleted, and one that looked only at
    /// the old would see every moved transcript as deleted — and `IndexBuilder.reconcile` acts on
    /// "not found on disk" by REMOVING the row. Reading both is what makes the migration a window
    /// rather than a cliff.
    ///
    /// A DISCOVERY FAILURE IS REPORTED, NOT SWALLOWED, because the locations it returns would
    /// otherwise be a silent lower bound — and a lower bound is exactly what the caller must not
    /// delete against. This is `Listing`'s rule one level up: absent evidence is not evidence of
    /// absence.
    ///
    /// It lives here rather than in the indexer so it can be tested: `IndexBuilder` is in the app
    /// target and `swift test` cannot reach it, which is how two of the six Phase 0 defects
    /// survived as long as they did (Doc 4 §6).
    public static func transcriptLocations(under root: URL) -> (locations: [URL], failures: [String]) {
        let found = vaultRoots(under: root)
        return ([root] + found.vaults.map(transcripts(inVaultAt:)), found.failures)
    }

    /// The vault directories under `root`, and any failure that made the answer incomplete.
    ///
    /// Separate from `transcriptLocations` because a caller deleting a WORKSPACE needs to know
    /// which vault is which, not merely where transcripts might be — and it must be able to tell
    /// "this workspace has no vault" from "I could not look", which a `[URL]` cannot express.
    public static func vaultRoots(under root: URL) -> (vaults: [URL], failures: [String]) {
        let entries: [URL]
        do {
            entries = try FileManager.default.contentsOfDirectory(
                at: root, includingPropertiesForKeys: [.isDirectoryKey],
                options: [.skipsHiddenFiles])
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                    && error.code == NSFileReadNoSuchFileError {
            // The root itself is absent: genuinely no vaults, not a failure to look. A fresh
            // install before the first recording is exactly this.
            return ([], [])
        } catch {
            return ([], ["\(root.lastPathComponent): \(error.localizedDescription)"])
        }
        return (entries.filter(isVault), [])
    }

    /// The workspace a transcript belongs to, derived from WHERE IT IS. `nil` when it is not inside
    /// a vault under `root` — the flat layout, where the frontmatter `group:` is still the answer.
    ///
    /// Doc 4 §7 retires `group:` as the partition and makes location the partition instead. This is
    /// that rule, and it is the engine's own: `vault._tier_for` derives a note's tier from its path
    /// rather than from a flag, "because core-vault holds both tier-1 and tier-2 content" — a field
    /// and a location that both claim to say where something belongs can disagree, and then every
    /// reader has to pick one.
    ///
    /// That disagreement is not hypothetical. The export gate found `app: call-transcriber-doc`
    /// sitting three lines under `class: conversation` in a note the exporter had written: the key
    /// that disproved the classification, carried through unread by the code that made it. A
    /// `group: "Personal"` on a transcript inside the `cbre` vault is the same shape, and the
    /// privacy wall is what it would be wrong about.
    ///
    /// Matched structurally rather than by prefix: the path must be exactly
    /// `<root>/<scope>/_sources/transcripts/<file>` and `<scope>` must carry a manifest. A prefix
    /// test would claim any file that happens to live below a vault, including one in a directory
    /// this app does not own.
    public static func scope(forTranscriptAt file: URL, under root: URL) -> String? {
        let transcriptDirectory = file.deletingLastPathComponent().standardizedFileURL
        let vaultRoot = transcriptDirectory.deletingLastPathComponent().deletingLastPathComponent()
        guard transcriptDirectory == transcripts(inVaultAt: vaultRoot).standardizedFileURL,
              vaultRoot.deletingLastPathComponent().standardizedFileURL == root.standardizedFileURL,
              isVault(vaultRoot)
        else { return nil }
        return vaultRoot.lastPathComponent
    }

    /// The vault for one scope beneath `root`, if it exists on disk. `nil` and a failure are
    /// different answers and both are returned, because a caller that treats "could not look" as
    /// "not there" is the lying-wipe bug.
    public static func existingVault(forScope scope: String,
                                     under root: URL) -> (vault: URL?, failures: [String]) {
        let name = slug(scope)
        guard !name.isEmpty else { return (nil, []) }
        let found = vaultRoots(under: root)
        return (found.vaults.first { $0.lastPathComponent == name }, found.failures)
    }

    /// Living notes — the operator's own words about this workspace. Tier 3: project thinking, not
    /// durable operator knowledge. Promotion to a core vault is deliberate and manual (Doc 4 §7),
    /// so nothing in the capture path can write above this tier.
    public var notes: URL { root.appendingPathComponent("02-areas", isDirectory: true) }

    /// Ingested documents, one directory per source. Tier 2 via `_tier_for`.
    public var references: URL { root.appendingPathComponent("10-reference", isDirectory: true) }

    public var manifestURL: URL { root.appendingPathComponent(Self.manifestName) }

    public static let manifestName = ".substrate.toml"

    // MARK: - The manifest

    /// Write the manifest, creating the vault's directories.
    ///
    /// REGENERATED IN PLACE on every call, not written once. `transcript_export.write_manifest` and
    /// `SubstrateLibraryVault.writeManifest` both do the same, for the reason the latter states: a
    /// manifest that exists only because an earlier version happened to write it is a vault that
    /// stops composing after a hand-clean of the folder, with nothing saying why.
    public func write() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: transcripts, withIntermediateDirectories: true)
        try manifest().write(to: manifestURL, atomically: true, encoding: .utf8)
    }

    /// `name` and `inherits` only. `reference_domains` and `reference_pins` are deliberately absent:
    /// `vault._read_manifest` validates both and records that the features reading them are
    /// deferred — "the value was declared, valid-looking, and read by nobody". Emitting a key whose
    /// consumer does not exist is how that defect happened; it is not repeated here.
    func manifest() -> String {
        var lines = [
            "# Scripta workspace vault — written by the app, regenerated in place.",
            "#",
            "# The scope name is this vault's identity: `substrate compose` registers it, and every",
            "# client asks for content by it. Renaming it here does not rename the registered scope",
            "# — `scopes.record` refuses to repoint an existing name at a different vault.",
            "name = \(Self.tomlString(scope))",
        ]
        if inherits.isEmpty {
            lines.append("inherits = []")
        } else {
            lines.append("inherits = [")
            for vault in inherits {
                lines.append("    \(Self.tomlString(vault.standardizedFileURL.path)),")
            }
            lines.append("]")
        }
        return lines.joined(separator: "\n") + "\n"
    }

    /// A TOML basic string. Backslash first — escaping it after the quote would double-escape the
    /// backslash this function just inserted.
    static func tomlString(_ value: String) -> String {
        var escaped = value.replacingOccurrences(of: "\\", with: "\\\\")
        escaped = escaped.replacingOccurrences(of: "\"", with: "\\\"")
        // A control byte inside a TOML basic string is a parse error, not a quoting problem, so it
        // is removed rather than escaped — the same stance `TranscriptWriter.sanitizeScalar` takes.
        escaped = String(escaped.map { $0.isNewline || ($0.asciiValue.map { $0 < 0x20 } ?? false)
                                       ? " " : $0 })
        return "\"\(escaped)\""
    }

    // MARK: - Naming

    /// The vault directory for a scope beneath a root.
    ///
    /// `AppSettings.outputFolder` becomes the ROOT that holds vaults rather than the folder that
    /// holds transcripts (Doc 4 §7's open question, decided 2026-08-05). The operator's existing
    /// setting keeps meaning something, and where it points — synced or not — stays their choice.
    public static func vault(forScope scope: String, under root: URL,
                             inherits: [URL] = []) throws -> ScriptaVault {
        let name = slug(scope)
        guard !name.isEmpty else { throw VaultError.unnameableScope(scope) }
        let directory = root.appendingPathComponent(name, isDirectory: true)
        // THE HARM, CHECKED DIRECTLY, not only its cause. Every destructive operation §7 describes
        // acts on `vault.root`, so a root that resolved to the containing folder would aim
        // "delete this workspace" at every workspace. The slug guard above already prevents the one
        // way that happened; this asserts the property that actually matters, so a future change to
        // path construction cannot reintroduce it quietly.
        guard directory.standardizedFileURL != root.standardizedFileURL else {
            throw VaultError.unnameableScope(scope)
        }
        return try ScriptaVault(root: directory, scope: name, inherits: inherits)
    }

    /// Lowercase ASCII slug — the shape a scope name and a directory name can both be, so the two
    /// cannot disagree. Matches `transcript_export._slug`, which is what the engine's own scope
    /// names are built with.
    public static func slug(_ text: String, limit: Int = 48) -> String {
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
}
