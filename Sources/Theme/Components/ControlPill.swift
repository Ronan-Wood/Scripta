import SwiftUI

// MARK: - Record & Register: pills and tags
//
// One shape at `Density.pill` (28) with `Corner.control` — the radius the render spec already
// calls a pill and `TitleBarPill` already draws. Filters, topics, scopes, states and speaker
// chips are all this component.

/// A pill's tones. Split into `label` and `mark` so hue can live in the icon while the words stay
/// readable, which is the only way most of these survive the contrast gate.
///
/// STATE PILLS PUT THEIR HUE IN THE WASH, NOT THE INK. `danger`/`success`/`stale` ink on their own
/// soft wash are recorded gate failures (`FindingCause.softWashErodesSameHueInk`: success light
/// measures 2.63:1 on layer against a required 4.5). `warning` now has a light-appearance ink and
/// still loses this way: yellow60 on a yellow30 wash over layer is 4.17:1, under the same 4.5.
/// Ink stays `textPrimary` — gated at 4.5 on every wash and passing — and the coloured wash
/// carries rule 3's "something departed from the default".
struct PillStyle {
    let label: Tone
    /// The leading glyph and the remove affordance.
    let mark: Tone
    let fill: Tone
    let hover: Tone
    let border: Tone?
    let face: Typeface

    init(label: Tone,
         mark: Tone? = nil,
         fill: Tone,
         hover: Tone? = nil,
         border: Tone? = nil,
         face: Typeface = Register.caption) {
        self.label = label
        self.mark = mark ?? label
        self.fill = fill
        self.hover = hover ?? fill
        self.border = border
        self.face = face
    }

    var palette: ControlPalette {
        ControlPalette(idle: fill,
                       hover: hover,
                       pressed: hover,
                       disabledFill: fill,
                       label: label,
                       border: border,
                       disabledBorder: border)
    }
}

extension PillStyle {
    static let neutral = PillStyle(label: Ink.textSecondary,
                                   mark: Ink.iconSecondary,
                                   fill: Ink.layer,
                                   hover: Ink.layerHover,
                                   border: Ink.borderSubtle)

    /// The one blue pill. Rule 2: a selected filter IS interaction state.
    static let selected = PillStyle(label: Ink.onInteractive,
                                    mark: Ink.onInteractive,
                                    fill: Ink.interactive,
                                    hover: Ink.interactiveHover)

    static let danger = PillStyle(label: Ink.textPrimary, fill: Ink.dangerSoft)
    static let warning = PillStyle(label: Ink.textPrimary, fill: Ink.warningSoft)
    static let success = PillStyle(label: Ink.textPrimary, fill: Ink.successSoft)
    static let stale = PillStyle(label: Ink.textPrimary, fill: Ink.staleSoft)

    /// The self party: neutral ink at `uiEmphasis`, because weight is the WHOLE identity signal
    /// here — that pairing is the speaker system's stated rule, not a style choice.
    static let me = PillStyle(label: Ink.speaker.me,
                              fill: Ink.speaker.meSoft,
                              face: Register.uiEmphasis)

    /// A coloured party. Wraps past four, matching `Ink.speaker.alt(_:)`.
    ///
    /// This is the one preset that keeps hue in the ink, because for a speaker the hue IS the
    /// identity. It is therefore the same-hue-wash shape the gate calls the system's weakest:
    /// amber on amberSoft over layer measures 2.75:1 light, violet 3.64:1 dark, both against 4.5
    /// (`FindingCause.softWashErodesSameHueInk`). Inherited knowingly rather than papered over
    /// with a token invented here.
    static func speaker(_ index: Int) -> PillStyle {
        PillStyle(label: Ink.speaker.alt(index),
                  fill: Ink.speaker.altSoft(index),
                  face: Register.ui)
    }
}

// MARK: - View

struct Pill: View {
    let text: String
    var glyph: Glyph? = nil
    var style: PillStyle = .neutral
    var action: (() -> Void)? = nil
    /// A remove affordance makes the pill itself inert: a close target nested inside a pressable
    /// pill is two overlapping hit boxes, and the wrong one always wins.
    var onRemove: (() -> Void)? = nil

    @ViewBuilder
    var body: some View {
        if let action, onRemove == nil {
            Pressable(action: action) { skin }
        } else {
            skin
        }
    }

    private var skin: PillSkin {
        PillSkin(text: text, glyph: glyph, style: style, onRemove: onRemove)
    }
}

private struct PillSkin: View {
    let text: String
    let glyph: Glyph?
    let style: PillStyle
    let onRemove: (() -> Void)?

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.forcedControlPhase) private var forced
    @Environment(\.controlPressed) private var pressed
    @Environment(\.controlFocused) private var focused
    @State private var hovering = false

    private var phase: ControlPhase {
        ControlPhase.resolve(forced: forced, enabled: isEnabled,
                             pressed: pressed, hovering: hovering, focused: focused)
    }

    var body: some View {
        PillContent(text: text, glyph: glyph, style: style, onRemove: onRemove)
            .modifier(ControlSkin(palette: style.palette, phase: phase,
                                  minHeight: Density.pill, horizontal: Gap.s10))
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: phase)
    }
}

private struct PillContent: View {
    let text: String
    let glyph: Glyph?
    let style: PillStyle
    let onRemove: (() -> Void)?

    var body: some View {
        HStack(spacing: Gap.s6) {
            if let glyph { Icon(glyph, style.face, style.mark) }
            Text(text).typeface(style.face).lineLimit(1)
            if let onRemove { RemoveMark(text: text, tone: style.mark, action: onRemove) }
        }
    }
}

/// Bare `Pressable` rather than an `IconButton`: an icon button brings its own 28pt box, which
/// would push the pill it sits in to 36.
private struct RemoveMark: View {
    let text: String
    let tone: Tone
    let action: () -> Void

    var body: some View {
        Pressable(action: action) {
            Icon(.close, Register.caption, tone)
        }
        .accessibilityLabel("Remove \(text)")
    }
}
