import XCTest

// MARK: - Does the speaker ramp survive colour blindness?
//
// The direction states the claim outright: "`alt` opens amber/violet because that pair sits on the
// blue–orange axis dichromats retain". That is a falsifiable claim about four specific hexes, so it
// is checked rather than believed — it is exactly the kind of statement that ships unverified and
// then gets quoted as if it had been.
//
// THE THRESHOLD WAS FIXED FIRST. ΔE2000 ≥ 15 was chosen before any number was computed: around 1 is
// a just-noticeable difference, 2-3 is visible at a glance, and by 15 two colours read as different
// colours rather than two versions of one. A floor picked after seeing the results is not a floor.

enum SpeakerRamp {
    /// The four coloured parties, in the order `Ink.speaker.alt(_:)` hands them out. `me` is not a
    /// member: it is neutral ink whose identity is carried by weight (`Register.uiEmphasis`), so it
    /// is tested separately and against a claim the design does not actually make.
    static let parties = ["amber", "violet", "teal", "rose"]

    static let separationFloor: Double = 15

    /// The pair the direction's claim rests on. Kept apart from the four-way matrix because the
    /// third and fourth parties are described as already rare — a collapse there costs much less
    /// than a collapse here.
    static let axisClaim = ("amber", "violet")
}

/// A pair that falls below the floor once dichromacy is simulated. Recorded with the value it
/// measures, on the same terms as the contrast ledger: a fix or a regression both fail the build.
struct Collapse {
    let first: String
    let second: String
    let appearance: Appearance
    let kind: Dichromacy
    let measured: Double
    let cause: CollapseCause

    init(_ first: String, _ second: String, _ appearance: Appearance, _ kind: Dichromacy,
         measured: Double, cause: CollapseCause) {
        self.first = first
        self.second = second
        self.appearance = appearance
        self.kind = kind
        self.measured = measured
        self.cause = cause
    }

    var key: String { "\(first)/\(second) [\(appearance.rawValue) · \(kind.rawValue)]" }
}

enum CollapseCause: String {
    case thirdAndFourthPartyConverge
    case blueYellowAxisIsNotRetainedByTritanopes
    case neutralPartyRestsOnWeightNotHue

    var explanation: String {
        switch self {
        case .thirdAndFourthPartyConverge:
            return "teal30 and rose40 — the dark-appearance third and fourth parties — land 11.97 apart under deuteranopia. A four-speaker transcript in dark mode has two parties that read as one colour. The direction already treats 3+ speakers as rare; it does not claim they survive."
        case .blueYellowAxisIsNotRetainedByTritanopes:
            return "the palette is built on the blue-orange axis, which is precisely the axis tritanopia removes. amber40/rose40 measure ΔE 0.94 — not similar, identical. Rare (tritanopia is far below red-green prevalence) but total where it applies, and no amount of choosing between these four colours fixes it."
        case .neutralPartyRestsOnWeightNotHue:
            return "under protanopia in dark appearance, teal30 desaturates to a light neutral 8.78 from `me`'s gray10. The design's own answer is that `me` is identified by weight, not hue — which holds only while every renderer honours the uiEmphasis pairing rule."
        }
    }
}

final class SpeakerVisionTests: XCTestCase {

    private var tokens: ThemeTokens!

    override func setUpWithError() throws {
        tokens = try ThemeTokens.loadFromRepository()
    }

    private func simulated(_ party: String, _ appearance: Appearance, _ kind: Dichromacy) throws -> TokenRGB {
        VisionSim.simulate(try tokens.color("speaker.\(party)", appearance), kind)
    }

    /// A simulation that mangles neutrals is a simulation with a transposed matrix, and it would
    /// make every number below meaningless in a direction nobody would notice. Dichromats see
    /// neutrals as neutral, so this must be ~0.
    func testSimulationLeavesNeutralsUnchanged() throws {
        for token in ["background", "layer", "textPrimary", "borderStrong"] {
            for appearance in Appearance.allCases {
                let base = try tokens.color(token, appearance)
                for kind in Dichromacy.allCases {
                    let delta = Perceptual.deltaE2000(base, VisionSim.simulate(base, kind))
                    XCTAssertLessThan(delta, 0.5,
                                      "\(kind.rawValue) shifted the neutral \(token) [\(appearance.rawValue)] by ΔE \(delta)")
                }
            }
        }
    }

    /// The headline claim. Verified: simulation *widens* the amber/violet gap rather than closing
    /// it (ΔE 51.8 → 74.7 under deuteranopia in light), because the two collapse onto opposite
    /// ends of the one axis a dichromat keeps. This is the part of the direction that holds.
    func testAmberVioletPairSurvivesRedGreenDichromacy() throws {
        let (first, second) = SpeakerRamp.axisClaim
        for appearance in Appearance.allCases {
            for kind in [Dichromacy.deuteranopia, .protanopia] {
                let delta = Perceptual.deltaE2000(try simulated(first, appearance, kind),
                                                  try simulated(second, appearance, kind))
                XCTAssertGreaterThanOrEqual(delta, SpeakerRamp.separationFloor, String(
                    format: "%@/%@ collapse to ΔE %.2f under %@ [%@] — the blue-orange axis claim does not hold",
                    first, second, delta, kind.rawValue, appearance.rawValue))
            }
        }
    }

