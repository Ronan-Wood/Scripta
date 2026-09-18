import XCTest
@testable import ScriptaCore
@testable import ScriptaShared

/// The vault layout, and the manifest the engine has to be able to read.
///
/// The layout assertions are not stylistic: `vault._tier_for` derives a note's tier from these exact
/// path prefixes, so `10-reference` vs `10-references` is the difference between a document
/// composing as tier 2 and composing as project content.
final class ScriptaVaultTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("ScriptaVaultTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    // MARK: - Layout

    /// Tier is derived from location by `vault._tier_for`, so these prefixes are a contract with the
    /// engine rather than a naming preference.
    func testLayoutMatchesTheTiersTheEngineDerives() throws {
        let vault = try ScriptaVault(root: root, scope: "cbre")
        XCTAssertTrue(vault.transcripts.path.hasSuffix("/_sources/transcripts"))
        XCTAssertTrue(vault.notes.path.hasSuffix("/02-areas"))
        XCTAssertTrue(vault.references.path.hasSuffix("/10-reference"))
        XCTAssertTrue(vault.manifestURL.path.hasSuffix("/.substrate.toml"))
    }

    /// `outputFolder` becomes the root that holds vaults, one per scope (Doc 4 §7's open question,
    /// decided 2026-08-05) — so the operator's existing setting keeps meaning something.
    func testAScopeGetsItsOwnVaultDirectoryUnderTheRoot() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        XCTAssertEqual(vault.root.lastPathComponent, "cbre")
        XCTAssertEqual(vault.scope, "cbre")
        XCTAssertEqual(vault.root.deletingLastPathComponent().standardizedFileURL,
                       root.standardizedFileURL)
    }

    /// The directory name and the scope name are one slug, so they cannot disagree — the failure
    /// `SubstrateLibraryModel` had when a name and a location were held as two values.
    func testTheDirectoryNameAndTheScopeNameAreTheSameSlug() throws {
        for name in ["CBRE", "cbre", "C.B.R.E.", "  CBRE  "] {
            let vault = try ScriptaVault.vault(forScope: name, under: root)
            XCTAssertEqual(vault.scope, vault.root.lastPathComponent, "disagreed for \(name)")
        }
        XCTAssertEqual(try ScriptaVault.vault(forScope: "Work Calls", under: root).scope, "work-calls")
    }

    // MARK: - Finding transcripts across both layouts

    /// The wipe this closes: a vaults root is READABLE and holds no `.md` — scope directories have
    /// no extension — so `IndexBuilder`'s listing succeeded with zero files, its unreadable-folder
    /// guard never fired, and the removal pass deleted every indexed row. At launch, and on every
    /// 2-second watcher fire.
    func testAVaultsRootReportsTheVaultsTranscriptDirectory() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()

        let (locations, failures) = ScriptaVault.transcriptLocations(under: root)
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertTrue(locations.contains { $0.standardizedFileURL == vault.transcripts.standardizedFileURL },
                      "the vault's transcripts were not discovered: \(locations)")
    }

    /// Both layouts at once, which is the only state in which a migration is safe: reading only the
    /// new location makes every not-yet-moved transcript look deleted, reading only the old makes
    /// every moved one look deleted, and `reconcile` acts on "not on disk" by REMOVING the row.
    func testTheFlatRootIsStillAListedLocation() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()

        let (locations, _) = ScriptaVault.transcriptLocations(under: root)
        XCTAssertTrue(locations.contains { $0.standardizedFileURL == root.standardizedFileURL },
                      "the pre-§7 flat layout must still be read: \(locations)")
    }

    /// The app writes four kinds of directory into this root. Only a manifest makes one a vault —
    /// a name-based check would need keeping in step with all of them.
    func testOnlyDirectoriesWithAManifestCountAsVaults() throws {
        for name in ["Notes", "Files", "Entities"] {
            try FileManager.default.createDirectory(
                at: root.appendingPathComponent(name, isDirectory: true),
                withIntermediateDirectories: true)
        }
        let (locations, failures) = ScriptaVault.transcriptLocations(under: root)
        XCTAssertTrue(failures.isEmpty, "\(failures)")
        XCTAssertEqual(locations.count, 1, "only the root itself should be listed: \(locations)")
    }

    /// A discovery failure is REPORTED, not swallowed — the locations would otherwise be a silent
    /// lower bound, and a lower bound is exactly what the caller must not delete against.
    func testAnUnreadableRootIsReportedRatherThanReturningJustTheRoot() throws {
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: locked.path) }

        let (_, failures) = ScriptaVault.transcriptLocations(under: locked)
        XCTAssertFalse(failures.isEmpty, "an unreadable root must report a failure")
    }

    /// "This workspace has no vault" and "I could not look" are different answers, and a caller
    /// that collapses them is the lying wipe: `WorkspaceDeleter` would report zero files, delete
    /// nothing, show success, and the operator would hand over the laptop.
    func testAnAbsentVaultAndAnUnreadableRootAreDifferentAnswers() throws {
        // Absent: no failure, no vault. An ordinary state — a workspace not yet recorded into.
        let absent = ScriptaVault.existingVault(forScope: "nope", under: root)
        XCTAssertNil(absent.vault)
        XCTAssertTrue(absent.failures.isEmpty, "an absent vault is not a failure to look")

        // Present.
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        let found = ScriptaVault.existingVault(forScope: "cbre", under: root)
        XCTAssertEqual(found.vault?.standardizedFileURL, vault.root.standardizedFileURL)
        XCTAssertTrue(found.failures.isEmpty)

        // Unreadable: NO vault reported, but a failure that must stop any deletion.
        let locked = root.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: locked.path) }
        let blind = ScriptaVault.existingVault(forScope: "cbre", under: locked)
        XCTAssertNil(blind.vault)
        XCTAssertFalse(blind.failures.isEmpty, "an unreadable root must not read as 'no vault'")
    }

    /// An absent ROOT is genuinely no vaults — a fresh install before the first recording — and
    /// must not be reported as a failure, or every such launch would refuse operations it should
    /// simply find nothing for.
    func testAnAbsentRootIsNoVaultsRatherThanAFailure() {
        let missing = root.appendingPathComponent("never-created", isDirectory: true)
        let found = ScriptaVault.vaultRoots(under: missing)
        XCTAssertTrue(found.vaults.isEmpty)
        XCTAssertTrue(found.failures.isEmpty, "absence is not a failure to look: \(found.failures)")
    }

    // MARK: - The workspace is where the file is

    func testATranscriptInAVaultBelongsToThatVaultsScope() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        let call = vault.transcripts.appendingPathComponent("call.md")
        XCTAssertEqual(ScriptaVault.scope(forTranscriptAt: call, under: root), "cbre")
    }

    /// The flat layout still answers from frontmatter, so the caller falls back — `nil` here means
    /// "not derivable", not "no workspace".
    func testAFlatTranscriptHasNoDerivableScope() {
        let call = root.appendingPathComponent("Call — 2026-08-05 0900.md")
        XCTAssertNil(ScriptaVault.scope(forTranscriptAt: call, under: root))
    }

    /// Structural, not a prefix test. A file that merely lives somewhere below a vault — or below a
    /// directory this app does not own — must not be claimed by it.
    func testOnlyTheTranscriptDirectoryItselfCounts() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()

        // Right vault, wrong directory: a note is not a transcript.
        let note = vault.notes.appendingPathComponent("thinking.md")
        XCTAssertNil(ScriptaVault.scope(forTranscriptAt: note, under: root))

        // Nested one level deeper than the transcript directory.
        let nested = vault.transcripts.appendingPathComponent("sub/call.md")
        XCTAssertNil(ScriptaVault.scope(forTranscriptAt: nested, under: root))

        // The right shape, but the directory carries no manifest, so it is not a vault.
        let impostor = root.appendingPathComponent("notavault/_sources/transcripts/call.md")
        XCTAssertNil(ScriptaVault.scope(forTranscriptAt: impostor, under: root))
    }

    /// A vault under a DIFFERENT root is not this root's business — otherwise one operator folder
    /// could claim transcripts belonging to another.
    func testAVaultUnderAnotherRootIsNotClaimed() throws {
        let other = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: other, withIntermediateDirectories: true)
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: other)
        try vault.write()

        let call = vault.transcripts.appendingPathComponent("call.md")
        XCTAssertEqual(ScriptaVault.scope(forTranscriptAt: call, under: other), "cbre")
        XCTAssertNil(ScriptaVault.scope(forTranscriptAt: call, under: root),
                     "a vault under another root must not be claimed by this one")
    }

    // MARK: - The name that would have deleted the folder

    /// `URL.appendingPathComponent("")` RETURNS THE RECEIVER — measured, not assumed — so before
    /// this guard `vault(forScope: "", under: outputFolder)` produced a vault whose root WAS the
    /// operator's output folder. `""` is `AppSettings.activeGroup`'s fresh-install default, so a
    /// first launch was the likeliest way to reach it: `write()` would drop `.substrate.toml` at
    /// the root of their folder, and Doc 4 §7's "delete the vault directory" would resolve to
    /// `removeItem(at: outputFolder)`.
    func testAnUnnameableScopeIsRefusedRatherThanResolvingToTheRoot() {
        for name in ["", "   ", "———", "…"] {
            XCTAssertThrowsError(try ScriptaVault.vault(forScope: name, under: root),
                                 "\(name.debugDescription) must not name a vault") { error in
                XCTAssertEqual(error as? ScriptaVault.VaultError, .unnameableScope(name))
            }
            XCTAssertThrowsError(try ScriptaVault(root: root, scope: name),
                                 "the initializer must refuse it too, or there are two ways in")
        }
    }

    /// THE SAME COLLISION, BEFORE THE DIRECTORY EXISTS.
    ///
    /// The existence-based guard below cannot see this one: `Notes/`, `Files/` and `Entities/` are
    /// created lazily — on the first note saved, the first document added, the first mirror sync —
    /// so on a fresh install none of them is on disk. That window was theoretical while capture was
    /// the only thing that wrote a vault; "New workspace…" now writes one, which makes it the first
    /// action a new user takes.
    ///
    /// The fixture asserts the state the check objects to — the directory must NOT exist when the
    /// refusal fires — and the ERROR, not merely that something threw: an assertion that accepts
    /// any error passes when an unrelated guard fires and proves nothing about this one.
    func testAnAppOwnedNameIsRefusedEvenBeforeThatDirectoryExists() throws {
        for name in ["Notes", "notes", "Files", "Entities", "ENTITIES"] {
            let directory = root.appendingPathComponent(ScriptaVault.slug(name), isDirectory: true)
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                           "the fixture must reach the pre-existence state, or it tests the "
                           + "existence guard instead of this one")
            XCTAssertThrowsError(try ScriptaVault.vault(forScope: name, under: root),
                                 "\(name) is an app-owned directory and must not become a vault") {
                XCTAssertEqual($0 as? ScriptaVault.VaultError,
                               .nameReservedForAppData(name, ScriptaVault.slug(name)),
                               "it must be refused as reserved, not as some other collision")
            }
            XCTAssertFalse(FileManager.default.fileExists(atPath: directory.path),
                           "a refused name must not leave a directory behind")
        }
    }

    /// AND THE REFUSAL IS GRANDFATHERED, because one that cannot be satisfied is worse.
    ///
    /// `Notes/` is lazy, so a workspace could have taken that name first and be sitting on a real
    /// vault. Refusing unconditionally made that vault permanently unconstructible — capture stops
    /// writing to it and says so only in a log line. A vault this workspace already owns resolves.
    func testAWorkspaceThatAlreadyOwnsAReservedNameKeepsIt() throws {
        // BUILT THROUGH THE INITIALIZER, not `vault(forScope:)`, because the guard now refuses that
        // front door — which is the point. The state being grandfathered is one that could only
        // have been created BEFORE the guard existed, so a fixture that tried to create it the
        // normal way would be asserting the guard does not work.
        let directory = root.appendingPathComponent("notes", isDirectory: true)
        let existing = try ScriptaVault(root: directory, scope: "Notes")
        try existing.write()
        XCTAssertTrue(ScriptaVault.isAppVault(directory), "the fixture must reach the owned state")

        let again = try ScriptaVault.vault(forScope: "Notes", under: root)
        XCTAssertEqual(again.root.standardizedFileURL, directory.standardizedFileURL,
                       "an app vault this workspace already owns must keep resolving")
    }

    /// THE COLLISION THAT WOULD HAVE DELETED THE OPERATOR'S NOTES.
    ///
    /// `slug` lowercases and APFS is case-insensitive by default, so a workspace named "Notes"
    /// resolves to `<root>/notes` — WHICH IS `<root>/Notes`, the living-notes directory. Measured:
    /// `mkdir notes` beside an existing `Notes` fails because they are one directory. The workspace
    /// name is a free-text field, so typing it is the whole exploit.
    ///
    /// The loss was not the collision, it was what came after: a manifest dropped into the notes
    /// folder makes it a vault, and `WorkspaceDeleter.delete` removes a workspace by removing its
    /// folder — with every note in it, while the confirmation counted calls and reported no
    /// collateral, because collateral counts the vault's own subdirectories.
    func testAWorkspaceCannotAdoptADirectoryItDidNotCreate() throws {
        // `Notes`/`Files`/`Entities` are created with their REAL casing, which is the point: the
        // slug is lowercase and APFS resolves the two to one directory. The last entry is created
        // at its slugged name, the shape any other pre-existing folder collides through.
        //
        // THE EXPECTED REFUSAL DIFFERS BY NAME, and asserting "some error" instead would hide that.
        // The three app-owned names are now refused earlier, by the reserved-name guard, which
        // fires whether or not the directory is there; a folder the operator made is refused by the
        // adoption guard, which is what this test is named for. Both are correct and they are not
        // interchangeable — a reserved name reported as an adoption collision tells the operator to
        // go look for a folder that may not exist.
        for (existing, onDisk, reserved) in [("Notes", "Notes", true), ("Files", "Files", true),
                                             ("Entities", "Entities", true),
                                             ("Some Folder Of Mine", "some-folder-of-mine", false)] {
            let directory = root.appendingPathComponent(onDisk, isDirectory: true)
            try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
            try "mine".write(to: directory.appendingPathComponent("keep.md"),
                             atomically: true, encoding: .utf8)

            XCTAssertThrowsError(try ScriptaVault.vault(forScope: existing, under: root),
                                 "\(existing) must not be adopted") { error in
                switch error as? ScriptaVault.VaultError {
                case .nameReservedForAppData where reserved: break
                case .nameCollidesWithExistingDirectory where !reserved: break
                default: XCTFail("wrong error for \(existing): \(error)")
                }
            }
            // Case-insensitively too — that is the form that actually collides.
            XCTAssertThrowsError(try ScriptaVault.vault(forScope: existing.lowercased(), under: root))
            XCTAssertTrue(FileManager.default.fileExists(
                atPath: directory.appendingPathComponent("keep.md").path),
                          "the refusal must not have touched what was there")
        }
    }

    /// Re-resolving a workspace that already has a vault still works — the directory exists, but it
    /// carries a manifest, so it is one this app created.
    func testAnExistingVaultIsStillResolvable() throws {
        let first = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try first.write()
        let again = try ScriptaVault.vault(forScope: "CBRE", under: root)
        XCTAssertEqual(again.root.standardizedFileURL, first.root.standardizedFileURL)
    }

    /// A MANIFEST IS EVIDENCE OF VALUE, NOT OF OWNERSHIP.
    ///
    /// `outputFolder` is the root that holds vaults, so pointing it at a directory that already
    /// contains substrate vaults is the intended-looking configuration. Adopting one would have
    /// `write()` overwrite its hand-written manifest — `inherits`, `reference_domains`,
    /// `reference_pins` — on EVERY recording, and `WorkspaceDeleter` remove it entire on a wipe.
    /// The engine refuses on exactly this signal for exactly this reason
    /// (`cli._refuse_index_root`); this side was reading it the other way.
    func testAVaultThisAppDidNotCreateIsNotAdopted() throws {
        let curated = root.appendingPathComponent("cbre", isDirectory: true)
        try FileManager.default.createDirectory(at: curated, withIntermediateDirectories: true)
        let handWritten = """
        name = "cbre"
        inherits = ["/Users/x/vaults/core-vault"]
        reference_domains = ["work"]
        """
        try handWritten.write(to: curated.appendingPathComponent(ScriptaVault.manifestName),
                              atomically: true, encoding: .utf8)

        XCTAssertTrue(ScriptaVault.isVault(curated), "it IS a substrate vault")
        XCTAssertFalse(ScriptaVault.isAppVault(curated), "but not one this app made")
        XCTAssertThrowsError(try ScriptaVault.vault(forScope: "CBRE", under: root))
        // The refusal must not have touched the manifest it declined to adopt.
        XCTAssertEqual(try String(contentsOf: curated.appendingPathComponent(ScriptaVault.manifestName),
                                  encoding: .utf8), handWritten)
    }

    /// The app's own vaults carry the ownership key, so they stay writable and deletable.
    func testAVaultThisAppCreatedDeclaresItsOwnership() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        XCTAssertTrue(ScriptaVault.isAppVault(vault.root))
        XCTAssertTrue(try String(contentsOf: vault.manifestURL, encoding: .utf8)
            .contains("\(ScriptaVault.ownershipKey) = true"))
    }

    /// Slugging is one-way, so two different workspace names can reduce to one directory. Without
    /// the recorded name the second would be handed the first's vault — and `WorkspaceDeleter`
    /// takes every transcript in a vault with no `group:` filter, so wiping one would delete the
    /// other's calls.
    func testTwoWorkspacesCannotShareOneVault() throws {
        let first = try ScriptaVault.vault(forScope: "Alpha Beta", under: root)
        try first.write()
        XCTAssertEqual(ScriptaVault.workspace(ofVaultAt: first.root), "Alpha Beta")

        XCTAssertThrowsError(try ScriptaVault.vault(forScope: "Alpha-Beta", under: root)) { error in
            XCTAssertEqual(error as? ScriptaVault.VaultError,
                           .vaultBelongsToAnotherWorkspace("Alpha-Beta", "Alpha Beta"))
        }
        // The owner itself still resolves, including through a differently-cased spelling of the
        // SAME name — that is one workspace, not two.
        XCTAssertNoThrow(try ScriptaVault.vault(forScope: "Alpha Beta", under: root))
    }

    /// `inherits` defaults to `[]`, so a caller that re-resolved an existing vault without
    /// re-supplying the inheritance regenerated the manifest without it — destroying the operator's
    /// `inherits`, `reference_domains` and `reference_pins`. That is the destruction the ownership
    /// key exists to prevent, aimed at an app-created vault instead of a foreign one.
    func testRewritingWithoutInheritsDoesNotClobberTheManifest() throws {
        let curated = URL(fileURLWithPath: "/Users/x/vaults/cbre-vault")
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root, inherits: [curated])
        try vault.write()
        let original = try String(contentsOf: vault.manifestURL, encoding: .utf8)
        XCTAssertTrue(original.contains(curated.path), original)

        // The same vault, resolved again with no inheritance — the shape capture takes when a
        // workspace has no binding yet.
        let bare = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try bare.write()
        XCTAssertEqual(try String(contentsOf: vault.manifestURL, encoding: .utf8), original,
                       "a rewrite with no inherits must not drop the inherits already there")
    }

    /// Regeneration still repairs a manifest that is missing entirely — the case it existed for.
    func testAMissingManifestIsStillRegenerated() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        try FileManager.default.removeItem(at: vault.manifestURL)
        try vault.write()
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.manifestURL.path))
    }

    /// The ownership gate is a real key match, not a prefix/suffix test — that accepted
    /// `scripta_workspace_vault = false # true`, and any key merely starting with the ownership key.
    func testOwnershipIsParsedNotPatternMatched() throws {
        let directory = root.appendingPathComponent("faux", isDirectory: true)
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        for hostile in ["scripta_workspace_vault = false # true",
                        "scripta_workspace_vault_other = true",
                        "# scripta_workspace_vault = true"] {
            try "name = \"faux\"\n\(hostile)\n".write(
                to: directory.appendingPathComponent(ScriptaVault.manifestName),
                atomically: true, encoding: .utf8)
            XCTAssertFalse(ScriptaVault.isAppVault(directory), "accepted: \(hostile)")
        }
    }

    /// APFS is case-insensitive, so a vault created as `cbre` inside a pre-existing `CBRE/` is
    /// reported by `contentsOfDirectory` as `CBRE`. Compared case-sensitively the lookup missed its
    /// own vault — and `WorkspaceDeleter` then found zero candidates and reported a successful
    /// wipe, which is the lying wipe reached through a different door.
    func testAVaultIsFoundRegardlessOfTheCasingOnDisk() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()

        for spelling in ["CBRE", "cbre", "CbRe"] {
            let found = ScriptaVault.existingVault(forScope: spelling, under: root)
            XCTAssertEqual(found.vault?.standardizedFileURL, vault.root.standardizedFileURL,
                           "not found for \(spelling)")
        }
    }

    /// The property that actually matters, asserted directly rather than only through its cause:
    /// no vault's root may be the folder that contains vaults.
    func testAVaultRootIsNeverTheContainingRoot() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        XCTAssertNotEqual(vault.root.standardizedFileURL, root.standardizedFileURL)
    }

    /// The engine refuses the same value for the same reason, so the two sides agree about what a
    /// nameable workspace is. the engine raises "slugifies to nothing; give it
    /// a name" — this message names that kinship so a reader hitting one finds the other.
    func testTheRefusalNamesTheRemedyAndTheEnginesAgreement() {
        let message = ScriptaVault.VaultError.unnameableScope("").errorDescription ?? ""
        XCTAssertTrue(message.contains("Name the workspace"), message)
        XCTAssertTrue(message.contains("slugifies to nothing"), message)
    }

    // MARK: - The manifest

    func testWriteCreatesTheManifestAndTheTranscriptDirectory() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()

        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.manifestURL.path))
        var isDirectory: ObjCBool = false
        XCTAssertTrue(FileManager.default.fileExists(atPath: vault.transcripts.path,
                                                     isDirectory: &isDirectory))
        XCTAssertTrue(isDirectory.boolValue)
    }

    /// Regenerated in place rather than written once: a manifest that survives only because an
    /// earlier build wrote it is a vault that stops composing after a hand-clean, with nothing
    /// saying why.
    func testWriteIsIdempotentAndRepairsAHandDeletedManifest() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        let first = try String(contentsOf: vault.manifestURL, encoding: .utf8)

        try FileManager.default.removeItem(at: vault.manifestURL)
        try vault.write()
        XCTAssertEqual(try String(contentsOf: vault.manifestURL, encoding: .utf8), first)
    }

    func testInheritsIsWrittenAsAbsolutePaths() throws {
        let curated = URL(fileURLWithPath: "/Users/x/Library/CloudStorage/OneDrive-Personal/vaults/cbre-vault")
        let vault = try ScriptaVault(root: root, scope: "cbre", inherits: [curated])
        let manifest = vault.manifest()

        XCTAssertTrue(manifest.contains("name = \"cbre\""), manifest)
        XCTAssertTrue(manifest.contains("\"\(curated.path)\""), manifest)
        // `_resolve_inherit` resolves a NON-absolute entry against the vault's parent, so a bare
        // name would silently mean "a sibling directory" rather than the curated vault.
        XCTAssertFalse(manifest.contains("inherits = []"), manifest)
    }

    func testNoInheritsIsAnExplicitEmptyList() throws {
        XCTAssertTrue(try ScriptaVault(root: root, scope: "cbre").manifest().contains("inherits = []"))
    }

    /// `_read_manifest` validates `reference_domains` and `reference_pins` and `vault.py` records
    /// that the features reading them are deferred — "the value was declared, valid-looking, and
    /// read by nobody", which is how a real defect went unnoticed for a whole phase. Emitting a key
    /// whose consumer does not exist is not repeated here.
    func testTheManifestDeclaresNoKeyWithoutAConsumer() throws {
        let manifest = try ScriptaVault(root: root, scope: "cbre").manifest()
        XCTAssertFalse(manifest.contains("reference_domains"), manifest)
        XCTAssertFalse(manifest.contains("reference_pins"), manifest)
    }

    /// A quote or a backslash in a path is a TOML parse error, and the manifest is the one file
    /// that must parse or the whole scope refuses to compose.
    func testHostilePathsStayValidTOML() throws {
        let nasty = URL(fileURLWithPath: #"/tmp/a "quoted" \path"#)
        let manifest = try ScriptaVault(root: root, scope: "s", inherits: [nasty]).manifest()
        XCTAssertTrue(manifest.contains(#"\"quoted\""#), manifest)
        XCTAssertTrue(manifest.contains(#"\\path"#), manifest)
    }

    // MARK: - A vault cannot inherit itself (#24)

    /// THE DEFECT THAT FROZE A LIVE SCOPE. `AskModel.bind` stored the roster row's vault for a scope
    /// registered to the workspace's OWN vault, `contextVaults` fell back to it, and the next
    /// recording regenerated the manifest with `inherits = [<own directory>]`. `vault.resolve_vaults`
    /// raises `VaultError: inheritance cycle` on that, so every refresh recorded `compose_failed` and
    /// the scope answered from its last good index for four days without saying so.
    ///
    /// The guard is HERE rather than at the caller because every writer funnels through `write()`:
    /// recording, note capture, upload promotion, workspace creation and group repair all build the
    /// vault with `contextVaults` and call it.
    func testAVaultDoesNotInheritItself() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        let selfInheriting = try ScriptaVault(root: vault.root, scope: "CBRE", inherits: [vault.root])

        let manifest = selfInheriting.manifest()
        XCTAssertTrue(manifest.contains("inherits = []"), manifest)
        XCTAssertFalse(manifest.contains(vault.root.path), manifest)
    }

    /// DROPPED, NOT REFUSED, and the rest of the list survives. A refusal would take the curated
    /// vault down with the bad entry — the workspace would compose without its notes, which is the
    /// same silent loss of context by another route.
    func testASelfReferenceIsDroppedAndTheOtherVaultsKept() throws {
        let curated = root.appendingPathComponent("cbre-vault", isDirectory: true)
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        let manifest = try ScriptaVault(root: vault.root, scope: "CBRE",
                                        inherits: [curated, vault.root]).manifest()

        XCTAssertTrue(manifest.contains(curated.path), manifest)
        XCTAssertFalse(manifest.contains("\"\(vault.root.path)\""), manifest)
        XCTAssertFalse(manifest.contains("inherits = []"), manifest)
    }

    /// THE ENGINE COMPARES RESOLVED PATHS (`Path.resolve()` in `vault.visit`), so a guard that
    /// compared spellings would pass a manifest the engine still refuses. The operator's vaults are
    /// reached through symlinks — `~/Documents/SchoolVault` is one — so this is the ordinary case,
    /// not a contrived one.
    func testASymlinkToTheVaultIsStillTheVault() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        let link = root.appendingPathComponent("cbre-link", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: vault.root)

        let manifest = try ScriptaVault(root: vault.root, scope: "CBRE", inherits: [link]).manifest()
        XCTAssertTrue(manifest.contains("inherits = []"), manifest)
        XCTAssertFalse(manifest.contains(link.path), manifest)
    }

    /// REPAIRED ON THE NEXT WRITE, because the guard above only protects a manifest not yet written.
    /// An operator already holding a self-inheriting manifest is the case that matters — the live
    /// `cbre` scope had to be hand-edited — and for them `inherits` is now empty, so `write()`'s
    /// "never rewrite with less than it had" early return would leave the broken file in place
    /// forever.
    func testAnExistingSelfInheritingManifestIsRepairedAndItsOtherVaultsKept() throws {
        let curated = root.appendingPathComponent("cbre-vault", isDirectory: true)
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        // The manifest as the defect wrote it: the curated vault, and the vault itself. Plus a key
        // the app never emits — `manifest()` deliberately writes no `reference_domains` — standing
        // in for whatever the operator added by hand.
        let broken = try String(contentsOf: vault.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "inherits = []", with: """
            reference_domains = ["lease"]
            inherits = [
                "\(curated.path)",
                "\(vault.root.path)",
            ]
            """)
        try broken.write(to: vault.manifestURL, atomically: true, encoding: .utf8)

        try vault.write()

        let repaired = try String(contentsOf: vault.manifestURL, encoding: .utf8)
        XCTAssertTrue(repaired.contains(curated.path), repaired)
        XCTAssertFalse(repaired.contains("\"\(vault.root.path)\""), repaired)
        // Everything outside the `inherits` block survives the repair: the ownership key is what
        // says this vault may be rewritten at all, and the guard key is the privacy wall.
        XCTAssertTrue(repaired.contains("scripta_workspace_vault = true"), repaired)
        XCTAssertTrue(repaired.contains("scripta_workspace = \"CBRE\""), repaired)
        // THE ONE THAT SEPARATES A SPLICE FROM A REGENERATION: `manifest()` does not emit this key,
        // so a repair that rewrote the whole file would silently delete it — which is precisely the
        // destruction `write()`'s early return exists to prevent.
        XCTAssertTrue(repaired.contains("reference_domains"), repaired)
    }

    /// A HEALTHY MANIFEST IS NOT TOUCHED. The repair reads every manifest on every recording, so a
    /// vault with ordinary inherits must come back byte-identical — otherwise the repair is a
    /// rewrite path that fires on every call, which is the hazard the early return exists for.
    func testAManifestWithNoSelfReferenceIsLeftAlone() throws {
        let curated = root.appendingPathComponent("cbre-vault", isDirectory: true)
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root, inherits: [curated])
        try vault.write()
        let written = try String(contentsOf: vault.manifestURL, encoding: .utf8)

        // Written once with inherits, then regenerated by a caller that has none — a note saved
        // before the binding is read, which is how the early return gets exercised in practice.
        try ScriptaVault.vault(forScope: "CBRE", under: root).write()
        XCTAssertEqual(try String(contentsOf: vault.manifestURL, encoding: .utf8), written)
    }

    /// A RELATIVE ENTRY SURVIVES THE REPAIR UNCHANGED, and this is the finding that would have made
    /// the fix worse than the bug. `_resolve_inherit` resolves a non-absolute entry against the
    /// VAULT'S PARENT, "never the process CWD" — and every curated vault on the operator's machine
    /// declares `inherits = ["core-vault"]` in exactly that form. Rebuilding the kept entry through
    /// `URL(fileURLWithPath:)` would have rewritten it to `<cwd>/core-vault`, and the engine hard
    /// fails an inherited vault that does not exist: the repair for a frozen scope would freeze it.
    func testARelativeInheritsEntryIsKeptExactlyAsWritten() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        try String(contentsOf: vault.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "inherits = []", with: """
            inherits = [
                "core-vault",
                "\(vault.root.path)",
            ]
            """)
            .write(to: vault.manifestURL, atomically: true, encoding: .utf8)

        try vault.write()

        let repaired = try String(contentsOf: vault.manifestURL, encoding: .utf8)
        XCTAssertTrue(repaired.contains("\"core-vault\""), repaired)
        XCTAssertFalse(repaired.contains("\"\(vault.root.path)\""), repaired)
    }

    /// THE SELF-REFERENCE THE OPERATOR IS LIKELIEST TO HAND-WRITE. A bare name resolves against the
    /// vault's parent, so `inherits = ["cbre"]` inside `<root>/cbre` points straight back at the
    /// vault and `vault.visit` raises the cycle — while a comparison that resolved it against the
    /// working directory would see two unrelated paths and repair nothing.
    func testARelativeSelfReferenceIsRecognised() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        try String(contentsOf: vault.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "inherits = []", with: """
            inherits = [
                "cbre",
            ]
            """)
            .write(to: vault.manifestURL, atomically: true, encoding: .utf8)

        try vault.write()

        let repaired = try String(contentsOf: vault.manifestURL, encoding: .utf8)
        XCTAssertTrue(repaired.contains("inherits = []"), repaired)
    }

    /// A PATH MAY CONTAIN `]`, and the entry reader has to parse it as the one string it is. Reading
    /// the block by scanning lines for a bracket ended the array early, and the splice then wrote a
    /// manifest with the remainder of the old array orphaned below the new one — unparseable TOML,
    /// so the engine refuses the scope outright. Worse than the defect being repaired.
    func testAPathContainingABracketDoesNotTruncateTheArray() throws {
        let awkward = root.appendingPathComponent("My [Notes]", isDirectory: true)
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        try String(contentsOf: vault.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "inherits = []", with: """
            inherits = [
                "\(vault.root.path)",
                "\(awkward.path)",
            ]
            """)
            .write(to: vault.manifestURL, atomically: true, encoding: .utf8)

        try vault.write()

        let repaired = try String(contentsOf: vault.manifestURL, encoding: .utf8)
        XCTAssertTrue(repaired.contains(awkward.path), repaired)
        XCTAssertFalse(repaired.contains("\"\(vault.root.path)\""), repaired)
        // The array closes exactly once: a stray `]` is the corruption this guards.
        XCTAssertEqual(repaired.components(separatedBy: "\n").filter {
            $0.trimmingCharacters(in: .whitespaces) == "]"
        }.count, 1, repaired)
    }

    /// A HAND-EDITED BLOCK IS LEFT ALONE RATHER THAN GUESSED AT — including its comments.
    ///
    /// Commenting an entry out instead of deleting it is the natural hand edit, and a reader that
    /// took every quoted string in the block as an entry would COMPOSE the disabled vault back into
    /// a scope holding call transcripts, destroying the note saying why it was disabled in the same
    /// write. The repair only recognises the shape the app itself writes; anything else keeps its
    /// self-reference and waits for the operator, which is the direction this must fail in.
    func testABlockCarryingACommentIsNotRewritten() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        let handEdited = try String(contentsOf: vault.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "inherits = []", with: """
            inherits = [
                # "/Users/x/vaults/private-old",  disabled 2026-09-01, do not re-add
                "\(vault.root.path)",
            ]
            """)
        try handEdited.write(to: vault.manifestURL, atomically: true, encoding: .utf8)

        try vault.write()

        let after = try String(contentsOf: vault.manifestURL, encoding: .utf8)
        XCTAssertEqual(after, handEdited, "a hand-edited block must be left exactly as it was")
        XCTAssertTrue(after.contains("do not re-add"), after)
        // The disabled vault is still on a COMMENT line — never promoted to a live entry, which is
        // the harm: a vault the operator switched off composing back into a scope of call
        // transcripts, with the note explaining why deleted in the same write.
        let disabled = after.components(separatedBy: "\n").first { $0.contains("private-old") }
        XCTAssertEqual(disabled?.trimmingCharacters(in: .whitespaces).first, "#", after)
        // And the self-reference is untouched rather than half-repaired: this manifest waits for the
        // operator. `declaredInherits` still stops the app from ever writing one itself.
        XCTAssertTrue(after.contains("\"\(vault.root.path)\""), after)
    }

    /// CASE-DIVERGENT SPELLINGS NAME ONE DIRECTORY on a case-insensitive volume, which is the macOS
    /// default, and the roster hands back whatever casing is on disk.
    ///
    /// WHICH BRANCH OF `isSameDirectory` ANSWERS IS NOT ASSERTED, deliberately: measured 2026-09-18,
    /// `resolvingSymlinksInPath()` canonicalises the on-disk casing on APFS, so the path comparison
    /// usually settles this before the `fileResourceIdentifier` fallback is reached. That fallback
    /// is defence for the shapes path canonicalisation does NOT fold together — firmlinks, a volume
    /// reached through two mount points — which no portable test can construct here. This asserts
    /// the behaviour the guard promises, not the route it takes to get there.
    func testTheVaultIsRecognisedThroughADifferentCasing() throws {
        let probe = root.appendingPathComponent("case-probe", isDirectory: true)
        try FileManager.default.createDirectory(at: probe, withIntermediateDirectories: true)
        guard FileManager.default.fileExists(
            atPath: root.appendingPathComponent("CASE-PROBE", isDirectory: true).path)
        else { throw XCTSkip("case-sensitive volume; the identity fallback has nothing to catch") }

        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        let shouted = root.appendingPathComponent("CBRE", isDirectory: true)

        let manifest = try ScriptaVault(root: vault.root, scope: "CBRE",
                                        inherits: [shouted]).manifest()
        XCTAssertTrue(manifest.contains("inherits = []"), manifest)
    }

    /// A VAULT THAT IS NOT THERE IS NOT THIS ONE. `isSameDirectory` returns false when it cannot
    /// resolve either side, so a stale `inherits` entry is left in the manifest for the engine to
    /// report rather than silently swallowed as a self-reference.
    func testAnAbsentInheritedVaultIsNotMistakenForThisOne() throws {
        let gone = root.appendingPathComponent("never-created", isDirectory: true)
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()

        let manifest = try ScriptaVault(root: vault.root, scope: "CBRE", inherits: [gone]).manifest()
        XCTAssertTrue(manifest.contains(gone.path), manifest)
    }

    /// THE REPAIR IS A ONE-SHOT, NOT A REWRITE LOOP. It runs on the early-return path, which means
    /// every recording and every note saved into an existing vault — so a repair that changed the
    /// file each time would rewrite a cloud-synced manifest on every call, and the second pass is
    /// the one that proves it converged.
    func testRepairingIsIdempotent() throws {
        let curated = root.appendingPathComponent("cbre-vault", isDirectory: true)
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        try String(contentsOf: vault.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "inherits = []", with: """
            inherits = [
                "\(curated.path)",
                "\(vault.root.path)",
            ]
            """)
            .write(to: vault.manifestURL, atomically: true, encoding: .utf8)

        try vault.write()
        let once = try String(contentsOf: vault.manifestURL, encoding: .utf8)
        try vault.write()
        XCTAssertEqual(try String(contentsOf: vault.manifestURL, encoding: .utf8), once)
        XCTAssertTrue(once.contains(curated.path), once)
    }

    /// AN ESCAPE THE READER DOES NOT FULLY DECODE MUST NOT BE RE-ENCODED. `soleTomlString` keeps the
    /// backslash on anything but `\"` and `\\`, so decoding `"a\tb"` and writing it back through
    /// `tomlString` would escape that backslash and yield `"a\\tb"` — a different, nonexistent path,
    /// in an entry that had nothing to do with the self-reference. The engine hard-fails an inherited
    /// vault that does not exist, so the repair would freeze the scope it is there to unfreeze.
    func testAKeptEntryIsWrittenBackByteForByte() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        try String(contentsOf: vault.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "inherits = []", with: """
            inherits = [
                "/vaults/a\\tb",
                "\(vault.root.path)",
            ]
            """)
            .write(to: vault.manifestURL, atomically: true, encoding: .utf8)

        try vault.write()

        let repaired = try String(contentsOf: vault.manifestURL, encoding: .utf8)
        XCTAssertTrue(repaired.contains(#""/vaults/a\tb""#), repaired)
        XCTAssertFalse(repaired.contains(#"a\\tb"#), repaired)
    }

    /// A QUOTE AND A BACKSLASH STILL ROUND-TRIP, which is what keeps the verbatim rule from being a
    /// licence to emit anything: these two ARE decoded, and the raw form re-emits them unchanged.
    func testAKeptEntryWithQuotedAndEscapedCharactersSurvives() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        try String(contentsOf: vault.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "inherits = []", with: """
            inherits = [
                "/vaults/a \\"quoted\\" \\\\path",
                "\(vault.root.path)",
            ]
            """)
            .write(to: vault.manifestURL, atomically: true, encoding: .utf8)

        try vault.write()

        let repaired = try String(contentsOf: vault.manifestURL, encoding: .utf8)
        XCTAssertTrue(repaired.contains(#""/vaults/a \"quoted\" \\path""#), repaired)
        XCTAssertFalse(repaired.contains("\"\(vault.root.path)\""), repaired)
    }

    /// THE REPAIR IS A REWRITE, so it is gated on the key that grants permission to rewrite. The
    /// factory already refuses a directory this app did not create, but the guard standing one call
    /// away in another function is the shape that made `vaultBelongsToAnotherWorkspace` necessary.
    func testAVaultWhoseOwnershipWasRevokedIsNotRepaired() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        // The documented escape hatch: remove the ownership line by hand and the app leaves it be.
        let disowned = try String(contentsOf: vault.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "scripta_workspace_vault = true\n", with: "")
            .replacingOccurrences(of: "inherits = []", with: """
            inherits = [
                "\(vault.root.path)",
            ]
            """)
        try disowned.write(to: vault.manifestURL, atomically: true, encoding: .utf8)

        try vault.write()

        XCTAssertEqual(try String(contentsOf: vault.manifestURL, encoding: .utf8), disowned)
    }

    /// TOP-LEVEL `inherits`, NOT ANY `inherits`. TOML puts every key after a `[table]` header inside
    /// that table, and the engine reads the top-level one — so a whole-file scan would splice a
    /// foreign tool's array in a manifest that has one and no top-level entry of its own.
    func testATablesInheritsIsNotMistakenForTheVaults() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        let withTable = try String(contentsOf: vault.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "inherits = []", with: """
            [other_tool]
            inherits = [
                "\(vault.root.path)",
            ]
            """)
        try withTable.write(to: vault.manifestURL, atomically: true, encoding: .utf8)

        try vault.write()

        XCTAssertEqual(try String(contentsOf: vault.manifestURL, encoding: .utf8), withTable)
    }

    /// A CRLF MANIFEST IS STILL REPAIRED. Splitting on `\n` leaves `\r` on every line, and
    /// `.whitespaces` does not include it — so a shape test using it alone would match nothing and
    /// the repair would silently never run on a file that came back through a sync path.
    func testACRLFManifestIsRepaired() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        try String(contentsOf: vault.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "inherits = []", with: """
            inherits = [
                "\(vault.root.path)",
            ]
            """)
            .replacingOccurrences(of: "\n", with: "\r\n")
            .write(to: vault.manifestURL, atomically: true, encoding: .utf8)

        try vault.write()

        let repaired = try String(contentsOf: vault.manifestURL, encoding: .utf8)
        XCTAssertFalse(repaired.contains("\"\(vault.root.path)\""), repaired)
        XCTAssertTrue(repaired.contains("inherits = []"), repaired)
    }

    /// A BLANK LINE CARRIES NOTHING, so it does not block the repair the way a comment does — there
    /// is no operator intent in it to destroy.
    func testABlankLineInsideTheArrayDoesNotBlockTheRepair() throws {
        let curated = root.appendingPathComponent("cbre-vault", isDirectory: true)
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        try String(contentsOf: vault.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "inherits = []", with: """
            inherits = [
                "\(curated.path)",

                "\(vault.root.path)",
            ]
            """)
            .write(to: vault.manifestURL, atomically: true, encoding: .utf8)

        try vault.write()

        let repaired = try String(contentsOf: vault.manifestURL, encoding: .utf8)
        XCTAssertTrue(repaired.contains(curated.path), repaired)
        XCTAssertFalse(repaired.contains("\"\(vault.root.path)\""), repaired)
    }

    /// AN EMPTY ENTRY IS GARBAGE, NOT A VAULT. `appendingPathComponent("")` returns the receiver, so
    /// `""` resolves to the directory holding every workspace — kept as a legitimate inherit, it
    /// would compose all of them into one scope. The block is left alone rather than rewritten
    /// around it.
    func testAnEmptyEntryLeavesTheBlockAlone() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        let malformed = try String(contentsOf: vault.manifestURL, encoding: .utf8)
            .replacingOccurrences(of: "inherits = []", with: """
            inherits = [
                "",
                "\(vault.root.path)",
            ]
            """)
        try malformed.write(to: vault.manifestURL, atomically: true, encoding: .utf8)

        try vault.write()

        XCTAssertEqual(try String(contentsOf: vault.manifestURL, encoding: .utf8), malformed)
    }

    // MARK: - Against the real engine

    /// THE GATE THIS TYPE EXISTS FOR: a vault Swift wrote composes, and the engine agrees about the
    /// tier of what is in it.
    ///
    /// Every assertion above is Swift checking its own output — they would all pass while the engine
    /// refused the manifest. This one hands the bytes to `substrate compose` and reads its verdict,
    /// which is the only check that can fail when the two sides disagree.
    ///
    /// SKIPPED when no deployed engine is present, the same trade `TransportTests` makes: a suite
    /// that fails on a machine without the engine is a suite people stop running. On a machine that
    /// HAS one, a layout change that breaks composition is caught on the first run after it lands.
    func testAVaultWrittenBySwiftComposesInTheEngine() throws {
        let engine = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".substrate/engine", isDirectory: true)
        let python = engine.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("no deployed engine at \(engine.path); run substrate/tools/substrate-deploy")
        }

        let vault = try ScriptaVault.vault(forScope: "GateTest", under: root)
        try vault.write()
        // One note, in the transcript location, carrying the spine capture now declares.
        try """
        ---
        doc_id: gate-test-call
        title: A call written by Swift
        status: \(TranscriptSpine.status)
        doc_type: \(TranscriptSpine.docType)
        confidence: \(TranscriptSpine.confidence)
        class: \(TranscriptSpine.documentClass)
        domains: [transcript]
        ---

        # A call written by Swift

        **[0:01] You:** Budgets and hiring for the next quarter.
        """.write(to: vault.transcripts.appendingPathComponent("gate-test-call.md"),
                  atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = python
        process.currentDirectoryURL = engine
        process.arguments = ["-m", "substrate.cli", "compose", vault.root.path,
                             "--index-root", root.appendingPathComponent("idx").path,
                             "--db", root.appendingPathComponent("gate.db").path,
                             "--registry", root.appendingPathComponent("scopes.toml").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0,
                       "the engine refused a vault this type wrote:\n\(text)")
        // Tier 3 is what `_tier_for` must derive from `_sources/transcripts/`. Asserted because the
        // path prefixes are a contract with the engine, not a naming preference — a note landing in
        // the wrong tier composes cleanly and answers wrongly.
        XCTAssertTrue(text.contains("'gatetest' registered") || text.contains("scope: 'gatetest'"),
                      "compose did not register the scope the manifest names:\n\(text)")
        XCTAssertTrue(text.contains("{3: 1}") || text.contains("3: 1"),
                      "the transcript did not compose as tier 3:\n\(text)")
    }

    /// ONE SCOPE, BOTH CORPORA — the property Doc 4 §8 rests on.
    ///
    /// Live retrieval during a call must answer from the workspace's calls AND its curated notes in
    /// a single query; querying two scopes and merging in Swift is retrieval logic in the client,
    /// which Doc 3 §6 forbids. That requires the workspace vault to INHERIT the curated one, and
    /// requires the engine to accept an `inherits` path this app wrote.
    ///
    /// Asserted through the engine because Swift cannot check it: `_resolve_inherit` resolves a
    /// non-absolute entry against the vault's PARENT, so a manifest that looks right can still
    /// compose the wrong directory — or none, and refuse.
    func testAVaultInheritsTheCuratedVaultAndBothComposeIntoOneScope() throws {
        let engine = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".substrate/engine", isDirectory: true)
        let python = engine.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("no deployed engine at \(engine.path)")
        }

        // The curated vault, somewhere else entirely — as `cbre-vault` is, in OneDrive.
        let curated = root.appendingPathComponent("curated", isDirectory: true)
        let notes = curated.appendingPathComponent("02-areas", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try """
        ---
        title: A curated note
        status: active
        doc_type: reference
        confidence: stated
        domains: [work]
        ---

        # A curated note

        The lease review is due before the quarter closes.
        """.write(to: notes.appendingPathComponent("lease.md"), atomically: true, encoding: .utf8)

        // The workspace vault: the app's, holding a call, inheriting the curated one.
        let vaults = root.appendingPathComponent("vaults", isDirectory: true)
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: vaults, inherits: [curated])
        try vault.write()
        try """
        ---
        doc_id: inherit-test-call
        title: A call
        status: \(TranscriptSpine.status)
        doc_type: \(TranscriptSpine.docType)
        confidence: \(TranscriptSpine.confidence)
        class: \(TranscriptSpine.documentClass)
        domains: [transcript]
        ---

        # A call

        **[0:01] You:** We should look at the lease before quarter end.
        """.write(to: vault.transcripts.appendingPathComponent("call.md"),
                  atomically: true, encoding: .utf8)

        let process = Process()
        process.executableURL = python
        process.currentDirectoryURL = engine
        process.arguments = ["-m", "substrate.cli", "compose", vault.root.path,
                             "--index-root", root.appendingPathComponent("idx2").path,
                             "--db", root.appendingPathComponent("inherit.db").path,
                             "--registry", root.appendingPathComponent("scopes2.toml").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0, "compose refused an inheriting vault:\n\(text)")
        // Both vaults present in one scope — the whole point. `A-compose` reports per-vault counts.
        XCTAssertTrue(text.contains("'curated'"), "the inherited vault did not compose:\n\(text)")
        XCTAssertTrue(text.contains("'cbre'"), "the workspace vault did not compose:\n\(text)")
    }

    /// THE FREEZE, ASSERTED AGAINST THE ENGINE THAT CAUSED IT (#24).
    ///
    /// Every assertion above is Swift reading its own manifest, and all of them would pass while the
    /// engine still refused the scope — which is exactly how this shipped: the manifest looked
    /// plausible, `substrate compose` raised `VaultError: inheritance cycle`, and the only symptom
    /// was `compose_failed` in a refresh record nobody reads during a call.
    ///
    /// On the code before the guard this fails the way the live scope did: compose exits non-zero
    /// naming the cycle.
    func testAWorkspaceVaultHandedItsOwnDirectoryStillComposes() throws {
        let engine = URL(fileURLWithPath: NSHomeDirectory())
            .appendingPathComponent(".substrate/engine", isDirectory: true)
        let python = engine.appendingPathComponent(".venv/bin/python")
        guard FileManager.default.isExecutableFile(atPath: python.path) else {
            throw XCTSkip("no deployed engine at \(engine.path)")
        }

        let curated = root.appendingPathComponent("curated", isDirectory: true)
        let notes = curated.appendingPathComponent("02-areas", isDirectory: true)
        try FileManager.default.createDirectory(at: notes, withIntermediateDirectories: true)
        try """
        ---
        title: A curated note
        status: active
        doc_type: reference
        confidence: stated
        domains: [work]
        ---

        # A curated note

        The lease review is due before the quarter closes.
        """.write(to: notes.appendingPathComponent("lease.md"), atomically: true, encoding: .utf8)

        // WHAT `contextVaults` HANDED IT: the curated vault, and — through the Ask scope control
        // binding a workspace to the scope registered to its own vault — its own directory.
        let vaults = root.appendingPathComponent("vaults", isDirectory: true)
        let own = vaults.appendingPathComponent("cbre", isDirectory: true)
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: vaults, inherits: [curated, own])
        try vault.write()
        XCTAssertEqual(vault.root.standardizedFileURL, own.standardizedFileURL,
                       "precondition: the second inherit really is this vault's own directory")

        let process = Process()
        process.executableURL = python
        process.currentDirectoryURL = engine
        process.arguments = ["-m", "substrate.cli", "compose", vault.root.path,
                             "--index-root", root.appendingPathComponent("idx3").path,
                             "--db", root.appendingPathComponent("cycle.db").path,
                             "--registry", root.appendingPathComponent("scopes3.toml").path]
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        let text = String(data: data, encoding: .utf8) ?? ""

        XCTAssertEqual(process.terminationStatus, 0,
                       "the engine refused a vault this type wrote:\n\(text)")
        XCTAssertFalse(text.contains("inheritance cycle"), text)
        // AND THE CURATED VAULT SURVIVED THE GUARD — dropping the whole list would compose the
        // workspace without its notes, which is the same loss by another route.
        XCTAssertTrue(text.contains("'curated'"), "the inherited vault did not compose:\n\(text)")
    }
}

