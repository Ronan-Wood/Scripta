import AppKit
import SwiftUI

// MARK: - Record & Register: icons
//
// SF Symbols replace the 27 bundled Carbon SVGs. Three things are bought by the swap:
//
//   1. The name becomes a CASE. `CarbonIcon(name: "checkmark")` compiles today, resolves nothing,
//      and draws `Color.clear` — there is no `checkmark.svg` in `Resources/CarbonIcons`, so two
//      call sites in this app are shipping an invisible icon right now. `Icon(.check)` cannot be
//      misspelled.
//   2. Optical alignment and Dynamic Type scaling come from the system rather than from a fixed
//      `.frame(width:height:)` around a raster.
//   3. 27 assets and a `NSImage` cache leave the bundle.

/// Every icon the app is allowed to draw. The raw value is the SF Symbol name.
///
/// Adding an icon is adding a case here, which is the point: the set is reviewable in one screen
/// and a view cannot invent one. Cases are named for the JOB, not the picture — `stale`, not
/// `clockArrow` — so swapping the symbol later is a one-line change and not a rename across the app.
enum Glyph: String, CaseIterable, Identifiable {

    // Navigation and structure
    case home = "house"
    case list = "list.bullet"
    case folder = "folder"
    case document = "doc.text"
    case book = "book"
    case tag = "tag"
    case calendar = "calendar"
    case chat = "bubble.left.and.bubble.right"
    case person = "person"
    case people = "person.2"

    // Movement
    case chevronRight = "chevron.right"
    case chevronDown = "chevron.down"
    case chevronLeft = "chevron.left"
    case arrowRight = "arrow.right"
    case arrowLeft = "arrow.left"
    case ellipsis = "ellipsis"

    // Capture and playback
    case microphone = "mic"
    case record = "record.circle"
    case recording = "record.circle.fill"
    case play = "play.fill"
    case pause = "pause.fill"
    case stop = "stop.fill"
    case waveform = "waveform"
    case meter = "speedometer"

    // Editing and action
    case edit = "square.and.pencil"
    case add = "plus"
    case remove = "minus"
    case close = "xmark"
    case check = "checkmark"
    case trash = "trash"
    case copy = "doc.on.doc"
    case share = "square.and.arrow.up"
    case send = "paperplane.fill"
    case search = "magnifyingglass"
    case filter = "line.3.horizontal.decrease"
    case refresh = "arrow.clockwise"
    case link = "link"
    case settings = "gearshape"
    case view = "eye"
    /// Reading a note: fill the pane, hand the pane back, or tear the note off into its own window.
    case expand = "arrow.up.left.and.arrow.down.right"
    case collapse = "arrow.down.right.and.arrow.up.left"
    case launch = "macwindow"

    // State — deviation only, per rule 3. These are the icons that mean something departed.
    case warning = "exclamationmark.triangle"
    case error = "exclamationmark.octagon"
    case info = "info.circle"
    case help = "questionmark.circle"
    case stale = "clock.arrow.circlepath"
    case time = "clock"
    case dot = "circle.fill"
    case sparkle = "sparkles"

    var id: String { rawValue }

    /// The case name, for the gallery sheet and for assertion text. Not an accessibility label —
    /// `Icon` is decorative by construction and `IconButton` demands a written one.
    var title: String { String(describing: self) }
}

extension Glyph {
    /// Symbols this OS cannot resolve. Normally empty; computed once.
    ///
    /// The whole reason this exists is that the failure it guards is already in the codebase and
    /// silent. An icon that is simply not there and says nothing is worse than a crash, because a
    /// crash gets fixed.
    static let unresolved: [Glyph] = allCases.filter {
        NSImage(systemSymbolName: $0.rawValue, accessibilityDescription: nil) == nil
    }

    static func resolves(_ glyph: Glyph) -> Bool { !unresolved.contains(glyph) }

    /// Traps in debug on the first unresolvable symbol. Call once at launch. In release the icon
    /// draws as a red box instead — loud, but not fatal to a user mid-recording.
    static func audit() {
        assert(unresolved.isEmpty,
               "Glyph cases with no SF Symbol on this system: "
                 + unresolved.map { "\($0.title) → \"\($0.rawValue)\"" }.joined(separator: ", "))
    }
}

// MARK: - View

/// An SF Symbol sized off the type register, so an icon beside a label is optically matched to it
/// without either one carrying a number.
///
/// Always decorative: it hides itself from accessibility. The meaning lives in the adjacent text,
/// or — for an icon-only control — in `IconButton`'s required label.
struct Icon: View {
    let glyph: Glyph
    var face: Typeface = Register.ui
    var tone: Tone = Ink.iconSecondary

    init(_ glyph: Glyph, _ face: Typeface = Register.ui, _ tone: Tone = Ink.iconSecondary) {
        self.glyph = glyph
        self.face = face
        self.tone = tone
    }

    var body: some View {
        if Glyph.resolves(glyph) {
            Image(systemName: glyph.rawValue)
                .font(.system(size: face.size, weight: face.symbolWeight))
                .symbolRenderingMode(.monochrome)
                .foregroundStyle(tone)
                .accessibilityHidden(true)
        } else {
            MissingGlyph(glyph: glyph, size: face.size)
        }
    }
}

/// What an unresolvable symbol looks like: a danger-tinted box the exact size the icon would have
/// been, with the failing name in its tooltip. It holds layout like the old `Color.clear` fallback
/// did, and unlike it, nobody can miss it.
private struct MissingGlyph: View {
    let glyph: Glyph
    let size: CGFloat

    var body: some View {
        Color.clear
            .frame(width: size, height: size)
            // `Corner.control`, not `Elevation.hairline` — that is a 1.0 STROKE WIDTH and was being
            // handed to a radius. At icon sizes 7 clamps to half the side, so this draws as a
            // rounded blob rather than a square; loud is the requirement, not geometry.
            .surface(Ink.dangerSoft, radius: Corner.control, border: Ink.danger)
            .help("No SF Symbol \"\(glyph.rawValue)\" for Glyph.\(glyph.title)")
    }
}

private extension Typeface {
    /// SF Symbols carry weight, not face. Mapped off the register's PostScript name so an icon set
    /// beside `uiEmphasis` text is not visibly lighter than the words next to it.
    var symbolWeight: Font.Weight {
        switch face {
        case Register.Face.sansSemiBold: return .semibold
        case Register.Face.sansMedium, Register.Face.monoMedium: return .medium
        default: return .regular
        }
    }
}
