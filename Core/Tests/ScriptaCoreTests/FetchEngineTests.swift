import CryptoKit
import Foundation
import XCTest

/// `Distribution/fetch-engine`, run for real in a throwaway repository against a tarball `git
/// archive` made from a throwaway engine: the lock is the trust, so each way a lock, a download or
/// a release can disagree with it must be refused before anything is unpacked. `gh` and `curl` are
/// stubs and the tarball is already in `vendor/`, so nothing leaves the machine.
final class FetchEngineTests: XCTestCase {
    /// `#filePath`, not the working directory: `swift test` and Xcode disagree about cwd.
    private static let distribution = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ScriptaCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Core
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("Distribution")

    private static let repoName = "Ronan-Wood/substrate"
    private static let tag = "v9.8.7"
    private static let version = "9.8.7"
    private static let tarball = "substrate-9.8.7.tar.gz"

    private var root: URL!
    private var repo: URL { root.appendingPathComponent("repo") }
    private var engine: URL { root.appendingPathComponent("engine") }
    private var stubs: URL { root.appendingPathComponent("stubs") }
    /// What the stub `curl` serves, by file name, and what the stub `gh` answers, by request.
    private var served: URL { root.appendingPathComponent("served") }
    private var answers: URL { root.appendingPathComponent("gh-answers") }
    private var commit = ""
    private var sha = ""

    private typealias Run = (status: Int32, out: String, err: String)

    @discardableResult
    private func sh(_ arguments: [String], in directory: URL? = nil) throws -> Run {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: arguments[0])
        process.arguments = Array(arguments.dropFirst())
        process.currentDirectoryURL = directory ?? repo
        process.environment = [
            "PATH": "\(stubs.path):/usr/bin:/bin", "HOME": root.path, "GIT_CONFIG_GLOBAL": "/dev/null",
            "GIT_CONFIG_NOSYSTEM": "1", "GIT_AUTHOR_NAME": "Test", "GIT_AUTHOR_EMAIL": "test@example.invalid",
            "GIT_COMMITTER_NAME": "Test", "GIT_COMMITTER_EMAIL": "test@example.invalid",
            "GH_ANSWERS": answers.path, "SERVED": served.path,
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
    private func git(_ arguments: String..., in directory: URL) throws -> String {
        let run = try sh(["/usr/bin/git"] + arguments, in: directory)
        XCTAssertEqual(run.status, 0, "git \(arguments.joined(separator: " ")): \(run.err)")
        return run.out.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private func write(_ text: String, to url: URL, executable: Bool = false) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data(text.utf8).write(to: url)
        if executable {
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        }
    }

    private static func sha256(_ url: URL) throws -> String {
        SHA256.hash(data: try Data(contentsOf: url)).map { String(format: "%02x", $0) }.joined()
    }

    private static let contract = #"{"wire": {"version": 2, "min_version": 1}, "socket": {"default": "~/.substrate/run/substrate.sock"}}"#
    private static let frame = #"{"result": {"registry": "/demo-substrate/scopes.toml"}}"#

    /// A throwaway engine at one commit, archived as its release would be and served under
    /// `tarball`, with GitHub's answers for its tag, signed tag object, tree and release. `frame`
    /// is one frame's body; `prefix` the folder the archive puts it under.
    @discardableResult
    private func release(tag: String = tag, tarball: String = tarball, frame: String = frame,
                         contract: String = contract, prefix: String = "substrate-9.8.7/") throws -> URL {
        try? FileManager.default.removeItem(at: engine)
        try FileManager.default.createDirectory(at: engine, withIntermediateDirectories: true)
        try git("init", "-q", in: engine)
        try write("#!/bin/bash\necho built\n", to: engine.appendingPathComponent("tools/build-bundled-engine"),
                  executable: true)
        try write("[project]\nname = \"substrate\"\n", to: engine.appendingPathComponent("pyproject.toml"))
        try write("version = 1\n", to: engine.appendingPathComponent("uv.lock"))
        try write("print('engine')\n", to: engine.appendingPathComponent("substrate/cli.py"))
        try write(contract, to: engine.appendingPathComponent("contract/contract.json"))
        try write(frame, to: engine.appendingPathComponent("contract/frames/list_scopes.frame.json"))
        try git("add", "-A", in: engine)
        try git("commit", "-q", "-m", "release", in: engine)
        commit = try git("rev-parse", "HEAD", in: engine)
        let out = served.appendingPathComponent(tarball)
        try FileManager.default.createDirectory(at: served, withIntermediateDirectories: true)
        try? FileManager.default.removeItem(at: out)
        try git("archive", "--format=tar.gz", "--prefix=\(prefix)", "-o", out.path, "HEAD", in: engine)
        sha = try Self.sha256(out)
        try write("\(sha)  \(tarball)\n", to: served.appendingPathComponent("SHA256SUMS"))
        try say(tagRef(tag), "tag \(String(repeating: "a", count: 40))")
        try say(tagObject, "commit \(commit) true")
        try say(treePath, try tree())
        try say("release \(tag)", "true")
        return out
    }

    private func tagRef(_ tag: String = tag) -> String { "repos/\(Self.repoName)/git/ref/tags/\(tag)" }
    private var tagObject: String { "repos/\(Self.repoName)/git/tags/\(String(repeating: "a", count: 40))" }
    private var treePath: String { "repos/\(Self.repoName)/git/trees/\(commit)?recursive=1" }

    /// GitHub's recursive tree of the engine's HEAD, as the trees API returns it.
    private func tree(truncated: Bool = false) throws -> String {
        let entries = try git("ls-tree", "-r", "--full-tree", "HEAD", in: engine).split(separator: "\n").map {
            line -> [String: String] in
            let (meta, path) = (line.split(separator: "\t")[0], line.split(separator: "\t")[1])
            let parts = meta.split(separator: " ").map(String.init)
            return ["mode": parts[0], "type": parts[1], "sha": parts[2], "path": String(path)]
        }
        return String(decoding: try JSONSerialization.data(withJSONObject: [
            "sha": "tree", "truncated": truncated, "tree": entries]), as: UTF8.self)
    }

    /// The stub `gh`'s answer to `key` (`gh api <path>`, or `release <tag>` for `gh release view`).
    private func say(_ key: String, _ text: String) throws {
        let name = key.replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "?", with: "_")
            .replacingOccurrences(of: "=", with: "_")
        try write(text + "\n", to: answers.appendingPathComponent(name))
    }

