import AppKit
import SwiftUI

/// The whole `Ink` table as data, so the gallery and the contrast grid iterate one list instead of
/// each hand-listing tokens and quietly disagreeing about which ones exist.
///
/// This catalogue cannot detect a token added to `Ink` and not added here — nothing in a compiled
/// binary can enumerate the members of an enum of `static let`s. The check that CAN is
/// `ContrastGateTests.testEveryTokenParticipatesInTheGate`, which parses `Ink.swift`. Treat this
/// list as the gallery's rendering order, not as proof of coverage.
struct InkToken: Identifiable {
    let name: String
    let tone: Tone
    let note: String?

    var id: String { name }

    init(_ name: String, _ tone: Tone, _ note: String? = nil) {
        self.name = name
        self.tone = tone
        self.note = note
    }
}

struct InkGroup: Identifiable {
    let title: String
    let rule: String?
    let tokens: [InkToken]

    var id: String { title }
}

enum InkCatalog {
    static let groups: [InkGroup] = [
        InkGroup(title: "Interaction", rule: "Rule 2 — blue appears here and nowhere else.", tokens: [
            InkToken("interactive", Ink.interactive, "primary fill, link, selected nav row"),
            InkToken("interactiveHover", Ink.interactiveHover),
            InkToken("interactiveSoft", Ink.interactiveSoft, "selected-row wash"),
            InkToken("interactiveSubtle", Ink.interactiveSubtle, "hover wash"),
            InkToken("focusRing", Ink.focusRing, "alias of interactive"),
            InkToken("onInteractive", Ink.onInteractive, "foreground on a filled control"),
        ]),
        InkGroup(title: "Text", rule: nil, tokens: [
            InkToken("textPrimary", Ink.textPrimary),
            InkToken("textSecondary", Ink.textSecondary),
            InkToken("textHelper", Ink.textHelper),
            InkToken("textPlaceholder", Ink.textPlaceholder),
            InkToken("textDisabled", Ink.textDisabled),
            InkToken("textOnColor", Ink.textOnColor),
        ]),
        InkGroup(title: "Icons", rule: nil, tokens: [
            InkToken("iconPrimary", Ink.iconPrimary),
            InkToken("iconSecondary", Ink.iconSecondary),
        ]),
        InkGroup(title: "Surfaces", rule: nil, tokens: [
            InkToken("background", Ink.background),
            InkToken("layer", Ink.layer),
            InkToken("layerHover", Ink.layerHover),
            InkToken("layerSelected", Ink.layerSelected),
            InkToken("layerAlt", Ink.layerAlt, "stacked above layer"),
            InkToken("field", Ink.field),
            InkToken("fieldHover", Ink.fieldHover),
        ]),
        InkGroup(title: "Borders", rule: nil, tokens: [
            InkToken("borderSubtle", Ink.borderSubtle, "separator between adjacent surfaces"),
            InkToken("borderStrong", Ink.borderStrong, "control boundary"),
            InkToken("borderFocus", Ink.borderFocus, "alias of interactive"),
        ]),
        InkGroup(title: "Chrome", rule: "Translucent — drawn over window vibrancy, not over a surface.", tokens: [
            InkToken("sidebarTint", Ink.sidebarTint),
            InkToken("titlebarTint", Ink.titlebarTint),
            InkToken("scrim", Ink.scrim),
            InkToken("overlayShadow", Ink.overlayShadow),
        ]),
        InkGroup(title: "State", rule: "Rule 3 — every one of these means something deviated from the default.", tokens: [
            InkToken("danger", Ink.danger),
            InkToken("dangerHover", Ink.dangerHover),
            InkToken("dangerSoft", Ink.dangerSoft),
            InkToken("warning", Ink.warning, "two ramp steps: yellow60 light, yellow30 dark"),
            InkToken("warningSoft", Ink.warningSoft),
            InkToken("success", Ink.success),
            InkToken("successSoft", Ink.successSoft),
            InkToken("stale", Ink.stale, "index moved on; texture carries it, not hue"),
            InkToken("staleSoft", Ink.staleSoft),
        ]),
        InkGroup(title: "Speakers", rule: "One coloured party against one neutral. `me` is ink + weight.", tokens: [
            InkToken("speaker.me", Ink.speaker.me, "pair with Register.uiEmphasis"),
            InkToken("speaker.meSoft", Ink.speaker.meSoft),
            InkToken("speaker.amber", Ink.speaker.amber, "alt(0)"),
            InkToken("speaker.amberSoft", Ink.speaker.amberSoft),
            InkToken("speaker.violet", Ink.speaker.violet, "alt(1)"),
            InkToken("speaker.violetSoft", Ink.speaker.violetSoft),
            InkToken("speaker.teal", Ink.speaker.teal, "alt(2)"),
            InkToken("speaker.tealSoft", Ink.speaker.tealSoft),
            InkToken("speaker.rose", Ink.speaker.rose, "alt(3)"),
            InkToken("speaker.roseSoft", Ink.speaker.roseSoft),
        ]),
    ]

    static var allTokens: [InkToken] { groups.flatMap(\.tokens) }

    /// Hand-counted against `Ink` + `Ink.speaker` on the day the layer landed, and reported rather
    /// than asserted — see the type comment for why the gallery cannot police its own coverage.
    static let countAtLanding = 47

