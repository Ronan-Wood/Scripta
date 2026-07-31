import Foundation
import XCTest

// MARK: - Two implementations of one published spec, held to being the same one
//
// `Sources/Gallery/ColorScience.swift` and `Core/Tests/ScriptaCoreTests/ColorMetrics.swift` each
// implement WCAG relative luminance, sRGB src-over compositing, the Viénot–Brettel–Mollon dichromat
// simulation, CIELAB and CIEDE2000 — about 200 lines including two hand-transcribed 3x3 matrices.
// Both files acknowledged the duplication in prose and neither did anything about it, so a
// transposed sign in one `deltaE2000` would have left the gallery's on-screen verdicts and this
// package's assertions describing different systems, with nothing to say so.
//
// MOVING THE MATH INTO A SHARED TARGET IS THE REAL FIX AND IS NOT THIS. Until it happens, the
// duplication is checked rather than hoped.
//
// WHICH APPROACH, AND WHY. Two were available: read the gallery's source the way
// `ThemeTokenSource` reads `Ink.swift`, or compare both against recorded reference values. This
// does both, because each covers exactly what the other cannot:
//
//   * READING THE SOURCE is the only thing that can speak about the gallery AT ALL. This target
//     cannot import it and cannot execute it, so no number computed here says anything about what
//     the gallery does. What text CAN prove is stronger than any finite input spread: not "the two
//     agreed on 45 samples" but "the two are the same arithmetic". So the shared regions of both
//     files were made character-for-character identical, and `testGalleryAndCoreShareOneColourMath`
//     slices and compares them. Any edit to one that is not made to the other fails here.
//
//   * RECORDED VALUES are what text cannot give: that the arithmetic is RIGHT, not merely shared.
//     Two anchors are independent of this code — the published CIELAB coordinates of the sRGB
//     primaries, and WCAG's own 21:1 for white on black — and the rest is a gamut spread pinned to
//     the values it measures today, because a restructure that changes behaviour should be loud
//     even when it is applied to both files at once.
//
// THE COST, stated the way `ThemeTokenSource` states its own: this couples to the SHAPE of two
// files. Reformat a formula in one and this fails until it is reformatted in the other, which is
// the point and is also genuinely annoying. The floors below exist so that a slice which quietly
// matches nothing cannot pass.

// MARK: Sources

/// A stretch of arithmetic both files must spell identically, cut so that it contains no colour
/// type: `TokenRGB` here and `NSColor` there is the one difference that is allowed to exist, so
/// every region begins after the unpacking line and ends before the packing one.
struct MathRegion {
    let name: String
    /// What a mismatch here would mean, printed on failure — a diff that only says "not equal"
    /// gets resolved by copying one side over the other without reading either.
    let stakes: String
    let start: String
    /// `nil` runs to the end of the file.
    let end: String?
    /// A constant that must appear in the slice. Guards against a needle matching somewhere else
    /// entirely and the comparison then passing on two irrelevant fragments.
    let anchor: String
}

enum ColourMath {
    static let galleryPath = "Sources/Gallery/ColorScience.swift"
    static let corePath = "Core/Tests/ScriptaCoreTests/ColorMetrics.swift"

    static let regions: [MathRegion] = [
        MathRegion(name: "sRGB transfer functions",
                   stakes: "linear() and encode() are the gamma boundary every other number here "
                        + "crosses. A wrong exponent moves every ratio, every ΔE and every "
                        + "simulated colour at once, in the same direction, invisibly.",
                   start: "static func linear(", end: "static func luminance(",
                   anchor: "0.04045"),
        MathRegion(name: "Viénot–Brettel–Mollon matrices",
                   stakes: "two hand-transcribed 3x3 matrices — 18 numbers typed from a paper. "
                        + "This is where a transposition actually happens, and a transposed LMS "
                        + "matrix produces plausible colours that are the wrong ones.",
                   start: "let rgbToLms", end: "static func simulate(",
                   anchor: "17.8824"),
        MathRegion(name: "the three dichromat projections",
                   stakes: "one sign per line decides which cone is being collapsed onto which "
                        + "plane. Flip one and the palette is measured against a deficiency "
                        + "nobody has.",
                   // `case .protanopia: lms[0]`, not `case .protanopia:` — the gallery's
                   // `Dichromacy.short` switches on the same cases forty lines earlier, and the
                   // shorter needle matched THAT, swallowing the whole of `VisionSim` into the
                   // slice. The anchor did not save it, because the constant was inside the
                   // oversized region too. A needle has to be unique, not merely present.
                   start: "case .protanopia: lms[0]", end: "let out = ",
                   anchor: "2.02344"),
        MathRegion(name: "CIELAB under D65",
                   stakes: "the sRGB→XYZ matrix, the f() cube-root branch and the white point. "
                        + "ΔE is computed in this space, so an error here is an error in every "
                        + "separation number the speaker ramp rests on.",
                   start: "let x = 0.4124564", end: "static func deltaE2000(",
                   anchor: "0.95047"),
        MathRegion(name: "CIEDE2000",
                   stakes: "the function the whole duplication argument is about: ~20 constants, "
                        + "four weighting terms and a rotation term whose sign is the classic "
                        + "transcription error.",
                   start: "let p = lab(c1), q = lab(c2)", end: "private static func",
                   anchor: "0.045"),
        MathRegion(name: "CIEDE2000 hue helpers",
                   stakes: "the ±180 wrap and the mean-hue rule. Both are the parts of CIEDE2000 "
                        + "that only misbehave for pairs straddling 0°, which is exactly the "
                        + "region a sample-based check is least likely to visit.",
                   start: "private static func angle(", end: "private extension Double",
                   anchor: "360"),
        MathRegion(name: "degrees to radians",
                   stakes: "every trigonometric term above passes through it.",
                   start: "private extension Double", end: "\n}",
                   anchor: ".pi"),
    ]

