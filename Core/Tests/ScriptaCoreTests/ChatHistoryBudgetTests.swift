import XCTest
@testable import ScriptaShared

/// Ask now sends whole retrieved notes with every turn, and `EndpointChat` retains each one, so the
/// thing that fails when this stops holding has to exist — a budget nothing enforces is a comment.
final class ChatHistoryBudgetTests: XCTestCase {

    private func message(_ role: String, _ content: String) -> [String: String] {
        ["role": role, "content": content]
    }

    private func chars(_ n: Int) -> String { String(repeating: "x", count: n) }

    func testShortHistoryIsUntouched() {
        var messages = [message("system", "grounding"),
                        message("user", "a question")]
        XCTAssertEqual(ChatHistoryBudget.trim(&messages, budget: 10), 0,
                       "with only a system message and the turn being sent there is nothing to drop")
        XCTAssertEqual(messages.count, 2)
    }

    func testOldestTurnsAreDroppedUntilItFits() {
        var messages = [message("system", chars(10))]
        for _ in 0..<6 { messages.append(message("user", chars(100))) }
        let dropped = ChatHistoryBudget.trim(&messages, budget: 250)
        XCTAssertGreaterThan(dropped, 0)
        let total = messages.reduce(0) { $0 + ($1["content"] ?? "").count }
        XCTAssertLessThanOrEqual(total, 250)
    }

    /// The grounding contract and the question being asked both survive any budget. A trim that can
    /// evict either produces a request that cannot be answered — and losing the system message
    /// specifically loses the instruction not to invent, which is the one message whose absence
    /// would not look like an absence.
    func testSystemMessageAndCurrentTurnSurviveAnImpossibleBudget() {
        var messages = [message("system", chars(5_000))]
        for i in 0..<4 { messages.append(message("user", chars(5_000) + "\(i)")) }
        let last = messages[messages.count - 1]
        ChatHistoryBudget.trim(&messages, budget: 1)
        XCTAssertEqual(messages.count, 2, "only the system message and the newest turn may remain")
        XCTAssertEqual(messages[0]["role"], "system")
        XCTAssertEqual(messages[0]["content"], chars(5_000))
        XCTAssertEqual(messages[1]["content"], last["content"], "the turn being sent must survive")
    }

    /// Dropping happens from the OLDEST end. Trimming the newest would throw away the context the
    /// current answer actually depends on.
    func testItDropsFromTheOldestEnd() {
        var messages = [message("system", "s"),
                        message("user", chars(100) + "OLDEST"),
                        message("assistant", chars(100) + "MIDDLE"),
                        message("user", chars(100) + "NEWEST")]
        ChatHistoryBudget.trim(&messages, budget: 220)
        let bodies = messages.compactMap { $0["content"] }
        XCTAssertFalse(bodies.contains { $0.hasSuffix("OLDEST") })
        XCTAssertTrue(bodies.contains { $0.hasSuffix("NEWEST") })
    }

    func testAGenerousBudgetDropsNothing() {
        var messages = [message("system", "s"),
                        message("user", "a"),
                        message("assistant", "b"),
                        message("user", "c")]
        XCTAssertEqual(ChatHistoryBudget.trim(&messages, budget: 1_000_000), 0)
        XCTAssertEqual(messages.count, 4)
    }
}
