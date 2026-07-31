import SwiftUI

/// The capability envelope and the exclusion bar, in every state that is hard to make legible.
///
/// Three of these states are the reason the page exists, and none of them can be reviewed from a
/// screenshot of the happy path:
///
///   * A 0.593 answer and a 0.698 answer must not look the same. Four independent signals separate
///     them here and not one of them is an alarm colour.
///   * `expected_mrr == nil` must read as ABSENCE. Put the unmeasured bar beside the measured one
///     and check that the eye does not read the dotted slot as an empty (zero) meter.
///   * A fully healthy engine is nearly silent, which is rule 3 working as designed and also the
///     easiest thing in the system to mistake for a component that failed to render.
struct EnvelopeGallery: View {
    let appearance: GalleryAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s16) {
            TierCard()
            AbsenceCard(appearance: appearance)
            DegradationCard()
            EngineStateCard()
            ExclusionCard()
        }
    }
}

// MARK: - Samples

private enum Sample {
    static let apple: [EngineArm] = [
        .embedder("apple-nlcontextual"), .hyde("apple-fm"), .reranker("apple-fm"),
    ]
    static let ollama: [EngineArm] = [
        .embedder("qwen3-embedding:0.6b"), .hyde("qwen2.5:7b"), .reranker("qwen2.5:7b"),
    ]

    /// The zero-install default: everything healthy, nothing installed, 85% of the ceiling. The
    /// state the product spends most of its life in, and the one rule 3 makes quietest.
    static let floor = EngineEnvelope(
        scope: "prism", arms: apple, expectedMRR: EngineTier.floor, frozen: false,
        health: .notInstalled)

    /// The ceiling. Renders two bands and stops — no commentary at all.
    static let ceiling = EngineEnvelope(
        scope: "prism", arms: ollama, expectedMRR: EngineTier.ceiling, frozen: false)

    /// The adaptive rerank gate declining to run. NOT a degradation: the tier is the measured
    /// no-rerank one, and the arm word is grey rather than yellow.
    static let gated = EngineEnvelope(
        scope: "scripta",
        arms: [.embedder("qwen3-embedding:0.6b"), .hyde("qwen2.5:7b"),
               .reranker("qwen2.5:7b", .skipped)],
        expectedMRR: 0.603, frozen: false)

    static let unmeasured = EngineEnvelope(
        scope: "research",
        arms: [.embedder("qwen3-embedding:0.6b"), .hyde("qwen2.5:7b"),
               .reranker("cross-encoder", .ran)],
        expectedMRR: nil, frozen: false,
        unmeasuredReason: "Rerank ran through the cross-encoder, an arm never measured at "
            + "44-case semantic. Per-corpus runs are in EXPERIMENTS.md.")

    /// `refresh.frozen == nil`. Everything else about this run is clean, which is the point: the
    /// only thing standing between this and a healthy render is one dotted line.
    static let noVerdict = EngineEnvelope(
        scope: "clovis", arms: apple, expectedMRR: EngineTier.floor, frozen: nil,
        health: .notInstalled)

    static let degraded = EngineEnvelope(
        scope: "prism",
        arms: [.embedder("qwen3-embedding:0.6b"), .hyde("apple-fm", .fellBack),
               .reranker("qwen2.5:7b")],
        expectedMRR: nil, frozen: false,
        unmeasuredReason: "A wired arm fell back mid-run, so the stack that answered is not one "
            + "that was ever measured.",
        fallbacks: ["hyde: ollama connection reset, fell back to apple-fm"])

    /// `degraded` asserted with nothing to back it. The bar says so rather than dropping the row,
    /// because a degradation with no reasons is still a degradation.
    static let degradedSilently = EngineEnvelope(
        scope: "prism", arms: ollama, expectedMRR: nil, frozen: false,
        unmeasuredReason: "The run reported a degradation, so no measured tier applies.",
        degraded: true)

    /// The CLI's ordering bug, rendered. With the reranker dead the engine returns the genuine
    /// no-rerank tier — a real number for what ran — and printing it alone said "measured tier"
    /// about a stack the caller never asked for. The number stays; the row above it is what makes
    /// the number safe to read.
    static let unavailable = EngineEnvelope(
        scope: "prism",
        arms: [.embedder("qwen3-embedding:0.6b"), .hyde("qwen2.5:7b"),
               .reranker(nil, .unavailable)],
        expectedMRR: 0.603, frozen: false)

    static let down = EngineEnvelope(
        scope: "cbre", arms: apple, expectedMRR: EngineTier.floor, frozen: false,
        fallbacks: ["embed: ollama unreachable, fell back to apple-nlcontextual",
                    "hyde: ollama unreachable, fell back to apple-fm"],
        health: .down("The local model server stopped answering, so every arm ran on-device."))

    static let schema = EngineEnvelope(
        scope: "school", arms: apple, expectedMRR: EngineTier.floor, frozen: false,
        health: .schemaMismatch(found: "schema v7", expected: "schema v8"))

    static let frozen = EngineEnvelope(
        scope: "prism", arms: apple, expectedMRR: EngineTier.floor, frozen: true,
        health: .notInstalled)

    /// The one anchor rule 3 exempts, absent. `EngineScope` cannot be built empty by accident, so
    /// this reaches the state through the door that says so — and the point of the specimen is that
    /// the segment still reads as a segment, with a red line above it saying why it says nothing.
    static let unnamedScope = EngineEnvelope(
        scope: .missing, arms: ollama, expectedMRR: EngineTier.ceiling, frozen: false)
}

