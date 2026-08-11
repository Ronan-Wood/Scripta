import XCTest
@testable import SubstrateKit

/// Doc 3 §6's parity, asserted where it can actually break.
///
/// THE TEST THAT DID NOT EXIST. Doc 4 lists Phase 6 as blocked on "a live parity number", and the
/// handoff has recorded for two sessions that `TransportTests`' live test is not it: it compares one
/// answer to its own JSON round trip, which proves no FIELD was dropped in decoding and says nothing
/// about what the app then DERIVES. Divergence does not live in the decoder. It lives one layer up,
/// in `SubstrateMapping`, where a mapped value can quietly stop being the engine's value.
///
/// So this asserts the property Doc 3 §6 actually wants — "an in-app query and the equivalent CLI
/// query must return the same passages, the same capability and the same `index_version`" — in the
/// form that is checkable from Swift: **every field the reader sees is the field the engine sent.**
/// The CLI is not invoked. It renders through the same `render.py` the wire payload came from, so
/// running it would test Python against itself; what is unverified is the Swift side, and `stack.py`
/// parity between entry points is already pinned by `substrate/tests/test_entrypoint_parity.py`.
///
/// ONE FIELD IS ALLOWED TO DIVERGE AND ONLY UPWARD. `EngineEnvelope` re-derives `degraded` from the
/// arms, because an arm sitting in `.fellBack` with an empty `fallbacks` array rendered a
/// known-degraded run as clean. That is a safety net, so the assertion on it is DIRECTIONAL rather
/// than equality: the app may report degraded when the engine did not, and may never report clean
/// when the engine said degraded. An equality assertion here would be the wrong test — it would
/// fail on correct code and pressure someone into deleting the net.
final class MappingParityTests: XCTestCase {

    private func searchPayload(_ fixture: String) throws -> WireSearchResult {
        let frame = try GoldenFixture.frame(fixture)
        let call: SubstrateCall<WireSearchResult> =
            SubstrateClient.interpret(frame: frame, expectedID: 1)
        guard case .ok(let payload) = call else {
            throw XCTSkip("fixture \(fixture) did not decode as a search result: \(call)")
        }
        return payload
    }

    /// The golden capture with named values overwritten inside its payload.
    ///
    /// NEEDED BECAUSE THE CAPTURES DO NOT REACH THE INTERESTING STATES, and a test whose fixture
    /// cannot reach the state its assertion objects to passes with the bug and without it. Both
    /// live captures carry `degraded: false` and `filters.vaults: null`, so the two assertions that
    /// matter most here — the safety net may only raise, and which tiers answered must survive —
    /// were `nil == nil` and a branch that never ran. Verified by mutation: inverting `degraded`'s
    /// mapping and deleting `vaults` from the filter both went GREEN before this existed.
    ///
    /// It patches the REAL frame rather than hand-writing a payload, so the shape stays the
    /// engine's and only the values under test move.
    private func patchedSearch(_ fixture: String,
                               _ patch: (inout [String: Any]) -> Void) throws -> WireSearchResult {
        let frame = try GoldenFixture.frame(fixture)
        guard var envelope = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
              var result = envelope["result"] as? [String: Any],
              var content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              var payload = try JSONSerialization.jsonObject(with: Data(text.utf8)) as? [String: Any]
        else { throw XCTSkip("fixture \(fixture) is not the frame shape this patcher expects") }

        patch(&payload)

        content[0]["text"] = String(
            data: try JSONSerialization.data(withJSONObject: payload), encoding: .utf8)
        result["content"] = content
        envelope["result"] = result
        let call: SubstrateCall<WireSearchResult> = SubstrateClient.interpret(
            frame: try JSONSerialization.data(withJSONObject: envelope), expectedID: 1)
        guard case .ok(let decoded) = call else {
            throw XCTSkip("patched fixture did not decode: \(call)")
        }
        return decoded
    }

    // MARK: - The capability envelope

