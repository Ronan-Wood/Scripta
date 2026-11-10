import Foundation
import XCTest
@testable import SubstrateKit

/// The wire version this client speaks is one the engine serves, as the engine states it in its
/// contract, and so is the note format it writes. Outside the engine's range, every call between
/// this app and the engine it bundles would be refused.
final class WireParityTests: XCTestCase {
    /// Where this client and a contract disagree about the wire, one line per constant. A function
    /// rather than five assertions, so the tests below can show it catches a contract that differs.
    static func disagreements(with contract: EngineContract, wire speaking: Int = SubstrateWire.version,
                              notes writing: Int = SubstrateNotes.version) -> [String] {
        let wire = contract.wire, notes = contract.notes
        let ranges = [("version", wire.minVersion, wire.version, speaking),
                      ("notes", notes.minVersion, notes.version, writing)]
            .filter { $0.1 > $0.2 || !($0.1...$0.2).contains($0.3) }
            .map { "\($0.0): engine \($0.1) to \($0.2), client \($0.3)" }
        return ranges + [("header", wire.header, SubstrateWire.header),
                         ("mismatch", "\(wire.mismatch)", "\(SubstrateWire.mismatchCode)"),
                         ("unstated", "\(wire.unstated)", "\(SubstrateWire.unstated)")]
            .filter { $0.1 != $0.2 }
            .map { "\($0.0): engine \($0.1), client \($0.2)" }
    }

    /// The real contract with fields of one section moved, each by `delta`.
    private func contract(_ section: String, _ keys: String..., by delta: Int) throws -> EngineContract {
        let data = try Data(contentsOf: EngineContract.url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var part = try XCTUnwrap(object[section] as? [String: Any])
        for key in keys { part[key] = try XCTUnwrap(part[key] as? Int) + delta }
        object[section] = part
        return try EngineContract(data: JSONSerialization.data(withJSONObject: object))
    }

    func testTheClientSpeaksTheEnginesWire() throws {
        XCTAssertEqual(Self.disagreements(with: try EngineContract.load()), [])
    }

    /// `engine.lock`'s `wire=` is the version this client speaks: `Distribution/fetch-engine`
    /// refuses a pinned release whose contract does not serve it, so the two must be one number.
    func testTheEngineLockStatesTheWireThisClientSpeaks() throws {
        let lock = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // SubstrateKitTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repository root
            .appendingPathComponent("engine.lock")
        let lines = try String(contentsOf: lock, encoding: .utf8).split(separator: "\n")
        XCTAssertEqual(lines.filter { $0.hasPrefix("wire=") }, ["wire=\(SubstrateWire.version)"])
    }

    /// THE RANGE: an engine one wire version ahead, which still serves this client, agrees.
    func testAnEngineOneVersionAheadThatStillServesThisClientAgrees() throws {
        XCTAssertEqual(Self.disagreements(with: try contract("wire", "version", by: 1)), [])
        XCTAssertEqual(Self.disagreements(with: try contract("notes", "version", by: 1)), [])
    }

    /// The gate this exists for: an engine whose oldest served version is above this client's, a
    /// breaking change, fails. Built from the real contract with the whole range moved up one, so
    /// it is a well-formed range that starts above this client, not an inverted one.
    func testAnEngineWhoseRangeStartsAboveThisClientFails() throws {
        let wire = try EngineContract.load().wire, notes = try EngineContract.load().notes
        XCTAssertEqual(Self.disagreements(with: try contract("wire", "min_version", "version", by: 1)),
                       ["version: engine \(wire.minVersion + 1) to \(wire.version + 1), client \(SubstrateWire.version)"])
        XCTAssertEqual(Self.disagreements(with: try contract("notes", "min_version", "version", by: 1)),
                       ["notes: engine \(notes.minVersion + 1) to \(notes.version + 1), client \(SubstrateNotes.version)"])
    }

    /// A client above the engine's newest version is not served: the app is newer than anything
    /// the engine speaks. Asked of the real contract for a client two versions ahead of it.
    func testAClientAboveTheEnginesNewestVersionFails() throws {
        let real = try EngineContract.load()
        let ahead = real.wire.version + 2, notesAhead = real.notes.version + 2
        XCTAssertEqual(Self.disagreements(with: real, wire: ahead, notes: notesAhead),
                       ["version: engine \(real.wire.minVersion) to \(real.wire.version), client \(ahead)",
                        "notes: engine \(real.notes.minVersion) to \(real.notes.version), client \(notesAhead)"])
    }

    /// From the app's side of a live call: a reply in this app's version or a newer one is read,
    /// and one older than this app's is refused before it is decoded.
    func testAReplyInAnOlderVersionIsRefusedAndANewerOneIsRead() throws {
        XCTAssertNil(SubstrateWire.unread(["3"], reading: 3))
        XCTAssertNil(SubstrateWire.unread(["4"], reading: 3))
        let why = try XCTUnwrap(SubstrateWire.unread(["2"], reading: 3))
        XCTAssertTrue(why.contains("speaks substrate wire 2") && why.contains("update the engine"), why)
    }

    /// The engine refusing this client's version arrives as a JSON-RPC error. It is the same fact
    /// as a reply in a version this client does not read, and is reported as one.
    func testTheEnginesRefusalOfThisClientsVersionIsAWireMismatch() {
        let frame = Data(#"""
            {"jsonrpc":"2.0","id":4,"error":{"code":-32010,"message":"this engine speaks substrate wire 2 and the client speaks 1","data":{"client":1,"supported":[2,2]}}}
            """#.utf8)
        let call: SubstrateCall<WireScopeList> = SubstrateClient.interpret(frame: frame,
                                                                          expectedID: 4)
        guard case .transportFailure(.wireMismatch(let why)) = call else {
            return XCTFail("expected .wireMismatch, got \(call)")
        }
        XCTAssertTrue(why.contains("speaks substrate wire 2"), why)
    }

    func testAnUnreadableValueIsNotEchoedBackWhole() throws {
        let why = try XCTUnwrap(SubstrateWire.unread([String(repeating: "x", count: 5000)]))
        XCTAssertLessThan(why.count, 120, why)
    }

    func testDeclaredReadsOnlyAPlainPositiveInteger() {
        XCTAssertEqual(SubstrateWire.declared(nil), 1)
        XCTAssertEqual(SubstrateWire.declared(" 3 "), 3)
        XCTAssertEqual(SubstrateWire.declared(" 3\t"), 3)
        for bad in ["", "x", "0", "+1", "1e2", "٣", "１", "1\u{0B}", "\u{1C}1", "1234567890"] {
            XCTAssertNil(SubstrateWire.declared(bad), bad)
        }
    }
}
