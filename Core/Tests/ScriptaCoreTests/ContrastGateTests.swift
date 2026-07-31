import Foundation
import XCTest

// MARK: - The contrast gate
//
// Every foreground/background pairing "Record & Register" permits, in both appearances, scored
// against WCAG 2.2 AA. It ships before the components that have to pass it, because a component
// built on a token that fails contrast is work done twice.
//
// HOW A FAILURE IS HANDLED. It is recorded, not excused. `Ledger.findings` carries every failing
// pair with the ratio it actually measures, and the suite asserts three things about it:
//
//   1. a pairing that fails and is NOT in the ledger fails the build — new breakage cannot land;
//   2. a ledgered pairing that no longer measures what was recorded fails the build — a token
//      cannot drift, better or worse, without someone looking;
//   3. a ledgered pairing that now PASSES fails the build — fixes force the row to be deleted.
//
// The number stands. What the ledger buys is that it cannot be forgotten, and it cannot be
// "fixed" by moving 4.5 to 3.0 — the required level is written next to every measurement.

// MARK: Matrix

/// A background: an opaque surface, optionally under a translucent wash.
struct Layer: Hashable {
    let base: String
    let wash: String?

    init(_ base: String, wash: String? = nil) {
        self.base = base
        self.wash = wash
    }

    var label: String { wash.map { "\($0) over \(base)" } ?? base }
}

struct Pairing {
    let foreground: String
    let background: Layer
    /// `nil` means measured and reported but never gated. Every `nil` states why on the spot —
    /// an ungated pairing with no stated reason is indistinguishable from an oversight.
    let required: Double?
    let ungatedBecause: String?

    init(_ foreground: String, on background: Layer, _ required: Double) {
        self.foreground = foreground
        self.background = background
        self.required = required
        self.ungatedBecause = nil
    }

    init(_ foreground: String, on background: Layer, ungated reason: String) {
        self.foreground = foreground
        self.background = background
        self.required = nil
        self.ungatedBecause = reason
    }

    func key(_ appearance: Appearance) -> String {
        "\(foreground) on \(background.label) [\(appearance.rawValue)]"
    }
}

enum Matrix {
    /// Opaque surfaces anything can be drawn on.
    static let surfaces = ["background", "layer", "layerHover", "layerSelected",
                           "layerAlt", "field", "fieldHover"]
    /// The two surfaces a selected or flagged row actually sits on, so washes are measured over
    /// something real rather than over nothing.
    static let washBases = ["background", "layer"]
    static let coloredParties = ["amber", "violet", "teal", "rose"]

    /// Tokens that are not one half of a foreground/background pairing. Listed rather than skipped,
    /// so `testEveryTokenParticipatesInTheGate` can prove the matrix covers the whole table.
    static let notAPairing: [String: String] = [
        "scrim": "dims arbitrary content beneath a sheet; there is no fixed pair to score",
        "overlayShadow": "a shadow colour, not a foreground or a surface",
        "borderFocus": "alias of interactive; measured as focusRing",
    ]

    static let all: [Pairing] = build()

