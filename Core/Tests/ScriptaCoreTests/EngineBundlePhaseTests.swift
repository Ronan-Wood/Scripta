import Foundation
import XCTest

/// The Xcode phase that bundles the engine, run from `project.yml` itself with a stub in place of
/// `build-bundled-engine`: which checkout's engine it builds, and that a shipping build refuses
/// `SUBSTRATE_ENGINE_SRC`. The app target has no test target, so the script is read out of the
/// project file rather than copied: a copy would pass while the phase changed.
final class EngineBundlePhaseTests: XCTestCase {
    /// `#filePath`, not the working directory: `swift test` and Xcode disagree about cwd.
    private static let project = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ScriptaCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Core
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("project.yml")

    private var root: URL!

    override func setUpWithError() throws {
        root = FileManager.default.temporaryDirectory
            .appendingPathComponent("engine-phase-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
    }

    override func tearDownWithError() throws {
        try FileManager.default.removeItem(at: root)
    }

    private static func indent(_ line: Substring) -> Int { line.prefix { $0 == " " }.count }

    /// The `script: |` block of the phase named `name`, dedented: the lines after it that are
    /// indented past the `script:` key. A shape this does not expect fails rather than handing back
    /// another phase's script or part of this one.
    private static func phaseScript(named name: String) throws -> String {
        let lines = try String(contentsOf: project, encoding: .utf8)
            .split(separator: "\n", omittingEmptySubsequences: false)
        func trimmed(_ line: Substring) -> String { line.trimmingCharacters(in: .whitespaces) }
        let phase = try XCTUnwrap(lines.firstIndex { trimmed($0) == "- name: \(name)" },
                                  "project.yml has no phase named \(name)")
        let key = try XCTUnwrap(lines[phase...].firstIndex { trimmed($0) == "script: |" },
                                "the phase \(name) has no `script: |`")
        XCTAssertFalse(lines[(phase + 1)..<key].contains { trimmed($0).hasPrefix("- name:") },
                       "the first `script: |` after \(name) belongs to another phase")
        var body: [Substring] = []
        for line in lines[(key + 1)...] {
            if line.trimmingCharacters(in: .whitespaces).isEmpty { body.append(""); continue }
            if indent(line) <= indent(lines[key]) { break }
            body.append(line)
        }
        let margin = body.filter { !$0.isEmpty }.map(indent).min() ?? 0
        let script = body.map { $0.isEmpty ? "" : String($0.dropFirst(margin)) }.joined(separator: "\n")
        let last = script.split(separator: "\n").last { !$0.trimmingCharacters(in: .whitespaces).isEmpty }
        XCTAssertTrue(script.hasPrefix("set -euo pipefail\n"), "the phase's script was not found whole")
        XCTAssertTrue(last?.contains("/tools/build-bundled-engine\" \"${ARGS[@]}\"") ?? false,
                      "the phase's script does not end by running the engine build")
        return script
    }

    /// A `build-bundled-engine` that records where it ran from and what it was handed.
    private func engine(at checkout: String) throws -> URL {
        let tool = root.appendingPathComponent(checkout).appendingPathComponent("tools/build-bundled-engine")
        try FileManager.default.createDirectory(at: tool.deletingLastPathComponent(),
                                                withIntermediateDirectories: true)
        try Data("""
        #!/bin/bash
        printf '%s\\n' "$0" "$@" "require=${SUBSTRATE_REQUIRE_SIGNING:-}" > "$CALLS"
        """.utf8).write(to: tool)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: tool.path)
        return tool
    }

    private struct Run {
        let status: Int32
        let stderr: String
        /// What the stub recorded: its own path, its arguments, then `require=…`. Nil if no stub ran.
        let calls: [String]?
    }

