import XCTest
@testable import SubstrateKit

/// The drift check: does the Swift decoder still describe the payload `render.py` builds?
///
/// THREE SOURCES ARE MADE TO AGREE, and needing all three is the point:
///   1. the engine's SOURCE — every key its payload builders literally write
///   2. the engine's OUTPUT — the key set in the captured golden frames
///   3. the Swift DECODER — proven by `WireDecodingTests`' lossless round trip against (2)
/// A key added to `render.py` fails (1) here on the next run, before anyone re-captures. A key
/// present in the source but never emitted at runtime fails (2). A key both send and Swift drops
/// fails the round trip. No single one of the three catches all of that.
///
/// The parser's limits are written out at the top of `PythonPayloadSource.swift`. Read them before
/// concluding a green run means the shape is pinned.
final class RenderContractTests: XCTestCase {

    private func render() throws -> PythonSource {
        try PythonSource.load("substrate/substrate/render.py")
    }

    // MARK: - render.py

    func testPassageKeysMatchTheDecoder() throws {
        let payload = try render().payload(of: "passage")
        XCTAssertEqual(payload.keys(plus: "out"), [
            "expand_ref", "citation", "path", "page", "n_chars",
            "status", "doc_type", "confidence", "domains", "vault", "supersedes",
            "snippet", "text", "truncated",
        ])
    }

    /// `outline_record` is a `passage` plus one discriminator. Checked separately so a second key
    /// bolted onto an orientation record cannot hide behind the passage's own set.
    func testOutlineRecordAddsOnlyKind() throws {
        XCTAssertEqual(try render().payload(of: "outline_record").assigned["rec"] ?? [], ["kind"])
    }

    /// THE ONE ABSENCE THIS CLIENT DEPENDS ON.
    ///
    /// `index_store.Hit` carries a `document_class`; `render.passage` does not emit it, so the axis
    /// is not on the wire — which is why `WirePassage.mapped(documentClass:)` makes the caller
    /// supply it rather than defaulting a transcript to `reference-frozen`. When this fails,
    /// `render.passage` has started sending it: decode the key and delete that parameter.
    func testPassageStillDoesNotCarryDocumentClass() throws {
        let keys = try render().payload(of: "passage").keys(plus: "out")
        XCTAssertFalse(keys.contains("document_class"),
                       "`render.passage` now emits document_class. Decode it in WirePassage and "
                       + "drop the `documentClass:` parameter from `mapped` — the client is "
                       + "currently making the caller state an axis the engine can now report.")
    }

    func testRetrievalModeKeysMatchTheDecoder() throws {
        XCTAssertEqual(try render().payload(of: "retrieval_mode").keys(), [
            "embedder", "hyde", "reranker", "expected_mrr", "cohort", "degraded",
            "fallbacks", "unavailable",
        ])
    }

    /// `EngineEnvelope.unmeasuredReason` has no wire source, and its own doc comment says the engine
    /// "always knows which of the five reasons applies". It does — and it does not send it. If a
    /// reason field ever appears in `retrieval_mode` the assertion above fails; this names what to
    /// do about it, because a `nil` reason beside a `nil` MRR is indistinguishable from a bug.
    func testNoReasonAccompaniesAnUnmeasuredMRR() throws {
        let keys = try render().payload(of: "retrieval_mode").keys()
        XCTAssertFalse(keys.contains { $0.contains("reason") },
                       "`retrieval_mode` now carries a reason for an unmeasured MRR. Decode it and "
                       + "pass it to EngineEnvelope.unmeasuredReason, which is nil today only "
                       + "because nothing on the wire could fill it.")
    }

    func testAppliedFiltersKeysMatchTheDecoder() throws {
        XCTAssertEqual(try render().payload(of: "applied_filters").keys(), [
            "statuses_included", "statuses_excluded", "sources_excluded",
            "doc_type", "document_class", "notes",
        ])
    }

