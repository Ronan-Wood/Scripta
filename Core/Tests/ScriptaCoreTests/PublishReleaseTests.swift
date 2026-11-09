import Foundation
import XCTest

/// `Distribution/publish-release`, run for real in a throwaway repository: the release carries the
/// source of the commit that was built, and `--dry-run` publishes nothing. Sparkle's tools and `gh`
/// are stubs, and `origin` is a bare repository beside it, so nothing leaves the machine.
final class PublishReleaseTests: XCTestCase {
    /// `#filePath`, not the working directory: `swift test` and Xcode disagree about cwd.
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ScriptaCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Core
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("Distribution/publish-release")

    private static let version = "1.2.3"
    private static let tag = "v1.2.3"
    private static let source = "dist/Scripta-1.2.3-source.tar.gz"

    private var root: URL!
    private var repo: URL { root.appendingPathComponent("repo") }
    private var origin: URL { root.appendingPathComponent("origin.git") }
    private var ghCalls: URL { root.appendingPathComponent("gh-calls") }
    /// The commit the dmg was built from. HEAD moves past it before the release runs.
    private var built = ""

    private typealias Run = (status: Int32, out: String, err: String)

    @discardableResult
    private func sh(_ arguments: [String], in directory: URL? = nil, path: String = "/usr/bin:/bin") throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = directory ?? repo
        // No global or system git config: the user's may sign tags, which would prompt.
        process.environment = [
            "PATH": path, "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
            "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
        ]
        // Files, not pipes: a full pipe that nobody reads blocks the child.
        let id = UUID().uuidString
        let outURL = root.appendingPathComponent("out-\(id)"), errURL = root.appendingPathComponent("err-\(id)")
        FileManager.default.createFile(atPath: outURL.path, contents: nil)
        FileManager.default.createFile(atPath: errURL.path, contents: nil)
        let out = try FileHandle(forWritingTo: outURL), err = try FileHandle(forWritingTo: errURL)
        defer { try? out.close(); try? err.close() }
        process.standardOutput = out
        process.standardError = err
        try process.run()
        process.waitUntilExit()
        return (process.terminationStatus, try String(contentsOf: outURL, encoding: .utf8),
                try String(contentsOf: errURL, encoding: .utf8))
    }

    @discardableResult
    private func git(_ arguments: String..., in directory: URL? = nil) throws -> String {
        let run = try sh(["/usr/bin/git"] + arguments, in: directory)
        XCTAssertEqual(run.status, 0, "git \(arguments.joined(separator: " ")): \(run.err)")
        return run.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func url(_ path: String) -> URL {
        path.hasPrefix("/") ? URL(fileURLWithPath: path) : repo.appendingPathComponent(path)
    }

    private func write(_ data: Data, to path: String, executable: Bool = false) throws {
        let url = url(path)
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try data.write(to: url)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private func write(_ text: String, to path: String, executable: Bool = false) throws {
        try write(Data(text.utf8), to: path, executable: executable)
    }

    private func plist(version: String, at path: String) throws {
        try write(PropertyListSerialization.data(
            fromPropertyList: ["CFBundleShortVersionString": version], format: .xml, options: 0), to: path)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("publish-release-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        try git("init", "-q", "--bare", origin.path, in: root)
        try git("init", "-q")
        try git("remote", "add", "origin", origin.path)

        // What is committed: the script under test, a Sparkle locator stub, and the two files the
        // plan names, which a source tarball of this repository must hold.
        try write(String(contentsOf: Self.script, encoding: .utf8), to: "Distribution/publish-release",
                  executable: true)
        let sparkle = root.appendingPathComponent("sparkle")
        try write("#!/bin/bash\necho \(sparkle.path)/bin\n", to: "Distribution/sparkle-bin", executable: true)
        try write("name: Scripta\n", to: "project.yml")
        try write("[project]\nname = \"substrate\"\n", to: "substrate/pyproject.toml")
        try write("build/\ndist/\n", to: ".gitignore")
        try git("add", "-A")
        try git("commit", "-q", "-m", "built")
        built = try git("rev-parse", "HEAD")

        // After the build: a later commit and an uncommitted edit, neither of which was built.
        try write("later\n", to: "LATER.md")
        try git("add", "LATER.md")
        try git("commit", "-q", "-m", "after the build")
        try write("name: edited after the build\n", to: "project.yml")

        // What build-and-notarize leaves behind.
        try plist(version: Self.version, at: "build/Distribution/Scripta.app/Contents/Info.plist")
        try plist(version: "2.0.0",
                  at: "build/Distribution/Scripta.app/Contents/Frameworks/Sparkle.framework/Resources/Info.plist")
        try write("dmg", to: "dist/archive/Scripta-\(Self.version).dmg")
        try write("\(built)\n", to: "dist/commits/Scripta-\(Self.version).commit")
        try write("Notes.\n", to: "dist/release-notes-\(Self.version).md")

        // Sparkle's tools: a matching framework version, and a generate_appcast that reports on
        // stdout as the real one does, writes one signed item under this tag, and a delta.
        try plist(version: "2.0.0", at: sparkle.appendingPathComponent(
            "Sparkle.xcframework/macos-arm64_x86_64/Sparkle.framework/Resources/Info.plist").path)
        let url = "https://github.com/Ronan-Wood/Scripta/releases/download/\(Self.tag)/Scripta-\(Self.version).dmg"
        try write("""
        #!/bin/bash
        while [ $# -gt 0 ]; do [ "$1" = -o ] && out=$2; shift; done
        echo "Wrote 1 new update"
        : > dist/archive/Scripta2-1.2.2.delta
        printf '%s\\n' '<rss xmlns:sparkle="x"><!-- sparkle-signatures: x -->' \\
          '<item><enclosure url="\(url)" sparkle:edSignature="x"/></item></rss>' > "$out"
        """, to: sparkle.appendingPathComponent("bin/generate_appcast").path, executable: true)

        try write("#!/bin/bash\nprintf '%s\\n' \"$@\" > \(ghCalls.path)\n",
                  to: root.appendingPathComponent("stubs/gh").path, executable: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func publish(_ arguments: [String] = []) throws -> Run {
        try sh(["/bin/bash", "Distribution/publish-release"] + arguments,
               path: "\(root.appendingPathComponent("stubs").path):/usr/bin:/bin")
    }

    private var tagExists: Bool {
        get throws { try sh(["/usr/bin/git", "rev-parse", "-q", "--verify", "refs/tags/\(Self.tag)"]).status == 0 }
    }

    private var ghRan: Bool { FileManager.default.fileExists(atPath: ghCalls.path) }

    private var expectedAssets: [String] {
        ["dist/archive/Scripta-\(Self.version).dmg", "dist/appcast.xml", Self.source,
         "dist/archive/Scripta2-1.2.2.delta"]
    }

    /// THE SOURCE IS THE BUILT COMMIT: its files exactly, `project.yml` and
    /// `substrate/pyproject.toml` among them, under `Scripta-<V>/`. So neither the commit after the
    /// build nor the edit in the working tree, and nothing ignored.
    private func assertSourceIsTheBuiltCommit(file: StaticString = #filePath, line: UInt = #line) throws {
        let listing = try sh(["/usr/bin/tar", "-tzf", Self.source])
        XCTAssertEqual(listing.status, 0, listing.err, file: file, line: line)
        let files = listing.out.split(separator: "\n").map(String.init).filter { !$0.hasSuffix("/") }
        let committed = try git("--no-replace-objects", "ls-tree", "-r", "--name-only", built).split(separator: "\n")
            .map { "Scripta-\(Self.version)/\($0)" }
        XCTAssertEqual(files.sorted(), committed.sorted(), file: file, line: line)
        let yml = try sh(["/usr/bin/tar", "-xzOf", Self.source, "Scripta-\(Self.version)/project.yml"])
        XCTAssertEqual(yml.out, "name: Scripta\n", file: file, line: line)
    }

    private func assertReleased(_ run: Run, file: StaticString = #filePath, line: UInt = #line) throws {
        XCTAssertEqual(run.status, 0, run.err, file: file, line: line)
        let gh = try String(contentsOf: ghCalls, encoding: .utf8).split(separator: "\n").map(String.init)
        XCTAssertEqual(Array(gh.prefix(3)), ["release", "create", Self.tag], file: file, line: line)
        XCTAssertEqual(Array(gh.dropFirst(3).prefix(expectedAssets.count)), expectedAssets, file: file, line: line)
        try assertSourceIsTheBuiltCommit(file: file, line: line)
        XCTAssertEqual(try git("rev-list", "-n", "1", Self.tag), built, file: file, line: line)
        XCTAssertEqual(try git("rev-list", "-n", "1", Self.tag, in: origin), built, file: file, line: line)
    }

    func testTheReleaseAttachesTheSourceOfTheBuiltCommit() throws {
        try assertReleased(try publish())
    }

    /// A rerun after the tag was made: the tag is reused, not made again, and the source is the same.
    func testTheReleaseReusesATagOnTheBuiltCommit() throws {
        try git("tag", "-a", Self.tag, built, "-m", "Scripta \(Self.tag)")
        try assertReleased(try publish())
    }

    /// Stdout is the asset list and nothing else, though generate_appcast reports on stdout.
    func testADryRunPrintsTheAssetsAndPublishesNothing() throws {
        let run = try publish(["--dry-run"])
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertEqual(run.out.split(separator: "\n").map(String.init), expectedAssets)
        try assertSourceIsTheBuiltCommit()
        XCTAssertFalse(try tagExists, "a dry run tagged")
        XCTAssertEqual(try git("tag", "-l", in: origin), "", "a dry run pushed a tag")
        XCTAssertFalse(ghRan, "a dry run ran gh")
    }

    /// A dry run refuses a local tag on another commit, as the release does. It does not ask
    /// origin, so a tag only there is found by the release's push.
    func testADryRunRefusesATagOnAnotherCommit() throws {
        try git("tag", "-a", Self.tag, "HEAD", "-m", "elsewhere")
        let run = try publish(["--dry-run"])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.err.contains("already exists on a different commit"), run.err)
        XCTAssertFalse(ghRan)
    }

    /// A mistyped flag is not a release.
    func testAnUnknownArgumentIsRefusedBeforeAnything() throws {
        for arguments in [["--dryrun"], ["--dry-run", "extra"], [""]] {
            let run = try publish(arguments)
            XCTAssertNotEqual(run.status, 0, "\(arguments)")
            XCTAssertTrue(run.err.contains("usage:"), run.err)
            XCTAssertFalse(try tagExists, "\(arguments) tagged")
            XCTAssertFalse(ghRan, "\(arguments) ran gh")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url("dist/appcast.xml").path),
                           "\(arguments) made an appcast")
        }
    }

    /// THE SOURCE IS THE COMMIT, BYTE FOR BYTE: git archive applies attributes and config that are
    /// not the commit's, and each way it can drop or rewrite a file is refused, by the file's name.
    func testAnArchiveThatIsNotTheCommitIsRefused() throws {
        let attributes = root.appendingPathComponent("attributes").path
        let cases: [(String, () throws -> Void)] = [
            ("core.attributesFile export-ignore", {
                try self.write("project.yml export-ignore\n", to: attributes)
                try self.git("config", "core.attributesFile", attributes)
            }),
            ("info/attributes eol=crlf", { try self.write("project.yml text eol=crlf\n", to: ".git/info/attributes") }),
            ("core.autocrlf", { try self.git("config", "core.autocrlf", "true") }),
            ("a smudge filter", {
                try self.write("project.yml filter=rename\n", to: ".git/info/attributes")
                try self.git("config", "filter.rename.smudge", "sed s/Scripta/Other/")
            }),
        ]
        for (name, change) in cases {
            try write("", to: ".git/info/attributes")
            for key in ["core.attributesFile", "core.autocrlf", "filter.rename.smudge"] {
                _ = try sh(["/usr/bin/git", "config", "--unset", key])
            }
            XCTAssertEqual(try publish(["--dry-run"]).status, 0, "before \(name)")
            try change()
            let run = try publish(["--dry-run"])
            XCTAssertNotEqual(run.status, 0, name)
            XCTAssertTrue(run.err.contains("project.yml: commit"), "\(name): \(run.err)")
            XCTAssertTrue(run.err.contains("is not \(built) byte for byte"), "\(name): \(run.err)")
            XCTAssertFalse(FileManager.default.fileExists(atPath: url(Self.source).path),
                           "\(name): a refused tarball has the asset's name")
        }
        XCTAssertFalse(ghRan)
    }

    /// A replace ref makes git read another commit under the built one's id; the source is still
    /// the built commit's.
    func testTheSourceIsTheBuiltCommitUnderAReplaceRef() throws {
        try git("replace", built, try git("rev-parse", "HEAD"))
        let run = try publish(["--dry-run"])
        XCTAssertEqual(run.status, 0, run.err)
        try assertSourceIsTheBuiltCommit()
    }

    /// The commit's own `.gitattributes` is no exception: a file it leaves out is source not shipped.
    func testACommitWhoseOwnAttributesDropAFileIsRefused() throws {
        try write("project.yml export-ignore\n", to: ".gitattributes")
        try git("add", ".gitattributes")
        try git("commit", "-q", "-m", "attributes")
        try write("\(try git("rev-parse", "HEAD"))\n", to: "dist/commits/Scripta-\(Self.version).commit")
        let run = try publish(["--dry-run"])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.err.contains("project.yml: commit"), run.err)
        XCTAssertFalse(FileManager.default.fileExists(atPath: url(Self.source).path),
                       "a refused tarball has the asset's name")
    }

    /// The commit file and the version become `git archive` arguments and the tarball's prefix.
    func testARecordedCommitOrVersionOfTheWrongShapeIsRefused() throws {
        let elsewhere = root.appendingPathComponent("written-by-an-option")
        for recorded in ["HEAD", "--output=\(elsewhere.path)", String(built.prefix(12))] {
            try write("\(recorded)\n", to: "dist/commits/Scripta-\(Self.version).commit")
            let run = try publish(["--dry-run"])
            XCTAssertNotEqual(run.status, 0, recorded)
            XCTAssertTrue(run.err.contains("not a commit's full id"), run.err)
        }
        XCTAssertFalse(FileManager.default.fileExists(atPath: elsewhere.path), "an option reached git")
        try plist(version: "1.2/../../x", at: "build/Distribution/Scripta.app/Contents/Info.plist")
        let run = try publish(["--dry-run"])
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.err.contains("is not dotted numbers"), run.err)
        XCTAssertFalse(ghRan)
    }
}
