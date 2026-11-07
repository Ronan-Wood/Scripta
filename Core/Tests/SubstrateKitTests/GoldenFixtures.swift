import Foundation
import XCTest

// MARK: - Real frames from the real engine
//
// PROVENANCE. Every file in `Fixtures/` except `http-415-refusal.body.json` is a response the engine
// in this repo produced, written by a test in the engine's own suite rather than by hand, and
// nothing in them was reformatted or trimmed. The non-agent frames come from
// `substrate/tests/test_swift_golden_frames.py`, run over the repo's SYNTHETIC demo vaults
// (`substrate/vaults/demo-vault`, inheriting `demo-core-vault`) in a registry holding one scope,
// `demo`. Its docstring is the authority on how: what it runs, and the three things it stands in
// (the workspace path as `/demo-substrate`, the workspace folder's mode, and a model daemon that
// refuses every connection). The `agent-*` frames come from `substrate/tests/test_agent_mode.py`;
// see `agentStatus` below. Re-capture with:
//
//   cd substrate && SUBSTRATE_CAPTURE_SWIFT_FIXTURES=1 PYTHONPATH=$PWD \
//     uv run --no-sync python -m pytest tests/test_swift_golden_frames.py tests/test_agent_mode.py \
//     -q -k swift
//
// Without the variable those tests fail when the engine's shape moves away from these files, or
// when a committed file carries a path of the machine that wrote it.
//
// `http-415-refusal.body.json` is the one older capture, from a live `substrate-mcp --http` sent a
// `Content-Type: text/plain` POST (→ HTTP 415). It names no scope, vault or path. The 415 is
// written by the HTTP transport itself, which `server.handle` never reaches, so the engine test
// cannot produce it.
//
// The calls, in order:
//
//   search.frame.json       tools/call search      {"scope":"demo","query":"which engine powers
//                                                   the app"}
//   search-sources.frame.json
//                           tools/call search      {"scope":"demo","query":"what was said on the
//                                                   call about the engine boundary",
//                                                   "include_sources":true}
//   status.frame.json       tools/call status      {"scope":"demo"}
//   list_scopes.frame.json  tools/call list_scopes {}
//   expand.frame.json       tools/call expand      {"expand_ref":"demo/engine-boundary-current
//                                                   #c00000","mode":"note"}
//   documents.frame.json    tools/call documents   {"scope":"demo","limit":3}
//   tool-fault.frame.json   tools/call status      {"scope":"no-such-scope"}  → isError: true
//   rpc-error.frame.json    method "nope/nope"     (id 8)                     → error -32601
//
// WHAT THAT MEANS ON THIS SIDE:
//
//   * No model daemon answered, so every arm is unavailable, `health.state` is `unreachable`,
//     `vectors` is null and the refresh pass recorded `embed_failed`. Those are the states the
//     content assertions pin — whatever the capturing machine's daemon was doing.
//   * `status.exposed` names `/demo-substrate`, because the capture sets that folder to 0755.
//   * The timestamps and `index_version` move on every capture, and nothing else does. The version
//     is a hash over each indexed note's chunks, spine, class AND absolute `source_path`
//     (`reconcile.py`), and that path is the capture's own temp workspace, which is new on every
//     run. The stand-in replaces the path in the text, not inside the hash. Every frame of one
//     capture names the same version, which is what `testSearchDecodesTheSpineAndTheEnvelope`
//     asserts in place of a literal.
//
// THE SECOND SEARCH EARNS ITS PLACE. Default retrieval withholds the conversation class, so every
// passage in the first one is `unclassified` and a decoder that ignored the field entirely would
// round-trip it. `search-sources` asks for the class back and returns the demo vault's one
// transcript (`_sources/engine-boundary-call.md`, synthetic, added for exactly this). It is the
// only SEARCH capture where the class axis takes more than one value, and the only fixture
// carrying `conversation`; `documents` spans the three non-source classes.
//
// A HAND-BUILT FIXTURE WOULD PROVE NOTHING. The whole failure this decoder exists to avoid is
// believing a shape the engine does not actually send, and a fixture written from the same reading
// of `render.py` that produced the decoder would agree with it by construction.