/// Vault discovery under adversarial filesystem shapes.
final class VaultDiscoverySafetyTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("VaultDiscovery-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// A symlink to a real vault passed `isAppVault` (which resolves through `fileExists`), so the
    /// pruner and the wipe deleted files THROUGH it inside the operator's real vault, while
    /// `removeItem` on the link removed only the link — over-deleting where it must not, and
    /// under-deleting where the count said it had.
    func testASymlinkedVaultIsNotDiscovered() throws {
        let real = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try real.write()

        let elsewhere = root.appendingPathComponent("elsewhere", isDirectory: true)
        try FileManager.default.createDirectory(at: elsewhere, withIntermediateDirectories: true)
        let link = elsewhere.appendingPathComponent("cbre", isDirectory: true)
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: real.root)

        // The link resolves — so a check that follows it would call it a vault.
        XCTAssertTrue(ScriptaVault.isAppVault(link), "precondition: the link resolves to a vault")
        XCTAssertTrue(ScriptaVault.vaultRoots(under: elsewhere).vaults.isEmpty,
                      "a symlink must not be discovered as a vault")
    }

    /// Only vaults this app created are discovered — every destructive caller reaches a directory
    /// through this filter, so `isVault` here would have handed them the operator's own vaults.
    func testForeignVaultsAreNotDiscovered() throws {
        let mine = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try mine.write()

        let theirs = root.appendingPathComponent("their-vault", isDirectory: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        try "name = \"theirs\"\ninherits = []\n".write(
            to: theirs.appendingPathComponent(ScriptaVault.manifestName),
            atomically: true, encoding: .utf8)

        let found = ScriptaVault.vaultRoots(under: root).vaults.map(\.lastPathComponent)
        XCTAssertEqual(found, ["cbre"], "found: \(found)")
    }

    // MARK: - The default vault (Doc 4 §7's ungrouped case)

    func testTheDefaultScopeNamesAVaultLikeAnyOther() throws {
        let vault = try ScriptaVault.vault(forScope: ScriptaVault.defaultScope, under: root)
        try vault.write()

        // It is a real, composable vault — not a special case the engine has to know about.
        XCTAssertTrue(ScriptaVault.isVault(vault.root), "compose needs a manifest to read")
        XCTAssertTrue(ScriptaVault.isAppVault(vault.root), "and the app must own what it writes")
        XCTAssertEqual(vault.scope, "default")
        // A transcript written here resolves back to the default scope by LOCATION, which is what
        // §7 made authoritative.
        let call = vault.transcripts.appendingPathComponent("call.md")
        XCTAssertEqual(ScriptaVault.scope(forTranscriptAt: call, under: root),
                       ScriptaVault.defaultScope)
    }

    /// The distinction the recording path draws: `""` is "no choice was made" and gets the default
    /// vault; a name the operator TYPED that slugifies to nothing is still refused, because filing
    /// its calls into the default corpus would merge two partitions on their behalf.
    func testAnUnnameableTypedWorkspaceIsStillRefused() throws {
        XCTAssertThrowsError(try ScriptaVault.vault(forScope: "———", under: root))
        XCTAssertThrowsError(try ScriptaVault.vault(forScope: "", under: root))
    }

}

