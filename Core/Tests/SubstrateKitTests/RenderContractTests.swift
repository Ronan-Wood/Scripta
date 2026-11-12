import XCTest
@testable import SubstrateKit

/// The drift check: does the Swift decoder still describe the payloads the engine builds?
///
/// THREE SOURCES ARE MADE TO AGREE, and needing all three is the point:
///   1. the engine's CONTRACT — the keys of every wire object, as the engine states them in
///      `contract.json` (`EngineContract`), which its own suite holds to its source
///   2. the engine's OUTPUT — the key set in the captured golden frames
///   3. the Swift DECODER — proven by `WireDecodingTests`' lossless round trip against (2)
/// A key added to a builder changes (1) and fails here once the copy is synced. A key present in the
/// source but never emitted at runtime fails (2). A key both send and Swift drops fails the round
/// trip. No single one of the three catches all of that.
final class RenderContractTests: XCTestCase {

    private var contract: EngineContract!

    override func setUpWithError() throws {
        contract = try EngineContract.load()
    }

    // MARK: - Payloads

    func testPassageKeysMatchTheDecoder() {
        XCTAssertEqual(contract.keys(of: "passage"), [
            "expand_ref", "citation", "path", "page", "n_chars", "document_class",
            "status", "doc_type", "confidence", "domains", "vault", "supersedes",
            "snippet", "text", "truncated", "provenance",
        ])
    }

    /// `provenance`'s keys, as `WireProvenance` decodes them.
    func testTheProvenanceKeysMatchTheDecoder() throws {
        XCTAssertEqual(contract.keys(of: "provenance"),
                       ["state", "client", "op", "at", "stamp", "stamped_by"])
    }

    /// `outline_record` is a `passage` plus one discriminator. Checked separately so a second key
    /// bolted onto an orientation record cannot hide behind the passage's own set.
    func testOutlineRecordAddsOnlyKind() {
        XCTAssertEqual(contract.ownKeys(of: "outline_record"), ["kind"])
        XCTAssertEqual(contract.extends["outline_record"], ["passage"])
    }

    /// THE ONE PRESENCE THIS CLIENT DEPENDS ON, and the inverse of the test that stood here.
    ///
    /// The engine did not emit `document_class`, so `WirePassage.mapped(documentClass:)` made the
    /// CALLER state the axis — and every caller stated `reference-frozen`, which is the value that
    /// reads as settled. The old test fired when the key arrived. This one fires if it ever leaves
    /// again, because its departure would silently restore that default: `decodeIfPresent` reads an
    /// absent key and a null one alike, so every passage would map to `.unreported` and nothing else
    /// would break.
    ///
    /// It pins the VALUES as well as the key. A class this build has no case for refuses by name in
    /// `mappedDocumentClass`, so the vocabularies must agree. That the engine sends `null` rather than
    /// a class name for an absent one is the engine's to keep, and its suite does
    /// (the engine's `tests/test_render.py`, the `document_class is None` case).
    func testPassageCarriesDocumentClassAndItsValuesAreTheClassPolicies() {
        XCTAssertTrue(contract.keys(of: "passage").contains("document_class"),
                      "the engine's passage has stopped carrying document_class. Every passage now "
                      + "maps to `.unreported` and no other test fails — the axis would be silently "
                      + "gone from the spine, which is the state this client was written to end.")

        // The three tokens the key can carry. `null` is the fourth thing it can be, and it is a
        // VALUE — `PassageDocumentClass.unreported` — not one of these.
        XCTAssertEqual(contract.classes.policies, Set(PassageDocumentClass.wireTokens))
        XCTAssertNil(PassageDocumentClass.named("unreported"),
                     "`unreported` must not be reachable from a wire token — it is the ABSENCE of a "
                     + "class, and a token that produced it would let the engine assert one")
    }

    func testRetrievalModeKeysMatchTheDecoder() {
        XCTAssertEqual(contract.keys(of: "retrieval_mode"), [
            "embedder", "embedder_state", "hyde", "reranker", "expected_mrr", "unmeasured_reason",
            "cohort", "degraded", "fallbacks", "unavailable", "health",
        ])
    }

    /// `unmeasured_reason` is a CLOSED vocabulary the mapping switches on, so a token added to the
    /// engine and not to `UnmeasuredReason` must fail here rather than at a user's screen — where it
    /// would arrive as a refusal on an otherwise healthy query.
    func testUnmeasuredReasonVocabularyMatchesTheRetriever() {
        XCTAssertEqual(contract.retrieval.unmeasuredReasons,
                       Set(UnmeasuredReason.allCases.map(\.rawValue)))
    }