enum GoldenFixture {
    static let search = "search.frame.json"
    /// The same tool with `include_sources: true` — the one capture carrying conversation-class hits.
    static let searchIncludingSources = "search-sources.frame.json"
    static let status = "status.frame.json"
    static let listScopes = "list_scopes.frame.json"
    static let expand = "expand.frame.json"
    /// `documents` — the BROWSE call (`{"scope":"demo","limit":3}`). It is the only capture where
    /// every row comes from an INHERITED vault: all three are `demo-core-vault`, at tiers 1 and 2,
    /// which the scope's own directory does not contain. That is the property the browse tool
    /// exists for, so a fixture where it did not hold would prove the wrong thing.
    static let documents = "documents.frame.json"
    static let toolFault = "tool-fault.frame.json"
    /// AGENT MODE (`substrate-mcp --agent-mode`), and a different provenance from every frame above:
    /// captured from the engine's own `world` fixture in `substrate/tests/test_agent_mode.py`, whose
    /// allowed scope is `demo`, because agent mode answers only from a published snapshot. They
    /// are the bytes `server.handle` returns, written by
    /// `test_the_swift_decoders_fixtures_are_what_agent_mode_sends` with
    /// `SUBSTRATE_CAPTURE_SWIFT_FIXTURES=1`; without it that test fails when the engine's shape
    /// moves away from these. `vault` and `registry` are null in all of them, by design: an agent
    /// server has no vault or registry to name. `unpublished` is the same `status` with the snapshot
    /// manifest removed, which is what nulls `composed`.
    /// The snapshot folder is written as `/agent-snapshots` rather than pytest's tmp path, so a
    /// recapture moves only values that changed — and the timestamps, which always do.
    static let agentStatus = "agent-status.frame.json"
    static let agentStatusUnpublished = "agent-status-unpublished.frame.json"
    static let agentListScopes = "agent-list_scopes.frame.json"
    static let rpcError = "rpc-error.frame.json"

    static let all = [search, searchIncludingSources, status, listScopes, expand, documents,
                      toolFault, rpcError]

