import SwiftUI
import AppKit

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