    /// `retrieval_mode.health` — the block that retired the client's parse of `unavailable`'s prose.
    /// Its four keys and the arm vocabulary its `arms` map speaks are both pinned: the mapping
    /// compares one value out of that map by name, and a rename there would silently stop promoting
    /// a dead arm to `.unavailable`. (The engine refuses to export an `engine_health` whose branches
    /// emit different keys, so one set stands for both.)
    func testEngineHealthKeysAndArmVocabularyMatchTheDecoder() {
        XCTAssertEqual(contract.keys(of: "engine_health"), ["known", "state", "arms", "note"])
        XCTAssertEqual(contract.retrieval.armUnavailable, WireEngineHealth.armUnavailable)
        XCTAssertEqual(contract.retrieval.armWired, "wired")
        XCTAssertEqual(contract.retrieval.armOff, "off")

        // The three states `WireEngineHealth.mapped()` switches on. A fourth would refuse at the
        // mapping, by name, on a live query.
        XCTAssertEqual(contract.retrieval.engineHealthStates, ["ready", "lexical_only", "unreachable"],
                       "`engine_health` no longer assigns the three states "
                       + "`WireEngineHealth.mapped()` knows")
    }

    func testAppliedFiltersKeysMatchTheDecoder() {
        XCTAssertEqual(contract.keys(of: "applied_filters"), [
            "statuses_included", "statuses_excluded", "sources_excluded",
            "doc_type", "document_class", "vaults", "notes",
        ])
    }

    func testSearchPayloadKeysMatchTheDecoder() {
        XCTAssertEqual(contract.keys(of: "search"), [
            "scope", "db", "query", "passages", "outline_records",
            "retrieval_mode", "filters", "index_version", "refresh",
        ])
    }

    func testDocumentRecordKeysMatchTheDecoder() {
        XCTAssertEqual(contract.keys(of: "document"), [
            "doc_id", "title", "expand_ref", "passage_count", "vault", "tier",
            "document_class", "status", "doc_type", "confidence", "domains", "supersedes",
            "superseded_by",
        ])
        // `source_path` was here and is deliberately gone: one call returned every note's absolute
        // path, which is the operator's whole directory layout in bulk over a port any local
        // process can reach. Asserted as an ABSENCE so re-adding it has to be a decision.
        XCTAssertFalse(contract.keys(of: "document").contains("source_path"),
                       "`document_record` is emitting source_path again — a browse call now "
                       + "discloses every note's filesystem path in bulk, which `expand` already "
                       + "provides one note at a time for a note the caller actually named.")
    }

    /// The browse envelope is `search_payload` MINUS `retrieval_mode`, and the absence is asserted
    /// rather than left to the key list to imply. Nothing retrieved; an arms block here would report
    /// a stack that did not run, and a null `expected_mrr` beside a list invites the reading that
    /// the LIST is unmeasured rather than inapplicable.
    func testDocumentsPayloadIsSearchsEnvelopeWithoutTheArms() {
        let keys = contract.keys(of: "documents")
        XCTAssertEqual(keys, [
            "scope", "db", "documents", "returned", "total", "filters", "index_version", "refresh",
        ])
        XCTAssertFalse(keys.contains("retrieval_mode"))

        // `returned` AND `total`. Either alone makes a short page indistinguishable from a small
        // corpus, which is the browse surface's version of a silent exclusion.
        XCTAssertTrue(keys.contains("returned") && keys.contains("total"))
    }

    func testRefreshBlockKeysMatchTheDecoder() {
        XCTAssertEqual(contract.keys(of: "refresh"), [
            "known", "outcome", "attempted", "succeeded", "frozen", "frozen_since", "note",
        ])
    }

