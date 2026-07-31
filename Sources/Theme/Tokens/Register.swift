import AppKit
import CoreText
import SwiftUI

// MARK: - Record & Register: the type layer
//
// Three registers, one job each. Every string in the app belongs to exactly one of them, and the
// register is what tells a reader whether they are looking at speech or at record:
//
//   PROSE  (IBM Plex Sans *Text*)  — human language. Transcript body, notes, summaries, answers.
//   UI     (Plex Sans Reg/Med/SB)  — chrome. Labels, buttons, headers, menu items, empty states.
//   MONO   (IBM Plex Mono)         — machine-generated fact. Timestamps, scopes, index versions,
//                                    measured numbers, refs, IDs, file paths, confidence values.
//
// If a string is a number the machine measured, it is mono even when it sits inside a sentence.
// If it is a word a person said, it is prose even when it sits inside a control.
//
// ENGINE VOCABULARY: A NAME IS UI, A VALUE IS MONO. This is the case the two rules above leave
// underdetermined, and it split two builders — `archived` and `superseded` went mono because "they
// are the words the CLI and the MCP envelope use", while `embed` and `hyde` sat beside them as
// engine words too. Both halves are engine vocabulary, so that test decides nothing. The test that
// does: the word naming WHICH FIELD you are looking at is chrome and takes UI; the word the engine
// PUT IN that field takes mono. `scope` / `prism` is the shape — the caption is a label a designer
// wrote, the token beside it is what the engine returned and what you would type to ask for it
// again. So: `unavailable`, `frozen`, `full stack`, `withheld`, `embed` are names, in UI.
// `archived`, `qwen2.5:7b`, `0.593`, `prism` are values, in mono. Where a vocabulary is a type,
// it declares its own register (`RetrievalClass.register`) so a second renderer cannot re-decide.
//
// 13 roles replace the 36 measured weight x size combinations in the app today. Sizes come from
// the actual distribution (11/12/13/14/15/17/20/26/28 are the real peaks), not from a scale
// invented on paper.

/// A resolved type role. Carries both the SwiftUI `Font` and the AppKit `NSFont` so the status
/// item, menu items and SwiftUI views cannot drift into different faces — the same reason `Tone`
/// is NSColor-first.
struct Typeface {
    /// Which register this role belongs to. Drives line height and the fallback face.
    enum Kind { case ui, prose, mono }

    /// PostScript name, verified against the TTFs in `Resources/Fonts`.
    let face: String
    let size: CGFloat
    let kind: Kind

    /// Dynamic Type anchor. Set on prose only in v1: `Font.custom(_:size:relativeTo:)` scales,
    /// `Font.custom(_:fixedSize:)` does not, so wiring it here now makes "turn on Dynamic Type"
    /// a later increment for the register that should scale, and a no-op for the chrome that
    /// must not reflow around it.
    let textStyle: Font.TextStyle?

    init(face: String, size: CGFloat, kind: Kind, textStyle: Font.TextStyle? = nil) {
        self.face = face
        self.size = size
        self.kind = kind
        self.textStyle = textStyle
    }

    var font: Font {
        if let textStyle {
            return .custom(face, size: size, relativeTo: textStyle)
        }
        return .custom(face, fixedSize: size)
    }

    /// Falls back to a *monospaced* system font for the mono register — a fallback that loses
    /// column alignment is worse than one that loses the typeface, because stat rows and
    /// timestamp gutters are laid out on the assumption that digits are one width.
    var nsFont: NSFont {
        if let resolved = NSFont(name: face, size: size) { return resolved }
        if kind == .mono { return .monospacedSystemFont(ofSize: size, weight: fallbackWeight) }
        return .systemFont(ofSize: size, weight: fallbackWeight)
    }

    var lineHeightMultiple: CGFloat {
        kind == .prose ? Metrics.lineHeightProse : Metrics.lineHeightUI
    }

    /// SwiftUI's `.lineSpacing` is *extra* leading, not a multiple, so the target line box has to
    /// be measured against the font's natural one or every prose block ends up over-leaded.
    var lineSpacing: CGFloat {
        let f = nsFont
        let natural = f.ascender - f.descender + f.leading
        return max(0, (size * lineHeightMultiple) - natural)
    }

    private var fallbackWeight: NSFont.Weight {
        switch face {
        case Register.Face.sansSemiBold: return .semibold
        case Register.Face.sansMedium, Register.Face.monoMedium: return .medium
        default: return .regular
        }
    }
}

enum Register {

    /// PostScript names. Note the family names differ from these (IBM ships each weight as its
    /// own family), so `NSFont(name:)` only resolves against the PostScript form.
    enum Face {
        static let sans = "IBMPlexSans"
        static let sansText = "IBMPlexSans-Text"
        static let sansMedium = "IBMPlexSans-Medium"
        static let sansSemiBold = "IBMPlexSans-SemiBold"
        static let mono = "IBMPlexMono"
        static let monoMedium = "IBMPlexMono-Medium"

