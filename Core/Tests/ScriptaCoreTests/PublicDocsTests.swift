import Foundation
import XCTest

/// The documents a newcomer reads name no one's machine: the Markdown at the root and directly in
/// `Distribution/`, anywhere under `docs/` and `Skill/`, and the issue and PR templates. In a git checkout only tracked files
/// count, so a contributor's untracked scratch note cannot fail the suite. A release's source tarball
/// has no `.git`, and there every file in the tree counts.
final class PublicDocsTests: XCTestCase {
    /// `#filePath`, not the working directory: `swift test` and Xcode disagree about cwd.
    private static let root = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ScriptaCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Core
        .deletingLastPathComponent()   // repository root
        .standardizedFileURL

    /// A home folder or a per-user temporary folder, in the usual spellings: `/Users/`, `/home/`,
    /// `/var/folders/`, `C:\Users\`, `$HOME`, `~name/` and `~/`. `~/.substrate`, the engine's own
    /// folder, names no machine.
    static let home = try! NSRegularExpression(pattern:
        #"/Users/|/home/\w|/var/folders/|[A-Z]:\\Users\\|\$\{?HOME\b|~[A-Z][\w.-]*/"# +
        #"|~/(?!\.substrate(?![\w.-]))[\w.-]"#, options: [.caseInsensitive])

    /// A dated record keeps its original text, so it is not scanned. Each one is named here.
    private static let unscanned: Set = ["docs/history/SPEC.md"]

    /// One document from each place the scan looks, so a sweep that silently finds nothing fails.
    private static let named = [
        "README.md", "docs/README.md", "Distribution/RELEASING.md", "Skill/scripta/SKILL.md",
        ".github/pull_request_template.md", ".github/ISSUE_TEMPLATE/bug_report.yml",
    ]

    private static func git(_ arguments: String...) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/git")
        process.arguments = ["-C", root.path] + arguments
        let out = Pipe()
        process.standardOutput = out
        process.standardError = FileHandle.nullDevice
        do { try process.run() } catch { return nil }
        let data = out.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: data, encoding: .utf8)
    }

    /// The tracked paths, or nil when this tree is not the root of its own checkout (a source
    /// tarball, or a copy inside some other repository).
    private static func tracked() -> Set<String>? {
        guard let top = git("rev-parse", "--show-toplevel"),
              URL(fileURLWithPath: top.trimmingCharacters(in: .newlines)).resolvingSymlinksInPath().path
                == root.resolvingSymlinksInPath().path,
              let out = git("ls-files", "-z") else { return nil }
        return Set(out.split(separator: "\0").map(String.init))
    }

    /// Repository-relative paths of the documents, sorted.
    private static func documents(tracked: Set<String>?) -> [String] {
        let fm = FileManager.default
        func list(_ directory: String) -> [String] {
            ((try? fm.contentsOfDirectory(atPath: root.appendingPathComponent(directory).path)) ?? [])
                .map { directory.isEmpty ? $0 : "\(directory)/\($0)" }
        }
        func walk(_ directory: String) -> [String] {
            (fm.enumerator(atPath: root.appendingPathComponent(directory).path)?.allObjects as? [String] ?? [])
                .map { "\(directory)/\($0)" }
        }
        let found = (list("") + walk("docs") + list("Distribution") + walk("Skill"))
            .filter { $0.hasSuffix(".md") }
            + list(".github").filter { $0.hasSuffix("pull_request_template.md") }
            + list(".github/ISSUE_TEMPLATE")
        // A new document counts once it is staged, as `git add -N` or `git add` leaves it.
        return found.filter { !unscanned.contains($0) && (tracked?.contains($0) ?? true) }.sorted()
    }

    func testThePublicDocumentsNameNoOnesMachine() throws {
        let documents = Self.documents(tracked: Self.tracked())
        XCTAssertEqual(Set(Self.named).subtracting(documents), [], "a place the scan looks found nothing")
        for path in documents {
            let text = try String(contentsOf: Self.root.appendingPathComponent(path), encoding: .utf8)
            for (index, line) in text.components(separatedBy: "\n").enumerated() {
                if Self.home.firstMatch(in: line, range: NSRange(line.startIndex..., in: line)) != nil {
                    XCTFail("\(path):\(index + 1): \(line)")
                }
            }
        }
    }

    func testTheHomePatternAllowsOnlyTheEngineFolder() {
        func matches(_ text: String) -> Bool {
            Self.home.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) != nil
        }
        for spelling in ["/Users/someone/notes", "/users/someone/notes", "/home/Someone", "/home/someone",
                         "$HOME/notes", "${HOME}/notes", "\"$HOME/Key.dmg\"", "cd \"$HOME\"", "~someone/notes",
                         "~/vaults/core", "~/Documents/x", "~/Library/Application Support/x",
                         "~/.substrate-old/x", "~/.substrate.bak", "/var/folders/ab/T/tmp.x", "C:\\Users\\someone"] {
            XCTAssertTrue(matches(spelling), spelling)
        }
        for spelling in ["~/.substrate/run/substrate.sock", "~/.substrate", "`~/.substrate`",
                         "/Volumes/External/models", "/Applications/Scripta.app", "cd Core && swift test",
                         "about ~600 MB", "HOMEBREW_PREFIX"] {
            XCTAssertFalse(matches(spelling), spelling)
        }
    }
}
