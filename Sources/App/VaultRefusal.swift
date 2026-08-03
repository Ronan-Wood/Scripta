import Foundation
import SubstrateKit

/// Why a vault query produced no answer — with "the engine is not running" as a first-class
/// member rather than an error.
///
/// Doc 3 §2: Scripta HOSTS the engine, so nothing-listening-on-the-port is what a user sees
/// before they start it, not a fault. It is the state a fresh machine is in. Folding it into a
/// generic failure is how that state becomes a spinner nobody can resolve.
///
/// SPLIT BY WHAT THE READER'S NEXT MOVE IS, which is the same rule `SubstrateTransportFailure`
/// splits on and the reason this is a second enum rather than a rename of that one: the transport
/// answers "did a JSON-RPC frame come back", and four of the seven cases below are 200s that came
/// back perfectly well and carry a condition inside them. The engine is explicit that a tool fault
/// is not a transport failure, so a type that merged them would throw away the distinction the
/// server goes out of its way to preserve.
enum VaultRefusal {
    /// Nothing is listening. NOT AN ERROR — see above.
    case engineDown(String)

    /// A JSON-RPC answer never arrived, for a reason that is not "the engine is down": a guard
    /// refusal, a malformed frame, a payload that would not decode. Carries the transport's own
    /// description, which names which of the six guards refused.
    case transport(SubstrateTransportFailure)

    /// `isError` inside a 200, classified. The engine writes an actionable sentence there and
    /// every case below carries it VERBATIM alongside whatever this build managed to recognise —
    /// so a sentence this classifier does not know still reaches the reader intact.
    case unknownScope(registered: [String], sentence: String)

    /// The index on disk was written by a different engine. `EngineHealth` marks this state as
    /// having no wire source and says why: the server raises before retrieval, so it can only ever
    /// be carried by a caller that saw the refusal. This is that caller.
    case schemaMismatch(found: String, expected: String, sentence: String)

    /// A composed scope whose index came back with zero passages. The engine refuses to answer
    /// from it deliberately — "answering from an empty index is indistinguishable from a genuine
    /// no-match" — and this case exists so the UI does not re-create the conflation one layer up.
    case emptyIndex(sentence: String)

    /// The database file the registry points at is not there at all.
    case indexMissing(sentence: String)

    /// Any other tool fault. The sentence is the engine's, unedited.
    case toolFault(sentence: String)

    /// The frame never reached a tool: `-32601` unknown method, `-32602` unknown tool or bad
    /// params, `-32700` parse, `-32603` internal.
    case rpcError(code: Int, message: String)

    /// The payload decoded and then said a word this build has no vocabulary for.
    /// `SubstrateMappingRefusal` refuses rather than reading the nearest neighbour, and this is
    /// where that refusal surfaces: the whole answer is withheld, because a result set silently
    /// missing the one passage whose `status` was new is the failure the refusal exists to stop.
    case vocabulary(String)
}

extension VaultRefusal {

    /// The refusal a call reports, or `nil` when it succeeded.
    static func of<Payload>(_ call: SubstrateCall<Payload>) -> VaultRefusal? {
        switch call {
        case .ok: return nil
        case .toolFault(let text): return classify(fault: text)
        case .rpcError(let code, let message): return .rpcError(code: code, message: message)
        case .transportFailure(let failure): return of(failure)
        }
    }

    /// `.cannotConnectToHost` is Foundation's "nothing is listening", and `waitsForConnectivity`
    /// is off in the client precisely so it arrives as that rather than as a hang. The neighbours
    /// travel with it because a socket that died mid-call and a host that refused the connection
    /// put the reader in the same place: start the engine.
    static func of(_ failure: SubstrateTransportFailure) -> VaultRefusal {
        guard case .unreachable(let reason, let code) = failure else { return .transport(failure) }
        switch code {
        case .some(.cannotConnectToHost), .some(.cannotFindHost),
             .some(.networkConnectionLost), .some(.notConnectedToInternet):
            return .engineDown(reason)
        default:
            return .transport(failure)
        }
    }

    // MARK: Classifying a tool fault

    /// The engine's fault sentence, recognised where possible and carried whole regardless.
    ///
    /// THIS MATCHES ON PROSE, WHICH IS A CONTRACT NOBODY CAN SEE BREAK — `SubstrateMapping` says
    /// exactly that about the last place this codebase did it, and the criticism holds here. It is
    /// done anyway because the alternative is worse: `_dispatch` renders every `ToolError` as
    /// `f"{type(e).__name__}: {e}"`, so an unknown scope and a schema mismatch are byte-identical
    /// in shape and differ only in their words. The mitigation is that recognition only ever
    /// PROMOTES a fault to a better-worded case — every branch, including the fallback, keeps the
    /// engine's sentence, so a match that stops working degrades to a rendered engine sentence
    /// rather than to silence.
    static func classify(fault text: String) -> VaultRefusal {
        if text.contains("unknown scope") {
            return .unknownScope(registered: registered(in: text), sentence: text)
        }
        if text.contains("has an EMPTY index") { return .emptyIndex(sentence: text) }
        if text.contains("Refusing to create it on a read") { return .indexMissing(sentence: text) }
        if let found = schemaFound(in: text) {
            return .schemaMismatch(found: found, expected: schemaExpected(in: text), sentence: text)
        }
        return .toolFault(sentence: text)
    }

    /// `Registered: cbre, clovis, demo, prism, ….` — the scopes the engine says it has. Empty when
    /// the sentence does not carry the list, which is honest: an empty list renders as "the engine
    /// did not say", never as "there are none".
    private static func registered(in text: String) -> [String] {
        guard let marker = text.range(of: "Registered: ") else { return [] }
        let tail = text[marker.upperBound...].prefix { $0 != "." }
        return tail.split(separator: ",")
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
    }

    /// What the index on disk is. Four shapes, because `SchemaMismatch` raises four ways and only
    /// one of them names a version number.
    private static func schemaFound(in text: String) -> String? {
        if let version = integer(after: "was built by schema v", in: text) {
            return "schema v\(version)"
        }
        if text.contains("has no schema") { return "an index with no schema stamp" }
        if text.contains("is not a readable SQLite database") { return "not a readable index" }
        return nil
    }

    private static func schemaExpected(in text: String) -> String {
        guard let version = integer(after: "this engine is v", in: text) else {
            return "a different schema"
        }
        return "schema v\(version)"
    }

    private static func integer(after marker: String, in text: String) -> Int? {
        guard let range = text.range(of: marker) else { return nil }
        let digits = text[range.upperBound...].prefix { $0.isNumber }
        return digits.isEmpty ? nil : Int(digits)
    }
}
