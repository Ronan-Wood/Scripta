import XCTest
@testable import SubstrateKit

/// Wire → vocabulary, on the payload the engine really sent.
final class MappingTests: XCTestCase {

    private func liveSearch() throws -> WireSearchResult {
        try JSONDecoder().decode(WireSearchResult.self,
                                 from: try GoldenFixture.payload(GoldenFixture.search))
    }

    // MARK: - Passage

    func testAPassageMapsOntoTheSpine() throws {
        let wire = try XCTUnwrap(try liveSearch().passages.first)
        let passage = try wire.mapped(documentClass: .referenceFrozen)

        XCTAssertEqual(passage.id, "scripta/scripta-doc3a-mcp-server#c00002")
        XCTAssertEqual(passage.status, .active)
        XCTAssertEqual(passage.docType, .reference)
        XCTAssertEqual(passage.confidence, .stated)
        XCTAssertEqual(passage.vault, "scripta-vault")
        XCTAssertEqual(passage.supersedes, [])
        XCTAssertEqual(passage.withheldAs, [], "an active reference is default-corpus content")
    }

    func testEveryLivePassageAndOutlineMaps() throws {
        let result = try liveSearch()
        for wire in result.passages + result.outlineRecords {
            XCTAssertNoThrow(try wire.mapped(documentClass: .referenceFrozen),
                             "the live corpus contains a spine value this build cannot map: "
                             + "\(wire.status)/\(wire.docType)/\(wire.confidence)")
        }
    }

    /// A vocabulary this build does not know REFUSES, naming the token. It does not fall back to
    /// the nearest neighbour, which would print a value the engine never sent.
    func testAnUnknownSpineValueRefuses() throws {
        let wire = WirePassage(
            expandRef: "scripta/x#c1", citation: "c", path: "p", page: nil, nChars: 1,
            status: "retired", docType: "reference", confidence: "stated", domains: [],
            vault: "v", supersedes: [], snippet: "s", text: nil, truncated: false
        )
        XCTAssertThrowsError(try wire.mapped(documentClass: .referenceFrozen)) { error in
            guard case SubstrateMappingRefusal.unknownToken(let field, let value, let known)
                    = error else {
                return XCTFail("expected .unknownToken, got \(error)")
            }
            XCTAssertEqual(field, "status")
            XCTAssertEqual(value, "retired")
            XCTAssertTrue(known.contains("archived"))
        }
    }

    /// `render.expand_ref` returns null for a query addressed by db path, and says why: "a handle
    /// that cannot round-trip is worse than an absent one — it looks usable." A `Passage` needs an
    /// identity, so this refuses rather than synthesising one.
    func testAPassageWithNoExpandRefRefuses() {
        let wire = WirePassage(
            expandRef: nil, citation: "Doc 3a · @scripta-vault", path: "p", page: nil, nChars: 1,
            status: "active", docType: "reference", confidence: "stated", domains: [],
            vault: "v", supersedes: [], snippet: "s", text: nil, truncated: false
        )
        XCTAssertThrowsError(try wire.mapped(documentClass: .referenceFrozen)) { error in
            guard case SubstrateMappingRefusal.unaddressablePassage = error else {
                return XCTFail("expected .unaddressablePassage, got \(error)")
            }
        }
    }

    // MARK: - Applied filters

    func testTheLiveFilterIsTheDefaultCorpus() throws {
        let filter = try liveSearch().mappedFilter()

        XCTAssertEqual(filter.searched, ExclusionFilter.defaultClasses)
        XCTAssertEqual(filter.withheld, [.archived, .superseded, .sources])
        XCTAssertNil(filter.inclusionSentence, "nothing beyond the default was asked for")
        XCTAssertTrue(filter.withheldSentence.contains("call transcripts"),
                      "the `sources` axis comes from `sources_excluded`, not from the status list")
    }

    /// `sources_excluded` is its own axis. A payload that opened it up must produce the fifth class,
    /// or the exclusion bar and the passage disagree about what was searched — the exact split that
    /// lost the axis the first time.
    func testIncludingSourcesAddsTheFifthClass() throws {
        let wire = WireAppliedFilters(
            statusesIncluded: ["active", "complete"],
            statusesExcluded: ["archived", "superseded"],
            sourcesExcluded: false, docType: nil, documentClass: nil, notes: ["k clamped to 20"]
        )
        let filter = try wire.mapped()
        XCTAssertTrue(filter.searched.contains(.sources))
        XCTAssertEqual(filter.included, [.sources])
        XCTAssertEqual(filter.notes, ["k clamped to 20"])
        XCTAssertEqual(try XCTUnwrap(filter.inclusionSentence),
                       "Asked for: call transcripts can appear in these results.")
    }

    // MARK: - Capability envelope

    func testTheLiveEnvelopeReportsThreeUnavailableArms() throws {
        let envelope = try liveSearch().mappedEnvelope()

        XCTAssertEqual(envelope.scope.name, "scripta")
        XCTAssertTrue(envelope.scope.isNamed)
        XCTAssertNil(envelope.expectedMRR, "this stack was never measured; there is no number")
        XCTAssertNil(envelope.upgrade, "no measured MRR means no honest upgrade price")
        XCTAssertEqual(envelope.frozen, false)
        XCTAssertFalse(envelope.degraded, "nothing fell back — three arms never started")

        // All three arms report `off` on the wire. `unavailable` is the ONLY thing that separates
        // "requested and could not start" from "nobody asked", and it is what the operator acts on.
        XCTAssertEqual(envelope.unavailableArms.count, 3)
        XCTAssertEqual(envelope.arms.map(\.label), ["embed", "hyde", "rank"])
        XCTAssertEqual(envelope.arms.map(\.state), [.unavailable, .unavailable, .unavailable])
    }

