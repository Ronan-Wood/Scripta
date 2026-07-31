import AppKit

// MARK: - The measurements the design direction is making claims about
//
// Everything here is spec math with no house opinion in it: WCAG 2.2 relative luminance, sRGB
// src-over compositing, the Viénot–Brettel–Mollon dichromat simulation, and CIEDE2000. It runs in
// the gallery against the SAME `Tone` values the app draws with, so a number on screen cannot
// agree with the design doc while disagreeing with the build.
//
// `Core/Tests/ScriptaCoreTests/ColorMetrics.swift` implements the same formulas over `TokenRGB`,
// because that target cannot see `Tone` across the module boundary. The duplication is real, it
// was "called out in the handoff" and nothing enforced it — a transposed sign in one `deltaE2000`
// would have left the verdicts on this screen and the Core gate's assertions describing different
// systems, silently.
//
// THE ARITHMETIC BELOW IS CHARACTER-FOR-CHARACTER THE CORE FILE'S, and `ColorScienceParityTests`
// slices both and compares them: every formula, both 3x3 matrices, every CIEDE2000 constant. Only
// the EDGES differ — `NSColor` here, `TokenRGB` there — and the regions are cut to exclude exactly
// those lines. So: if you reformat a formula here, reformat it there. The real fix is one shared
// target, at which point that test and one of these files delete together.

enum Wcag {
    /// WCAG 1.4.3 — body copy.
    static let bodyText: Double = 4.5
    /// WCAG 1.4.3 large text and 1.4.11 non-text contrast (icons, control boundaries, focus rings).
    static let largeOrUI: Double = 3.0

    static func components(_ color: NSColor) -> (r: Double, g: Double, b: Double, a: Double) {
        // A `Tone` half is always built by `rgb(_:)` in sRGB, but converting anyway is what keeps
        // this honest if a token is ever sourced from a system color in a different space.
        let c = color.usingColorSpace(.sRGB) ?? color
        return (Double(c.redComponent), Double(c.greenComponent),
                Double(c.blueComponent), Double(c.alphaComponent))
    }

    static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    static func encode(_ channel: Double) -> Double {
        channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055
    }

    static func luminance(_ color: NSColor) -> Double {
        let p = components(color)
        return 0.2126 * linear(p.r) + 0.7152 * linear(p.g) + 0.0722 * linear(p.b)
    }

    /// Assumes both colors are already opaque. Composite first — a ratio taken against a
    /// translucent wash reads its alpha as if it were opaque and over-reports by a wide margin.
    static func ratio(_ a: NSColor, _ b: NSColor) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        let hi = max(la, lb), lo = min(la, lb)
        return (hi + 0.05) / (lo + 0.05)
    }

    /// src-over in *gamma-encoded* sRGB, matching what CoreGraphics does in a standard sRGB
    /// context. Blending in linear light is physically prettier and would report a contrast the
    /// screen never actually shows.
    static func composite(_ fg: NSColor, over bg: NSColor) -> NSColor {
        let f = components(fg), b = components(bg)
        let a = f.a
        return NSColor(srgbRed: CGFloat(f.r * a + b.r * (1 - a)),
                       green: CGFloat(f.g * a + b.g * (1 - a)),
                       blue: CGFloat(f.b * a + b.b * (1 - a)),
                       alpha: 1)
    }
}

// MARK: - Dichromat simulation

/// Viénot, Brettel & Mollon (1999), the single-projection-plane approximation, applied to linear
/// sRGB. Simulation is an approximation of a *population*, not a prediction for one reader — its
/// job here is to falsify a palette claim cheaply, not to certify one.
enum Dichromacy: String, CaseIterable, Identifiable {
    case deuteranopia
    case protanopia
    /// Not part of the design direction's claim (blue-yellow deficiency is far rarer than
    /// red-green), measured anyway because a palette that leans on the blue-orange axis is exactly
    /// the palette tritanopia collapses.
    case tritanopia

    var id: String { rawValue }
    var short: String {
        switch self {
        case .deuteranopia: return "deuter"
        case .protanopia: return "protan"
        case .tritanopia: return "tritan"
        }
    }
}

enum VisionSim {
    private static let rgbToLms: [[Double]] = [
        [17.8824, 43.5161, 4.11935],
        [3.45565, 27.1554, 3.86714],
        [0.0299566, 0.184309, 1.46709],
    ]
    private static let lmsToRgb: [[Double]] = [
        [0.080944479, -0.130504409, 0.116721066],
        [-0.010248533, 0.054019327, -0.113614708],
        [-0.000365297, -0.004121615, 0.693511405],
    ]