    private func run(_ configuration: String, override: String? = nil,
                     identity: String? = nil) throws -> Run {
        let calls = root.appendingPathComponent("calls")
        try? FileManager.default.removeItem(at: calls)
        var env = ["PATH": "/usr/bin:/bin", "CONFIGURATION": configuration, "CALLS": calls.path,
                   "SRCROOT": root.appendingPathComponent("src").path,
                   "CODESIGNING_FOLDER_PATH": root.appendingPathComponent("Scripta.app").path]
        env["SUBSTRATE_ENGINE_SRC"] = override
        env["EXPANDED_CODE_SIGN_IDENTITY"] = identity
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = ["-c", try Self.phaseScript(named: "Bundle the substrate engine (Doc 5)")]
        process.environment = env
        let err = Pipe()
        process.standardError = err
        process.standardOutput = FileHandle.nullDevice
        try process.run()
        let stderr = String(decoding: err.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
        process.waitUntilExit()
        let recorded = try? String(contentsOf: calls, encoding: .utf8)
        return Run(status: process.terminationStatus, stderr: stderr,
                   calls: recorded.map { $0.split(separator: "\n").map(String.init) })
    }

    private var destination: String {
        root.appendingPathComponent("Scripta.app/Contents/Resources/substrate-engine").path
    }

    func testADebugBuildBundlesThisCheckoutsEngine() throws {
        let own = try engine(at: "src/substrate")
        let run = try run("Debug")
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertEqual(run.calls, [own.path, destination, "require="])
    }

    /// THE OVERRIDE: another checkout's engine, and this one's is not run.
    func testADebugBuildBundlesTheCheckoutTheVariableNames() throws {
        _ = try engine(at: "src/substrate")
        let other = try engine(at: "engine-checkout")
        let run = try run("Debug", override: other.deletingLastPathComponent()
            .deletingLastPathComponent().path)
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertEqual(run.calls, [other.path, destination, "require="])
    }

    func testAnEmptyVariableIsNoOverride() throws {
        let own = try engine(at: "src/substrate")
        let run = try run("Debug", override: "")
        XCTAssertEqual(run.calls?.first, own.path)
    }

    /// Every configuration but Debug bundles this checkout's own engine, and says why it refuses
    /// rather than building something else or ignoring it: Distribution is the release, Release
    /// signs with the team's identity, and one added later is refused without being named.
    func testEveryConfigurationButDebugRefusesTheVariableByName() throws {
        _ = try engine(at: "src/substrate")
        let other = try engine(at: "engine-checkout")
        for configuration in ["Distribution", "Release", "Staging"] {
            let run = try run(configuration, override: other.deletingLastPathComponent()
                .deletingLastPathComponent().path, identity: "Developer ID Application: Test")
            XCTAssertNotEqual(run.status, 0, configuration)
            XCTAssertTrue(run.stderr.contains("SUBSTRATE_ENGINE_SRC is set"), run.stderr)
            XCTAssertNil(run.calls, "an engine build ran under a refused override in \(configuration)")
        }
    }

    /// The natural mistake is a checkout's root rather than its `substrate/`, which has no
    /// `tools/`; bash would only say "No such file or directory".
    func testAPathThatIsNotAnEngineRootIsRefusedByName() throws {
        _ = try engine(at: "src/substrate")
        _ = try engine(at: "checkout/substrate")
        let run = try run("Debug", override: root.appendingPathComponent("checkout").path)
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.stderr.contains("is not an engine root"), run.stderr)
        XCTAssertNil(run.calls)
    }

    /// Relative to the phase's working directory, which is not the shell it was typed in.
    func testARelativePathIsRefused() throws {
        _ = try engine(at: "src/substrate")
        let run = try run("Debug", override: "checkout/substrate")
        XCTAssertNotEqual(run.status, 0)
        XCTAssertTrue(run.stderr.contains("not an absolute path"), run.stderr)
        XCTAssertNil(run.calls)
    }

    func testADistributionBuildWithoutItSignsTimestampsAndRequiresSigning() throws {
        let own = try engine(at: "src/substrate")
        let run = try run("Distribution", identity: "Developer ID Application: Test")
        XCTAssertEqual(run.status, 0, run.stderr)
        XCTAssertEqual(run.calls, [own.path, destination, "--sign", "Developer ID Application: Test",
                                   "--timestamp", "require=1"])
    }
}
