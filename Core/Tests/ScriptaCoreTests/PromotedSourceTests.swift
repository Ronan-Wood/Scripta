import XCTest
@testable import ScriptaCore

/// The name that authorises a recursive, trashless delete.
///
/// WHAT RESTS ON THIS. `SubstrateLibraryModel.remove(source:)` calls `FileManager.removeItem` — no
/// trash, no backup — on a target inside the operator's own output folder. Its guard is: the parent
/// (resolved through symlinks) is one of the two promotion directories, the name passes
/// `isDirectoryName`, the entry is a directory or a symlink, and a directory additionally passes
/// `isAuthoredDirectory`. The parent check alone was not enough, because one of those parents is
/// `_sources/transcripts/`, which is also where CAPTURE writes recorded calls; and the name alone
/// was not enough, because an operator's own directory can wear that shape.
///
/// It has to be exactly right in BOTH directions, and the two failures look nothing alike: too wide
/// deletes something unrecreatable, too narrow refuses the orphan-recovery the rail exists for and
/// says "not a source this app added" about a directory plainly inside the library.
final class PromotedSourceTests: XCTestCase {

    private func origin(_ path: String) -> URL { URL(fileURLWithPath: path) }

    // MARK: - What capture writes must never be deletable

    /// THE BLOCKER THIS EXISTS FOR. Capture writes `<Title> — <date> <time>.md` into
    /// `_sources/transcripts/`, which the delete guard admits as a parent.
    func testARecordedCallFilenameIsNeverAPromotedSourceName() {
        let calls = [
            "Call — 2026-08-07 1021.md",
            "Quarterly sync — 2026-08-17 1150.md",
            "Call — 2026-08-07 1021 (2).md",
            "standup-deadbeef.md",              // a promoted NAME that is a file
            "a-abcdef12.md",
        ]
        for name in calls {
            XCTAssertFalse(PromotedSource.isDirectoryName(name),
                           "a recorded call would have been admitted to removeItem: \(name)")
        }
    }

    /// The structural reason, pinned so a future change to the digest length cannot quietly break
    /// it: any extension SHORTER than the digest puts its `.` inside the trailing digest, so with
    /// `digestLength == 8` everything up to seven characters is disqualified by the dot alone.
    /// Covered here from two through six.
    func testAnyShortExtensionLandsInsideTheDigestAndDisqualifiesTheName() {
        for ext in ["md", "txt", "pdf", "docx", "m4a", "caf", "jpeg", "xhtml", "sqlite"] {
            let name = "notes-abcdef12.\(ext)"
            XCTAssertFalse(PromotedSource.isDirectoryName(name), name)
        }
    }

    // MARK: - What promote writes must always be deletable

    /// The round trip that matters: anything the writer produces, the recogniser accepts. A false
    /// rejection here is an orphan the operator cannot clear through the app.
    func testEveryNameTheWriterProducesIsRecognised() {
        let origins = [
            "/Users/x/Documents/report.pdf",
            "/Users/x/Documents/Quarterly Sync 2026.docx",
            "/Users/x/notes",                                  // no extension
            "/Users/x/.hidden.md",
            "/Users/x/ALL CAPS FILE.PDF",
            "/Users/x/123456.txt",
            "/Users/x/a.txt",                                  // one-character readable half
            "/Users/x/研究.pdf",                                // slugs to empty -> "document"
            "/Users/x/— — —.pdf",                              // ditto
            "/Users/x/" + String(repeating: "long", count: 30) + ".pdf",   // past the 48-char cut
            "/Users/x/" + String(repeating: "a", count: 47) + " b.pdf",    // the 49-char boundary
            "/Users/x/report-a1b2c3d4.pdf",                    // already shaped like a promoted name
        ]
        for path in origins {
            let name = PromotedSource.directoryName(origin: origin(path))
            XCTAssertTrue(PromotedSource.isDirectoryName(name),
                          "the writer produced a name the recogniser refuses: \(name) (from \(path))")
        }
    }

