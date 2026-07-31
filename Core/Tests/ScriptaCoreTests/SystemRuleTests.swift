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

    static func components() throws -> [URL] { try swiftFiles(in: "Sources/Theme/Components") }

    static func gallery() throws -> [URL] { try swiftFiles(in: "Sources/Gallery") }

    static func tokenLayer() -> [URL] {
        ["Ink", "Register", "Metrics", "Surface"].map {
            root.appendingPathComponent("Sources/Theme/\($0).swift")
        }
    }

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
                "EngineBar.swift": "the scope segment: rule 3's one permanent exemption, and it is "
                    + "permanent because the segment is genuinely a button",
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
        "layer", "layerAlt", "borderSubtle", "borderStrong",
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

    /// Rule 2, and the placeholder ink. Both directions are checked: a file naming a restricted
    /// token without a row fails, and a row whose file no longer names the token fails too — a
    /// stale permission is a permission nobody re-read.
    func testRestrictedTokensAreOnlyNamedWhereTheRuleAllows() throws {
        let files = try DesignSystemSource.components()
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
        XCTAssertGreaterThanOrEqual(files.count, 15, "component files read")
        XCTAssertGreaterThanOrEqual(scanned, 7, "files matching a restricted token")
    }

    /// Rule 3, mechanised as far as a parser honestly can.
    ///
    /// THE HUMAN HALF, restated so a reviewer can re-run it: trace every branch that applies a tone
    /// to a default-corpus, ACTIVE, VERIFIED, reference-frozen passage. `PassageSpine` draws
    /// `Passage.spineAxes`; all four axes answer `.record`, whose fill is `layerAlt` and whose text
    /// is `textSecondary`. The snippet is `textPrimary`, provenance is `textSecondary` and
    /// `textHelper`, the card is `layer`, and its edge is `borderSubtle` because `withheldAs` is
    /// empty. Six tokens. The exclusion bar at its default adds `borderStrong` on the withheld
    /// chips. Seven tokens, fourteen values.
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
