import SwiftUI

// MARK: - Record & Register: control plumbing
//
// One place that decides what state a control is in, and one place that declares the tones a
// control wears across those states. Both exist because the app answers those questions per view
// today: four button-shaped types each track hover themselves, three of them differently, and not
// one of them can be shown in a state a reviewer did not physically produce with a mouse.

/// The five states every interactive primitive has to answer for.
///
/// A type rather than a pile of booleans, so the gallery can FORCE each one. A hover state that
/// exists only while a pointer is over it is a state nobody reviews and no diff can catch.
enum ControlPhase: String, CaseIterable, Identifiable {
    case normal, hover, pressed, focused, disabled

    var id: String { rawValue }

    /// Priority is disabled > pressed > focused > hover, and the ordering is deliberate: the focus
    /// ring is a keyboard user's only position signal, so a pointer resting on the focused control
    /// must not take it away. Hover feedback is the cheaper of the two to lose.
    static func resolve(forced: ControlPhase?,
                        enabled: Bool,
                        pressed: Bool = false,
                        hovering: Bool = false,
                        focused: Bool = false) -> ControlPhase {
        if let forced { return forced }
        if !enabled { return .disabled }
        if pressed { return .pressed }
        if focused { return .focused }
        if hovering { return .hover }
        return .normal
    }
}

/// The one composed value in the component layer, named once so it cannot be re-guessed per view.
///
/// `Ramp` carries a hover step for the interactive and danger ramps and no pressed step, so
/// "pressed" on a *filled* control is composed rather than tokenised: the hover fill dimmed toward
/// whatever sits behind the control, which reads as depressed in both appearances. Outline and
/// ghost controls never need it — `layerSelected` is their pressed token.
///
/// FLAGGED: an `interactivePressed` / `dangerPressed` in `Ink` deletes this enum outright.
enum ControlAlpha {
    static let pressed: CGFloat = 0.86
}

extension Tone {
    /// A fill that defers to whatever is behind it. Outline and ghost controls must not paint a
    /// surface — a secondary button that painted `background` would drag the page colour into
    /// every card it sat in.
    ///
    /// FLAGGED: this belongs in `Ink`, beside the surfaces.
    static let clear = Ink.background.opacity(0)
}

// MARK: - Palette

/// The tones one control wears across the five phases.
///
/// A struct rather than a `switch` inside every component: the same five-way decision was being
/// re-made per control, which is how `.secondary` ended up with a hover fill in `CarbonButton` and
/// none in `TitleBarPill`.
struct ControlPalette {
    let idle: Tone
    let hover: Tone
    let pressed: Tone
    let disabledFill: Tone
    let label: Tone
    /// Label while the pointer is down or over it. `nil` keeps `label`.
    let activeLabel: Tone?
    let disabledLabel: Tone
    let border: Tone?
    let disabledBorder: Tone?

    init(idle: Tone,
         hover: Tone,
         pressed: Tone,
         disabledFill: Tone,
         label: Tone,
         activeLabel: Tone? = nil,
         disabledLabel: Tone = Ink.textDisabled,
         border: Tone? = nil,
         disabledBorder: Tone? = nil) {
        self.idle = idle
        self.hover = hover
        self.pressed = pressed
        self.disabledFill = disabledFill
        self.label = label
        self.activeLabel = activeLabel
        self.disabledLabel = disabledLabel
        self.border = border
        self.disabledBorder = disabledBorder
    }

    func background(_ phase: ControlPhase) -> Tone {
        switch phase {
        case .normal, .focused: return idle
        case .hover: return hover
        case .pressed: return pressed
        case .disabled: return disabledFill
        }
    }

    func foreground(_ phase: ControlPhase) -> Tone {
        switch phase {
        case .disabled: return disabledLabel
        case .hover, .pressed: return activeLabel ?? label
        case .normal, .focused: return label
        }
    }

    /// `borderFocus` wins on focus even where the control has no resting border. A ring that only
    /// appears on controls which already had an outline is not a focus ring.
    func stroke(_ phase: ControlPhase) -> Tone? {
        switch phase {
        case .focused: return Ink.borderFocus
        case .disabled: return disabledBorder
        default: return border
        }
    }
}