    /// The truncation boundary deserves its own gate. `slug` breaks its loop at `limit`, but the
    /// separator and the character after it are appended in ONE iteration — so the readable half can
    /// reach 49 characters, and the recogniser's `readable == slug(readable)` equality only holds
    /// because re-slugging reproduces that same cut. This is the case a hand-trace gets wrong.
    func testTheSlugTruncationBoundaryStillRoundTrips() {
        var sawFortyNine = false
        for filler in 30...70 {
            let path = "/Users/x/" + String(repeating: "a", count: filler) + " b.pdf"
            let name = PromotedSource.directoryName(origin: origin(path))
            let readable = String(name.dropLast(PromotedSource.digestLength + 1))
            if readable.count == 49 { sawFortyNine = true }
            XCTAssertTrue(PromotedSource.isDirectoryName(name),
                          "readable half of \(readable.count) chars was refused: \(name)")
        }
        XCTAssertTrue(sawFortyNine, "the 49-character case was never produced — the gate proved nothing")
    }

    // MARK: - What the operator writes must not be deletable

    func testOperatorNamesAreNotRecognised() {
        let theirs = [
            "handmade", "passages", "_meta.md", "10-reference", "notes",
            "-abcdef12",                        // no readable half
            "abcdef12",                         // digest alone
            "report-abcdef1",                   // seven hex
            "report-abcdef123",                 // nine
            "report-abcdefg2",                  // not hex
            "report-ABCDEF12",                  // uppercase is not what %02x emits
            "Report-abcdef12",                  // readable half is not a slug
            "report_sync-abcdef12",             // underscore
            "report--sync-abcdef12",            // doubled separator
            "report sync-abcdef12",             // space
            "café-abcdef12",                    // non-ASCII
            "", "..", ".",
        ]
        for name in theirs {
            XCTAssertFalse(PromotedSource.isDirectoryName(name),
                           "an operator's own entry would have been deleted: \(name.debugDescription)")
        }
    }

    /// Composed and decomposed forms both have to be refused. Swift string equality is canonical, so
    /// an NFD name could otherwise compare equal to an NFC slug.
    func testUnicodeNormalisationFormsAreBothRefused() {
        XCTAssertFalse(PromotedSource.isDirectoryName("caf\u{E9}-abcdef12"))        // NFC
        XCTAssertFalse(PromotedSource.isDirectoryName("cafe\u{301}-abcdef12"))      // NFD
        XCTAssertFalse(PromotedSource.isDirectoryName("\u{FF41}-abcdef12"))         // fullwidth a
    }

    // MARK: - Authorship, the second half of the delete authorisation

    /// THE NAME IS A SHAPE; THE MARKER'S CONTENT IS EVIDENCE. `<slug>-<8 hex>` is not rare enough to
    /// be proof on its own — `my-notes-2026abcd`, `backup-20250101` and `photos-20240704` all pass
    /// every clause of `isDirectoryName`. And the marker FILE proves nothing either: `_meta.md` is
    /// the engine's own per-source convention, so an operator building a source by hand writes one.
    /// Only the authorship line `promote` puts inside it distinguishes ours.
    func testADirectoryWearingTheNameIsNotAuthoredWithoutTheMarker() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("promoted-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: root) }

        // The accidental collision: right shape, not ours.
        let theirs = root.appendingPathComponent("my-notes-2026abcd", isDirectory: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        XCTAssertTrue(PromotedSource.isDirectoryName(theirs.lastPathComponent),
                      "the fixture must pass the NAME check, or it tests nothing")
        XCTAssertFalse(PromotedSource.isAuthoredDirectory(at: theirs),
                       "a directory with no marker was treated as one this app wrote")

        // THE OPERATOR'S OWN HAND-BUILT SOURCE. `_meta.md` is the ENGINE's convention
        // (`vault._source_meta`), not this app's signature — there is one on this machine at
        // core-vault/10-reference/frozen/software-dev/ddia-2e/. A guard that took the file's
        // existence as authorship would call this ours and recursively delete it.
        try Data("---\nstatus: active\n---\n\n# My own source\n".utf8)
            .write(to: theirs.appendingPathComponent(PromotedSource.markerFile))
        XCTAssertFalse(PromotedSource.isAuthoredDirectory(at: theirs),
                       "a hand-built engine source was treated as one this app wrote")

        // Ours: the marker carries the authorship line `promote` writes.
        try Data("---\n---\n\n\(PromotedSource.authorshipLine)\n".utf8)
            .write(to: theirs.appendingPathComponent(PromotedSource.markerFile))
        XCTAssertTrue(PromotedSource.isAuthoredDirectory(at: theirs))
    }

    /// The marker alone is not enough either — both halves have to hold, or a marker dropped into
    /// any directory would authorise deleting it.
    func testTheMarkerAloneDoesNotAuthoriseADirectory() throws {
        let root = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("promoted-\(UUID().uuidString)", isDirectory: true)
        let theirs = root.appendingPathComponent("Documents", isDirectory: true)
        try FileManager.default.createDirectory(at: theirs, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: root) }
        try Data(PromotedSource.authorshipLine.utf8)
            .write(to: theirs.appendingPathComponent(PromotedSource.markerFile))
        XCTAssertFalse(PromotedSource.isAuthoredDirectory(at: theirs))
    }

