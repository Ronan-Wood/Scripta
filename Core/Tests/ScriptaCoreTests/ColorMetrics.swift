import Foundation

// Spec math with no house opinion in it: WCAG 2.2 relative luminance, sRGB src-over compositing,
// the Viénot–Brettel–Mollon dichromat simulation, CIELAB and CIEDE2000.
//
// `Sources/Gallery/ColorScience.swift` implements the same formulas over `NSColor`. Two copies of
// a published spec is a smaller cost than one copy that only one side of the module boundary can
// reach — but it IS a cost, and the two must be changed together.

enum Srgb {
    static func linear(_ channel: Double) -> Double {
        channel <= 0.04045 ? channel / 12.92 : pow((channel + 0.055) / 1.055, 2.4)
    }

    static func encode(_ channel: Double) -> Double {
        channel <= 0.0031308 ? channel * 12.92 : 1.055 * pow(channel, 1 / 2.4) - 0.055
    }

    static func luminance(_ color: TokenRGB) -> Double {
        0.2126 * linear(color.red) + 0.7152 * linear(color.green) + 0.0722 * linear(color.blue)
    }

    /// src-over in *gamma-encoded* sRGB, matching what CoreGraphics does in a standard sRGB
    /// context. Compositing in linear light is physically truer and reports a contrast the screen
    /// never shows, which for a gate is the wrong kind of correct.
    static func composite(_ foreground: TokenRGB, over background: TokenRGB) -> TokenRGB {
        let a = foreground.alpha
        return TokenRGB(red: foreground.red * a + background.red * (1 - a),
                        green: foreground.green * a + background.green * (1 - a),
                        blue: foreground.blue * a + background.blue * (1 - a),
                        alpha: 1)
    }

    /// Both arguments must already be opaque — composite first. A ratio taken against a
    /// translucent colour reads its alpha as if it were solid and over-reports by a wide margin.
    static func contrast(_ a: TokenRGB, _ b: TokenRGB) -> Double {
        let (la, lb) = (luminance(a), luminance(b))
        return (max(la, lb) + 0.05) / (min(la, lb) + 0.05)
    }
}

enum Wcag {
    static let bodyText: Double = 4.5
    /// Large text (1.4.3) and non-text contrast (1.4.11): icons, control boundaries, focus rings.
    static let largeOrUI: Double = 3.0
}

/// Viénot, Brettel & Mollon (1999), single-projection-plane, applied to linear sRGB. It models a
/// population rather than a reader; its job here is to falsify a palette claim cheaply.
enum Dichromacy: String, CaseIterable {
    case deuteranopia
    case protanopia
    /// Outside the direction's claim — blue-yellow deficiency is far rarer than red-green — and
    /// measured anyway, because a palette that leans on the blue-orange axis is precisely the
    /// palette tritanopia flattens.
    case tritanopia
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
        (0..<3).map { m[$0][0] * v[0] + m[$0][1] * v[1] + m[$0][2] * v[2] }
    }

    private static func clamp(_ x: Double) -> Double { min(1, max(0, x)) }

    static func simulate(_ color: TokenRGB, _ kind: Dichromacy) -> TokenRGB {
        var lms = apply(rgbToLms, [Srgb.linear(color.red), Srgb.linear(color.green), Srgb.linear(color.blue)])
        switch kind {
        case .protanopia: lms[0] = 2.02344 * lms[1] - 2.52581 * lms[2]
        case .deuteranopia: lms[1] = 0.494207 * lms[0] + 1.24827 * lms[2]
        case .tritanopia: lms[2] = -0.395913 * lms[0] + 0.801109 * lms[1]
        }
        let out = apply(lmsToRgb, lms).map { clamp(Srgb.encode(clamp($0))) }
        return TokenRGB(red: out[0], green: out[1], blue: out[2], alpha: color.alpha)
    }
}

/// Contrast ratio answers "can this be read". ΔE answers "is this the same colour as its
/// neighbour", which is the only question a categorical ramp asks.
enum Perceptual {
    static func lab(_ color: TokenRGB) -> (l: Double, a: Double, b: Double) {
        let (r, g, b) = (Srgb.linear(color.red), Srgb.linear(color.green), Srgb.linear(color.blue))
        let x = 0.4124564 * r + 0.3575761 * g + 0.1804375 * b
        let y = 0.2126729 * r + 0.7151522 * g + 0.0721750 * b
        let z = 0.0193339 * r + 0.1191920 * g + 0.9503041 * b
        let f = { (t: Double) -> Double in
            t > 216.0 / 24389.0 ? pow(t, 1.0 / 3.0) : (841.0 / 108.0) * t + 4.0 / 29.0
        }
        let (fx, fy, fz) = (f(x / 0.95047), f(y), f(z / 1.08883))
        return (116 * fy - 16, 500 * (fx - fy), 200 * (fy - fz))
    }

    static func deltaE2000(_ c1: TokenRGB, _ c2: TokenRGB) -> Double {
        let p = lab(c1), q = lab(c2)
        let cBar = (hypot(p.a, p.b) + hypot(q.a, q.b)) / 2
        let g = 0.5 * (1 - sqrt(pow(cBar, 7) / (pow(cBar, 7) + pow(25, 7))))
        let a1 = (1 + g) * p.a, a2 = (1 + g) * q.a
        let c1p = hypot(a1, p.b), c2p = hypot(a2, q.b)
        let h1 = hue(a1, p.b), h2 = hue(a2, q.b)

        let dL = q.l - p.l
        let dC = c2p - c1p
        let dh = hueDelta(h1, h2, c1p * c2p)
        let dH = 2 * sqrt(c1p * c2p) * sin(radians(dh) / 2)

        let lBar = (p.l + q.l) / 2
        let cBarP = (c1p + c2p) / 2
        let hBar = hueMean(h1, h2, c1p * c2p)
        let t = 1 - 0.17 * cos(radians(hBar - 30)) + 0.24 * cos(radians(2 * hBar))
            + 0.32 * cos(radians(3 * hBar + 6)) - 0.20 * cos(radians(4 * hBar - 63))
        let sL = 1 + (0.015 * pow(lBar - 50, 2)) / sqrt(20 + pow(lBar - 50, 2))
        let sC = 1 + 0.045 * cBarP
        let sH = 1 + 0.015 * cBarP * t
        let rC = cBarP > 0 ? 2 * sqrt(pow(cBarP, 7) / (pow(cBarP, 7) + pow(25, 7))) : 0
        let rT = -rC * sin(radians(2 * 30 * exp(-pow((hBar - 275) / 25, 2))))

        let (kL, kC, kH) = (dL / sL, dC / sC, dH / sH)
        return sqrt(kL * kL + kC * kC + kH * kH + rT * kC * kH)
    }

    private static func radians(_ degrees: Double) -> Double { degrees * .pi / 180 }

    private static func hue(_ a: Double, _ b: Double) -> Double {
        guard a != 0 || b != 0 else { return 0 }
        let degrees = atan2(b, a) * 180 / .pi
        return degrees < 0 ? degrees + 360 : degrees
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
