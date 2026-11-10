import Foundation

/// The engine's vocabularies, as the engine states them in its contract: the app's byte-identical
/// copy at `Core/Tests/EngineContract/contract.json`, which `engine pin`
/// (`Distribution/fetch-engine --check`) holds to the pinned release's. The note and transcript
/// gates check what the app DECLARES against these, rather than against the engine's source or a
/// second copy of the decision.
///
/// Its own small reader, because this test target cannot see SubstrateKitTests' `EngineContract`
/// (two test targets, deliberately apart: see `Package.swift`). It mirrors that type's nesting for
/// the sections it needs, so one rename reads the same in both. A missing value THROWS, naming the
/// key path: a gate that quietly finds nothing to compare is worse than one that cannot run.
struct EngineVocabulary: Decodable {
    struct Spine: Decodable {
        let statuses: Set<String>
        let includedStatuses: Set<String>
        let docTypes: Set<String>
        let confidences: Set<String>
        /// What a note may declare: the judged confidences plus the no-claim token. The engine's
        /// own gate refuses anything outside it.
        let declarableConfidences: Set<String>

        enum CodingKeys: String, CodingKey {
            case statuses, confidences
            case includedStatuses = "included_statuses"
            case docTypes = "doc_types"
            case declarableConfidences = "declarable_confidences"
        }
    }

    struct Classes: Decodable {
        let policies: Set<String>
        let excluded: Set<String>
    }

    struct Socket: Decodable {
        let lockSuffix: String

        enum CodingKeys: String, CodingKey { case lockSuffix = "lock_suffix" }
    }

    struct YAML: Decodable {
        /// The code points a one-line quoted frontmatter scalar may hold, as `[first, last]`
        /// ranges; the engine reads every other character as a space.
        let printable: [[UInt32]]

        func holds(_ v: UInt32) -> Bool { printable.contains { $0.count == 2 && $0[0] <= v && v <= $0[1] } }
    }

    let spine: Spine
    let classes: Classes
    let socket: Socket
    let yaml: YAML

    /// `#filePath`, not the working directory: `swift test` and Xcode disagree about cwd.
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // ScriptaCoreTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("EngineContract/contract.json")

    static func load() throws -> EngineVocabulary {
        try JSONDecoder().decode(EngineVocabulary.self, from: Data(contentsOf: url))
    }
}
