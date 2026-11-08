import XCTest
@testable import ScriptaCore
@testable import ScriptaShared

/// Every free-text value the app writes into frontmatter is a single-quoted YAML scalar, which
/// YAML 1.2, YAML 1.1, the engine's line reader and `Frontmatter.field` all read back as written.
/// The engine side of the same property is `substrate/tests/test_frontmatter_yaml.py`, which also
/// checks `yamlSafe`'s ranges against the engine's code point by code point.
///
/// WHY. The writers put every title inside double quotes and escaped nothing, so YAML read the
/// `\a` of `$\alpha$` as a bell and refused `\d` outright, while the line readers kept them as
/// typed. Obsidian reads YAML, the engine and the app read lines: one note meant two things.
final class FrontmatterYAMLTests: XCTestCase {

    /// SplitMix64: a seeded generator, so a failure names a reproducible case.
    private struct Seeded: RandomNumberGenerator {
        var state: UInt64
        mutating func next() -> UInt64 {
            state &+= 0x9E37_79B9_7F4A_7C15
            var z = state
            z = (z ^ (z >> 30)) &* 0xBF58_476D_1CE4_E5B9
            z = (z ^ (z >> 27)) &* 0x94D0_49BB_1331_11EB
            return z ^ (z >> 31)
        }
    }

    /// Scalars weighted toward the ones that broke a writer: quotes, backslashes, YAML indicators,
    /// every control and line break, the byte-order mark and the non-characters, plus anything.
    private static let hostile: [UInt32] = Array(0x00...0x20) + [0x22, 0x27, 0x5C, 0x23, 0x3A,
        0x2C, 0x5B, 0x5D, 0x7B, 0x7D, 0x2A, 0x26, 0x21, 0x7C, 0x3E, 0x2D, 0x3F, 0x25, 0x40, 0x60,
        0x7F, 0x80, 0x85, 0x9B, 0x9F, 0xA0, 0x301, 0x2028, 0x2029, 0x202F, 0xFEFF, 0xFFFE, 0xFFFF,
        0x1F600, 0x10FFFF]

    private func randomValue(_ rng: inout Seeded) -> String {
        var out = String.UnicodeScalarView()
        for _ in 0..<Int.random(in: 0...24, using: &rng) {
            let pick: UInt32
            switch Int.random(in: 0..<4, using: &rng) {
            case 0: pick = Self.hostile.randomElement(using: &rng)!
            case 1: pick = UInt32.random(in: 0x21...0x7E, using: &rng)
            case 2: pick = UInt32.random(in: 0...0xFFFF, using: &rng)
            default: pick = UInt32.random(in: 0...0x10FFFF, using: &rng)
            }
            if let scalar = Unicode.Scalar(pick) { out.append(scalar) }
        }
        return String(out)
    }

    func testAQuotedValueReadsBackAsWrittenForSeededRandomUnicode() {
        var rng = Seeded(state: 0x5EED)
        for _ in 0..<20_000 {
            let value = randomValue(&rng)
            let want = Frontmatter.yamlSafe(value)
            let quoted = Frontmatter.quoted(value)
            XCTAssertFalse(quoted.unicodeScalars.contains {
                ($0.value < 0x20 && $0 != "\t") || [0x7F, 0x85, 0x2028, 0x2029, 0xFEFF].contains($0.value)
            }, "a line break or control reached the line: \(quoted.debugDescription)")
            XCTAssertEqual(Frontmatter.field("k: \(quoted)\nz: 1", "k"), want, value.debugDescription)
            let items = Frontmatter.parseList("[\(quoted), 'b']")
            let expected = want.trimmingCharacters(in: .whitespaces).isEmpty ? ["b"] : [want, "b"]
            XCTAssertEqual(items, expected, value.debugDescription)
            let split = Frontmatter.split("---\nk: \(quoted)\n---\nbody")
            XCTAssertEqual(split?.body, "body", value.debugDescription)
        }
    }

    func testYamlSafeKeepsOnlyWhatAOneLineScalarHolds() {
        for v: UInt32 in [0x0A, 0x0D, 0x7F, 0x85, 0x9F, 0x2028, 0x2029, 0xFEFF, 0xFFFE, 0xFFFF] {
            XCTAssertEqual(Frontmatter.yamlSafe(String(Unicode.Scalar(v)!)), " ", String(v, radix: 16))
        }
        for v: UInt32 in [0x09, 0x20, 0x7E, 0xA0, 0x2027, 0x202A, 0xD7FF, 0xE000, 0xFEFD, 0xFF00, 0xFFFD, 0x10000] {
            let s = String(Unicode.Scalar(v)!)
            XCTAssertEqual(Frontmatter.yamlSafe(s), s, String(v, radix: 16))
        }
    }