    func testSearchPayloadKeysMatchTheDecoder() throws {
        XCTAssertEqual(try render().payload(of: "search_payload").keys(), [
            "scope", "db", "query", "passages", "outline_records",
            "retrieval_mode", "filters", "index_version", "refresh",
        ])
    }

    // MARK: - refresh_state.py, introspect.py, freshness.py, mcp/server.py

    func testRefreshBlockKeysMatchTheDecoder() throws {
        let source = try PythonSource.load("substrate/substrate/refresh_state.py")
        XCTAssertEqual(try source.payload(of: "_block").keys(), [
            "known", "outcome", "attempted", "succeeded", "frozen", "frozen_since", "note",
        ])
    }

    /// `refresh_state.OUTCOMES` is the table that decides `frozen`, and `skipped` sitting under a
    /// null verdict rather than `False` is the whole tri-state. A new outcome this build has no
    /// interpretation for is handled by the engine (it reports the word and withholds a verdict),
    /// so this asserts the vocabulary is still the one the tests reason about.
    func testRefreshOutcomeVocabulary() throws {
        let source = try PythonSource.load("substrate/substrate/refresh_state.py")
        XCTAssertEqual(try source.binding("OUTCOMES").keys(), [
            "unchanged", "refreshed", "compose_failed", "embed_failed", "skipped",
        ])
    }

    func testStatusPayloadKeysMatchTheDecoder() throws {
        let source = try PythonSource.load("substrate/substrate/introspect.py")
        XCTAssertEqual(try source.payload(of: "status_payload").keys(plus: "out"), [
            "scope", "db", "vault", "composed", "index_version",
            "documents", "passages", "outlines", "schema_version",
            "by_vault", "by_tier", "by_status", "by_doc_type", "by_confidence",
            "retrieval_arms", "vectors", "refresh", "drift",
        ])
        XCTAssertEqual(try source.payload(of: "arms").keys(),
                       ["embedder", "hyde", "reranker", "unavailable"])
        XCTAssertEqual(try source.payload(of: "vector_status").keys(),
                       ["model", "stored", "chunks", "complete", "note"])
    }

    func testScopeListKeysMatchTheDecoder() throws {
        let source = try PythonSource.load("substrate/substrate/introspect.py")
        let payload = try source.payload(of: "scopes_payload")
        // Two literals: the per-scope row, then the envelope around the list.
        XCTAssertEqual(payload.keys(dict: 0, plus: "row"), [
            "scope", "db", "vault", "composed", "index_present", "refresh", "sources", "error",
        ])
        XCTAssertEqual(payload.keys(dict: 1), ["scopes", "registry"])
    }

    func testDriftKeysMatchTheDecoder() throws {
        let source = try PythonSource.load("substrate/substrate/freshness.py")
        XCTAssertEqual(try source.payload(of: "drift").keys(), [
            "stale", "checkable", "added", "removed", "changed",
            "checked", "unverifiable", "unreadable",
        ])
    }

    func testExpandKeysMatchTheDecoder() throws {
        let source = try PythonSource.load("substrate/substrate/mcp/server.py")
        XCTAssertEqual(try source.payload(of: "_tool_expand").keys(plus: "out"),
                       ["scope", "mode", "index_version", "passage", "note"])
        XCTAssertEqual(try source.payload(of: "_note_text").keys(),
                       ["path", "text", "n_chars", "truncated", "stale"])
    }

    // MARK: - The vocabulary the mapping refuses on

    /// `PassageStatus` and `RetrievalClass` against `spine.STATUSES`, and the default partition
    /// against `spine.INCLUDED_STATUSES`. `RetrievalClass.isDefault` is what `ExclusionFilter`
    /// computes the whole disclosure from, so a status moving across that partition in the engine
    /// silently inverts the sentence the reader is shown.
    func testStatusVocabularyMatchesSpine() throws {
        let spine = try PythonSource.load("substrate/substrate/spine.py")
        let statuses = try spine.binding("STATUSES").members
        XCTAssertEqual(statuses, Set(PassageStatus.allCases.map(\.rawValue)))

        let included = try spine.binding("INCLUDED_STATUSES").members
        XCTAssertEqual(included, Set(RetrievalClass.allCases.filter(\.isDefault).map(\.rawValue)))

        // `sources` is the fifth class and is NOT a status — it comes from the class partition.
        let excludedClasses = try PythonSource
            .load("substrate/substrate/classes.py").binding("EXCLUDED_CLASSES").members
        XCTAssertEqual(excludedClasses, ["conversation"])
        XCTAssertEqual(Set(RetrievalClass.allCases.map(\.rawValue)), statuses.union(["sources"]))
    }

