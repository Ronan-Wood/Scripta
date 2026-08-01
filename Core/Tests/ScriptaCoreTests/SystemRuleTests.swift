import Foundation
import XCTest

// MARK: - The rules the contrast gate cannot see
//
// `ContrastGateTests` scores PAIRINGS and `TextInk` scores SIZES. Between them they catch a token
// that cannot be read. They cannot catch a token that is perfectly legible and MEANS THE WRONG
// THING, and that is what actually drifted — every time, in the same shape:
//
//   * blue defaulted onto a progress bar, which reports machine-measured work state. Rule 2 says
//     blue marks a thing you can click, and you cannot click a progress bar.
//   * `textPlaceholder` under load-bearing 11pt engine state, a token the ledger records below 4.5
//     on every surface and which `SpineBadge` had already rejected for exactly that job.
//   * a dotted rule spent as a row separator, in the surface that reviews the claim the dotted
//     texture carries.
//   * a fixed height in the review surface that exhibits "never a fixed height".
//
// Each is a question about the CALL SITE, not about a colour pair, so each gate here is an allow
// list with a reason on every row — the same shape as `TextInk.notText`, for the same reason: a new
// use cannot arrive unexamined. Where a rule can instead be made unrepresentable it is (see
// `Passage.withheldAs`'s exhaustive switch and `EngineScope`), and no test is written for it,
// because the compiler is a better gate than a parser.
//
// Same module boundary and same cost as `ThemeTokenSource`: this target cannot import the design
// system, so it reads it as text. Every test below therefore asserts a FLOOR on what it parsed. A
// scan that quietly finds nothing would pass all of them.

// MARK: Sources

enum DesignSystemSource {
    /// The files this pass owns. `Sources/Theme/Carbon*` is deliberately absent: it is the layer
    /// "Record & Register" replaces, and holding it to these rules would report the thing being
    /// removed as the thing that is broken.
    static func files() throws -> [URL] {
        try components() + tokenLayer() + gallery()
    }

    /// Everything the rules apply to that also DRAWS: the component layer and the review surface.
    /// The token layer is excluded on purpose — it declares the tokens, so "names `Ink.interactive`"
    /// is what it is for, and a permission row there would say nothing.
    static func drawing() throws -> [URL] { try components() + gallery() }

    static func components() throws -> [URL] { try swiftFiles(in: "Sources/Theme/Components") }

    static func gallery() throws -> [URL] { try swiftFiles(in: "Sources/Gallery") }

    /// A DIRECTORY, like the other two. It was `["Ink", "Register", "Metrics", "Surface"]` — one of
    /// four places that spelled out "the token layer is these four files", none of which could tell
    /// you a fifth had arrived: it would have compiled nowhere and gated nowhere, silently.
    static func tokenLayer() throws -> [URL] { try swiftFiles(in: "Sources/Theme/Tokens") }

    static var root: URL {
        URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScriptaCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repository root
    }