// MARK: - Cards

/// The requirement, stated as a comparison because it can only be judged as one.
private struct TierCard: View {
    var body: some View {
        Card(title: "Which tier answered",
             note: "0.593 and 0.698 differ four ways: meter length, the number, the model names on the arms, and whether a price is quoted at all. None of them is a colour.") {
            VStack(alignment: .leading, spacing: Gap.s12) {
                SpecimenRow(name: "floor", detail: "apple · zero install · healthy") {
                    EngineBar(envelope: Sample.floor)
                }
                SpecimenRow(name: "ceiling", detail: "ollama full stack · healthy · silent") {
                    EngineBar(envelope: Sample.ceiling)
                }
                SpecimenRow(name: "gated", detail: "rerank skipped by the adaptive gate — not a fault") {
                    EngineBar(envelope: Sample.gated)
                }
            }
        }
    }
}

/// Both absence states, together, because they share one texture and the whole claim is that the
/// texture cannot be mistaken for a value.
private struct AbsenceCard: View {
    let appearance: GalleryAppearance

    var body: some View {
        Card(title: "Absence, not zero",
             note: "Dotted means no basis for a verdict. A solid empty track would be a zero-length fill, and a zero-length fill is a number the engine never produced.") {
            VStack(alignment: .leading, spacing: Gap.s12) {
                SpecimenRow(name: "expected_mrr == nil", detail: "the slot is kept and drawn empty") {
                    EngineBar(envelope: Sample.unmeasured)
                }
                SpecimenRow(name: "refresh.frozen == nil", detail: "absent evidence — must not render as healthy") {
                    EngineBar(envelope: Sample.noVerdict)
                }
                GroupLabel(text: "The texture the absence states rest on")
                TextureReadout(appearance: appearance)
            }
        }
    }
}

/// The dotted rule is one point of `Ink.stale` over `Ink.layer`. If that pair is invisible in
/// either appearance, every absence state in this component silently becomes a healthy one — so
/// the two values are printed rather than assumed.
private struct TextureReadout: View {
    let appearance: GalleryAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s2) {
            TokenRow(name: "stale", tone: Ink.stale, appearance: appearance,
                     note: "the dotted marker and the empty meter slot")
            TokenRow(name: "layer", tone: Ink.layer, appearance: appearance,
                     note: "what both are drawn on")
        }
    }
}

private struct DegradationCard: View {
    var body: some View {
        Card(title: "Degradation",
             note: "An arm that fell back is yellow; an arm that never started is red, because only the second means the stack that ran is not the stack that was asked for.") {
            VStack(alignment: .leading, spacing: Gap.s12) {
                SpecimenRow(name: "fell back", detail: "hyde dropped mid-run, reasons reported") {
                    EngineBar(envelope: Sample.degraded)
                }
                SpecimenRow(name: "unavailable", detail: "requested, could not start — the number below it is real and not the one asked for") {
                    EngineBar(envelope: Sample.unavailable)
                }
                SpecimenRow(name: "degraded, no reasons", detail: "asserted with nothing behind it — still said out loud") {
                    EngineBar(envelope: Sample.degradedSilently)
                }
            }
        }
    }
}

private struct EngineStateCard: View {
    var body: some View {
        Card(title: "Engine states",
             note: "not-installed is the default configuration and stays monochrome. Down and schema-mismatch are faults someone can act on, and they are the only red in this component.") {
            VStack(alignment: .leading, spacing: Gap.s12) {
                SpecimenRow(name: "down", detail: "installed and unreachable — a fault, unlike not-installed") {
                    EngineBar(envelope: Sample.down)
                }
                SpecimenRow(name: "schema mismatch", detail: "the index was written by another build") {
                    EngineBar(envelope: Sample.schema)
                }
                SpecimenRow(name: "refresh.frozen == true", detail: "answering from superseded content") {
                    EngineBar(envelope: Sample.frozen)
                }
                SpecimenRow(name: "scope unnamed", detail: "otherwise a perfect run — and every line in it is a claim about a corpus nobody can name") {
                    EngineBar(envelope: Sample.unnamedScope)
                }
            }
        }
    }
}

private struct ExclusionCard: View {
    var body: some View {
        Card(title: "What was withheld",
             note: "The default is monochrome because withholding IS the default. Including is the deviation, and a result set carrying superseded notes is exactly what Ink.stale marks.") {
            VStack(alignment: .leading, spacing: Gap.s12) {
                SpecimenRow(name: "default", detail: "live — tap a chip to move it between the groups") {
                    ExclusionPlayground()
                }
                SpecimenRow(name: "opened out", detail: "archived and sources asked for") {
                    ExclusionBar(filter: Self.opened)
                }
                SpecimenRow(name: "nothing withheld", detail: "the whole corpus, said as plainly as the exclusion is") {
                    ExclusionBar(filter: Self.everything)
                }
            }
        }
    }

    private static let opened = ExclusionFilter(
        searched: [.active, .complete, .archived, .sources], notes: ["k clamped to 20"])

    private static let everything = ExclusionFilter(searched: Set(RetrievalClass.allCases))
}

/// The control has to be real here. A screenshot of two static states cannot answer the question
/// the bar exists for — whether a reader who spots a withheld class can actually act on it.
private struct ExclusionPlayground: View {
    @State private var filter = ExclusionFilter.standard

    var body: some View {
        ExclusionBar(filter: filter) { filter.toggle($0) }
    }
}