    /// The writer and the guard must name the same file. They were spelled independently in two
    /// files — the writer in the app target, the guard beside it — which is the split this type
    /// exists to close for the naming half.
    func testPromoteWritesTheMarkerThisTypeLooksFor() throws {
        let writer = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
            .appendingPathComponent("Sources/App/SubstrateLibraryVault.swift")
        guard FileManager.default.fileExists(atPath: writer.path) else {
            throw XCTSkip("app source not present at \(writer.path)")
        }
        let source = try String(contentsOf: writer, encoding: .utf8)
        XCTAssertTrue(source.contains("PromotedSource.markerFile"),
                      "promote spells the marker filename itself instead of using the constant the "
                      + "delete guard reads — the two can now drift apart silently")
        // THE LITERAL MUST BE ABSENT, not the constant present. Asserting the constant appears
        // somewhere in the file is satisfied by the refusal MESSAGE further down, which uses it
        // legitimately — so `meta()` could revert to a hard-coded string and this would still pass,
        // which is exactly the drift it claims to prevent.
        XCTAssertFalse(source.contains(PromotedSource.authorshipLine),
                       "the authorship line appears as literal text in the writer instead of being "
                       + "interpolated from the constant the delete guard reads — reword one and "
                       + "every delete starts refusing sources this app wrote")
    }

    // MARK: - The key

    /// KEYED ON THE ORIGIN PATH, not the filename and not the content — re-adding an edited file
    /// must land on the same directory and replace it rather than mint a second one that answers
    /// beside the first.
    func testTheNameIsStableForOnePathAndDistinctAcrossPaths() {
        let a = PromotedSource.directoryName(origin: origin("/Users/x/a/report.pdf"))
        let b = PromotedSource.directoryName(origin: origin("/Users/x/b/report.pdf"))
        XCTAssertEqual(a, PromotedSource.directoryName(origin: origin("/Users/x/a/report.pdf")))
        XCTAssertNotEqual(a, b, "same filename in two folders collided onto one directory")
        XCTAssertTrue(a.hasPrefix("report-"), a)
    }

    /// The sweep for stale copies of one origin matches on this suffix, and it must be the same
    /// digest the name carries — otherwise `promote` leaves the wrong-tier copy live and both answer.
    func testTheDigestSuffixMatchesTheNameItWrites() {
        let url = origin("/Users/x/Documents/report.pdf")
        XCTAssertTrue(PromotedSource.directoryName(origin: url)
            .hasSuffix(PromotedSource.digestSuffix(origin: url)))
    }

    /// A path that differs only by `.` / `..` is the same path, so it must key the same.
    func testTheKeyIsStandardisedBeforeItIsHashed() {
        XCTAssertEqual(PromotedSource.directoryName(origin: origin("/Users/x/./a/report.pdf")),
                       PromotedSource.directoryName(origin: origin("/Users/x/a/report.pdf")))
    }
}
