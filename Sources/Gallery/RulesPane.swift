import SwiftUI

/// The three rules, each shown as the thing it forbids next to the thing it permits. A rule stated
/// in a comment is a rule the next author reads once; a rule shown failing beside itself is one
/// they can check a diff against.
struct RulesPane: View {
    let appearance: GalleryAppearance

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s16) {
            CoverageCard()
            PlumbingCard(appearance: appearance)
            BlueOnlyCard()
            DeviationCard()
        }
    }
}

/// States what the gallery is showing, and — deliberately — that this number is not self-verifying.
/// A running binary cannot enumerate an enum of `static let`s, so a token added to `Ink` and not to
/// `InkCatalog` would simply not appear here, silently. The checks that catch that parse the
/// source, and live in the Core gate.
private struct CoverageCard: View {
    var body: some View {
        Card(title: "Coverage",
             note: "Not self-verifying — a running binary cannot enumerate its own tokens. Four Core gates parse the source instead: testEveryTokenParticipatesInTheGate (no token escapes the contrast matrix), testEveryInkTheComponentLayerNamesIsClassified (text or not-text, with a reason), testRestrictedTokensAreOnlyNamedWhereTheRuleAllows (rule 2's blue, the placeholder ink and `success` — over this surface too, not just the component layer), and testRuleThreeSurfacesAreClassifiedAndTheDefaultPathIsAchromatic.") {
            VStack(alignment: .leading, spacing: Gap.s2) {
                CoverageRow(label: "Ink tokens rendered", value: "\(InkCatalog.allTokens.count)")
                CoverageRow(label: "counted in Ink.swift at landing", value: "\(InkCatalog.countAtLanding)")
                CoverageRow(label: "type roles rendered", value: "\(RegisterCatalog.all.count)")
                CoverageRow(label: "pages", value: "\(GalleryPage.allCases.count)")
            }
        }
    }
}

private struct CoverageRow: View {
    let label: String
    let value: String

    var body: some View {
        HStack(spacing: Gap.s8) {
            Text(label).typeface(Register.ui, Ink.textPrimary)
            Spacer(minLength: Gap.s8)
            Text(value).typeface(Register.mono, Ink.textSecondary)
        }
        .frame(minHeight: Density.row)
    }
}

/// The gallery's own honesty check. Each chip draws the same token twice — once through the
/// `ShapeStyle` path a real view uses, once pre-resolved for this column. A seam means this column
/// is rendering the other appearance's values and nothing else on the page can be trusted.
private struct PlumbingCard: View {
    let appearance: GalleryAppearance

    private static let probes: [(String, Tone)] = [
        ("background", Ink.background),
        ("layer", Ink.layer),
        ("textPrimary", Ink.textPrimary),
        ("interactive", Ink.interactive),
        ("speaker.amber", Ink.speaker.amber),
    ]

    var body: some View {
        Card(title: "Appearance plumbing — \(appearance.title)",
             note: "Left half: .fill(token). Right half: token.resolved(for: this appearance). A visible seam invalidates this column.") {
            VStack(alignment: .leading, spacing: Gap.s2) {
                ForEach(Self.probes, id: \.0) { probe in
                    TokenRow(name: probe.0, tone: probe.1, appearance: appearance)
                }
            }
        }
    }
}

private struct BlueOnlyCard: View {
    var body: some View {
        Card(title: "Rule 2 — blue is interaction only",
             note: "Blue never carries content meaning. The failure this prevents: an accent declared as \"Them\" that a second author then draws in a different orange.") {
            VStack(alignment: .leading, spacing: Gap.s10) {
                RuleExample(verdict: .allowed, caption: "selected row, link, focus ring") {
                    SelectedRowSample()
                }
                RuleExample(verdict: .forbidden, caption: "blue as a speaker or a category") {
                    Text("Priya").typeface(Register.uiEmphasis, Ink.interactive)
                }
            }
        }
    }
}

private struct SelectedRowSample: View {
    var body: some View {
        Text("Weekly review")
            .typeface(Register.ui, Ink.textPrimary)
            .controlBox(Density.row)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Ink.interactiveSoft, in: Corner.shape(Corner.control))
    }
}