    private static let titles = ["He said \"hi\": ok", "Regex: \\d+ and C:\\Users", "Proof: $\\alpha$",
        "C:\\new folder", "'90s \\m/", "*bold* intro", "&anchor", "- dash", "[WIP] notes",
        "it's fine", "'quoted'", "a #b", "trailing \\", "yes", "2026-11-07", "del\u{7F}x",
        "c1\u{9B}x", "bom\u{FEFF}x", "e\u{301}\u{7F}", "Last, First"]

    func testTheTranscriptWriterWritesTitlesAndListsThatReadBack() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        defer { try? FileManager.default.removeItem(at: dir) }
        for title in Self.titles {
            let url = try TranscriptWriter.write(to: dir, segments: [], startedAt: Date(timeIntervalSince1970: 0),
                                                 duration: 1, participants: [title, "O'Brien"],
                                                 tags: ["call", title], title: title)
            let text = try String(contentsOf: url, encoding: .utf8)
            let front = try XCTUnwrap(Frontmatter.split(text)?.frontmatter)
            let want = TranscriptWriter.sanitizeScalar(title)
            XCTAssertEqual(Frontmatter.field(front, "title"), want, text)
            XCTAssertEqual(Frontmatter.list(front, "participants"), [want, "O'Brien"], text)
            XCTAssertEqual(Frontmatter.list(front, "tags"), ["call", want, TranscriptWriter.ownerMarker], text)
            XCTAssertTrue(text.contains("\n# \(want)"), "the H1 and the title are one value\n\(text)")
            XCTAssertTrue(Frontmatter.hasOwnerMarker(front))
            try FileManager.default.removeItem(at: url)
        }
    }

    func testTheNoteWriterWritesTitlesThatReadBack() throws {
        for title in Self.titles {
            let note = NoteWriter.document(title: title, docType: "reference", domains: ["yes", "calc"], body: "b")
            let front = try XCTUnwrap(Frontmatter.split(note)?.frontmatter)
            XCTAssertEqual(Frontmatter.field(front, "title"), TranscriptWriter.sanitizeScalar(title), note)
            XCTAssertEqual(Frontmatter.list(front, "domains"), ["yes", "calc"], note)
            XCTAssertTrue(front.contains("domains: ['yes', 'calc']"), note)
        }
    }

    /// Notes written before keep their reading: a double-quoted value is never unescaped, and a
    /// double-quoted list item is still read whole.
    func testValuesWrittenBeforeReadAsTheyAlwaysDid() {
        let front = """
        title: "C:\\new: x"
        participants: ["Last, First", "O'Brien"]
        tags: [call, it's]
        a: 'it''s'
        b: 'it's'
        """
        XCTAssertEqual(Frontmatter.field(front, "title"), "C:\\new: x")
        XCTAssertEqual(Frontmatter.list(front, "participants"), ["Last, First", "O'Brien"])
        XCTAssertEqual(Frontmatter.list(front, "tags"), ["call", "it's"])
        XCTAssertEqual(Frontmatter.field(front, "a"), "it's")
        XCTAssertEqual(Frontmatter.field(front, "b"), "'it's'", "not one closed scalar: as written")
        XCTAssertEqual(Frontmatter.parseList("['a, b', 'c''d', \"e\"]"), ["a, b", "c'd", "e"])
    }

    func testGroupRepairClearsUntaggedHoweverItWasQuoted() throws {
        let dir = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: dir) }
        for tags in ["['call', 'untagged']", "[\"call\", \"untagged\"]", "[call, untagged]"] {
            let url = dir.appendingPathComponent("c.md")
            try """
            ---
            date: 2026-01-01
            title: 'T'
            tags: \(tags)
            status: active
            app: call-transcriber
            ---

            # T
            """.write(to: url, atomically: true, encoding: .utf8)
            try TranscriptGroupRepair.assign("Acme: R&D \\ \"x\"", to: url)
            let front = try XCTUnwrap(Frontmatter.split(String(contentsOf: url, encoding: .utf8))?.frontmatter)
            XCTAssertEqual(Frontmatter.list(front, "tags"), ["call"], front)
            XCTAssertEqual(Frontmatter.field(front, "group"), "Acme: R&D \\ 'x'", front)
        }
    }
}