    private static func build() -> [Pairing] {
        var pairings: [Pairing] = []

        for surface in surfaces {
            let layer = Layer(surface)
            pairings.append(Pairing("textPrimary", on: layer, Wcag.bodyText))
            pairings.append(Pairing("textSecondary", on: layer, Wcag.bodyText))
            pairings.append(Pairing("textHelper", on: layer, Wcag.bodyText))
            pairings.append(Pairing("textPlaceholder", on: layer, Wcag.bodyText))
            pairings.append(Pairing("textDisabled", on: layer,
                                    ungated: "WCAG 1.4.3 exempts text in an inactive control"))
            pairings.append(Pairing("iconPrimary", on: layer, Wcag.largeOrUI))
            pairings.append(Pairing("iconSecondary", on: layer, Wcag.largeOrUI))
        }

        for surface in ["background", "layer", "layerAlt", "field"] {
            pairings.append(Pairing("interactive", on: Layer(surface), Wcag.bodyText))
            pairings.append(Pairing("interactiveHover", on: Layer(surface), Wcag.bodyText))
        }

        for surface in ["background", "layer", "layerAlt"] {
            let layer = Layer(surface)
            pairings.append(Pairing("focusRing", on: layer, Wcag.largeOrUI))
            pairings.append(Pairing("borderStrong", on: layer, Wcag.largeOrUI))
            pairings.append(Pairing("borderSubtle", on: layer,
                                    ungated: "decorative separator between adjacent surfaces, not a control boundary — see testBorderTokensAreDistinguishableFromTheirSurface"))
            pairings.append(Pairing("danger", on: layer, Wcag.bodyText))
            pairings.append(Pairing("dangerHover", on: layer, Wcag.bodyText))
            pairings.append(Pairing("success", on: layer, Wcag.bodyText))
            pairings.append(Pairing("stale", on: layer, Wcag.bodyText))
            // Body text, not 3.0: `warning` is the tone of three marker WORDS in the capability
            // envelope. `TextInk` is what makes that non-negotiable — see the note above it.
            pairings.append(Pairing("warning", on: layer, Wcag.bodyText))
        }

        // Saturated fills. `textOnColor` is declared as "text drawn over a saturated fill, in
        // either appearance", so the vocabulary permits all of these — including the ones it
        // cannot survive, which is the point.
        pairings.append(Pairing("onInteractive", on: Layer("interactive"), Wcag.bodyText))
        pairings.append(Pairing("onInteractive", on: Layer("interactiveHover"), Wcag.bodyText))
        pairings.append(Pairing("textOnColor", on: Layer("danger"), Wcag.bodyText))
        pairings.append(Pairing("textOnColor", on: Layer("dangerHover"), Wcag.bodyText))
        pairings.append(Pairing("textOnColor", on: Layer("success"), Wcag.bodyText))
        pairings.append(Pairing("textOnColor", on: Layer("warning"), Wcag.bodyText))
        for party in coloredParties {
            pairings.append(Pairing("textOnColor", on: Layer("speaker.\(party)"), Wcag.bodyText))
        }

        for base in washBases {
            pairings.append(Pairing("textPrimary", on: Layer(base, wash: "interactiveSoft"), Wcag.bodyText))
            pairings.append(Pairing("textPrimary", on: Layer(base, wash: "interactiveSubtle"), Wcag.bodyText))
            pairings.append(Pairing("interactive", on: Layer(base, wash: "interactiveSoft"), Wcag.bodyText))
            pairings.append(Pairing("interactive", on: Layer(base, wash: "interactiveSubtle"), Wcag.bodyText))
            pairings.append(Pairing("danger", on: Layer(base, wash: "dangerSoft"), Wcag.bodyText))
            pairings.append(Pairing("success", on: Layer(base, wash: "successSoft"), Wcag.bodyText))
            pairings.append(Pairing("textPrimary", on: Layer(base, wash: "warningSoft"), Wcag.bodyText))
            pairings.append(Pairing("stale", on: Layer(base, wash: "staleSoft"), Wcag.bodyText))
            pairings.append(Pairing("speaker.me", on: Layer(base, wash: "speaker.meSoft"), Wcag.bodyText))
            pairings.append(Pairing("textPrimary", on: Layer(base, wash: "speaker.meSoft"), Wcag.bodyText))
            pairings.append(Pairing("textPrimary", on: Layer(base, wash: "sidebarTint"), Wcag.bodyText))
            pairings.append(Pairing("textSecondary", on: Layer(base, wash: "sidebarTint"), Wcag.bodyText))
            pairings.append(Pairing("textPrimary", on: Layer(base, wash: "titlebarTint"), Wcag.bodyText))
            pairings.append(Pairing("textSecondary", on: Layer(base, wash: "titlebarTint"), Wcag.bodyText))
        }

        for party in coloredParties {
            let ink = "speaker.\(party)"
            for surface in ["background", "layer", "layerAlt"] {
                pairings.append(Pairing(ink, on: Layer(surface), Wcag.bodyText))
            }
            for base in washBases {
                let layer = Layer(base, wash: "\(ink)Soft")
                pairings.append(Pairing(ink, on: layer, Wcag.bodyText))
                pairings.append(Pairing("textPrimary", on: layer, Wcag.bodyText))
            }
        }
        for surface in ["background", "layer", "layerAlt"] {
            pairings.append(Pairing("speaker.me", on: Layer(surface), Wcag.bodyText))
        }

        return pairings
    }
}

// MARK: Text tones
//
// THE GAP THIS CLOSES. `Matrix` scores PAIRINGS. It has no notion of what a token is used FOR, so
// one row covers a token drawn as a 1pt edge and the same token drawn as an 11pt word — and 3:1 is
// the right level for the first and nowhere near it for the second. That is not hypothetical:
// `Ink.warning` was gated at 3.0, failed at 1.53:1 on `layer` in light, was filed as a
// border-level finding, and shipped as the tone of three marker WORDS in the capability envelope.
// The pairing gate could not have caught it, because nothing ever told the pairing gate it was type.
//
// The mechanism is one rule: A TONE THE COMPONENTS DRAW WORDS IN MAY NOT BE GATED BELOW
// `Wcag.bodyText` ANYWHERE IN THE MATRIX. It measures nothing the matrix does not already measure;
// it forbids measuring it against the wrong number.
//
// WHAT IT STILL CANNOT SEE, stated rather than left as a hole. This target cannot import the app
// module, so it reads the design system as text (see ThemeTokenSource for the same trade). That
// splits the check in two, and only the first half is proof:
//
//   DERIVED — a literal `Ink.x` inside `.typeface(_:_:)`, `.microLabel(_:)` or `.proseText(_:_:)`.
//             It must be in `tones`, and no `notText` entry can excuse it.
//   DECLARED — a tone that reaches type through a `Tone`-valued property. `Ink.warning` gets there
//             via `EngineArmState.tone` and `EngineNote.tone`, `Ink.textOnColor` via
//             `ControlPalette.label`; this parser does not follow properties and will not pretend
//             to. What keeps the declaration honest is weaker: EVERY `Ink` token a component names
//             must be classified text or not-text with a reason, so a new one cannot arrive
//             unexamined — but a wrong classification is possible, and only a reader catches it.

