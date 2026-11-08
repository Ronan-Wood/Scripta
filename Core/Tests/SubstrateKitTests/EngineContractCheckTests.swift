import Foundation
import XCTest

/// `Distribution/engine-contract check` is what keeps the copy these decoders are tested against
/// (`Core/Tests/EngineContract/`) the engine's own frames. A check that passed on a stale copy would
/// leave every decoder test scoring frames the engine no longer sends, so each way a copy can drift
/// must fail it. Run on scratch copies of the real vendored frames, never on the committed ones.
final class EngineContractCheckTests: XCTestCase {
    private var scratch: URL!

    override func setUpWithError() throws {
        scratch = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-contract-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: scratch, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: scratch)
    }

    /// `#filePath`, not the working directory: `swift test` and Xcode disagree about cwd.
    private static let repository = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SubstrateKitTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Core
        .deletingLastPathComponent()   // repository root

    private struct Run {
        let status: Int32
        let output: String
    }

    private func run(_ arguments: [String]) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [Self.repository.appendingPathComponent("Distribution/engine-contract").path]
            + arguments
        let output = Pipe()
        process.standardOutput = output
        process.standardError = output
        try process.run()
        let data = output.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        return Run(status: process.terminationStatus, output: String(decoding: data, as: UTF8.self))
    }

    private func check(_ from: URL, _ to: URL) throws -> Run {
        try run(["check", "--from", from.path, "--to", to.path])
    }

    /// Two scratch copies of the vendored contract: an engine side and an app side.
    private func pair() throws -> (from: URL, to: URL) {
        let vendored = Self.repository.appendingPathComponent("Core/Tests/EngineContract")
        let from = scratch.appendingPathComponent("from")
        let to = scratch.appendingPathComponent("to")
        try FileManager.default.copyItem(at: vendored, to: from)
        try FileManager.default.copyItem(at: vendored, to: to)
        return (from, to)
    }

    func testAnIdenticalCopyPasses() throws {
        let (from, to) = try pair()
        let result = try check(from, to)
        XCTAssertEqual(result.status, 0, result.output)
    }

    /// The regression this check exists for: one byte of one vendored frame differs.
    func testOneChangedByteInAVendoredFrameFails() throws {
        let (from, to) = try pair()
        let frame = to.appendingPathComponent("frames/search.frame.json")
        var bytes = try Data(contentsOf: frame)
        let at = bytes.count / 2
        bytes[at] = bytes[at] == UInt8(ascii: "a") ? UInt8(ascii: "b") : UInt8(ascii: "a")
        try bytes.write(to: frame)

        let result = try check(from, to)
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("\(to.path)/frames/search.frame.json differ"),
                      result.output)
    }

    func testAFrameMissingFromTheCopyFails() throws {
        let (from, to) = try pair()
        try FileManager.default.removeItem(at: to.appendingPathComponent("frames/status.frame.json"))
        let result = try check(from, to)
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("Only in \(from.path)/frames: status.frame.json"),
                      result.output)
    }

    func testAFrameOnlyTheCopyHasFails() throws {
        let (from, to) = try pair()
        try Data("{}".utf8).write(to: to.appendingPathComponent("frames/stray.frame.json"))
        let result = try check(from, to)
        XCTAssertEqual(result.status, 1, result.output)
        XCTAssertTrue(result.output.contains("Only in \(to.path)/frames: stray.frame.json"),
                      result.output)
    }

    /// Anything but `frames/*.json` is refused, not compared: the copy may hold only what the
    /// engine's leak scan covers.
    func testAFileOutsideTheFramesAllowlistIsRefused() throws {
        let (from, to) = try pair()
        try Data("notes".utf8).write(to: from.appendingPathComponent("README.md"))
        try Data("{}".utf8).write(to: to.appendingPathComponent("README.md"))
        XCTAssertEqual(try check(from, to).status, 2)
    }

    func testTheSameFolderTwiceIsRefused() throws {
        let (from, _) = try pair()
        XCTAssertEqual(try check(from, from).status, 2)
    }

    /// APFS is case-insensitive by default, so `from` and `FROM` are one folder no string
    /// comparison equates. Skipped on a case-sensitive volume, where they are two folders.
    func testTheSameFolderSpelledInAnotherCaseIsRefused() throws {
        let (from, _) = try pair()
        let other = from.deletingLastPathComponent().appendingPathComponent("FROM")
        try XCTSkipUnless(FileManager.default.fileExists(atPath: other.path),
                          "this volume is case-sensitive")
        XCTAssertEqual(try check(from, other).status, 2)
        XCTAssertEqual(try run(["sync", "--from", from.path, "--to", other.path]).status, 2)
    }

    /// A new copy may not be made inside the source: the source would then fail its own check.
    func testSyncRefusesANewCopyInsideTheSource() throws {
        let (from, _) = try pair()
        let target = from.appendingPathComponent("frames/copy")
        XCTAssertEqual(try run(["sync", "--from", from.path, "--to", target.path]).status, 2)
        XCTAssertFalse(FileManager.default.fileExists(atPath: target.path))
    }

    /// A refused sync creates nothing, not even the folders on the way to its target.
    func testARefusedSyncLeavesNoFolderBehind() throws {
        let (from, _) = try pair()
        let target = from.appendingPathComponent("frames/new/deep/copy")
        XCTAssertEqual(try run(["sync", "--from", from.path, "--to", target.path]).status, 2)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: from.appendingPathComponent("frames/new").path))
    }

    /// A symlink would let the copy "match" by pointing at the source, so it is refused, not read.
    func testASymlinkInTheCopyIsRefused() throws {
        let (from, to) = try pair()
        let frame = to.appendingPathComponent("frames/expand.frame.json")
        try FileManager.default.removeItem(at: frame)
        try FileManager.default.createSymbolicLink(
            at: frame, withDestinationURL: from.appendingPathComponent("frames/expand.frame.json"))
        let result = try check(from, to)
        XCTAssertEqual(result.status, 2, result.output)
    }

    /// `[ -L link/ ]` tests what the link points at, so a trailing slash must not get a symlinked
    /// copy past the refusal and let it "match" the source it points to.
    func testACopyThatIsASymlinkIsRefusedWithATrailingSlash() throws {
        let (from, _) = try pair()
        let link = scratch.appendingPathComponent("link")
        try FileManager.default.createSymbolicLink(at: link, withDestinationURL: from)
        XCTAssertEqual(try run(["check", "--from", from.path, "--to", link.path + "/"]).status, 2)
        XCTAssertEqual(try run(["sync", "--from", from.path, "--to", link.path + "/"]).status, 2)
    }

    /// A mistyped `--to` naming a folder that is not a copy is refused, and nothing in it is touched.
    /// Without this, `sync --to Core/Tests` deleted every Swift test.
    func testSyncRefusesToReplaceAFolderThatIsNotACopy() throws {
        let (from, _) = try pair()
        let tests = scratch.appendingPathComponent("Tests")
        try FileManager.default.createDirectory(at: tests, withIntermediateDirectories: true)
        let work = tests.appendingPathComponent("Work.swift")
        try Data("let kept = true\n".utf8).write(to: work)

        XCTAssertEqual(try run(["sync", "--from", from.path, "--to", tests.path]).status, 2)
        XCTAssertTrue(FileManager.default.fileExists(atPath: work.path))
    }

    /// The source's own parent is not a copy either: the sync would delete the source with it.
    func testSyncRefusesAnAncestorOfTheSource() throws {
        let (from, _) = try pair()
        XCTAssertEqual(try run(["sync", "--from", from.path, "--to", scratch.path]).status, 2)
        XCTAssertTrue(FileManager.default.fileExists(
            atPath: from.appendingPathComponent("frames/search.frame.json").path))
    }

    /// An empty source would make every copy "match".
    func testAnEmptySourceIsRefused() throws {
        let from = scratch.appendingPathComponent("empty")
        try FileManager.default.createDirectory(at: from, withIntermediateDirectories: true)
        let (_, to) = try pair()
        let result = try check(from, to)
        XCTAssertEqual(result.status, 2, result.output)
    }

    /// `sync` replaces the copy whole: a changed frame is restored and a stray file is gone.
    func testSyncWritesACopyTheCheckAccepts() throws {
        let (from, to) = try pair()
        try Data("{}".utf8).write(to: to.appendingPathComponent("frames/search.frame.json"))
        try Data("{}".utf8).write(to: to.appendingPathComponent("frames/stray.frame.json"))

        let synced = try run(["sync", "--from", from.path, "--to", to.path])
        XCTAssertEqual(synced.status, 0, synced.output)
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: to.appendingPathComponent("frames/stray.frame.json").path))
        XCTAssertEqual(try check(from, to).status, 0)
    }
}
