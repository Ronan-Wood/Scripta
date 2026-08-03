import Foundation
import XCTest

// MARK: - Real frames from the real engine
//
// PROVENANCE. Every file in `Fixtures/` is the byte-for-byte HTTP response body of a live
// `substrate-mcp --http 127.0.0.1:8765`, RE-CAPTURED 2026-08-03 against the operator's real composed
// scopes (`scripta`: 57 documents, 527 passages, index_version v8:84fda18a439c) after the engine
// grew `passage.document_class` and `retrieval_mode`'s `embedder_state` / `unmeasured_reason` /
// `health`. Nothing was hand-written, reformatted or trimmed. The calls, in order:
//
//   search.frame.json       tools/call search      {"scope":"scripta","query":"what did we decide
//                                                   about the retrieval envelope"}
//   search-sources.frame.json
//                           tools/call search      {"scope":"scripta","query":"diff-only
//                                                   adversarial review reviewer sees only the
//                                                   diff","include_sources":true}
//   status.frame.json       tools/call status      {"scope":"scripta"}
//   list_scopes.frame.json  tools/call list_scopes {}
//   expand.frame.json       tools/call expand      {"expand_ref":"scripta/scripta-doc3a-mcp-server
//                                                   #c00002","mode":"note"}
//   tool-fault.frame.json   tools/call status      {"scope":"no-such-scope"}  → isError: true
//   rpc-error.frame.json    method "nope/nope"                                → error -32601
//
// THE SECOND SEARCH EARNS ITS PLACE. Default retrieval withholds the conversation class, so every
// passage in the first one carries `document_class: "reference-frozen"` and a decoder that ignored
// the field entirely would round-trip it. `search-sources` asks for the class back and really does
// return transcript passages, which is the only fixture here where the axis takes a value that
// changes what the spine draws.
//
// A HAND-BUILT FIXTURE WOULD PROVE NOTHING. The whole failure this decoder exists to avoid is
// believing a shape the engine does not actually send, and a fixture written from the same reading
// of `render.py` that produced the decoder would agree with it by construction.
//
// To re-capture, run the engine and repeat the calls above:
//   /Users/ronanwood/.local/bin/substrate-mcp --http 127.0.0.1:8765
//   curl -s -X POST http://127.0.0.1:8765 -H 'Content-Type: application/json' \
//     -d '{"jsonrpc":"2.0","id":1,"method":"tools/call","params":{"name":"search",...}}'

enum GoldenFixture {
    static let search = "search.frame.json"
    /// The same tool with `include_sources: true` — the one capture carrying conversation-class hits.
    static let searchIncludingSources = "search-sources.frame.json"
    static let status = "status.frame.json"
    static let listScopes = "list_scopes.frame.json"
    static let expand = "expand.frame.json"
    static let toolFault = "tool-fault.frame.json"
    static let rpcError = "rpc-error.frame.json"

    static let all = [search, searchIncludingSources, status, listScopes, expand, toolFault,
                      rpcError]

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

    private static func isBoolean(_ value: Any) -> Bool {
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
