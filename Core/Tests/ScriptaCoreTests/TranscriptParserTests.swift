import XCTest
@testable import ScriptaCore
@testable import ScriptaShared

/// Covers the transcript-line parser — purpose-built for the exact shapes TranscriptWriter emits.
/// A regression here mis-renders the viewer (drops speaker labels, mangles timestamps) (audit L14).
final class TranscriptParserTests: XCTestCase {

    private func blocks(_ body: String) -> [TranscriptBlock] {
        // A minimal app-authored transcript; the parser strips the frontmatter itself.
        TranscriptParser.parse("---\napp: call-transcriber\n---\n\n\(body)\n")
    }

    private func assertAudio(_ b: TranscriptBlock?, _ stamp: String, _ speaker: String?, _ text: String,
                             file: StaticString = #file, line: UInt = #line) {
        guard case let .audioLine(s, sp, t)? = b else {
            return XCTFail("expected audioLine, got \(String(describing: b))", file: file, line: line)
        }
        XCTAssertEqual(s, stamp, file: file, line: line)
        XCTAssertEqual(sp, speaker, file: file, line: line)
        XCTAssertEqual(t, text, file: file, line: line)
    }

    func testLabeledSpeakerLine() {
        assertAudio(blocks("**[0:05] You:** hello there").first, "[0:05]", "You", "hello there")
    }

    func testUnlabeledLine() {
        assertAudio(blocks("**[0:00]** just some text").first, "[0:00]", nil, "just some text")
    }

    func testHoursTimestampAndThemSpeaker() {
        assertAudio(blocks("**[1:02:03] Them:** on the far side").first, "[1:02:03]", "Them", "on the far side")
    }

    func testEmptyRestBecomesScreenMarker() {
        guard case let .screenMarker(stamp)? = blocks("**[1:23]**").first else {
            return XCTFail("expected screenMarker")
        }
        XCTAssertEqual(stamp, "[1:23]")
    }

    func testSectionHeaderAndDivider() {
        guard case let .section(title)? = blocks("## Summary").first else { return XCTFail("expected section") }
        XCTAssertEqual(title, "Summary")
        guard case .divider? = blocks("---").first else { return XCTFail("expected divider") }
    }

    func testTitleH1IsSkipped() {
        XCTAssertTrue(blocks("# Some Title").isEmpty)
    }

    func testTableDropsSeparatorRow() {
        guard case let .table(rows)? = blocks("| Name | Role |\n| --- | --- |\n| Sarah | PM |").first else {
            return XCTFail("expected table")
        }
        XCTAssertEqual(rows, ["| Name | Role |", "| Sarah | PM |"])
    }

    func testLegacyUnlabeledStillParses() {
        // Old transcripts (pre speaker labels) use the same bold-timestamp shape with no speaker.
        assertAudio(blocks("**[0:12]** legacy line").first, "[0:12]", nil, "legacy line")
    }
}