    /// `refresh_state.OUTCOMES` is the table that decides `frozen`, and `skipped` sitting under a
    /// null verdict rather than `False` is the whole tri-state. A new outcome this build has no
    /// interpretation for is handled by the engine (it reports the word and withholds a verdict),
    /// so this asserts the vocabulary is still the one the tests reason about.
    func testRefreshOutcomeVocabulary() {
        XCTAssertEqual(contract.refresh.outcomes, [
            "unchanged", "refreshed", "compose_failed", "embed_failed", "skipped",
            // Both added 2026-08-03, both reporting a refusal to ACT rather than a failure to, and
            // both `frozen` verdicts that are NOT `false` — which is why they belong in a test that
            // exists to notice the table moving.
            //
            // `schema_mismatch` (frozen: true): the index on disk was built by a different engine,
            // so it was refused rather than answered from. `engine_unverified` (frozen: null): the
            // refresh agent could not prove the engine it would run matches its deployment record,
            // so it composed nothing and checked nothing — a stopped maintenance job, not a damaged
            // scope, and unlike `skipped` it never clears itself.
            //
            // This test caught them, and it caught a real process failure with them: the Python
            // side of `schema_mismatch` shipped in b334da4 with only the PYTHON suite run. A
            // contract that spans two languages is not verified by running one of them.
            "engine_unverified", "schema_mismatch",
        ])
    }

    func testStatusPayloadKeysMatchTheDecoder() {
        XCTAssertEqual(contract.keys(of: "status"), [
            "scope", "db", "vault", "composed", "index_version",
            "documents", "passages", "outlines", "schema_version",
            "by_vault", "by_tier", "by_status", "by_doc_type", "by_confidence",
            "entities", "retrieval_arms", "vectors", "refresh", "exposed", "drift",
        ])
        XCTAssertEqual(contract.keys(of: "arms"),
                       ["embedder", "hyde", "hyde_requested", "reranker", "unavailable"])
        XCTAssertEqual(contract.keys(of: "vector"),
                       ["model", "stored", "chunks", "complete", "note"])
    }

    func testScopeListKeysMatchTheDecoder() {
        XCTAssertEqual(contract.keys(of: "scope_row"), [
            "scope", "db", "vault", "composed", "index_present", "pending", "refresh", "sources",
            "error",
        ])
        XCTAssertEqual(contract.keys(of: "scope_list"), ["scopes", "registry"])
    }

    /// The `list_scopes` TOOL adds the serving process's arms and what kind of server it is around
    /// the roster, and `WireScopeList` decodes both. They are the facts a client uses to decide
    /// whether to attach to an engine it did not start, so a rename here is an attach that silently
    /// stops seeing them.
    func testTheListScopesReplyCarriesTheServerFactsTheDecoderReads() {
        XCTAssertEqual(contract.ownKeys(of: "scope_list_reply"), ["retrieval_arms", "server"])
        XCTAssertEqual(Set(contract.extends["scope_list_reply"] ?? []),
                       ["scope_list", "agent_scope_list"])
        XCTAssertEqual(contract.keys(of: "server"), ["read_only", "agent_mode", "refresh_every",
                                                     "refresh_requests", "writes", "writes_log",
                                                     "notes_version", "notes_min_version"])
        XCTAssertEqual(contract.keys(of: "refresh_request"),
                       ["next_pass", "wait_seconds"])
    }

    func testDriftKeysMatchTheDecoder() {
        XCTAssertEqual(contract.keys(of: "drift"), [
            "stale", "checkable", "added", "removed", "changed",
            "checked", "unverifiable", "unreadable",
        ])
    }

    func testExpandKeysMatchTheDecoder() {
        XCTAssertEqual(contract.keys(of: "expand"),
                       ["scope", "mode", "index_version", "passage", "note"])
        XCTAssertEqual(contract.keys(of: "expand_note"),
                       ["path", "text", "n_chars", "truncated", "stale"])
    }

    // MARK: - The vocabulary the mapping refuses on

    /// `PassageStatus` and `RetrievalClass` against `spine.STATUSES`, and the default partition
    /// against `spine.INCLUDED_STATUSES`. `RetrievalClass.isDefault` is what `ExclusionFilter`
    /// computes the whole disclosure from, so a status moving across that partition in the engine
    /// silently inverts the sentence the reader is shown.
    func testStatusVocabularyMatchesSpine() {
        let statuses = contract.spine.statuses
        XCTAssertEqual(statuses, Set(PassageStatus.allCases.map(\.rawValue)))
        XCTAssertEqual(contract.spine.includedStatuses,
                       Set(RetrievalClass.allCases.filter(\.isDefault).map(\.rawValue)))

        // `sources` is the fifth class and is NOT a status — it comes from the class partition.
        XCTAssertEqual(contract.classes.excluded, ["conversation"])
        XCTAssertEqual(Set(RetrievalClass.allCases.map(\.rawValue)), statuses.union(["sources"]))
    }

