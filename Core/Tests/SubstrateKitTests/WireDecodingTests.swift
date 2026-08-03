import XCTest
@testable import SubstrateKit

/// Decoding, checked against what the engine actually sent.
final class WireDecodingTests: XCTestCase {

    // MARK: - Lossless round trips against the captured bytes

    func testSearchPayloadRoundTripsLosslessly() throws {
        try JSONDiff.assertLossless(WireSearchResult.self,
                                    payload: try GoldenFixture.payload(GoldenFixture.search))
    }

    func testTheConversationSearchRoundTripsLosslessly() throws {
        try JSONDiff.assertLossless(
            WireSearchResult.self,
            payload: try GoldenFixture.payload(GoldenFixture.searchIncludingSources)
        )
    }

    func testStatusPayloadRoundTripsLosslessly() throws {
        try JSONDiff.assertLossless(WireStatusResult.self,
                                    payload: try GoldenFixture.payload(GoldenFixture.status))
    }

    func testScopeListRoundTripsLosslessly() throws {
        try JSONDiff.assertLossless(WireScopeList.self,
                                    payload: try GoldenFixture.payload(GoldenFixture.listScopes))
    }

    func testExpandPayloadRoundTripsLosslessly() throws {
        try JSONDiff.assertLossless(WireExpandResult.self,
                                    payload: try GoldenFixture.payload(GoldenFixture.expand))
    }

    /// The round-trip gate has to be able to FAIL, or it proves nothing.
    ///
    /// A decoder that drops a key round-trips cleanly against its own output, which is exactly the
    /// blind spot the comparison is aimed at. So one is built that drops `truncated`, and the
    /// diff is required to name it.
    func testTheRoundTripGateCatchesADroppedField() throws {
        struct LossyPassage: Codable {
            let citation: String
            // `truncated` is deliberately absent.
        }
        struct LossySearch: Codable {
            let passages: [LossyPassage]
        }
        let payload = try GoldenFixture.payload(GoldenFixture.search)
        let decoded = try JSONDecoder().decode(LossySearch.self, from: payload)
        let reencoded = try JSONEncoder().encode(decoded)
        let difference = JSONDiff.firstDifference(
            expected: try JSONSerialization.jsonObject(with: payload),
            actual: try JSONSerialization.jsonObject(with: reencoded)
        )
        XCTAssertNotNil(difference, "a decoder that keeps one field of fifteen must not pass")
        XCTAssertTrue(difference?.contains("did not re-emit") == true,
                      "the diff should name a dropped key, got: \(difference ?? "nil")")
    }

