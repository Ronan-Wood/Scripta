import Foundation

// MARK: - The four fields where `null` is a claim
//
// `substrate/substrate/render.py` opens with the rule this file implements: "Nothing that was
// withheld is silent. Every spine field is emitted UNCONDITIONALLY, null included." A `null` there
// is a VALUE the engine chose to send, and for four fields it is a different claim from `false` and
// from `0`. Each of them gets an enum with a named no-verdict case, so the ONE expression that
// inverts the signal — `?? false` — has nothing to attach to.
//
// The four, and what each null means:
//   `refresh.frozen`          no verdict was possible; NOT a clean bill of health
//   `retrieval_mode.expected_mrr`  this exact stack was never measured; not an estimate, not zero
//   `note.stale`              the stored checksum is a declared one, so no edit is detectable here
//   `status.drift`            a SUM TYPE — either a checked report or an error payload
//
// These are wire types. They map to the view vocabulary (`EngineEnvelope.frozen` and friends) in
// `SubstrateMapping.swift`; nothing here knows what a bar looks like.

/// `refresh.frozen` — whether the index is answering from superseded content.
///
/// `refresh_state.py` states the tri-state exactly: `true` means the vault changed and the rebuild
/// REFUSED; `false` means the agent's last pass left index and vault in agreement; `null` means the
/// agent never got far enough to form a view. `skipped` records `null` rather than `false` for that
/// reason — "nothing was checked" is not "nothing is wrong".
public enum FrozenVerdict: Equatable, Hashable, Sendable {
    /// The index demonstrably disagrees with the vault.
    case frozen
    /// Index and vault agreed at the last pass.
    case current
    /// No verdict was possible. ABSENT EVIDENCE — never read this as healthy.
    case noBasis

    public init(_ wire: Bool?) {
        switch wire {
        case .some(true): self = .frozen
        case .some(false): self = .current
        case .none: self = .noBasis
        }
    }

    public var wireValue: Bool? {
        switch self {
        case .frozen: return true
        case .current: return false
        case .noBasis: return nil
        }
    }
}

/// `retrieval_mode.expected_mrr` — the measured MRR for the exact stack that ran.
///
/// There is deliberately no `Double`-returning accessor and no `orZero`. `render.retrieval_mode`
/// promises "the measured tier for THIS exact stack or an honest null — never an estimate, never a
/// number generalized from a neighbouring configuration", and a client that could reach a `Double`
/// without naming the case would put the estimate back. Callers pattern-match.
public enum MeasuredMRR: Equatable, Hashable, Sendable {
    case measured(Double)
    /// This configuration was never measured at `cohort`. Not a lower bound, not a dash, not zero.
    case unmeasured

    public init(_ wire: Double?) {
        self = wire.map(Self.measured) ?? .unmeasured
    }

    public var wireValue: Double? {
        if case .measured(let value) = self { return value }
        return nil
    }
}

/// `note.stale` from `expand(mode: "note")` — whether the note on disk still matches what was
/// indexed.
///
/// `null` where the stored checksum is a DECLARED one (it names a PDF, per Doc 2 §3b), so an edit to
/// the note body cannot be seen from the index at all. `mcp/server._note_text` says it plainly:
/// "false is a claim, and this is the case where no claim can honestly be made."
public enum StaleVerdict: Equatable, Hashable, Sendable {
    /// The note no longer matches what was indexed — the passages came from the OLD content.
    case stale
    case matches
    /// Not checkable from the index.
    case uncheckable

    public init(_ wire: Bool?) {
        switch wire {
        case .some(true): self = .stale
        case .some(false): self = .matches
        case .none: self = .uncheckable
        }
    }

    public var wireValue: Bool? {
        switch self {
        case .stale: return true
        case .matches: return false
        case .uncheckable: return nil
        }
    }
}

// MARK: - Encoding helper

extension KeyedEncodingContainer {
    /// Writes `null` rather than dropping the key.
    ///
    /// Swift's synthesized `encode(to:)` uses `encodeIfPresent` for optionals, which OMITS a nil —
    /// producing a shape the engine never sends. Every payload builder in `render.py`,
    /// `introspect.py` and `refresh_state._block` emits its full key set unconditionally, and the
    /// round-trip gate compares against the engine's own bytes, so a dropped key is a failure here
    /// rather than a cosmetic difference.
    mutating func encodeExplicitNull<T: Encodable>(_ value: T?, forKey key: Key) throws {
        if let value {
            try encode(value, forKey: key)
        } else {
            try encodeNil(forKey: key)
        }
    }
}
