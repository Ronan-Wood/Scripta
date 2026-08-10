import XCTest
@testable import ScriptaCore
@testable import ScriptaShared

/// The whole point of retiring `group:`: the workspace survives without it.
final class GroupRetirementTests: XCTestCase {
    func testAWrittenTranscriptCarriesNoGroupAndStillKnowsItsWorkspace() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("GroupGone-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }

        let vault = try ScriptaVault(root: root.appendingPathComponent("cbre"), scope: "CBRE")
        try vault.write()
        let url = try TranscriptWriter.write(
            to: vault.transcripts,
            segments: [TranscriptSegment(startMs: 0, text: "Budgets.", speaker: .you)],
            startedAt: Date(timeIntervalSince1970: 1_785_000_000), duration: 60, title: "Sync")

        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("group:"), "capture must not write the field any more:\n\(text)")

        // And every reader still gets the workspace — in the OPERATOR'S casing, which is what the
        // index partitions on. A slug here hides the call from search, Ask and entity pages.
        let meta = try XCTUnwrap(TranscriptStore.meta(of: url))
        XCTAssertEqual(meta.group, "CBRE")
        XCTAssertEqual(ScriptaVault.scope(forTranscriptAt: url), "cbre")

        // A call in the flat folder has no location to speak for it, and is reported unfiled.
        let flat = root.appendingPathComponent("loose.md")
        try text.write(to: flat, atomically: true, encoding: .utf8)
        XCTAssertEqual(TranscriptStore.meta(of: flat)?.group, "")
        XCTAssertEqual((TranscriptGroupRepair.untagged(in: root) ?? []).count, 1)
    }
}