    /// The captured response body.
    ///
    /// `#filePath`, not the working directory or `Bundle.module`: `swift test` and Xcode disagree
    /// about cwd, and the repo already learned that lesson in `ThemeTokenSource.loadFromRepository`.
    static func frame(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws
        -> Data {
        let url = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent()
            .appendingPathComponent("Fixtures")
            .appendingPathComponent(name)
        guard FileManager.default.fileExists(atPath: url.path) else {
            XCTFail("golden fixture missing at \(url.path). These are captured engine responses; "
                    + "see the provenance note in GoldenFixtures.swift to re-capture.",
                    file: file, line: line)
            throw CocoaError(.fileNoSuchFile)
        }
        return try Data(contentsOf: url)
    }

    /// The tool payload inside a captured frame — `result.content[0].text`, parsed out of the
    /// envelope rather than stored a second time. One copy of the bytes, so the payload fixture
    /// cannot drift from the frame fixture.
    static func payload(_ name: String, file: StaticString = #filePath, line: UInt = #line) throws
        -> Data {
        let frame = try frame(name, file: file, line: line)
        guard let object = try JSONSerialization.jsonObject(with: frame) as? [String: Any],
              let result = object["result"] as? [String: Any],
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String,
              let data = text.data(using: .utf8) else {
            XCTFail("\(name) is not a tools/call result carrying text content",
                    file: file, line: line)
            throw CocoaError(.coderReadCorrupt)
        }
        return data
    }
}

// MARK: - Deep JSON comparison

/// Compares two parsed JSON values and reports the first divergence BY KEY PATH.
///
/// Byte equality is not available and would be the wrong instrument anyway: Python writes
/// `indent=2` with insertion-ordered keys, Swift writes whatever its encoder does. What must hold is
/// that no field was dropped, added or altered — which is a structural claim, so it is checked
/// structurally.
///
/// The direction matters. `expected` is always the CAPTURED bytes; `actual` is what Swift produced
/// after a decode/encode round trip. A field Swift silently drops shows up here as "missing from
/// actual", which is the failure a same-side comparison cannot see.
enum JSONDiff {
    static func firstDifference(expected: Any, actual: Any, path: String = "") -> String? {
        if let expected = expected as? [String: Any] {
            guard let actual = actual as? [String: Any] else {
                return "\(display(path)): expected an object, got \(type(of: actual))"
            }
            let expectedKeys = Set(expected.keys), actualKeys = Set(actual.keys)
            if let dropped = expectedKeys.subtracting(actualKeys).sorted().first {
                return "\(display(path)): the engine sent `\(dropped)` and Swift did not "
                    + "re-emit it — the decoder is dropping it"
            }
            if let invented = actualKeys.subtracting(expectedKeys).sorted().first {
                return "\(display(path)): Swift emitted `\(invented)`, which the engine did not send"
            }
            for key in expectedKeys.sorted() {
                if let difference = firstDifference(expected: expected[key]!, actual: actual[key]!,
                                                    path: path.isEmpty ? key : "\(path).\(key)") {
                    return difference
                }
            }
            return nil
        }

        if let expected = expected as? [Any] {
            guard let actual = actual as? [Any] else {
                return "\(display(path)): expected an array, got \(type(of: actual))"
            }
            guard expected.count == actual.count else {
                return "\(display(path)): \(expected.count) elements on the wire, "
                    + "\(actual.count) after the round trip"
            }
            for index in expected.indices {
                if let difference = firstDifference(expected: expected[index], actual: actual[index],
                                                    path: "\(path)[\(index)]") {
                    return difference
                }
            }
            return nil
        }

        // BOOL AND NUMBER FIRST, because `isEqual` cannot tell them apart. JSONSerialization
        // bridges both to NSNumber, and `NSNumber(false).isEqual(NSNumber(0))` is true — so a
        // `frozen: false` re-encoded as `0` would pass a gate whose entire subject is the three
        // fields where a Bool and a number mean different things. Discriminated on the CoreFoundation
        // type, which is the only place the distinction survives the bridge.
        if isBoolean(expected) != isBoolean(actual) {
            return "\(display(path)): the engine sent \(brief(expected)) as a "
                + "\(isBoolean(expected) ? "boolean" : "number") and the round trip produced a "
                + "\(isBoolean(actual) ? "boolean" : "number")"
        }
        // Otherwise NSNull covers null and NSNumber/NSString the rest: a `null` the encoder turned
        // into an omission is already caught above, and a `null` turned into `false` fails here.
        let lhs = expected as? NSObject
        let rhs = actual as? NSObject
        if let lhs, let rhs, lhs.isEqual(rhs) { return nil }
        return "\(display(path)): the engine sent \(brief(expected)), the round trip produced "
            + "\(brief(actual))"
    }

    static func isBoolean(_ value: Any) -> Bool {
        guard let number = value as? NSNumber else { return false }
        return CFGetTypeID(number) == CFBooleanGetTypeID()
    }

    private static func display(_ path: String) -> String { path.isEmpty ? "<root>" : path }

    private static func brief(_ value: Any) -> String {
        if value is NSNull { return "null" }
        let text = String(describing: value)
        return text.count <= 80 ? text : String(text.prefix(80)) + "…"
    }

    /// Decode, re-encode, and prove nothing was lost against the CAPTURED bytes.
    static func assertLossless<T: Codable>(
        _ type: T.Type, payload: Data, file: StaticString = #filePath, line: UInt = #line
    ) throws {
        let decoded = try JSONDecoder().decode(T.self, from: payload)
        let reencoded = try JSONEncoder().encode(decoded)
        let expected = try JSONSerialization.jsonObject(with: payload)
        let actual = try JSONSerialization.jsonObject(with: reencoded)
        if let difference = firstDifference(expected: expected, actual: actual) {
            XCTFail("\(T.self) does not round-trip the engine's own bytes — \(difference)",
                    file: file, line: line)
        }
    }
}
