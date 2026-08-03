import XCTest
@testable import SubstrateKit

/// The four fields where `null` is a claim, and the one place each of them could be inverted.
///
/// These are not style checks. Every case below is a shape the engine really produces, and for each
/// one there is a single expression — `?? false`, `?? 0`, a struct of optionals — that would read it
/// as healthy. The types are built so that expression has nothing to attach to; these tests are what
/// keep that true.
final class TriStateHonestyTests: XCTestCase {

    private func decode<T: Decodable>(_ type: T.Type, _ json: String) throws -> T {
        try JSONDecoder().decode(T.self, from: Data(json.utf8))
    }

    // MARK: - refresh.frozen

    /// `frozen: null` is NOT `frozen: false`. `refresh_state.OUTCOMES` records `skipped` as
    /// `frozen: None` precisely because "nothing was checked" is not "nothing is wrong".
    func testFrozenNullIsNotCurrent() throws {
        let skipped = try decode(WireRefreshReport.self, """
            {"known": true, "outcome": "skipped", "attempted": "2026-08-03T12:36:40+00:00",
             "succeeded": null, "frozen": null, "frozen_since": null, "note": "the last refresh …"}
            """)
        XCTAssertEqual(skipped.frozen, .noBasis)
        XCTAssertNotEqual(skipped.frozen, .current)
        XCTAssertNil(skipped.frozen.wireValue)

        let clean = try decode(WireRefreshReport.self, """
            {"known": true, "outcome": "unchanged", "attempted": null, "succeeded": null,
             "frozen": false, "frozen_since": null, "note": null}
            """)
        XCTAssertEqual(clean.frozen, .current)

        let refused = try decode(WireRefreshReport.self, """
            {"known": true, "outcome": "compose_failed", "attempted": null, "succeeded": null,
             "frozen": true, "frozen_since": "2026-07-30T00:00:00+00:00", "note": "FROZEN — …"}
            """)
        XCTAssertEqual(refused.frozen, .frozen)
        XCTAssertEqual(refused.frozenSince, "2026-07-30T00:00:00+00:00")
    }

    /// THE OLDER-SERVER CASE. An engine that predates `refresh` omits the block silently, with no
    /// error. That absence must be indistinguishable, to every consumer, from `known: false`.
    func testAnAbsentRefreshBlockDecodesAsKnownFalse() throws {
        let withBlock = try decode(WireSearchResult.self, Self.searchPayload(refresh: """
            "refresh": {"known": false, "outcome": null, "attempted": null, "succeeded": null,
                        "frozen": null, "frozen_since": null, "note": "no refresh agent has …"}
            """))
        let withoutBlock = try decode(WireSearchResult.self, Self.searchPayload(refresh: nil))

        XCTAssertFalse(withoutBlock.refresh.known)
        XCTAssertEqual(withoutBlock.refresh.frozen, .noBasis)
        XCTAssertEqual(withoutBlock.refresh, WireRefreshReport.absent)
        // The `note` differs (the engine supplies one, an absent block has none) so the two are
        // compared on the fields a consumer branches on.
        XCTAssertEqual(withoutBlock.refresh.known, withBlock.refresh.known)
        XCTAssertEqual(withoutBlock.refresh.frozen, withBlock.refresh.frozen)
    }

    /// `wasSent` is provenance for the encoder and must not leak into equality — otherwise the
    /// assertion above would be true by accident of one extra Bool rather than by design.
    func testWasSentDoesNotAffectEquality() {
        let sent = WireRefreshReport(known: false, outcome: nil, attempted: nil, succeeded: nil,
                                     frozen: .noBasis, frozenSince: nil, note: nil, wasSent: true)
        XCTAssertEqual(sent, WireRefreshReport.absent)
        XCTAssertNotEqual(sent.wasSent, WireRefreshReport.absent.wasSent)
    }

    /// An omitted block must not come back as an invented one. The engine never sent that key, and
    /// re-emitting it would be this client authoring a report about itself.
    func testAnAbsentRefreshBlockIsNotInventedOnReEncode() throws {
        let decoded = try decode(WireSearchResult.self, Self.searchPayload(refresh: nil))
        let object = try JSONSerialization.jsonObject(with: try JSONEncoder().encode(decoded))
        let keys = Set((object as? [String: Any])?.keys ?? [:].keys)
        XCTAssertFalse(keys.contains("refresh"))
    }

    // MARK: - retrieval_mode.expected_mrr

    /// `null` here means the running stack has no measured number. There is deliberately no way to
    /// reach a `Double` without naming the case, so it cannot become a lower bound or a zero.
    func testUnmeasuredMRRIsNotZero() throws {
        let mode = try decode(WireRetrievalMode.self, """
            {"embedder": null, "hyde": "off", "reranker": "off", "expected_mrr": null,
             "cohort": "44-case semantic", "degraded": false, "fallbacks": [], "unavailable": []}
            """)
        XCTAssertEqual(mode.expectedMRR, .unmeasured)
        XCTAssertNil(mode.expectedMRR.wireValue)
        XCTAssertNotEqual(mode.expectedMRR, .measured(0))

        let measured = try decode(WireRetrievalMode.self, """
            {"embedder": "qwen3-embedding:0.6b", "hyde": "ran", "reranker": "ran",
             "expected_mrr": 0.698, "cohort": "44-case semantic", "degraded": false,
             "fallbacks": [], "unavailable": []}
            """)
        XCTAssertEqual(measured.expectedMRR, .measured(0.698))
    }

