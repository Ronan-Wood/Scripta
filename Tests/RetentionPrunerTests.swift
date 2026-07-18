import XCTest

/// Exercises `RetentionPruner.pruneIfNeeded` end-to-end against a real directory — the safety
/// guarantees the pure `RetentionGate` predicates can't reach on their own (audit M10). Each kept
/// fixture is built to fail EXACTLY ONE gate while passing every other, so its survival proves that
/// one gate is load-bearing: non-recursion, the `.md` extension check, the app-authored marker, the
/// transcript-filename shape, and the age/cutoff check. The single deleted fixture passes them all.
///
/// The pruner reads its three inputs from an injected `Config`, so this runs in the host-less logic
/// bundle without linking `AppSettings` (which drags in the Vision + engine graphs).
final class RetentionPrunerTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("RetentionPrunerTests-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    // MARK: - Fixtures

    /// A leading frontmatter block carrying the owner marker on its own line — an app-authored file.
    private let appAuthored = "---\napp: call-transcriber\ntitle: Sync\n---\n\nSpeaker: hello\n"
    /// A user's own note that happens to sit in the folder — no owner marker.
    private let foreign = "---\ntitle: My own note\ntags: [ideas]\n---\n\nnot ours\n"

    @discardableResult
    private func seed(_ relativePath: String, _ contents: String, ageDays: Double) throws -> URL {
        let url = root.appendingPathComponent(relativePath)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(contents.utf8).write(to: url)
        // fileDate() reads `creationDate ?? contentModificationDate`, so BOTH must move into the past
        // for a file to read as expired — setting only the modification date would leave the (now)
        // creation date winning and the file would never age out.
        let date = Date().addingTimeInterval(-ageDays * 86_400)
        try FileManager.default.setAttributes([.creationDate: date, .modificationDate: date],
                                              ofItemAtPath: url.path)
        return url
    }

    private func exists(_ url: URL) -> Bool { FileManager.default.fileExists(atPath: url.path) }

    // MARK: - The full pruning pass

    func testPrunesOnlyTheExpiredAppAuthoredTranscript() throws {
        // (a) app-authored + correctly-named + well past the window -> the only file that may be deleted.
        let expired = try seed("Budget review — 2026-05-01 0900.md", appAuthored, ageDays: 60)
        // (b) app-authored + expired, but the name isn't a transcript name -> the filename gate keeps it.
        let wrongName = try seed("My Ideas.md", appAuthored, ageDays: 60)
        // (c) correctly-named + expired, but no owner marker -> the app-authored gate keeps it.
        let noMarker = try seed("Team notes — 2026-05-02 1000.md", foreign, ageDays: 60)
        // (d) an IDENTICAL fully-qualifying file one level down -> non-recursion keeps it (the shallow
        //     scan never descends). This is the guarantee the M10 finding named explicitly.
        let nested = try seed("Archived/Budget review — 2026-05-01 0900.md", appAuthored, ageDays: 60)
        // (e) app-authored + correctly-named but only a day old -> the age/cutoff gate keeps it.
        let tooRecent = try seed("Fresh sync — 2026-07-17 1400.md", appAuthored, ageDays: 1)
        // (f) app-authored + expired + transcript-shaped name but a .txt extension -> the extension
        //     gate keeps it.
        let notMarkdown = try seed("Old recording — 2026-05-04 1200.txt", appAuthored, ageDays: 60)

        RetentionPruner.pruneIfNeeded(.init(enabled: true, days: 30, folder: root))

        XCTAssertFalse(exists(expired), "(a) expired app-authored transcript should have been pruned")
        XCTAssertTrue(exists(wrongName), "(b) non-transcript filename must survive")
        XCTAssertTrue(exists(noMarker), "(c) file without the owner marker must survive")
        XCTAssertTrue(exists(nested), "(d) qualifying file in a subdirectory must survive (non-recursion)")
        XCTAssertTrue(exists(tooRecent), "(e) file inside the retention window must survive")
        XCTAssertTrue(exists(notMarkdown), "(f) non-.md file must survive")
    }

    /// The first guard in pruneIfNeeded: with retention disabled, nothing is ever touched — even a
    /// file that would otherwise qualify on every axis.
    func testDisabledRetentionDeletesNothing() throws {
        let qualifying = try seed("Budget review — 2026-05-01 0900.md", appAuthored, ageDays: 60)

        RetentionPruner.pruneIfNeeded(.init(enabled: false, days: 30, folder: root))

        XCTAssertTrue(exists(qualifying), "retention disabled must delete nothing")
    }
}