    private func lock(tag: String = tag, commit: String? = nil, tarball: String = tarball,
                      sha256: String? = nil, wire: String = "1", repo: String = repoName) -> String {
        "# the pin\nrepo=\(repo)\ntag=\(tag)\ncommit=\(commit ?? self.commit)\ntarball=\(tarball)\n"
            + "sha256=\(sha256 ?? sha)\nwire=\(wire)\n"
    }

    /// The release in `vendor/`, as an earlier run would have left it.
    private func cache(_ release: URL) throws {
        let vendor = repo.appendingPathComponent("vendor")
        try FileManager.default.createDirectory(at: vendor, withIntermediateDirectories: true)
        let cached = vendor.appendingPathComponent(release.lastPathComponent)
        try? FileManager.default.removeItem(at: cached)
        try FileManager.default.copyItem(at: release, to: cached)
    }

    /// The served tarball again, with one more file member, its header's commit kept: what a hand
    /// could build that `git archive` never would.
    private func adding(_ name: String, _ text: String, to tarball: URL) throws {
        let run = try sh(["/usr/bin/python3", "-I", "-c", """
        import io, sys, tarfile
        path, name, text = sys.argv[1:]
        src = tarfile.open(path, "r:gz")
        members = [(m, src.extractfile(m).read() if m.isfile() else None) for m in src.getmembers()]
        out = tarfile.open(path, "w:gz", format=tarfile.PAX_FORMAT, pax_headers=src.pax_headers)
        for m, data in members:
            out.addfile(m, io.BytesIO(data) if data is not None else None)
        extra = tarfile.TarInfo(name)
        extra.size = len(text.encode())
        out.addfile(extra, io.BytesIO(text.encode()))
        out.close()
        """, tarball.path, name, text])
        XCTAssertEqual(run.status, 0, run.err)
        sha = try Self.sha256(tarball)
    }

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("fetch-engine-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: repo, withIntermediateDirectories: true)
        for script in ["fetch-engine", "engine-contract"] {
            try write(String(contentsOf: Self.distribution.appendingPathComponent(script), encoding: .utf8),
                      to: repo.appendingPathComponent("Distribution/\(script)"), executable: true)
        }
        try git("init", "-q", in: repo)
        try cache(try release())
        try write(lock(), to: repo.appendingPathComponent("engine.lock"))
        // The app's copy of the contract, as the release has it.
        try write(Self.contract, to: repo.appendingPathComponent("Core/Tests/EngineContract/contract.json"))
        try write(Self.frame, to: repo.appendingPathComponent("Core/Tests/EngineContract/frames/list_scopes.frame.json"))

        // `gh api <path> [--jq …]` and `gh release view <tag> …`: the answer filed for that request,
        // or a failure as a 404 would be. The `--jq` is not run; each answer is what it would print.
        try write("""
        #!/bin/bash
        case $1 in api) key=$2 ;; release) key="release $3" ;; *) exit 64 ;; esac
        file="$GH_ANSWERS/$(printf '%s' "$key" | tr '/?=' '___')"
        [ -f "$file" ] || { echo "gh: HTTP 404 $key" >&2; exit 1; }
        cat "$file"
        """, to: stubs.appendingPathComponent("gh"), executable: true)
        // `curl … -o FILE -- URL`: the served file named by the URL's last word, or a failure.
        try write("""
        #!/bin/bash
        while [ $# -gt 0 ]; do case $1 in -o) out=$2; shift ;; --) url=$2; shift ;; esac; shift; done
        [ -f "$SERVED/${url##*/}" ] || { echo "curl: (22) 404 $url" >&2; exit 22; }
        cp "$SERVED/${url##*/}" "$out"
        """, to: stubs.appendingPathComponent("curl"), executable: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private func fetch(_ arguments: [String] = []) throws -> Run {
        try sh(["/bin/bash", "Distribution/fetch-engine"] + arguments)
    }

    private var unpacked: URL { repo.appendingPathComponent("vendor/substrate-\(Self.version)") }
    private var link: URL { repo.appendingPathComponent("vendor/substrate") }
    private var linked: Bool { FileManager.default.fileExists(atPath: link.path) }

    /// Every file under `url`, relative, with its executable bit.
    private func files(_ url: URL) throws -> [String] {
        let all = try sh(["/usr/bin/find", ".", "-type", "f"], in: url).out.split(separator: "\n")
        let exec = Set(try sh(["/usr/bin/find", ".", "-type", "f", "-perm", "-u+x"], in: url).out.split(separator: "\n"))
        return all.map { "\($0)\(exec.contains($0) ? " +x" : "")" }.sorted()
    }

    func testThePinnedReleaseIsUnpackedStampedAndLinked() throws {
        let run = try fetch()
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertEqual(try files(unpacked), [
            "./.engine.lock", "./contract/contract.json", "./contract/frames/list_scopes.frame.json",
            "./pyproject.toml", "./substrate/cli.py", "./tools/build-bundled-engine +x", "./uv.lock",
        ])
        XCTAssertEqual(try Data(contentsOf: unpacked.appendingPathComponent(".engine.lock")),
                       try Data(contentsOf: repo.appendingPathComponent("engine.lock")))
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path),
                       "substrate-\(Self.version)")
        XCTAssertTrue(run.out.contains("serving wire 1 to 2, this app's 1"), run.out)
        XCTAssertEqual(try sh(["/usr/bin/find", "vendor", "-maxdepth", "1", "-name", ".*"]).out, "",
                       "a stage was left in vendor/")
    }

