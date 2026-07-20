import SwiftUI
import AppKit

/// The colophon "S." as a status-bar mark. Template by default (the menu bar recolors it);
/// pass a tint for a flat-colored variant. `dotColor`, when set, colors ONLY the period —
/// the mark's own "." doubling as a status indicator (e.g. call-proximity color) instead of
/// a separate badge dot composited elsewhere on the icon.
enum ScriptaMark {
    static func statusIcon(tint: NSColor? = nil, dotColor: NSColor? = nil) -> NSImage {
        let font = NSFont(name: "IBMPlexSans-SemiBold", size: 13) ?? .systemFont(ofSize: 13, weight: .semibold)
        let color = tint ?? .black
        let str = NSAttributedString(string: "S", attributes: [.font: font, .foregroundColor: color])
        let sSize = str.size()
        let square: CGFloat = 4, gap: CGFloat = 1.5
        let size = NSSize(width: ceil(sSize.width + gap + square), height: 14)
        let image = NSImage(size: size, flipped: false) { rect in
            let textY = (rect.height - sSize.height) / 2
            str.draw(at: NSPoint(x: 0, y: textY))
            let dot = NSBezierPath(roundedRect: NSRect(x: sSize.width + gap,
                                                       y: textY + abs(font.descender),
                                                       width: square, height: square),
                                   xRadius: 1, yRadius: 1)
            (dotColor ?? color).setFill(); dot.fill()
            return true
        }
        image.isTemplate = (tint == nil && dotColor == nil)
        image.accessibilityDescription = "Scripta"
        return image
    }
}

/// Renders a bundled IBM Carbon SVG icon as a template image, tinted with a Carbon token color.
/// Carbon icons are single-path monochrome, so template rendering + foreground tint is exact.
struct CarbonIcon: View {
    let name: String
    var size: CGFloat = 16
    var color: Color = Carbon.iconPrimary

    var body: some View {
        if let image = CarbonIcon.load(name) {
            Image(nsImage: image)
                .renderingMode(.template)
                .resizable()
                .interpolation(.high)
                .frame(width: size, height: size)
                .foregroundStyle(color)
        } else {
            // Missing-asset fallback keeps layout stable rather than collapsing.
            Color.clear.frame(width: size, height: size)
        }
    }

    private static var cache: [String: NSImage] = [:]

    static func load(_ name: String) -> NSImage? {
        if let cached = cache[name] { return cached }
        guard let path = Bundle.main.path(forResource: name, ofType: "svg"),
              let image = NSImage(contentsOfFile: path) else { return nil }
        image.isTemplate = true
        cache[name] = image
        return image
    }
}
