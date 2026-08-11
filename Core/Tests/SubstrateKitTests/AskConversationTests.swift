import XCTest
@testable import SubstrateKit

/// The spine has to survive a relaunch, and the file that carries it says so — so this is the thing
/// that fails when it stops being true (PRINCIPLES' fourth law: a claim with nothing behind it is
/// worse than silence).
///
/// EXHAUSTIVE OVER EACH AXIS, not a sample. A projection that drops one value is green on a fixture
/// that never uses it, and `unreported` in particular is reachable only from a row that never went
/// through the class gate — precisely the value a hand-picked fixture forgets.
final class AskConversationTests: XCTestCase {

    private func passage(_ klass: PassageDocumentClass,
                         status: PassageStatus = .active,
                         docType: PassageDocType = .decision,
                         confidence: PassageConfidence = .stated) -> Passage {
        Passage(id: "scope/doc#c00001", snippet: "a snippet", citation: "Doc · Heading · @vault",
                vault: "vault", status: status, docType: docType, confidence: confidence,
                documentClass: klass, domains: ["one", "two"], supersedes: ["old-note"])
    }

    // MARK: - The projection is total and invertible

    func testEveryDocumentClassRoundTrips() throws {
        for klass in PassageDocumentClass.allCases {
            let restored = StoredPassage(passage(klass)).passage
            XCTAssertEqual(restored?.documentClass, klass,
                           "document_class \(klass.label) did not survive the projection")
        }
    }

    func testEveryStatusDocTypeAndConfidenceRoundTrip() throws {
        for status in PassageStatus.allCases {
            let restored = StoredPassage(passage(.conversation, status: status)).passage
            XCTAssertEqual(restored?.status, status)
        }
        for docType in PassageDocType.allCases {
            let restored = StoredPassage(passage(.conversation, docType: docType)).passage
            XCTAssertEqual(restored?.docType, docType)
        }
        for confidence in PassageConfidence.allCases {
            let restored = StoredPassage(passage(.conversation, confidence: confidence)).passage
            XCTAssertEqual(restored?.confidence, confidence)
        }
    }

    /// Through JSON, not just through the two initialisers — the disk is the boundary that matters,
    /// and `documentClass` is written as an ABSENT KEY for `unreported`, which only an encode/decode
    /// pass exercises.
    func testSpineSurvivesJSON() throws {
        for klass in PassageDocumentClass.allCases {
            let original = passage(klass)
            let data = try JSONEncoder().encode(StoredPassage(original))
            let restored = try JSONDecoder().decode(StoredPassage.self, from: data).passage
            XCTAssertEqual(restored?.documentClass, klass)
            XCTAssertEqual(restored?.status, original.status)
            XCTAssertEqual(restored?.docType, original.docType)
            XCTAssertEqual(restored?.confidence, original.confidence)
            XCTAssertEqual(restored?.vault, original.vault)
            XCTAssertEqual(restored?.domains, original.domains)
            XCTAssertEqual(restored?.supersedes, original.supersedes)
            XCTAssertEqual(restored?.id, original.id)
        }
    }

    /// `unreported` has no wire token, so it must persist as an absent key rather than as a word a
    /// later reader could mistake for an engine verdict.
    func testUnreportedPersistsAsAbsence() throws {
        let data = try JSONEncoder().encode(StoredPassage(passage(.unreported)))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertNil(object["documentClass"],
                     "unreported must not be written as a token — that invents a class the engine never sent")
        XCTAssertEqual(StoredPassage.documentClass(from: nil), .unreported)
    }

    /// A token this build cannot read is refused, not defaulted. Defaulting is how six conversations
    /// were silently relabelled `reference-frozen` (PRINCIPLES, third law).
    func testUnknownClassTokenRefusesRatherThanDefaults() {
        let stored = StoredPassage(id: "s/d#c1", snippet: "", citation: "", vault: "v",
                                   status: "active", docType: "decision", confidence: "stated",
                                   documentClass: "a-class-from-a-newer-engine",
                                   domains: [], supersedes: [])
        XCTAssertNil(stored.passage, "an unreadable class token must withhold the citation, not relabel it")
    }

