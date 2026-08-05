import XCTest
@testable import ScriptaCore
@testable import ScriptaShared

/// The remedy for the engine's refusal. `transcript_export.export_workspace` aborts the WHOLE
/// export over one untagged transcript and names the fix; these assert the app can apply it.
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

        let found = TranscriptGroupRepair.untagged(in: dir)
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

        let found = TranscriptGroupRepair.untagged(in: dir)
        XCTAssertEqual(found.map(\.title), ["Real"],
                       "non-recursive, marker-checked — the output folder may live inside a vault")
    }

    func testAssignWritesTheWorkspaceAndTheFileStaysAValidTranscript() throws {
        let url = try write("untagged.md", transcript(title: "Recovered", group: nil))
        try TranscriptGroupRepair.assign("CBRE", to: url)

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertTrue(text.contains("\ngroup: \"CBRE\"\n"), text)
        XCTAssertTrue(TranscriptGroupRepair.untagged(in: dir).isEmpty, "it must no longer be untagged")
        // The body is untouched and the marker survives — otherwise the pruner stops recognising it.
        XCTAssertTrue(text.contains("**[0:01]** Something was said."), text)
        XCTAssertTrue(Frontmatter.hasOwnerMarker(Frontmatter.split(text)!.frontmatter))
    }

    /// The key lands immediately before `app:`, which is where `TranscriptWriter` puts it — so a
    /// repaired file is byte-comparable with a freshly written one, not merely equivalent.
    func testRepairedOrderMatchesWhatTheWriterEmits() throws {
        let url = try write("untagged.md", transcript(title: "Recovered", group: nil))
        try TranscriptGroupRepair.assign("CBRE", to: url)

        let lines = try String(contentsOf: url, encoding: .utf8).components(separatedBy: "\n")
        let group = lines.firstIndex { $0.hasPrefix("group:") }
        let app = lines.firstIndex { $0.hasPrefix("app:") }
        XCTAssertNotNil(group); XCTAssertNotNil(app)
        XCTAssertEqual(group! + 1, app!)
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
    func testAnEmptyWorkspaceIsRefused() throws {
        let url = try write("untagged.md", transcript(title: "Recovered", group: nil))
        XCTAssertThrowsError(try TranscriptGroupRepair.assign("   ", to: url))
        XCTAssertEqual(TranscriptGroupRepair.untagged(in: dir).count, 1, "nothing was written")
    }

    func testANonTranscriptIsRefusedRatherThanRewritten() throws {
        let url = try write("note.md", "---\napp: call-transcriber-note\ntitle: \"A note\"\n---\n\n# A note\n")
        XCTAssertThrowsError(try TranscriptGroupRepair.assign("CBRE", to: url))
    }
}