    func testEveryEnvelopeFieldIsTheEngineSValue() throws {
        for fixture in [GoldenFixture.search, GoldenFixture.searchIncludingSources] {
            let payload = try searchPayload(fixture)
            let envelope = try payload.mappedEnvelope()
            let mode = payload.retrievalMode

            XCTAssertEqual(envelope.expectedMRR, mode.expectedMRR.wireValue,
                           "\(fixture): expected_mrr must be the engine's number or its absence — "
                           + "never a nearest tier, a lower bound, or a zero")
            XCTAssertEqual(envelope.cohort, mode.cohort, "\(fixture): cohort")
            XCTAssertEqual(envelope.fallbacks, mode.fallbacks, "\(fixture): fallbacks")
            XCTAssertEqual(envelope.frozen, payload.refresh.frozen.wireValue,
                           "\(fixture): the refresh verdict is tri-state and each value is a "
                           + "different claim — none may be collapsed on the way through")
            XCTAssertEqual(envelope.arms.count, 3,
                           "\(fixture): three arms — embedder, hyde, reranker — always reported")
            assertArmsMatchTheWire(envelope, payload: payload, fixture: fixture)
        }
    }

    /// Each arm reports the state the engine sent, with ONE promotion allowed.
    ///
    /// `off` means two different things on the wire — "nobody asked for it" and "it was asked for
    /// and could not start" — and `health.arms` is where that distinction survives. So an `off` arm
    /// the health block calls unavailable is promoted to `.unavailable`, and everything else is
    /// carried verbatim. Asserted as a RULE rather than as equality because the promotion is the
    /// point: without it, a requested-but-dead arm renders identically to one nobody wanted.
    private func assertArmsMatchTheWire(_ envelope: EngineEnvelope,
                                        payload: WireSearchResult,
                                        fixture: String) {
        let mode = payload.retrievalMode
        // THREE NAMES FOR EACH ARM AND THEY ARE NOT THE SAME STRING. The display label is `embed`
        // and `rank` (chrome, chosen for a 300pt column); the wire field is `embedder_state` and
        // `reranker`; the health key is `embedder` and `reranker`. Keeping them keyed together here
        // is the point — this is exactly the alias drift that let `class:`/`document_class:` relabel
        // six conversations, and a test that assumed one name would silently check nothing.
        let wire: [(label: String, state: String, healthKey: String)] = [
            ("embed", mode.embedderState, "embedder"),
            ("hyde", mode.hyde, "hyde"),
            ("rank", mode.reranker, "reranker"),
        ]
        XCTAssertEqual(Set(envelope.arms.map(\.label)), Set(wire.map(\.label)),
                       "\(fixture): the rendered arms are not the three the engine reports")
        for arm in envelope.arms {
            guard let row = wire.first(where: { $0.label == arm.label }),
                  let sent = EngineArmState.byWireToken[row.state] else {
                return XCTFail("\(fixture): arm `\(arm.label)` has no wire counterpart")
            }
            let deadOnArrival = mode.health.arms?[row.healthKey] == WireEngineHealth.armUnavailable
            if sent == .off && deadOnArrival {
                XCTAssertEqual(arm.state, .unavailable,
                               "\(fixture): `\(arm.label)` was requested and could not start — that "
                               + "must not render as an arm nobody asked for")
            } else {
                XCTAssertEqual(arm.state, sent,
                               "\(fixture): `\(arm.label)` state must be the engine's")
            }
        }
    }

    /// `degraded` — the one documented exception, asserted in its own direction, against a payload
    /// that actually says so. Both captures carry `false`, so this state has to be constructed or
    /// the assertion is a branch that never runs.
    func testAnEngineDegradedRunIsNeverRenderedClean() throws {
        let payload = try patchedSearch(GoldenFixture.search) { p in
            var mode = p["retrieval_mode"] as! [String: Any]
            mode["degraded"] = true
            p["retrieval_mode"] = mode
        }
        XCTAssertTrue(payload.retrievalMode.degraded, "the patch did not take")
        XCTAssertTrue(try payload.mappedEnvelope().degraded,
                      "the engine said degraded and the app cleared it — the one direction this "
                      + "field may never move")
    }