enum TextInk {
    /// Tones that reach a `Text`. Six are derived from the component sources; the rest arrive
    /// through a `Tone`-valued property and are declared, with where they come from.
    static let tones: Set<String> = [
        // Derived — literal at a `.typeface` / `.microLabel` / `.proseText` call site.
        "textPrimary", "textSecondary", "textHelper", "textPlaceholder", "interactive", "stale",
        // Declared — `EngineArmState.tone` and `EngineNote.tone`, the envelope's marker words.
        "danger", "warning",
        // Declared — `ControlPalette.foreground(_:)`: every button, pill and field label.
        "onInteractive", "textOnColor", "textDisabled",
        // Declared — `PillStyle.me` / `PillStyle.speaker(_:)` labels.
        "speaker.me", "speaker.amber", "speaker.violet", "speaker.teal", "speaker.rose",
    ]

    /// Tones a component names but never draws a word in, and what they do instead. A reason
    /// rather than a bare list: "not text" is a claim about a component, and an unexplained one is
    /// indistinguishable from a token nobody looked at.
    static let notText: [String: String] = [
        "background": "Tone.clear — a fill that defers to whatever is behind the control",
        "layer": "surface fill",
        "layerAlt": "surface fill; the record-tier badge",
        "layerHover": "surface fill",
        "layerSelected": "surface fill",
        "field": "surface fill",
        "fieldHover": "surface fill",
        "borderSubtle": "hairline",
        "borderStrong": "control boundary",
        "borderFocus": "focus ring",
        "focusRing": "focus ring",
        "iconSecondary": "an SF Symbol, not a word — gated at 3.0 as a non-text mark",
        "interactiveHover": "fill under a pressed or hovered control",
        "dangerHover": "fill under a pressed or hovered destructive control",
        "interactiveSoft": "wash",
        "interactiveSubtle": "wash",
        "dangerSoft": "wash",
        "successSoft": "wash",
        "warningSoft": "wash",
        "staleSoft": "wash",
        "speaker.meSoft": "wash",
        "speaker.amberSoft": "wash",
        "speaker.violetSoft": "wash",
        "speaker.tealSoft": "wash",
        "speaker.roseSoft": "wash",
    ]

    /// `Ink.speaker.alt(_:)` hands out one of the four parties, so naming it is naming all four.
    static func expand(_ name: String) -> [String] {
        switch name {
        case "speaker.alt": return Matrix.coloredParties.map { "speaker.\($0)" }
        case "speaker.altSoft": return Matrix.coloredParties.map { "speaker.\($0)Soft" }
        default: return [name]
        }
    }
}

/// The component layer, read as text. Same bridge as `ThemeTokenSource` and the same cost: it
/// couples to the SHAPE of a call site, so a parse that quietly finds nothing would make the gate
/// vacuous — which is why the test asserts a floor on what it read.
enum ComponentInk {
    static func sources() throws -> [URL] {
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()   // ScriptaCoreTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // Core
            .deletingLastPathComponent()              // repository root
        let directory = root.appendingPathComponent("Sources/Theme/Components")
        let all = try FileManager.default.contentsOfDirectory(at: directory,
                                                              includingPropertiesForKeys: nil)
        return all.filter { $0.pathExtension == "swift" }.sorted { $0.path < $1.path }
    }

    /// Doc comments name tokens constantly ("`Ink.warning` is the intuitive choice and is wrong"),
    /// and a mention is not a use. Line comments only — the component layer has no block comments.
    static func withoutComments(_ source: String) -> String {
        source.components(separatedBy: .newlines).map(strip).joined(separator: "\n")
    }

    /// Every `Ink.x` / `Ink.speaker.x` the source names.
    static func tokens(in source: String) -> [String] {
        let chars = Array(source)
        var found: [String] = []
        var index = 0
        while index < chars.count {
            guard matches(chars, index, "Ink."),
                  index == 0 || !isIdentifier(chars[index - 1]) else {
                index += 1
                continue
            }
            index += 4
            var name = identifier(chars, &index)
            if name == "speaker", index < chars.count, chars[index] == "." {
                index += 1
                name = "speaker." + identifier(chars, &index)
            }
            if !name.isEmpty { found.append(name) }
        }
        return found
    }

    /// The derived half: tokens sitting inside a call that applies type. Balanced parens rather
    /// than end-of-line, so a ternary or a nested call is read whole.
    static func drawnAsText(in source: String) -> [String] {
        let chars = Array(source)
        var found: [String] = []
        for modifier in [".typeface(", ".microLabel(", ".proseText("] {
            var index = 0
            while index < chars.count {
                guard matches(chars, index, modifier) else {
                    index += 1
                    continue
                }
                let open = index + modifier.count - 1
                var depth = 0
                var end = open
                while end < chars.count {
                    if chars[end] == "(" { depth += 1 }
                    if chars[end] == ")" {
                        depth -= 1
                        if depth == 0 { break }
                    }
                    end += 1
                }
                found.append(contentsOf: tokens(in: String(chars[open..<min(end + 1, chars.count)])))
                index = end + 1
            }
        }
        return found
    }

    private static func strip(_ line: String) -> String {
        let chars = Array(line)
        var inString = false
        var index = 0
        var end = chars.count
        while index < chars.count {
            let character = chars[index]
            if inString {
                if character == "\\" { index += 2; continue }
                if character == "\"" { inString = false }
                index += 1
                continue
            }
            if character == "\"" { inString = true }
            else if character == "/", index + 1 < chars.count, chars[index + 1] == "/" {
                end = index
                break
            }
            index += 1
        }
        return String(chars[0..<end])
    }

