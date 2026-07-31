import AppKit
import SwiftUI

// MARK: - Record & Register: the color layer
//
// Three rules govern every token in this file. A component that breaks one is wrong even when it
// compiles, so they are stated here rather than in a doc nobody opens.
//
// 1. Three type registers, one job each — prose / UI / mono. See `Register`.
//
// 2. BLUE IS INTERACTION ONLY. `Ink.interactive*` marks a thing you can click, focus, or have
//    selected. It never carries content meaning. This is the exact rule whose absence produced
//    `Carbon.orange` declared as "Them" while the reader drew the same speaker in system
//    `Color.orange` — a content meaning parked on a chrome token drifts the moment a second
//    author needs it.
//
// 3. COLOR MARKS DEVIATION. A default-corpus, active, verified passage is entirely monochrome.
//    Every colored pixel means something departed from the default; that is what keeps the spine
//    visible without noise and the capability envelope from reading as an upsell. Known cost,
//    accepted deliberately: a healthy engine and a default result set are almost silent. ONE
//    anchor is exempt and must never be silent — the Engine Bar's scope segment, which carries
//    `interactive` permanently because it is genuinely a control. That is the whole
//    discoverability budget. Do not spend it anywhere else.

/// A color token. The `NSColor` is the source of truth and the SwiftUI `Color` derives from it,
/// never the reverse — that is what lets AppKit chrome and SwiftUI views share one definition.
/// `MenuController` hand-copies three hex pairs today precisely because the SwiftUI side owns the
/// values; `tone.ns` is what removes that copy.
///
/// Conforms to `ShapeStyle`, so `.foregroundStyle(Ink.textPrimary)`, `.fill(Ink.layer)` and
/// `.strokeBorder(Ink.borderSubtle)` all take a token directly. Use `.color` only where a literal
/// `Color` is required (`.shadow(color:)`, `.tint(_:)`, existing `Color`-typed component params).
struct Tone: ShapeStyle {
    let light: NSColor
    let dark: NSColor

    /// Appearance-resolving color: the block re-runs per drawing appearance, so one instance is
    /// correct in both themes *and* inside a per-view `.preferredColorScheme` override — which a
    /// pre-resolved color silently would not be.
    let ns: NSColor

    init(light: NSColor, dark: NSColor) {
        self.light = light
        self.dark = dark
        self.ns = NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
        }
    }

    /// A token that does not change between appearances (white on a blue fill, for instance).
    init(_ both: NSColor) { self.init(light: both, dark: both) }

    var color: Color { Color(nsColor: ns) }

    /// Resolving to `Color` rather than `Color.Resolved` hands appearance resolution back to
    /// SwiftUI, so `.foregroundStyle(Ink.x)` and `.foregroundStyle(Ink.x.color)` cannot diverge.
    func resolve(in environment: EnvironmentValues) -> Color { color }

    /// Multiplies the existing alpha instead of replacing it, so softening an already-soft token
    /// composes rather than silently turning it opaque.
    func opacity(_ factor: CGFloat) -> Tone {
        Tone(light: light.withAlphaComponent(light.alphaComponent * factor),
             dark: dark.withAlphaComponent(dark.alphaComponent * factor))
    }

    /// For AppKit call sites that already hold an appearance (custom `NSView` drawing).
    func resolved(for appearance: NSAppearance) -> NSColor {
        appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua ? dark : light
    }
}

// MARK: - Raw ramp

