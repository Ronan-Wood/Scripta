import Foundation
import XCTest
@testable import SubstrateKit

/// The wire version this client speaks is the engine's, read from `substrate/substrate/wire.py`.
/// A bump on one side only would refuse every call between this app and its own bundled engine.
final class WireParityTests: XCTestCase {
    /// A FAILURE, not a skip, when the declaration moves: a parity gate that quietly finds nothing
    /// to compare is worse than one that cannot run.
    private struct Undeclared: Error, CustomStringConvertible {
        let description: String
    }

    private func value(_ name: String, in text: String) throws -> String {
        guard let match = text.range(of: "(?m)^\(name) = (.+)$", options: .regularExpression)
        else { throw Undeclared(description: "wire.py no longer declares \(name) on one line") }
        return String(text[match].dropFirst(name.count + 3))
    }

    func testTheClientSpeaksTheEnginesWire() throws {
        let text = try PythonSource.load("substrate/substrate/wire.py").text
        XCTAssertEqual(try value("VERSION", in: text), "\(SubstrateWire.version)")
        XCTAssertEqual(try value("HEADER", in: text), "\"\(SubstrateWire.header)\"")
        XCTAssertEqual(try value("MISMATCH", in: text), "\(SubstrateWire.mismatchCode)")
        XCTAssertEqual(try value("UNSTATED", in: text), "\(SubstrateWire.unstated)")
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