    private static func swiftFiles(in path: String) throws -> [URL] {
        let all = try FileManager.default.contentsOfDirectory(
            at: root.appendingPathComponent(path), includingPropertiesForKeys: nil)
        return all.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    /// Comments name tokens constantly — this file's whole subject is why one token is wrong — and
    /// a mention is not a use. Same stripper the contrast gate uses.
    static func code(_ url: URL) throws -> String {
        ComponentInk.withoutComments(try String(contentsOf: url, encoding: .utf8))
    }
}

// MARK: Restricted tokens

/// A constraint on WHERE a token may be named at all, and the files allowed to name it.
struct InkUseRule {
    let name: String
    let tokens: [String]
    /// Why the constraint exists. Printed on failure, because a gate that only says "not allowed"
    /// gets satisfied by adding a row.
    let rule: String
    /// file name → what the token marks there.
    let permitted: [String: String]
}

enum RestrictedInk {
    static let rules: [InkUseRule] = [
        InkUseRule(
            name: "rule 2 — blue is interaction only",
            tokens: ["interactive", "interactiveHover", "interactiveSoft", "interactiveSubtle",
                     "focusRing", "borderFocus"],
            rule: "Blue marks a thing you can click, focus, or have selected. It never carries "
                + "content meaning. A file that names one of these has to say what is clickable "
                + "about the thing it draws — `ProgressTrack` and `Spinner` defaulted to "
                + "Ink.interactive and nobody can click a progress bar.",
            permitted: [
                "ControlButton.swift": "the primary rank's fill, and tertiary's hover label",
                "ControlPill.swift": "PillStyle.selected — a selected filter IS interaction state",
                "ControlState.swift": "the focus ring every primitive draws, and borderFocus",
                "SurfaceRow.swift": "rowSelected — selection is interaction state",
                "SpokenLine.swift": "the wash under the line a search hit or an Ask citation "
                    + "scrolled to. Being the line you looked for is selection state; nothing "
                    + "about what was said changed",
                "EngineBar.swift": "the scope segment: rule 3's one permanent exemption, and it is "
                    + "permanent because the segment is genuinely a button",
                // The review surface. Its job is to DISPLAY the token, which is the one use no
                // amount of rule 2 can forbid — but it is also where blue kept being spent as
                // decoration, because until this scan reached the gallery nothing here was read.
                "InkCatalog.swift": "the token table itself — every blue in the system is a row "
                    + "here, in the contrast matrix, in a wash pairing or in a fill pairing",
                "RulesPane.swift": "the rule-2 card, which shows a permitted use (a selected row "
                    + "in interactiveSoft) beside a forbidden one (a speaker name in interactive), "
                    + "and the appearance-plumbing probe that draws `interactive` twice",
                "SurfacePane.swift": "the focus specimen — borderFocus at 1pt, drawn as the "
                    + "subject of the row",
            ]),
        InkUseRule(
            name: "textPlaceholder is not an ink for words that matter",
            tokens: ["textPlaceholder"],
            rule: "The ledger records textPlaceholder below 4.5 on EVERY surface (2.16:1 on layer "
                + "in light). `SpineBadge` rejected it for the absent tier and `InputField` "
                + "declares its prompt decorative; it reached 11pt load-bearing engine arm state "
                + "anyway. It may be named only where the thing it draws is genuinely decorative "
                + "or is not a word.",
            permitted: [
                "ControlField.swift": "the field prompt, declared decorative — a field's meaning "
                    + "lives in a label outside it",
                "SurfaceEmpty.swift": "the empty-state glyph: an icon, not a word",
                "InkCatalog.swift": "a row in the token table and a gated row in the contrast "
                    + "matrix — the measurement that says it is unusable",
                "PassageGallery.swift": "the REJECTED pairing, shown with its ratio: the absent "
                    + "badge was drawn in it and is not any more",
            ]),
        InkUseRule(
            name: "rule 3 — success is a deviation token, not a verdict tick",
            tokens: ["success", "successSoft"],
            rule: "`Ink.success` is declared inside the \"State — deviation only (rule 3)\" block. "
                + "Colour marks a DEPARTURE from the default, so the passing case is the silent "
                + "one — a green tick on every row that behaved is rule 3 run backwards, and it "
                + "ran backwards hardest in the surface that exhibits the rule: four panes drew "
                + "PASS / YES / DISTINCT / allowed in it. A verdict that passes takes a neutral; "
                + "only the failure departs, which also makes the failures the only colour on the "
                + "page. `danger` is deliberately NOT restricted here — a failure IS a deviation.",
            permitted: [
                "ControlPill.swift": "PillStyle.success — the wash under a state pill, spent by a "
                    + "screen that has a genuine deviation to report. The ink stays textPrimary",
                "InkCatalog.swift": "the token table, the contrast matrix, the wash pairing and "
                    + "the fill pairing — this is where the token is measured",
            ]),
    ]
}

// MARK: Forbidden pairings

/// A foreground that may not be drawn on a given wash AT ALL, and the files allowed to name both
/// halves anyway.
///
/// `Matrix` scores what the system PERMITS: a pairing in it either clears WCAG or is a ledger row
/// with its measured ratio. This is the other list, and the distinction is not bookkeeping — a
/// ledger row says "the system permits this and it fails", which for `textHelper` on a selection
/// wash is the wrong claim. Nothing should draw it. So the pairing stays OUT of the matrix and the
/// prohibition is enforced here instead, over the source.
///
/// WHAT THE CHECK CAN AND CANNOT PROVE. It cannot know which surface a `Text` sits on — this target
/// reads the design system as text (see `ThemeTokenSource` for the same trade). What it can prove is
/// narrower and still catches the real shape: a file that PAINTS the wash and also hands the
/// forbidden ink to a type modifier has to say which of its rows is which. That is over-broad by
/// construction — `SurfaceRow` and `RulesPane` both do it legitimately — which is why this is an
/// allow list with a reason per row, the same shape as `RestrictedInk` and `TextInk.notText`, and
/// why a stale row fails too. A component routing the ink through a `Tone`-valued property still
/// escapes, exactly as `TextInk`'s declared half does.
struct ForbiddenPairing {
    let foreground: String
    let wash: String
    /// Opaque surface → appearance → what the pairing measures there. "Forbidden" is a number, not
    /// a taste, and pinning it means a palette change that fixes the pairing deletes the row rather
    /// than leaving a prohibition nobody re-measured.
    let measured: [String: [Appearance: Double]]
    let instead: String
    let rule: String
    /// file name → why it names both halves without drawing one on the other.
    let permitted: [String: String]
}

enum ForbiddenInk {
    static let rules: [ForbiddenPairing] = [
        ForbiddenPairing(
            foreground: "textHelper",
            wash: "interactiveSoft",
            measured: [
                "background": [.light: 4.11, .dark: 4.16],
                "layer": [.light: 3.77, .dark: 3.46],
            ],
            instead: "textSecondary, which measures 6.40 / 5.86 light and 8.09 / 6.72 dark on the "
                + "same ground and is already in the matrix",
            rule: "A 12pt label needs 4.5:1 and textHelper does not reach it on the selection wash "
                + "in either appearance. It is the ordinary shape twice over: ListRow's subtitle "
                + "under a selected row, and SpokenLine's timestamp on the line a search just "
                + "scrolled to — the one row in the reader whose stamp most needs reading. Both "
                + "survived because the matrix never paired the two, and the second survived for "
                + "the extra reason that it lived in Sources/Viewer, which no gate reads.",
            permitted: [
                "SurfaceRow.swift": "the UNSELECTED row's subtitle. The selected branch steps up "
                    + "to textSecondary on the same line — the ternary IS the fix",
                "RulesPane.swift": "the rule-2 card draws a selected row in the wash; the "
                    + "textHelper captions sit under the specimens, on the card",
            ]),
    ]
}

// MARK: Rule 3

/// What each token the ANSWER SURFACES name is allowed to be.
///
/// Rule 3's claim is that a default-corpus, active, verified passage renders entirely monochrome.
/// A parser cannot walk the branches to prove reachability — that argument is human and is written
/// out in the test — but it can prove the half that actually rots: that every token these files
/// name is classified, and that every token on the default path is a NEUTRAL. A hue arriving on the
/// default path is then either an achromatic assertion failing or an unclassified token, and both
/// are loud.
enum RuleThree {
    /// The files a retrieved answer is drawn out of.
    static let surfaces = ["Passage.swift", "PassageSpine.swift", "PassageCard.swift",
                           "ExclusionBar.swift", "EngineBar.swift", "EngineEnvelope.swift"]

