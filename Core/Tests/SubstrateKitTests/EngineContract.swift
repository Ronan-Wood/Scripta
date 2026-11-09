import Foundation
import XCTest

// MARK: - The engine's contract, as the engine states it
//
// `contract.json` is what the engine says about itself: its wire constants, its closed
// vocabularies and the keys of every wire object this client decodes. The engine writes it
// (`substrate/tools/export-contract.py`) and its own suite fails when the file stops describing the
// code. This reads the app's byte-identical copy of it, `Core/Tests/EngineContract/contract.json`,
// which `Distribution/engine-contract check` holds to the engine's. So the parity tests read no
// engine source: they compare this client against what the engine states, wherever the engine is.

struct EngineContract: Decodable {
    struct Wire: Decodable {
        let version: Int
        let header: String
        let mismatch: Int
        let unstated: Int
    }

    struct Socket: Decodable {
        let defaultPath: String

        enum CodingKeys: String, CodingKey { case defaultPath = "default" }
    }

    struct Spine: Decodable {
        let statuses: Set<String>
        let includedStatuses: Set<String>
        let docTypes: Set<String>
        let confidences: Set<String>
        let declarableConfidences: Set<String>
        let storedConfidences: Set<String>
        let unstatedConfidence: String
        let unjudgedConfidence: String

        enum CodingKeys: String, CodingKey {
            case statuses, confidences
            case includedStatuses = "included_statuses"
            case docTypes = "doc_types"
            case declarableConfidences = "declarable_confidences"
            case storedConfidences = "stored_confidences"
            case unstatedConfidence = "unstated_confidence"
            case unjudgedConfidence = "unjudged_confidence"
        }
    }

    struct Classes: Decodable {
        let policies: Set<String>
        let excluded: Set<String>
    }

    struct Retrieval: Decodable {
        let arms: Set<String>
        let armWired: String
        let armUnavailable: String
        let armOff: String
        let armStates: Set<String>
        let engineHealthStates: Set<String>
        let unmeasuredReasons: Set<String>

        enum CodingKeys: String, CodingKey {
            case arms
            case armWired = "arm_wired"
            case armUnavailable = "arm_unavailable"
            case armOff = "arm_off"
            case armStates = "arm_states"
            case engineHealthStates = "engine_health_states"
            case unmeasuredReasons = "unmeasured_reasons"
        }
    }

    struct Refresh: Decodable {
        let outcomes: Set<String>
    }

    struct Tiers: Decodable {
        let caseCount: Int
        let ceiling: Double
        let floor: Double

        enum CodingKeys: String, CodingKey {
            case ceiling, floor
            case caseCount = "case_count"
        }
    }

    /// The file at an engine root that says what the engine there is (`EngineManifest`).
    struct Manifest: Decodable {
        let file: String
        let features: Set<String>
    }

    let wire: Wire
    let socket: Socket
    let engineManifest: Manifest
    let spine: Spine
    let classes: Classes
    let retrieval: Retrieval
    let refresh: Refresh
    /// Each wire object's OWN keys, sorted. `keys(of:)` adds those of the objects it extends.
    let payloads: [String: [String]]
    /// The objects each one is built on. One base is an object built on another (`outline_record`
    /// on `passage`); several are ALTERNATIVES, one per branch, of which a reply carries one
    /// (`scope_list_reply` on the registry's roster or the agent's).
    let extends: [String: [String]]
    let tiers: Tiers

    enum CodingKeys: String, CodingKey {
        case wire, socket, spine, classes, retrieval, refresh, payloads, extends, tiers
        case engineManifest = "engine_manifest"
    }

    init(data: Data) throws {
        self = try JSONDecoder().decode(EngineContract.self, from: data)
    }

    /// `#filePath`, not the working directory or `Bundle.module`: `swift test` and Xcode disagree
    /// about cwd, and a gate that silently finds no file is worse than one that cannot run.
    static let url = URL(fileURLWithPath: #filePath)
        .deletingLastPathComponent()   // SubstrateKitTests
        .deletingLastPathComponent()   // Tests
        .appendingPathComponent("EngineContract/contract.json")

    static func load() throws -> EngineContract {
        try EngineContract(data: Data(contentsOf: url))
    }

    /// Every key a wire object MAY carry: its own and those of every object it extends (with
    /// alternative bases, all of them). A name the contract does not declare, or an `extends` that
    /// loops, is a failure rather than an empty set, which would make every comparison vacuous.
    func keys(of object: String, file: StaticString = #filePath, line: UInt = #line,
              through seen: [String] = []) -> Set<String> {
        guard !seen.contains(object) else {
            XCTFail("the contract's extends loops: \((seen + [object]).joined(separator: " -> "))",
                    file: file, line: line)
            return []
        }
        return (extends[object] ?? []).reduce(into: ownKeys(of: object, file: file, line: line)) {
            $0.formUnion(keys(of: $1, file: file, line: line, through: seen + [object]))
        }
    }

    /// A wire object's OWN keys, without what it extends.
    func ownKeys(of object: String, file: StaticString = #filePath, line: UInt = #line)
        -> Set<String> {
        guard let own = payloads[object] else {
            XCTFail("the engine's contract declares no wire object `\(object)`", file: file,
                    line: line)
            return []
        }
        return Set(own)
    }
}