        /// Every face this system can hand to `Font.custom`, declared beside the names themselves.
        /// The gallery's resolution check reads THIS — it used to keep its own copy, so a seventh
        /// face added here would have slipped past the one check whose entire job is catching a
        /// name that does not resolve.
        static let all: [String] = [sans, sansText, sansMedium, sansSemiBold, mono, monoMedium]
    }

    /// Registers the bundled Plex TTFs with CoreText for the calling process.
    ///
    /// Per BUNDLE, not per app: the gallery is its own bundle, so a registration that ran only in
    /// the app would leave every `Font.custom` there falling back to San Francisco *silently* —
    /// which is a type review of a typeface the product does not ship. `.process` scope because
    /// these are private to whoever is running, never installed for the user.
    ///
    /// Registering a face twice is a no-op that returns an error, so the result is deliberately
    /// unchecked: `Register.Face.all` resolving is the fact worth knowing, and the gallery asserts
    /// exactly that rather than trusting this call.
    static func registerFonts(in bundle: Bundle = .main) {
        guard let directory = bundle.resourceURL,
              let urls = try? FileManager.default.contentsOfDirectory(
                at: directory, includingPropertiesForKeys: nil)
        else { return }
        for url in urls where url.pathExtension == "ttf" {
            CTFontManagerRegisterFontsForURL(url as CFURL, .process, nil)
        }
    }

    // MARK: UI register — chrome

    /// Uppercase section labels and stat captions. Use `.microLabel()`, which adds the tracking.
    static let micro = Typeface(face: Face.sansMedium, size: 11, kind: .ui)
    static let caption = Typeface(face: Face.sans, size: 12, kind: .ui)
    static let ui = Typeface(face: Face.sans, size: 13, kind: .ui)
    static let uiEmphasis = Typeface(face: Face.sansMedium, size: 13, kind: .ui)
    static let bodyUI = Typeface(face: Face.sans, size: 14, kind: .ui)
    static let title3 = Typeface(face: Face.sansSemiBold, size: 17, kind: .ui)
    static let title2 = Typeface(face: Face.sansSemiBold, size: 20, kind: .ui)
    static let title1 = Typeface(face: Face.sansSemiBold, size: 26, kind: .ui)

    // MARK: Prose register — human language
    //
    // Plex Sans *Text* is the optical size IBM cuts for running copy; it ships in
    // `Resources/Fonts` and has never been used. Prose reading differently from chrome is the
    // whole "verba volant, scripta manent" distinction made structural.

    static let prose = Typeface(face: Face.sansText, size: 15, kind: .prose, textStyle: .body)
    static let proseSm = Typeface(face: Face.sansText, size: 14, kind: .prose, textStyle: .callout)
    static let proseLg = Typeface(face: Face.sansText, size: 17, kind: .prose, textStyle: .title3)

    // MARK: Mono register — machine-generated fact

    static let mono = Typeface(face: Face.mono, size: 12, kind: .mono)
    static let monoMicro = Typeface(face: Face.mono, size: 11, kind: .mono)
    /// Stat values. Moved off Sans SemiBold because mono numerals column-align, which is the one
    /// thing a row of stat tiles actually needs.
    static let numeral = Typeface(face: Face.monoMedium, size: 28, kind: .mono)

    /// Tracking for uppercase micro labels. Uppercase at 11pt closes up without it.
    static let microTracking: CGFloat = 0.4
}

// MARK: - Application

extension View {
    /// Font only.
    func typeface(_ face: Typeface) -> some View {
        font(face.font)
    }

    /// Font and color together. Two of the ~7 available modifier slots are spent on type at
    /// nearly every call site; collapsing them into one keeps components under the threshold.
    func typeface(_ face: Typeface, _ tone: Tone) -> some View {
        font(face.font).foregroundStyle(tone)
    }

    /// Prose is the only register with a line-height opinion — UI chrome sets its rhythm from
    /// control heights instead, so applying prose leading to it just loosens dense rows.
    func proseText(_ face: Typeface = Register.prose, _ tone: Tone = Ink.textPrimary) -> some View {
        font(face.font).foregroundStyle(tone).lineSpacing(face.lineSpacing)
    }

    /// 11pt is the single most-used size in the app (35 call sites) and nearly all of them are
    /// this same uppercase-plus-tracking treatment. Four wraps collapsed into one, for the same
    /// threshold reason as `typeface(_:_:)`.
    func microLabel(_ tone: Tone = Ink.textSecondary) -> some View {
        font(Register.micro.font)
            .tracking(Register.microTracking)
            .textCase(.uppercase)
            .foregroundStyle(tone)
    }
}
