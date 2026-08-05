import XCTest
@testable import ScriptaCore
@testable import ScriptaShared

/// Reading the corpus across both layouts.
///
/// `TranscriptStore.list(in:)` is non-recursive, so it was the whole app's view of its own calls
/// and would have become an EMPTY one the moment a transcript moved into a vault (Doc 4 §7). An
/// audit of that move traced 21 surfaces to this one function — the calls list, the menu, Meetings,
/// concept backfill, the MCP server, the retention pruner — every one failing to zero rather than
/// to an error.
final class TranscriptStoreLayoutTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("TranscriptLayout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    private func transcript(_ title: String, date: String, group: String? = nil) -> String {
        var yaml = """
        ---
        date: \(date)
        time: "09:00"
        duration: "5:00"
        title: "\(title)"
        participants: []
        tags: ["call"]
        """
        if let group { yaml += "\ngroup: \"\(group)\"" }
        yaml += "\napp: \(OwnerMarker.value)\n---\n\n# \(title)\n\n**[0:01]** Something.\n"
        return yaml
    }

    @discardableResult
    private func write(_ text: String, to directory: URL, named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    /// The migration window: one call in the old place, one in the new, and BOTH must be visible.
    /// A reader that knew only one location would report half the corpus as missing.
    func testBothLayoutsAreRead() throws {
        try write(transcript("Legacy flat call", date: "2026-08-01", group: "CBRE"),
                  to: root, named: "flat.md")

        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        try write(transcript("Vault call", date: "2026-08-02"),
                  to: vault.transcripts, named: "vault.md")

        let titles = TranscriptStore.list(under: root).map(\.title)
        XCTAssertEqual(titles, ["Vault call", "Legacy flat call"],
                       "both layouts, newest first — got \(titles)")
    }

    /// The regression this replaces, pinned: the single-directory primitive cannot see into a vault.
    func testTheSingleDirectoryPrimitiveStillSeesOnlyItsOwnFolder() throws {
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        try write(transcript("Vault call", date: "2026-08-02"),
                  to: vault.transcripts, named: "vault.md")

        XCTAssertTrue(TranscriptStore.list(in: root).isEmpty,
                      "list(in:) is non-recursive by contract; if this starts passing, "
                      + "`WorkspaceDeleter`'s two-layout logic is double-counting")
        XCTAssertEqual(TranscriptStore.list(under: root).count, 1)
    }

    /// Ordering is by frontmatter date/time across the COMBINED set, not per-location — otherwise
    /// the calls list would show every vault call before every flat one regardless of when they
    /// happened.
    func testOrderingIsGlobalNotPerLocation() throws {
        try write(transcript("Newest, flat", date: "2026-08-09", group: "CBRE"),
                  to: root, named: "flat.md")

        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        try write(transcript("Older, in a vault", date: "2026-08-03"),
                  to: vault.transcripts, named: "vault.md")

        XCTAssertEqual(TranscriptStore.list(under: root).map(\.title),
                       ["Newest, flat", "Older, in a vault"])
    }

    /// Several workspaces, each its own vault. Every call is visible to a reading surface; the
    /// PARTITION is applied by the caller, not by hiding files here.
    func testEveryVaultIsRead() throws {
        for (scope, title) in [("CBRE", "A work call"), ("Personal", "A personal call")] {
            let vault = try ScriptaVault.vault(forScope: scope, under: root)
            try vault.write()
            try write(transcript(title, date: "2026-08-0\(scope.count)"),
                      to: vault.transcripts, named: "\(ScriptaVault.slug(scope)).md")
        }
        XCTAssertEqual(Set(TranscriptStore.list(under: root).map(\.title)),
                       ["A work call", "A personal call"])
    }

    /// A directory without a manifest is not a vault and is not searched — `Notes/`, `Files/` and
    /// `Entities/` sit in this same root and hold markdown that is deliberately not transcripts.
    func testNonVaultDirectoriesAreNotSearched() throws {
        let notes = root.appendingPathComponent("Notes", isDirectory: true)
        try write(transcript("Not a call", date: "2026-08-05"), to: notes, named: "note.md")

        XCTAssertTrue(TranscriptStore.list(under: root).isEmpty,
                      "a directory with no manifest must not be treated as a vault")
    }
}

/// Retention across both layouts.
///
/// The pruner's shallow listing still SUCCEEDS on a vaults root — it just finds no `.md` — so
/// without this the feature would fail silently: nothing deleted, nothing reported, transcripts
/// accumulating past the configured window with no symptom anywhere.
final class RetentionLayoutTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RetentionLayout-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: root) }

    /// `TranscriptWriter.uniqueURL`'s shape — the pruner gates on the filename as well as the
    /// marker, so a name it does not recognise is never deleted.
    private func writeOldCall(in directory: URL, named name: String) throws -> URL {
        try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let url = directory.appendingPathComponent(name)
        try """
        ---
        date: 2020-01-01
        time: "09:00"
        app: \(OwnerMarker.value)
        ---

        # Old call
        """.write(to: url, atomically: true, encoding: .utf8)
        let old = Date(timeIntervalSince1970: 0)
        try FileManager.default.setAttributes([.creationDate: old, .modificationDate: old],
                                              ofItemAtPath: url.path)
        return url
    }

    func testRetentionReachesTranscriptsInsideVaults() throws {
        let flat = try writeOldCall(in: root, named: "Call — 2020-01-01 0900.md")
        let vault = try ScriptaVault.vault(forScope: "CBRE", under: root)
        try vault.write()
        let inVault = try writeOldCall(in: vault.transcripts, named: "Call — 2020-01-01 0901.md")

        RetentionPruner.pruneIfNeeded(.init(enabled: true, days: 30, folder: root))

        XCTAssertFalse(FileManager.default.fileExists(atPath: flat.path), "flat call not pruned")
        XCTAssertFalse(FileManager.default.fileExists(atPath: inVault.path),
                       "a call inside a vault outlived the retention window — the pruner's shallow "
                       + "listing finds no .md in a vaults root and fails silently")
    }

    /// The safety property the pruner is built on: the output folder may sit inside someone's real
    /// Obsidian vault, and only a directory carrying OUR manifest is ever visited. A general
    /// recursive walk would eventually reach their notes with only the content gates in the way.
    func testADirectoryWithoutAManifestIsNeverVisited() throws {
        let foreign = root.appendingPathComponent("SomeonesNotes", isDirectory: true)
        let survivor = try writeOldCall(in: foreign, named: "Call — 2020-01-01 0900.md")

        RetentionPruner.pruneIfNeeded(.init(enabled: true, days: 30, folder: root))

        XCTAssertTrue(FileManager.default.fileExists(atPath: survivor.path),
                      "the pruner descended into a directory this app did not declare")
    }
}