    func testDocTypeVocabularyMatchesSpine() {
        XCTAssertEqual(contract.spine.docTypes, Set(PassageDocType.allCases.map(\.rawValue)))
    }

    /// `STORED_CONFIDENCES` is composed rather than written out, and the engine exports the
    /// composition as evaluated, so the composed sets are pinned as well as the terms. Without them
    /// a third term added to the union would widen the engine's vocabulary and this test would not
    /// notice.
    func testConfidenceVocabularyMatchesSpine() {
        let judged = contract.spine.confidences
        let unstated = contract.spine.unstatedConfidence
        let unjudged = contract.spine.unjudgedConfidence

        XCTAssertEqual(judged, Set(PassageConfidence.allCases.filter(\.isJudged).map(\.rawValue)))
        XCTAssertEqual(judged.union([unstated, unjudged]),
                       Set(PassageConfidence.allCases.map(\.rawValue)))
        XCTAssertEqual(contract.spine.declarableConfidences, judged.union([unstated]))
        XCTAssertEqual(contract.spine.storedConfidences, judged.union([unstated, unjudged]))
    }

    /// The three tokens, plus the assertion that keeps the fourth case honest.
    ///
    /// `PassageDocumentClass` has a case `classes.POLICIES` does not: `unreported`, for the `null`
    /// the engine sends when the index row carries no class. It is compared through `wireToken` and
    /// not `allCases` for that reason — and the count check is what stops a second token-less case
    /// being added, which would widen the enum past the vocabulary without failing anything.
    func testDocumentClassVocabularyMatchesTheClassPolicies() {
        XCTAssertEqual(contract.classes.policies, Set(PassageDocumentClass.wireTokens))
        XCTAssertEqual(PassageDocumentClass.allCases.filter { $0.wireToken == nil },
                       [.unreported],
                       "exactly one case may be token-less: the one that means the engine sent none")
        XCTAssertEqual(PassageDocumentClass.unreported.label, "unreported",
                       "the absent class must still draw a WORD — an empty badge is "
                       + "indistinguishable from an axis nobody rendered")
    }

    // MARK: - The arm vocabulary

    /// `retrieval_mode.unavailable` is free prose, and the arm names in `health.arms` are recovered
    /// from each entry's LEADING TOKEN by the engine (`Stack.unavailable_arms`). This client reads
    /// the map, never the sentences; that every entry leads with its arm is the engine's to keep,
    /// and its suite does (the engine's `tests/test_unavailable_arms.py`). Pinned here: the arm names
    /// that map is keyed by.
    func testTheArmNamesAreTheEngines() {
        XCTAssertEqual(contract.retrieval.arms, ["embedder", "hyde", "reranker"])
    }

    /// The arm state words `mappedArms` translates — now for all THREE arms, since `embedder_state`
    /// gave the embedder the vocabulary it lacked. `fell_back` here becomes `EngineArmState.fellBack`
    /// whose `label` is `"fell back"`: different strings, deliberately, since one is wire and one is
    /// display, and they are separate properties so neither can stand in for the other.
    func testArmStateVocabularyMatchesTheCapabilityDerivation() {
        let words = contract.retrieval.armStates
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

    /// `EngineTier`'s ceiling, floor and case count are MEASUREMENTS, and the engine states them
    /// (from the sections of its `EXPERIMENTS.md` that hold them). The client may not claim a tier
    /// nothing measured.
    func testEngineTierNumbersAreTheEnginesMeasurements() {
        XCTAssertEqual(contract.tiers.ceiling, EngineTier.ceiling,
                       "EngineTier.ceiling is not the engine's measured ceiling")
        XCTAssertEqual(contract.tiers.floor, EngineTier.floor,
                       "EngineTier.floor is not the engine's measured floor")
        XCTAssertEqual(contract.tiers.caseCount, EngineTier.caseCount)
    }

    // MARK: - The contract itself

    /// The objects this client decodes, in one place: a contract that lost several would otherwise
    /// read as many unrelated failures above instead of one list here.
    func testTheContractHoldsEveryObjectThisClientDecodes() {
        let decoded = ["passage", "outline_record", "retrieval_mode", "engine_health",
                       "applied_filters", "search", "document", "documents", "refresh", "status",
                       "arms", "vector", "scope_row", "scope_list", "scope_list_reply", "server",
                       "drift", "expand", "expand_note"]
        for object in decoded {
            XCTAssertFalse(contract.ownKeys(of: object).isEmpty, "\(object) has no keys")
        }
    }
}
