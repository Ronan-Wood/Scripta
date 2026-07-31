import SwiftUI

// MARK: - Record & Register: text input

extension ControlPalette {
    /// A field never changes fill when disabled — it greys its ink instead. Greying the surface as
    /// well makes a disabled field read as a label, and users stop trying to click it even after
    /// it re-enables.
    static let field = ControlPalette(idle: Ink.field,
                                      hover: Ink.fieldHover,
                                      pressed: Ink.fieldHover,
                                      disabledFill: Ink.field,
                                      label: Ink.textPrimary,
                                      border: Ink.borderSubtle,
                                      disabledBorder: Ink.borderSubtle)
}

/// A single-line text field. `Density.row` (32) tall, `Corner.field` radius, focus carried by
/// `borderFocus` plus the double ring `ControlSkin` draws.
///
/// `prompt` is DECORATIVE and must never be the only place a field's meaning appears. The contrast
/// gate records `textPlaceholder` on `field` at 2.16:1 light / 3.01:1 dark against a required 4.5
/// (`FindingCause.placeholderInk`), and this component takes the second of the two ways out that
/// finding names: the system states that a placeholder may not carry information the label does
/// not. Put the label outside the field.
struct InputField: View {
    let prompt: String
    @Binding var text: String
    var glyph: Glyph? = nil
    var onSubmit: () -> Void = {}

    @Environment(\.isEnabled) private var isEnabled
    @Environment(\.forcedControlPhase) private var forced
    @FocusState private var focused: Bool
    @State private var hovering = false

    private var phase: ControlPhase {
        ControlPhase.resolve(forced: forced, enabled: isEnabled,
                             hovering: hovering, focused: focused)
    }

    var body: some View {
        FieldContent(prompt: prompt, text: $text, glyph: glyph, phase: phase, focus: $focused)
            .modifier(ControlSkin(palette: .field, phase: phase,
                                  minHeight: Density.row,
                                  horizontal: Gap.s10, radius: Corner.field))
            .onHover { hovering = $0 }
            .onTapGesture { focused = true }
            .animation(Motion.hover, value: phase)
            .onSubmit(onSubmit)
    }
}

private struct FieldContent: View {
    let prompt: String
    @Binding var text: String
    let glyph: Glyph?
    let phase: ControlPhase
    var focus: FocusState<Bool>.Binding

    var body: some View {
        HStack(spacing: Gap.s8) {
            if let glyph { Icon(glyph, Register.ui, Ink.iconSecondary) }
            TextField("", text: $text)
                .textFieldStyle(.plain)
                .typeface(Register.ui, ControlPalette.field.foreground(phase))
                .focused(focus)
                .overlay(alignment: .leading) { PromptText(prompt: prompt, on: text.isEmpty) }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// Drawn rather than handed to `TextField(prompt:)`, which colours its prompt from the system's
/// placeholder colour and ignores the token entirely.
private struct PromptText: View {
    let prompt: String
    let on: Bool

    var body: some View {
        Text(prompt)
            .typeface(Register.ui, Ink.textPlaceholder)
            .opacity(on ? 1 : 0)
            .allowsHitTesting(false)
    }
}
