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
            "expand_ref", "citation", "path", "page", "n_chars", "document_class",
            "status", "doc_type", "confidence", "domains", "vault", "supersedes",
            "snippet", "text", "truncated",
        ])
    }

    /// `outline_record` is a `passage` plus one discriminator. Checked separately so a second key
    /// bolted onto an orientation record cannot hide behind the passage's own set.
    func testOutlineRecordAddsOnlyKind() throws {
        XCTAssertEqual(try render().payload(of: "outline_record").assigned["rec"] ?? [], ["kind"])
    }

    /// THE ONE PRESENCE THIS CLIENT DEPENDS ON, and the inverse of the test that stood here.
    ///
    /// `render.passage` did not emit `document_class`, so `WirePassage.mapped(documentClass:)` made
    /// the CALLER state the axis — and every caller stated `reference-frozen`, which is the value
    /// that reads as settled. The old test fired when the key arrived. This one fires if it ever
    /// leaves again, because its departure would silently restore that default: `decodeIfPresent`
    /// reads an absent key and a null one alike, so every passage would map to `.unreported` and
    /// nothing else would break.
    ///
    /// It pins the VALUES as well as the key. A class this build has no case for refuses by name in
    /// `mappedDocumentClass`, so the vocabularies must agree — and they are checked against
    /// `classes.POLICIES` rather than against a list written here, one file over in
    /// `testDocumentClassVocabularyMatchesTheClassPolicies`.
    func testPassageCarriesDocumentClassAndItsValuesAreTheClassPolicies() throws {
        let keys = try render().payload(of: "passage").keys(plus: "out")
        XCTAssertTrue(keys.contains("document_class"),
                      "`render.passage` has stopped emitting document_class. Every passage now maps "
                      + "to `.unreported` and no other test fails — the axis would be silently gone "
                      + "from the spine, which is the state this client was written to end.")

        // The three tokens the key can carry. `null` is the fourth thing it can be, and it is a
        // VALUE — `PassageDocumentClass.unreported` — not one of these.
        let classes = try PythonSource.load("substrate/substrate/classes.py")
        XCTAssertEqual(try classes.binding("POLICIES").keys(),
                       Set(PassageDocumentClass.wireTokens))
        XCTAssertNil(PassageDocumentClass.named("unreported"),
                     "`unreported` must not be reachable from a wire token — it is the ABSENCE of a "
                     + "class, and a token that produced it would let the engine assert one")

        // And the engine really does send `null` rather than a class name for an absent one.
        XCTAssertTrue(try render().text.contains("\"document_class\": h.document_class or None"),
                      "`render.passage` no longer emits `or None` for an absent class. If it now "
                      + "defaults one, the client's `.unreported` case is unreachable and a "
                      + "class-less row is being relabelled at the boundary instead.")
    }

    func testRetrievalModeKeysMatchTheDecoder() throws {
        XCTAssertEqual(try render().payload(of: "retrieval_mode").keys(), [
            "embedder", "embedder_state", "hyde", "reranker", "expected_mrr", "unmeasured_reason",
            "cohort", "degraded", "fallbacks", "unavailable", "health",
        ])
    }

    /// `unmeasured_reason` is a CLOSED vocabulary the mapping switches on, so a token added to the
    /// engine and not to `UnmeasuredReason` must fail here rather than at a user's screen — where it
    /// would arrive as a refusal on an otherwise healthy query.
    func testUnmeasuredReasonVocabularyMatchesTheRetriever() throws {
        let retriever = try PythonSource.load("substrate/substrate/retrieve/retriever.py")
        XCTAssertEqual(try retriever.binding("UNMEASURED_REASONS").keys(),
                       Set(UnmeasuredReason.allCases.map(\.rawValue)))
    }

    /// `retrieval_mode.health` — the block that retired the client's parse of `unavailable`'s prose.
    /// Its four keys and the arm vocabulary its `arms` map speaks are both pinned: the mapping
    /// compares one value out of that map by name, and a rename there would silently stop promoting
    /// a dead arm to `.unavailable`.
    func testEngineHealthKeysAndArmVocabularyMatchTheDecoder() throws {
        let source = try render()
        XCTAssertEqual(try source.payload(of: "engine_health").keys(),
                       ["known", "state", "arms", "note"])
        XCTAssertEqual(try source.payload(of: "engine_health").keys(dict: 1),
                       ["known", "state", "arms", "note"],
                       "both branches of `engine_health` must emit the same key set; a branch that "
                       + "drops one makes its absence mean either `false` or `this build predates "
                       + "the field`")

        let stack = try PythonSource.load("substrate/substrate/stack.py")
        XCTAssertEqual(try stack.stringConstant("ARM_UNAVAILABLE"),
                       WireEngineHealth.armUnavailable)
        XCTAssertEqual(try stack.stringConstant("ARM_WIRED"), "wired")
        XCTAssertEqual(try stack.stringConstant("ARM_OFF"), "off")

        // The three states `WireEngineHealth.mapped()` switches on, read out of the branch that
        // assigns them. A fourth would refuse at the mapping, by name, on a live query.
        var states = Set<String>()
        for line in source.text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            guard trimmed.hasPrefix("state ") || trimmed.hasPrefix("state,") else { continue }
            for piece in trimmed.components(separatedBy: "\"") where
                ["ready", "lexical_only", "unreachable"].contains(piece) {
                states.insert(piece)
            }
        }
        XCTAssertEqual(states, ["ready", "lexical_only", "unreachable"],
                       "found \(states.sorted()); `engine_health` no longer assigns the three "
                       + "states `WireEngineHealth.mapped()` knows")
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

    /// The three tokens, plus the assertion that keeps the fourth case honest.
    ///
    /// `PassageDocumentClass` has a case `classes.POLICIES` does not: `unreported`, for the `null`
    /// the engine sends when the index row carries no class. It is compared through `wireToken` and
    /// not `allCases` for that reason — and the count check is what stops a second token-less case
    /// being added, which would widen the enum past the vocabulary without failing anything.
    func testDocumentClassVocabularyMatchesTheClassPolicies() throws {
        let classes = try PythonSource.load("substrate/substrate/classes.py")
        XCTAssertEqual(try classes.binding("POLICIES").keys(),
                       Set(PassageDocumentClass.wireTokens))
        XCTAssertEqual(PassageDocumentClass.allCases.filter { $0.wireToken == nil },
                       [.unreported],
                       "exactly one case may be token-less: the one that means the engine sent none")
        XCTAssertEqual(PassageDocumentClass.unreported.label, "unreported",
                       "the absent class must still draw a WORD — an empty badge is "
                       + "indistinguishable from an axis nobody rendered")
    }

    // MARK: - The two prose fields the mapping has to read

    /// `retrieval_mode.unavailable` is free prose, and the arm names in `health.arms` are recovered
    /// from each entry's LEADING TOKEN — by the ENGINE now, in `Stack.unavailable_arms`, which is
    /// where the parse belongs. THE SWIFT SIDE NO LONGER READS THOSE SENTENCES; it reads the map.
    /// The rule still has to hold for the map to be right, and it is now enforceable in one place:
    /// every entry goes through `_unreachable`, whose f-string puts the arm first.
    func testEveryUnavailableEntryIsBuiltByTheOneSpellingThatLeadsWithItsArm() throws {
        let stack = try PythonSource.load("substrate/substrate/stack.py")
        XCTAssertTrue(stack.text.contains("return f\"{arm} {model!r} unreachable at {where}\""),
                      "`_unreachable` no longer leads with the arm name, so `Stack.unavailable_arms`"
                      + " cannot recover it and `health.arms` will read healthy over a dead arm")

        var arms: [String] = []
        for line in stack.text.components(separatedBy: .newlines) {
            guard let range = line.range(of: "unavailable.append(_unreachable(\"") else { continue }
            arms.append(String(line[range.upperBound...].prefix { $0.isLetter }))
        }
        XCTAssertEqual(arms.count, 3, "expected one append per arm, all through `_unreachable`; a "
                       + "hand-built entry would not be covered by the spelling asserted above")
        XCTAssertEqual(Set(arms), ["embedder", "hyde", "reranker"])
    }

    /// The arm state words `mappedArms` translates — now for all THREE arms, since `embedder_state`
    /// gave the embedder the vocabulary it lacked. `fell_back` here becomes `EngineArmState.fellBack`
    /// whose `label` is `"fell back"`: different strings, deliberately, since one is wire and one is
    /// display, and they are separate properties so neither can stand in for the other.
    func testArmStateVocabularyMatchesTheCapabilityDerivation() throws {
        let retriever = try PythonSource.load("substrate/substrate/retrieve/retriever.py")
        var words = Set<String>()
        for line in retriever.text.components(separatedBy: .newlines) {
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            for arm in ["hyde", "reranker", "embedder_state"]
            where trimmed.hasPrefix("\(arm) = \"") {
                let body = trimmed.dropFirst("\(arm) = \"".count)
                if let close = body.firstIndex(of: "\"") { words.insert(String(body[..<close])) }
            }
        }
        XCTAssertGreaterThanOrEqual(words.count, 3, "found \(words.count) arm state words in "
                                    + "_capability; the parse is not finding the assignments")
        XCTAssertEqual(words, ["ran", "off", "skipped", "fell_back"])
        XCTAssertEqual(Set(EngineArmState.wireTokens), words,
                       "`EngineArmState.byWireToken` is the only door from the wire; a word the "
                       + "engine can assign and it has no entry for refuses a healthy query")

        // `unavailable` is the one state with no wire token, and that is what makes the promotion
        // in `armState` the only way to reach it.
        XCTAssertNil(EngineArmState.unavailable.wireToken)
        XCTAssertEqual(EngineArmState.fellBack.label, "fell back")
        XCTAssertEqual(EngineArmState.fellBack.wireToken, "fell_back")
        XCTAssertNil(EngineArmState.byWireToken["fell back"],
                     "the display string must never decode; that confusion is what returned nil "
                     + "for every fallen-back arm while the two were one rawValue")
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
             ["passage", "outline_record", "retrieval_mode", "engine_health", "applied_filters",
              "search_payload"]),
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
        XCTAssertEqual(builders, 14)
        XCTAssertGreaterThanOrEqual(keys, 90, "only \(keys) payload keys parsed out of the engine; "
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