    /// The gate's other blind spot, closed deliberately. `JSONSerialization` bridges booleans and
    /// numbers to the same `NSNumber`, and `NSNumber(false).isEqual(NSNumber(0))` is true — so a
    /// `frozen: false` re-encoded as `0` would slide through the very comparison written to protect
    /// the tri-state fields.
    func testTheRoundTripGateSeparatesFalseFromZero() throws {
        let asBool = try JSONSerialization.jsonObject(with: Data(#"{"frozen": false}"#.utf8))
        let asZero = try JSONSerialization.jsonObject(with: Data(#"{"frozen": 0}"#.utf8))
        let difference = JSONDiff.firstDifference(expected: asBool, actual: asZero)
        XCTAssertNotNil(difference, "`false` and `0` are different claims and must not compare equal")
        XCTAssertTrue(difference?.contains("boolean") == true,
                      "the diff should say which side was a boolean, got: \(difference ?? "nil")")
    }

    // MARK: - Values the engine actually sent

    func testSearchDecodesTheSpineAndTheEnvelope() throws {
        let result = try JSONDecoder()
            .decode(WireSearchResult.self, from: try GoldenFixture.payload(GoldenFixture.search))

        XCTAssertEqual(result.scope, "scripta")
        XCTAssertEqual(result.indexVersion, "v8:84fda18a439c")
        XCTAssertFalse(result.passages.isEmpty)

        let first = try XCTUnwrap(result.passages.first)
        XCTAssertEqual(first.expandRef, "scripta/scripta-doc3a-mcp-server#c00002")
        XCTAssertEqual(first.status, "active")
        XCTAssertEqual(first.confidence, "stated")
        XCTAssertEqual(first.documentClass, "reference-frozen",
                       "the class is on the wire now — a missing key would read as `null` and map "
                       + "to `.unreported` without anything else failing")
        XCTAssertEqual(first.supersedes, [], "supersedes is a LIST since v8, empty not null")
        XCTAssertNil(first.text, "`text` is null on a search result, never absent")
        XCTAssertTrue(first.truncated)
        XCTAssertNil(first.kind, "a passage has no `kind`; only an outline record does")

        // The two-speed layer: same spine, plus the discriminator.
        for outline in result.outlineRecords {
            XCTAssertEqual(outline.kind, "outline")
        }

        XCTAssertEqual(result.filters.statusesIncluded, ["active", "complete"])
        XCTAssertEqual(result.filters.statusesExcluded, ["archived", "superseded"])
        XCTAssertTrue(result.filters.sourcesExcluded)
        XCTAssertEqual(result.filters.notes, [])

        let mode = result.retrievalMode
        XCTAssertEqual(mode.embedderState, "off",
                       "the embedder has its own state word now, not just an emptied model key")
        XCTAssertEqual(mode.unmeasuredReason, "no_vector_arm",
                       "a null expected_mrr arrives WITH the reason the engine declined")
        XCTAssertTrue(mode.health.known)
        XCTAssertEqual(mode.health.state, "unreachable")
        XCTAssertEqual(mode.health.arms,
                       ["embedder": "unavailable", "hyde": "unavailable",
                        "reranker": "unavailable"])
    }

    /// THE ONE CAPTURE WHERE `document_class` VARIES. Default retrieval withholds the conversation
    /// class, so the first search cannot distinguish a decoder that reads the field from one that
    /// ignores it — every value there is the same. This one asked for sources back.
    func testTheConversationSearchCarriesMoreThanOneDocumentClass() throws {
        let result = try JSONDecoder().decode(
            WireSearchResult.self,
            from: try GoldenFixture.payload(GoldenFixture.searchIncludingSources)
        )
        XCTAssertFalse(result.filters.sourcesExcluded)

        let classes = Set((result.passages + result.outlineRecords).map(\.documentClass))
        XCTAssertEqual(classes, ["conversation", "reference-frozen"])

        let transcript = try XCTUnwrap(
            result.passages.first { $0.documentClass == "conversation" }
        )
        let mapped = try transcript.mapped()
        XCTAssertEqual(mapped.documentClass, .conversation)
        XCTAssertEqual(mapped.withheldAs, [.sources],
                       "a transcript passage must reach the card marked, which is what it could not "
                       + "do while the axis was supplied by the caller")
    }

    func testStatusDecodesCountsArmsAndDrift() throws {
        let result = try JSONDecoder()
            .decode(WireStatusResult.self, from: try GoldenFixture.payload(GoldenFixture.status))

        XCTAssertEqual(result.scope, "scripta")
        XCTAssertEqual(result.documents, 57)
        XCTAssertEqual(result.schemaVersion, 8)
        XCTAssertEqual(result.byStatus["active"], 48)
        XCTAssertEqual(result.byConfidence["unjudged"], 1)
        XCTAssertEqual(result.byConfidence["unstated"], 3,
                       "`unstated` and `unjudged` are different values and both were counted")

        // No local model server was up when this was captured, so no vector arm is wired at all —
        // and `vectors: null` is the whole block being absent, not zero coverage.
        XCTAssertNil(result.vectors)
        XCTAssertNil(result.retrievalArms.embedder)
        XCTAssertEqual(result.retrievalArms.unavailable.count, 3)
    }

    func testScopeListDecodesEveryComposedScope() throws {
        let list = try JSONDecoder()
            .decode(WireScopeList.self, from: try GoldenFixture.payload(GoldenFixture.listScopes))

        XCTAssertGreaterThanOrEqual(list.scopes.count, 7)
        let scripta = try XCTUnwrap(list.scopes.first { $0.scope == "scripta" })
        XCTAssertTrue(scripta.indexPresent)
        XCTAssertEqual(scripta.sources, ["core-vault", "scripta-vault"])
        XCTAssertNil(scripta.error, "`error` is present only on a resolution failure")
        XCTAssertTrue(list.scopes.allSatisfy { $0.refresh.wasSent })
    }

    /// THE ONE ROW SHAPE THE CAPTURE COULD NOT SUPPLY. Every scope on this machine resolves, so no
    /// captured row carries the `error` key `scopes_payload` writes in its except branch — and that
    /// branch is the whole reason the payload lists a broken scope at all: "omitting it would read
    /// as 'that scope was never composed', which is the opposite of the truth."
    ///
    /// Synthetic, and said so. Its field names come from the captured row beside it plus the
    /// two-key except branch that `RenderContractTests` reads out of `introspect.py`, so it cannot
    /// invent a shape the source does not write.
    func testAScopeThatFailedToResolveKeepsBothItsFaultAndItsRow() throws {
        let json = """
            {"scope": "gone", "db": "/tmp/gone.db", "vault": "/vaults/gone-vault",
             "composed": "2026-07-29T14:33:44+00:00", "index_present": false,
             "refresh": {"known": false, "outcome": null, "attempted": null, "succeeded": null,
                         "frozen": null, "frozen_since": null, "note": "no refresh agent has …"},
             "sources": null, "error": "no manifest at /vaults/gone-vault"}
            """
        let row = try JSONDecoder().decode(WireScopeRow.self, from: Data(json.utf8))
        XCTAssertNil(row.sources)
        XCTAssertEqual(row.error, "no manifest at /vaults/gone-vault")
        XCTAssertEqual(row.refresh.frozen, .noBasis,
                       "an unresolvable scope has no refresh verdict, not a clean one")
        try JSONDiff.assertLossless(WireScopeRow.self, payload: Data(json.utf8))
    }

    func testExpandCarriesTheWholeTextAndTheNote() throws {
        let result = try JSONDecoder()
            .decode(WireExpandResult.self, from: try GoldenFixture.payload(GoldenFixture.expand))

        XCTAssertEqual(result.mode, "note")
        XCTAssertNotNil(result.passage.text, "`full=True` fills `text`")
        XCTAssertFalse(result.passage.truncated, "nothing was withheld from an expanded passage")

        let note = try XCTUnwrap(result.note)
        XCTAssertEqual(note.stale, .matches)
        XCTAssertFalse(note.truncated)
        XCTAssertGreaterThan(note.nChars, 0)
    }
}