    static func source(_ path: String) throws -> String {
        let url = DesignSystemSource.root.appendingPathComponent(path)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ParityError.missing(url.path)
        }
        return ComponentInk.withoutComments(try String(contentsOf: url, encoding: .utf8))
    }

    /// From the first occurrence of `start` up to the next occurrence of `end`. Comments are
    /// already stripped by `source(_:)`, so a doc comment between two declarations cannot make two
    /// otherwise-identical regions differ.
    static func slice(_ source: String, _ region: MathRegion, in file: String) throws -> String {
        guard let opening = source.range(of: region.start) else {
            throw ParityError.needleMissing(region.name, region.start, file)
        }
        let rest = source[opening.lowerBound...]
        var text = String(rest)
        if let end = region.end {
            let after = rest.index(rest.startIndex, offsetBy: 1)
            guard let closing = rest.range(of: end, range: after..<rest.endIndex) else {
                throw ParityError.needleMissing(region.name, end, file)
            }
            text = String(rest[..<closing.lowerBound])
        }
        guard text.contains(region.anchor) else {
            throw ParityError.anchorMissing(region.name, region.anchor, file)
        }
        return text
    }

    /// Layout is not arithmetic: a line break moved to satisfy a column limit must not fail this.
    static func normalised(_ text: String) -> String {
        text.split(whereSeparator: { $0.isWhitespace }).joined(separator: " ")
    }
}

enum ParityError: Error, CustomStringConvertible {
    case missing(String)
    case needleMissing(String, String, String)
    case anchorMissing(String, String, String)

    var description: String {
        switch self {
        case .missing(let path):
            return "\(path) not found. The parity check reads both implementations from source; without one there is nothing to compare."
        case .needleMissing(let region, let needle, let file):
            return "region '\(region)' — \(file) no longer contains \"\(needle)\". Either the declaration moved or it was renamed on one side only; update MathRegion, and check the OTHER file before you do."
        case .anchorMissing(let region, let anchor, let file):
            return "region '\(region)' in \(file) sliced a fragment with no \(anchor) in it. The needle matched somewhere it was not meant to, and the comparison would have passed on the wrong text."
        }
    }
}

// MARK: Recorded values

/// A published CIELAB coordinate, or one this implementation measures today. The first four rows
/// are independent of this code entirely — they are the sRGB primaries' textbook D65 values — and
/// are what makes the rest of the table a regression pin rather than a tautology.
struct LabAnchor {
    let name: String
    let hex: UInt32
    let l: Double
    let a: Double
    let b: Double

    init(_ name: String, _ hex: UInt32, _ l: Double, _ a: Double, _ b: Double) {
        self.name = name
        self.hex = hex
        self.l = l
        self.a = a
        self.b = b
    }

    var color: TokenRGB { ColourProbes.rgb(hex) }
}

enum ColourProbes {
    static func rgb(_ hex: UInt32) -> TokenRGB {
        TokenRGB(red: Double((hex >> 16) & 0xFF) / 255,
                 green: Double((hex >> 8) & 0xFF) / 255,
                 blue: Double(hex & 0xFF) / 255,
                 alpha: 1)
    }