    /// Reachable when nothing has departed from the default. Every one must be R == G == B in both
    /// appearances — that is the whole of rule 3, mechanised.
    static let monochrome: Set<String> = [
        "layer", "layerHover", "layerAlt", "borderSubtle", "borderStrong",
        "textPrimary", "textSecondary", "textHelper",
    ]

    /// Allowed to carry hue, because reaching them means something departed. The value is the
    /// departure each one marks, so "why is this coloured" is answered next to the token.
    static let deviation: [String: String] = [
        "danger": "a reader could take this passage for settled fact; a stack arm could not start",
        "dangerSoft": "the wash under an unsettled badge",
        "warning": "an arm fell back mid-run; the index is frozen",
        "stale": "outside the default corpus, or no basis for a verdict",
        "staleSoft": "the wash under an excluded badge and an included chip",
    ]

    /// Rule 3's single stated exemption, and the reason it is stated rather than derived: under
    /// rule 3 a healthy engine is silent, so ONE anchor has to say the answer came from a named
    /// corpus that could have been a different one. That is the whole discoverability budget.
    static let exempt: [String: String] = [
        "interactive": "the Engine Bar scope segment",
        "interactiveSubtle": "the scope segment's fill",
    ]
}

// MARK: Tests

final class SystemRuleTests: XCTestCase {