    /// The four-way matrix. Not all of it holds — see `Collapses.recorded`.
    func testFourPartyRampRemainsMutuallyDistinguishable() throws {
        var unrecorded: [String] = []
        for appearance in Appearance.allCases {
            for kind in Dichromacy.allCases {
                for i in SpeakerRamp.parties.indices {
                    for j in SpeakerRamp.parties.indices where j > i {
                        let (a, b) = (SpeakerRamp.parties[i], SpeakerRamp.parties[j])
                        let delta = Perceptual.deltaE2000(try simulated(a, appearance, kind),
                                                          try simulated(b, appearance, kind))
                        guard delta < SpeakerRamp.separationFloor else { continue }
                        let key = "\(a)/\(b) [\(appearance.rawValue) · \(kind.rawValue)]"
                        if Collapses.byKey[key] == nil {
                            unrecorded.append(String(format: "%@ — ΔE %.2f, floor %.0f",
                                                     key, delta, SpeakerRamp.separationFloor))
                        }
                    }
                }
            }
        }
        XCTAssertTrue(unrecorded.isEmpty, """
            \(unrecorded.count) speaker pair(s) collapse under simulation and are not recorded:
            \(unrecorded.joined(separator: "\n"))
            """)
    }

    /// `me` against each coloured party. The design does not claim hue separation here — weight is
    /// the signal — so a failure is a constraint on renderers, not a broken palette. Measured all
    /// the same, because "the pairing rule covers it" is only true while the rule is followed.
    ///
    /// ALL THREE KINDS. This filtered `kind != .tritanopia` with no reason given, in a file whose
    /// whole subject is that an exclusion must be stated — skipping 8 of the 24 separations its
    /// name claims to measure, in the axis this file elsewhere calls the palette's weakest. The
    /// eight all clear the floor comfortably (27.66 is the tightest), so nothing was being hidden;
    /// what was being hidden is that nobody could tell.
    func testNeutralSelfPartySeparationIsMeasured() throws {
        var unrecorded: [String] = []
        for appearance in Appearance.allCases {
            for kind in Dichromacy.allCases {
                let me = VisionSim.simulate(try tokens.color("speaker.me", appearance), kind)
                for party in SpeakerRamp.parties {
                    let delta = Perceptual.deltaE2000(me, try simulated(party, appearance, kind))
                    guard delta < SpeakerRamp.separationFloor else { continue }
                    let key = "me/\(party) [\(appearance.rawValue) · \(kind.rawValue)]"
                    if Collapses.byKey[key] == nil {
                        unrecorded.append(String(format: "%@ — ΔE %.2f", key, delta))
                    }
                }
            }
        }
        XCTAssertTrue(unrecorded.isEmpty,
                      "unrecorded neutral/party collapses:\n\(unrecorded.joined(separator: "\n"))")
    }

    /// Same discipline as the contrast ledger: a recorded collapse that changed value, or stopped
    /// collapsing, fails the build so the row cannot outlive the fact.
    func testRecordedCollapsesStillMeasureWhatWasRecorded() throws {
        var drifted: [String] = []
        for collapse in Collapses.recorded {
            let a = collapse.first == "me"
                ? VisionSim.simulate(try tokens.color("speaker.me", collapse.appearance), collapse.kind)
                : try simulated(collapse.first, collapse.appearance, collapse.kind)
            let b = try simulated(collapse.second, collapse.appearance, collapse.kind)
            let delta = Perceptual.deltaE2000(a, b)
            if delta >= SpeakerRamp.separationFloor {
                drifted.append(String(format: "%@ — now ΔE %.2f, clears the floor. Delete this row.",
                                      collapse.key, delta))
            } else if abs(delta - collapse.measured) > 0.01 {
                drifted.append(String(format: "%@ — recorded ΔE %.2f, now %.2f.",
                                      collapse.key, collapse.measured, delta))
            }
        }
        XCTAssertTrue(drifted.isEmpty, "collapse ledger out of date:\n\(drifted.joined(separator: "\n"))")
    }
}

enum Collapses {
    /// Measured 2026-07-30 against Sources/Theme/Tokens/Ink.swift as first landed.
    static let recorded: [Collapse] = [
        Collapse("teal", "rose", .dark, .deuteranopia, measured: 11.97, cause: .thirdAndFourthPartyConverge),
        Collapse("me", "teal", .dark, .protanopia, measured: 8.78, cause: .neutralPartyRestsOnWeightNotHue),
        // 8.00 -> 3.07, and this one was PAID rather than discovered. Darkening amber60 to Carbon
        // orange-60 lifted it from 3.56:1 to 5.03:1 — the ramp's only ink that could not carry body
        // text, and the ink on every speaker name in every light-mode call, because `Speaker` is
        // `{You, Them}` and slot 0 is the only reachable party. The cost is that a darker orange
        // sits closer to rose once the blue-yellow axis is gone.
        //
        // Taken deliberately: the contrast failure reached every light-mode reader of every call,
        // while amber/rose adjacency needs a FOUR-party transcript, which the current `Speaker`
        // vocabulary cannot produce. If parties three and four ever become reachable, this row is
        // the thing to re-open — not the contrast fix.
        Collapse("amber", "rose", .light, .tritanopia, measured: 3.07, cause: .blueYellowAxisIsNotRetainedByTritanopes),
        Collapse("violet", "teal", .light, .tritanopia, measured: 10.78, cause: .blueYellowAxisIsNotRetainedByTritanopes),
        Collapse("amber", "rose", .dark, .tritanopia, measured: 0.94, cause: .blueYellowAxisIsNotRetainedByTritanopes),
    ]

    static let byKey: [String: Collapse] = Dictionary(recorded.map { ($0.key, $0) },
                                                      uniquingKeysWith: { first, _ in first })
}
