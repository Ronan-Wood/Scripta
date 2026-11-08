import Foundation
import XCTest
@testable import SubstrateKit

/// The wire version this client speaks is the engine's, as the engine states it in its contract.
/// A bump on one side only would refuse every call between this app and its own bundled engine.
final class WireParityTests: XCTestCase {
    /// Where this client and a contract disagree about the wire, one line per constant. A function
    /// rather than four assertions, so the test below can show it catches a contract that differs.
    static func disagreements(with contract: EngineContract) -> [String] {
        let wire = contract.wire
        return [("version", "\(wire.version)", "\(SubstrateWire.version)"),
                ("header", wire.header, SubstrateWire.header),
                ("mismatch", "\(wire.mismatch)", "\(SubstrateWire.mismatchCode)"),
                ("unstated", "\(wire.unstated)", "\(SubstrateWire.unstated)")]
            .filter { $0.1 != $0.2 }
            .map { "\($0.0): engine \($0.1), client \($0.2)" }
    }

    func testTheClientSpeaksTheEnginesWire() throws {
        XCTAssertEqual(Self.disagreements(with: try EngineContract.load()), [])
    }

    /// The regression this gate exists for: an engine one wire version ahead must not pass. Built
    /// from the real contract with only `wire.version` moved, so nothing else can be what fails it.
    func testAContractOneWireVersionAheadFails() throws {
        let data = try Data(contentsOf: EngineContract.url)
        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        var wire = try XCTUnwrap(object["wire"] as? [String: Any])
        let version = try XCTUnwrap(wire["version"] as? Int)
        wire["version"] = version + 1
        object["wire"] = wire
        let ahead = try EngineContract(data: JSONSerialization.data(withJSONObject: object))

        XCTAssertEqual(Self.disagreements(with: ahead),
                       ["version: engine \(version + 1), client \(SubstrateWire.version)"])
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