// MARK: - Skin

/// Fill, border, label colour, hit shape and the focus ring, applied in one wrap. Every primitive
/// in this directory goes through it, which is what makes "a pill and a row disagree about hover"
/// a thing that cannot happen rather than a thing nobody noticed.
struct ControlSkin: ViewModifier {
    let palette: ControlPalette
    let phase: ControlPhase
    var minHeight: CGFloat = Density.row
    var horizontal: CGFloat = Gap.s12
    var vertical: CGFloat = Gap.s4
    var radius: CGFloat = Corner.control

    func body(content: Content) -> some View {
        content
            .foregroundStyle(palette.foreground(phase))
            .controlBox(minHeight, horizontal: horizontal, vertical: vertical)
            .surface(palette.background(phase), radius: radius, border: palette.stroke(phase))
            .overlay { FocusRing(radius: radius, on: phase == .focused) }
            .opacity(phase == .pressed ? ControlAlpha.pressed : 1)
            .contentShape(Corner.shape(radius))
    }
}

/// Carbon's double ring: the control's own border turns `borderFocus` and a second hairline sits
/// one point outside it. Drawn in an overlay with negative padding, so gaining focus never moves
/// the row the control is in — a ring that reflows its neighbours is how focus rings get removed.
private struct FocusRing: View {
    let radius: CGFloat
    let on: Bool

    var body: some View {
        Corner.shape(radius + Elevation.hairline)
            .strokeBorder(Ink.focusRing.opacity(on ? 1 : 0), lineWidth: Elevation.hairline)
            .padding(-Elevation.hairline)
    }
}

// MARK: - Press and focus plumbing

/// A `ButtonStyle` that draws nothing and only publishes `isPressed` downward.
///
/// Without it, every pressable primitive has to *be* a `ButtonStyle` and therefore has to own its
/// whole appearance inside one `makeBody`. With it, a primitive stays an ordinary `View` that
/// happens to know it is being pressed, and the same view renders identically whether or not it
/// was given an action.
struct PressReporter: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label.environment(\.controlPressed, configuration.isPressed)
    }
}

extension ButtonStyle where Self == PressReporter {
    static var pressReporter: PressReporter { PressReporter() }
}

/// The hit target every pressable primitive shares. Publishes pressed and focused state to its
/// content and draws nothing itself.
///
/// `focusEffectDisabled()` is deliberate: `ControlSkin` draws the ring, and letting AppKit draw a
/// second one around the same control is how a system ends up with two focus indicators that
/// disagree about the corner radius.
struct Pressable<Content: View>: View {
    let action: () -> Void
    @ViewBuilder var content: () -> Content

    @FocusState private var focused: Bool

    var body: some View {
        Button(action: action) { content() }
            .buttonStyle(.pressReporter)
            .focused($focused)
            .focusEffectDisabled()
            .environment(\.controlFocused, focused)
    }
}

// MARK: - Environment

private struct ForcedControlPhaseKey: EnvironmentKey { static let defaultValue: ControlPhase? = nil }
private struct ControlPressedKey: EnvironmentKey { static let defaultValue = false }
private struct ControlFocusedKey: EnvironmentKey { static let defaultValue = false }

extension EnvironmentValues {
    /// Set by the gallery and nothing else. Production never sets it, so live tracking is what
    /// runs in the app and the review surface is not a second code path.
    var forcedControlPhase: ControlPhase? {
        get { self[ForcedControlPhaseKey.self] }
        set { self[ForcedControlPhaseKey.self] = newValue }
    }

    var controlPressed: Bool {
        get { self[ControlPressedKey.self] }
        set { self[ControlPressedKey.self] = newValue }
    }

    var controlFocused: Bool {
        get { self[ControlFocusedKey.self] }
        set { self[ControlFocusedKey.self] = newValue }
    }
}

extension View {
    /// Pins every primitive beneath this view to one phase. Pair with `.disabled(true)` when
    /// forcing `.disabled`, so the control is genuinely inert and not merely painted that way.
    func forcedControlPhase(_ phase: ControlPhase?) -> some View {
        environment(\.forcedControlPhase, phase)
    }
}
