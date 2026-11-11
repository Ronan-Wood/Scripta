import XCTest
@testable import SubstrateKit

/// `substrate grants --json`, as the Settings → Clients pane reads it. The fixture is the shape
/// `substrate.grants.listing` writes, with synthetic names.
final class EngineGrantsTests: XCTestCase {
    func testTheListingDecodes() throws {
        let json = """
        {"granted": [{"client": "claude-code", "generation": 2, "scopes": ["*"],
                      "issued_at": "2026-11-10T21:00:00+00:00"}],
         "requested": [{"client": "zed", "client_info": {"name": "Zed", "version": "1.0"},
                        "at": "2026-11-10T21:05:00+00:00"},
                       {"client": "demo-agent", "client_info": null,
                        "at": "2026-11-10T21:06:00+00:00"}]}
        """
        let listing = try XCTUnwrap(EngineGrants.parse(json))
        XCTAssertEqual(listing.granted.map(\.client), ["claude-code"])
        XCTAssertEqual(listing.granted.first?.generation, 2)
        XCTAssertEqual(listing.granted.first?.scopes, ["*"])
        XCTAssertEqual(listing.requested.map(\.client), ["zed", "demo-agent"])
        XCTAssertEqual(listing.requested.first?.clientInfo?.version, "1.0")
        XCTAssertNil(listing.requested.last?.clientInfo)
    }

    /// An engine older than grants prints usage, not JSON: unknown, never "nobody may write".
    func testWhatIsNotAListingIsUnknown() {
        XCTAssertNil(EngineGrants.parse("usage: substrate [-h] {ingest,…}"))
        XCTAssertNil(EngineGrants.parse(""))
    }

    func testClientNamesAreTheEnginesShape() {
        for good in ["claude-code", "claude-ai", "zed", "a", "x.y_z-1", String(repeating: "a", count: 64)] {
            XCTAssertTrue(EngineGrants.isClientName(good), good)
        }
        for bad in ["", "Claude Code", "-x", ".x", "a/b", "../x", String(repeating: "a", count: 65)] {
            XCTAssertFalse(EngineGrants.isClientName(bad), bad)
        }
    }
}
