import XCTest
@testable import SubstrateKit

/// An engine the app did not start is used only when it is the kind the app would have started.
/// Before this, any engine already on the socket was refused outright, so a `substrate serve` run on
/// its own was a wall rather than the engine.
final class EngineAttachTests: XCTestCase {
    private let mine = EngineAttach.Expectation(registry: "/r/scopes.toml", schema: 11)

    private func list(_ server: WireServerInfo?, registry: String = "/r/scopes.toml") -> WireScopeList {
        WireScopeList(scopes: [], registry: registry, server: server)
    }

    private func verdict(_ list: WireScopeList, schema: Int? = 11) -> EngineAttach.Verdict {
        EngineAttach.verdict(list, engineSchema: schema, expecting: mine)
    }

    private let serve = WireServerInfo(readOnly: true, agentMode: false, refreshEvery: 900)

    func testAReadOnlyServeIsAttached() {
        XCTAssertEqual(verdict(list(.init(readOnly: true, agentMode: false,
                                                       refreshEvery: 900))), .attach)
    }

    /// THE NOTE FORMAT. This app writes notes the engine indexes, so its format must be in the range
    /// the engine says it indexes. An engine that states none is older than the ranges, and indexed
    /// format 1, which is this app's.
    func testAnEngineIsAttachedOnlyWhenItIndexesThisAppsNoteFormat() {
        func notes(_ lowest: Int?, _ highest: Int?) -> EngineAttach.Verdict {
            verdict(list(.init(readOnly: true, agentMode: false, refreshEvery: 900,
                               notesVersion: highest, notesMinVersion: lowest)))
        }
        let mine = SubstrateNotes.version
        XCTAssertEqual(notes(nil, nil), .attach)
        XCTAssertEqual(notes(mine, mine), .attach)
        XCTAssertEqual(notes(mine, mine + 3), .attach, "an engine ahead that still indexes this format")
        let refused: [(Int?, Int?, String, String)] = [
            (mine + 1, mine + 2, "indexes note format \(mine + 1) to \(mine + 2)", "update this app"),
            (mine - 1, mine - 1, "indexes note format \(mine - 1) and", "update the engine"),
            // The engine's fault, whichever way round: an empty range, or half of one.
            (mine + 2, mine, "cannot hold", "update the engine"),
            (mine, nil, "cannot hold", "update the engine"),
            (nil, mine, "cannot hold", "update the engine"),
        ]
        for (lowest, highest, says, update) in refused {
            guard case .refuse(let why) = notes(lowest, highest) else {
                return XCTFail("note format \(String(describing: lowest)) to \(String(describing: highest)) was attached")
            }
            XCTAssertTrue(why.contains(says) && why.contains(update), why)
        }
    }

    /// The app no longer refreshes indexes itself, so an engine with no loop of its own would leave
    /// them ageing with nothing running that refreshes them.
    func testAServerThatRefreshesNothingIsRefused() {
        guard case .refuse(let why) = verdict(
            list(.init(readOnly: true, agentMode: false, refreshEvery: nil))) else {
            return XCTFail("a server with no refresh loop was attached")
        }
        XCTAssertTrue(why.contains("refreshes nothing"), why)
    }

    func testAWritableServerIsRefused() {
        guard case .refuse(let why) = verdict(
            list(.init(readOnly: false, agentMode: false, refreshEvery: 900))) else {
            return XCTFail("a writable server was attached")
        }
        XCTAssertTrue(why.contains("writes"), why)
    }

    func testAnAgentModeServerIsRefused() {
        guard case .refuse(let why) = verdict(
            list(.init(readOnly: true, agentMode: true, refreshEvery: nil))) else {
            return XCTFail("an agent-mode server was attached")
        }
        XCTAssertTrue(why.contains("agent-mode"), why)
    }

    /// This app's CLI writes an attached engine's indexes. Another registry would leave the calls
    /// it records where the engine never looks; another schema would have each rebuild the other's.
    func testAnEngineOnAnotherRegistryOrSchemaIsRefused() {
        guard case .refuse(let registry) = verdict(list(serve, registry: "/elsewhere/scopes.toml"))
        else { return XCTFail("an engine on another registry was attached") }
        XCTAssertTrue(registry.contains("/elsewhere/scopes.toml"), registry)
        guard case .refuse(let schema) = verdict(list(serve), schema: 12) else {
            return XCTFail("an engine on another schema was attached")
        }
        XCTAssertTrue(schema.contains("v12") && schema.contains("v11"), schema)
        guard case .refuse(let unknown) = verdict(list(serve), schema: nil) else {
            return XCTFail("an engine whose schema is unknown was attached")
        }
        XCTAssertTrue(unknown.contains("did not report"), unknown)
    }

    /// An app whose own CLI cannot say what it writes has nothing to hold an engine to, and the
    /// sentence says the gap is the app's, not the engine's.
    func testAnAppThatCannotSayWhatItWritesAttachesToNothing() {
        for gap in [EngineAttach.Expectation(registry: nil, schema: 11),
                    EngineAttach.Expectation(registry: "/r/scopes.toml", schema: nil)] {
            guard case .refuse(let why) = EngineAttach.verdict(list(serve), engineSchema: 11,
                                                               expecting: gap) else {
                return XCTFail("attached with nothing to compare against: \(gap)")
            }
            XCTAssertTrue(why.contains("this app's own substrate command"), why)
        }
    }

    /// What a host retries on: a refusal for a missing answer, not one on the engine itself.
    func testRosterQualificationIgnoresOnlyWhatTheRosterCannotSay() {
        XCTAssertTrue(EngineAttach.qualifiesByRoster(list(serve, registry: "/elsewhere.toml")))
        XCTAssertFalse(EngineAttach.qualifiesByRoster(
            list(.init(readOnly: false, agentMode: false, refreshEvery: 900))))
        XCTAssertFalse(EngineAttach.qualifiesByRoster(
            list(.init(readOnly: true, agentMode: false, refreshEvery: nil))))
        XCTAssertFalse(EngineAttach.qualifiesByRoster(list(nil)))
    }

    func testAnEngineThatDoesNotSayWhatItIsIsRefused() {
        guard case .refuse = verdict(list(nil)) else {
            return XCTFail("an engine with no server report was attached")
        }
    }
}