    /// Ten colours chosen to exercise every branch rather than to look like a palette: the
    /// achromatic axis at both ends and the middle, the three sRGB primaries at full chroma, two
    /// violets near hue 275° where CIEDE2000's rotation term is at its largest, a saturated orange
    /// on the opposite side of it, and a near-black that lands on the LINEAR arm of CIELAB's f().
    static let all: [LabAnchor] = [
        LabAnchor("black", 0x000000, 0.000000, 0.000000, 0.000000),
        LabAnchor("gray50", 0x808080, 53.585016, -0.000010, 0.000004),
        LabAnchor("white", 0xFFFFFF, 100.000004, -0.000017, 0.000007),
        // Independent of this code: the published D65 CIELAB coordinates of the sRGB primaries.
        LabAnchor("red", 0xFF0000, 53.240794, 80.092460, 67.203197),
        LabAnchor("green", 0x00FF00, 87.734722, -86.182716, 83.179321),
        LabAnchor("blue", 0x0000FF, 32.297011, 79.187520, -107.860162),
        LabAnchor("violet", 0x7C3AED, 43.396425, 64.796698, -79.089422),
        LabAnchor("indigo", 0x4B0082, 20.469443, 51.685573, -53.312623),
        LabAnchor("amber", 0xEA580C, 56.588857, 53.811157, 64.061113),
        LabAnchor("nearBlack", 0x0A0A0A, 2.741748, -0.000001, 0.000000),
    ]

    /// ΔE2000 for all 45 unordered pairs of `all`, in `for i { for j > i }` order. Measured
    /// 2026-07-31. A checksum would be shorter and would say nothing on failure; this says which
    /// pair moved, which is the difference between a test and an alarm.
    static let separations: [Double] = [
        39.934472, 100.000004, 50.411407, 87.864209,
        39.681700, 43.530513, 30.698227, 51.817514,
        1.588156, 33.238954, 31.196578, 41.688986,
        38.663250, 32.592112, 39.488983, 29.191655,
        38.491707, 45.810524, 33.255232, 64.232822,
        52.935203, 75.087960, 42.186722, 96.675632,
        86.608237, 52.881368, 47.557095, 51.000857,
        9.746423, 49.284149, 83.185878, 73.741224,
        88.079526, 73.230645, 87.048688, 11.352556,
        15.771429, 57.427510, 38.864640, 19.482905,
        51.815839, 42.486178, 55.876909, 30.072038,
        50.648999,
    ]
}

// MARK: Tests

final class ColorScienceParityTests: XCTestCase {

    /// The half that can speak about the gallery. Both files are read as text and their shared
    /// arithmetic compared region by region.
    func testGalleryAndCoreShareOneColourMath() throws {
        let gallery = try ColourMath.source(ColourMath.galleryPath)
        let core = try ColourMath.source(ColourMath.corePath)

        var divergent: [String] = []
        var compared = 0
        for region in ColourMath.regions {
            let a = ColourMath.normalised(
                try ColourMath.slice(gallery, region, in: ColourMath.galleryPath))
            let b = ColourMath.normalised(
                try ColourMath.slice(core, region, in: ColourMath.corePath))
            compared += a.count
            guard a != b else { continue }
            divergent.append("""
                — \(region.name): \(region.stakes)
                  \(ColourMath.galleryPath): \(a)
                  \(ColourMath.corePath): \(b)
                """)
        }

        XCTAssertTrue(divergent.isEmpty, """
            \(divergent.count) of \(ColourMath.regions.count) shared region(s) of colour maths \
            differ between the two implementations:
            \(divergent.joined(separator: "\n"))
            These are two copies of one published spec and they must be the same arithmetic. Change \
            both, or move the math into a target both can import — which is the real fix and the \
            reason this test exists rather than that one.
            """)

        // A slice that quietly matched nothing would compare "" against "" and pass every
        // assertion above, so the floors are what make this test mean anything.
        XCTAssertEqual(ColourMath.regions.count, 7, "regions declared")
        XCTAssertGreaterThanOrEqual(compared, 2000, "characters of arithmetic compared")
    }

    /// The anchors that owe nothing to this code: WCAG's own worst-case ratio, and the sRGB
    /// primaries' published CIELAB coordinates. If the implementation were wrong in a way both
    /// files shared, this is what would notice.
    func testSpecAnchorsHold() {
        let white = ColourProbes.rgb(0xFFFFFF)
        let black = ColourProbes.rgb(0x000000)
        XCTAssertEqual(Srgb.luminance(white), 1.0, accuracy: 1e-9)
        XCTAssertEqual(Srgb.luminance(black), 0.0, accuracy: 1e-9)
        XCTAssertEqual(Srgb.contrast(white, black), 21.0, accuracy: 1e-9)
        XCTAssertEqual(Srgb.contrast(black, white), 21.0, accuracy: 1e-9,
                       "contrast is defined on the lighter/darker pair, not on argument order")

        for anchor in ColourProbes.all.prefix(6) {
            let measured = Perceptual.lab(anchor.color)
            XCTAssertEqual(measured.l, anchor.l, accuracy: 1e-4, "L* of \(anchor.name)")
            XCTAssertEqual(measured.a, anchor.a, accuracy: 1e-4, "a* of \(anchor.name)")
            XCTAssertEqual(measured.b, anchor.b, accuracy: 1e-4, "b* of \(anchor.name)")
        }

        // Compositing at the endpoints, where the answer is not a matter of convention.
        var glass = ColourProbes.rgb(0xFF0000)
        glass.alpha = 0
        XCTAssertEqual(Srgb.composite(glass, over: white), white)
        glass.alpha = 1
        XCTAssertEqual(Srgb.composite(glass, over: white), ColourProbes.rgb(0xFF0000))
    }