    private static func matches(_ chars: [Character], _ index: Int, _ text: String) -> Bool {
        let needle = Array(text)
        guard index + needle.count <= chars.count else { return false }
        for offset in 0..<needle.count where chars[index + offset] != needle[offset] { return false }
        return true
    }

    private static func isIdentifier(_ character: Character) -> Bool {
        character.isLetter || character.isNumber || character == "_"
    }

    private static func identifier(_ chars: [Character], _ index: inout Int) -> String {
        var out = ""
        while index < chars.count, isIdentifier(chars[index]) {
            out.append(chars[index])
            index += 1
        }
        return out
    }
}

// MARK: Ledger

enum FindingCause: String {
    case placeholderInk
    case helperInkOffBaseSurface
    case noDarkOnColorToken
    case darkFillsAreTextTints
    case softWashErodesSameHueInk
    case sixtyLevelInkNotBodyCapable
    case layerAltDarkTooClose
    case borderSubtleVanishesOnLayerAlt

    /// What is actually wrong, and what fixing it would take. A ledger row without this is a
    /// number nobody can act on.
    var explanation: String {
        switch self {
        case .placeholderInk:
            return "textPlaceholder is gray40/gray60 — Carbon's own value, and below 4.5 on every surface. Either it gains a step of contrast or the system states that a placeholder may never carry information the label does not."
        case .helperInkOffBaseSurface:
            return "textHelper (gray60/gray50) is tuned against background and layer. On the hover/selected/alt steps it falls under 4.5, so helper text inside a hovered or selected row is out of spec."
        case .noDarkOnColorToken:
            return "the only on-fill foreground is white. success, warning's dark ink and the speaker tints are too light to hold it, and the 40/30-level dark tints are text colours being asked to act as fills. A dark-on-colour token, or a rule that these are never filled, closes this."
        case .darkFillsAreTextTints:
            return "in dark appearance interactive/danger drop to the 50/40 levels — tints chosen to be readable ON dark, not to be drawn on. White on them lands between 2.3 and 3.4."
        case .softWashErodesSameHueInk:
            return "a 14-16% wash of the same hue lifts the background toward the ink, costing roughly 0.5-1.5:1 versus the same ink on the bare surface. Same-hue badge patterns (wash + coloured ink) are the system's most common shape and its weakest."
        case .sixtyLevelInkNotBodyCapable:
            return "amber60 and green50 are Carbon's fill-level steps, not its text-level steps. Carbon's own text-capable equivalents are orange-60 #BA4E00 and green-60 #198038."
        case .layerAltDarkTooClose:
            return "layerAlt resolves to gray80 in dark, two steps lighter than layer. Colour inks that clear 4.5 on layer do not clear it here."
        case .borderSubtleVanishesOnLayerAlt:
            return "borderSubtle and layerAlt are both gray80 in dark appearance: the border is not low-contrast, it is the same colour. A card on layerAlt has no edge at all."
        }
    }
}

struct Finding {
    let foreground: String
    let background: String
    let appearance: Appearance
    let measured: Double
    let required: Double
    let cause: FindingCause

    init(_ foreground: String, on background: String, _ appearance: Appearance,
         measured: Double, required: Double, cause: FindingCause) {
        self.foreground = foreground
        self.background = background
        self.appearance = appearance
        self.measured = measured
        self.required = required
        self.cause = cause
    }

    var key: String { "\(foreground) on \(background) [\(appearance.rawValue)]" }
}

