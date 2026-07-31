import Foundation

// MARK: - Reading the token layer from outside its module
//
// WHERE THIS LIVES AND WHY IT IS UNCOMFORTABLE.
//
// "Record & Register" lives in `Sources/Theme` — the app module. The app target has no test target
// at all (project.yml: "Unit tests live in the Core package"), and adding one is a bigger change
// than the gate it would carry. So the gate runs from `Core/Tests`, which cannot import `Ink`.
//
// The obvious fallback is to copy the hexes into this package. That is a second source of truth
// for the one thing the gate exists to measure, and it goes stale silently — a gate scoring last
// month's palette passes cheerfully and means nothing. So this reads the values out of
// `Sources/Theme/Ink.swift` instead. There is exactly one set of numbers in the repo.
//
// The cost, stated plainly: this couples to the *shape* of the declarations, not just their
// values. Reformat `Ink.swift` and the parser stops recognising lines — which is why
// `testTokenSourceParsesCompletely` asserts floors on what it found rather than trusting the parse
// to have worked. A parse failure is loud. A stale copy would not have been.
//
// The real fix is an app-side test target, at which point this file deletes and the gate imports
// `Ink` directly.

struct TokenRGB: Equatable {
    var red: Double
    var green: Double
    var blue: Double
    var alpha: Double
}

enum Appearance: String, CaseIterable {
    case light
    case dark
}

/// A `Ramp` entry plus whatever alpha `.at(_:)` applied at the use site.
struct RampRef: Equatable {
    let ramp: String
    let alpha: Double
}

struct ToneSpec: Equatable {
    let light: RampRef
    let dark: RampRef

    func reference(for appearance: Appearance) -> RampRef {
        appearance == .light ? light : dark
    }
}

enum ThemeSourceError: Error, CustomStringConvertible {
    case fileMissing(String)
    case unparsable(line: Int, text: String)
    case unknownToken(String)
    case unknownRamp(String, usedBy: String)
    case unresolvedAlias(String, target: String)

    var description: String {
        switch self {
        case .fileMissing(let path):
            return "Ink.swift not found at \(path). The contrast gate reads the token layer from source; without it there is nothing to measure."
        case .unparsable(let line, let text):
            return "Ink.swift:\(line) declares a token in a shape this parser does not recognise — \(text). Update ThemeTokenSource alongside the declaration."
        case .unknownToken(let name):
            return "no token named '\(name)' in Ink.swift"
        case .unknownRamp(let name, let user):
            return "'\(user)' refers to Ramp.\(name), which Ink.swift does not declare"
        case .unresolvedAlias(let name, let target):
            return "'\(name)' aliases '\(target)', which never resolves to a Tone"
        }
    }
}

struct ThemeTokens {
    let ramp: [String: TokenRGB]
    let tones: [String: ToneSpec]
    let sourcePath: String

    static func loadFromRepository() throws -> ThemeTokens {
        // #filePath, not the working directory: `swift test` and Xcode disagree about cwd, and a
        // gate that silently finds no file is worse than one that cannot run.
        let here = URL(fileURLWithPath: #filePath)
        let root = here.deletingLastPathComponent()   // ScriptaCoreTests
            .deletingLastPathComponent()              // Tests
            .deletingLastPathComponent()              // Core
            .deletingLastPathComponent()              // repository root
        let url = root.appendingPathComponent("Sources/Theme/Ink.swift")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw ThemeSourceError.fileMissing(url.path)
        }
        return try parse(try String(contentsOf: url, encoding: .utf8), path: url.path)
    }

    func color(_ token: String, _ appearance: Appearance) throws -> TokenRGB {
        guard let spec = tones[token] else { throw ThemeSourceError.unknownToken(token) }
        let reference = spec.reference(for: appearance)
        guard let base = ramp[reference.ramp] else {
            throw ThemeSourceError.unknownRamp(reference.ramp, usedBy: token)
        }
        return TokenRGB(red: base.red, green: base.green, blue: base.blue, alpha: reference.alpha)
    }

    // MARK: Parsing