/// Palette values with no meaning attached. Nothing outside `Ink` should reference these: a view
/// reaching for `Ramp.blue60` is a view that has decided what blue means, which is rule 2's
/// failure mode.
enum Ramp {
    // Carbon neutrals. `*Hover` are Carbon's own hover derivatives, not eyeballed shifts.
    static let white = rgb(0xFFFFFF)
    static let gray10 = rgb(0xF4F4F4)
    static let gray10Hover = rgb(0xE8E8E8)
    static let gray20 = rgb(0xE0E0E0)
    static let gray30 = rgb(0xC6C6C6)
    static let gray40 = rgb(0xA8A8A8)
    static let gray50 = rgb(0x8D8D8D)
    static let gray60 = rgb(0x6F6F6F)
    static let gray70 = rgb(0x525252)
    static let gray80 = rgb(0x393939)
    static let gray90 = rgb(0x262626)
    static let gray90Hover = rgb(0x333333)
    static let gray100 = rgb(0x161616)
    static let black = rgb(0x000000)

    static let blue10 = rgb(0xEDF5FF)
    static let blue40 = rgb(0x78A9FF)
    static let blue50 = rgb(0x4589FF)
    static let blue60 = rgb(0x0F62FE)
    static let blue70 = rgb(0x0353E9)

    static let red50 = rgb(0xFA4D56)
    static let red50Hover = rgb(0xFF6169)
    static let red60 = rgb(0xDA1E28)
    static let red60Hover = rgb(0xBA1B23)
    static let green40 = rgb(0x42BE65)
    static let green50 = rgb(0x24A148)
    static let yellow30 = rgb(0xF1C21B)
    /// The caution ramp's text-capable step. yellow30 is a dark-appearance ink and a fill; on a
    /// light surface it measures 1.53:1, so a light appearance needs its own step.
    static let yellow60 = rgb(0x8E6A00)

    // Speaker accents. amber/violet are the hexes the now-reassigned `orange`/`purple` tokens
    // were already carrying; teal/rose come from Carbon Teal and Carbon Magenta, the same palette
    // danger/success/warning were drawn from.
    static let amber60 = rgb(0xEA580C)
    static let amber40 = rgb(0xFF8B4D)
    static let violet60 = rgb(0x7C3AED)
    static let violet40 = rgb(0xA56EFF)
    static let teal60 = rgb(0x007D79)
    static let teal30 = rgb(0x3DDBD9)
    static let rose60 = rgb(0xD02670)
    static let rose40 = rgb(0xFF7EB6)

    // Carbon Cool Gray: the one ramp with a hue but no state meaning, which is why `stale` uses
    // it instead of yellow.
    static let coolGray40 = rgb(0xA2A9B0)
    static let coolGray60 = rgb(0x697077)

    // Chrome tints, verbatim from the `.scripta` blocks of the Scripta.dc.html render.
    static let chromeLight = rgb(0xF7F7F9)
    static let chromeSidebarDark = rgb(0x222226)
    static let chromeTitlebarDark = rgb(0x1E1E22)
    static let scrimLight = rgb(0x141E37)
}

// MARK: - Semantic roles

enum Ink {

    // MARK: Interaction — blue lives here and nowhere else (rule 2)

    /// Focus ring, primary button fill, selected nav row, links, and the Engine Bar scope segment.
    static let interactive = Tone(light: Ramp.blue60, dark: Ramp.blue50)
    static let interactiveHover = Tone(light: Ramp.blue70, dark: Ramp.blue40)
    /// Selected-row wash behind `textPrimary`.
    static let interactiveSoft = Tone(light: Ramp.blue60.at(0.14), dark: Ramp.blue50.at(0.20))
    /// The quieter of the two washes — hover over a selectable row, secondary selection.
    static let interactiveSubtle = Tone(light: Ramp.blue10, dark: Ramp.blue50.at(0.13))
    /// Named separately from `interactive` so a focus ring never reads as "reuse the button blue".
    static let focusRing = interactive
    /// Foreground on any filled interactive surface.
    static let onInteractive = Tone(Ramp.white)

    // MARK: Text

    static let textPrimary = Tone(light: Ramp.gray100, dark: Ramp.gray10)
    static let textSecondary = Tone(light: Ramp.gray70, dark: Ramp.gray30)
    static let textHelper = Tone(light: Ramp.gray60, dark: Ramp.gray50)
    static let textPlaceholder = Tone(light: Ramp.gray40, dark: Ramp.gray60)
    static let textDisabled = Tone(light: Ramp.gray30, dark: Ramp.gray60)
    /// Text drawn over a saturated fill, in either appearance.
    static let textOnColor = Tone(Ramp.white)

