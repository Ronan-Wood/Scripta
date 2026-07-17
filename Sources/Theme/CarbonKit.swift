import SwiftUI
import AppKit

/// Native macOS vibrancy (the translucent sidebar material).
struct VisualEffectView: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .sidebar
    var blending: NSVisualEffectView.BlendingMode = .behindWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        view.material = material
        view.blendingMode = blending
        view.state = .followsWindowActiveState
        return view
    }
    func updateNSView(_ view: NSVisualEffectView, context: Context) {
        view.material = material
        view.blendingMode = blending
    }
}

/// Reusable Carbon-styled SwiftUI primitives so every hub view shares one language:
/// rounded (Apple-y) corners, IBM Plex, token colors, 8px grid.

enum CarbonButtonKind { case primary, danger, secondary, ghost }

struct CarbonButton: View {
    let title: String
    var icon: String? = nil
    var kind: CarbonButtonKind = .secondary
    var fill: Bool = false
    let action: () -> Void

    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.x3) {
                Text(title).font(CarbonFont.medium(14)).foregroundStyle(foreground)
                if fill { Spacer(minLength: Space.x6) }
                if let icon { CarbonIcon(name: icon, size: 16, color: foreground) }
            }
            .padding(.horizontal, Space.x5)
            .frame(height: 36)
            .frame(maxWidth: fill ? .infinity : nil, alignment: .leading)
            .background(background, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .overlay {
                if kind == .secondary {
                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                        .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
    }

    private var foreground: Color {
        switch kind {
        case .primary, .danger: return Carbon.textOnColor
        case .secondary, .ghost: return Carbon.textPrimary
        }
    }
    private var background: Color {
        switch kind {
        case .primary: return hovering ? Carbon.interactiveHover : Carbon.interactive
        case .danger: return Carbon.danger
        case .secondary: return hovering ? Carbon.layerHover : Color.clear
        case .ghost: return hovering ? Carbon.layerHover : Color.clear
        }
    }
}

/// A rounded surface tile, native-macOS feel with a hairline border.
struct CarbonCard<Content: View>: View {
    @ViewBuilder var content: Content
    var body: some View {
        content
            .padding(Space.x5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
            .overlay {
                RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                    .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
            }
    }
}

/// Small uppercase section label, Carbon productive style.
struct SectionHeader: View {
    let title: String
    var body: some View {
        Text(title.uppercased())
            .font(CarbonFont.label(11))
            .tracking(0.4)
            .foregroundStyle(Carbon.textSecondary)
    }
}

/// Segmented input-level meter (0–1). Green → amber → red toward the top.
struct LevelMeter: View {
    let level: Float
    var segments: Int = 16

    var body: some View {
        HStack(spacing: 2) {
            ForEach(0..<segments, id: \.self) { i in
                RoundedRectangle(cornerRadius: 1)
                    .fill(level > Float(i) / Float(segments) ? color(i) : Carbon.borderSubtle)
                    .frame(width: 4, height: 12)
            }
        }
        .animation(.linear(duration: 0.08), value: level)
    }

    private func color(_ i: Int) -> Color {
        let frac = Double(i) / Double(segments)
        return frac > 0.85 ? Carbon.danger : (frac > 0.6 ? Carbon.warning : Carbon.success)
    }
}

/// Dashboard stat tile: uppercase label over a large numeral (+ optional unit).
struct StatTile: View {
    let label: String
    let value: String
    var unit: String? = nil

    var body: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text(label.uppercased()).font(CarbonFont.label(11)).tracking(0.4)
                .foregroundStyle(Carbon.textSecondary)
            HStack(alignment: .firstTextBaseline, spacing: Space.x2) {
                Text(value).font(CarbonFont.semibold(28)).foregroundStyle(Carbon.textPrimary)
                if let unit {
                    Text(unit).font(CarbonFont.label(12)).foregroundStyle(Carbon.textSecondary)
                }
            }
        }
        .padding(Space.x5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.card, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: Radius.card, style: .continuous)
                .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
        }
    }
}

/// A tag / topic chip. Selected state uses the interactive token.
struct CarbonChip: View {
    let text: String
    var selected: Bool = false
    var action: (() -> Void)? = nil

    var body: some View {
        let label = Text(text).font(CarbonFont.label(12))
            .foregroundStyle(selected ? Carbon.textOnColor : Carbon.textPrimary)
            .padding(.horizontal, Space.x4).padding(.vertical, Space.x2)
            .background(selected ? Carbon.interactive : Carbon.layerSelected, in: Capsule())
        if let action {
            Button(action: action) { label.contentShape(Rectangle()) }.buttonStyle(.plain)
        } else {
            label
        }
    }
}
