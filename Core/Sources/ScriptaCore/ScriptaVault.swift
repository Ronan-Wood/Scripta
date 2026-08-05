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

    public init(root: URL, scope: String, inherits: [URL] = []) {
        self.root = root
        self.scope = scope
        self.inherits = inherits
    }

    // MARK: - Where things go

    /// Calls. `_sources/` is where every conversation-class note in the operator's vaults already
    /// lives, and `transcript_export` writes to the same place — so a transcript written here is
    /// byte-for-byte where the exporter would have put it, which is what lets the exporter be
    /// deleted rather than merely bypassed.
    public var transcripts: URL {
        root.appendingPathComponent("_sources/transcripts", isDirectory: true)
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
                             inherits: [URL] = []) -> ScriptaVault {
        ScriptaVault(root: root.appendingPathComponent(slug(scope), isDirectory: true),
                     scope: slug(scope), inherits: inherits)
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