    static let iconPrimary = Tone(light: Ramp.gray100, dark: Ramp.gray10)
    static let iconSecondary = Tone(light: Ramp.gray70, dark: Ramp.gray30)

    // MARK: Surfaces

    static let background = Tone(light: Ramp.white, dark: Ramp.gray100)
    static let layer = Tone(light: Ramp.gray10, dark: Ramp.gray90)
    static let layerHover = Tone(light: Ramp.gray10Hover, dark: Ramp.gray90Hover)
    static let layerSelected = Tone(light: Ramp.gray20, dark: Ramp.gray80)
    /// A layer stacked on top of `layer` — popovers, drawers, cards inside a tinted panel. In
    /// light mode it goes *up* to white, which is the only way to gain contrast against gray10.
    static let layerAlt = Tone(light: Ramp.white, dark: Ramp.gray80)
    static let field = Tone(light: Ramp.gray10, dark: Ramp.gray90)
    static let fieldHover = Tone(light: Ramp.gray10Hover, dark: Ramp.gray90Hover)

    // MARK: Borders

    static let borderSubtle = Tone(light: Ramp.gray20, dark: Ramp.gray80)
    static let borderStrong = Tone(light: Ramp.gray50, dark: Ramp.gray60)
    /// The border of a focused field. One of the sanctioned blue uses.
    static let borderFocus = interactive

    // MARK: Chrome — translucent tints layered over window vibrancy

    static let sidebarTint = Tone(light: Ramp.chromeLight.at(0.72), dark: Ramp.chromeSidebarDark.at(0.66))
    static let titlebarTint = Tone(light: Ramp.chromeLight.at(0.80), dark: Ramp.chromeTitlebarDark.at(0.74))
    /// Drawer / sheet backdrop.
    static let scrim = Tone(light: Ramp.scrimLight.at(0.32), dark: Ramp.black.at(0.50))
    /// The single real elevation in the system; everything else is a hairline border.
    static let overlayShadow = Tone(light: Ramp.black.at(0.18), dark: Ramp.black.at(0.44))

    // MARK: State — deviation only (rule 3)

    static let danger = Tone(light: Ramp.red60, dark: Ramp.red50)
    static let dangerHover = Tone(light: Ramp.red60Hover, dark: Ramp.red50Hover)
    static let dangerSoft = Tone(light: Ramp.red60.at(0.14), dark: Ramp.red50.at(0.16))
    /// The only state token that needed two different ramp steps rather than one hue at two
    /// levels. yellow30 is legible on a dark surface (8.99:1 on `layer`) and illegible on a light
    /// one (1.53:1) — which is how three marker WORDS in the capability envelope shipped
    /// unreadable. Light takes yellow60, the first step of Carbon's yellow ramp that clears 4.5 on
    /// background / layer / layerAlt (4.99 / 4.53 / 4.99).
    ///
    /// The cost, measured rather than left to be discovered: at the lightness 4.5 demands, warning
    /// and `danger` land ΔE2000 3.91 apart under deuteranopia in light appearance. Hue is the
    /// SECOND channel wherever this token is used — every coloured marker in the envelope is a
    /// labelled word ("degraded" beside "unavailable") inside a severity-ordered column — so the
    /// distinction survives. A renderer that drops the word keeps no signal at all.
    static let warning = Tone(light: Ramp.yellow60, dark: Ramp.yellow30)
    /// Stays yellow30 in both appearances: a wash is read as a tint, not as ink, and yellow60 at
    /// 18% is an olive smudge. Text on it is `textPrimary`, never `warning` — see `PillStyle`.
    static let warningSoft = Tone(light: Ramp.yellow30.at(0.18), dark: Ramp.yellow30.at(0.16))
    static let success = Tone(light: Ramp.green50, dark: Ramp.green40)
    static let successSoft = Tone(light: Ramp.green50.at(0.14), dark: Ramp.green40.at(0.16))