/// The migration's loose end: a curated vault and a workspace vault can each declare the same scope
/// name, both correctly. Measured on the operator's machine 2026-08-17 — `school` had a curated
/// vault registered as the scope AND an app vault registered nowhere, inheriting nothing, so a call
/// recorded into it would have composed into a scope resolving elsewhere.
final class WorkspaceVaultConflictTests: XCTestCase {
    private let output = URL(fileURLWithPath: "/Users/x/OneDrive/Scripta", isDirectory: true)

    func testACuratedVaultOfTheSameNameIsFound() {
        let hit = ScriptaVault.conflictingScope(
            forWorkspaceNamed: "School",
            registered: [("school", "/Users/x/OneDrive/vaults/school-vault"),
                         ("prism", "/Users/x/OneDrive/vaults/prism-vault")],
            outputFolder: output)
        XCTAssertEqual(hit?.scope, "school")
        XCTAssertEqual(hit?.vault, "/Users/x/OneDrive/vaults/school-vault")
    }

    /// THE CASE THAT WOULD MAKE A WORKSPACE OFFER TO CONNECT TO ITSELF. A scope already pointing at
    /// the directory this name would create IS this workspace's own vault, correctly registered —
    /// the working state, not a conflict.
    func testAWorkspacesOwnAlreadyRegisteredVaultIsNotAConflict() {
        XCTAssertNil(ScriptaVault.conflictingScope(
            forWorkspaceNamed: "CBRE",
            registered: [("cbre", "/Users/x/OneDrive/Scripta/cbre")],
            outputFolder: output))
        // Even spelled with a trailing slash, which is how a path read back from TOML can arrive.
        XCTAssertNil(ScriptaVault.conflictingScope(
            forWorkspaceNamed: "CBRE",
            registered: [("cbre", "/Users/x/OneDrive/Scripta/cbre/")],
            outputFolder: output))
    }