    private static func apply(_ m: [[Double]], _ v: [Double]) -> [Double] {
        (0..<3).map { i in m[i][0] * v[0] + m[i][1] * v[1] + m[i][2] * v[2] }
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    static func simulate(_ color: NSColor, _ kind: Dichromacy) -> NSColor {
        let p = Wcag.components(color)
        var lms = apply(rgbToLms, [Wcag.linear(p.r), Wcag.linear(p.g), Wcag.linear(p.b)])
        switch kind {
        case .protanopia: lms[0] = 2.02344 * lms[1] - 2.52581 * lms[2]
        case .deuteranopia: lms[1] = 0.494207 * lms[0] + 1.24827 * lms[2]
        case .tritanopia: lms[2] = -0.395913 * lms[0] + 0.801109 * lms[1]
        }
        let out = apply(lmsToRgb, lms).map { clamp(Wcag.encode(clamp($0))) }
        return NSColor(srgbRed: CGFloat(out[0]), green: CGFloat(out[1]),
                       blue: CGFloat(out[2]), alpha: CGFloat(p.a))
    }
}

// MARK: - Perceptual distance

/// CIELAB under D65 plus CIEDE2000. Contrast ratio answers "can it be read"; ΔE answers "are these
/// two categories the same colour", which is the only question a speaker ramp is asking.
enum Perceptual {
    static func lab(_ color: NSColor) -> (l: Double, a: Double, b: Double) {
        let p = Wcag.components(color)
        let (r, g, bl) = (Wcag.linear(p.r), Wcag.linear(p.g), Wcag.linear(p.b))
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * bl
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * bl
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * bl
        let f = { (t: Double) -> Double in
            t > 216.0 / 24389.0 ? pow(t, 1.0 / 3.0) : (841.0 / 108.0) * t + 4.0 / 29.0
        }
        let (fx, fy, fz) = (f(x / 0.95047), f(y / 1.0), f(z / 1.08883))
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func deltaE2000(_ c1: NSColor, _ c2: NSColor) -> Double {
        let p = lab(c1), q = lab(c2)
        let c1ab = hypot(p.a, p.b), c2ab = hypot(q.a, q.b)
        let cBar = (c1ab + c2ab) / 2
        let g = 0.5 * (1 - sqrt(pow(cBar, 7) / (pow(cBar, 7) + pow(25, 7))))
        let a1p = (1 + g) * p.a, a2p = (1 + g) * q.a
        let c1p = hypot(a1p, p.b), c2p = hypot(a2p, q.b)
        let h1p = angle(a1p, p.b), h2p = angle(a2p, q.b)

        let dLp = q.l - p.l
        let dCp = c2p - c1p
        let dhp = hueDelta(h1p, h2p, c1p * c2p)
        let dHp = 2 * sqrt(c1p * c2p) * sin(dhp.radians / 2)

        let lBar = (p.l + q.l) / 2, cBarP = (c1p + c2p) / 2
        let hBar = hueMean(h1p, h2p, c1p * c2p)
        let t = 1 - 0.17 * cos((hBar - 30).radians) + 0.24 * cos((2 * hBar).radians)
            + 0.32 * cos((3 * hBar + 6).radians) - 0.20 * cos((4 * hBar - 63).radians)
        let sL = 1 + (0.015 * pow(lBar - 50, 2)) / sqrt(20 + pow(lBar - 50, 2))
        let sC = 1 + 0.045 * cBarP
        let sH = 1 + 0.015 * cBarP * t
        let rC = cBarP > 0 ? 2 * sqrt(pow(cBarP, 7) / (pow(cBarP, 7) + pow(25, 7))) : 0
        let rT = -rC * sin((2 * 30 * exp(-pow((hBar - 275) / 25, 2))).radians)

        let kL = dLp / sL, kC = dCp / sC, kH = dHp / sH
        return sqrt(kL * kL + kC * kC + kH * kH + rT * kC * kH)
    }

    private static func angle(_ a: Double, _ b: Double) -> Double {
        guard a != 0 || b != 0 else { return 0 }
        let deg = atan2(b, a) * 180 / .pi
        return deg < 0 ? deg + 360 : deg
    }

    private static func hueDelta(_ h1: Double, _ h2: Double, _ chromaProduct: Double) -> Double {
        guard chromaProduct != 0 else { return 0 }
        let d = h2 - h1
        if d > 180 { return d - 360 }
        if d < -180 { return d + 360 }
        return d
    }

    private static func hueMean(_ h1: Double, _ h2: Double, _ chromaProduct: Double) -> Double {
        guard chromaProduct != 0 else { return h1 + h2 }
        let sum = h1 + h2
        guard abs(h1 - h2) > 180 else { return sum / 2 }
        return sum < 360 ? (sum + 360) / 2 : (sum - 360) / 2
    }
}

private extension Double {
    var radians: Double { self * .pi / 180 }
}

// MARK: - Readouts

enum Hex {
    static func string(_ color: NSColor) -> String {
        let p = Wcag.components(color)
        let hex = String(format: "#%02X%02X%02X",
                         Int((p.r * 255).rounded()), Int((p.g * 255).rounded()), Int((p.b * 255).rounded()))
        return p.a < 0.999 ? hex + String(format: " %.0f%%", p.a * 100) : hex
    }
}