    func testDocTypeVocabularyMatchesSpine() throws {
        let spine = try PythonSource.load("substrate/substrate/spine.py")
        XCTAssertEqual(try spine.binding("DOC_TYPES").members,
                       Set(PassageDocType.allCases.map(\.rawValue)))
    }

    /// `STORED_CONFIDENCES` is composed rather than written out, so the composition is pinned as
    /// well as the terms. Without the two `contains` checks a third term added to the union would
    /// widen the engine's vocabulary and this test would not notice.
    func testConfidenceVocabularyMatchesSpine() throws {
        let spine = try PythonSource.load("substrate/substrate/spine.py")
        let judged = try spine.binding("CONFIDENCES").members
        let unstated = try spine.stringConstant("UNSTATED_CONFIDENCE")
        let unjudged = try spine.stringConstant("UNJUDGED_CONFIDENCE")

        XCTAssertEqual(judged, Set(PassageConfidence.allCases.filter(\.isJudged).map(\.rawValue)))
        XCTAssertEqual(judged.union([unstated, unjudged]),
                       Set(PassageConfidence.allCases.map(\.rawValue)))

        XCTAssertTrue(spine.text.contains(
            "DECLARABLE_CONFIDENCES: frozenset[str] = CONFIDENCES | {UNSTATED_CONFIDENCE}"))
        XCTAssertTrue(spine.text.contains(
            "STORED_CONFIDENCES: frozenset[str] = DECLARABLE_CONFIDENCES | {UNJUDGED_CONFIDENCE}"))
    }

    func testDocumentClassVocabularyMatchesTheClassPolicies() throws {
        let classes = try PythonSource.load("substrate/substrate/classes.py")
        XCTAssertEqual(try classes.binding("POLICIES").keys(),
                       Set(PassageDocumentClass.allCases.map(\.rawValue)))
    }

    // MARK: - The two prose fields the mapping has to read

    /// `retrieval_mode.unavailable` is free prose, and `mappedArms` matches on each entry's LEADING
    /// TOKEN to promote an `off` arm to `.unavailable`. That is only sound while `stack.py` builds
    /// every entry with the arm's name first. All three sites are checked, and the floor is what
    /// catches a parse that quietly found none of them.
    func testEveryUnavailableEntryLeadsWithItsArmName() throws {
        let stack = try PythonSource.load("substrate/substrate/stack.py")
        var leads: [String] = []
        for line in stack.text.components(separatedBy: .newlines) {
            guard let range = line.range(of: "unavailable.append(f\"") else { continue }
            let lead = line[range.upperBound...].prefix { $0.isLetter }
            leads.append(String(lead))
        }
        XCTAssertEqual(leads.count, 3, "expected one append per arm; the prefix rule in "
                       + "WireRetrievalMode.mappedArms depends on finding all of them")
        XCTAssertEqual(Set(leads), ["embedder", "hyde", "reranker"])
    }

