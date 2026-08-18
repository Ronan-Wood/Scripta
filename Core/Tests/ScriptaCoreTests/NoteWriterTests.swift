import XCTest
@testable import ScriptaCore
@testable import ScriptaShared

/// The note path's gate, in the same shape `TranscriptSpineParityTests` established: check what the
/// app declares against the ENGINE's own vocabulary, parsed from `spine.py`, rather than against a
/// second copy of the decision.
///
/// It exists because the failure it covers was measured rather than imagined. On 2026-08-17 a blank
/// vault refused a hand-written note twice — `no status`, then `no doc_type` — and the app named
/// neither field anywhere. A note that declares a word the engine has no case for fails the same
/// way, one compose later.
final class NoteWriterTests: XCTestCase {

    // MARK: - Against the engine's vocabulary

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

    /// The quoted strings of a top-level `NAME: type = frozenset({...})`. Same parser as
    /// `TranscriptSpineParityTests`, and the same stated cost: it couples to the SHAPE of the Python
    /// declaration, and a reformat fails the gate rather than passing it empty.
    private func frozenset(_ name: String, in source: String) -> Set<String>? {
        let lines = source.components(separatedBy: "\n")
        guard let start = lines.firstIndex(where: {
            $0.hasPrefix("\(name):") || $0.hasPrefix("\(name) =")
        }) else { return nil }
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

    func testTheStatusIsLegalAndIsSEARCHED() throws {
        let spine = try engineSource("substrate/substrate/spine.py")
        guard let statuses = frozenset("STATUSES", in: spine),
              let included = frozenset("INCLUDED_STATUSES", in: spine) else {
            return XCTFail("could not parse the status vocabularies out of spine.py — that is a "
                           + "gate failure, not a pass")
        }
        XCTAssertTrue(statuses.contains(NoteSpine.status),
                      "notes declare status '\(NoteSpine.status)', not in \(statuses.sorted()) — "
                      + "every hand-written note would be refused at compose")
        XCTAssertTrue(included.contains(NoteSpine.status),
                      "status '\(NoteSpine.status)' is legal but outside default retrieval "
                      + "\(included.sorted()) — notes would index and never be found, which reads "
                      + "as an empty vault rather than as a bug")
    }

    /// EXACT SET EQUALITY, not containment, and both directions are a real defect. A type the engine
    /// accepts but the picker omits is a vocabulary the operator cannot reach from the app; a type
    /// the picker offers but the engine rejects is a note refused at the next compose.
    func testThePickerOffersEXACTLYTheEnginesDocTypes() throws {
        let spine = try engineSource("substrate/substrate/spine.py")
        guard let docTypes = frozenset("DOC_TYPES", in: spine) else {
            return XCTFail("could not parse DOC_TYPES out of spine.py — a gate failure, not a pass")
        }
        XCTAssertEqual(Set(NoteSpine.docTypes.map(\.value)), docTypes,
                       "the picker and the engine disagree about doc_type")
        XCTAssertTrue(docTypes.contains(NoteSpine.defaultDocType),
                      "the DEFAULT doc_type '\(NoteSpine.defaultDocType)' is not one the engine "
                      + "accepts — the note nobody edits the picker for is the one that fails")
    }

    /// The picker's own list must not carry a duplicate: `ForEach` over `Identifiable` with a
    /// repeated id renders one row and drops the other silently.
    func testTheOfferedTypesAreDistinct() {
        XCTAssertEqual(Set(NoteSpine.docTypes.map(\.value)).count, NoteSpine.docTypes.count)
        XCTAssertEqual(Set(NoteSpine.confidences.map(\.value)).count, NoteSpine.confidences.count)
    }

    /// `unstated` is DECLARABLE but is not a member of `CONFIDENCES` — the engine names it
    /// separately as the no-claim token. Offering it is correct; asserting it belongs to the judged
    /// set would not be, so it is checked against the token `spine.py` declares for it.
    func testTheConfidencesAreEngineVocabulary() throws {
        let spine = try engineSource("substrate/substrate/spine.py")
        guard let judged = frozenset("CONFIDENCES", in: spine) else {
            return XCTFail("could not parse CONFIDENCES out of spine.py — a gate failure, not a pass")
        }
        for level in NoteSpine.confidences {
            XCTAssertTrue(judged.contains(level.value)
                          || spine.contains("UNSTATED_CONFIDENCE = \"\(level.value)\""),
                          "confidence '\(level.value)' is neither in \(judged.sorted()) nor the "
                          + "engine's declared no-claim token — a shared note declaring it would "
                          + "be refused at compose")
        }
        // And every judged value is offered: one missing is a claim the operator cannot make.
        XCTAssertTrue(judged.isSubset(of: Set(NoteSpine.confidences.map(\.value))),
                      "the picker omits \(judged.subtracting(Set(NoteSpine.confidences.map(\.value))))")
        XCTAssertTrue(NoteSpine.confidences.contains { $0.value == NoteSpine.defaultConfidence })
    }

    /// The folder decides the TIER (`vault._tier_for`), so this is not cosmetic: a shared note in
    /// `02-areas/` would be filed as project thinking and rank as the wrong kind of thing, with
    /// every gate reporting PASS.
    func testEachDestinationWritesIntoItsOwnTierFolder() {
        XCTAssertEqual(NoteDestination.workspace.folderName, "02-areas")
        XCTAssertEqual(NoteDestination.shared.folderName, "00-operator")
        XCTAssertFalse(NoteDestination.workspace.declaresJudgement)
        XCTAssertTrue(NoteDestination.shared.declaresJudgement)
    }

    // MARK: - What actually reaches the file

    private func vault() -> URL {
        URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("NoteWrite-\(UUID().uuidString)", isDirectory: true)
    }

    func testAWrittenNoteCarriesBothRequiredFields() throws {
        let root = vault()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try NoteWriter.write(intoVaultAt: root, title: "Why we picked Postgres",
                                       docType: "decision", body: "The team already knows it.")
        let text = try String(contentsOf: url, encoding: .utf8)

        XCTAssertTrue(text.contains("\nstatus: \(NoteSpine.status)\n"), text)
        XCTAssertTrue(text.contains("\ndoc_type: decision\n"), text)
        XCTAssertTrue(text.contains("The team already knows it."), text)
        XCTAssertEqual(url.lastPathComponent, "why-we-picked-postgres.md")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent,
                       ScriptaVault.notesFolderName)
    }

