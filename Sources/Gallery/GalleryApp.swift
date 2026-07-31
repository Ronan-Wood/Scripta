import AppKit
import SwiftUI

/// The design system's review surface: a separate runnable app that links `Sources/Theme/Tokens`
/// and `Sources/Theme/Components` — both as whole directories, so a token file or a component that
/// nobody reviewed cannot exist. It exists so "Record & Register" can be accepted or rejected
/// before it touches an app view — a component built against a token that fails contrast is work
/// done twice.
///
/// It deliberately does NOT link `CarbonKit` / `CarbonTheme` / `CarbonIcon` or any view under
/// `Sources/App`. Pulling one in would let a gallery page compile against the layer this system
/// replaces, and the page would then review a blend of the two.
@main
struct GalleryApp: App {
    init() {
        // The token layer's own registration, not a copy of it. This was a verbatim duplicate of
        // `CarbonFont.register()` beside a second hand-written list of the Plex PostScript names.
        Register.registerFonts()
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