    /// The arm state words `mappedArms` translates. `fell_back` here becomes `EngineArmState`'s
    /// `"fell back"` — different strings, deliberately, since one is wire and one is display.
    func testArmStateVocabularyMatchesTheCapabilityDerivation() throws {
        let retriever = try PythonSource.load("substrate/substrate/retrieve/retriever.py")
        var words = Set<String>()
        for line in retriever.text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for arm in ["hyde", "reranker"] where trimmed.hasPrefix("\(arm) = \"") {
                let body = trimmed.dropFirst("\(arm) = \"".count)
                if let close = body.firstIndex(of: "\"") { words.insert(String(body[..<close])) }
            }
        }
        XCTAssertGreaterThanOrEqual(words.count, 3, "found \(words.count) arm state words in "
                                    + "_capability; the parse is not finding the assignments")
        XCTAssertEqual(words, ["ran", "off", "skipped", "fell_back"])
    }

    // MARK: - The tier numbers

    /// `EngineTier`'s ceiling, floor and case count are MEASUREMENTS whose only link to
    /// `EXPERIMENTS.md` was a comment. This is that link, made checkable: the numbers must still
    /// appear in the sections the comment names.
    func testEngineTierNumbersAreStillInExperiments() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        let url = root.appendingPathComponent("substrate/EXPERIMENTS.md")
        let text = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(text.contains("44-case cohort"),
                      "the cohort heading EngineTier.caseCount cites is gone from EXPERIMENTS.md")
        XCTAssertTrue(text.contains("\(EngineTier.ceiling)"),
                      "EngineTier.ceiling (\(EngineTier.ceiling)) no longer appears in "
                      + "EXPERIMENTS.md — the client is claiming a tier nothing measured")
        XCTAssertTrue(text.contains("nothing installed. \(EngineTier.floor)"),
                      "EngineTier.floor (\(EngineTier.floor)) is no longer the number in the "
                      + "THE FLOOR heading")
        XCTAssertTrue(text.contains("Measured at \(EngineTier.caseCount) cases"))
    }

    // MARK: - The parser itself

    /// FLOORS, for the same reason `ThemeTokenSource` asserts them: this couples to the shape of
    /// the Python, and a reformat that stops the parser recognising a dict would otherwise turn
    /// every assertion above into a confusing individual diff instead of one loud failure.
    func testTheContractParserFoundEverythingItShould() throws {
        let sources: [(String, [String])] = [
            ("substrate/substrate/render.py",
             ["passage", "outline_record", "retrieval_mode", "applied_filters", "search_payload"]),
            ("substrate/substrate/introspect.py", ["arms", "vector_status", "status_payload",
                                                   "scopes_payload"]),
            ("substrate/substrate/refresh_state.py", ["_block"]),
            ("substrate/substrate/freshness.py", ["drift"]),
            ("substrate/substrate/mcp/server.py", ["_tool_expand", "_note_text"]),
        ]
        var builders = 0
        var keys = 0
        for (path, functions) in sources {
            let source = try PythonSource.load(path)
            for function in functions {
                let payload = try source.payload(of: function)
                let found = payload.dicts.reduce(0) { $0 + $1.count }
                    + payload.assigned.values.reduce(0) { $0 + $1.count }
                XCTAssertGreaterThan(found, 0, "\(path):\(function) parsed to no keys at all")
                builders += 1
                keys += found
            }
        }
        XCTAssertEqual(builders, 13)
        XCTAssertGreaterThanOrEqual(keys, 80, "only \(keys) payload keys parsed out of the engine; "
                                    + "the parser has stopped recognising a declaration shape")
    }

    /// The parser has to be able to SEE a change, or the gate above is decoration.
    func testTheContractParserDetectsAnAddedKey() {
        let mutated = """
            def payload(a, b) -> dict:
                \"\"\"A docstring with a { brace and a "quoted key": that is not one.\"\"\"
                # A comment with "another": decoy
                out = {
                    "scope": scope,       # trailing comment
                    "nested": {"inner": 1},
                    "note": f"an f-string with {a} braces",
                }
                out["added_later"] = b
                return out
            """
        let source = PythonSource(path: "<memory>", text: mutated)
        let payload = try? source.payload(of: "payload")
        XCTAssertEqual(payload?.keys(plus: "out"), ["scope", "nested", "note", "added_later"],
                       "the parser must see a bolted-on key, ignore nested keys, and not be fooled "
                       + "by comments, docstrings or f-string braces")
    }
}