    /// The live capture is the unmeasured case — no local model server was running — so the
    /// measured branch above is the only hand-built JSON here, and this pins that the fixture
    /// really does exercise the null.
    func testTheCapturedSearchIsTheUnmeasuredCase() throws {
        let result = try JSONDecoder()
            .decode(WireSearchResult.self, from: try GoldenFixture.payload(GoldenFixture.search))
        XCTAssertEqual(result.retrievalMode.expectedMRR, .unmeasured)
        XCTAssertEqual(result.retrievalMode.unavailable.count, 3)
        XCTAssertFalse(result.retrievalMode.degraded,
                       "nothing FELL BACK — three arms never started, which is a different claim")
    }

    // MARK: - note.stale

    /// `null` is "cannot be checked": the stored checksum is a DECLARED one naming a PDF, so an
    /// edit to the note body is invisible from the index. `false` would be a claim.
    func testStaleNullIsNotAMatch() throws {
        let declared = try decode(WireNote.self, """
            {"path": "/x.md", "text": "…", "n_chars": 3, "truncated": false, "stale": null}
            """)
        XCTAssertEqual(declared.stale, .uncheckable)
        XCTAssertNotEqual(declared.stale, .matches)

        let moved = try decode(WireNote.self, """
            {"path": "/x.md", "text": "…", "n_chars": 3, "truncated": false, "stale": true}
            """)
        XCTAssertEqual(moved.stale, .stale)
    }

    // MARK: - status.drift

    /// THE SUM TYPE, and the specific bug `introspect.py` was written to prevent. A struct of
    /// optionals decodes `{"error": …}` as all-nil, and all-nil reads as CLEAN.
    func testDriftErrorPayloadIsNotACleanReport() throws {
        let unresolvable = try decode(WireDriftReport.self, """
            {"error": "no manifest at /Users/x/vaults/gone-vault"}
            """)
        guard case .unavailable(let message) = unresolvable else {
            return XCTFail("an error payload must not decode as a checked report; got \(unresolvable)")
        }
        XCTAssertTrue(message.contains("gone-vault"))
    }

    func testDriftDetailReadsStaleAndCheckableTogether() throws {
        let clean = try decode(WireDriftReport.self, """
            {"stale": false, "checkable": true, "added": [], "removed": [], "changed": [],
             "checked": 57, "unverifiable": 0, "unreadable": []}
            """)
        guard case .checked(let detail) = clean else { return XCTFail("expected a checked report") }
        XCTAssertEqual(detail.verdict, .unchangedAndComplete)

        // `stale: false, checkable: false` is "no change found, and some notes were not examined".
        // The two fields disagree in exactly the direction a single Bool would erase.
        let partial = try decode(WireDriftReport.self, """
            {"stale": false, "checkable": false, "added": [], "removed": [], "changed": [],
             "checked": 40, "unverifiable": 3, "unreadable": ["/vault/locked.md"]}
            """)
        guard case .checked(let partialDetail) = partial else {
            return XCTFail("expected a checked report")
        }
        XCTAssertFalse(partialDetail.stale)
        XCTAssertEqual(partialDetail.verdict, .unchangedButIncomplete,
                       "an unread note must not be folded into a clean verdict")

        let moved = try decode(WireDriftReport.self, """
            {"stale": true, "checkable": true, "added": ["/vault/new.md"], "removed": [],
             "changed": [], "checked": 56, "unverifiable": 0, "unreadable": []}
            """)
        guard case .checked(let movedDetail) = moved else {
            return XCTFail("expected a checked report")
        }
        XCTAssertEqual(movedDetail.verdict, .moved)
    }

    /// Both drift shapes must survive a round trip, since the error one is a different JSON object
    /// entirely rather than a variant of the same keys.
    func testBothDriftShapesRoundTrip() throws {
        for json in ["""
            {"error": "vault is gone"}
            """, """
            {"stale": true, "checkable": true, "added": ["/a.md"], "removed": [], "changed": [],
             "checked": 1, "unverifiable": 0, "unreadable": []}
            """] {
            let payload = Data(json.utf8)
            try JSONDiff.assertLossless(WireDriftReport.self, payload: payload)
        }
    }

    // MARK: - Fixture scaffolding

    /// A minimal but SHAPE-FAITHFUL search payload, used only where the live capture cannot supply
    /// the case (an older server, a measured stack). Field names are copied from the captured
    /// bytes, not from `render.py`, so it cannot drift from what the round-trip tests decode.
    private static func searchPayload(refresh: String?) -> String {
        """
        {"scope": "scripta", "db": "/tmp/scripta.db", "query": "q", "passages": [],
         "outline_records": [],
         "retrieval_mode": {"embedder": null, "hyde": "off", "reranker": "off",
                            "expected_mrr": null, "cohort": "44-case semantic", "degraded": false,
                            "fallbacks": [], "unavailable": []},
         "filters": {"statuses_included": ["active", "complete"],
                     "statuses_excluded": ["archived", "superseded"], "sources_excluded": true,
                     "doc_type": null, "document_class": null, "notes": []},
         "index_version": "v8:84fda18a439c"\(refresh.map { ", \($0)" } ?? "")}
        """
    }
}