    /// A rerun unpacks afresh, so an edit to the unpacked tree never reaches a build.
    func testARerunReplacesAnEditedTree() throws {
        XCTAssertEqual(try fetch().status, 0)
        try write("edited\n", to: unpacked.appendingPathComponent("uv.lock"))
        try write("planted\n", to: unpacked.appendingPathComponent("tools/extra"))
        XCTAssertEqual(try fetch(["--offline"]).status, 0)
        XCTAssertEqual(try String(contentsOf: unpacked.appendingPathComponent("uv.lock"), encoding: .utf8),
                       "version = 1\n")
        XCTAssertFalse(FileManager.default.fileExists(atPath: unpacked.appendingPathComponent("tools/extra").path))
    }

    /// Nothing reaches `vendor/substrate` when the lock is not exactly the six keys, each well formed.
    func testALockThatIsNotExactlyItsKeysIsRefused() throws {
        let good = lock()
        let cases: [(String, String, String)] = [
            ("missing", good.replacingOccurrences(of: "wire=1\n", with: ""), "no 'wire'"),
            ("twice", good + "tag=v9.8.8\n", "'tag' given twice"),
            ("unknown", good + "mirror=elsewhere\n", "unknown key 'mirror'"),
            ("not key=value", good + "just words\n", "not key=value"),
            ("another repo", lock(repo: "someone/substrate"), "is not Ronan-Wood/substrate"),
            ("short commit", lock(commit: String(commit.prefix(12))), "is not a full commit id"),
            ("sha shape", lock(sha256: "--output=/tmp/x"), "is not 64 hex digits"),
            ("tarball", lock(tarball: "../substrate-9.8.7.tar.gz"), "run Distribution/fetch-engine --bump v9.8.7"),
            ("tag", lock(tag: "v9.8.7;rm"), "is not vX.Y.Z"),
            ("pre-release form", lock(tag: "v9.8.7-beta", tarball: "substrate-9.8.7-beta.tar.gz"), "is not vX.Y.Z"),
            ("wire", lock(wire: "0"), "is not a wire version"),
            ("crlf", good.replacingOccurrences(of: "\n", with: "\r\n"), "engine.lock"),
        ]
        for (name, text, why) in cases {
            try write(text, to: repo.appendingPathComponent("engine.lock"))
            let run = try fetch()
            XCTAssertEqual(run.status, 2, "\(name): \(run.err)")
            XCTAssertTrue(run.err.contains(why), "\(name): \(run.err)")
            XCTAssertFalse(linked, "\(name): unpacked")
        }
    }

