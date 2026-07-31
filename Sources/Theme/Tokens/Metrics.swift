import SwiftUI

// MARK: - Record & Register: the measurement layer

/// Spacing, value-named. The names ARE the values, so a reviewer can check a layout against a
/// render without a lookup table, and adding a step later cannot renumber the existing ones.
///
/// Extended to absorb the off-grid values rather than snapping the chrome to a grid it does not
/// sit on: the old `x1...x8` scale skipped 6, 10, 14 and 20, which is why ~191 literal paddings
/// exist, concentrated in the sidebar and the drawer. 6 and 10 are in because they are the
/// second and third most common literals in the app; 14 stays out because it appears twice.
enum Gap {
    static let s2: CGFloat = 2
    static let s4: CGFloat = 4
    static let s6: CGFloat = 6
    static let s8: CGFloat = 8
    static let s10: CGFloat = 10
    static let s12: CGFloat = 12
    static let s16: CGFloat = 16
    static let s20: CGFloat = 20
    static let s24: CGFloat = 24
    static let s32: CGFloat = 32
    static let s40: CGFloat = 40
    static let s56: CGFloat = 56
}

/// Page-level measurements: the frame a screen is composed inside.
///
/// Named `Metrics` and not `Layout` because SwiftUI's `Layout` protocol is unqualified at every
/// custom-layout conformance in the app (`struct FlexWrap: Layout`); a module-level `Layout` type
/// shadows it and breaks all of them.
enum Metrics {
    /// Outer margin of a content pane. Sidebars and drawers set their own.
    static let pageGutter: CGFloat = 32
    static let cardPadding: CGFloat = 16
    /// Cards inside a drawer or a sidebar, where 16 costs a column of text.
    static let cardPaddingCompact: CGFloat = 12

    /// Measure caps. Prose is capped short because a transcript read at full window width loses
    /// the line the eye was on; lists get more because their scan is vertical.
    static let proseMaxWidth: CGFloat = 720
    static let listMaxWidth: CGFloat = 900

    /// Line-height multiples. Consumed via `Typeface.lineSpacing`, which converts them into the
    /// extra leading SwiftUI actually wants — do not hand them to `.lineSpacing` directly.
    static let lineHeightProse: CGFloat = 1.55
    static let lineHeightUI: CGFloat = 1.35
}

/// Control heights, expressed as MINIMUMS.
///
/// ANYTHING WITH CONTENT IN IT is sized with padding plus `.frame(minHeight:)`, never
/// `.frame(height:)`: a fixed height clips the moment a label wraps, a Dynamic Type step lands, or
/// a locale is longer than English. There are 30+ fixed heights in the app today
/// (26/28/30/34/36/40/48) and every one of them is a latent clip. Use
/// `.controlBox(_:horizontal:vertical:)`.
///
/// The rule is about content, and stating it that way is what makes it enforceable rather than
/// merely strict. A 1pt rule and a colour swatch have nothing to clip; their fixed size is the
/// whole point, because two of them in two appearance columns have to be exactly comparable. Those
/// live in the gallery's `Specimen` table, which names every one of them, and
/// `SystemRuleTests.testFixedHeightsAreNamedAndJustified` fails on any height spelled as a bare
/// number in this design system — which is the difference between a rule and a preference.
enum Density {
    /// Pills, icon buttons, tag chips, title-bar controls.
    static let pill: CGFloat = 28
    /// List rows, table rows, text fields, popup buttons.
    static let row: CGFloat = 32
    /// Primary and destructive buttons — the ones that need a target, not just a hit box.
    static let action: CGFloat = 36
}

/// Continuous corner radii, rounded toward native macOS. The Carbon thread in this app runs
/// through color and type, not through square corners.
enum Corner {
    static let control: CGFloat = 7
    static let field: CGFloat = 8
    static let card: CGFloat = 10

    /// The ONE spelling. `controlShape` / `fieldShape` / `cardShape` were here beside it: the last
    /// two had no call sites at all, and the first gave the control radius two spellings while
    /// covering neither of the others — so `ControlSkin` and `FocusRing`, which take a radius as a
    /// parameter and therefore cannot use a fixed shape, said `Corner.shape(...)` while two gallery
    /// call sites said `Corner.controlShape`. An unused VALUE is fine ahead of a migration; an
    /// unused HELPER gets adopted from whichever spelling a migrating author happens to find first.
    ///
    /// `.continuous` everywhere: mixing it with `.circular` inside one screen is visible at these
    /// radii, and `RoundedRectangle`'s default is circular.
    static func shape(_ radius: CGFloat) -> RoundedRectangle {
        RoundedRectangle(cornerRadius: radius, style: .continuous)
    }
}

extension View {
    /// The sanctioned way to size a control: padding plus a floor, so content can always grow.
    func controlBox(_ minHeight: CGFloat = Density.row,
                    horizontal: CGFloat = Gap.s12,
                    vertical: CGFloat = Gap.s4) -> some View {
        padding(.horizontal, horizontal)
            .padding(.vertical, vertical)
            .frame(minHeight: minHeight)
    }
}