/// Rule 3 is the spine, and its cost is deliberate: the healthy case is silent. Showing both cases
/// adjacent is the only way to judge whether the silence reads as calm or as broken.
///
/// Every row is a real `Passage` drawn by the real `PassageSpine`, and the count beside it comes
/// from the same `prominence` the badges drew with. It used to be a private `ResultFlag` enum and a
/// freeform meta string used nowhere else, which is how this card came to render "low confidence"
/// as `stale` while the component two pages away renders the same value as `danger` — the exhibit
/// contradicting the thing it exhibits, and a reviewer with no way to tell which one was the
/// system. A card that demonstrates a rule has to be built from the types that implement it, or it
/// is a DRAWING of the rule and drifts the first time the rule moves.
private struct DeviationCard: View {
    var body: some View {
        Card(title: "Rule 3 — colour marks deviation",
             note: "A default-corpus, active, verified result is entirely monochrome. Every coloured mark below is a departure — drawn by the passage spine itself, counted from the same prominence.") {
            VStack(alignment: .leading, spacing: Gap.s6) {
                ForEach(DeviationSpecimen.all) { DeviationRow(specimen: $0) }
            }
        }
    }
}

private struct DeviationSpecimen: Identifiable {
    let caption: String
    let passage: Passage

    var id: String { passage.id }

    /// The census, derived. Nothing here decides what is coloured; it counts what the spine drew.
    var marks: Int { passage.spineAxes.filter(\.prominence.carriesColour).count }

    var verdict: String {
        marks == 0 ? "monochrome" : (marks == 1 ? "1 mark" : "\(marks) marks")
    }

    static let all: [DeviationSpecimen] = [
        DeviationSpecimen(
            caption: "default corpus, active, verified — nothing departed",
            passage: Passage(id: "adr-031", snippet: "Blue marks interaction and nothing else.",
                             citation: "02-areas/record-and-register.md", vault: "prism",
                             status: .active, docType: .decision, confidence: .verified,
                             documentClass: .referenceFrozen)),
        DeviationSpecimen(
            caption: "judged and unsettled — a proposal read as a decision is a wrong action",
            passage: Passage(id: "adr-044", snippet: "A per-scope refresh budget.",
                             citation: "02-areas/refresh-budget.md", vault: "prism",
                             status: .active, docType: .decision, confidence: .proposed,
                             documentClass: .referenceFrozen)),
        DeviationSpecimen(
            caption: "outside the default corpus — you asked for superseded notes",
            passage: Passage(id: "adr-014", snippet: "supersedes names one note.",
                             citation: "02-areas/envelope-v7.md", vault: "prism",
                             status: .superseded, docType: .decision, confidence: .stated,
                             documentClass: .referenceFrozen)),
        DeviationSpecimen(
            caption: "conversation class — confidence varies WITHIN a transcript",
            passage: Passage(id: "call-0714", snippet: "…so we'd drop the rerank entirely.",
                             citation: "_sources/2026-07-14-platform-sync.md", vault: "scripta",
                             status: .active, docType: .reference, confidence: .stated,
                             documentClass: .conversation)),
    ]
}

private struct DeviationRow: View {
    let specimen: DeviationSpecimen

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s6) {
            DeviationCaption(caption: specimen.caption, verdict: specimen.verdict)
            PassageSpine(passage: specimen.passage)
        }
        .padding(Metrics.cardPaddingCompact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Ink.background, radius: Corner.control)
    }
}

private struct DeviationCaption: View {
    let caption: String
    let verdict: String

    var body: some View {
        HStack(spacing: Gap.s8) {
            Text(caption).typeface(Register.caption, Ink.textHelper)
            Spacer(minLength: Gap.s8)
            Text(verdict).typeface(Register.monoMicro, Ink.textHelper)
        }
    }
}

private enum RuleVerdict {
    case allowed, forbidden

    var label: String { self == .allowed ? "allowed" : "forbidden" }
    /// Neutral for `allowed`. Green here would be `Ink.success` — a "State — deviation only"
    /// token — spent to mark the case that did NOT deviate, on the page that states the rule.
    var tone: Tone { self == .allowed ? Ink.textSecondary : Ink.danger }
}

private struct RuleExample<Content: View>: View {
    let verdict: RuleVerdict
    let caption: String
    @ViewBuilder var content: () -> Content

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s4) {
            HStack(spacing: Gap.s8) {
                Text(verdict.label).microLabel(verdict.tone)
                Text(caption).typeface(Register.caption, Ink.textHelper)
            }
            content()
        }
    }
}