    /// And the net stays armed the other way: the app may raise `degraded` on evidence the engine's
    /// own flag does not carry, which is why `false` is forwarded as `nil` rather than as `false`.
    func testTheAppMayStillRaiseDegradedOnAFellBackArm() throws {
        let payload = try patchedSearch(GoldenFixture.search) { p in
            var mode = p["retrieval_mode"] as! [String: Any]
            mode["degraded"] = false
            mode["fallbacks"] = ["reranker fell back to lexical order"]
            p["retrieval_mode"] = mode
        }
        XCTAssertFalse(payload.retrievalMode.degraded)
        XCTAssertTrue(try payload.mappedEnvelope().degraded,
                      "a run with fallbacks is degraded even when the engine's flag says otherwise "
                      + "— forwarding the engine's `false` would switch that derivation off")
    }

    // MARK: - The passages

    /// Nothing about a passage is computed on this side. Every spine axis, the citation, the vault
    /// and the id are the engine's — which is what makes "the same passages" checkable at all.
    func testEveryPassageFieldIsTheEngineSValue() throws {
        for fixture in [GoldenFixture.search, GoldenFixture.searchIncludingSources] {
            let payload = try searchPayload(fixture)
            let mapped = try payload.passages.map { try $0.mapped() }
            XCTAssertEqual(mapped.count, payload.passages.count,
                           "\(fixture): a mapped result set may not be shorter than the wire's")

            for (wire, passage) in zip(payload.passages, mapped) {
                XCTAssertEqual(passage.id, wire.expandRef, "\(fixture): id IS the expand ref")
                XCTAssertEqual(passage.citation, wire.citation, "\(fixture): citation")
                XCTAssertEqual(passage.snippet, wire.snippet, "\(fixture): snippet")
                XCTAssertEqual(passage.vault, wire.vault ?? "", "\(fixture): vault")
                XCTAssertEqual(passage.status.rawValue, wire.status, "\(fixture): status")
                XCTAssertEqual(passage.docType.rawValue, wire.docType, "\(fixture): doc_type")
                XCTAssertEqual(passage.confidence.rawValue, wire.confidence,
                               "\(fixture): confidence")
                XCTAssertEqual(passage.domains, wire.domains, "\(fixture): domains")
                XCTAssertEqual(passage.supersedes, wire.supersedes,
                               "\(fixture): supersedes is a LIST since v8 and must stay one")
                // `nil` on the wire means the row never went through the class gate, which is
                // `unreported` — NOT a class, and not `unclassified` either.
                XCTAssertEqual(passage.documentClass.wireToken, wire.documentClass,
                               "\(fixture): document_class token")
            }
        }
    }

    // MARK: - The disclosure

    /// What the engine says it searched is what the bar reports. `vaults` in particular: it says
    /// WHICH TIERS answered, and it was decoded and then dropped until Phase 5 — harmless only while
    /// the tier chips re-ran the query on every toggle.
    func testAppliedFiltersAreTheEngineSValues() throws {
        for fixture in [GoldenFixture.search, GoldenFixture.searchIncludingSources] {
            let payload = try searchPayload(fixture)
            let filter = try payload.mappedFilter()
            let wire = payload.filters

            XCTAssertEqual(filter.notes, wire.notes, "\(fixture): filters.notes")
            XCTAssertEqual(filter.searched.contains(.sources), !wire.sourcesExcluded,
                           "\(fixture): the sources axis comes from `sources_excluded`, not the "
                           + "status list — they are different axes")
            for status in wire.statusesIncluded {
                XCTAssertTrue(filter.searched.contains { $0.rawValue == status },
                              "\(fixture): status `\(status)` was searched and the bar does not say so")
            }
            for status in wire.statusesExcluded {
                XCTAssertFalse(filter.searched.contains { $0.rawValue == status },
                               "\(fixture): status `\(status)` was withheld and the bar claims it was searched")
            }
        }
    }

