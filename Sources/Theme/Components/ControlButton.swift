import SwiftUI

// MARK: - Record & Register: buttons
//
// Four ranks and one icon-only form. Rank is the ONLY thing a call site chooses; every tone,
// height and radius follows from it. `CarbonButton` took `kind` and then let each call site add
// `.frame(height:)`, which is how 30+ fixed control heights got into the app.

enum ButtonRank: String, CaseIterable, Identifiable {
    /// The one action a screen is for. Carries `interactive`, which is rule 2's sanctioned blue.
    case primary
    /// Outlined. The default for anything that is not the screen's point.
    case secondary
    /// No fill and no border until touched — toolbars, inline affordances, dismissals.
    case tertiary
    /// Carries `danger`. Never the default rank on a screen: a destructive default is a bug report.
    case destructive

    var id: String { rawValue }

    var palette: ControlPalette {
        switch self {
        case .primary:
            return ControlPalette(idle: Ink.interactive,
                                  hover: Ink.interactiveHover,
                                  pressed: Ink.interactiveHover,
                                  disabledFill: Ink.layerSelected,
                                  label: Ink.onInteractive)
        case .secondary:
            return ControlPalette(idle: .clear,
                                  hover: Ink.layerHover,
                                  pressed: Ink.layerSelected,
                                  disabledFill: .clear,
                                  label: Ink.textPrimary,
                                  border: Ink.borderStrong,
                                  disabledBorder: Ink.borderSubtle)
        case .tertiary:
            // Blue on hover, neutral at rest. Rule 2 permits blue on a thing you can click; rule
            // 3 spends the *permanent* colour budget on the Engine Bar's scope segment alone. A
            // transient hover tint sits inside both.
            return ControlPalette(idle: .clear,
                                  hover: Ink.layerHover,
                                  pressed: Ink.layerSelected,
                                  disabledFill: .clear,
                                  label: Ink.textPrimary,
                                  activeLabel: Ink.interactive)
        case .destructive:
            return ControlPalette(idle: Ink.danger,
                                  hover: Ink.dangerHover,
                                  pressed: Ink.dangerHover,
                                  disabledFill: Ink.layerSelected,
                                  label: Ink.textOnColor)
        }
    }

    /// One face for every rank. A button whose weight changed with its rank would make rank read
    /// as importance-of-the-words rather than importance-of-the-action.
    var face: Typeface { Register.uiEmphasis }
}

/// A labelled button. `Density.action` (36) tall in every rank, so a row of mixed ranks lines up.
struct ActionButton: View {
    let title: String
    var glyph: Glyph? = nil
    var rank: ButtonRank = .secondary
    /// Stretches to the width offered. Off by default — a button that fills by accident is the
    /// most common layout bug in the app's settings panes.
    var fills: Bool = false
    let action: () -> Void

    var body: some View {
        Pressable(action: action) {
            ActionButtonSkin(title: title, glyph: glyph, rank: rank, fills: fills)
        }
    }
}

/// Icon-only, `Density.pill` (28) square. `label` is required and is not decoration: an icon
/// button without one is a control VoiceOver announces as "button".
///
/// `help` is SEPARATE from `label` because one string could not do both jobs. A tooltip earns its
/// space by explaining what the control is FOR — "teach a term once; transcription and search learn
/// it everywhere" — while an accessibility label has to be the short name of the thing, because
/// VoiceOver reads it on every focus. Collapsing them cost the reader's vocabulary button its
/// explanation on first migration: the long form was deleted rather than inflicted on a screen
/// reader. Defaults to `label`, so the common case where the name IS the explanation stays one
/// argument.
struct IconButton: View {
    let glyph: Glyph
    let label: String
    var help: String? = nil
    var rank: ButtonRank = .tertiary
    let action: () -> Void

    var body: some View {
        Pressable(action: action) {
            IconButtonSkin(glyph: glyph, label: label, help: help ?? label, rank: rank)
        }
        .accessibilityLabel(label)
    }
}

// MARK: - Skins

private struct ActionButtonSkin: View {
    let title: String
    let glyph: Glyph?
    let rank: ButtonRank
    let fills: Bool

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
        ActionButtonContent(title: title, glyph: glyph, rank: rank, phase: phase, fills: fills)
            .modifier(ControlSkin(palette: rank.palette, phase: phase,
                                  minHeight: Density.action,
                                  horizontal: Gap.s16, vertical: Gap.s6))
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: phase)
    }
}

private struct ActionButtonContent: View {
    let title: String
    let glyph: Glyph?
    let rank: ButtonRank
    let phase: ControlPhase
    let fills: Bool

    var body: some View {
        HStack(spacing: Gap.s8) {
            if let glyph { Icon(glyph, rank.face, rank.palette.foreground(phase)) }
            Text(title).typeface(rank.face)
            if fills { Spacer(minLength: Gap.s8) }
        }
        .frame(maxWidth: fills ? .infinity : nil, alignment: fills ? .leading : .center)
    }
}

private struct IconButtonSkin: View {
    let glyph: Glyph
    let label: String
    let help: String
    let rank: ButtonRank

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
        Icon(glyph, Register.bodyUI, rank.palette.foreground(phase))
            // A MINIMUM square around the glyph, not a fixed one: symbol widths differ by case,
            // and 16 + 2x6 lands the control on 28 without pinning anything.
            .frame(minWidth: Gap.s16, minHeight: Gap.s16)
            .modifier(ControlSkin(palette: rank.palette, phase: phase,
                                  minHeight: Density.pill, horizontal: Gap.s6))
            .help(help)
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: phase)
    }
}