    // MARK: - History written by the pre-merge model still loads

    /// The store is one array read with `try?`. A single missing key used to throw, and the `?? []`
    /// behind it turns that into "you have never had a conversation" — indistinguishable from a
    /// first launch. This is the fixture in the OLD shape, verbatim in spirit: `group`, `sources`,
    /// `grounding`, and no `passages`.
    func testPreMergeConversationsStillDecode() throws {
        let legacy = """
        [{
          "id": "3F2504E0-4F89-11D3-9A0C-0305E82C3301",
          "title": "What did we decide about pricing",
          "created": 760000000,
          "group": "CBRE",
          "messages": [
            {"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3302", "fromUser": true, "text": "what did we decide"},
            {"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3303", "fromUser": false, "text": "You agreed to revisit it.",
             "sources": [{"id": "3F2504E0-4F89-11D3-9A0C-0305E82C3304", "title": "Pricing call",
                          "url": "file:///tmp/a.md", "startMs": 1200}],
             "grounding": "strong", "engineLabel": "Apple Intelligence"}
          ]
        }]
        """.data(using: .utf8)!

        let conversations = try JSONDecoder().decode([AskConversation].self, from: legacy)
        XCTAssertEqual(conversations.count, 1)
        let conversation = try XCTUnwrap(conversations.first)
        XCTAssertEqual(conversation.workspace, "CBRE", "the old `group` key must still name the workspace")
        XCTAssertEqual(conversation.title, "What did we decide about pricing")
        XCTAssertEqual(conversation.messages.count, 2)
        XCTAssertEqual(conversation.messages[1].text, "You agreed to revisit it.")
        XCTAssertEqual(conversation.messages[1].engineLabel, "Apple Intelligence")
    }

    /// An old answer that HAD citations says so, rather than rendering as one that cited nothing.
    func testPreMergeAnswerWithSourcesIsMarkedRatherThanSilentlyEmptied() throws {
        let answer = """
        {"fromUser": false, "text": "an answer",
         "sources": [{"title": "Pricing call"}]}
        """.data(using: .utf8)!
        let message = try JSONDecoder().decode(AskMessage.self, from: answer)
        XCTAssertTrue(message.passages.isEmpty)
        XCTAssertTrue(message.citationsNotCarried,
                      "an answer whose citations cannot be expressed must not look like one that had none")
    }

    /// And an old answer that genuinely cited nothing is NOT marked — otherwise the flag says
    /// "something was lost" on every turn and stops meaning anything.
    func testPreMergeAnswerWithoutSourcesIsNotMarked() throws {
        let answer = #"{"fromUser": false, "text": "I could not find anything about that."}"#
            .data(using: .utf8)!
        let message = try JSONDecoder().decode(AskMessage.self, from: answer)
        XCTAssertFalse(message.citationsNotCarried)
    }

    // MARK: - The workspace wipe reaches chat history

    private func thread(_ workspace: String, _ title: String) -> AskConversation {
        AskConversation(title: title, workspace: workspace,
                        messages: [AskMessage(fromUser: true, text: "q")])
    }

    func testForgettingAWorkspaceTakesItsThreadsAndNothingElse() {
        var conversations = [thread("CBRE", "a"), thread("Family", "b"), thread("CBRE", "c")]
        XCTAssertEqual(ConversationPurge.forget("CBRE", from: &conversations), 2)
        XCTAssertEqual(conversations.map(\.workspace), ["Family"])
    }

    /// `""` IS UNGROUPED, NOT A WILDCARD. It is the registry's global sentinel and `WorkspaceDeleter`
    /// gates the registry purge on `!group.isEmpty` for exactly that reason — if that gate's logic
    /// ever leaked into this rule, wiping Ungrouped would wipe every conversation in the app.
    func testWipingUngroupedTakesOnlyUngrouped() {
        var conversations = [thread("", "ungrouped"), thread("CBRE", "cbre"), thread("", "also")]
        XCTAssertEqual(ConversationPurge.forget("", from: &conversations), 2)
        XCTAssertEqual(conversations.map(\.title), ["cbre"])
    }