    func testAnUnrelatedNameFindsNothing() {
        XCTAssertNil(ScriptaVault.conflictingScope(
            forWorkspaceNamed: "Deals",
            registered: [("school", "/Users/x/OneDrive/vaults/school-vault")],
            outputFolder: output))
    }

    /// Matching is on the SLUG, because that is the name the vault will declare. Case and
    /// surrounding punctuation collapse, so every spelling that would create ONE directory has to
    /// find the SAME conflict — otherwise "SCHOOL" walks past the alert that "School" gets.
    ///
    /// Note the example: `slug("C.B.R.E.")` is `"c-b-r-e"`, NOT `"cbre"` — each separator emits a
    /// hyphen. `ScriptaVault.workspace(ofVaultAt:)`'s comment claims that pair collapses to one
    /// directory and it does not; the real collapsing cases are case divergence and a shared
    /// 48-character prefix. Left as found rather than corrected here.
    func testMatchingIsOnTheSlugNotTheTypedName() {
        for spelling in ["SCHOOL", "school", " School "] {
            XCTAssertEqual(ScriptaVault.conflictingScope(
                forWorkspaceNamed: spelling,
                registered: [("school", "/Users/x/OneDrive/vaults/school-vault")],
                outputFolder: output)?.scope, "school", "spelling \(spelling)")
        }
    }

    /// An empty roster is an engine that has not listed yet, not proof of no conflict — the caller
    /// treats nil as "nothing to ask about", so this must not invent one either.
    func testAnUnnameableWorkspaceAndAnEmptyRosterBothFindNothing() {
        XCTAssertNil(ScriptaVault.conflictingScope(forWorkspaceNamed: "日本語",
                                                   registered: [("", "/x")], outputFolder: output))
        XCTAssertNil(ScriptaVault.conflictingScope(forWorkspaceNamed: "School",
                                                   registered: [], outputFolder: output))
    }
}
