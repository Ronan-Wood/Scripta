import Foundation
import SwiftUI

// MARK: - Record & Register: the capability envelope, as data
//
// The engine already refuses to invent a quality number: `Capability.expected_mrr` is the measured
// MRR for the EXACT stack that ran, or null — no interpolation, no family generalization, no
// lower-bound guess. This file is the UI half of that contract, and it exists because the usual way
// a UI breaks it is not by lying but by *rounding absence into a shape that reads as a value* — a
// dash, an empty meter, a greyed-out zero.
//
// So the rendering vocabulary is fixed here, at the model, and there are exactly three states:
//
//   SOLID   — we measured this. A filled meter, a mono number.
//   DOTTED  — we have no basis for a verdict. `expected_mrr == nil`, `refresh.frozen == nil`.
//             Drawn with the `stale` texture, which is the token layer's "not settled" mark.
//   COLOUR  — something departed from the default and it is worth your attention (rule 3).
//
// The trap the dotted state avoids: under rule 3 a healthy engine is silent, so SILENCE MEANS
// HEALTHY. Absent evidence therefore cannot be rendered as silence — `frozen == nil` would then
// claim a clean bill of health the agent never gave. It gets the quietest VISIBLE treatment
// instead, which is what `Ink.stale` was cut for: texture carries the signal, hue only keeps it
// from reading as a solid rule.

/// What one retrieval arm did.
///
/// `skipped` and `off` are NOT failures and must never be coloured: `skipped` is the adaptive
/// rerank gate working correctly, `off` is an arm nobody asked for. Only `fellBack` (started, then
/// dropped mid-run) and `unavailable` (requested, could not start) are deviations. The engine
/// keeps those last two apart on purpose — `unavailable` is byte-identical to `off` in the raw
/// capability record, which is why it travels as its own field, and it is the more urgent of the
/// two because it means the stack the caller asked for is not the stack that ran.
enum EngineArmState: String {
    case ran
    case skipped
    case off
    case fellBack = "fell back"
    case unavailable

    /// `off` shares `skipped`'s tone rather than fading further. `Ink.textPlaceholder` was the
    /// intuitive step down and is the one token this system forbids for load-bearing words twice
    /// over: the ledger records it below 4.5 on EVERY surface (2.16:1 on `layer` in light), and
    /// `SpineBadge` already rejected it for exactly this job. An arm state a reader cannot read is
    /// not a quieter arm state, it is a missing one — and "quieter than skipped" was never a claim
    /// worth a token, because both are the engine working correctly.
    var tone: Tone {
        switch self {
        case .ran: return Ink.textSecondary
        case .skipped, .off: return Ink.textHelper
        case .fellBack: return Ink.warning
        case .unavailable: return Ink.danger
        }
    }
}

/// One arm of the query-time stack: embedder, HyDE, or reranker.
struct EngineArm: Identifiable {
    let label: String
    /// The model that actually ran. `nil` when nothing did — absence, not `"lexical-only"`, for
    /// the same reason the engine sends `null` there: absence is not a model name.
    let model: String?
    let state: EngineArmState

    var id: String { label }

    /// The model when the arm ran, the state word otherwise. Showing the model is what makes an
    /// Apple-tier answer and a full-stack answer legibly different beyond one decimal place.
    var detail: String {
        if state == .ran, let model { return model }
        return state.rawValue
    }

    static func embedder(_ model: String?, _ state: EngineArmState = .ran) -> EngineArm {
        EngineArm(label: "embed", model: model, state: state)
    }

    static func hyde(_ model: String?, _ state: EngineArmState = .ran) -> EngineArm {
        EngineArm(label: "hyde", model: model, state: state)
    }

    static func reranker(_ model: String?, _ state: EngineArmState = .ran) -> EngineArm {
        EngineArm(label: "rank", model: model, state: state)
    }
}

/// The engine's own condition, which is a different axis from what the arms did.
enum EngineHealth {
    case ready

    /// No local model server installed. THE ZERO-INSTALL DEFAULT, NOT A FAULT — it is the state a
    /// fresh download is in, and it delivers 85% of the ceiling. Colouring it would make the
    /// product's default configuration render as broken, which is precisely the upsell posture
    /// this component is built to refuse.
    case notInstalled

    /// Installed and unreachable. This one *is* a fault: the user set something up and it stopped.
    case down(String)

    /// The index on disk was written by a different schema than this build reads.
    case schemaMismatch(found: String, expected: String)
}

/// The measured tiers. Both numbers come from the same 44-case semantic cohort; never compare
/// across cohorts, which is why `cohort` travels with every number this file produces.
enum EngineTier {
    /// Ollama: qwen3-embedding:0.6b + qwen2.5:7b HyDE + qwen2.5:7b listwise rerank.
    static let ceiling: Double = 0.698
    /// Apple only: NLContextualEmbedding + Apple FM HyDE + Apple FM rerank. Zero install.
    static let floor: Double = 0.593
    static let caseCount: Int = 44
    static let cohort = "44-case semantic"

