import Foundation

// MARK: - The capability envelope, as the engine sends it
//
// `render.retrieval_mode` refuses to invent a quality number: `expected_mrr` is the measured MRR for
// the EXACT stack that ran, or null — no interpolation, no family generalization, no lower-bound
// guess. This file is the client's half of that contract, and it holds only what the engine
// reported plus what is derivable from it.
//
// What is NOT here, and the line it draws: the three rendering states (solid / dotted / colour), the
// commentary lines and their tones, and the tone an arm state takes. Those are how we choose to draw
// an envelope, so they live in `Sources/Theme/Components/EngineEnvelope.swift` as extensions. Every
// value below is one the engine put in a field.

/// What one retrieval arm did.
///
/// `skipped` and `off` are NOT failures: `skipped` is the adaptive rerank gate working correctly,
/// `off` is an arm nobody asked for. Only `fellBack` (started, then dropped mid-run) and
/// `unavailable` (requested, could not start) are deviations. The engine keeps those last two apart
/// on purpose — `unavailable` is byte-identical to `off` in the raw capability record, which is why
/// it travels as its own field (`retrieval_mode.unavailable`), and it is the more urgent of the two
/// because it means the stack the caller asked for is not the stack that ran.
public enum EngineArmState: String {
    case ran
    case skipped
    case off
    case fellBack = "fell back"
    case unavailable
}

/// One arm of the query-time stack: embedder, HyDE, or reranker.
public struct EngineArm: Identifiable {
    public let label: String
    /// The model that actually ran. `nil` when nothing did — absence, not `"lexical-only"`, for
    /// the same reason the engine sends `null` there: absence is not a model name.
    public let model: String?
    public let state: EngineArmState

    public var id: String { label }

    public init(label: String, model: String?, state: EngineArmState) {
        self.label = label
        self.model = model
        self.state = state
    }

    /// The model when the arm ran, the state word otherwise. Showing the model is what makes an
    /// Apple-tier answer and a full-stack answer legibly different beyond one decimal place.
    public var detail: String {
        if state == .ran, let model { return model }
        return state.rawValue
    }

    public static func embedder(_ model: String?, _ state: EngineArmState = .ran) -> EngineArm {
        EngineArm(label: "embed", model: model, state: state)
    }

    public static func hyde(_ model: String?, _ state: EngineArmState = .ran) -> EngineArm {
        EngineArm(label: "hyde", model: model, state: state)
    }

    public static func reranker(_ model: String?, _ state: EngineArmState = .ran) -> EngineArm {
        EngineArm(label: "rank", model: model, state: state)
    }
}

/// The engine's own condition, which is a different axis from what the arms did.
public enum EngineHealth {
    case ready

    /// No local model server installed. THE ZERO-INSTALL DEFAULT, NOT A FAULT — it is the state a
    /// fresh download is in, and it delivers 85% of the ceiling.
    case notInstalled

    /// Installed and unreachable. This one *is* a fault: the user set something up and it stopped.
    case down(String)

    /// The index on disk was written by a different schema than this build reads.
    case schemaMismatch(found: String, expected: String)
}

/// The measured tiers.
///
/// MEASUREMENTS, not settings. Their source of truth is `substrate/EXPERIMENTS.md` — the ceiling at
/// its §"44-case cohort" table, the floor at its §"THE FLOOR — what a user gets with nothing
/// installed. 0.593." Nothing links that file to this declaration but this comment, so a number
/// changed there and not here is a client claiming a tier the engine never measured.
///
/// Both come from the same 44-case semantic cohort; never compare across cohorts, which is why
/// `cohort` travels with every number this file produces.
public enum EngineTier {
    /// Ollama: qwen3-embedding:0.6b + qwen2.5:7b HyDE + qwen2.5:7b listwise rerank.
    public static let ceiling: Double = 0.698
    /// Apple only: NLContextualEmbedding + Apple FM HyDE + Apple FM rerank. Zero install.
    public static let floor: Double = 0.593
    public static let caseCount: Int = 44
    public static let cohort = "44-case semantic"

    /// Where a measured tier sits against the ceiling. The floor lands at 85%, and saying so is
    /// the whole anti-upsell argument — a bar that only showed "not full" would make the default
    /// look crippled when it is 85% of the best thing we have measured.
    public static func fractionOfCeiling(_ mrr: Double) -> Double {
        max(0, min(1, mrr / ceiling))
    }

    public static func percentOfCeiling(_ mrr: Double) -> Int {
        Int((fractionOfCeiling(mrr) * 100).rounded())
    }
}

/// What installing the full stack actually buys, priced in the units it was measured in.
public struct EngineUpgrade {
    public let delta: Double
    public let cases: Double
    public let caseCount: Int
    /// Context that changes the sentence's meaning without changing the price — "no local model
    /// server installed" tells a reader the gap is a setup step rather than a purchase.
    public let lead: String?

    public init(delta: Double, cases: Double, caseCount: Int, lead: String?) {
        self.delta = delta
        self.cases = cases
        self.caseCount = caseCount
        self.lead = lead
    }
}

