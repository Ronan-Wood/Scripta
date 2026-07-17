import SwiftUI
import AppKit
import CoreText

/// IBM Carbon-flavored theme for the native app: Carbon color tokens (White / Gray 100 themes),
/// IBM Plex typography, and the 8px spacing grid. Not an official Carbon port — it captures the
/// design language (the blue, the grays, Plex, square corners, spacing) in native SwiftUI.

// MARK: - Colors (Carbon tokens, light = White theme / dark = Gray 100 theme)

/// Values are copied VERBATIM from the design source of truth — the `.scripta` / `.scripta.dark`
/// variable blocks in Ronan's Scripta.dc.html render. Do not eyeball-adjust; re-extract instead.
enum Carbon {
    static let interactive      = dyn(0x0F62FE, 0x4589FF)          // --c-blue
    static let interactiveHover = dyn(0x0353E9, 0x78A9FF)          // --c-blue-hover
    static let blueSoft         = dynA(0x0F62FE, 0.14, 0x4589FF, 0.20)   // --c-blue-soft / --c-nav-sel
    static let blueSoft2        = dynA(0xEDF5FF, 1.0, 0x4589FF, 0.13)    // --c-blue-soft2
    static let danger           = dyn(0xDA1E28, 0xFA4D56)          // --c-danger (Record)
    static let success          = dyn(0x24A148, 0x42BE65)          // --c-success
    static let warning          = dyn(0xF1C21B, 0xF1C21B)          // --c-warning
    static let warningSoft      = dynA(0xF1C21B, 0.18, 0xF1C21B, 0.16)
    static let orange           = dyn(0xEA580C, 0xFF8B4D)          // --c-orange ("Them")
    static let orangeSoft       = dynA(0xEA580C, 0.14, 0xFF8B4D, 0.16)
    static let purple           = dyn(0x7C3AED, 0xA56EFF)          // --c-purple
    static let purpleSoft       = dynA(0x7C3AED, 0.14, 0xA56EFF, 0.16)

    static let background    = dyn(0xFFFFFF, 0x161616)   // --c-bg
    static let layer         = dyn(0xF4F4F4, 0x262626)   // --c-layer
    static let layerHover    = dyn(0xE8E8E8, 0x333333)
    static let layerSelected = dyn(0xE0E0E0, 0x393939)
    static let field         = dyn(0xF4F4F4, 0x262626)

    static let borderSubtle  = dyn(0xE0E0E0, 0x393939)
    static let borderStrong  = dyn(0x8D8D8D, 0x6F6F6F)

    static let textPrimary   = dyn(0x161616, 0xF4F4F4)
    static let textSecondary = dyn(0x525252, 0xC6C6C6)
    static let textHelper    = dyn(0x6F6F6F, 0x8D8D8D)
    static let textPlaceholder = dyn(0xA8A8A8, 0x6F6F6F)
    static let textOnColor   = Color.white
    static let iconPrimary   = dyn(0x161616, 0xF4F4F4)
    static let iconSecondary = dyn(0x525252, 0xC6C6C6)

    /// Translucent chrome tints, layered over window vibrancy.
    static let sidebarTint  = dynA(0xF7F7F9, 0.72, 0x222226, 0.66)   // --c-sidebar
    static let titlebarTint = dynA(0xF7F7F9, 0.80, 0x1E1E22, 0.74)   // --c-titlebar
    static let scrim        = dynA(0x141E37, 0.32, 0x000000, 0.50)   // --c-scrim (drawer backdrop)

    private static func dyn(_ light: UInt32, _ dark: UInt32) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
        })
    }

    private static func dynA(_ light: UInt32, _ lightAlpha: CGFloat,
                             _ dark: UInt32, _ darkAlpha: CGFloat) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            let isDark = appearance.bestMatch(from: [.aqua, .darkAqua]) == .darkAqua
            return NSColor(hex: isDark ? dark : light)
                .withAlphaComponent(isDark ? darkAlpha : lightAlpha)
        })
    }
}

extension NSColor {
    convenience init(hex: UInt32) {
        self.init(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255,
                  green: CGFloat((hex >> 8) & 0xFF) / 255,
                  blue: CGFloat(hex & 0xFF) / 255, alpha: 1)
    }
}

// MARK: - Spacing (Carbon 8px grid; smaller steps for dense controls)

enum Space {
    static let x1: CGFloat = 2
    static let x2: CGFloat = 4
    static let x3: CGFloat = 8
    static let x4: CGFloat = 12
    static let x5: CGFloat = 16
    static let x6: CGFloat = 24
    static let x7: CGFloat = 32
    static let x8: CGFloat = 40
}

/// Corner radii — rounded toward native macOS (the Carbon thread stays in color + type).
enum Radius {
    static let control: CGFloat = 7
    static let field: CGFloat = 8
    static let card: CGFloat = 10
}

// MARK: - Typography (IBM Plex; Carbon type scale, productive)

enum CarbonFont {
    static func register() {
        guard let dir = Bundle.main.resourceURL,
              let urls = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: nil) else { return }
        for url in urls where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    private static let sans     = "IBMPlexSans"
    private static let text     = "IBMPlexSans-Text"
    private static let medium   = "IBMPlexSans-Medium"
    private static let semibold = "IBMPlexSans-SemiBold"
    private static let mono     = "IBMPlexMono"

    static func body(_ size: CGFloat = 14) -> Font { .custom(sans, size: size) }
    static func label(_ size: CGFloat = 12) -> Font { .custom(sans, size: size) }
    static func medium(_ size: CGFloat = 14) -> Font { .custom(medium, size: size) }
    static func semibold(_ size: CGFloat = 14) -> Font { .custom(semibold, size: size) }
    static func monospace(_ size: CGFloat = 12) -> Font { .custom(mono, size: size) }

    // Carbon productive type scale
    static var bodyText: Font { .custom(sans, size: 14) }
    static var heading: Font { .custom(semibold, size: 16) }       // heading-compact-02
    static var headingLg: Font { .custom(semibold, size: 20) }     // heading-04
    static var caption: Font { .custom(sans, size: 12) }
}
