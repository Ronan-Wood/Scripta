import XCTest
@testable import ScriptaCore
@testable import ScriptaShared

/// The one scalar sanitizer, pinned against the reader that decides what a line break is.
///
/// WHY THIS SUITE EXISTS. `sanitizeScalar` replaced `\r\n`, `\n` and `\r` BY NAME and let eight
/// other characters through, every one of which Python's `str.splitlines()` treats as a break —
/// and `str.splitlines()` is what the engine's frontmatter reader splits the block with. A title
/// carrying one of them (`U+2028` and `U+0085` arrive routinely in text pasted from Word or a
/// browser, and the metadata editor feeds operator-typed titles straight in) forges a frontmatter
/// line or emits one with no colon, which stops the block being frontmatter at all and refuses the
/// whole scope at the next compose — over a recorded call.
///
/// Nothing pinned that behaviour, in either direction, which is why the gap survived four writers.
final class ScalarSanitizerTests: XCTestCase {

    /// Every SINGLE-SCALAR separator `str.splitlines()` honours — the `\r\n` pair has its own test
    /// below, because it is one Swift `Character` and behaves differently. Sourced from the Python
    /// docs' own table rather
    /// than from what the Swift side happens to catch, because the reader is the authority here and
    /// a list derived from the writer would agree with the writer by construction.
    private static let pythonLineBreaks: [(name: String, scalar: Character)] = [
        ("LF U+000A", "\u{0A}"), ("VT U+000B", "\u{0B}"), ("FF U+000C", "\u{0C}"),
        ("CR U+000D", "\u{0D}"), ("FS U+001C", "\u{1C}"), ("GS U+001D", "\u{1D}"),
        ("RS U+001E", "\u{1E}"), ("NEL U+0085", "\u{85}"),
        ("LS U+2028", "\u{2028}"), ("PS U+2029", "\u{2029}"),
    ]

    func testNoLineBreakThePythonReaderHonoursSurvivesTheSanitizer() {
        for (name, scalar) in Self.pythonLineBreaks {
            let cleaned = TranscriptWriter.sanitizeScalar("Real title\(scalar)doc_id: forged")
            XCTAssertFalse(cleaned.contains(scalar),
                           "\(name) survived — it is a line break to str.splitlines()")
            XCTAssertEqual(cleaned.split(whereSeparator: \.isNewline).count, 1,
                           "\(name) left the value spanning more than one line: \(cleaned.debugDescription)")
        }
    }

    /// CRLF is the pair that a naive per-character map turns into TWO spaces. Pinned because the
    /// old implementation special-cased it first for exactly that reason, and the replacement drops
    /// the special case — so the question "did collapsing to one space matter?" has an answer on
    /// record rather than being rediscovered.
    func testCRLFBecomesWhitespaceAndDoesNotBreakTheLine() {
        let cleaned = TranscriptWriter.sanitizeScalar("before\r\nafter")
        XCTAssertFalse(cleaned.contains(where: \.isNewline))
        XCTAssertEqual(cleaned.split(whereSeparator: \.isNewline).count, 1)
        // ONE SPACE, NOT TWO, and that is a real assertion rather than a formality: `\r\n` is a
        // single Swift `Character`, so a per-Character map emits one space where a per-scalar map
        // would emit two. Nothing else pins that, and the difference is invisible until a title
        // shows up with a double space in it.
        XCTAssertEqual(cleaned, "before after")
    }

    /// The C0 range beyond the line breaks. A control byte inside a quoted scalar is not a break,
    /// but it is not something to write into a corpus either, and `tomlString` and
    /// `SubstrateLibraryVault.scalar` both already remove it.
    func testTheRestOfTheC0RangeIsRemoved() {
        for byte in UInt8(0x00)...UInt8(0x1F) {
            let scalar = Character(UnicodeScalar(byte))
            let cleaned = TranscriptWriter.sanitizeScalar("a\(scalar)b")
            XCTAssertEqual(cleaned, "a b",
                           "0x\(String(byte, radix: 16)) was not neutralised: \(cleaned.debugDescription)")
        }
    }

    /// The quote is REPLACED, never escaped — nothing on either side unescapes, so a backslash
    /// would be stored literally and read back mangled.
    func testAQuoteBecomesAnApostropheAndNoBackslashIsIntroduced() {
        let cleaned = TranscriptWriter.sanitizeScalar("He said \"no\" twice")
        XCTAssertEqual(cleaned, "He said 'no' twice")
        XCTAssertFalse(cleaned.contains("\\"))
    }

    /// ORDINARY TEXT IS LEFT ALONE. A sanitizer that quietly mangles a normal title would pass every
    /// test above.
    func testOrdinaryTextIsUnchanged() {
        for title in ["Quarterly sync", "Q3 — planning (draft)", "Über/naïve: notes", "a\tb"] {
            let cleaned = TranscriptWriter.sanitizeScalar(title)
            let expected = title.replacingOccurrences(of: "\t", with: " ")
            XCTAssertEqual(cleaned, expected, "mangled an ordinary title")
        }
    }

    /// THE TWO WRITERS ARE ONE RULE, asserted rather than assumed. `NoteWriter` held a fourth copy
    /// of this that was CORRECT while `sanitizeScalar` was not — the duplicate looked harmless
    /// precisely because it was the right one, so the divergence read as style and was a live
    /// scope-refusal on the transcript path. This fails if they are ever forked again.
    func testTheNoteWriterAndTheTranscriptWriterAgreeCharacterForCharacter() throws {
        var probes = ["plain", "He said \"no\"", "trailing   ", "   leading"]
        probes += Self.pythonLineBreaks.map { "a\($0.scalar)b" }
        probes += (UInt8(0x00)...UInt8(0x1F)).map { "a\(Character(UnicodeScalar($0)))b" }

        for probe in probes {
            // The note writer's copy is private, so it is compared through the artefact it writes:
            // the frontmatter `title:` and the H1 both carry the sanitised value.
            let note = NoteWriter.document(title: "x\(probe)x", docType: "note", body: "b")
            guard let split = Frontmatter.split(note),
                  let line = split.frontmatter.components(separatedBy: "\n")
                      .first(where: { $0.hasPrefix("title:") })
            else { return XCTFail("no title line for \(probe.debugDescription)") }
            let readBack = line.dropFirst("title:".count)
                .trimmingCharacters(in: .whitespaces)
                .trimmingCharacters(in: CharacterSet(charactersIn: "\""))
            XCTAssertEqual(readBack, TranscriptWriter.sanitizeScalar("x\(probe)x"),
                           "the two sanitizers disagree on \(probe.debugDescription)")
        }
    }
}