    /// THE LOCK IS THE TRUST: a tarball that is not its bytes, or not its commit's archive, or that
    /// carries anything but files and folders under its own prefix, each written to a place of its
    /// own on a case-insensitive disk, is refused before unpacking.
    func testATarballTheLockDoesNotDescribeIsRefused() throws {
        let served = self.served.appendingPathComponent(Self.tarball)
        let cases: [(String, () throws -> Void, String)] = [
            ("other bytes", {
                try self.write("not the release", to: self.repo.appendingPathComponent("vendor/\(Self.tarball)"))
            }, "is not the pinned tarball"),
            ("other commit", {
                try self.write(self.lock(commit: String(repeating: "b", count: 40)),
                               to: self.repo.appendingPathComponent("engine.lock"))
            }, "was archived from commit"),
            ("other prefix", {
                try self.cache(try self.release(prefix: "elsewhere/"))
                try self.write(self.lock(), to: self.repo.appendingPathComponent("engine.lock"))
            }, "is not under substrate-9.8.7/"),
            ("one file twice by case", {
                try self.adding("substrate-9.8.7/Contract/frames/list_scopes.frame.json",
                                #"{"db": "/Users/someone/x.db"}"#, to: served)
                try self.cache(served)
                try self.write(self.lock(), to: self.repo.appendingPathComponent("engine.lock"))
            }, "spells 'substrate-9.8.7/contract' another way"),
            ("a folder by another spelling", {
                try self.adding("substrate-9.8.7/Substrate/extra.py", "print('x')\n", to: served)
                try self.cache(served)
                try self.write(self.lock(), to: self.repo.appendingPathComponent("engine.lock"))
            }, "spells 'substrate-9.8.7/substrate' another way"),
            ("contract by another spelling", {
                try self.adding("substrate-9.8.7/CONTRACT/notes.json", #"{"db": "/Users/someone/x.db"}"#, to: served)
                try self.cache(served)
                try self.write(self.lock(), to: self.repo.appendingPathComponent("engine.lock"))
            }, "spells 'substrate-9.8.7/contract' another way"),
        ]
        for (name, change, why) in cases {
            try cache(try release())
            try write(lock(), to: repo.appendingPathComponent("engine.lock"))
            try change()
            let run = try fetch()
            XCTAssertEqual(run.status, 2, "\(name): \(run.err)")
            XCTAssertTrue(run.err.contains(why), "\(name): \(run.err)")
            XCTAssertFalse(linked, "\(name): unpacked")
        }
    }

    /// The contract is vendored into this public repository, so it is scanned as the engine's own
    /// suite scans it: no host string, and no path but the stand-ins, in any JSON string, nested
    /// JSON included. And it must serve the wire this app speaks.
    func testAContractThatLeaksOrDoesNotServeThisAppIsRefused() throws {
        let cases: [(String, String, String, String)] = [
            ("home", #"{"db": "/Users/someone/x.db"}"#, Self.contract, "/Users/"),
            ("other path", #"{"text": "wrote /srv/data/index"}"#, Self.contract, "/srv/data/index"),
            ("nested", #"{"text": "{\"db\": \"/opt/x\"}"}"#, Self.contract, "/opt/x"),
            ("traversal", #"{"db": "/demo-substrate/../etc"}"#, Self.contract, "/demo-substrate/../etc"),
            ("range above", Self.frame, #"{"wire": {"version": 3, "min_version": 2}}"#, "serves wire 2 to 3"),
        ]
        for (name, frame, contract, why) in cases {
            try cache(try release(frame: frame, contract: contract))
            try write(lock(), to: repo.appendingPathComponent("engine.lock"))
            let run = try fetch()
            XCTAssertEqual(run.status, 2, "\(name): \(run.err)")
            XCTAssertTrue(run.err.contains(why), "\(name): \(run.err)")
            XCTAssertFalse(linked, "\(name): unpacked")
        }
    }

    /// With nothing in `vendor/`, the release is downloaded, and kept only if it is the lock's bytes.
    /// `--offline`, which the Xcode phase passes, never downloads.
    func testADownloadIsKeptOnlyWhenItIsTheLocksBytes() throws {
        try FileManager.default.removeItem(at: repo.appendingPathComponent("vendor/\(Self.tarball)"))
        let offline = try fetch(["--offline"])
        XCTAssertEqual(offline.status, 1, offline.err)
        XCTAssertTrue(offline.err.contains("--offline does not download"), offline.err)
        XCTAssertFalse(offline.err.contains("downloading"), offline.err)

        XCTAssertEqual(try fetch().status, 0)
        XCTAssertEqual(try Self.sha256(repo.appendingPathComponent("vendor/\(Self.tarball)")), sha)

        try FileManager.default.removeItem(at: repo.appendingPathComponent("vendor"))
        try write("replaced on the server", to: served.appendingPathComponent(Self.tarball))
        let run = try fetch()
        XCTAssertEqual(run.status, 1, run.err)
        XCTAssertTrue(run.err.contains("Refusing it"), run.err)
        XCTAssertEqual(try sh(["/usr/bin/find", "vendor", "-type", "f"]).out, "", "a refused download was kept")
    }

    /// `--release`, which build-and-notarize and a Distribution build pass, refuses a pre-release
    /// pin; it is for a draft pull request. The engine names an rc's files `X.Y.ZrcN`.
    func testAReleaseRefusesAPreReleasePin() throws {
        let rc = try release(tag: "v9.9.0-rc.1", tarball: "substrate-9.9.0rc1.tar.gz", prefix: "substrate-9.9.0rc1/")
        try cache(rc)
        try write(lock(tag: "v9.9.0-rc.1", tarball: "substrate-9.9.0rc1.tar.gz"),
                  to: repo.appendingPathComponent("engine.lock"))
        let refused = try fetch(["--offline", "--release"])
        XCTAssertEqual(refused.status, 1, refused.err)
        XCTAssertTrue(refused.err.contains("pins the pre-release v9.9.0-rc.1"), refused.err)
        XCTAssertFalse(linked)
        let draft = try fetch(["--offline"])
        XCTAssertEqual(draft.status, 0, draft.err)
        XCTAssertEqual(try FileManager.default.destinationOfSymbolicLink(atPath: link.path), "substrate-9.9.0rc1")
    }

    /// `vendor/substrate` is this script's link; a real folder there is someone else's, and stays.
    func testAFolderWhereTheLinkGoesIsRefused() throws {
        try write("mine\n", to: link.appendingPathComponent("notes.txt"))
        let run = try fetch()
        XCTAssertEqual(run.status, 2, run.err)
        XCTAssertTrue(run.err.contains("is not a symlink"), run.err)
        XCTAssertTrue(FileManager.default.fileExists(atPath: link.appendingPathComponent("notes.txt").path))
    }

    /// `engine pin`: the tag must name the lock's commit, signed and verified; every file the
    /// tarball holds must be that commit's, which is the one thing tying its bytes to the signed
    /// tag; and the app's copy of the contract must be the release's.
    func testTheCheckHoldsTheTagTheTreeAndTheContractCopyToTheLock() throws {
        let passed = try fetch(["--check"])
        XCTAssertEqual(passed.status, 0, passed.err)
        XCTAssertTrue(passed.out.contains("agree on \(Self.tag)"), passed.out)

        try say(tagObject, "commit \(commit) false")
        XCTAssertEqual(try fetch(["--check"]).status, 1, "an unverified tag passed")
        try say(tagObject, "commit \(String(repeating: "c", count: 40)) true")
        XCTAssertEqual(try fetch(["--check"]).status, 1, "a tag on another commit passed")
        try say(tagRef(), "commit \(commit)")
        let lightweight = try fetch(["--check"])
        XCTAssertEqual(lightweight.status, 1, lightweight.err)
        XCTAssertTrue(lightweight.err.contains("is not an annotated tag"), lightweight.err)
        try say(tagRef(), "tag \(String(repeating: "a", count: 40))")
        try say(tagObject, "commit \(commit) true")

        // The commit's tree with one file's content changed, then GitHub's answer truncated.
        let real = try tree()
        try say(treePath, real.replacingOccurrences(of: try git("rev-parse", "HEAD:uv.lock", in: engine),
                                                    with: String(repeating: "d", count: 40)))
        let other = try fetch(["--check"])
        XCTAssertEqual(other.status, 2, other.err)
        XCTAssertTrue(other.err.contains("is not commit \(commit)'s tree: 1 files differ, first uv.lock"), other.err)
        try say(treePath, try tree(truncated: true))
        let truncated = try fetch(["--check"])
        XCTAssertEqual(truncated.status, 2, truncated.err)
        XCTAssertTrue(truncated.err.contains("is truncated"), truncated.err)
        try say(treePath, real)

        try write(#"{"result": {}}"#, to: repo.appendingPathComponent("Core/Tests/EngineContract/frames/list_scopes.frame.json"))
        let stale = try fetch(["--check"])
        XCTAssertEqual(stale.status, 1, stale.err)
        XCTAssertTrue(stale.err.contains("is not a copy of"), stale.err)
    }

    /// `--bump`: the lock is rewritten from GitHub's tag and the release's own `SHA256SUMS`, its
    /// comments and the app's wire kept, the tarball held to the commit's tree, and the contract
    /// copy re-vendored from the release. A release that is not immutable is refused.
    func testABumpRewritesTheLockAndRevendorsTheContract() throws {
        try FileManager.default.removeItem(at: repo.appendingPathComponent("vendor"))
        try write(lock(commit: String(repeating: "0", count: 40), sha256: String(repeating: "0", count: 64)),
                  to: repo.appendingPathComponent("engine.lock"))
        try write(#"{"old": true}"#, to: repo.appendingPathComponent("Core/Tests/EngineContract/frames/list_scopes.frame.json"))
        let run = try fetch(["--bump", Self.tag])
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("engine.lock"), encoding: .utf8), lock())
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("Core/Tests/EngineContract/frames/list_scopes.frame.json"),
                                  encoding: .utf8), Self.frame)
        XCTAssertEqual(try fetch(["--check"]).status, 0)

        try say("release \(Self.tag)", "false")
        let mutable = try fetch(["--bump", Self.tag])
        XCTAssertEqual(mutable.status, 1, mutable.err)
        XCTAssertTrue(mutable.err.contains("is not immutable"), mutable.err)
        try say("release \(Self.tag)", "true")

        try write("\(String(repeating: "f", count: 64))  \(Self.tarball)\n", to: served.appendingPathComponent("SHA256SUMS"))
        let mismatched = try fetch(["--bump", Self.tag])
        XCTAssertEqual(mismatched.status, 1, mismatched.err)
        XCTAssertTrue(mismatched.err.contains("SHA256SUMS lists"), mismatched.err)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("engine.lock"), encoding: .utf8), lock(),
                       "a refused bump rewrote the lock")
    }

    /// THE LOCK MOVES LAST. A bump that fails after the download, here because the contract copy is
    /// not one `engine-contract sync` will replace, leaves the lock describing the copy it had.
    func testABumpThatFailsLateLeavesTheLock() throws {
        let old = lock(commit: String(repeating: "0", count: 40), sha256: String(repeating: "0", count: 64))
        try write(old, to: repo.appendingPathComponent("engine.lock"))
        try write("not a contract file\n", to: repo.appendingPathComponent("Core/Tests/EngineContract/notes.txt"))
        let run = try fetch(["--bump", Self.tag])
        XCTAssertEqual(run.status, 2, run.err)
        XCTAssertTrue(run.err.contains("holds entries other than"), run.err)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("engine.lock"), encoding: .utf8), old)
        XCTAssertEqual(try sh(["/usr/bin/find", "vendor", "-maxdepth", "1", "-name", ".*"]).out, "",
                       "a failed bump left its work in vendor/")
    }

    /// An rc tag's files are named as the engine names them, `X.Y.ZrcN`.
    func testABumpToAReleaseCandidateUsesTheEnginesName() throws {
        try release(tag: "v9.9.0-rc.1", tarball: "substrate-9.9.0rc1.tar.gz", prefix: "substrate-9.9.0rc1/")
        let run = try fetch(["--bump", "v9.9.0-rc.1"])
        XCTAssertEqual(run.status, 0, run.err)
        XCTAssertEqual(try String(contentsOf: repo.appendingPathComponent("engine.lock"), encoding: .utf8),
                       lock(tag: "v9.9.0-rc.1", tarball: "substrate-9.9.0rc1.tar.gz"))
    }

    func testAnUnknownArgumentIsRefused() throws {
        for arguments in [["--chek"], ["--bump"], ["--bump", "9.8.7"], ["--check", "extra"],
                          ["--offline", "--check"], ["--bump", "v9.8.7-beta"]] {
            let run = try fetch(arguments)
            XCTAssertEqual(run.status, 2, "\(arguments): \(run.err)")
            XCTAssertFalse(linked, "\(arguments) unpacked")
        }
    }
}
