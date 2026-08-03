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
        let passage = try wire.mapped()

        XCTAssertEqual(passage.id, "scripta/scripta-doc3a-mcp-server#c00002")
        XCTAssertEqual(passage.status, .active)
        XCTAssertEqual(passage.docType, .reference)
        XCTAssertEqual(passage.confidence, .stated)
        XCTAssertEqual(passage.documentClass, .unclassified,
                       "the class comes off the wire now; nobody supplies it — and this note "
                       + "declares none, which the engine says as `unclassified` rather than "
                       + "defaulting to reference-frozen the way it used to")
        XCTAssertEqual(passage.vault, "scripta-vault")
        XCTAssertEqual(passage.supersedes, [])
        XCTAssertEqual(passage.withheldAs, [],
                       "an undeclared class is default-corpus content: absence of a label is not "
                       + "evidence about the note, so nothing here is withheld")
    }

    func testEveryLivePassageAndOutlineMaps() throws {
        let result = try liveSearch()
        for wire in result.passages + result.outlineRecords {
            XCTAssertNoThrow(try wire.mapped(),
                             "the live corpus contains a spine value this build cannot map: "
                             + "\(wire.status)/\(wire.docType)/\(wire.confidence)")
        }
    }

    /// A vocabulary this build does not know REFUSES, naming the token. It does not fall back to
    /// the nearest neighbour, which would print a value the engine never sent.
    func testAnUnknownSpineValueRefuses() throws {
        let wire = WirePassage(
            expandRef: "scripta/x#c1", citation: "c", path: "p", page: nil, nChars: 1,
            documentClass: "reference-frozen", status: "retired", docType: "reference",
            confidence: "stated", domains: [], vault: "v", supersedes: [], snippet: "s",
            text: nil, truncated: false
        )
        XCTAssertThrowsError(try wire.mapped()) { error in
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
            documentClass: "reference-frozen", status: "active", docType: "reference",
            confidence: "stated", domains: [], vault: "v", supersedes: [], snippet: "s",
            text: nil, truncated: false
        )
        XCTAssertThrowsError(try wire.mapped()) { error in
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
        XCTAssertEqual(envelope.unmeasuredReason, .noVectorArm,
                       "a null MRR now arrives WITH the engine's reason for it")
        XCTAssertNil(envelope.upgrade, "no measured MRR means no honest upgrade price")
        XCTAssertEqual(envelope.frozen, false)
        XCTAssertFalse(envelope.degraded, "nothing fell back — three arms never started")

        // All three arms report `off` on the wire. `health.arms` is the ONLY thing that separates
        // "requested and could not start" from "nobody asked", and it is what the operator acts on.
        XCTAssertEqual(envelope.unavailableArms.count, 3)
        XCTAssertEqual(envelope.arms.map(\.label), ["embed", "hyde", "rank"])
        XCTAssertEqual(envelope.arms.map(\.state), [.unavailable, .unavailable, .unavailable])

        guard case .unreachable(let note) = envelope.health else {
            return XCTFail("expected .unreachable, got \(envelope.health)")
        }
        XCTAssertTrue(try XCTUnwrap(note).contains("must not be inferred"),
                      "the engine's note is carried verbatim, including its refusal to say WHY")
    }

    /// THE TRAP THIS MAPPING EXISTS FOR. The wire word is `fell_back` and the displayed word is
    /// `fell back` — a space. They were one `rawValue`, the display string won, and the obvious
    /// decode (`EngineArmState(rawValue:)`) returned nil for every fallen-back arm: the one state
    /// that reports a degradation became no state at all. They are separate properties now, so the
    /// confusion is not expressible, and the wire direction refuses rather than returning nil.
    func testTheWireTokenAndTheDisplayStringCannotBeConfused() throws {
        XCTAssertEqual(EngineArmState.byWireToken["fell_back"], .fellBack)
        XCTAssertNil(EngineArmState.byWireToken["fell back"],
                     "the display string is not a wire token and must not decode")

        let mode = Self.mode(embedder: "qwen3-embedding:0.6b", embedderState: "ran",
                             hyde: "fell_back", reranker: "skipped",
                             expectedMRR: .measured(0.603), degraded: true,
                             fallbacks: ["expansion fell back to bare query"])
        let arms = try mode.mappedArms()
        XCTAssertEqual(arms.map(\.state), [.ran, .fellBack, .skipped])
        XCTAssertEqual(arms[0].detail, "qwen3-embedding:0.6b",
                       "a running arm shows its model, which is what makes tiers legibly different")
        XCTAssertEqual(arms[1].detail, "fell back")
    }

    /// THE ARM THAT USED TO UNDERSTATE. An embedder that fell back mid-run empties `embedder`, which
    /// is byte-identical to one nobody asked for — so the client derived `.off` and the arm row said
    /// a degradation had not happened. `embedder_state` is that arm's own word, and it is used.
    func testAFallenBackEmbedderIsNoLongerReadAsOff() throws {
        let mode = Self.mode(embedder: nil, embedderState: "fell_back", hyde: "ran",
                             reranker: "ran", degraded: true,
                             fallbacks: ["embed: vector coverage incomplete, dropped to lexical"])
        XCTAssertEqual(try mode.mappedArms().map(\.state), [.fellBack, .ran, .ran])
    }

    /// `off` is promoted to `.unavailable` only when `health.arms` calls that arm unavailable. An
    /// arm nobody asked for stays `off`, because those are opposite situations to the operator —
    /// and the promotion no longer reads the arm name out of an engine SENTENCE.
    func testOnlyTheArmTheBuildMapNamesIsPromotedToUnavailable() throws {
        let mode = Self.mode(
            embedder: nil, embedderState: "off", hyde: "off", reranker: "off",
            unavailable: ["reranker 'dengcao/Qwen3-Reranker-4B:Q4_K_M' unreachable at http://…"],
            health: WireEngineHealth(
                known: true, state: "unreachable",
                arms: ["embedder": "off", "hyde": "off", "reranker": "unavailable"],
                note: "an arm was requested and could not start")
        )
        XCTAssertEqual(try mode.mappedArms().map(\.state), [.off, .off, .unavailable])
    }

    /// The prose and the map cannot contradict each other, because the engine forces `unreachable`
    /// whenever `unavailable` is non-empty — even when it could attribute none of it. The arm rows
    /// then understate, and the health line is what says so.
    func testAnUnattributedFailureStillReportsUnreachable() throws {
        let mode = Self.mode(
            embedder: nil, embedderState: "off", hyde: "off", reranker: "off",
            unavailable: ["something 'x' unreachable at http://…"],
            health: WireEngineHealth(
                known: true, state: "unreachable",
                arms: ["embedder": "off", "hyde": "off", "reranker": "off"],
                note: "no entry in `unavailable` names one of the known arms")
        )
        XCTAssertEqual(try mode.mappedArms().map(\.state), [.off, .off, .off])
        guard case .unreachable = try mode.health.mapped() else {
            return XCTFail("a non-empty `unavailable` must never read as healthy")
        }
    }

    func testAnUnknownArmStateRefuses() {
        let mode = Self.mode(embedder: nil, embedderState: "off", hyde: "deferred", reranker: "off")
        XCTAssertThrowsError(try mode.mappedArms()) { error in
            guard case SubstrateMappingRefusal.unknownToken(let field, let value, _) = error else {
                return XCTFail("expected .unknownToken, got \(error)")
            }
            XCTAssertEqual(field, "hyde")
            XCTAssertEqual(value, "deferred")
        }
    }

    // MARK: - Health

    /// `known: false` is ABSENT EVIDENCE, not a clean bill. Reading it as `.ready` would be the same
    /// defect as `refresh.frozen` defaulting to `false` with no record behind it.
    func testAnUnreportedWiringIsNotHealthy() throws {
        let health = WireEngineHealth(known: false, state: nil, arms: nil,
                                      note: "the caller did not report which arms it wired")
        guard case .unreported(let note) = try health.mapped() else {
            return XCTFail("expected .unreported, got \(try health.mapped())")
        }
        XCTAssertEqual(note, "the caller did not report which arms it wired")
    }

    /// `lexical_only` is a CONFIGURATION and must not become `.notInstalled`: nothing was asked for,
    /// so nothing was probed, and "no local model server installed" is a claim nobody made.
    func testLexicalOnlyIsNotReadAsNotInstalled() throws {
        let health = WireEngineHealth(known: true, state: "lexical_only",
                                      arms: ["embedder": "off", "hyde": "off", "reranker": "off"],
                                      note: "no local-model arm was requested")
        guard case .lexicalOnly = try health.mapped() else {
            return XCTFail("expected .lexicalOnly, got \(try health.mapped())")
        }
    }

    /// A state word this build has no case for refuses by name, and so does `known: true` with no
    /// state — a contradiction the engine's own contract forbids. Neither picks a healthy half.
    func testAnIncoherentOrUnknownHealthStateRefuses() {
        for health in [WireEngineHealth(known: true, state: "degraded", arms: nil, note: nil),
                       WireEngineHealth(known: true, state: nil, arms: nil, note: nil)] {
            XCTAssertThrowsError(try health.mapped()) { error in
                guard case SubstrateMappingRefusal.unknownToken(let field, _, _) = error else {
                    return XCTFail("expected .unknownToken, got \(error)")
                }
                XCTAssertEqual(field, "retrieval_mode.health.state")
            }
        }
    }

    /// An unmeasured reason outside `UNMEASURED_REASONS` refuses rather than reaching the screen as
    /// a token dressed up as a sentence.
    func testAnUnknownUnmeasuredReasonRefuses() {
        let mode = Self.mode(embedder: nil, embedderState: "off", hyde: "off", reranker: "off",
                             unmeasuredReason: "budget_exceeded")
        XCTAssertThrowsError(try mode.mappedUnmeasuredReason()) { error in
            guard case SubstrateMappingRefusal.unknownToken(let field, let value, _) = error else {
                return XCTFail("expected .unknownToken, got \(error)")
            }
            XCTAssertEqual(field, "unmeasured_reason")
            XCTAssertEqual(value, "budget_exceeded")
        }
    }

    /// One builder for the synthetic modes above, so a key added to `retrieval_mode` is one edit
    /// here rather than six — and so no test quietly drifts to a different health block than the
    /// one it means to exercise.
    private static func mode(
        embedder: String?, embedderState: String, hyde: String, reranker: String,
        expectedMRR: MeasuredMRR = .unmeasured, unmeasuredReason: String? = "no_vector_arm",
        degraded: Bool = false, fallbacks: [String] = [], unavailable: [String] = [],
        health: WireEngineHealth = WireEngineHealth(
            known: true, state: "ready",
            arms: ["embedder": "wired", "hyde": "wired", "reranker": "wired"], note: nil)
    ) -> WireRetrievalMode {
        WireRetrievalMode(
            embedder: embedder, embedderState: embedderState, hyde: hyde, reranker: reranker,
            expectedMRR: expectedMRR,
            unmeasuredReason: expectedMRR == .unmeasured ? unmeasuredReason : nil,
            cohort: "44-case semantic", degraded: degraded, fallbacks: fallbacks,
            unavailable: unavailable, health: health
        )
    }

    /// `degraded` is forwarded upward only. The engine's `true` is authoritative; its `false` must
    /// not switch off the envelope's own derivation, which exists because a `.fellBack` arm with an
    /// empty `fallbacks` array once rendered a known-degraded run as clean.
    func testEngineFalseDoesNotDisarmTheDegradedDerivation() throws {
        let payload = try JSONDecoder().decode(WireSearchResult.self, from: Data("""
            {"scope": "scripta", "db": null, "query": "q", "passages": [], "outline_records": [],
             "retrieval_mode": {"embedder": "e", "embedder_state": "ran", "hyde": "fell_back",
                                "reranker": "off", "expected_mrr": null,
                                "unmeasured_reason": "unmeasured_arm_combination",
                                "cohort": "44-case semantic", "degraded": false,
                                "fallbacks": [], "unavailable": [],
                                "health": {"known": true, "state": "ready",
                                           "arms": {"embedder": "wired", "hyde": "wired",
                                                    "reranker": "off"},
                                           "note": null}},
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
             "retrieval_mode": {"embedder": null, "embedder_state": "off", "hyde": "off",
                                "reranker": "off", "expected_mrr": null,
                                "unmeasured_reason": "no_vector_arm",
                                "cohort": "44-case semantic", "degraded": false,
                                "fallbacks": [], "unavailable": [],
                                "health": {"known": true, "state": "lexical_only",
                                           "arms": {"embedder": "off", "hyde": "off",
                                                    "reranker": "off"},
                                           "note": "no local-model arm was requested"}},
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
