import XCTest
@testable import ScriptaCore
@testable import ScriptaShared

/// The spine is declared ONCE now — by `TranscriptSpine` at capture — so there is nothing left to
/// be parity WITH. What replaced the parity check is stronger: every value it declares is checked
/// against the engine's own VOCABULARY, not against a second copy of the decision.
///
/// The old gate compared Scripta's four values to `transcript_export.py`'s. That file is gone
/// (Doc 4 §7: capture writes into the vault, so nothing exports into one), and with it the second
/// author. But the risk it covered did not go anywhere: a transcript declaring a word the engine
/// has no case for is refused at compose, after the call has been recorded and written. Comparing
/// against the engine's own vocabularies — as its contract states them (`EngineVocabulary`) —
/// catches that at build time and would have caught it before too: the exporter agreeing with the
/// app said nothing about either agreeing with the engine.
final class TranscriptSpineParityTests: XCTestCase {

    /// THE CHECK THAT REPLACED THE PARITY CHECK. Each value capture stamps must be a word the engine
    /// will accept — otherwise the refusal arrives at compose, after the call has been recorded.
    func testTheDeclaredSpineIsEngineVocabulary() throws {
        let spine = try EngineVocabulary.load().spine
        let statuses = spine.statuses, included = spine.includedStatuses
        let docTypes = spine.docTypes

        XCTAssertTrue(statuses.contains(TranscriptSpine.status),
                      "capture stamps status '\(TranscriptSpine.status)', which is not in the "
                      + "engine's \(statuses.sorted()) — every call would be refused at compose")
        // AND it must be a status default retrieval SEARCHES. A transcript filed as `archived`
        // would compose cleanly and never answer, which is the failure that looks like an empty
        // vault rather than like a bug.
        XCTAssertTrue(included.contains(TranscriptSpine.status),
                      "status '\(TranscriptSpine.status)' is legal but outside default retrieval "
                      + "\(included.sorted()) — calls would index and never be found")
        XCTAssertTrue(docTypes.contains(TranscriptSpine.docType),
                      "doc_type '\(TranscriptSpine.docType)' is not in \(docTypes.sorted())")
        // `unstated` is declarable but is not in CONFIDENCES (the judged set), so it is checked
        // against what the engine lets a note DECLARE rather than against that set.
        XCTAssertTrue(spine.declarableConfidences.contains(TranscriptSpine.confidence),
                      "confidence '\(TranscriptSpine.confidence)' is not one the engine lets a "
                      + "note declare \(spine.declarableConfidences.sorted())")
    }

    /// The class is a different axis and lives in a different file. `conversation` is the one the
    /// engine WITHHOLDS from default retrieval, which is the whole reason capture declares it.
    func testTheDeclaredClassIsAnEngineClassAndIsWithheld() throws {
        let classes = try EngineVocabulary.load().classes
        XCTAssertTrue(classes.policies.contains(TranscriptSpine.documentClass),
                      "class '\(TranscriptSpine.documentClass)' is not one of the engine's classes "
                      + "\(classes.policies.sorted())")
        XCTAssertTrue(classes.excluded.contains(TranscriptSpine.documentClass),
                      "class '\(TranscriptSpine.documentClass)' is no longer withheld by default — "
                      + "call passages would arrive uninvited in every query")
    }

    // MARK: - What actually reaches the file

    func testAWrittenTranscriptCarriesTheSpine() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SpineWrite-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try TranscriptWriter.write(
            to: dir,
            segments: [TranscriptSegment(startMs: 0, text: "Budgets and hiring.", speaker: .you)],
            startedAt: Date(timeIntervalSince1970: 1_785_000_000),
            duration: 630, participants: ["Alex"], tags: ["call"], title: "Quarterly sync")
        let text = try String(contentsOf: url, encoding: .utf8)

        for expected in ["status: \(TranscriptSpine.status)",
                         "doc_type: \(TranscriptSpine.docType)",
                         "confidence: \(TranscriptSpine.confidence)",
                         "class: \(TranscriptSpine.documentClass)",
                         "app: \(OwnerMarker.value)"] {
            XCTAssertTrue(text.contains("\n\(expected)\n"), "missing `\(expected)`\n\n\(text)")
        }
    }

    /// `title` used to be omitted when empty while the same computed value became the H1 — so the
    /// file carried the title in prose and withheld it as data, and every reader either regexed the
    /// heading or fell back to the filename.
    func testAnUntitledTranscriptStillDeclaresItsTitle() throws {
        let dir = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("SpineTitle-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: dir) }

        let url = try TranscriptWriter.write(
            to: dir, segments: [], startedAt: Date(timeIntervalSince1970: 1_785_000_000),
            duration: 60, title: nil)
        let text = try String(contentsOf: url, encoding: .utf8)

        guard let front = Frontmatter.split(text)?.frontmatter else {
            return XCTFail("no frontmatter\n\n\(text)")
        }
        XCTAssertTrue(front.contains("title: '"), "an untitled call must still declare a title:\n\(front)")
        // And it must be the value the H1 uses, or the two readers disagree again.
        let heading = text.components(separatedBy: "\n").first { $0.hasPrefix("# ") }
        XCTAssertNotNil(heading)
        XCTAssertEqual(heading, "# \(Frontmatter.field(front, "title"))")
    }
}