enum Ledger {
    /// Every pairing the token layer permits and does not survive, at the ratio it measures.
    /// Measured 2026-07-30 against Sources/Theme/Ink.swift as first landed.
    ///
    /// `warningLacksLightInk` was here and is gone: `warning` gained a light-appearance ink
    /// (yellow60), so the three foreground rows now measure 4.99 / 4.53 / 4.99 and the light
    /// `textOnColor` row clears 4.5 as well. The one survivor — white on yellow30 in dark — is a
    /// missing dark-on-colour token, which is what it always was.
    static let findings: [Finding] = [
        // --- darkFillsAreTextTints (4) ---
        Finding("onInteractive", on: "interactive", .dark, measured: 3.35, required: 4.5, cause: .darkFillsAreTextTints),
        Finding("onInteractive", on: "interactiveHover", .dark, measured: 2.35, required: 4.5, cause: .darkFillsAreTextTints),
        Finding("textOnColor", on: "danger", .dark, measured: 3.35, required: 4.5, cause: .darkFillsAreTextTints),
        Finding("textOnColor", on: "dangerHover", .dark, measured: 2.93, required: 4.5, cause: .darkFillsAreTextTints),

        // --- helperInkOffBaseSurface (7) ---
        Finding("textHelper", on: "fieldHover", .dark, measured: 3.81, required: 4.5, cause: .helperInkOffBaseSurface),
        Finding("textHelper", on: "fieldHover", .light, measured: 4.10, required: 4.5, cause: .helperInkOffBaseSurface),
        Finding("textHelper", on: "layerAlt", .dark, measured: 3.48, required: 4.5, cause: .helperInkOffBaseSurface),
        Finding("textHelper", on: "layerHover", .dark, measured: 3.81, required: 4.5, cause: .helperInkOffBaseSurface),
        Finding("textHelper", on: "layerHover", .light, measured: 4.10, required: 4.5, cause: .helperInkOffBaseSurface),
        Finding("textHelper", on: "layerSelected", .dark, measured: 3.48, required: 4.5, cause: .helperInkOffBaseSurface),
        Finding("textHelper", on: "layerSelected", .light, measured: 3.81, required: 4.5, cause: .helperInkOffBaseSurface),

        // --- layerAltDarkTooClose (5) ---
        Finding("borderStrong", on: "layerAlt", .dark, measured: 2.30, required: 3.0, cause: .layerAltDarkTooClose),
        Finding("danger", on: "layerAlt", .dark, measured: 3.44, required: 4.5, cause: .layerAltDarkTooClose),
        Finding("dangerHover", on: "layerAlt", .dark, measured: 3.94, required: 4.5, cause: .layerAltDarkTooClose),
        Finding("interactive", on: "layerAlt", .dark, measured: 3.45, required: 4.5, cause: .layerAltDarkTooClose),
        Finding("speaker.violet", on: "layerAlt", .dark, measured: 3.45, required: 4.5, cause: .layerAltDarkTooClose),

        // --- noDarkOnColorToken (8) ---
        Finding("textOnColor", on: "warning", .dark, measured: 1.68, required: 4.5, cause: .noDarkOnColorToken),
        Finding("textOnColor", on: "speaker.amber", .dark, measured: 2.32, required: 4.5, cause: .noDarkOnColorToken),
        Finding("textOnColor", on: "speaker.amber", .light, measured: 3.56, required: 4.5, cause: .noDarkOnColorToken),
        Finding("textOnColor", on: "speaker.rose", .dark, measured: 2.36, required: 4.5, cause: .noDarkOnColorToken),
        Finding("textOnColor", on: "speaker.teal", .dark, measured: 1.70, required: 4.5, cause: .noDarkOnColorToken),
        Finding("textOnColor", on: "speaker.violet", .dark, measured: 3.35, required: 4.5, cause: .noDarkOnColorToken),
        Finding("textOnColor", on: "success", .dark, measured: 2.39, required: 4.5, cause: .noDarkOnColorToken),
        Finding("textOnColor", on: "success", .light, measured: 3.35, required: 4.5, cause: .noDarkOnColorToken),

        // --- placeholderInk (14) ---
        Finding("textPlaceholder", on: "background", .dark, measured: 3.60, required: 4.5, cause: .placeholderInk),
        Finding("textPlaceholder", on: "background", .light, measured: 2.38, required: 4.5, cause: .placeholderInk),
        Finding("textPlaceholder", on: "field", .dark, measured: 3.01, required: 4.5, cause: .placeholderInk),
        Finding("textPlaceholder", on: "field", .light, measured: 2.16, required: 4.5, cause: .placeholderInk),
        Finding("textPlaceholder", on: "fieldHover", .dark, measured: 2.51, required: 4.5, cause: .placeholderInk),
        Finding("textPlaceholder", on: "fieldHover", .light, measured: 1.94, required: 4.5, cause: .placeholderInk),
        Finding("textPlaceholder", on: "layer", .dark, measured: 3.01, required: 4.5, cause: .placeholderInk),
        Finding("textPlaceholder", on: "layer", .light, measured: 2.16, required: 4.5, cause: .placeholderInk),
        Finding("textPlaceholder", on: "layerAlt", .dark, measured: 2.30, required: 4.5, cause: .placeholderInk),
        Finding("textPlaceholder", on: "layerAlt", .light, measured: 2.38, required: 4.5, cause: .placeholderInk),
        Finding("textPlaceholder", on: "layerHover", .dark, measured: 2.51, required: 4.5, cause: .placeholderInk),
        Finding("textPlaceholder", on: "layerHover", .light, measured: 1.94, required: 4.5, cause: .placeholderInk),
        Finding("textPlaceholder", on: "layerSelected", .dark, measured: 2.30, required: 4.5, cause: .placeholderInk),
        Finding("textPlaceholder", on: "layerSelected", .light, measured: 1.80, required: 4.5, cause: .placeholderInk),

        // --- sixtyLevelInkNotBodyCapable (6) ---
        Finding("speaker.amber", on: "background", .light, measured: 3.56, required: 4.5, cause: .sixtyLevelInkNotBodyCapable),
        Finding("speaker.amber", on: "layer", .light, measured: 3.24, required: 4.5, cause: .sixtyLevelInkNotBodyCapable),
        Finding("speaker.amber", on: "layerAlt", .light, measured: 3.56, required: 4.5, cause: .sixtyLevelInkNotBodyCapable),
        Finding("success", on: "background", .light, measured: 3.35, required: 4.5, cause: .sixtyLevelInkNotBodyCapable),
        Finding("success", on: "layer", .light, measured: 3.05, required: 4.5, cause: .sixtyLevelInkNotBodyCapable),
        Finding("success", on: "layerAlt", .light, measured: 3.35, required: 4.5, cause: .sixtyLevelInkNotBodyCapable),

        // --- softWashErodesSameHueInk (22) ---
        Finding("danger", on: "dangerSoft over background", .dark, measured: 4.48, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("danger", on: "dangerSoft over background", .light, measured: 3.99, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("danger", on: "dangerSoft over layer", .dark, measured: 3.73, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("danger", on: "dangerSoft over layer", .light, measured: 3.65, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("interactive", on: "interactiveSoft over background", .dark, measured: 4.13, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("interactive", on: "interactiveSoft over background", .light, measured: 4.09, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("interactive", on: "interactiveSoft over layer", .dark, measured: 3.43, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("interactive", on: "interactiveSoft over layer", .light, measured: 3.75, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("interactive", on: "interactiveSubtle over layer", .dark, measured: 3.81, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("speaker.amber", on: "speaker.amberSoft over background", .light, measured: 3.00, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("speaker.amber", on: "speaker.amberSoft over layer", .light, measured: 2.75, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("speaker.rose", on: "speaker.roseSoft over background", .light, measured: 4.04, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("speaker.rose", on: "speaker.roseSoft over layer", .light, measured: 3.70, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("speaker.teal", on: "speaker.tealSoft over background", .light, measured: 4.12, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("speaker.teal", on: "speaker.tealSoft over layer", .light, measured: 3.77, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("speaker.violet", on: "speaker.violetSoft over background", .dark, measured: 4.39, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("speaker.violet", on: "speaker.violetSoft over layer", .dark, measured: 3.64, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("speaker.violet", on: "speaker.violetSoft over layer", .light, measured: 4.23, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("stale", on: "staleSoft over background", .light, measured: 4.31, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("stale", on: "staleSoft over layer", .light, measured: 3.95, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("success", on: "successSoft over background", .light, measured: 2.87, required: 4.5, cause: .softWashErodesSameHueInk),
        Finding("success", on: "successSoft over layer", .light, measured: 2.63, required: 4.5, cause: .softWashErodesSameHueInk),
    ]

    /// `uniquingKeysWith` rather than `uniqueKeysWithValues`: a duplicated row is a mistake worth a
    /// named test failure, not a trap inside a dictionary initialiser.
    static let byKey: [String: Finding] = Dictionary(findings.map { ($0.key, $0) },
                                                     uniquingKeysWith: { first, _ in first })
}

// MARK: Tests

final class ContrastGateTests: XCTestCase {

    private var tokens: ThemeTokens!

    override func setUpWithError() throws {
        tokens = try ThemeTokens.loadFromRepository()
    }

    private func ratio(_ pairing: Pairing, _ appearance: Appearance) throws -> Double {
        var background = try tokens.color(pairing.background.base, appearance)
        if let wash = pairing.background.wash {
            background = Srgb.composite(try tokens.color(wash, appearance), over: background)
        }
        return Srgb.contrast(try tokens.color(pairing.foreground, appearance), background)
    }

    /// The matrix is built by nested loops, so it is easy to state a pairing twice and never
    /// notice — and a duplicate would make the ledger's uniqueness meaningless.
    func testMatrixStatesEachPairingOnce() {
        var seen = Set<String>()
        var duplicates: [String] = []
        for pairing in Matrix.all {
            let key = pairing.key(.light)
            if !seen.insert(key).inserted { duplicates.append(key) }
        }
        XCTAssertTrue(duplicates.isEmpty, "duplicated pairings: \(duplicates.joined(separator: ", "))")
        // A floor, so a refactor that guts the loops leaves every gate above passing vacuously.
        XCTAssertGreaterThanOrEqual(Matrix.all.count, 140,
                                    "the matrix shrank — a gate over 3 pairings passes for the wrong reason")
    }

    func testLedgerStatesEachFindingOnce() {
        var seen = Set<String>()
        var duplicates: [String] = []
        for finding in Ledger.findings where !seen.insert(finding.key).inserted {
            duplicates.append(finding.key)
        }
        XCTAssertTrue(duplicates.isEmpty, "duplicated ledger rows: \(duplicates.joined(separator: ", "))")
    }

    /// The gate. A pairing that fails and is not already recorded is new breakage.
    func testEveryPermittedPairingMeetsWcagUnlessItIsARecordedFinding() throws {
        var unrecorded: [String] = []
        for pairing in Matrix.all {
            guard let required = pairing.required else { continue }
            for appearance in Appearance.allCases {
                let measured = try ratio(pairing, appearance)
                guard measured < required else { continue }
                let key = pairing.key(appearance)
                if Ledger.byKey[key] == nil {
                    unrecorded.append(String(format: "%@ — %.2f:1, needs %.1f:1", key, measured, required))
                }
            }
        }
        XCTAssertTrue(unrecorded.isEmpty, """
            \(unrecorded.count) pairing(s) fail WCAG AA and are not in Ledger.findings. \
            Fix the token or add the row with its measured ratio — do not lower the required level.
            \(unrecorded.joined(separator: "\n"))
            """)
    }

    /// The ledger is pinned to the numbers, so a token cannot drift in either direction unnoticed
    /// and a fix cannot leave a stale row behind claiming the system is still broken.
    func testRecordedFindingsStillMeasureExactlyWhatWasRecorded() throws {
        let byKey = Dictionary(Matrix.all.flatMap { pairing in
            Appearance.allCases.map { (pairing.key($0), (pairing, $0)) }
        }, uniquingKeysWith: { first, _ in first })

        var drifted: [String] = []
        for finding in Ledger.findings {
            guard let (pairing, appearance) = byKey[finding.key] else {
                drifted.append("\(finding.key) — recorded, but the matrix no longer contains this pairing")
                continue
            }
            let measured = try ratio(pairing, appearance)
            if measured >= finding.required {
                drifted.append(String(format: "%@ — now %.2f:1, clears %.1f:1. Delete this row.",
                                      finding.key, measured, finding.required))
            } else if abs(measured - finding.measured) > 0.005 {
                drifted.append(String(format: "%@ — recorded %.2f:1, now measures %.2f:1.",
                                      finding.key, finding.measured, measured))
            }
        }
        XCTAssertTrue(drifted.isEmpty, "ledger out of date:\n\(drifted.joined(separator: "\n"))")
    }

    /// The size-aware half of the gate. A tone the components draw WORDS in cannot be scored at
    /// the 3:1 non-text level anywhere, because 3:1 is a number about edges and icons.
    ///
    /// An explicitly ungated pairing is allowed through: `Pairing(ungated:)` demands a reason at
    /// construction, so the exemption is on the record rather than implied by a low number —
    /// `textDisabled` is the only one, under 1.4.3's inactive-control exemption.
    func testTonesDrawnAsTextAreNeverGatedBelowTheTextThreshold() {
        var underGated: [String] = []
        var unscored = TextInk.tones
        for pairing in Matrix.all where TextInk.tones.contains(pairing.foreground) {
            unscored.remove(pairing.foreground)
            guard let required = pairing.required, required < Wcag.bodyText else { continue }
            underGated.append(String(format: "%@ on %@ — gated at %.1f:1, but it is type",
                                     pairing.foreground, pairing.background.label, required))
        }
        XCTAssertTrue(underGated.isEmpty, """
            \(underGated.count) pairing(s) draw text and are gated below \(Wcag.bodyText):
            \(underGated.joined(separator: "\n"))
            Raise the pairing to Wcag.bodyText, or take the tone out of TextInk.tones because \
            nothing draws words in it.
            """)
        XCTAssertTrue(unscored.isEmpty, """
            \(unscored.count) text tone(s) are never scored as a foreground in the matrix: \
            \(unscored.sorted().joined(separator: ", ")). The threshold above them is vacuous.
            """)
    }

    /// Keeps `TextInk` honest against the code it describes. Every `Ink` token the component layer
    /// NAMES has to be classified; every token it draws type with has to be classified as text.
    ///
    /// The second half is the derived one and cannot be argued with — a literal inside
    /// `.typeface(_:_:)` is type by definition. The first half is what stops the declared half
    /// going stale: a component reaching for a token nobody has classified fails here.
    func testEveryInkTheComponentLayerNamesIsClassified() throws {
        let files = try ComponentInk.sources()
        var unclassified: [String] = []
        var undeclaredText: [String] = []
        var named = Set<String>()
        var drawn = Set<String>()
        for file in files {
            let source = ComponentInk.withoutComments(try String(contentsOf: file, encoding: .utf8))
            let name = file.lastPathComponent
            for token in ComponentInk.tokens(in: source).flatMap(TextInk.expand) {
                named.insert(token)
                guard !TextInk.tones.contains(token), TextInk.notText[token] == nil else { continue }
                unclassified.append("\(name) — Ink.\(token)")
            }
            for token in ComponentInk.drawnAsText(in: source).flatMap(TextInk.expand) {
                drawn.insert(token)
                guard !TextInk.tones.contains(token) else { continue }
                undeclaredText.append("\(name) — Ink.\(token)")
            }
        }
        XCTAssertTrue(unclassified.isEmpty, """
            \(unclassified.count) token(s) are used by a component and classified nowhere:
            \(Set(unclassified).sorted().joined(separator: "\n"))
            Add each to TextInk.tones, or to TextInk.notText with what it does instead.
            """)
        XCTAssertTrue(undeclaredText.isEmpty, """
            \(undeclaredText.count) token(s) are handed to a type modifier and are not in \
            TextInk.tones:
            \(Set(undeclaredText).sorted().joined(separator: "\n"))
            """)

        // A scan that silently found nothing passes both assertions above, so the floors are the
        // load-bearing part: files read, tokens recognised, and type call sites recognised.
        XCTAssertGreaterThanOrEqual(files.count, 15, "component files read")
        XCTAssertGreaterThanOrEqual(named.count, 35, "distinct Ink tokens found: \(named.sorted())")
        XCTAssertGreaterThanOrEqual(drawn.count, 6, "distinct text tones found: \(drawn.sorted())")

        let classified = TextInk.tones.union(TextInk.notText.keys)
        let stale = classified.filter { tokens.tones[$0] == nil }.sorted()
        XCTAssertTrue(stale.isEmpty,
                      "TextInk classifies \(stale.joined(separator: ", ")), which Ink.swift no longer declares")
    }

    /// "The WHOLE token table" has to be provable, not asserted. Every token `Ink.swift` declares
    /// either takes part in a pairing or is listed as not being one, with a reason.
    func testEveryTokenParticipatesInTheGate() throws {
        var used = Set<String>()
        for pairing in Matrix.all {
            used.insert(pairing.foreground)
            used.insert(pairing.background.base)
            if let wash = pairing.background.wash { used.insert(wash) }
        }
        used.formUnion(Matrix.notAPairing.keys)

        let missing = tokens.tones.keys.filter { !used.contains($0) }.sorted()
        XCTAssertTrue(missing.isEmpty, """
            \(missing.count) token(s) in Ink.swift take no part in the contrast gate: \
            \(missing.joined(separator: ", ")). Add a pairing, or add them to Matrix.notAPairing \
            with the reason they are not one.
            """)
    }

    /// A hairline you cannot see is a drawing bug before it is an accessibility one. 1.15 is not a
    /// WCAG level and is not pretending to be — it is the floor below which two tokens are the
    /// same colour.
    func testBorderTokensAreDistinguishableFromTheirSurface() throws {
        let floor = 1.15
        var invisible: [String] = []
        for border in ["borderSubtle", "borderStrong"] {
            for surface in ["background", "layer", "layerAlt"] {
                for appearance in Appearance.allCases {
                    let measured = Srgb.contrast(try tokens.color(border, appearance),
                                                 try tokens.color(surface, appearance))
                    guard measured < floor else { continue }
                    invisible.append(String(format: "%@ on %@ [%@] — %.2f:1",
                                            border, surface, appearance.rawValue, measured))
                }
            }
        }
        XCTAssertEqual(invisible, ["borderSubtle on layerAlt [dark] — 1.00:1"], """
            border visibility changed. \(FindingCause.borderSubtleVanishesOnLayerAlt.explanation)
            """)
    }

    /// The parser is the bridge across the module boundary, so a parse that quietly returns
    /// nothing would turn every assertion above into a vacuous pass. Anchors, not a second copy of
    /// the table: three values that could only be right if the parse worked.
    func testTokenSourceParsesCompletely() throws {
        XCTAssertGreaterThanOrEqual(tokens.ramp.count, 40, "Ramp entries found in \(tokens.sourcePath)")
        XCTAssertGreaterThanOrEqual(tokens.tones.count, 47, "Tone tokens found in \(tokens.sourcePath)")

        let interactive = try tokens.color("interactive", .light)
        XCTAssertEqual(interactive.red, 15.0 / 255, accuracy: 0.001)
        XCTAssertEqual(interactive.green, 98.0 / 255, accuracy: 0.001)
        XCTAssertEqual(interactive.blue, 254.0 / 255, accuracy: 0.001)

        // `.at(_:)` has to survive the parse or every wash measurement is wrong.
        XCTAssertEqual(try tokens.color("interactiveSoft", .dark).alpha, 0.20, accuracy: 0.0001)

        // The appearance-invariant `Tone(_:)` form.
        XCTAssertEqual(try tokens.color("textOnColor", .light), try tokens.color("textOnColor", .dark))

        // Alias resolution: `borderFocus = interactive`.
        XCTAssertEqual(tokens.tones["borderFocus"], tokens.tones["interactive"])
    }

    /// The `speaker.` prefix used to latch on at `enum speaker` and never turn off, so any `Tone`
    /// declared after that block anywhere in the file would be filed under a prefix it does not
    /// have — and then be missing under its real name, which reads as "the token was deleted".
    /// Nothing in `Ink.swift` sits there today, which is exactly why this is worth pinning.
    func testSpeakerPrefixEndsWithTheSpeakerBlock() throws {
        let source = """
            enum Ramp {
                static let red = rgb(0xFF0000)
            }
            enum Ink {
                enum speaker {
                    static let me = Tone(Ramp.red)
                }
                static let afterTheBlock = Tone(Ramp.red)
            }
            """
        let parsed = try ThemeTokens.parse(source, path: "<synthetic>")
        XCTAssertNotNil(parsed.tones["speaker.me"], "a token inside the block lost its prefix")
        XCTAssertNotNil(parsed.tones["afterTheBlock"],
                        "a token declared after the block was filed under `speaker.`")
        XCTAssertNil(parsed.tones["speaker.afterTheBlock"])
    }

    /// Not a WCAG gate — there is no standard for how far one surface must sit from the next. It
    /// is a drift detector on numbers that matter anyway: `layer` sits 1.10:1 from `background` in
    /// light, so a card is delimited almost entirely by a border that is itself 1.32:1. Neither is
    /// a failure alone; together they are why a card can read as absent. Pinning them means a
    /// future palette change to the neutral ramp cannot quietly flatten the stack further.
    func testSurfaceStepsHaveNotDrifted() throws {
        let recorded: [(String, String, Appearance, Double)] = [
            ("layer", "background", .light, 1.10), ("layer", "background", .dark, 1.20),
            ("layerAlt", "layer", .light, 1.10), ("layerAlt", "layer", .dark, 1.31),
            ("layerSelected", "layer", .light, 1.20), ("layerSelected", "layer", .dark, 1.31),
            ("layerHover", "layer", .light, 1.11), ("layerHover", "layer", .dark, 1.20),
            ("field", "background", .light, 1.10), ("field", "background", .dark, 1.20),
        ]
        for (upper, lower, appearance, expected) in recorded {
            let measured = Srgb.contrast(try tokens.color(upper, appearance),
                                         try tokens.color(lower, appearance))
            XCTAssertEqual(measured, expected, accuracy: 0.005,
                           "surface step \(upper)/\(lower) [\(appearance.rawValue)] moved")
        }
    }
}