    private var tokens: ThemeTokens!

    override func setUpWithError() throws {
        tokens = try ThemeTokens.loadFromRepository()
    }

    /// Rule 2, the placeholder ink, and `success`. Both directions are checked: a file naming a
    /// restricted token without a row fails, and a row whose file no longer names the token fails
    /// too — a stale permission is a permission nobody re-read.
    ///
    /// IT SCANS THE GALLERY. It read `components()` alone while `testFixedHeightsAreNamedAndJustified`
    /// two tests down read `files()`, so the review surface — the one place with no component author
    /// to answer for a token, and the place a rule is most expensive to break, because it is where
    /// the rule is TAUGHT — was structurally invisible to the gate written to catch exactly this.
    /// Blue was a spacing ruler, a measure cap, a motion mark and a hand-built primary button;
    /// `success` was a green tick on four panes. None of it was hidden. Nothing was looking.
    func testRestrictedTokensAreOnlyNamedWhereTheRuleAllows() throws {
        let files = try DesignSystemSource.drawing()
        var violations: [String] = []
        var stale: [String] = []
        var scanned = 0

        for rule in RestrictedInk.rules {
            var seen = Set<String>()
            for file in files {
                let named = Set(try ComponentInk.tokens(in: DesignSystemSource.code(file))
                    .flatMap(TextInk.expand))
                let hits = rule.tokens.filter { named.contains($0) }
                guard !hits.isEmpty else { continue }
                scanned += 1
                let name = file.lastPathComponent
                seen.insert(name)
                if rule.permitted[name] == nil {
                    violations.append("[\(rule.name)] \(name) names \(hits.sorted().joined(separator: ", "))"
                        + " — \(rule.rule)")
                }
            }
            for (name, why) in rule.permitted where !seen.contains(name) {
                stale.append("[\(rule.name)] \(name) is permitted for \"\(why)\" and no longer "
                    + "names any of \(rule.tokens.sorted().joined(separator: ", "))")
            }
        }

        XCTAssertTrue(violations.isEmpty, """
            \(violations.count) restricted-token use(s) with no permission:
            \(violations.sorted().joined(separator: "\n"))
            Move the token, or add the file to RestrictedInk with what it marks there.
            """)
        XCTAssertTrue(stale.isEmpty, """
            \(stale.count) stale permission(s) in RestrictedInk — delete the row:
            \(stale.sorted().joined(separator: "\n"))
            """)
        XCTAssertGreaterThanOrEqual(files.count, 30, "component + gallery files read")
        XCTAssertGreaterThanOrEqual(scanned, 12, "files matching a restricted token")
    }

    /// The use half of the prohibition. A file that paints the wash and draws the forbidden ink as
    /// type has to hold a permission saying which of its rows is which.
    ///
    /// This is what "the gate holds it" means for `SpokenLine`: the row now lives in the component
    /// layer, so putting `Ink.textHelper` back on its timestamp fails here with the rule printed,
    /// instead of being held by a comment in an app view no gate reads.
    func testNoFileDrawsAForbiddenInkOnAWashItPaints() throws {
        let files = try DesignSystemSource.drawing()
        var violations: [String] = []
        var stale: [String] = []
        var scanned = 0

        for rule in ForbiddenInk.rules {
            var seen = Set<String>()
            for file in files {
                let code = try DesignSystemSource.code(file)
                let named = Set(ComponentInk.tokens(in: code).flatMap(TextInk.expand))
                let drawn = Set(ComponentInk.drawnAsText(in: code).flatMap(TextInk.expand))
                guard named.contains(rule.wash), drawn.contains(rule.foreground) else { continue }
                scanned += 1
                let name = file.lastPathComponent
                seen.insert(name)
                if rule.permitted[name] == nil {
                    violations.append("\(name) paints \(rule.wash) and draws Ink.\(rule.foreground)"
                        + " as text — \(rule.rule) Use \(rule.instead).")
                }
            }
            for (name, why) in rule.permitted where !seen.contains(name) {
                stale.append("\(name) is permitted for \"\(why)\" and no longer both paints "
                    + "\(rule.wash) and draws Ink.\(rule.foreground)")
            }
        }

        XCTAssertTrue(violations.isEmpty, """
            \(violations.count) forbidden pairing(s) with no permission:
            \(violations.sorted().joined(separator: "\n"))
            Draw the safe ink, or add the file to ForbiddenInk with why the two never meet there.
            """)
        XCTAssertTrue(stale.isEmpty, """
            \(stale.count) stale permission(s) in ForbiddenInk — delete the row:
            \(stale.sorted().joined(separator: "\n"))
            """)
        XCTAssertGreaterThanOrEqual(scanned, 2, "files naming a forbidden wash and drawing its ink")
    }

