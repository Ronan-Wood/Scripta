import Foundation
import XCTest

/// Settings copy never recommends a model by tag. The Local Model footer told users to
/// `ollama pull qwen2.5:14b` or `qwen2.5:7b` long after qwen2.5 left the setup it described; Auto
/// (`ModelResolver.best`) picks from whatever the server has, so a named tag in the copy only goes
/// stale. Read from the app's source because the app target has no test target — the same
/// arrangement, and the same cost, as `ThemeTokenSource` (it couples to the file, not a symbol).
final class SettingsCopyTests: XCTestCase {
    /// A string literal on one line. Copy, not commentary: whole-line `//` comments are skipped,
    /// since a comment may cite the model a number was measured on.
    private let literal = try! NSRegularExpression(pattern: #""(?:[^"\\\n]|\\.)*""#)

    /// An Ollama tag with a size (`qwen2.5:14b`, `qwen3.5:4b-mlx`, `gemma3n:e4b`, `x:0.6b`) or
    /// `:latest`, or a pull command that names its model.
    private let pinned = try! NSRegularExpression(
        pattern: #"[A-Za-z][\w./-]*:(?:latest|[\w.-]*\d[bB])\b|ollama pull [A-Za-z0-9]"#)

    func testSettingsCopyNamesNoModelTag() throws {
        let files = try settingsSources()
        // A moved folder must fail loudly, not pass by scanning nothing.
        XCTAssertTrue(files.contains { $0.lastPathComponent == "SettingsView.swift" }, "\(files)")
        for file in files {
            let text = try String(contentsOf: file, encoding: .utf8)
            // The scan reads one-line literals only; a multi-line one would pass unread.
            XCTAssertFalse(text.contains("\"\"\""), "\(file.lastPathComponent) has a multi-line literal the scan cannot read")
            XCTAssertEqual(pinnedTags(in: text), [], "\(file.lastPathComponent) names a model tag; describe Auto instead")
        }
    }

    /// The scan itself: what it must catch and what it must leave alone.
    func testThePatternCatchesTagsInCopyOnly() {
        XCTAssertEqual(pinnedTags(in: #"Text("then e.g. `ollama pull qwen2.5:14b` or `qwen2.5:7b`")"#).count, 3)
        XCTAssertFalse(pinnedTags(in: #"Text("try gemma3n:e4b")"#).isEmpty)
        XCTAssertFalse(pinnedTags(in: #"Text("or llama3:latest")"#).isEmpty)
        // A quote inside an interpolation splits the literal, but the copy after it is still read.
        XCTAssertFalse(pinnedTags(in: #"Text("\(x ?? "y") or qwen2.5:7b")"#).isEmpty)
        XCTAssertEqual(pinnedTags(in: #"Text("then `ollama pull` any chat model")"#), [])
        XCTAssertEqual(pinnedTags(in: #"TextField("http://localhost:11434/v1", text: $url)"#), [])
        XCTAssertEqual(pinnedTags(in: "// measured on \"qwen3.5:4b-mlx\"\nlet x = 1"), [])
        XCTAssertEqual(pinnedTags(in: #"Text("mask:0b1")"#), [])
    }

    private func pinnedTags(in source: String) -> [String] {
        let code = source.split(separator: "\n", omittingEmptySubsequences: false)
            .filter { !$0.trimmingCharacters(in: .whitespaces).hasPrefix("//") }
            .joined(separator: "\n")
        return strings(literal, in: code).flatMap { strings(pinned, in: $0) }
    }

    private func strings(_ regex: NSRegularExpression, in text: String) -> [String] {
        regex.matches(in: text, range: NSRange(text.startIndex..., in: text))
            .compactMap { Range($0.range, in: text).map { String(text[$0]) } }
    }

    private func settingsSources() throws -> [URL] {
        // #filePath, not the working directory: `swift test` and Xcode disagree about cwd.
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()   // ScriptaCoreTests
            .deletingLastPathComponent()   // Tests
            .deletingLastPathComponent()   // Core
            .deletingLastPathComponent()   // repository root
        return try FileManager.default
            .contentsOfDirectory(at: root.appendingPathComponent("Sources/Settings"), includingPropertiesForKeys: nil)
            .filter { $0.pathExtension == "swift" }
    }
}
