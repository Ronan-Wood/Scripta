import Foundation
import ScriptaShared

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
    /// Always a slug.
    public let scope: String

    /// The workspace's name as the operator wrote it. Kept BESIDE the slug rather than derived from
    /// it, because slugging is one-way: "Alpha Beta" and "Alpha-Beta" both reduce to `alpha-beta`,
    /// and telling them apart is the whole point of recording it. Defaulting this from `scope`
    /// stored a slug where a name belonged and compared the two — the same namespace confusion the
    /// index had, reproduced inside the guard written to fix it.
    public let workspace: String

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
    /// The engine refuses the same thing for the same reason — an unslugifiable name raises
    /// "workspace {!r} slugifies to nothing; give it a name" — and this side simply did not. Throwing
    /// rather than returning an optional so the reason travels with the refusal, and validating in
    /// `init` rather than in the factory so there is no second way to build the bad value.
    public init(root: URL, scope: String, inherits: [URL] = []) throws {
        let name = Self.slug(scope)
        guard !name.isEmpty else { throw VaultError.unnameableScope(scope) }
        self.root = root
        self.scope = name
        self.workspace = scope
        self.inherits = inherits
    }

    /// A vault that is already on disk, for a caller that has its directory and only needs the
    /// layout. Skips the name guard deliberately: the guard exists to stop a NEW vault resolving to
    /// its own parent, and a directory discovered by `vaultRoots` has already proved it is one.
    public init(rootOfExistingVault root: URL) {
        self.root = root
        self.scope = root.lastPathComponent
        // The name the vault records for itself, or the directory's if it predates that key.
        self.workspace = Self.workspace(ofVaultAt: root) ?? root.lastPathComponent
        self.inherits = []
    }

    public enum VaultError: LocalizedError, Equatable {
        case unnameableScope(String)
        case nameCollidesWithExistingDirectory(String, URL)
        case vaultBelongsToAnotherWorkspace(String, String)

        public var errorDescription: String? {
            switch self {
            case .unnameableScope(let raw):
                return "A workspace named \(raw.isEmpty ? "\"\"" : "\"\(raw)\"") has no usable "
                    + "directory or scope name — it reduces to nothing once slugified. Name the "
                    + "workspace before recording into it. (The engine refuses the same value: "
                    + "the engine raises \"slugifies to nothing; give it a "
                    + "name\".)"
            case .nameCollidesWithExistingDirectory(let raw, let directory):
                return "A workspace named \"\(raw)\" would use the folder \(directory.path), which "
                    + "already exists and is not a Scripta vault. Refusing to adopt it — this app "
                    + "deletes a workspace by deleting its folder, so taking over a folder it did "
                    + "not create would put whatever is already in there inside a future wipe. "
                    + "Choose a different workspace name."
            case .vaultBelongsToAnotherWorkspace(let asked, let owner):
                return "The folder a workspace named \"\(asked)\" would use already belongs to "
                    + "\"\(owner)\" — the two names reduce to the same directory. Sharing it would "
                    + "put both workspaces' calls in one vault, and deleting either would delete "
                    + "the other's. Choose a name that differs by more than punctuation or case."
            }
        }
    }

    // MARK: - Where things go

    /// Calls. `_sources/` is where every conversation-class note in the operator's vaults already
    /// lives, and the engine composes from the same place — so a transcript written here is
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

    /// The key that marks a vault as this app's to write and to delete.
    ///
    /// `isVault` answers "is this a substrate vault" and that is NOT the same question as "may we
    /// overwrite this manifest and, on a wipe, remove this whole directory". `outputFolder` is
    /// documented as the root that HOLDS vaults, so pointing it somewhere that already contains
    /// substrate vaults is the intended-looking configuration — and a workspace whose slug matched
    /// one of them would have had `write()` overwrite that vault's hand-written manifest on EVERY
    /// recording (destroying its `inherits`, `reference_domains`, `reference_pins`) long before
    /// anyone pressed delete, at which point `WorkspaceDeleter` would remove the vault entire.
    ///
    /// The engine already refuses on exactly this signal and reaches the opposite conclusion from
    /// it: `cli._refuse_destructive_clean` says "a directory holding a `.substrate.toml` IS a vault
    /// whether or not this scope inherits it — refusing to delete it". A manifest is evidence of
    /// value, not of ownership, and this side was reading it as the latter.
    /// Where a call goes when its workspace names nothing.
    ///
    /// THE FRESH-INSTALL PATH, and it used to be the flat output folder. `AppSettings.activeGroup`
    /// is `""` until the operator names a workspace, a vault must have a name, and the alternatives
    /// were to invent one, refuse to record, or write flat. Writing flat lost nothing readable — every
    /// reader covers that location — but it left the call in NO VAULT, therefore in no scope,
    /// therefore unanswerable by the engine that is supposed to be the product.
    ///
    /// `default` is a name, not an invention of the operator's intent: it says "no workspace was
    /// chosen" in the one place that has to hold a name, and a call filed here is as queryable as
    /// any other. `TranscriptGroupRepair.file` moves it out when the operator decides where it
    /// belongs.
    public static let defaultScope = "default"

    /// The manifest key naming the file that must vouch for this vault before the engine will
    /// answer from it. Generic on the engine's side (`guard.py`); Scripta's state file on ours.
    static let guardKey = "guard_state"

    /// The manifest key naming the shared entity roster the engine resolves mentions against.
    static let identityKey = "identity"

    /// The roster's filename, at the output-folder root beside every workspace vault — shared, not
    /// per-vault, because identity is one thing across workspaces.
    static let registryName = ".calltranscriber-registry.json"

    static let ownershipKey = "scripta_workspace_vault"

    /// Whether a directory is a substrate vault at all: it carries a manifest. Read-only discovery
    /// only — never a licence to write or delete. Use `isAppVault` for that.
    public static func isVault(_ directory: URL) -> Bool {
        FileManager.default.fileExists(atPath: directory.appendingPathComponent(manifestName).path)
    }

    /// Whether THIS APP created the vault, and may therefore rewrite its manifest or delete it.
    ///
    /// Parsed rather than inferred from the directory's name or position: a vault the operator made
    /// by hand can sit anywhere, including under the vaults root, and nothing about where it is says
    /// whose it is.
    public static func isAppVault(_ directory: URL) -> Bool {
        manifestValue(ownershipKey, in: directory) == "true"
    }

    /// The workspace name this vault was created for, in the operator's own casing.
    ///
    /// Recorded because the DIRECTORY only knows the slug, and slugging is lossy: "CBRE",
    /// "C.B.R.E." and any two names sharing a 48-character prefix all reduce to one directory. A
    /// vault that stored only the slug would be re-adopted by the second workspace, and
    /// `WorkspaceDeleter` takes every transcript in a vault with no `group:` filter — so wiping one
    /// workspace would delete the other's calls.
    public static func workspace(ofVaultAt directory: URL) -> String? {
        manifestValue(workspaceKey, in: directory)
    }

    static let workspaceKey = "scripta_workspace"

    /// One `key = value` from a manifest, unquoted. A real key match rather than a prefix test:
    /// `hasPrefix(key) && hasSuffix("true")` accepted `scripta_workspace_vault = false # true`, and
    /// any key merely STARTING with the ownership key — which is a poor gate for the one check
    /// standing between a foreign vault and adoption.
    static func manifestValue(_ key: String, in directory: URL) -> String? {
        guard let manifest = try? String(
            contentsOf: directory.appendingPathComponent(manifestName), encoding: .utf8)
        else { return nil }
        for line in manifest.components(separatedBy: "\n") {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard !trimmed.hasPrefix("#"), let equals = trimmed.firstIndex(of: "=") else { continue }
            guard trimmed[trimmed.startIndex..<equals].trimmingCharacters(in: .whitespaces) == key
            else { continue }
            var value = trimmed[trimmed.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            if value.count >= 2, value.hasPrefix("\""), value.hasSuffix("\"") {
                value = String(value.dropFirst().dropLast())
            }
            return value
        }
        return nil
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
                at: root, includingPropertiesForKeys: [.isDirectoryKey, .isSymbolicLinkKey],
                options: [.skipsHiddenFiles])
        } catch let error as NSError where error.domain == NSCocoaErrorDomain
                    && error.code == NSFileReadNoSuchFileError {
            // The root itself is absent: genuinely no vaults, not a failure to look. A fresh
            // install before the first recording is exactly this.
            return ([], [])
        } catch {
            return ([], ["\(root.lastPathComponent): \(error.localizedDescription)"])
        }
        // `isAppVault`, NOT `isVault`. Everything downstream of this — the pruner's delete list, the
        // wipe's `removeItem`, the indexer's removal pass — inherits whatever this filter admits,
        // and `isVault` proves only that SOME manifest exists. A hand-made vault of the operator's
        // sitting under the vaults root passed it, so the wipe would have removed it whole and the
        // pruner would have deleted inside it. The adoption guard in `vault(forScope:)` was gated on
        // ownership; this, the path every destructive caller actually reaches the directory through,
        // was not.
        // SYMLINKS ARE SKIPPED, not followed. `isVault`/`isAppVault` resolve through
        // `fileExists`, so a link under the vaults root pointing at a real vault passed as one —
        // and the two sides then disagreed about what they were acting on: the pruner and the wipe
        // deleted files THROUGH the link inside the operator's real vault, while `removeItem` on
        // the vault root removed only the link. Over-deleting where it must not, under-deleting
        // where the count said it had.
        return (entries.filter { entry in
            let isLink = (try? entry.resourceValues(forKeys: [.isSymbolicLinkKey]))?
                .isSymbolicLink ?? false
            return !isLink && isAppVault(entry)
        }, [])
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
        // Lowercased for the same reason `existingVault` compares that way: the
        // directory's casing is the filesystem's, and callers reason in slug space.
        return vaultRoot.lastPathComponent.lowercased()
    }

    /// The vault for one scope beneath `root`, if it exists on disk. `nil` and a failure are
    /// different answers and both are returned, because a caller that treats "could not look" as
    /// "not there" is the lying-wipe bug.
    public static func existingVault(forScope scope: String,
                                     under root: URL) -> (vault: URL?, failures: [String]) {
        let name = slug(scope)
        guard !name.isEmpty else { return (nil, []) }
        let found = vaultRoots(under: root)
        // CASE-INSENSITIVE, because the two sides of this comparison come from different places:
        // `name` is a lowercase slug, while `lastPathComponent` is whatever is on disk — and APFS
        // is case-insensitive by default, so a workspace whose vault landed in a pre-existing
        // `Notes/` or `CBRE/` is reported by `contentsOfDirectory` with THAT casing. Compared
        // case-sensitively the lookup missed its own vault, and `WorkspaceDeleter` then found zero
        // candidates, offered "Delete 0 calls" and reported success — the lying wipe, reached
        // through a different door than the one 1f450a6 closed.
        return (found.vaults.first { $0.lastPathComponent.lowercased() == name.lowercased() },
                found.failures)
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
    /// REGENERATED IN PLACE on every call, not written once. This writer and
    /// `SubstrateLibraryVault.writeManifest` both do the same, for the reason the latter states: a
    /// manifest that exists only because an earlier version happened to write it is a vault that
    /// stops composing after a hand-clean of the folder, with nothing saying why.
    public func write() throws {
        let manager = FileManager.default
        try manager.createDirectory(at: transcripts, withIntermediateDirectories: true)
        // NEVER REWRITE A MANIFEST WITH LESS THAN IT HAD. `inherits` defaults to `[]` and
        // `init(rootOfExistingVault:)` hardcodes it, so any caller that re-resolved an existing
        // vault without re-supplying the inheritance would regenerate the manifest without it —
        // destroying the operator's `inherits`, and any `reference_domains` or `reference_pins`
        // they had added by hand. That is the same destruction the ownership key exists to prevent,
        // aimed at an app-created vault instead of a foreign one.
        //
        // Regeneration still repairs a MISSING manifest, which is what it was for.
        if inherits.isEmpty, manager.fileExists(atPath: manifestURL.path) { return }
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
            // OWNERSHIP, DECLARED. Scripta rewrites this manifest on every recording and deletes
            // this directory whole when the workspace is wiped; both are only ever safe on a vault
            // it created. Remove this line by hand and the app will leave the vault alone rather
            // than adopt it — which is the intended escape hatch, not a way to break it.
            "\(Self.ownershipKey) = true",
            // The workspace's own name, because the directory only knows the slug and slugging is
            // lossy: "CBRE" and "C.B.R.E." reduce to one directory, as does any pair sharing a
            // 48-character prefix. Without this the second workspace re-adopts the first's vault,
            // and `WorkspaceDeleter` takes every transcript in a vault with no `group:` filter — so
            // wiping one would delete the other's calls.
            "\(Self.workspaceKey) = \(Self.tomlString(workspace))",
            // THE PRIVACY WALL, DECLARED WHERE THE ENGINE CAN SEE IT. A workspace vault holds call
            // transcripts, and before §7 the app's own MCP server was what kept a model out of them
            // — it refused unless Scripta was running and this workspace was the active one. Moving
            // the calls into a vault the engine composes made them reachable by any local process,
            // because the wall lived in the server being retired rather than in the corpus.
            //
            // `guard.py` reads this key and refuses the scope unless the file below reports a fresh
            // heartbeat naming this scope. The engine learns nothing about Scripta: it enforces a
            // shape a vault asked for. An operator who removes this line gets an unguarded vault,
            // which is a choice they can make and not one that happens by accident.
            "\(Self.guardKey) = \(Self.tomlString(SharedLocations.mcpState.path))",
            // IDENTITY, SHARED ACROSS EVERY WORKSPACE (operator, 2026-08-07). One roster behind all
            // of them means the same person found in a call and in a project note is the same id,
            // which is the entire point of having ids — a registry per workspace would make
            // "Alexandra" a different person in each.
            //
            // The engine READS this and never writes it. The rules are authored here, they survive
            // an index rebuild because they are not in the index, and `compose` re-derives who each
            // note mentions from them every time.
            "\(Self.identityKey) = \(Self.tomlString(root.appendingPathComponent(Self.registryName).path))",
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
        // A VAULT NEVER ADOPTS A DIRECTORY IT DID NOT CREATE.
        //
        // `slug` lowercases, APFS is case-insensitive by default, and the vaults root also holds
        // this app's `Notes/`, `Files/` and `Entities/` directories — so a workspace named "Notes"
        // produced `<root>/notes`, WHICH IS `<root>/Notes`. Measured on this machine: `mkdir notes`
        // beside an existing `Notes` fails because they are one directory. The workspace name is a
        // free-text field, so this is reachable by typing it.
        //
        // What followed was not a naming collision, it was data loss. `write()` would drop a
        // manifest into the living-notes directory, `transcriptLocations` would then see it as a
        // vault, and `WorkspaceDeleter.delete` would `removeItem` the whole thing — every note in
        // it — while the confirmation counted calls and reported no collateral, because collateral
        // counts the VAULT'S subdirectories and the notes were never in one.
        //
        // Checked as the general property rather than against a list of reserved names: any
        // pre-existing directory is one the operator made for their own reasons, and a list would
        // have to be kept in step with every folder this app or its user ever adds. A directory the
        // app created is a vault and carries a manifest, so re-resolving an existing workspace
        // still passes.
        // A SUBSTRATE VAULT THIS APP DID NOT CREATE IS REFUSED TOO, not just a non-vault directory.
        // A manifest is evidence that a directory has value, not evidence of whose it is — and
        // adopting one means overwriting its manifest on every recording and removing it entire on
        // a wipe.
        if FileManager.default.fileExists(atPath: directory.path) {
            guard isAppVault(directory) else {
                throw VaultError.nameCollidesWithExistingDirectory(scope, directory)
            }
            // AND IT MUST BE THIS WORKSPACE'S. Slugging is lossy, so a second workspace can reduce
            // to the first's directory and would otherwise be handed a vault full of someone else's
            // calls — which the wipe then takes wholesale, since the vault branch of `candidates`
            // applies no `group:` filter. A vault written before this key existed reports `nil` and
            // is accepted, so upgrading does not orphan one.
            if let owner = workspace(ofVaultAt: directory), owner != scope {
                throw VaultError.vaultBelongsToAnotherWorkspace(scope, owner)
            }

        }
        // The RAW name, not `name`: `init` slugs it for `scope` and keeps the original for
        // `workspace`. Passing the slug here set both from one value and put a slug
        // where the display name belonged.
        return try ScriptaVault(root: directory, scope: scope, inherits: inherits)
    }

    /// Lowercase ASCII slug — the shape a scope name and a directory name can both be, so the two
    /// cannot disagree. Matches the engine's own slug rule, which is what its scope
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
