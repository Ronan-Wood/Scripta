import XCTest
@testable import ScriptaCore
@testable import ScriptaShared

/// Filing a call that capture could not file itself — the two-part remedy for the two cases where
/// capture falls back to the flat output folder (an unnamed workspace, and a vault that could not
/// be prepared). `assign` gives it a workspace; `file` MOVES it into that workspace's vault.
///
/// The move is new, and it is what the exporter used to be. `substrate export-transcripts` was
/// deleted with Doc 4 §7 — capture writes into the vault, so nothing exports into one — and it was
/// the only thing that ever relocated a flat transcript. Without this, a repaired call carried the
/// right workspace and sat in no vault, therefore in no scope: visible in the app and unreachable
/// by every query.
final class TranscriptGroupRepairTests: XCTestCase {
    private var dir: URL!

    override func setUpWithError() throws {
        dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GroupRepair-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws { try? FileManager.default.removeItem(at: dir) }

    @discardableResult
    private func write(_ name: String, _ text: String, subdirectory: String? = nil) throws -> URL {
        var folder = dir!
        if let subdirectory {
            folder = folder.appendingPathComponent(subdirectory, isDirectory: true)
            try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        }
        let url = folder.appendingPathComponent(name)
        try text.write(to: url, atomically: true, encoding: .utf8)
        return url
    }

    private func transcript(title: String, group: String?) -> String {
        var yaml = """
        ---
        date: 2026-07-21
        time: "08:31"
        duration: "11:04"
        title: "\(title)"
        participants: []
        tags: ["call", "recovered"]
        """
        if let group { yaml += "\ngroup: \"\(group)\"" }
        yaml += "\napp: \(OwnerMarker.value)\n---\n\n# \(title)\n\n**[0:01]** Something was said.\n"
        return yaml
    }

    func testFindsOnlyTranscriptsWithNoWorkspace() throws {
        try write("tagged.md", transcript(title: "Tagged", group: "CBRE"))
        try write("untagged.md", transcript(title: "Untagged", group: nil))
        try write("empty.md", transcript(title: "Empty", group: ""))

        let found = TranscriptGroupRepair.untagged(in: dir) ?? []
        XCTAssertEqual(Set(found.map(\.title)), ["Untagged", "Empty"],
                       "a present-but-empty group: is what the exporter treats as untagged too")
    }

    /// The app writes four `app:` markers into one folder. Only transcripts are repairable — a note
    /// or an entity stub is not a call and must never be rewritten as one.
    func testIgnoresForeignAndNonTranscriptMarkdown() throws {
        try write("untagged.md", transcript(title: "Real", group: nil))
        try write("note.md", "---\napp: call-transcriber-note\ntitle: \"A note\"\n---\n\n# A note\n")
        try write("foreign.md", "---\ntitle: \"Someone else's\"\n---\n\n# Not ours\n")
        try write("Deal.md", transcript(title: "In a subfolder", group: nil), subdirectory: "Notes")

        let found = TranscriptGroupRepair.untagged(in: dir) ?? []
        XCTAssertEqual(found.map(\.title), ["Real"],
                       "non-recursive, marker-checked — the output folder may live inside a vault")
    }

    func testAssignWritesTheWorkspaceAndTheFileStaysAValidTranscript() throws {
        let url = try write("untagged.md", transcript(title: "Recovered", group: nil))
        try TranscriptGroupRepair.assign("CBRE", to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\ngroup: \"CBRE\"\n"), text)
        XCTAssertTrue((TranscriptGroupRepair.untagged(in: dir) ?? []).isEmpty, "it must no longer be untagged")
        // The body is untouched and the marker survives — otherwise the pruner stops recognising it.
        XCTAssertTrue(text.contains("**[0:01]** Something was said."), text)
        XCTAssertTrue(Frontmatter.hasOwnerMarker(Frontmatter.split(text)!.frontmatter))
    }

    /// `group:` lands where `TranscriptWriter` puts it — BEFORE the spine keys. Anchored on `app:`
    /// it landed after all four, so a repaired file and a written one differed in key order while
    /// the doc comment claimed they were byte-comparable.
    func testRepairedOrderMatchesWhatTheWriterEmits() throws {
        let spined = transcript(title: "Recovered", group: nil)
            .replacingOccurrences(of: "app: ", with: "status: complete\ndoc_type: reference\napp: ")
        let url = try write("untagged.md", spined)
        try TranscriptGroupRepair.assign("CBRE", to: url)

        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        guard let group = lines.firstIndex(where: { $0.hasPrefix("group:") }),
              let status = lines.firstIndex(where: { $0.hasPrefix("status:") }) else {
            return XCTFail("missing keys")
        }
        XCTAssertLessThan(group, status, "group must precede the spine, as the writer emits it")
    }

    /// A legacy transcript has no spine, so `app:` is the fallback anchor and still works.
    func testALegacyTranscriptWithNoSpineStillAnchorsOnTheMarker() throws {
        let url = try write("legacy.md", transcript(title: "Old", group: nil))
        try TranscriptGroupRepair.assign("CBRE", to: url)
        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        guard let group = lines.firstIndex(where: { $0.hasPrefix("group:") }),
              let app = lines.firstIndex(where: { $0.hasPrefix("app:") }) else {
            return XCTFail("missing keys")
        }
        XCTAssertEqual(group + 1, app)
    }