    /// The number half. A prohibition is a measurement, so it drifts like a ledger row does — and a
    /// palette change that lifts the pairing over 4.5 makes the whole rule stale, permissions
    /// included.
    func testForbiddenPairingsStillMeasureBelowTheTextThreshold() throws {
        var drifted: [String] = []
        var checked = 0
        for rule in ForbiddenInk.rules {
            for (base, byAppearance) in rule.measured {
                for (appearance, recorded) in byAppearance {
                    checked += 1
                    let ground = Srgb.composite(try tokens.color(rule.wash, appearance),
                                                over: try tokens.color(base, appearance))
                    let measured = Srgb.contrast(try tokens.color(rule.foreground, appearance), ground)
                    let label = "\(rule.foreground) on \(rule.wash) over \(base) [\(appearance.rawValue)]"
                    if measured >= Wcag.bodyText {
                        drifted.append(String(format: "%@ — now %.2f:1, clears %.1f:1. The "
                                              + "prohibition is stale; delete it and its permissions.",
                                              label, measured, Wcag.bodyText))
                    } else if abs(measured - recorded) > 0.005 {
                        drifted.append(String(format: "%@ — recorded %.2f:1, now measures %.2f:1.",
                                              label, recorded, measured))
                    }
                }
            }
        }
        XCTAssertTrue(drifted.isEmpty, "forbidden pairings out of date:\n\(drifted.joined(separator: "\n"))")
        XCTAssertGreaterThanOrEqual(checked, 4, "forbidden measurements taken")
    }

    /// Rule 3, mechanised as far as a parser honestly can.
    ///
    /// THE HUMAN HALF, restated so a reviewer can re-run it: trace every branch that applies a tone
    /// to a default-corpus, ACTIVE, VERIFIED, reference-frozen passage. `PassageSpine` draws
    /// `Passage.spineAxes`; all four axes answer `.record`, whose fill is `layerAlt` and whose text
    /// is `textSecondary`. The snippet is `textPrimary`, provenance is `textSecondary` and
    /// `textHelper`, the card is `layer`, and its edge is `borderSubtle` because `withheldAs` is
    /// empty. Six tokens. The exclusion bar at its default adds `borderStrong` on the withheld
    /// chips, and `layerHover` under the pointer once those chips became real controls rather than
    /// a plain `Button` with no phase at all. Eight tokens, sixteen values.
    ///
    /// THE MECHANICAL HALF, which is what survives the next edit: every token these files name is
    /// classified, and every token classified as default-path is achromatic in both appearances.
    func testRuleThreeSurfacesAreClassifiedAndTheDefaultPathIsAchromatic() throws {
        let files = try DesignSystemSource.components()
            .filter { RuleThree.surfaces.contains($0.lastPathComponent) }
        XCTAssertEqual(files.count, RuleThree.surfaces.count,
                       "an answer-surface file was renamed or removed: \(files.map(\.lastPathComponent))")

        let classified = RuleThree.monochrome
            .union(RuleThree.deviation.keys)
            .union(RuleThree.exempt.keys)
        var named = Set<String>()
        for file in files {
            named.formUnion(try ComponentInk.tokens(in: DesignSystemSource.code(file))
                .flatMap(TextInk.expand))
        }

        let unclassified = named.subtracting(classified).sorted()
        XCTAssertTrue(unclassified.isEmpty, """
            \(unclassified.count) token(s) reach a rule-3 answer surface and are classified \
            nowhere: \(unclassified.joined(separator: ", ")).
            Put each in RuleThree.monochrome (it renders on the default path, and must be a \
            neutral), RuleThree.deviation with the departure it marks, or RuleThree.exempt — \
            which has two members and is the entire discoverability budget.
            """)

        let unused = classified.subtracting(named).sorted()
        XCTAssertTrue(unused.isEmpty,
                      "RuleThree classifies \(unused.joined(separator: ", ")), which no answer "
                        + "surface names any more. Delete the row.")

        var coloured: [String] = []
        for name in RuleThree.monochrome.sorted() {
            for appearance in Appearance.allCases {
                let c = try tokens.color(name, appearance)
                guard c.red != c.green || c.green != c.blue else { continue }
                coloured.append(String(format: "%@ [%@] — %.3f/%.3f/%.3f",
                                       name, appearance.rawValue, c.red, c.green, c.blue))
            }
        }
        XCTAssertTrue(coloured.isEmpty, """
            RULE 3 IS BROKEN. \(coloured.count) token(s) on the default answer path carry a hue, \
            so a default-corpus, active, verified passage is no longer monochrome:
            \(coloured.joined(separator: "\n"))
            """)

        XCTAssertGreaterThanOrEqual(named.count, 12,
                                    "tokens found on the answer surfaces: \(named.sorted())")
    }

