import AppKit
import CoreText
import SwiftUI

/// The design system's review surface: a separate runnable app that links the token layer and
/// nothing else. It exists so "Record & Register" can be accepted or rejected before it touches an
/// app view — a component built against a token that fails contrast is work done twice.
///
/// It deliberately does NOT link `CarbonKit` / `CarbonTheme` / `CarbonIcon` or any view under
/// `Sources/App`. Pulling one in would let a gallery page compile against the layer this system
/// replaces, and the page would then review a blend of the two.
@main
struct GalleryApp: App {
    init() {
        GalleryFonts.register()
        // The launch `Glyph.audit()` was documented and never called, which left the debug trap on
        // an unresolvable SF Symbol inert — the whole reason `Icon` replaced `CarbonIcon`'s silent
        // `Color.clear`. The gallery is where it runs, because the components are not in the app
        // target until the view migration puts them there (project.yml). When they land, the app's
        // own launch has to call it too.
        Glyph.audit()
    }

    var body: some Scene {
        WindowGroup("Record & Register") {
            GalleryRoot()
        }
        .defaultSize(width: 1340, height: 900)
    }
}

enum GalleryFonts {
    /// Every PostScript name `Register.Face` can hand to `Font.custom`.
    static let faces: [String] = [
        Register.Face.sans,
        Register.Face.sansText,
        Register.Face.sansMedium,
        Register.Face.sansSemiBold,
        Register.Face.mono,
        Register.Face.monoMedium,
    ]

    /// The gallery is its own bundle, so the app's registration never runs for it. Without this
    /// every `Font.custom` falls back to San Francisco *silently* and the type page reviews a
    /// typeface the app does not ship — which is why `RegisterPane` prints the resolution result
    /// rather than trusting this call.
    static func register() {
        guard let dir = Bundle.main.resourceURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
        else { return }
        for url in urls where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }
}
