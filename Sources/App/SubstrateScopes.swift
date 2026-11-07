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

    /// The serving engine's wiring, from the same call (`WireScopeList.retrievalArms`). Nil until an
    /// engine has answered, and from the moment an engine is (re)started or exits (`forgetArms`).
    /// A listing that fails leaves it alone: one failed call is not news about the arms.
    @Published private(set) var arms: WireRetrievalArms?

    /// What kind of server the engine is (`WireScopeList.server`): read-only, agent mode, and how
    /// often it refreshes its own scopes. Kept, and forgotten, exactly as `arms` is.
    @Published private(set) var server: WireServerInfo?

    /// Which engine the current `arms` may come from. Bumped by `forgetArms`, and checked before
    /// every write, so an answer still in flight from an engine that has since been replaced can
    /// never write its report back over the new one's.
    private var armsEpoch = 0

    /// Whether an answer to a call made at `epoch` may become `arms`. Only while THIS app's engine
    /// is serving: a call made just after a restart can still be answered by the engine that is
    /// leaving, and the epoch alone cannot tell, because the call began after `forgetArms`.
    private func accepts(_ epoch: Int) -> Bool {
        epoch == armsEpoch && SubstrateEngine.shared.lifecycle.isServing
    }

    /// The engine is being started, restarted or has exited, so what it reported no longer holds.
    func forgetArms() {
        armsEpoch += 1
        arms = nil
        server = nil
        // A new engine's first listing is its baseline, not a change.
        lastAttempted = [:]
        baselined = false
    }

    /// Each scope's `refresh.attempted` at the last listing, so a pass the ENGINE ran is noticed
    /// once (`notice`). Empty until the first listing after an engine starts: that one is the baseline.
    private var lastAttempted: [String: String] = [:]
    private var baselined = false

    /// What a poll found (`poll`).
    enum Poll {
        /// The engine answered with what it said.
        case answered(WireScopeList)
        /// Nothing is listening.
        case down
        /// Something answered that this app will not use: another release's wire, or a socket
        /// that is not provably this user's.
        case foreign
        /// No roster this time: a fault, a timeout, an undecodable reply. Says nothing about which
        /// engine is there, since a busy healthy one does this too.
        case unreadable
    }

    /// A listing that never leaves a refusal behind: the roster is replaced only by a roster. For the
    /// minute-by-minute watch (`EngineRefresh`), where one failed call must not turn a healthy
    /// engine's roster into a red card nobody asked for.
    func poll() async -> Poll {
        let epoch = armsEpoch
        switch await client.listScopes() {
        case .ok(let list):
            // Only for the engine it was asked of: a reply that outlived a restart is not news.
            guard epoch == armsEpoch else { return .unreadable }
            roster = .listed(list.scopes)
            if accepts(epoch) {
                arms = list.retrievalArms
                server = list.server
                notice(list.scopes)
            }
            return .answered(list)
        case .transportFailure(let failure):
            if failure.isCancellation { return .unreadable }
            switch failure {
            case .wireMismatch, .untrusted: return .foreign
            default: break
            }
            if case .engineDown = VaultRefusal.of(failure) { return .down }
            return .unreadable
        case .toolFault, .rpcError:
            return .unreadable
        }
    }

    /// Whether a scope's last refresh attempt moved since the last listing. Browse is told when one
    /// did: these are changes this app did not make (an Obsidian edit, a Claude session's note).
    /// Published so the Library's refresh rail can clear a stale failure once the engine has passed.
    @Published private(set) var lastMoved: Date?

    private func notice(_ rows: [WireScopeRow]) {
        var moved = false
        for row in rows {
            guard let now = row.refresh.attempted else { continue }
            if baselined && lastAttempted[row.scope] != now { moved = true }
            lastAttempted[row.scope] = now
        }
        baselined = true
        if moved {
            lastMoved = Date()
            VaultBrowseModel.shared.corpusChanged()
        }
    }

    /// Ask the engine for its wiring WITHOUT touching the roster: when an engine starts serving, and
    /// when Settings appears (the engine's background re-check can resolve Auto later). The roster
    /// has its own rule for when it is listed (`activate`), and a listing that races a restart must
    /// not leave a refusal behind for a healthy engine.
    func refreshArms() async {
        let epoch = armsEpoch
        if case .ok(let list) = await client.listScopes(), accepts(epoch) {
            arms = list.retrievalArms
            server = list.server
        }
    }

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
        let epoch = armsEpoch
        switch await client.listScopes() {
        case .ok(let list):
            roster = .listed(list.scopes)
            if accepts(epoch) {
                arms = list.retrievalArms
                server = list.server
                notice(list.scopes)
            }
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