    /// THE TRAP THIS MAPPING EXISTS FOR. The wire word is `fell_back` and `EngineArmState`'s
    /// rawValue is `fell back` — a space, because that string is display text. A rawValue
    /// initialiser would return nil on every fallen-back arm and lose the state that matters most.
    func testFellBackIsTranslatedRatherThanRawValueInitialised() throws {
        XCTAssertNil(EngineArmState(rawValue: "fell_back"),
                     "if this ever succeeds the translation below is redundant — check why")

        let mode = WireRetrievalMode(
            embedder: "qwen3-embedding:0.6b", hyde: "fell_back", reranker: "skipped",
            expectedMRR: .measured(0.603), cohort: "44-case semantic", degraded: true,
            fallbacks: ["expansion fell back to bare query"], unavailable: []
        )
        let arms = try mode.mappedArms()
        XCTAssertEqual(arms.map(\.state), [.ran, .fellBack, .skipped])
        XCTAssertEqual(arms[0].detail, "qwen3-embedding:0.6b",
                       "a running arm shows its model, which is what makes tiers legibly different")
        XCTAssertEqual(arms[1].detail, "fell back")
    }

    /// `off` is promoted to `.unavailable` only when `unavailable` names that arm. An arm nobody
    /// asked for stays `off`, because those are opposite situations to the operator.
    func testOnlyTheNamedArmIsPromotedToUnavailable() throws {
        let mode = WireRetrievalMode(
            embedder: nil, hyde: "off", reranker: "off", expectedMRR: .unmeasured,
            cohort: "44-case semantic", degraded: false, fallbacks: [],
            unavailable: ["reranker 'dengcao/Qwen3-Reranker-4B:Q4_K_M' unreachable at http://…"]
        )
        let arms = try mode.mappedArms()
        XCTAssertEqual(arms.map(\.state), [.off, .off, .unavailable])
    }

    func testAnUnknownArmStateRefuses() {
        let mode = WireRetrievalMode(
            embedder: nil, hyde: "deferred", reranker: "off", expectedMRR: .unmeasured,
            cohort: "44-case semantic", degraded: false, fallbacks: [], unavailable: []
        )
        XCTAssertThrowsError(try mode.mappedArms()) { error in
            guard case SubstrateMappingRefusal.unknownToken(let field, let value, _) = error else {
                return XCTFail("expected .unknownToken, got \(error)")
            }
            XCTAssertEqual(field, "hyde")
            XCTAssertEqual(value, "deferred")
        }
    }

    /// `degraded` is forwarded upward only. The engine's `true` is authoritative; its `false` must
    /// not switch off the envelope's own derivation, which exists because a `.fellBack` arm with an
    /// empty `fallbacks` array once rendered a known-degraded run as clean.
    func testEngineFalseDoesNotDisarmTheDegradedDerivation() throws {
        let payload = try JSONDecoder().decode(WireSearchResult.self, from: Data("""
            {"scope": "scripta", "db": null, "query": "q", "passages": [], "outline_records": [],
             "retrieval_mode": {"embedder": "e", "hyde": "fell_back", "reranker": "off",
                                "expected_mrr": null, "cohort": "44-case semantic",
                                "degraded": false, "fallbacks": [], "unavailable": []},
             "filters": {"statuses_included": ["active"], "statuses_excluded": [],
                         "sources_excluded": true, "doc_type": null, "document_class": null,
                         "notes": []},
             "index_version": "v8:x",
             "refresh": {"known": true, "outcome": "unchanged", "attempted": null,
                         "succeeded": null, "frozen": false, "frozen_since": null, "note": null}}
            """.utf8))
        XCTAssertFalse(payload.retrievalMode.degraded)
        XCTAssertTrue(try payload.mappedEnvelope().degraded,
                      "an arm in .fellBack is a degradation even when `fallbacks` is empty")
    }

    /// A query addressed by db path has no scope, and `EngineScope` has no correct render for that.
    /// `.missing` is the one door to the fault state that does not trip the debug trap.
    func testAScopelessPayloadMapsToTheFaultState() {
        XCTAssertEqual(WireSearchResult.mappedScope(nil), EngineScope.missing)
        XCTAssertEqual(WireSearchResult.mappedScope("   "), EngineScope.missing)
        XCTAssertFalse(WireSearchResult.mappedScope(nil).isNamed)
        XCTAssertTrue(WireSearchResult.mappedScope("scripta").isNamed)
    }

    /// `frozen: null` must reach `EngineEnvelope.frozen` as `nil`, not as `false`. That single
    /// conversion is where a whole freeze warning would be lost.
    func testNoBasisFreezeReachesTheEnvelopeAsNil() throws {
        let payload = try JSONDecoder().decode(WireSearchResult.self, from: Data("""
            {"scope": "scripta", "db": null, "query": "q", "passages": [], "outline_records": [],
             "retrieval_mode": {"embedder": null, "hyde": "off", "reranker": "off",
                                "expected_mrr": null, "cohort": "44-case semantic",
                                "degraded": false, "fallbacks": [], "unavailable": []},
             "filters": {"statuses_included": ["active"], "statuses_excluded": [],
                         "sources_excluded": true, "doc_type": null, "document_class": null,
                         "notes": []},
             "index_version": "v8:x",
             "refresh": {"known": true, "outcome": "skipped", "attempted": "2026-08-03T00:00:00Z",
                         "succeeded": null, "frozen": null, "frozen_since": null,
                         "note": "the last refresh tick made no attempt on this scope"}}
            """.utf8))
        XCTAssertNil(try payload.mappedEnvelope().frozen)
    }
}
