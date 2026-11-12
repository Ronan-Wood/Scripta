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

    /// `exposed` has three wire states and each must survive a round trip: absent (an engine older
    /// than the field), `null` (an agent-mode server), and a list. Collapsing absent and `null`
    /// into one optional would re-encode one as the other. The golden capture SENDS a list — the
    /// engine found the demo workspace readable by other users — so absence is made by removing
    /// the key from it.
    func testStatusExposureDecodesAndRoundTripsEachWireState() throws {
        let golden = try GoldenFixture.payload(GoldenFixture.status)
        XCTAssertEqual(try JSONDecoder().decode(WireStatusResult.self, from: golden).exposed,
                       .paths(["/demo-substrate"]))

        let cases: [(Any?, WireExposure)] = [
            (nil, .notSent),
            (NSNull(), .notChecked),
            ([String](), .paths([])),
            (["/x/demo.db", "/x/demo-index"], .paths(["/x/demo.db", "/x/demo-index"])),
        ]
        for (value, expected) in cases {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: golden) as? [String: Any])
            object["exposed"] = value
            let payload = try JSONSerialization.data(withJSONObject: object)
            XCTAssertEqual(try JSONDecoder().decode(WireStatusResult.self, from: payload).exposed,
                           expected)
            try JSONDiff.assertLossless(WireStatusResult.self, payload: payload)
        }
    }

    /// `server.writes_log` has three wire states, like `exposed`: absent (an engine older than the
    /// write log), `null` (agent mode, which reads none), and the log's path.
    func testTheWritesLogDecodesAndRoundTripsEachWireState() throws {
        let golden = try GoldenFixture.payload(GoldenFixture.listScopes)
        let cases: [(Any?, WireWritesLog)] = [
            (nil, .notSent),
            (NSNull(), .noLog),
            ("/x/writes.jsonl", .path("/x/writes.jsonl")),
        ]
        for (value, expected) in cases {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: golden) as? [String: Any])
            var server = try XCTUnwrap(object["server"] as? [String: Any])
            server["writes_log"] = value
            object["server"] = server
            let payload = try JSONSerialization.data(withJSONObject: object)
            XCTAssertEqual(try JSONDecoder().decode(WireScopeList.self, from: payload)
                           .server?.writesLog, expected)
            try JSONDiff.assertLossless(WireScopeList.self, payload: payload)
        }
    }

    /// Every golden passage's `provenance` is `none` with nulls, so a value is decoded here.
    func testAPopulatedProvenanceDecodesAndRoundTrips() throws {
        let payload = Data(#"""
            {"state": "engine", "client": "claude-code", "op": "amend",
             "at": "2026-11-11T14:03:22.418Z", "stamp": "matches", "stamped_by": "claude-code"}
            """#.utf8)
        XCTAssertEqual(try JSONDecoder().decode(WireProvenance.self, from: payload),
                       WireProvenance(state: "engine", client: "claude-code", op: "amend",
                                      at: "2026-11-11T14:03:22.418Z", stamp: "matches",
                                      stampedBy: "claude-code"))
        try JSONDiff.assertLossless(WireProvenance.self, payload: payload)
        let missing = Data(#"{"state": "none", "client": null}"#.utf8)
        XCTAssertThrowsError(try JSONDecoder().decode(WireProvenance.self, from: missing),
                             "one key set: a key left out is not a null")
    }

    /// `hyde_requested` has three wire states, like `exposed`: absent (an engine older than the
    /// field), `null` (HyDE off), and what HyDE was asked for. It is the engine's own account of
    /// its Search pick, which this app reads instead of keeping a copy of the engine's rule. The
    /// golden capture asked for the default, `auto`; absence is made by removing the key.
    func testTheHydeRequestDecodesAndRoundTripsEachWireState() throws {
        let golden = try GoldenFixture.payload(GoldenFixture.status)
        XCTAssertEqual(try JSONDecoder().decode(WireStatusResult.self, from: golden)
            .retrievalArms.hydeRequested, .asked("auto"))
        let cases: [(Any?, WireHydeRequest)] = [
            (nil, .notSent), (NSNull(), .off), ("auto", .asked("auto")),
            ("mistral:7b", .asked("mistral:7b")),
        ]
        for (value, expected) in cases {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: golden) as? [String: Any])
            var arms = try XCTUnwrap(object["retrieval_arms"] as? [String: Any])
            arms["hyde_requested"] = value
            object["retrieval_arms"] = arms
            let payload = try JSONSerialization.data(withJSONObject: object)
            XCTAssertEqual(try JSONDecoder().decode(WireStatusResult.self, from: payload)
                .retrievalArms.hydeRequested, expected)
            try JSONDiff.assertLossless(WireStatusResult.self, payload: payload)
        }
    }

    /// `list_scopes` carries the serving process's arms (`_tool_list_scopes`). The golden capture
    /// sends them — three unreachable arms, HyDE asked for as `auto` — and an engine older than the
    /// field omits them; both states round-trip.
    func testTheScopeListsArmsDecodeAndRoundTrip() throws {
        let golden = try GoldenFixture.payload(GoldenFixture.listScopes)
        let captured = try XCTUnwrap(
            JSONDecoder().decode(WireScopeList.self, from: golden).retrievalArms)
        XCTAssertNil(captured.embedder)
        XCTAssertEqual(captured.hydeRequested, .asked("auto"))
        XCTAssertEqual(captured.unavailable.count, 3)

        var object = try XCTUnwrap(JSONSerialization.jsonObject(with: golden) as? [String: Any])
        object.removeValue(forKey: "retrieval_arms")
        let older = try JSONSerialization.data(withJSONObject: object)
        XCTAssertNil(try JSONDecoder().decode(WireScopeList.self, from: older).retrievalArms)
        try JSONDiff.assertLossless(WireScopeList.self, payload: older)

        object["retrieval_arms"] = ["embedder": "qwen3-embedding:0.6b#raw", "hyde": "qwen3.5:4b-mlx",
                                    "hyde_requested": "auto", "reranker": NSNull(),
                                    "unavailable": [String]()] as [String: Any]
        let payload = try JSONSerialization.data(withJSONObject: object)
        let arms = try XCTUnwrap(JSONDecoder().decode(WireScopeList.self, from: payload).retrievalArms)
        XCTAssertEqual(arms.hyde, "qwen3.5:4b-mlx")
        XCTAssertEqual(arms.hydeRequested, .asked("auto"))
        try JSONDiff.assertLossless(WireScopeList.self, payload: payload)
    }

    /// What `refresh` answers, in each of its three shapes, and back.
    func testARefreshRequestsReplyDecodesAndRoundTrips() throws {
        for (when, wait) in [("now", 0.0), ("after_pass", 0.0), ("after_gap", 6.5)] {
            let payload = Data(#"{"next_pass": "\#(when)", "wait_seconds": \#(wait)}"#.utf8)
            let reply = try JSONDecoder().decode(WireRefreshRequest.self, from: payload)
            XCTAssertEqual(reply.nextPass.rawValue, when)
            XCTAssertEqual(reply.waitSeconds, wait)
            try JSONDiff.assertLossless(WireRefreshRequest.self, payload: payload)
        }
    }

    /// `list_scopes` says what kind of server answered. The golden capture is a read-only server
    /// that refreshes nothing; a `substrate serve` engine says it refreshes, and an engine older
    /// than the field sends no block at all.
    func testTheScopeListsServerBlockDecodesAndRoundTrips() throws {
        let golden = try GoldenFixture.payload(GoldenFixture.listScopes)
        XCTAssertEqual(try JSONDecoder().decode(WireScopeList.self, from: golden).server,
                       WireServerInfo(readOnly: true, agentMode: false, refreshEvery: nil,
                                      refreshRequests: false, notesVersion: 2, notesMinVersion: 1,
                                      writes: "none",
                                      writesLog: .path("/demo-substrate/engine-home/writes.jsonl")))
        var withoutBlock = try XCTUnwrap(
            JSONSerialization.jsonObject(with: golden) as? [String: Any])
        withoutBlock.removeValue(forKey: "server")
        let older = try JSONSerialization.data(withJSONObject: withoutBlock)
        XCTAssertNil(try JSONDecoder().decode(WireScopeList.self, from: older).server)
        try JSONDiff.assertLossless(WireScopeList.self, payload: older)
        for every in [900.0, nil] as [Double?] {
            var object = try XCTUnwrap(JSONSerialization.jsonObject(with: golden) as? [String: Any])
            object["server"] = ["read_only": true, "agent_mode": false,
                                "refresh_every": every.map { $0 as Any } ?? NSNull()]
            let payload = try JSONSerialization.data(withJSONObject: object)
            let server = try XCTUnwrap(JSONDecoder().decode(WireScopeList.self, from: payload).server)
            XCTAssertEqual(server, WireServerInfo(readOnly: true, agentMode: false, refreshEvery: every))
            try JSONDiff.assertLossless(WireScopeList.self, payload: payload)
        }
    }

    func testScopeListRoundTripsLosslessly() throws {
        try JSONDiff.assertLossless(WireScopeList.self,
                                    payload: try GoldenFixture.payload(GoldenFixture.listScopes))
    }

    func testExpandPayloadRoundTripsLosslessly() throws {
        try JSONDiff.assertLossless(WireExpandResult.self,
                                    payload: try GoldenFixture.payload(GoldenFixture.expand))
    }

    func testDocumentsPayloadRoundTripsLosslessly() throws {
        try JSONDiff.assertLossless(WireDocumentsResult.self,
                                    payload: try GoldenFixture.payload(GoldenFixture.documents))
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

        XCTAssertEqual(result.scope, "demo")
        // One capture, one index: every frame of it names the same `index_version`, and the
        // version leads with the schema the status frame reports.
        let status = try JSONDecoder()
            .decode(WireStatusResult.self, from: try GoldenFixture.payload(GoldenFixture.status))
        XCTAssertEqual(result.indexVersion, status.indexVersion)
        XCTAssertTrue(result.indexVersion.hasPrefix("v\(status.schemaVersion):"))
        XCTAssertFalse(result.passages.isEmpty)

        let first = try XCTUnwrap(result.passages.first)
        XCTAssertEqual(first.expandRef, "demo/engine-boundary-current#c00000")
        XCTAssertEqual(first.status, "active")
        XCTAssertEqual(first.confidence, "unjudged",
                       "the demo note declares no confidence, and absence has its own word")
        XCTAssertEqual(first.documentClass, "unclassified",
                       "the class is on the wire now — a missing key would read as `null` and map "
                       + "to `.unreported` without anything else failing. `unclassified` is what "
                       + "an undeclared note sends, rather than an invented `reference-frozen`")
        // A NON-EMPTY list: the top hit is a note that replaced one. `[]` and `["x"]` decode
        // through the same path, but only this shape proves the LIST half of v8 rather than the
        // null-vs-empty half.
        XCTAssertEqual(first.supersedes, ["engine-boundary-old"],
                       "supersedes is a LIST since v8 — one note can replace several")
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
        XCTAssertEqual(classes, ["conversation", "unclassified", "reference-versioned"])

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

        XCTAssertEqual(result.scope, "demo")
        XCTAssertEqual(result.documents, 10)
        XCTAssertEqual(result.schemaVersion, 11)
        XCTAssertEqual(result.byVault, ["demo-core-vault": 3, "demo-vault": 7],
                       "the inherited vault's notes are counted in the scope that composes them")
        // v10's identity layer. EMPTY IS THE HONEST VALUE HERE: `demo-vault` declares no roster,
        // and an empty list means nobody was RESOLVED — never that nobody was mentioned.
        XCTAssertEqual(result.entities, [])
        XCTAssertEqual(result.byStatus["active"], 7)
        XCTAssertEqual(result.byConfidence["unjudged"], 9)
        XCTAssertEqual(result.byConfidence["unstated"], 1,
                       "`unstated` and `unjudged` are different values and both were counted — "
                       + "the transcript DECLARES `unstated`; every other demo note declares nothing")

        // No local model server answered during the capture, so no vector arm is wired at all —
        // and `vectors: null` is the whole block being absent, not zero coverage.
        XCTAssertNil(result.vectors)
        XCTAssertNil(result.retrievalArms.embedder)
        XCTAssertEqual(result.retrievalArms.unavailable.count, 3)
    }

    func testScopeListDecodesEveryComposedScope() throws {
        let list = try JSONDecoder()
            .decode(WireScopeList.self, from: try GoldenFixture.payload(GoldenFixture.listScopes))

        XCTAssertEqual(list.scopes.map(\.scope), ["demo"],
                       "the capture's registry holds one scope")
        XCTAssertEqual(list.registry, "/demo-substrate/scopes.toml")
        let demo = try XCTUnwrap(list.scopes.first)
        XCTAssertTrue(demo.indexPresent)
        XCTAssertEqual(demo.sources, ["demo-core-vault", "demo-vault"],
                       "a scope lists its inherited vault as a source, not only its own")
        XCTAssertNil(demo.error, "`error` is present only on a resolution failure")
        XCTAssertTrue(list.scopes.allSatisfy { $0.refresh.wasSent })
    }

    /// THE ONE ROW SHAPE THE CAPTURE COULD NOT SUPPLY. The captured scope resolves, so no
    /// captured row carries the `error` key `scopes_payload` writes in its except branch — and that
    /// branch is the whole reason the payload lists a broken scope at all: "omitting it would read
    /// as 'that scope was never composed', which is the opposite of the truth."
    ///
    /// Synthetic, and said so. Its field names come from the captured row beside it plus the
    /// `error` key the engine's contract declares for `scope_row` (pinned in `RenderContractTests`),
    /// so it cannot invent a shape the engine does not send.
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
        XCTAssertEqual(row.vaultState, .faulted, "it names a vault, but its fault is what it reports")
        XCTAssertEqual(row.vaultPath, "/vaults/gone-vault",
                       "a scope that fails to resolve still names a directory another can collide with")
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

    // MARK: - documents

    func testDocumentsCarriesProvenanceTheScopesOwnFolderDoesNotHold() throws {
        let result = try JSONDecoder()
            .decode(WireDocumentsResult.self, from: try GoldenFixture.payload(GoldenFixture.documents))

        // A PAGE, not the corpus — and the payload says both, which is the whole reason `returned`
        // and `total` are separate fields.
        XCTAssertEqual(result.returned, 3)
        XCTAssertEqual(result.returned, result.documents.count)
        XCTAssertGreaterThan(result.total, result.returned,
                             "this capture is a page of a larger corpus; if it ever stops being "
                             + "one, the short-page-vs-small-corpus distinction goes untested")

        // THE PROPERTY THE TOOL EXISTS FOR. Every row composed from a vault that is NOT the scope's
        // own — reading `demo-vault`'s directory would have returned none of these three. Their
        // tiers are the inherited ones; the project vault's own notes are tier 3.
        let vaults = Set(result.documents.compactMap(\.vault))
        XCTAssertEqual(vaults, ["demo-core-vault"])
        XCTAssertEqual(Set(result.documents.compactMap(\.tier)), [1, 2])
        XCTAssertNil(result.filters.vaults, "no tier was asked for — they are simply first")

        // The spine crosses whole, and it maps — a token this build has no case for refuses by
        // name here rather than arriving as a plausible neighbour.
        let mapped = try result.mappedDocuments()
        XCTAssertEqual(mapped.count, 3)
        XCTAssertTrue(mapped.allSatisfy { $0.expandRef != nil },
                      "every row in this capture has passages, so every one is readable")
        XCTAssertTrue(mapped.allSatisfy { $0.passageCount > 0 })
        // Three rows, three classes. `unclassified` is a WORD on this axis, not the absence of one
        // — the distinction that was missing when the reader defaulted an undeclared class to
        // `reference-frozen` — and it sits here beside the two classes a note really declares.
        XCTAssertEqual(Set(mapped.map(\.documentClass)),
                       [.unclassified, .referenceFrozen, .referenceVersioned])
        XCTAssertEqual(Set(mapped.map(\.docType)), [.explanation, .reference],
                       "the capture spans doc_types")
        XCTAssertTrue(mapped.allSatisfy { $0.confidence == .unjudged },
                      "none of the three declares a confidence, and absence maps to its own case")

        // Browse withholds exactly what search withholds, and says so.
        XCTAssertTrue(result.filters.sourcesExcluded)
    }

    /// A note with NO passages is a row, not an omission — and its ref is null rather than invented.
    ///
    /// Not in the capture (the three rows all have passages), so it is constructed. That is honest
    /// about what it proves: the DECODER and the MAPPER handle the state, which is the half that
    /// lives in this module. The engine really does produce it, and the engine-side half is
    /// asserted in its own suite.
    func testAPassagelessNoteMapsToAnUnreadableRowRatherThanThrowing() throws {
        let json = """
            {"doc_id": "empty-note", "title": null, "expand_ref": null, "passage_count": 0,
             "vault": "core-vault", "tier": 1,
             "document_class": "unclassified", "status": "active", "doc_type": "reference",
             "confidence": "unjudged", "domains": [], "supersedes": [], "superseded_by": null}
            """
        let wire = try JSONDecoder().decode(WireDocumentRecord.self, from: Data(json.utf8))
        let mapped = try wire.mapped()

        XCTAssertNil(mapped.expandRef, "an empty note has nothing to expand, and says so")
        XCTAssertNil(mapped.title)
        XCTAssertEqual(mapped.passageCount, 0)
        XCTAssertEqual(mapped.id, "empty-note")
        try JSONDiff.assertLossless(WireDocumentRecord.self, payload: Data(json.utf8))
    }

    /// EVERY nullable key null at once, because the lossless gate can only see a dropped key when
    /// the captured value IS null. No fixture carries `vault`, `tier` or `document_class` as null,
    /// so swapping their `encodeExplicitNull` for Swift's default `encodeIfPresent` — the exact
    /// mistake `WireCoding` exists to prevent — passed every other test in this file.
    func testEveryNullableDocumentKeySurvivesAsAnExplicitNull() throws {
        let json = """
            {"doc_id": "bare", "title": null, "expand_ref": null, "passage_count": 0,
             "vault": null, "tier": null, "document_class": null, "status": "active",
             "doc_type": "reference", "confidence": "unjudged", "domains": [], "supersedes": [],
             "superseded_by": null}
            """
        try JSONDiff.assertLossless(WireDocumentRecord.self, payload: Data(json.utf8))

        let mapped = try JSONDecoder()
            .decode(WireDocumentRecord.self, from: Data(json.utf8)).mapped()
        // A null class is `.unreported` — the ABSENCE of a class, never the settled-reading default.
        XCTAssertEqual(mapped.documentClass, .unreported)
        // A null vault is empty rather than a stand-in word: invented provenance is worse than none.
        XCTAssertEqual(mapped.vault, "")
        XCTAssertNil(mapped.tier)
    }

    // MARK: - agent mode

    /// An agent-mode server names no vault and no registry, and these declared both as `String`, so
    /// every agent-mode `status` and `list_scopes` threw `valueNotFound` before reaching a field.
    func testAgentModeStatusDecodesWithNoVault() throws {
        let status = try JSONDecoder().decode(
            WireStatusResult.self, from: try GoldenFixture.payload(GoldenFixture.agentStatus))
        XCTAssertNil(status.vault)
        XCTAssertNotNil(status.composed, "a published snapshot still says when it was composed")
        XCTAssertEqual(status.exposed, .notChecked)
        try JSONDiff.assertLossless(WireStatusResult.self,
                                    payload: try modelledPart(of: GoldenFixture.agentStatus))
    }

    func testAgentModeStatusWithNoManifestDecodesWithNoComposedStamp() throws {
        let status = try JSONDecoder().decode(
            WireStatusResult.self,
            from: try GoldenFixture.payload(GoldenFixture.agentStatusUnpublished))
        XCTAssertNil(status.vault)
        XCTAssertNil(status.composed)
        try JSONDiff.assertLossless(
            WireStatusResult.self,
            payload: try modelledPart(of: GoldenFixture.agentStatusUnpublished))
    }

    func testAgentModeScopeListDecodesWithNoVaultOrRegistry() throws {
        let list = try JSONDecoder().decode(
            WireScopeList.self, from: try GoldenFixture.payload(GoldenFixture.agentListScopes))
        XCTAssertNil(list.registry)
        let row = try XCTUnwrap(list.scopes.first)
        XCTAssertEqual(list.scopes.count, 1)
        XCTAssertEqual(row.scope, "demo")
        XCTAssertNil(row.vault)
        XCTAssertNotNil(row.composed)
        try JSONDiff.assertLossless(WireScopeList.self,
                                    payload: try modelledPart(of: GoldenFixture.agentListScopes))
    }

    /// An agent-mode row names no vault, and nothing about it failed. The distinction is what lets
    /// a refresh pass report an all-agent roster unavailable, instead of recording `compose_failed`
    /// for each row and freezing the operator's scopes of the same names.
    func testARowThatNamesNoVaultIsNotAFaultedOne() throws {
        let agent = try JSONDecoder().decode(
            WireScopeList.self, from: try GoldenFixture.payload(GoldenFixture.agentListScopes))
        XCTAssertEqual(agent.scopes.map(\.vaultState), [.notNamed])
        XCTAssertNil(agent.scopes.first?.vaultPath)
        XCTAssertTrue(agent.scopes.namesNoVault)

        let operatorRows = try JSONDecoder().decode(
            WireScopeList.self, from: try GoldenFixture.payload(GoldenFixture.listScopes)).scopes
        XCTAssertFalse(operatorRows.isEmpty)
        for row in operatorRows {
            XCTAssertEqual(row.vaultState, .named(try XCTUnwrap(row.vault)), row.scope)
            XCTAssertEqual(row.vaultPath, row.vault, row.scope)
        }
        XCTAssertFalse(operatorRows.namesNoVault)
        // Mixed is no engine's roster; it must not read as an agent one, or its operator rows would
        // never be composed.
        XCTAssertFalse((operatorRows + agent.scopes).namesNoVault)
        XCTAssertFalse([WireScopeRow]().namesNoVault, "an empty roster is not an agent-mode one")
    }

    /// A null vault is agent mode's whatever else the row says. Read as faulted, one agent row with
    /// an `error` would stop the roster reading as agent-only, and every row would be frozen.
    func testANullVaultIsNotNamedEvenBesideAnError() throws {
        let json = """
            {"scope": "demo", "db": "/agent-snapshots/demo.snapshot.db", "vault": null,
             "composed": null, "index_present": false, "sources": null,
             "error": "no snapshot published yet"}
            """
        let row = try JSONDecoder().decode(WireScopeRow.self, from: Data(json.utf8))
        XCTAssertEqual(row.vaultState, .notNamed)
        XCTAssertTrue([row].namesNoVault)
    }

    /// A GUARD, NOT A CAPTURE: no engine sends these (`scopes.record` stores an absolute path,
    /// `agent.py` writes null), but a hand-edited registry can. `URL(fileURLWithPath:)` resolves an
    /// empty or relative vault against the working directory, and the root is no vault, so none of
    /// them is a path to compose.
    func testAnEmptyRelativeOrRootVaultIsFaultedRatherThanAPath() throws {
        // `\u{0600}` is a prepend scalar: it fuses with the `/` after it into one Character, so a
        // split by Character would miss that separator and read this as a directory.
        for vault in ["", "/", "//", "/.", "/./", "/./.", "/..", "/../", "/a/..", "/a/./..",
                      "/a/b/../..", "/\u{0600}/..", "vaults/blank-vault", "~/vaults/blank-vault"] {
            let json = """
                {"scope": "blank", "db": "/tmp/blank.db", "vault": "\(vault)",
                 "composed": "2026-07-29T14:33:44+00:00", "index_present": true,
                 "sources": ["blank-vault"]}
                """
            let row = try JSONDecoder().decode(WireScopeRow.self, from: Data(json.utf8))
            XCTAssertNil(row.error)
            XCTAssertEqual(row.vaultState, .faulted, "`\(vault)`")
            XCTAssertNil(row.vaultPath, "`\(vault)`")
        }
    }

    /// The other side of the root check: a dot or dot-dot that leaves a directory below the root
    /// is still that directory, and the row keeps naming it exactly as the engine sent it.
    func testADotOrDotDotThatStaysBelowRootIsStillNamed() throws {
        for vault in ["/a/../b", "/a/./b", "///a", "/../a", "/a/b/.."] {
            let json = """
                {"scope": "kept", "db": "/tmp/kept.db", "vault": "\(vault)",
                 "composed": "2026-07-29T14:33:44+00:00", "index_present": true,
                 "sources": ["kept-vault"]}
                """
            let row = try JSONDecoder().decode(WireScopeRow.self, from: Data(json.utf8))
            XCTAssertEqual(row.vaultState, .named(vault), "`\(vault)`")
        }
    }

    /// Null is a value the engine sends; a MISSING key is a different engine. Optional must not have
    /// turned into "absent is fine".
    func testAMissingVaultKeyStillRefusesToDecode() throws {
        var object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try GoldenFixture.payload(GoldenFixture.agentStatus)) as? [String: Any])
        object.removeValue(forKey: "vault")
        let payload = try JSONSerialization.data(withJSONObject: object)
        XCTAssertThrowsError(try JSONDecoder().decode(WireStatusResult.self, from: payload)) {
            guard case DecodingError.keyNotFound(let key, _) = $0 else {
                return XCTFail("expected keyNotFound, got \($0)")
            }
            XCTAssertEqual(key.stringValue, "vault")
        }
    }

    /// An agent frame minus the two keys only agent mode sends and the app does not model —
    /// `snapshot_dir`, and `snapshot` inside each `refresh` — so the lossless gate can run on the rest.
    private func modelledPart(of fixture: String) throws -> Data {
        func strip(_ object: [String: Any]) -> [String: Any] {
            var object = object
            object.removeValue(forKey: "snapshot_dir")
            if var refresh = object["refresh"] as? [String: Any] {
                refresh.removeValue(forKey: "snapshot")
                object["refresh"] = refresh
            }
            if let scopes = object["scopes"] as? [[String: Any]] {
                object["scopes"] = scopes.map(strip)
            }
            return object
        }
        let object = try XCTUnwrap(JSONSerialization.jsonObject(
            with: try GoldenFixture.payload(fixture)) as? [String: Any])
        return try JSONSerialization.data(withJSONObject: strip(object))
    }

    /// `writes` arrived with grants. An engine before it states none, which decodes as nil.
    func testTheServerBlockDecodesItsWritesMode() throws {
        let block = #"{"read_only": true, "writes": "granted", "agent_mode": false, "refresh_every": 900}"#
        let server = try JSONDecoder().decode(WireServerInfo.self, from: Data(block.utf8))
        XCTAssertEqual(server.writes, "granted")
        XCTAssertTrue(server.readOnly)
        let older = #"{"read_only": true, "agent_mode": false, "refresh_every": 900}"#
        XCTAssertNil(try JSONDecoder().decode(WireServerInfo.self, from: Data(older.utf8)).writes)
    }

}