    /// `Density` forbids `.frame(height:)` on anything with content, and the review surface that
    /// exhibits the rule was breaking it eight times.
    ///
    /// The enforceable form is NO NUMERIC LITERAL, not "no fixed height" — because the exemption a
    /// swatch genuinely needs is real: a colour band has nothing to clip, and being exactly one
    /// size in both appearance columns is its whole job. What is not real is an exemption spelled
    /// as a bare number, which is indistinguishable from the mistake it excuses. A named value
    /// (`Specimen.bandHeight`, `Gap.s6`, `Elevation.hairline`) or a passed-through identifier
    /// carries the reason with it; `34` carries nothing.
    func testFixedHeightsAreNamedAndJustified() throws {
        var bare: [String] = []
        var checked = 0
        for file in try DesignSystemSource.files() {
            for argument in Self.frameHeightArguments(in: try DesignSystemSource.code(file)) {
                checked += 1
                guard argument.first.map({ $0.isNumber || $0 == "." }) == true else { continue }
                bare.append("\(file.lastPathComponent) — .frame(height: \(argument))")
            }
        }
        XCTAssertTrue(bare.isEmpty, """
            \(bare.count) fixed height(s) spelled as a bare number:
            \(bare.sorted().joined(separator: "\n"))
            If it sizes anything with content in it, use .controlBox(_:) and a minimum. If it is a \
            measuring instrument, name it in the gallery's Specimen table.
            """)
        XCTAssertGreaterThanOrEqual(checked, 8, "`.frame(height:)` call sites found")
    }

    /// Every `height:` argument inside a `frame(` call, as written. Scoped to `frame(` on purpose:
    /// a window's `defaultSize` is not a view that can clip, and a rule that swept it in would be
    /// argued with rather than obeyed.
    private static func frameHeightArguments(in source: String) -> [String] {
        let chars = Array(source)
        var found: [String] = []
        var index = 0
        while let open = Self.next("frame(", in: chars, from: index) {
            let close = Self.matchingParen(chars, open)
            let call = String(chars[open..<close])
            if let label = call.range(of: "height:") {
                found.append(String(call[label.upperBound...])
                    .trimmingCharacters(in: .whitespaces)
                    .prefix(while: { $0 != "," && $0 != ")" })
                    .trimmingCharacters(in: .whitespaces))
            }
            index = close
        }
        return found
    }

    /// Index of the `(` that opens the next `frame(`, or nil.
    private static func next(_ needle: String, in chars: [Character], from start: Int) -> Int? {
        let pattern = Array(needle)
        var index = start
        while index + pattern.count <= chars.count {
            if Array(chars[index..<(index + pattern.count)]) == pattern {
                return index + pattern.count - 1
            }
            index += 1
        }
        return nil
    }

    private static func matchingParen(_ chars: [Character], _ open: Int) -> Int {
        var depth = 0
        var index = open
        while index < chars.count {
            if chars[index] == "(" { depth += 1 }
            if chars[index] == ")" {
                depth -= 1
                if depth == 0 { return index }
            }
            index += 1
        }
        return chars.count
    }
}