    /// An unreadable folder is `nil`, not "nothing to repair" — the surface must not report a clean
    /// corpus it never looked at.
    func testAnUnreadableFolderIsNotAnEmptyResult() throws {
        let locked = dir.appendingPathComponent("locked", isDirectory: true)
        try FileManager.default.createDirectory(at: locked, withIntermediateDirectories: true)
        try FileManager.default.setAttributes([.posixPermissions: 0o000], ofItemAtPath: locked.path)
        defer { try? FileManager.default.setAttributes([.posixPermissions: 0o755],
                                                       ofItemAtPath: locked.path) }
        XCTAssertNil(TranscriptGroupRepair.untagged(in: locked))
    }

    /// A name that sanitizes fine but slugifies to nothing was stamped into the file, producing a
    /// `group:` every later consumer refuses — with nothing said at repair time.
    func testAWorkspaceThatSlugifiesToNothingIsRefused() throws {
        let url = try write("untagged.md", transcript(title: "Recovered", group: nil))
        for name in ["...", "———", "🙂"] {
            XCTAssertThrowsError(try TranscriptGroupRepair.assign(name, to: url), name)
        }
    }

    /// Recovery stamps `untagged` into `tags:`; a repaired call must stop asserting it has no
    /// workspace, since that tag feeds the exporter's `domains`.
    func testRepairClearsTheUntaggedTag() throws {
        let text = transcript(title: "Recovered", group: nil)
            .replacingOccurrences(of: #"tags: ["call", "recovered"]"#,
                                  with: #"tags: ["call", "recovered", "untagged"]"#)
        let url = try write("untagged.md", text)
        try TranscriptGroupRepair.assign("CBRE", to: url)
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("untagged"))
    }

    /// Two `group:` keys is a frontmatter whose meaning depends on which parser reads it.
    func testAssignReplacesAnEmptyGroupRatherThanAddingASecond() throws {
        let url = try write("empty.md", transcript(title: "Empty", group: ""))
        try TranscriptGroupRepair.assign("CBRE", to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertEqual(text.components(separatedBy: "\ngroup:").count - 1, 1, text)
        XCTAssertTrue(text.contains("group: \"CBRE\""), text)
    }

    /// `scope_name("")` raises in the engine — a workspace that slugifies to nothing names no scope
    /// — so "file it as ungrouped" is not a repair, it is the same refusal one step later.
    // MARK: - Filing into the vault

    func testFilingMovesAFlatTranscriptIntoItsWorkspaceVault() throws {
        let url = try write("call.md", transcript(title: "Budget", group: nil))
        try TranscriptGroupRepair.assign("CBRE", to: url)

        let moved = try TranscriptGroupRepair.file(url, into: "CBRE", under: dir)

        XCTAssertFalse(FileManager.default.fileExists(atPath: url.path),
                       "the flat copy must be gone — two copies of one call is worse than none")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
        // In the VAULT's transcript directory, which is what puts it in a scope.
        XCTAssertEqual(moved.deletingLastPathComponent().lastPathComponent, "transcripts")
        XCTAssertEqual(ScriptaVault.scope(forTranscriptAt: moved, under: dir), "cbre")
        // And the vault it landed in declares itself, or nothing would compose it.
        XCTAssertTrue(ScriptaVault.isAppVault(dir.appendingPathComponent("cbre")))
        // The content survived the move intact.
        let text = try String(contentsOf: moved, encoding: .utf8)
        XCTAssertTrue(text.contains("group: \"CBRE\""))
    }

    func testFilingACallAlreadyInAVaultIsANoOp() throws {
        let url = try write("call.md", transcript(title: "Budget", group: "CBRE"))
        let moved = try TranscriptGroupRepair.file(url, into: "CBRE", under: dir)
        let again = try TranscriptGroupRepair.file(moved, into: "CBRE", under: dir)

        XCTAssertEqual(again, moved, "a second filing must not move a call that is already filed")
        XCTAssertTrue(FileManager.default.fileExists(atPath: moved.path))
    }

    /// A transcript is the ONE artefact that cannot be recreated — the audio is deleted after a
    /// successful write — so a name collision refuses rather than overwrites.
    func testFilingRefusesRatherThanOverwritingACallOfTheSameName() throws {
        let first = try write("call.md", transcript(title: "One", group: "CBRE"))
        try TranscriptGroupRepair.file(first, into: "CBRE", under: dir)

        let second = try write("call.md", transcript(title: "Two", group: "CBRE"))
        XCTAssertThrowsError(try TranscriptGroupRepair.file(second, into: "CBRE", under: dir)) {
            guard case TranscriptGroupRepair.RepairError.destinationOccupied = $0 else {
                return XCTFail("expected destinationOccupied, got \($0)")
            }
        }
        // The one it refused to move is still where it was, unread and unlost.
        XCTAssertTrue(FileManager.default.fileExists(atPath: second.path))
        XCTAssertTrue(try String(contentsOf: second, encoding: .utf8).contains("\"Two\""))
    }

    func testFilingRefusesAWorkspaceThatCannotNameAVault() throws {
        let url = try write("call.md", transcript(title: "Budget", group: nil))
        XCTAssertThrowsError(try TranscriptGroupRepair.file(url, into: "———", under: dir))
        XCTAssertTrue(FileManager.default.fileExists(atPath: url.path))
    }

    func testAnEmptyWorkspaceIsRefused() throws {
        let url = try write("untagged.md", transcript(title: "Recovered", group: nil))
        XCTAssertThrowsError(try TranscriptGroupRepair.assign("   ", to: url))
        XCTAssertEqual((TranscriptGroupRepair.untagged(in: dir) ?? []).count, 1, "nothing was written")
    }

    func testANonTranscriptIsRefusedRatherThanRewritten() throws {
        let url = try write("note.md", "---\napp: call-transcriber-note\ntitle: \"A note\"\n---\n\n# A note\n")
        XCTAssertThrowsError(try TranscriptGroupRepair.assign("CBRE", to: url))
    }
}
