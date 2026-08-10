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
/// against `spine.py` and `classes.py` catches that at build time and would have caught it before
/// too — the exporter agreeing with the app said nothing about either agreeing with the engine.
///
/// Same trade as `PythonPayloadSource`, with the same stated cost: this couples to the SHAPE of the
/// Python declaration. Rewrite these as anything other than a top-level `NAME: type = frozenset(…)`
/// or a `POLICIES` dict of quoted keys and the parser stops finding them — which fails loudly,
/// where a stale hand-copied duplicate would not have.
final class TranscriptSpineParityTests: XCTestCase {

    /// `#filePath`, not the working directory: `swift test` and Xcode disagree about cwd, and a gate
    /// that silently finds no file is worse than one that cannot run.
    private func engineSource(_ relative: String) throws -> String {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScriptaCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repository root
        let url = root.appendingPathComponent(relative)
        guard FileManager.default.fileExists(atPath: url.path) else {
            throw XCTSkip("engine source not present at \(url.path)")
        }
        return try String(contentsOf: url, encoding: .utf8)
    }

    /// The quoted strings of a top-level `NAME: type = frozenset({...})`, which is how `spine.py`
    /// declares each vocabulary. Returns nil when the declaration cannot be found or parsed, so a
    /// reformat fails the gate rather than passing it empty.
    private func frozenset(_ name: String, in source: String) -> Set<String>? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("\(name):") || $0.hasPrefix("\(name) =")
        }) else { return nil }
        // The declaration may wrap; take lines until the braces balance.
        var text = "", depth = 0, seen = false
        for line in lines[start...] {
            text += line
            depth += line.filter { $0 == "{" || $0 == "(" }.count
            depth -= line.filter { $0 == "}" || $0 == ")" }.count
            if line.contains("{") || line.contains("(") { seen = true }
            if seen, depth <= 0 { break }
        }
        let quoted = text.split(separator: "\"").enumerated()
            .filter { $0.offset % 2 == 1 }.map { String($0.element) }
        return quoted.isEmpty ? nil : Set(quoted)
    }

    /// THE CHECK THAT REPLACED THE PARITY CHECK. Each value capture stamps must be a word the engine
    /// will accept — otherwise the refusal arrives at compose, after the call has been recorded.
    func testTheDeclaredSpineIsEngineVocabulary() throws {
        let spine = try engineSource("substrate/substrate/spine.py")

        guard let statuses = frozenset("STATUSES", in: spine),
              let included = frozenset("INCLUDED_STATUSES", in: spine),
              let docTypes = frozenset("DOC_TYPES", in: spine),
              let confidences = frozenset("CONFIDENCES", in: spine) else {
            return XCTFail("could not parse the vocabularies out of spine.py — that is a gate "
                           + "failure, not a pass")
        }

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
        // against the token spine.py names for it rather than against that set.
        XCTAssertTrue(confidences.contains(TranscriptSpine.confidence)
                      || spine.contains("UNSTATED_CONFIDENCE = \"\(TranscriptSpine.confidence)\""),
                      "confidence '\(TranscriptSpine.confidence)' is neither a judged confidence "
                      + "\(confidences.sorted()) nor the engine's declared no-claim token")
    }

    /// The class is a different axis and lives in a different file. `conversation` is the one the
    /// engine WITHHOLDS from default retrieval, which is the whole reason capture declares it.
    func testTheDeclaredClassIsAnEngineClassAndIsWithheld() throws {
        let classes = try engineSource("substrate/substrate/classes.py")
        XCTAssertTrue(classes.contains("\"\(TranscriptSpine.documentClass)\": ClassPolicy("),
                      "class '\(TranscriptSpine.documentClass)' is not a key of classes.POLICIES")
        XCTAssertTrue(classes.contains("EXCLUDED_CLASSES")
                      && classes.range(of: "EXCLUDED_CLASSES")
                          .map { classes[$0.lowerBound...].contains(TranscriptSpine.documentClass) } == true,
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
            duration: 630, participants: ["Ronan"], tags: ["call"], title: "Quarterly sync")
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
