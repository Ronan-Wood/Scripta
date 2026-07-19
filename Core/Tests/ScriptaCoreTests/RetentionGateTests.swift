import XCTest
@testable import ScriptaCore
@testable import ScriptaShared

/// Covers the retention pruner's app-authored gate — the guard that keeps a user's surrounding
/// Obsidian vault from ever losing a file the app didn't create (audit M10). These are pure
/// predicates, so they're tested in isolation without the app.
final class RetentionGateTests: XCTestCase {
    private var tmp: URL!

    override func setUpWithError() throws {
        tmp = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RetentionGateTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: tmp, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: tmp)
    }

    private func write(_ name: String, _ contents: String) throws -> URL {
        let url = tmp.appendingPathComponent(name)
        try Data(contents.utf8).write(to: url)
        return url
    }

    // MARK: - hasTranscriptFilename (only files the writer produced may match)

    func testFilenameShapeAccepted() {
        XCTAssertTrue(RetentionGate.hasTranscriptFilename(URL(fileURLWithPath: "/x/Budget review — 2026-07-18 1432.md")))
        XCTAssertTrue(RetentionGate.hasTranscriptFilename(URL(fileURLWithPath: "/x/Budget review — 2026-07-18 1432 (2).md")))
    }

    func testFilenameShapeRejected() {
        // A user's own note/document that merely lives in the output folder.
        XCTAssertFalse(RetentionGate.hasTranscriptFilename(URL(fileURLWithPath: "/x/My Ideas.md")))
        XCTAssertFalse(RetentionGate.hasTranscriptFilename(URL(fileURLWithPath: "/x/Project — notes.md")))
        // Right title-separator but missing the HHmm time.
        XCTAssertFalse(RetentionGate.hasTranscriptFilename(URL(fileURLWithPath: "/x/Call — 2026-07-18.md")))
        // A timestamp that isn't anchored at the end of the name.
        XCTAssertFalse(RetentionGate.hasTranscriptFilename(URL(fileURLWithPath: "/x/2026-07-18 1432 recap.md")))
    }

    // MARK: - isAppAuthored (the owner marker must be on its own line in the leading frontmatter)

    func testMarkerOnOwnLineAccepted() throws {
        let url = try write("t.md", "---\napp: call-transcriber\ntitle: Hi\n---\n\nbody\n")
        XCTAssertTrue(RetentionGate.isAppAuthored(url))
    }

    func testQuotedMarkerAccepted() throws {
        let url = try write("t.md", "---\napp: \"call-transcriber\"\n---\n\nbody\n")
        XCTAssertTrue(RetentionGate.isAppAuthored(url))
    }

    func testNonTranscriptMarkerRejected() throws {
        // A note/doc carries a DIFFERENT marker value — must not count as a transcript.
        let url = try write("t.md", "---\napp: call-transcriber-note\n---\n\nbody\n")
        XCTAssertFalse(RetentionGate.isAppAuthored(url))
    }

    func testNoMarkerRejected() throws {
        let url = try write("t.md", "---\ntitle: My note\ntags: [ideas]\n---\n\nbody\n")
        XCTAssertFalse(RetentionGate.isAppAuthored(url))
    }

    func testMarkerOnlyInBodyRejected() throws {
        // The marker text appears in the body, not the frontmatter — a note quoting us stays safe.
        let url = try write("t.md", "---\ntitle: My note\n---\n\napp: call-transcriber is mentioned here\n")
        XCTAssertFalse(RetentionGate.isAppAuthored(url))
    }

    func testNoFrontmatterRejected() throws {
        let url = try write("t.md", "just some text with app: call-transcriber inline\n")
        XCTAssertFalse(RetentionGate.isAppAuthored(url))
    }

    func testMarkerBeyondHeadReadFailsClosed() throws {
        // A frontmatter block whose closing `---` (and the marker) sit past the 2 KB head read must
        // fail CLOSED — treated as not app-authored, so a file we can't fully verify is never pruned.
        let padding = String(repeating: "x: \(String(repeating: "y", count: 80))\n", count: 40)  // > 2 KB
        let url = try write("t.md", "---\n\(padding)app: call-transcriber\n---\n\nbody\n")
        XCTAssertFalse(RetentionGate.isAppAuthored(url))
    }

    func testMissingFileRejected() {
        XCTAssertFalse(RetentionGate.isAppAuthored(tmp.appendingPathComponent("does-not-exist.md")))
    }
}