    /// And a named wipe must not take Ungrouped with it.
    func testANamedWipeLeavesUngroupedAlone() {
        var conversations = [thread("", "ungrouped"), thread("CBRE", "cbre")]
        XCTAssertEqual(ConversationPurge.forget("CBRE", from: &conversations), 1)
        XCTAssertEqual(conversations.map(\.title), ["ungrouped"])
    }

    /// Exact match, so a workspace whose name merely contains another's is untouched. "CB" must not
    /// take "CBRE" — the failure a `hasPrefix` or `contains` would introduce silently.
    func testMatchingIsExactNotPrefix() {
        var conversations = [thread("CB", "short"), thread("CBRE", "long")]
        XCTAssertEqual(ConversationPurge.forget("CB", from: &conversations), 1)
        XCTAssertEqual(conversations.map(\.title), ["long"])
    }

    func testForgettingAWorkspaceWithNoThreadsChangesNothing() {
        var conversations = [thread("CBRE", "a")]
        XCTAssertEqual(ConversationPurge.forget("Family", from: &conversations), 0)
        XCTAssertEqual(conversations.count, 1)
    }

    // MARK: - Stop leaves a turn that cannot be mistaken for a finished one

    private static let marker = "\n\n_(Stopped.)_"

    /// Text that arrived is KEPT and marked. Without the marker, `thinking` and `running` are both
    /// cleared by Stop, so nothing on screen distinguishes a truncated answer from a complete one —
    /// and the next `syncCurrent` writes it to disk that way.
    func testStopMarksAPartialAnswerRatherThanLeavingItLookingFinished() {
        var messages = [AskMessage(fromUser: true, text: "what did we decide"),
                        AskMessage(fromUser: false, text: "You agreed to")]
        let outcome = InterruptedTurn.close(&messages, marker: Self.marker)
        XCTAssertEqual(outcome, .marked(messages[1].id))
        XCTAssertEqual(messages.count, 2)
        XCTAssertEqual(messages[1].text, "You agreed to" + Self.marker)
    }

    /// An empty placeholder is REMOVED. A blank bubble is not a partial answer — it is a claim that
    /// the model replied with nothing.
    func testStopRemovesAnAnswerNoTokenEverReached() {
        let placeholder = AskMessage(fromUser: false, text: "")
        var messages = [AskMessage(fromUser: true, text: "what did we decide"), placeholder]
        let outcome = InterruptedTurn.close(&messages, marker: Self.marker)
        XCTAssertEqual(outcome, .removed(placeholder.id))
        XCTAssertEqual(messages.count, 1)
        XCTAssertTrue(messages[0].fromUser)
    }

    /// Stopped during RETRIEVAL, before any placeholder exists: the question stands on its own and
    /// must not be touched. Marking the trailing user turn would put the app's words in the
    /// reader's mouth.
    func testStopDuringRetrievalLeavesTheQuestionAlone() {
        var messages = [AskMessage(fromUser: true, text: "what did we decide")]
        let outcome = InterruptedTurn.close(&messages, marker: Self.marker)
        XCTAssertEqual(outcome, .nothingToClose)
        XCTAssertEqual(messages.count, 1)
        XCTAssertEqual(messages[0].text, "what did we decide")
    }

    func testStopOnAnEmptyThreadIsANoOp() {
        var messages: [AskMessage] = []
        XCTAssertEqual(InterruptedTurn.close(&messages, marker: Self.marker), .nothingToClose)
        XCTAssertTrue(messages.isEmpty)
    }

    /// The rename migrates on save: `workspace` is written, `group` never is.
    func testWorkspaceIsWrittenAndGroupIsNot() throws {
        let data = try JSONEncoder().encode(AskConversation(workspace: "CBRE"))
        let object = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        XCTAssertEqual(object["workspace"] as? String, "CBRE")
        XCTAssertNil(object["group"], "the retired word must not be written back out")
    }
}