    /// The frontmatter title and the H1 are one value — the parity transcripts lost once.
    func testTheHeadingAndTheDeclaredTitleAgree() throws {
        let root = vault()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try NoteWriter.write(intoVaultAt: root, title: "Sharding: by hash",
                                       docType: "explanation", body: "")
        let text = try String(contentsOf: url, encoding: .utf8)
        guard let front = Frontmatter.split(text)?.frontmatter else {
            return XCTFail("no frontmatter\n\n\(text)")
        }
        // Quoted, because this title contains ": " and would otherwise parse as a mapping.
        XCTAssertTrue(front.contains("title: \"Sharding: by hash\""), front)
        XCTAssertEqual(text.components(separatedBy: "\n").first { $0.hasPrefix("# ") },
                       "# Sharding: by hash")
    }

    func testABodylessNoteIsStillAValidNote() throws {
        let root = vault()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try NoteWriter.write(intoVaultAt: root, title: "Placeholder",
                                       docType: "reference", body: "   \n  ")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertNotNil(Frontmatter.split(text), "frontmatter must still parse\n\n\(text)")
        XCTAssertTrue(text.hasSuffix("# Placeholder\n"), "trailing whitespace body leaked\n\n\(text)")
    }

    // MARK: - The refusals

    func testASecondNoteWithTheSameTitleIsRefusedRatherThanUniquified() throws {
        let root = vault()
        defer { try? FileManager.default.removeItem(at: root) }

        try NoteWriter.write(intoVaultAt: root, title: "Retrieval", docType: "explanation", body: "a")
        XCTAssertThrowsError(try NoteWriter.write(intoVaultAt: root, title: "Retrieval",
                                                  docType: "explanation", body: "b")) { error in
            XCTAssertEqual(error as? NoteWriter.Failure, .alreadyExists("retrieval.md"))
        }
        // AND the first note is untouched — the refusal must not have half-written over it.
        let survivor = root.appendingPathComponent("\(ScriptaVault.notesFolderName)/retrieval.md")
        XCTAssertTrue(try String(contentsOf: survivor, encoding: .utf8).contains("\na\n"))
    }