/// The corpus a result set came from. Never empty, never silent.
///
/// A TYPE and not a `String` because "never empty, never silent" was written in a doc comment, the
/// initialiser took a plain `String`, and the label had no guard — so an empty scope drew an empty
/// pill, and under rule 3 an empty pill is indistinguishable from a healthy quiet one. The scope
/// segment is the entire discoverability budget: it is the one thing that tells a first-time reader
/// the answer came from a NAMED corpus that could have been a different one.
///
/// There is no failable initialiser because there is no correct render for an absent scope, and a
/// caller forced to unwrap would reach for `?? ""` and put the hole back. Instead the value cannot
/// BE empty: it traps in debug and, in release, names itself `unnamed` so the envelope can raise a
/// `danger` note at the top of its commentary. Loud in development, loud on screen, never silent.
public struct EngineScope: Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    public let name: String

    /// What an engine that cannot name its corpus renders as. A word, not a blank — a fault the
    /// reader can see beats an anchor that vanished — and parenthesised, because a scope token is a
    /// lowercase identifier the caller could type and this one deliberately is not. That also keeps
    /// `isNamed` honest: no real scope can collide with the fault state.
    public static let unnamed = "(unnamed)"

    /// The fault state, constructed on purpose. The gallery has to be able to DRAW this — a state
    /// nobody can look at is a state nobody reviews — and this is the only door to it that does not
    /// trip the trap, which is what keeps every other route accidental and loud.
    public static let missing = EngineScope(checked: unnamed)

    public init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        assert(!trimmed.isEmpty,
               "EngineEnvelope.scope is empty. The scope segment is rule 3's whole discoverability "
                 + "budget; an empty one renders as a healthy quiet bar.")
        self.init(checked: trimmed.isEmpty ? Self.unnamed : trimmed)
    }

    private init(checked name: String) { self.name = name }

    public init(stringLiteral value: String) { self.init(value) }

    public var isNamed: Bool { name != Self.unnamed }
    public var description: String { name }
}

/// One `search_payload`'s capability half, assembled once so a view is layout only.
public struct EngineEnvelope {
    public let scope: EngineScope
    public let arms: [EngineArm]

    /// `nil` means this exact stack was never measured. It is NOT a nearest-tier estimate, a lower
    /// bound, or a zero, and nothing downstream may turn it into one.
    public let expectedMRR: Double?
    /// Why there is no number. Required in practice: "unmeasured" without a reason is
    /// indistinguishable from a bug, and the engine always knows which of the five reasons applies.
    public let unmeasuredReason: String?
    public let cohort: String

    public let degraded: Bool
    public let fallbacks: [String]
    public let health: EngineHealth

    /// Tri-state, and every value is a different claim. `true`: the vault changed and the rebuild
    /// REFUSED, so these answers come from superseded content. `false`: index and vault agreed at
    /// the last pass. `nil`: NO BASIS — nothing checked, which is not the same as nothing wrong.
    public let frozen: Bool?

    /// No default for `expectedMRR` or `frozen`. Both are tri-state honesty fields whose whole
    /// point is that a caller must decide; a default would let one be forgotten into the healthy
    /// reading, which is the failure mode both exist to prevent.
    public init(scope: EngineScope,
                arms: [EngineArm],
                expectedMRR: Double?,
                frozen: Bool?,
                unmeasuredReason: String? = nil,
                cohort: String = EngineTier.cohort,
                fallbacks: [String] = [],
                degraded: Bool? = nil,
                health: EngineHealth = .ready) {
        self.scope = scope
        self.arms = arms
        self.expectedMRR = expectedMRR
        self.unmeasuredReason = unmeasuredReason
        self.cohort = cohort
        self.fallbacks = fallbacks
        // Derived from the ARMS as well as the reasons. `!fallbacks.isEmpty` alone rendered a
        // known-degraded run as clean: an arm sitting in `.fellBack` with an empty `fallbacks`
        // array — which the engine produces whenever an arm degrades without attaching a reason
        // string — yielded `degraded == false`, so the degraded line never appeared. That is the
        // false-healthy shape this whole envelope exists to remove, reached through the one field
        // that was not derived from the same place `unavailableArms` is.
        //
        // Still overridable, for the opposite case: `degraded == true` with no reasons and no
        // fallen-back arm is a real state that must be sayable out loud. An explicit `false` is
        // honoured too — a caller that has looked and concluded otherwise outranks the inference,
        // which is why this is `??` and not an `||` over the derived value.
        // `.fellBack` ONLY, deliberately. Including `.unavailable` here made the bar invent an
        // event: the degraded line's text is written for the fell-back case, so a run whose only
        // deviation was an arm that never started printed "An arm fell back mid-run" — an event the
        // engine did not report. `.unavailable` is not unreported either way; it has its own
        // higher-severity note derived from `unavailableArms`, so counting it here also
        // double-reported one condition.
        let armFellBack = arms.contains { $0.state == .fellBack }
        self.degraded = degraded ?? (!fallbacks.isEmpty || armFellBack)
        self.health = health
        self.frozen = frozen
    }

    public var unavailableArms: [EngineArm] { arms.filter { $0.state == .unavailable } }

    /// The honest price of the rest, or nothing at all.
    ///
    /// Refuses on a foreign cohort. `ceiling - mrr` is only a real quantity when both sides were
    /// measured the same way; subtracting across cohorts produces a number that looks measured and
    /// is not, which is the same sin as estimating `expected_mrr` from a neighbouring tier.
    public var upgrade: EngineUpgrade? {
        guard cohort == EngineTier.cohort,
              let mrr = expectedMRR,
              mrr < EngineTier.ceiling else { return nil }
        let delta = EngineTier.ceiling - mrr
        var lead: String?
        if case .notInstalled = health { lead = "No local model server installed." }
        return EngineUpgrade(delta: delta,
                             cases: delta * Double(EngineTier.caseCount),
                             caseCount: EngineTier.caseCount,
                             lead: lead)
    }
}
