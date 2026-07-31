import SwiftUI

// MARK: - Record & Register: the list row
//
// The workhorse. `Density.row` (32) as a MINIMUM, never a fixed height — a row that clips the
// moment a title wraps or a locale runs long is the failure mode 30+ `.frame(height:)` calls in
// this app are waiting to produce.

extension ControlPalette {
    /// Unselected. No resting fill at all, so the row inherits whatever surface it was dropped on
    /// and a list works identically on `background`, inside a `Card`, or over sidebar vibrancy.
    static let row = ControlPalette(idle: .clear,
                                    hover: Ink.layerHover,
                                    pressed: Ink.layerSelected,
                                    disabledFill: .clear,
                                    label: Ink.textPrimary)

    /// Selected. `interactiveSoft` is rule 2's sanctioned blue — selection is interaction state,
    /// not content meaning.
    static let rowSelected = ControlPalette(idle: Ink.interactiveSoft,
                                            hover: Ink.interactiveSoft,
                                            pressed: Ink.layerSelected,
                                            disabledFill: Ink.interactiveSoft,
                                            label: Ink.textPrimary)
}

struct ListRow<Trailing: View>: View {
    let title: String
    var subtitle: String? = nil
    var glyph: Glyph? = nil
    var selected: Bool = false
    var action: (() -> Void)? = nil
    @ViewBuilder var trailing: () -> Trailing

    @ViewBuilder
    var body: some View {
        if let action {
            Pressable(action: action) { skin }
        } else {
            skin
        }
    }

    private var skin: ListRowSkin<Trailing> {
        ListRowSkin(title: title, subtitle: subtitle, glyph: glyph,
                    selected: selected, trailing: trailing)
    }
}

extension ListRow where Trailing == EmptyView {
    init(title: String,
         subtitle: String? = nil,
         glyph: Glyph? = nil,
         selected: Bool = false,
         action: (() -> Void)? = nil) {
        self.init(title: title, subtitle: subtitle, glyph: glyph,
                  selected: selected, action: action) { EmptyView() }
    }
}

// MARK: - Skin

private struct ListRowSkin<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let glyph: Glyph?
    let selected: Bool
    @ViewBuilder var trailing: () -> Trailing

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
        ListRowContent(title: title, subtitle: subtitle, glyph: glyph,
                       selected: selected, trailing: trailing)
            .modifier(ControlSkin(palette: selected ? .rowSelected : .row, phase: phase,
                                  minHeight: Density.row, horizontal: Gap.s10))
            .onHover { hovering = $0 }
            .animation(Motion.hover, value: phase)
    }
}

private struct ListRowContent<Trailing: View>: View {
    let title: String
    let subtitle: String?
    let glyph: Glyph?
    let selected: Bool
    @ViewBuilder var trailing: () -> Trailing

    var body: some View {
        HStack(spacing: Gap.s10) {
            if let glyph { Icon(glyph, Register.ui, Ink.iconSecondary) }
            RowText(title: title, subtitle: subtitle, selected: selected)
            Spacer(minLength: Gap.s8)
            trailing()
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

private struct RowText: View {
    let title: String
    let subtitle: String?
    let selected: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            // Weight, not colour, marks the selected row's title. The wash behind it already
            // carries the blue; a second signal in the ink would spend rule 3's budget twice.
            Text(title).typeface(selected ? Register.uiEmphasis : Register.ui)
            if let subtitle { Text(subtitle).typeface(Register.caption, Ink.textHelper) }
        }
    }
}
