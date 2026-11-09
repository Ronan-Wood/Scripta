import Foundation
import XCTest

/// What `Distribution/build-and-notarize` must do, checked on the script itself. The app's release
/// is the app's: this lived in the engine's suite, which reached out of the engine's tree to read
/// it, and moved here when the engine began running alone.
final class ReleaseScriptTests: XCTestCase {
    /// `#filePath`, not the working directory: `swift test` and Xcode disagree about cwd.
    private static let script = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ScriptaCoreTests
        .deletingLastPathComponent()   // Tests
        .deletingLastPathComponent()   // Core
        .deletingLastPathComponent()   // repository root
        .appendingPathComponent("Distribution/build-and-notarize")

    /// The engine phase checks only its own stage. Xcode, Sparkle's helper phase, stapling and the
    /// copy into the dmg stage all run later, so the release must check the app it actually packs:
    /// after the copy into the stage, before the dmg is made, for all three signature attributes.
    func testTheReleaseChecksTheShippedAppForSignatureXattrsBeforeTheDmg() throws {
        let text = try String(contentsOf: Self.script, encoding: .utf8)
        func at(_ needle: String, after start: String.Index? = nil) throws -> String.Index {
            let range = start.map { $0..<text.endIndex } ?? text.startIndex..<text.endIndex
            return try XCTUnwrap(text.range(of: needle, range: range)?.lowerBound,
                                 "build-and-notarize no longer has `\(needle)`")
        }
        let copy = try at(#"cp -R "$APP" dist/stage/"#)
        let check = try at("find dist/stage/Scripta.app -xattrname com.apple.cs.CodeDirectory")
        let create = try at("hdiutil create")
        XCTAssertLessThan(copy, check, "the shipped-app check runs before the copy into the stage")
        XCTAssertLessThan(check, create, "the dmg is made before the shipped app is checked")

        let signature = try at("com.apple.cs.CodeSignature", after: check)
        let scan = text[check..<(text[signature...].firstIndex(of: "\n") ?? text.endIndex)]
        for attribute in ["CodeDirectory", "CodeRequirements", "CodeSignature"] {
            XCTAssertTrue(scan.contains("com.apple.cs.\(attribute)"), attribute)
        }
    }
}