    /// The properties CIEDE2000 has by construction, over a 216-colour sweep of the cube rather
    /// than over the palette — the palette is a dozen points and every one of them is far from the
    /// hue wrap and the achromatic axis, which is where these formulas go wrong.
    func testDeltaE2000PropertiesHoldAcrossTheGamut() {
        let steps: [Double] = [0, 0.2, 0.4, 0.6, 0.8, 1]
        var cube: [TokenRGB] = []
        for r in steps {
            for g in steps {
                for b in steps { cube.append(TokenRGB(red: r, green: g, blue: b, alpha: 1)) }
            }
        }
        XCTAssertEqual(cube.count, 216)

        var selfDistance = 0.0
        var worstAsymmetry = 0.0
        for (index, colour) in cube.enumerated() {
            selfDistance = max(selfDistance, Perceptual.deltaE2000(colour, colour))
            // Every colour against eight others, spread through the cube rather than adjacent to
            // it: neighbouring entries differ in one channel only and would never straddle 0°.
            for offset in stride(from: 7, to: 216, by: 27) {
                let other = cube[(index + offset) % cube.count]
                let forward = Perceptual.deltaE2000(colour, other)
                let backward = Perceptual.deltaE2000(other, colour)
                worstAsymmetry = max(worstAsymmetry, abs(forward - backward))
            }
        }
        XCTAssertEqual(selfDistance, 0, accuracy: 1e-9, "ΔE2000 of a colour against itself")
        XCTAssertEqual(worstAsymmetry, 0, accuracy: 1e-9,
                       "ΔE2000 is symmetric by construction; asymmetry means a term lost a sign")

        // On the achromatic axis chroma and hue vanish and CIEDE2000 collapses to |ΔL*| / S_L,
        // which is short enough to write out. It is the one closed form the standard has, and it
        // exercises the L weighting term independently of everything else.
        for first in stride(from: 0, through: 255, by: 15) {
            for second in stride(from: 0, through: 255, by: 15) {
                let a = ColourProbes.rgb(UInt32(first) << 16 | UInt32(first) << 8 | UInt32(first))
                let b = ColourProbes.rgb(UInt32(second) << 16 | UInt32(second) << 8 | UInt32(second))
                let (la, lb) = (Perceptual.lab(a).l, Perceptual.lab(b).l)
                let mean = (la + lb) / 2 - 50
                let sL = 1 + (0.015 * mean * mean) / (20 + mean * mean).squareRoot()
                XCTAssertEqual(Perceptual.deltaE2000(a, b), abs(lb - la) / sL, accuracy: 1e-3,
                               "grey \(first) against grey \(second)")
            }
        }
    }

    /// The gamut spread, pinned. Text parity says the two files agree; this says what they agree
    /// ON, so a restructure applied to both at once still has to be deliberate.
    func testRecordedColourMathAcrossTheGamut() {
        for anchor in ColourProbes.all {
            let measured = Perceptual.lab(anchor.color)
            XCTAssertEqual(measured.l, anchor.l, accuracy: 1e-5, "L* of \(anchor.name)")
            XCTAssertEqual(measured.a, anchor.a, accuracy: 1e-5, "a* of \(anchor.name)")
            XCTAssertEqual(measured.b, anchor.b, accuracy: 1e-5, "b* of \(anchor.name)")
        }

        var drifted: [String] = []
        var index = 0
        for i in ColourProbes.all.indices {
            for j in ColourProbes.all.indices where j > i {
                let measured = Perceptual.deltaE2000(ColourProbes.all[i].color,
                                                     ColourProbes.all[j].color)
                let recorded = ColourProbes.separations[index]
                index += 1
                guard abs(measured - recorded) > 1e-5 else { continue }
                drifted.append(String(format: "%@/%@ — recorded ΔE %.6f, now %.6f",
                                      ColourProbes.all[i].name, ColourProbes.all[j].name,
                                      recorded, measured))
            }
        }
        XCTAssertEqual(index, ColourProbes.separations.count,
                       "the recorded table no longer has one row per pair")
        XCTAssertTrue(drifted.isEmpty, """
            \(drifted.count) recorded separation(s) moved:
            \(drifted.joined(separator: "\n"))
            Re-record only after establishing WHICH change moved them — and make the same change in \
            \(ColourMath.galleryPath).
            """)
    }
}
