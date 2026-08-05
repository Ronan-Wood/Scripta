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

    /// The property that actually matters, asserted directly rather than only through its cause:
    /// no vault's root may be the folder that contains vaults.
    func testAVaultRootIsNeverTheContainingRoot() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        XCTAssertNotEqual(vault.root.standardizedFileURL, root.standardizedFileURL)
    }

    /// The engine refuses the same value for the same reason, so the two sides agree about what a
    /// nameable workspace is. `transcript_export.scope_name` raises "slugifies to nothing; give it
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
}
