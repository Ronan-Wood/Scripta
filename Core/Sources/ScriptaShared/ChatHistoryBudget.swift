import Foundation

/// How much of a stateless endpoint's conversation to carry forward.
///
/// IN THE PACKAGE BECAUSE IT IS A RULE, NOT WIRING. Doc 4 §6: anything rebuilt lands where
/// `swift test` can reach it, and the two Phase 0 defects that survived longest did so because
/// `IndexBuilder` and `Retriever` sat in the app target where no test could see them. `EndpointChat`
/// keeps history app-side (the server is stateless per request), so this decides what a long thread
/// costs — and it went unbounded until Ask started sending whole retrieved notes with every turn.
public enum ChatHistoryBudget {

    /// Drop the oldest turns until the retained conversation fits `budget` characters of content.
    ///
    /// THE FIRST AND LAST MESSAGES ALWAYS SURVIVE. The first is the system message — the grounding
    /// contract, and losing it loses the instruction not to invent — and the last is the turn being
    /// sent, so a budget small enough to evict either would produce a request with nothing to
    /// answer. Everything between is dropped oldest-first: the same thing Apple's chat does on
    /// `exceededContextWindowSize` (it rebuilds the session outright), done gradually rather than
    /// all at once, and without depending on an error string a local server may not send.
    ///
    /// Returns how many messages were dropped, so a caller can say so if it ever wants to.
    @discardableResult
    public static func trim(_ messages: inout [[String: String]], budget: Int) -> Int {
        guard messages.count > 2 else { return 0 }
        func size(_ message: [String: String]) -> Int { (message["content"] ?? "").count }
        var total = messages.reduce(0) { $0 + size($1) }
        var oldest = 1
        while total > budget, oldest < messages.count - 1 {
            total -= size(messages[oldest])
            oldest += 1
        }
        guard oldest > 1 else { return 0 }
        messages.removeSubrange(1..<oldest)
        return oldest - 1
    }
}