    /// Where a measured tier sits against the ceiling. The floor lands at 85%, and saying so is
    /// the whole anti-upsell argument — a bar that only showed "not full" would make the default
    /// look crippled when it is 85% of the best thing we have measured.
    static func fractionOfCeiling(_ mrr: Double) -> Double {
        max(0, min(1, mrr / ceiling))
    }

    static func percentOfCeiling(_ mrr: Double) -> Int {
        Int((fractionOfCeiling(mrr) * 100).rounded())
    }
}

/// A single line of engine commentary. Built as data rather than as branches inside a `body` so
/// the ORDER — most actionable fault first, absence next, informational last — is one readable
/// list that a reviewer can check against the severity it claims.
struct EngineNote: Identifiable {
    let id: String
    let marker: String
    let tone: Tone
    let text: String
    /// Draw the marker with the `stale` dotted texture: this line reports absent evidence rather
    /// than a measured condition.
    var dotted: Bool = false
}

/// What installing the full stack actually buys, priced in the units it was measured in.
struct EngineUpgrade {
    let delta: Double
    let cases: Double
    let caseCount: Int
    /// Context that changes the sentence's meaning without changing the price — "no local model
    /// server installed" tells a reader the gap is a setup step rather than a purchase.
    let lead: String?
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
/// BE empty: it traps in debug and, in release, names itself `unnamed` and the envelope raises a
/// `danger` note at the top of its commentary. Same shape as `Glyph`/`MissingGlyph` — loud in
/// development, loud on screen, never silent.
struct EngineScope: Hashable, ExpressibleByStringLiteral, CustomStringConvertible {
    let name: String

    /// What an engine that cannot name its corpus renders as. A word, not a blank — a fault the
    /// reader can see beats an anchor that vanished — and parenthesised, because a scope token is a
    /// lowercase identifier the caller could type and this one deliberately is not. That also keeps
    /// `isNamed` honest: no real scope can collide with the fault state.
    static let unnamed = "(unnamed)"

    /// The fault state, constructed on purpose. The gallery has to be able to DRAW this — a state
    /// nobody can look at is a state nobody reviews — and this is the only door to it that does not
    /// trip the trap, which is what keeps every other route accidental and loud.
    static let missing = EngineScope(checked: unnamed)

    init(_ raw: String) {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        assert(!trimmed.isEmpty,
               "EngineEnvelope.scope is empty. The scope segment is rule 3's whole discoverability "
                 + "budget; an empty one renders as a healthy quiet bar.")
        self.init(checked: trimmed.isEmpty ? Self.unnamed : trimmed)
    }

    private init(checked name: String) { self.name = name }

    init(stringLiteral value: String) { self.init(value) }

    var isNamed: Bool { name != Self.unnamed }
    var description: String { name }
}

/// Everything the bar renders, assembled once so the view is layout only.
struct EngineEnvelope {
    let scope: EngineScope
    let arms: [EngineArm]

    /// `nil` means this exact stack was never measured. It is NOT a nearest-tier estimate, a lower
    /// bound, or a zero, and the renderer must not turn it into one.
    let expectedMRR: Double?
    /// Why there is no number. Required in practice: "unmeasured" without a reason is
    /// indistinguishable from a bug, and the engine always knows which of the five reasons applies.
    let unmeasuredReason: String?
    let cohort: String

    let degraded: Bool
    let fallbacks: [String]
    let health: EngineHealth

    /// Tri-state, and every value is a different claim. `true`: the vault changed and the rebuild
    /// REFUSED, so these answers come from superseded content. `false`: index and vault agreed at
    /// the last pass. `nil`: NO BASIS — nothing checked, which is not the same as nothing wrong.
    let frozen: Bool?

    /// No default for `expectedMRR` or `frozen`. Both are tri-state honesty fields whose whole
    /// point is that a caller must decide; a default would let one be forgotten into the healthy
    /// reading, which is the failure mode both exist to prevent.
    init(scope: EngineScope,
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
        // string — yielded `degraded == false`, so `degradedNote` never appeared. That is the
        // false-healthy shape this whole envelope exists to remove, reached through the one field
        // that was not derived from the same place `unavailableArms` is.
        //
        // Still overridable, for the opposite case: `degraded == true` with no reasons and no
        // fallen-back arm is a real state the bar must be able to say out loud. An explicit `false`
        // is honoured too — a caller that has looked and concluded otherwise outranks the
        // inference, which is why this is `??` and not an `||` over the derived value.
        // `.fellBack` ONLY, deliberately. Including `.unavailable` here made the bar invent an
        // event: `degradedNote`'s text is written for the fell-back case, so a run whose only
        // deviation was an arm that never started printed "An arm fell back mid-run" — an event
        // the engine did not report, from the component whose entire job is not doing that.
        // `.unavailable` is not unreported either way; it has its own higher-severity note derived
        // from `unavailableArms`, so counting it here also double-reported one condition.
        let armFellBack = arms.contains { $0.state == .fellBack }
        self.degraded = degraded ?? (!fallbacks.isEmpty || armFellBack)
        self.health = health
        self.frozen = frozen
    }

