import Foundation
import SubstrateKit

/// The engine's scope roster, owned once.
///
/// EXTRACTED WHEN THE SECOND CONSUMER ARRIVED, and the reason is the comment inside `listScopes`
/// rather than tidiness. That method carries a hard-won rule — a cancelled `URLSession` call is not
/// a refusal, and a roster that records one as a refusal keeps the red card after the cause is gone,
/// because `activate()` only re-lists from `.unasked`. A second copy of the roster in the Library
/// would be a second place for that rule to be got wrong, and the two would drift the first time
/// only one of them was fixed.
///
/// It is also the honest shape: the roster is a fact about the ENGINE, not about Ask. Which scope a
/// surface has selected is that surface's own state and stays there.
@MainActor
final class SubstrateScopes: ObservableObject {
    static let shared = SubstrateScopes()

    /// The scope list, and its own failure modes — which are NOT any query's.
    ///
    /// Separate from an answer on purpose: the engine can be down before a question is ever asked,
    /// and that is the state a fresh machine is in. Merging the two would make "the engine is not
    /// running" reachable only by asking something first, which is the wrong order to learn it in.
    enum Roster {
        case unasked
        case listing
        /// The rows verbatim, faults included. `scopes_payload` lists a scope whose inheritance no
        /// longer resolves WITH its error rather than omitting it, because an omitted scope reads
        /// as one that was never composed — so this keeps every row it was handed.
        case listed([WireScopeRow])
        case refused(VaultRefusal)

        var isListed: Bool {
            if case .listed = self { return true }
            return false
        }
    }

    @Published private(set) var roster: Roster = .unasked

    /// The rows, or none. For a caller that wants to read the list without switching on the state
    /// it arrived in — never for one that has to DRAW the state, which must switch.
    var rows: [WireScopeRow] {
        if case .listed(let rows) = roster { return rows }
        return []
    }

    private let client = SubstrateClient()

    /// First appearance only. A refused roster stays refused until the reader retries, because
    /// re-listing on every appearance would turn "the engine is not running" into a flicker.
    func activate() async {
        guard case .unasked = roster else { return }
        await listScopes()
    }

    func listScopes() async {
        // A roster that is already on screen stays there while it refreshes. This call is reachable
        // from the bar's own scope segment, and dropping to `.listing` would blank the answer the
        // reader was looking at in order to re-fetch a list of seven names.
        if !roster.isListed { roster = .listing }
        switch await client.listScopes() {
        case .ok(let list):
            roster = .listed(list.scopes)
        case .toolFault(let text):
            roster = .refused(VaultRefusal.classify(fault: text))
        case .rpcError(let code, let message):
            roster = .refused(.rpcError(code: code, message: message))
        case .transportFailure(let failure):
            // CANCELLATION IS NOT A REFUSAL, and this is the one path where that mattered without
            // being guarded. This runs under SwiftUI's `.task`, which cancels itself when the view
            // goes away — tapping the Calls chip, or leaving the pane entirely. A cancelled
            // URLSession comes back as URLError -999, which no refusal case recognises, so it fell
            // to the transport arm and drew `Ink.danger`: "the engine answered, but not with a
            // JSON-RPC response", about an engine that is running perfectly.
            //
            // Worse than a wrong frame: `activate()` only re-lists from `.unasked`, and this object
            // outlives the view, so the red card SURVIVED coming back and sat there until someone
            // pressed Try again. Returning to `.unasked` rather than to a refusal is what makes the
            // next `activate()` retry instead of inheriting a verdict about an event that never
            // happened.
            if failure.isCancellation || Task.isCancelled {
                roster = .unasked
                return
            }
            roster = .refused(.of(failure))
        }
    }
}
