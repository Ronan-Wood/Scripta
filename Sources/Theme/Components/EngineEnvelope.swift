import Foundation
import SwiftUI

// MARK: - Record & Register: how the capability envelope is drawn
//
// THE ENVELOPE ITSELF IS NOT HERE. `EngineEnvelope`, `EngineArm`, `EngineArmState`, `EngineHealth`,
// `EngineScope`, `EngineUpgrade` and the measured `EngineTier` constants are what the engine
// reported, so they live in `SubstrateKit` (Core/Sources/SubstrateKit/EngineEnvelope.swift). This
// file is the other half, and the split is the same one the passage spine makes: an arm STATE is a
// value the engine sends, the tone it is drawn in is a choice we make.
//
// The engine already refuses to invent a quality number: `expected_mrr` is the measured MRR for the
// EXACT stack that ran, or null. This file exists because the usual way a UI breaks that contract is
// not by lying but by *rounding absence into a shape that reads as a value* — a dash, an empty
// meter, a greyed-out zero.
//
// So the rendering vocabulary is fixed here and there are exactly three states:
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

extension EngineArmState {
    /// `skipped` and `off` are NOT failures and must never be coloured; only `fellBack` and
    /// `unavailable` are deviations, and `unavailable` is the more urgent of the two because it
    /// means the stack the caller asked for is not the stack that ran.
    ///
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

extension EngineEnvelope {

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
}