    var unavailableArms: [EngineArm] { arms.filter { $0.state == .unavailable } }

    /// Whether the bar has a third band at all. Asked before the band is built so a healthy
    /// full-stack query renders two rows and stops, rather than two rows plus an empty container
    /// still spending its parent's spacing.
    var hasCommentary: Bool { !notes.isEmpty || upgrade != nil }

    /// Severity order, top to bottom: faults you can act on, then absent evidence, then context.
    var notes: [EngineNote] {
        var out: [EngineNote] = []
        // First, above every other fault: a result set whose corpus is unnamed cannot be judged at
        // all, because every other line here is a claim ABOUT that corpus.
        if !scope.isNamed { out.append(unnamedScopeNote) }
        out.append(contentsOf: healthNotes)
        if !unavailableArms.isEmpty {
            let names = unavailableArms.map(\.label).joined(separator: " · ")
            out.append(EngineNote(
                id: "unavailable", marker: "unavailable", tone: Ink.danger,
                text: "Requested but could not start: \(names). The stack that ran is not the one "
                    + "that was asked for."))
        }
        if degraded { out.append(degradedNote) }
        out.append(contentsOf: frozenNotes)
        if expectedMRR == nil { out.append(unmeasuredNote) }
        if case .notInstalled = health, upgrade == nil { out.append(defaultTierNote) }
        return out
    }

    private var unnamedScopeNote: EngineNote {
        EngineNote(
            id: "scope", marker: "scope", tone: Ink.danger,
            text: "This answer names no corpus. Every other line below is a claim about a scope "
                + "nobody can identify, so none of them can be checked.")
    }

    private var healthNotes: [EngineNote] {
        switch health {
        // `notInstalled` is deliberately absent from this switch. It is the default state, and the
        // upgrade line below already says what it means, priced.
        case .ready, .notInstalled:
            return []
        case .down(let detail):
            return [EngineNote(id: "down", marker: "engine down", tone: Ink.danger, text: detail)]
        case .schemaMismatch(let found, let expected):
            return [EngineNote(
                id: "schema", marker: "schema", tone: Ink.danger,
                text: "The index on disk is \(found); this build reads \(expected). Recompose "
                    + "before trusting these results.")]
        }
    }

    private var degradedNote: EngineNote {
        EngineNote(
            id: "degraded", marker: "degraded", tone: Ink.warning,
            // A degradation with no reasons attached is still a degradation. Saying "no reasons
            // reported" beats dropping the row, which would render a known-degraded run as clean.
            text: fallbacks.isEmpty
                ? "An arm fell back mid-run. No reasons were reported."
                : "Arms fell back mid-run: " + fallbacks.joined(separator: "; "))
    }

    private var frozenNotes: [EngineNote] {
        switch frozen {
        case .some(true):
            return [EngineNote(
                id: "frozen", marker: "frozen", tone: Ink.warning,
                text: "The vault changed and the last recompose refused, so these results do not "
                    + "reflect it. Treat them as superseded content.")]
        case .some(false):
            return []
        case .none:
            return [EngineNote(
                id: "refresh", marker: "refresh", tone: Ink.stale,
                text: "No verdict. Nothing has checked this index against the vault, which is not "
                    + "the same as checking it and finding it current.",
                dotted: true)]
        }
    }

    private var unmeasuredNote: EngineNote {
        EngineNote(
            id: "unmeasured", marker: "unmeasured", tone: Ink.stale,
            text: unmeasuredReason
                ?? "This stack was never measured at \(cohort), so there is no quality number for "
                + "it — not a low one.",
            dotted: true)
    }

    private var defaultTierNote: EngineNote {
        EngineNote(
            id: "default", marker: "default", tone: Ink.textHelper,
            text: "No local model server installed. This is the configuration a fresh install "
                + "runs.")
    }

    /// The honest price of the rest, or nothing at all.
    ///
    /// Refuses on a foreign cohort. `ceiling - mrr` is only a real quantity when both sides were
    /// measured the same way; subtracting across cohorts produces a number that looks measured and
    /// is not, which is the same sin as estimating `expected_mrr` from a neighbouring tier.
    var upgrade: EngineUpgrade? {
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