    /// The index-is-stale-after-ingest condition. Deliberately NOT `warning` yellow, which
    /// over-alarms a state that is normal for a minute after every ingest. Low-chroma slate,
    /// intended as a dotted 1px underline beneath mono text (`.staleUnderline()`) — the texture
    /// carries the signal, the hue only keeps it from reading as a solid rule.
    static let stale = Tone(light: Ramp.coolGray60, dark: Ramp.coolGray40)
    static let staleSoft = Tone(light: Ramp.coolGray60.at(0.12), dark: Ramp.coolGray40.at(0.14))
}

// MARK: - Speakers

extension Ink {
    /// ONE colored party against one neutral. `me` is neutral ink with identity carried by weight
    /// (`Register.uiEmphasis`) rather than hue, so the common two-person transcript spends exactly
    /// one color and stays legible past two speakers. `alt` opens amber/violet because that pair
    /// sits on the blue–orange axis dichromats retain; teal and rose are the third and fourth
    /// party, which is already rare.
    ///
    /// Lowercase because it is a token path, not a type you construct.
    enum speaker {
        /// Neutral ink. Pair with `Register.uiEmphasis` — weight is the whole signal here.
        static let me = Tone(light: Ramp.gray100, dark: Ramp.gray10)
        /// Row tint for the self party: neutral, near-invisible, present only so alternating rows
        /// have the same structure in both directions.
        static let meSoft = Tone(light: Ramp.gray100.at(0.05), dark: Ramp.gray10.at(0.06))

        static let amber = Tone(light: Ramp.amber60, dark: Ramp.amber40)
        static let amberSoft = Tone(light: Ramp.amber60.at(0.14), dark: Ramp.amber40.at(0.16))
        static let violet = Tone(light: Ramp.violet60, dark: Ramp.violet40)
        static let violetSoft = Tone(light: Ramp.violet60.at(0.14), dark: Ramp.violet40.at(0.16))
        static let teal = Tone(light: Ramp.teal60, dark: Ramp.teal30)
        static let tealSoft = Tone(light: Ramp.teal60.at(0.14), dark: Ramp.teal30.at(0.16))
        static let rose = Tone(light: Ramp.rose60, dark: Ramp.rose40)
        static let roseSoft = Tone(light: Ramp.rose60.at(0.14), dark: Ramp.rose40.at(0.16))

        static let alt: [Tone] = [amber, violet, teal, rose]
        static let altSoft: [Tone] = [amberSoft, violetSoft, tealSoft, roseSoft]

        /// Wraps instead of trapping: a transcript with five non-self speakers is a rendering
        /// problem, not a crash. Prefer these over `alt[i]` wherever the count is data-driven.
        static func alt(_ index: Int) -> Tone { alt[wrapped(index)] }
        static func altSoft(_ index: Int) -> Tone { altSoft[wrapped(index)] }

        private static func wrapped(_ index: Int) -> Int {
            let n = alt.count
            return ((index % n) + n) % n
        }
    }
}

// MARK: - Construction

private func rgb(_ hex: UInt32) -> NSColor {
    NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
            green: CGFloat((hex >> 8) & 0xFF) / 255,
            blue: CGFloat(hex & 0xFF) / 255,
            alpha: 1)
}

private extension NSColor {
    /// Alpha applied to a *static* ramp entry. Never call this on `Tone.ns` — alpha on a dynamic
    /// `NSColor(name:)` flattens it to whichever appearance happened to be current; use
    /// `Tone.opacity(_:)`, which reapplies to both halves of the pair.
    func at(_ alpha: CGFloat) -> NSColor { withAlphaComponent(alpha) }
}
