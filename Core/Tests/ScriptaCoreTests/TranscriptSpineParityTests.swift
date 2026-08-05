import XCTest
@testable import ScriptaCore
@testable import ScriptaShared

/// The spine is declared TWICE — by `TranscriptSpine` at capture and by `transcript_export.py` at
/// export — and this is what stops the two meaning different things.
///
/// Keeping both is deliberate (see `TranscriptSpine`): `_RESERVED_KEYS` drops a source spine value
/// so the app can never supply one the exporter believes it decided, which is a guard worth having
/// while an exporter exists. The cost of that guard is exactly this — two statements of one fact —
/// and the only honest way to pay it is a gate that fails when they diverge.
///
/// Same trade as `PythonPayloadSource`, with the same stated cost: this couples to the SHAPE of the
/// Python declaration, not just its value. Rewrite those constants as anything other than a
/// top-level `NAME = "value"` and the parser stops finding them — which fails loudly, where a stale
/// hand-copied duplicate would not have.
final class TranscriptSpineParityTests: XCTestCase {

    /// `#filePath`, not the working directory: `swift test` and Xcode disagree about cwd, and a gate
    /// that silently finds no file is worse than one that cannot run.
    private func exporterSource() throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScriptaCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repository root
        let url = root.appendingPathComponent("substrate/substrate/transcript_export.py")
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("engine source not present at \(url.path)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// A top-level `NAME = "value"`, ignoring the comment blocks that carry each one's argument.
    private func constant(_ name: String, in source: String) -> String? {
        for line in source.components(separatedBy: "\n") {
            guard line.hasPrefix("\(name) ") || line.hasPrefix("\(name)=") else { continue }
            guard let equals = line.firstIndex(of: "=") else { continue }
            let value = line[line.index(after: equals)...]
                .trimmingCharacters(in: .whitespaces)
            guard value.count >= 2, value.first == "\"", value.last == "\"" else { continue }
            return String(value.dropFirst().dropLast())
        }
        return nil
    }

    func testSwiftSpineMatchesTheExporters() throws {
        let source = try exporterSource()
        let pairs: [(swift: String, python: String, label: String)] = [
            (TranscriptSpine.status, "TRANSCRIPT_STATUS", "status"),
            (TranscriptSpine.docType, "TRANSCRIPT_DOC_TYPE", "doc_type"),
            (TranscriptSpine.confidence, "TRANSCRIPT_CONFIDENCE", "confidence"),
            (TranscriptSpine.documentClass, "TRANSCRIPT_CLASS", "class"),
        ]
        for pair in pairs {
            guard let engine = constant(pair.python, in: source) else {
                return XCTFail("\(pair.python) not found in transcript_export.py — the parser could "
                               + "not read the declaration, which is a gate failure, not a pass")
            }
            XCTAssertEqual(pair.swift, engine,
                           "\(pair.label): capture writes '\(pair.swift)', the exporter authors "
                           + "'\(engine)'. One of them is now lying about every transcript.")
        }
    }

    /// The owner marker is the same fact in a third place — the engine gained it when the export
    /// learned that three of Scripta's four `app:` markers are not transcripts.
    func testOwnerMarkerMatchesTheExporters() throws {
        let source = try exporterSource()
        guard let engine = constant("TRANSCRIPT_MARKER", in: source) else {
            return XCTFail("TRANSCRIPT_MARKER not found in transcript_export.py")
        }
        XCTAssertEqual(OwnerMarker.value, engine,
                       "the app marks transcripts '\(OwnerMarker.value)' and the exporter selects "
                       + "on '\(engine)' — no transcript would ever be exported")
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
            duration: 630, participants: ["Ronan"], tags: ["call"], title: "Quarterly sync",
            group: "CBRE")
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
        XCTAssertTrue(front.contains("title: \""), "an untitled call must still declare a title:\n\(front)")
        // And it must be the value the H1 uses, or the two readers disagree again.
        let heading = text.components(separatedBy: "\n").first { $0.hasPrefix("# ") }
        XCTAssertNotNil(heading)
        let titleLine = front.components(separatedBy: "\n").first { $0.hasPrefix("title:") }
        let title = titleLine?
            .replacingOccurrences(of: "title: \"", with: "")
            .replacingOccurrences(of: "\"", with: "")
        XCTAssertEqual(heading, "# \(title ?? "")")
    }
}
