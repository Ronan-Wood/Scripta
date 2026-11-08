import Darwin
import Foundation
import XCTest
@testable import ScriptaCore

/// Clients registered through 0.3.4 hold the socket's old path. It becomes a link to the new one,
/// but never by taking it from something still listening there.
final class LegacyEngineSocketTests: XCTestCase {
    private var root: URL!

    override func setUpWithError() throws {
        // Under /tmp: an XCTest temporary directory can push a socket path past sun_path's 104 bytes.
        root = URL(fileURLWithPath: "/tmp", isDirectory: true)
            .appendingPathComponent("les-\(UUID().uuidString.prefix(8))", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
    }

    override func tearDownWithError() throws {
        try? FileManager.default.removeItem(at: root)
    }

    private func legacyFolder() throws -> String {
        let folder = root.appendingPathComponent("old").path
        try FileManager.default.createDirectory(atPath: folder, withIntermediateDirectories: false,
                                                attributes: [.posixPermissions: 0o700])
        return folder
    }

    private var target: String { root.appendingPathComponent("new.sock").path }

    private func destination(_ path: String) -> String? {
        try? FileManager.default.destinationOfSymbolicLink(atPath: path)
    }

    /// A bound socket at `path`, listening when `listen` is true. Returns its descriptor.
    private func bind(_ path: String, listen: Bool) throws -> Int32 {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { $0.copyBytes(from: bytes) }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        XCTAssertEqual(bound, 0, String(cString: strerror(errno)))
        if listen { XCTAssertEqual(Darwin.listen(fd, 1), 0) }
        return fd
    }

    func testNoLegacyFolderMeansNothingIsCreated() {
        let legacy = root.appendingPathComponent("absent/substrate.sock").path
        XCTAssertEqual(LegacyEngineSocket.link(legacy: legacy, to: target), .noLegacyFolder)
        XCTAssertFalse(FileManager.default.fileExists(atPath: (legacy as NSString)
            .deletingLastPathComponent))
    }

    func testAnEmptyLegacyFolderGetsTheLink() throws {
        let legacy = try legacyFolder() + "/substrate.sock"
        XCTAssertEqual(LegacyEngineSocket.link(legacy: legacy, to: target), .linked)
        XCTAssertEqual(destination(legacy), target)
        XCTAssertEqual(LegacyEngineSocket.link(legacy: legacy, to: target), .linked)
    }

    func testAStoppedEnginesLeftoverIsReplaced() throws {
        let legacy = try legacyFolder() + "/substrate.sock"
        let fd = try bind(legacy, listen: false)
        close(fd)
        XCTAssertEqual(LegacyEngineSocket.link(legacy: legacy, to: target), .linked)
        XCTAssertEqual(destination(legacy), target)
    }

    /// A live engine whose backlog is full refuses connections exactly like a leftover, so the
    /// probe alone would take its path and orphan it. The lock every engine holds decides.
    func testAnEngineHoldingItsLockKeepsItsPathEvenWhenItRefusesConnections() throws {
        let legacy = try legacyFolder() + "/substrate.sock"
        close(try bind(legacy, listen: false))
        let held = open(legacy + ".lock", O_RDWR | O_CREAT, 0o600)
        XCTAssertGreaterThanOrEqual(held, 0)
        defer { close(held) }
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(LegacyEngineSocket.link(legacy: legacy, to: target), .liveListener)
        XCTAssertNil(destination(legacy))
    }

    func testAnUnheldLockBesideALeftoverDoesNotStopTheLink() throws {
        let legacy = try legacyFolder() + "/substrate.sock"
        close(try bind(legacy, listen: false))
        close(open(legacy + ".lock", O_RDWR | O_CREAT, 0o600))
        XCTAssertEqual(LegacyEngineSocket.link(legacy: legacy, to: target), .linked)
        XCTAssertEqual(destination(legacy), target)
    }

    /// The lock's name is the engine's, or the lock check silently never runs and only the probe
    /// is left: the full-backlog case it exists for.
    func testTheLockSpellingIsTheEngines() throws {
        XCTAssertEqual(try EngineVocabulary.load().socket.lockSuffix, LegacyEngineSocket.lockSuffix,
                       "the engine no longer names its lock <socket>\(LegacyEngineSocket.lockSuffix)")
    }

    /// With no lock file there was nothing held across the unlink and the link, so an engine could
    /// claim the path in between. The lock is created and taken now; one held elsewhere stops it.
    func testTheLockIsTakenEvenWhenNoEngineEverCreatedIt() throws {
        let legacy = try legacyFolder() + "/substrate.sock"
        close(try bind(legacy, listen: false))
        XCTAssertEqual(LegacyEngineSocket.link(legacy: legacy, to: target), .linked)
        XCTAssertTrue(FileManager.default.fileExists(atPath: legacy + LegacyEngineSocket.lockSuffix))
    }

    func testAHeldLockStopsAWrongLinkBeingRepointed() throws {
        let legacy = try legacyFolder() + "/substrate.sock"
        let elsewhere = root.appendingPathComponent("stale.sock").path
        XCTAssertEqual(symlink(elsewhere, legacy), 0)
        let held = open(legacy + LegacyEngineSocket.lockSuffix, O_RDWR | O_CREAT, 0o600)
        defer { close(held) }
        XCTAssertEqual(flock(held, LOCK_EX | LOCK_NB), 0)
        XCTAssertEqual(LegacyEngineSocket.link(legacy: legacy, to: target), .liveListener)
        XCTAssertEqual(destination(legacy), elsewhere)
    }

    /// Someone pointed the old path at another engine on purpose, and it answers.
    func testALinkToAnotherLiveEngineIsLeftAlone() throws {
        let legacy = try legacyFolder() + "/substrate.sock"
        let other = root.appendingPathComponent("other.sock").path
        let fd = try bind(other, listen: true)
        defer { close(fd) }
        XCTAssertEqual(symlink(other, legacy), 0)
        XCTAssertEqual(LegacyEngineSocket.link(legacy: legacy, to: target), .liveListener)
        XCTAssertEqual(destination(legacy), other)
    }

    func testTheEnginesOwnPathIsNeverLinkedToItself() throws {
        let legacy = try legacyFolder() + "/substrate.sock"
        close(try bind(legacy, listen: false))
        guard case .failed = LegacyEngineSocket.link(legacy: legacy, to: legacy) else {
            return XCTFail("a path was linked to itself")
        }
        var st = stat()
        XCTAssertEqual(lstat(legacy, &st), 0)
        XCTAssertEqual(st.st_mode & S_IFMT, S_IFSOCK, "the engine's own socket was replaced")
    }

    func testALinkSpelledDifferentlyIsAlreadyLinked() throws {
        let legacy = try legacyFolder() + "/substrate.sock"
        let spelled = root.path + "//new.sock"
        XCTAssertEqual(symlink(spelled, legacy), 0)
        XCTAssertEqual(LegacyEngineSocket.link(legacy: legacy, to: target), .linked)
        XCTAssertEqual(destination(legacy), spelled, "an equivalent link was rewritten")
    }

    func testALiveListenerKeepsItsPath() throws {
        let legacy = try legacyFolder() + "/substrate.sock"
        let fd = try bind(legacy, listen: true)
        defer { close(fd) }
        XCTAssertEqual(LegacyEngineSocket.link(legacy: legacy, to: target), .liveListener)
        XCTAssertNil(destination(legacy))
    }

    func testALinkToSomewhereElseIsRepointed() throws {
        let legacy = try legacyFolder() + "/substrate.sock"
        XCTAssertEqual(symlink(root.appendingPathComponent("stale.sock").path, legacy), 0)
        XCTAssertEqual(LegacyEngineSocket.link(legacy: legacy, to: target), .linked)
        XCTAssertEqual(destination(legacy), target)
    }

    func testAFileThatIsNotASocketIsLeftAlone() throws {
        let legacy = try legacyFolder() + "/substrate.sock"
        XCTAssertTrue(FileManager.default.createFile(atPath: legacy, contents: Data("x".utf8)))
        XCTAssertEqual(LegacyEngineSocket.link(legacy: legacy, to: target), .foreignFile)
        XCTAssertEqual(try String(contentsOfFile: legacy, encoding: .utf8), "x")
    }

    func testTheLegacyPathIsWhereClientsWereRegistered() {
        XCTAssertEqual(LegacyEngineSocket.legacyPath, NSHomeDirectory()
            + "/Library/Application Support/Scripta/engine/substrate.sock")
    }
}
