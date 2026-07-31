import AppKit
import SwiftUI

/// One appearance, named and passed explicitly, so every readout in a column knows which half of
/// each `Tone` it is describing.
struct GalleryAppearance: Hashable, Identifiable {
    let name: NSAppearance.Name

    var id: String { name.rawValue }
    var isDark: Bool { name == .darkAqua }
    var title: String { isDark ? "Dark" : "Light" }
    var scheme: ColorScheme { isDark ? .dark : .light }
    var resolved: NSAppearance { NSAppearance(named: name) ?? NSAppearance.currentDrawing() }

    static let light = GalleryAppearance(name: .aqua)
    static let dark = GalleryAppearance(name: .darkAqua)
    static let both: [GalleryAppearance] = [.light, .dark]
}

/// Renders `content` under a FORCED `NSAppearance`, not merely a forced `ColorScheme`.
///
/// This is the difference between an honest gallery and a decorative one. `Ink`'s tokens are
/// `NSColor(name:)` blocks that resolve against the *drawing appearance*, and the app pins that
/// appearance process-wide through `NSApp.appearance` — which is exactly why SwiftUI previews in
/// this codebase show one theme no matter what they ask for. `.preferredColorScheme` alone would
/// inherit that lie. An `NSHostingView` carrying its own `appearance` is the one mechanism that
/// overrides an app-level pin for a subtree, so the two columns are genuinely independent.
///
/// `.environment(\.colorScheme:)` goes on as well: it is what SwiftUI's own materials, symbol
/// rendering and `.shadow` read, and those do not consult `NSAppearance`.
///
/// `.preferredColorScheme` deliberately does NOT go on here. On macOS it reaches up and sets the
/// *window's* appearance, so two side-by-side subtrees asking for opposite schemes would fight
/// over one window and the last one laid out would win. It is applied at the window root instead,
/// in the single-appearance mode — which is also the only place its behaviour is worth reviewing.
struct AppearanceHost<Content: View>: NSViewRepresentable {
    let appearance: GalleryAppearance
    /// Fixed, because an `NSHostingView` sized from its intrinsic content needs one axis pinned
    /// before it can report the other — an unconstrained column reports a single enormous line.
    let width: CGFloat
    @ViewBuilder var content: () -> Content

    func makeNSView(context: Context) -> NSHostingView<AnyView> {
        let view = NSHostingView(rootView: body)
        view.sizingOptions = [.intrinsicContentSize]
        view.appearance = appearance.resolved
        return view
    }

    func updateNSView(_ view: NSHostingView<AnyView>, context: Context) {
        view.rootView = body
        view.appearance = appearance.resolved
    }

    private var body: AnyView {
        AnyView(
            content()
                .frame(width: width, alignment: .leading)
                .environment(\.colorScheme, appearance.scheme)
        )
    }
}