    /// Titles that differ only by punctuation or case slug to ONE filename, so this is the same
    /// refusal reached by a route the operator does not see coming.
    func testTitlesThatSlugAlikeCollide() throws {
        let root = vault()
        defer { try? FileManager.default.removeItem(at: root) }

        try NoteWriter.write(intoVaultAt: root, title: "Refresh budget", docType: "decision", body: "")
        XCTAssertThrowsError(try NoteWriter.write(intoVaultAt: root, title: "Refresh, Budget!",
                                                  docType: "decision", body: "")) { error in
            // THE REASON, not merely that something was raised. Neutering the collision guard left
            // this test green on a Foundation write error from `.withoutOverwriting` — the backstop
            // firing, not the check under test. A refusal the operator can read is the behaviour.
            XCTAssertEqual(error as? NoteWriter.Failure, .alreadyExists("refresh-budget.md"))
        }
    }

    func testAnEmptyOrUnusableTitleIsRefused() throws {
        let root = vault()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try NoteWriter.write(intoVaultAt: root, title: "   ",
                                                  docType: "decision", body: "x")) { error in
            XCTAssertEqual(error as? NoteWriter.Failure, .titleEmpty)
        }
        // Non-ASCII slugs to nothing. Refused with its own message rather than writing `.md`.
        XCTAssertThrowsError(try NoteWriter.write(intoVaultAt: root, title: "日本語",
                                                  docType: "decision", body: "x")) { error in
            XCTAssertEqual(error as? NoteWriter.Failure, .titleUnusable("日本語"))
        }
    }

    func testADocTypeTheEngineWouldRejectIsRefusedHere() throws {
        let root = vault()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try NoteWriter.write(intoVaultAt: root, title: "Note",
                                                  docType: "note", body: "x")) { error in
            XCTAssertEqual(error as? NoteWriter.Failure, .unknownDocType("note"))
        }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(ScriptaVault.notesFolderName).path),
            "a refused note must not leave a folder behind")
    }

    // MARK: - The shared destination

    /// A shared vault, and NOTE THAT IT HAS NO MANIFEST — because a real one does not. The engine's
    /// `resolve_vaults` says "core-vault has no manifest (it is the root)", and the first version of
    /// this fixture wrote one, which let a guard that refused every real core-vault pass its test.
    private func sharedVault() -> URL {
        let root = vault()
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        return root
    }

    func testASharedNoteLandsInTheOperatorTierAndDeclaresItsJudgement() throws {
        let root = sharedVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try NoteWriter.write(intoVaultAt: root, destination: .shared,
                                       title: "How the operator reviews",
                                       docType: "explanation", confidence: "verified",
                                       domains: ["operator", "process"],
                                       body: "Audit, then implement, then verify.")
        let text = try String(contentsOf: url, encoding: .utf8)

        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "00-operator")
        XCTAssertTrue(text.contains("\nconfidence: verified\n"), text)
        XCTAssertTrue(text.contains("\ndomains: [operator, process]\n"), text)
    }

    /// A workspace note declares NEITHER, and that is a deliberate difference rather than an
    /// oversight: an omitted confidence stores as `unjudged`, which is the true statement about a
    /// note nobody has judged. Writing `unstated` would claim a judgement was made.
    func testAWorkspaceNoteDeclaresNoJudgement() throws {
        let root = vault()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try NoteWriter.write(intoVaultAt: root, title: "Local thing",
                                       docType: "explanation", body: "x")
        let text = try String(contentsOf: url, encoding: .utf8)
        XCTAssertFalse(text.contains("confidence:"), text)
        XCTAssertFalse(text.contains("domains:"), text)
    }

    /// An empty domains list is OMITTED, never written as `domains: []` — that would be a declared
    /// claim of belonging to no subject, and `domains` is what cross-scope filtering runs on.
    func testEmptyDomainsAreOmittedRatherThanDeclaredEmpty() throws {
        let root = sharedVault()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try NoteWriter.write(intoVaultAt: root, destination: .shared, title: "Bare",
                                       docType: "reference", confidence: "stated",
                                       domains: ["  ", ""], body: "x")
        XCTAssertFalse(try String(contentsOf: url, encoding: .utf8).contains("domains:"))
    }

    /// THE REGRESSION TEST FOR THE GUARD THAT REFUSED EVERY REAL CORE-VAULT. A root vault carries no
    /// `.substrate.toml` — a manifest declares what a vault inherits, and the root inherits nothing
    /// — so a check for one refused precisely the directory this destination exists to write into.
    /// Caught by pointing the shipped Settings picker at the operator's actual core-vault.
    func testASharedVaultNeedsNoManifest() throws {
        let root = sharedVault()
        defer { try? FileManager.default.removeItem(at: root) }
        XCTAssertFalse(FileManager.default.fileExists(
            atPath: root.appendingPathComponent(ScriptaVault.manifestName).path),
            "the fixture must have no manifest, or it cannot reach the state that broke")

        let url = try NoteWriter.write(intoVaultAt: root, destination: .shared, title: "Root note",
                                       docType: "explanation", confidence: "stated", body: "x")
        XCTAssertEqual(url.deletingLastPathComponent().lastPathComponent, "00-operator")
    }

    /// A stale setting — the folder renamed, the drive unmounted — must refuse rather than rebuild
    /// the vault as an empty shell somewhere nothing composes.
    func testASharedNoteIntoAMissingDirectoryIsRefused() throws {
        let root = vault()   // never created
        XCTAssertThrowsError(try NoteWriter.write(intoVaultAt: root, destination: .shared,
                                                  title: "Nowhere", docType: "reference",
                                                  confidence: "stated", body: "x")) { error in
            XCTAssertEqual(error as? NoteWriter.Failure, .vaultMissing(root.path))
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: root.path),
                       "a refused note must not create the vault it was refused from")
    }

    func testAConfidenceTheEngineWouldRejectIsRefusedHere() throws {
        let root = sharedVault()
        defer { try? FileManager.default.removeItem(at: root) }

        XCTAssertThrowsError(try NoteWriter.write(intoVaultAt: root, destination: .shared,
                                                  title: "Sure", docType: "decision",
                                                  confidence: "high", body: "x")) { error in
            XCTAssertEqual(error as? NoteWriter.Failure, .unknownConfidence("high"))
        }
    }

    /// A traversing title cannot escape `02-areas/`. The slug already strips the separators; this
    /// asserts the outcome rather than trusting the argument.
    func testATraversingTitleStaysInsideTheNotesFolder() throws {
        let root = vault()
        defer { try? FileManager.default.removeItem(at: root) }

        let url = try NoteWriter.write(intoVaultAt: root, title: "../../etc/passwd",
                                       docType: "reference", body: "x")
        XCTAssertEqual(url.deletingLastPathComponent().standardizedFileURL,
                       root.appendingPathComponent(ScriptaVault.notesFolderName,
                                                   isDirectory: true).standardizedFileURL)
        XCTAssertEqual(url.lastPathComponent, "etc-passwd.md")
    }
}
