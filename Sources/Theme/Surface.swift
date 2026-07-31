import SwiftUI

// MARK: - Record & Register: elevation and motion

/// Hairline border over shadow is the house style and stays that way: a hairline reads at any
/// window opacity and over vibrancy, where a shadow turns into a gray smear. Shadow is reserved
/// for surfaces that genuinely float free of the layout — drawers, popovers, sheets.
enum Elevation {
    static let hairline: CGFloat = 1
    /// Title-bar controls, where a full point reads as a heavy outline against vibrancy.
    static let hairlineThin: CGFloat = 0.5

    static let overlayRadius: CGFloat = 24
    static let overlayY: CGFloat = 8
}

/// Named by intent, not by duration, so a timing change is one edit and every surface that shares
/// the intent moves together.
enum Motion {
    /// Pointer-driven feedback. Short enough that it never lags the cursor.
    static let hover: Animation = .easeOut(duration: 0.12)
    /// A control changing what it means — selected, enabled, expanded.
    static let state: Animation = .easeInOut(duration: 0.18)
    /// Panels entering and leaving. The one place worth a spring.
    static let drawer: Animation = .spring(response: 0.34, dampingFraction: 0.86)
    /// Continuously-driven readouts (input meters, progress). Linear, because easing a stream of
    /// samples makes the value look like it is lying.
    static let meter: Animation = .linear(duration: 0.08)
}

/// A horizontal rule that dashes cleanly at 1pt. `Divider` and a stroked `Rectangle` both draw
/// four sides; this draws one, so the dash phase starts where the text starts.
///
/// THE DOTTED TEXTURE IS RESERVED. It means "we have no basis for a verdict" — the third state in
/// `EngineEnvelope`, beside SOLID (we measured this) and COLOUR (something departed). Reach for
/// this shape only through `staleUnderline(_:)` or for that meaning. A dotted line spent as a row
/// separator teaches the texture as decoration, and then the one place it carries a claim says
/// nothing. Separators are a solid hairline in `Ink.borderSubtle`.
struct DottedRule: Shape {
    func path(in rect: CGRect) -> Path {
        var path = Path()
        path.move(to: CGPoint(x: rect.minX, y: rect.midY))
        path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
        return path
    }
}

extension View {
    /// Fill plus hairline in one wrap. Pass `border: nil` for a fill-only surface.
    func surface(_ fill: Tone = Ink.layer,
                 radius: CGFloat = Corner.card,
                 border: Tone? = Ink.borderSubtle,
                 width: CGFloat = Elevation.hairline) -> some View {
        background(fill, in: Corner.shape(radius))
            .overlay {
                if let border {
                    Corner.shape(radius).strokeBorder(border, lineWidth: width)
                }
            }
    }

    /// Border without a fill — over vibrancy, or over a background the parent already set.
    func hairline(_ tone: Tone = Ink.borderSubtle,
                  radius: CGFloat = Corner.card,
                  width: CGFloat = Elevation.hairline) -> some View {
        overlay {
            Corner.shape(radius).strokeBorder(tone, lineWidth: width)
        }
    }

    /// The one real elevation. Everything else uses `surface`/`hairline`.
    func overlayShadow() -> some View {
        shadow(color: Ink.overlayShadow.color,
               radius: Elevation.overlayRadius,
               x: 0,
               y: Elevation.overlayY)
    }

    /// Marks a mono value as computed against an index that has moved on since — a normal state
    /// for a minute after every ingest, which is why it is texture rather than the alarm colour a
    /// yellow badge would give it. Sits outside the text's own bounds, so it never reflows a row.
    func staleUnderline(_ tone: Tone = Ink.stale, offset: CGFloat = 2) -> some View {
        overlay(alignment: .bottom) {
            DottedRule()
                .stroke(tone, style: StrokeStyle(lineWidth: Elevation.hairline,
                                                 lineCap: .butt, dash: [1.5, 2.5]))
                .frame(height: Elevation.hairline)
                .offset(y: offset)
        }
    }
}