    static func parse(_ text: String, path: String) throws -> ThemeTokens {
        var ramp: [String: TokenRGB] = [:]
        var tones: [String: ToneSpec] = [:]
        var aliases: [String: String] = [:]
        // The `speaker.` prefix is bounded by the `enum speaker` block's INDENTATION rather than
        // latched on at its opening line. A latch never turns off, so every `static let` declared
        // after the block — anywhere later in the file — would be filed under a `speaker.` prefix
        // it does not have, and would then be missing under its real name with nothing saying why.
        // Indentation over brace counting because this file also contains braces inside comments
        // and closures, and a miscount there fails silently in the same direction.
        var speakerIndent: Int?

        for (offset, rawLine) in text.components(separatedBy: .newlines).enumerated() {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            let indent = rawLine.prefix { $0 == " " }.count
            if line.hasPrefix("enum speaker") {
                speakerIndent = indent
            } else if let opened = speakerIndent, line.hasPrefix("}"), indent <= opened {
                speakerIndent = nil
            }
            let inSpeaker = speakerIndent != nil
            guard line.hasPrefix("static let "), let equals = line.range(of: " = ") else { continue }

            let name = String(line[line.index(line.startIndex, offsetBy: 11)..<equals.lowerBound])
                .trimmingCharacters(in: .whitespaces)
            // `static let alt: [Tone] = [...]` — a collection of tokens already parsed individually.
            if name.contains(":") { continue }

            var rhs = String(line[equals.upperBound...])
            if let comment = rhs.range(of: "//") { rhs = String(rhs[..<comment.lowerBound]) }
            rhs = rhs.trimmingCharacters(in: .whitespaces)
            let key = inSpeaker ? "speaker.\(name)" : name

            if rhs.hasPrefix("rgb(0x") {
                ramp[name] = try parseHex(rhs, at: offset + 1)
            } else if rhs.hasPrefix("Tone(") {
                tones[key] = try parseTone(rhs, at: offset + 1)
            } else if isIdentifier(rhs) {
                aliases[key] = inSpeaker ? "speaker.\(rhs)" : rhs
            }
        }

        // Aliases can chain (`borderFocus = interactive`), so resolve to a fixed point rather than
        // assuming one hop.
        for _ in 0..<4 {
            for (name, target) in aliases where tones[name] == nil {
                tones[name] = tones[target]
            }
        }
        for (name, target) in aliases where tones[name] == nil {
            throw ThemeSourceError.unresolvedAlias(name, target: target)
        }

        return ThemeTokens(ramp: ramp, tones: tones, sourcePath: path)
    }

    private static func isIdentifier(_ text: String) -> Bool {
        !text.isEmpty && text.allSatisfy { $0.isLetter || $0.isNumber || $0 == "_" }
    }

    private static func parseHex(_ rhs: String, at line: Int) throws -> TokenRGB {
        let body = rhs.dropFirst("rgb(0x".count)
        guard let close = body.firstIndex(of: ")"),
              let value = UInt32(body[body.startIndex..<close], radix: 16) else {
            throw ThemeSourceError.unparsable(line: line, text: rhs)
        }
        return TokenRGB(red: Double((value >> 16) & 0xFF) / 255,
                        green: Double((value >> 8) & 0xFF) / 255,
                        blue: Double(value & 0xFF) / 255,
                        alpha: 1)
    }

    private static func parseTone(_ rhs: String, at line: Int) throws -> ToneSpec {
        guard rhs.hasSuffix(")") else { throw ThemeSourceError.unparsable(line: line, text: rhs) }
        let inner = String(rhs.dropFirst("Tone(".count).dropLast())
        guard inner.hasPrefix("light:") else {
            // `Tone(_ both:)` — the appearance-invariant form.
            let both = try parseRef(inner, at: line)
            return ToneSpec(light: both, dark: both)
        }
        guard let separator = inner.range(of: ", dark:") else {
            throw ThemeSourceError.unparsable(line: line, text: rhs)
        }
        let lightText = String(inner[inner.index(inner.startIndex, offsetBy: 6)..<separator.lowerBound])
        let darkText = String(inner[separator.upperBound...])
        return ToneSpec(light: try parseRef(lightText, at: line),
                        dark: try parseRef(darkText, at: line))
    }

    private static func parseRef(_ text: String, at line: Int) throws -> RampRef {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        guard trimmed.hasPrefix("Ramp.") else {
            throw ThemeSourceError.unparsable(line: line, text: trimmed)
        }
        let body = trimmed.dropFirst("Ramp.".count)
        guard let at = body.range(of: ".at(") else {
            return RampRef(ramp: String(body), alpha: 1)
        }
        let rest = body[at.upperBound...]
        guard let close = rest.firstIndex(of: ")"),
              let alpha = Double(rest[rest.startIndex..<close]) else {
            throw ThemeSourceError.unparsable(line: line, text: trimmed)
        }
        return RampRef(ramp: String(body[body.startIndex..<at.lowerBound]), alpha: alpha)
    }
}
