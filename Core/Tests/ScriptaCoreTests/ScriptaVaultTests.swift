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
    /// (`cli._refuse_destructive_clean`); this side was reading it the other way.
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