    /// WHICH TIERS ANSWERED, against a payload that names some. `null` in both captures means "the
    /// whole chain", so comparing them proved only `nil == nil` — deleting the field from the
    /// mapping was green until this case existed.
    func testWhichTiersAnsweredSurvivesTheMapping() throws {
        let payload = try patchedSearch(GoldenFixture.search) { p in
            var filters = p["filters"] as! [String: Any]
            filters["vaults"] = ["core-vault"]
            p["filters"] = filters
        }
        XCTAssertEqual(payload.filters.vaults, ["core-vault"], "the patch did not take")
        XCTAssertEqual(try payload.mappedFilter().vaults, ["core-vault"],
                       "a turn narrowed to one tier must not be indistinguishable from one that "
                       + "searched the whole chain")
    }

    /// And `null` still means the whole chain rather than an empty narrowing — the two are opposite
    /// claims and the engine distinguishes them.
    func testAnAbsentTierListStaysAbsent() throws {
        let payload = try searchPayload(GoldenFixture.search)
        XCTAssertNil(payload.filters.vaults)
        XCTAssertNil(try payload.mappedFilter().vaults,
                     "`null` is every vault the scope composes; `[]` would be a narrowing to nothing")
    }

    // MARK: - index_version

    /// The value Doc 3 §6 names explicitly, and the one a reader can compare against a CLI run by
    /// eye. It is on screen per answered turn, so it has to survive mapping unaltered.
    func testIndexVersionIsCarriedVerbatim() throws {
        for fixture in [GoldenFixture.search, GoldenFixture.searchIncludingSources] {
            let payload = try searchPayload(fixture)
            XCTAssertFalse(payload.indexVersion.isEmpty, "\(fixture): index_version is never blank")
            XCTAssertTrue(payload.indexVersion.contains(":"),
                          "\(fixture): index_version is `<schema>:<digest>` — a bare digest would "
                          + "not distinguish two schemas over one vault")
        }
    }

    // MARK: - Against the running engine

    /// The same assertions against the LIVE engine, so a `render.py` change that alters a value
    /// rather than adding a field is caught on the first run after it lands.
    ///
    /// Skipped when nothing is listening, for the reason `TransportTests` documents: a suite that
    /// fails on a machine with no daemon is a suite people stop running.
    func testLiveSearchAgreesFieldForField() async throws {
        let client = SubstrateClient(timeout: 30)
        let probe = await client.listScopes()
        if case .transportFailure(.unreachable(let reason, _)) = probe {
            throw XCTSkip("the substrate engine is not running (\(reason))")
        }
        guard case .ok(let scopes) = probe, let scope = scopes.scopes.first?.scope else {
            throw XCTSkip("no scope to query")
        }

        let call = await client.search(
            SubstrateSearchRequest(scope: scope, query: "the retrieval envelope", k: 5))
        guard case .ok(let payload) = call else {
            return XCTFail("live search did not answer: \(call)")
        }

        let envelope = try payload.mappedEnvelope()
        XCTAssertEqual(envelope.expectedMRR, payload.retrievalMode.expectedMRR.wireValue)
        XCTAssertEqual(envelope.cohort, payload.retrievalMode.cohort)
        XCTAssertEqual(envelope.fallbacks, payload.retrievalMode.fallbacks)
        XCTAssertEqual(envelope.frozen, payload.refresh.frozen.wireValue)
        if payload.retrievalMode.degraded { XCTAssertTrue(envelope.degraded) }

        XCTAssertEqual(try payload.mappedFilter().vaults, payload.filters.vaults)

        for (wire, passage) in zip(payload.passages, try payload.passages.map { try $0.mapped() }) {
            XCTAssertEqual(passage.id, wire.expandRef)
            XCTAssertEqual(passage.status.rawValue, wire.status)
            XCTAssertEqual(passage.confidence.rawValue, wire.confidence)
            XCTAssertEqual(passage.documentClass.wireToken, wire.documentClass)
        }
    }
}
