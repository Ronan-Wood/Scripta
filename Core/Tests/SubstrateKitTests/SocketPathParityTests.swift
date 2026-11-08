import Foundation
import XCTest
@testable import SubstrateKit

/// The client's default socket and the engine's are one path, and it is the engine's own.
///
/// Through 0.3.4 both sides defaulted to a folder under Scripta's Application Support, so an
/// engine run with no app listened inside an app's layout. Each side spelled the path separately,
/// so the two could also drift and present as "the engine is down".
final class SocketPathParityTests: XCTestCase {
    func testTheClientDefaultIsTheEngineDefault() throws {
        let engines = try EngineContract.load().socket.defaultPath
        XCTAssertEqual((engines as NSString).expandingTildeInPath, SubstrateClient.defaultSocketPath)
    }
}