    // MARK: Roles the contrast grid needs to know about

    /// Opaque surfaces anything can be drawn on.
    static let surfaces: [InkToken] = [
        InkToken("background", Ink.background),
        InkToken("layer", Ink.layer),
        InkToken("layerHover", Ink.layerHover),
        InkToken("layerSelected", Ink.layerSelected),
        InkToken("layerAlt", Ink.layerAlt),
        InkToken("field", Ink.field),
        InkToken("fieldHover", Ink.fieldHover),
    ]

    /// Foregrounds, with the WCAG level each one's role actually demands. `nil` means the pairing
    /// is measured but not gated — stated per entry, never left to be inferred.
    static let foregrounds: [(token: InkToken, required: Double?)] = [
        (InkToken("textPrimary", Ink.textPrimary), Wcag.bodyText),
        (InkToken("textSecondary", Ink.textSecondary), Wcag.bodyText),
        (InkToken("textHelper", Ink.textHelper), Wcag.bodyText),
        (InkToken("textPlaceholder", Ink.textPlaceholder), Wcag.bodyText),
        (InkToken("textDisabled", Ink.textDisabled, "1.4.3 exempts inactive controls"), nil),
        (InkToken("iconPrimary", Ink.iconPrimary), Wcag.largeOrUI),
        (InkToken("iconSecondary", Ink.iconSecondary), Wcag.largeOrUI),
        (InkToken("interactive", Ink.interactive), Wcag.bodyText),
        (InkToken("interactiveHover", Ink.interactiveHover), Wcag.bodyText),
        (InkToken("focusRing", Ink.focusRing, "1.4.11 focus indicator"), Wcag.largeOrUI),
        (InkToken("borderStrong", Ink.borderStrong, "1.4.11 control boundary"), Wcag.largeOrUI),
        (InkToken("borderSubtle", Ink.borderSubtle, "decorative separator"), nil),
        (InkToken("danger", Ink.danger), Wcag.bodyText),
        (InkToken("dangerHover", Ink.dangerHover), Wcag.bodyText),
        (InkToken("success", Ink.success), Wcag.bodyText),
        (InkToken("warning", Ink.warning, "marker words in the envelope — gated as body copy"), Wcag.bodyText),
        (InkToken("stale", Ink.stale), Wcag.bodyText),
        (InkToken("speaker.me", Ink.speaker.me), Wcag.bodyText),
        (InkToken("speaker.amber", Ink.speaker.amber), Wcag.bodyText),
        (InkToken("speaker.violet", Ink.speaker.violet), Wcag.bodyText),
        (InkToken("speaker.teal", Ink.speaker.teal), Wcag.bodyText),
        (InkToken("speaker.rose", Ink.speaker.rose), Wcag.bodyText),
    ]

    /// Soft washes, each with the ink it is designed to sit under. This is where the system loses
    /// contrast it looks like it has: a 14% wash of the same hue lifts the background toward the
    /// foreground, so `danger on dangerSoft` is materially weaker than `danger on layer`.
    static let washes: [(wash: InkToken, ink: InkToken)] = [
        (InkToken("interactiveSoft", Ink.interactiveSoft), InkToken("interactive", Ink.interactive)),
        (InkToken("interactiveSubtle", Ink.interactiveSubtle), InkToken("interactive", Ink.interactive)),
        (InkToken("dangerSoft", Ink.dangerSoft), InkToken("danger", Ink.danger)),
        (InkToken("successSoft", Ink.successSoft), InkToken("success", Ink.success)),
        (InkToken("warningSoft", Ink.warningSoft), InkToken("textPrimary", Ink.textPrimary)),
        (InkToken("staleSoft", Ink.staleSoft), InkToken("stale", Ink.stale)),
        (InkToken("speaker.meSoft", Ink.speaker.meSoft), InkToken("speaker.me", Ink.speaker.me)),
        (InkToken("speaker.amberSoft", Ink.speaker.amberSoft), InkToken("speaker.amber", Ink.speaker.amber)),
        (InkToken("speaker.violetSoft", Ink.speaker.violetSoft), InkToken("speaker.violet", Ink.speaker.violet)),
        (InkToken("speaker.tealSoft", Ink.speaker.tealSoft), InkToken("speaker.teal", Ink.speaker.teal)),
        (InkToken("speaker.roseSoft", Ink.speaker.roseSoft), InkToken("speaker.rose", Ink.speaker.rose)),
    ]

    /// Saturated fills the system offers a named foreground for.
    static let fills: [(fill: InkToken, ink: InkToken)] = [
        (InkToken("interactive", Ink.interactive), InkToken("onInteractive", Ink.onInteractive)),
        (InkToken("interactiveHover", Ink.interactiveHover), InkToken("onInteractive", Ink.onInteractive)),
        (InkToken("danger", Ink.danger), InkToken("textOnColor", Ink.textOnColor)),
        (InkToken("dangerHover", Ink.dangerHover), InkToken("textOnColor", Ink.textOnColor)),
        (InkToken("success", Ink.success), InkToken("textOnColor", Ink.textOnColor)),
        (InkToken("warning", Ink.warning), InkToken("textOnColor", Ink.textOnColor)),
    ]
}
