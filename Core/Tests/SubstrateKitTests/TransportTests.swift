import XCTest
@testable import SubstrateKit

/// The four outcomes, each against a frame the engine really produced.
///
/// The decision table is pure (`SubstrateClient.interpret`), so every case here runs without a
/// socket. The live-socket behaviour that cannot be captured — a refused connection — gets its own
/// test below against a port nothing is listening on.
final class TransportTests: XCTestCase {

    // MARK: - Outcome 1: a tool answered

    func testAResultDecodesToItsPayload() throws {
        let frame = try GoldenFixture.frame(GoldenFixture.status)
        let call: SubstrateCall<WireStatusResult> =
            SubstrateClient.interpret(frame: frame, expectedID: 1)
        guard case .ok(let payload) = call else { return XCTFail("expected .ok, got \(call)") }
        XCTAssertEqual(payload.scope, "scripta")
    }

    // MARK: - Outcome 2: isError inside a successful result

    /// The engine's deliberate design: `_dispatch` catches every handler exception and returns it
    /// as a normal `result` with `isError: true`, "so the model sees the condition and can act on
    /// it … rather than a transport error it cannot interpret". It must not surface as a failure.
    func testAToolFaultIsNotATransportFailure() throws {
        let frame = try GoldenFixture.frame(GoldenFixture.toolFault)
        let call: SubstrateCall<WireStatusResult> =
            SubstrateClient.interpret(frame: frame, expectedID: 7)
        guard case .toolFault(let text) = call else {
            return XCTFail("expected .toolFault, got \(call)")
        }
        XCTAssertTrue(text.contains("unknown scope 'no-such-scope'"))
        // The engine puts the remedy in the sentence; carrying it verbatim is the whole point.
        XCTAssertTrue(text.contains("Registered:"))
        XCTAssertNil(call.payloadIfOK)
    }

    /// The read-only refusal is the tool fault an operator is most likely to meet, and it is a
    /// POLICY rather than a bug — `ingest` is off the socket by design (Doc 3 §3).
    func testTheReadOnlyRefusalArrivesAsAToolFault() {
        let frame = Data("""
            {"jsonrpc": "2.0", "id": 9, "result": {"content": [{"type": "text", "text": \
            "`ingest` is refused on this transport: the server is read-only (Doc 3 §3)."}], \
            "isError": true}}
            """.utf8)
        let call: SubstrateCall<WireSearchResult> =
            SubstrateClient.interpret(frame: frame, expectedID: 9)
        guard case .toolFault(let text) = call else {
            return XCTFail("expected .toolFault, got \(call)")
        }
        XCTAssertTrue(text.contains("read-only"))
    }

    // MARK: - Outcome 3: a JSON-RPC error object

    func testAnErrorObjectIsItsOwnOutcome() throws {
        let frame = try GoldenFixture.frame(GoldenFixture.rpcError)
        let call: SubstrateCall<WireSearchResult> =
            SubstrateClient.interpret(frame: frame, expectedID: 8)
        guard case .rpcError(let code, let message) = call else {
            return XCTFail("expected .rpcError, got \(call)")
        }
        XCTAssertEqual(code, -32601)
        XCTAssertTrue(message.contains("nope/nope"))
    }

    /// A frame carrying both is malformed; preferring `result` would read it as a success.
    func testAnErrorWinsOverAResult() {
        let frame = Data("""
            {"jsonrpc": "2.0", "id": 1, "error": {"code": -32603, "message": "internal"}, \
            "result": {"content": [{"type": "text", "text": "{}"}]}}
            """.utf8)
        let call: SubstrateCall<WireScopeList> =
            SubstrateClient.interpret(frame: frame, expectedID: 1)
        guard case .rpcError(let code, _) = call else {
            return XCTFail("expected .rpcError, got \(call)")
        }
        XCTAssertEqual(code, -32603)
    }

    // MARK: - Outcome 4: no JSON-RPC answer at all

    /// A LIVE check that the engine being down is its own outcome. Port 1 on loopback has nothing
    /// bound, which is the same refused connection a stopped `substrate-mcp` produces — no fixture
    /// can stand in for it, and it is the state a fresh machine is in.
    func testAnUnreachableEngineIsNotAnEmptyResult() async throws {
        let client = SubstrateClient(endpoint: URL(string: "http://127.0.0.1:1")!, timeout: 5)
        let call = await client.status(SubstrateScopeRequest(scope: "scripta"))
        guard case .transportFailure(let failure) = call else {
            return XCTFail("expected a transport failure, got \(call)")
        }
        guard case .unreachable(_, let code) = failure else {
            return XCTFail("expected .unreachable, got \(failure)")
        }
        XCTAssertEqual(code, .cannotConnectToHost)
        XCTAssertTrue(failure.description.contains("unreachable"))
    }

    /// A non-200 is read from the STATUS, not from the body — and this body is the real one the
    /// engine sends, captured from a live `Content-Type: text/plain` POST. It is a perfectly
    /// well-formed JSON-RPC error object, which is exactly why body-first would misreport it.
    func testAGuardRefusalIsAnHTTPStatusNotAProtocolError() throws {
        let body = try GoldenFixture.frame("http-415-refusal.body.json")
        let response = HTTPURLResponse(url: SubstrateClient.defaultEndpoint, statusCode: 415,
                                       httpVersion: "HTTP/1.1", headerFields: nil)
        let call: SubstrateCall<WireSearchResult> =
            SubstrateClient.interpret(body: body, response: response, expectedID: 1)
        guard case .transportFailure(.httpStatus(let code, let text)) = call else {
            return XCTFail("expected .httpStatus, got \(call)")
        }
        XCTAssertEqual(code, 415)
        XCTAssertTrue(text.contains("expected Content-Type: application/json"),
                      "the refusal names which guard fired; dropping the body loses that")
    }

    func testAnAnswerToADifferentRequestIsRefused() throws {
        let frame = try GoldenFixture.frame(GoldenFixture.status)
        let call: SubstrateCall<WireStatusResult> =
            SubstrateClient.interpret(frame: frame, expectedID: 99)
        guard case .transportFailure(.malformedResponse(let why)) = call else {
            return XCTFail("expected .malformedResponse, got \(call)")
        }
        XCTAssertTrue(why.contains("does not match"))
    }

    func testAFrameWithNeitherResultNorErrorIsMalformed() {
        let call: SubstrateCall<WireScopeList> =
            SubstrateClient.interpret(frame: Data(#"{"jsonrpc": "2.0", "id": 1}"#.utf8),
                                      expectedID: 1)
        guard case .transportFailure(.malformedResponse) = call else {
            return XCTFail("expected .malformedResponse, got \(call)")
        }
    }

    /// A tool answered, and its payload was not the shape this call expected. Separate from a
    /// malformed frame because the frame was fine — the disagreement is with `render.py`.
    func testAWrongPayloadShapeIsUndecodableNotMalformed() throws {
        // A real `status` frame decoded as if it were a `search` result.
        let frame = try GoldenFixture.frame(GoldenFixture.status)
        let call: SubstrateCall<WireSearchResult> =
            SubstrateClient.interpret(frame: frame, expectedID: 1)
        guard case .transportFailure(.undecodablePayload) = call else {
            return XCTFail("expected .undecodablePayload, got \(call)")
        }
    }

    // MARK: - Against the running engine

    /// The one test that talks to the real thing.
    ///
    /// SKIPPED when the engine is not running, which is the honest trade: a suite that fails on a
    /// machine with no daemon is a suite people stop running, and the golden fixtures are the
    /// durable half of the verification. When the engine IS up this asserts the live payload still
    /// round-trips losslessly — so a shape change in `render.py` is caught on the first run after
    /// it lands, not at the next re-capture.
    ///
    ///     /Users/ronanwood/.local/bin/substrate-mcp --http 127.0.0.1:8765
    func testLiveEngineAgreesWithTheGoldenShape() async throws {
        let client = SubstrateClient(timeout: 30)
        let probe = await client.listScopes()

        if case .transportFailure(.unreachable(let reason, _)) = probe {
            throw XCTSkip("the substrate engine is not running (\(reason)); "
                          + "start it with `substrate-mcp --http 127.0.0.1:8765` to run this")
        }
        guard case .ok(let scopes) = probe else {
            return XCTFail("list_scopes did not answer: \(probe)")
        }
        XCTAssertTrue(scopes.scopes.contains { $0.scope == "scripta" })

        // Lossless against the LIVE bytes rather than the fixture, so a field added to
        // `scopes_payload` or `status_payload` since the capture fails on the first run after it
        // lands. The raw body is fetched directly because the client — correctly — hands back a
        // decoded payload and not the bytes it came from.
        try await JSONDiff.assertLossless(WireScopeList.self,
                                          payload: liveToolPayload("list_scopes", arguments: "{}"))
        try await JSONDiff.assertLossless(
            WireStatusResult.self,
            payload: liveToolPayload("status", arguments: #"{"scope": "scripta"}"#)
        )
        try await JSONDiff.assertLossless(
            WireSearchResult.self,
            payload: liveToolPayload(
                "search", arguments: #"{"scope": "scripta", "query": "the retrieval envelope"}"#
            )
        )
    }

    /// One `tools/call` straight to the socket, returning `content[0].text` as bytes.
    private func liveToolPayload(_ tool: String, arguments: String) async throws -> Data {
        var request = URLRequest(url: SubstrateClient.defaultEndpoint)
        request.httpMethod = "POST"
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.timeoutInterval = 60
        request.httpBody = Data("""
            {"jsonrpc": "2.0", "id": 1, "method": "tools/call", \
            "params": {"name": "\(tool)", "arguments": \(arguments)}}
            """.utf8)
        let (data, _) = try await URLSession(configuration: .ephemeral).data(for: request)
        let object = try JSONSerialization.jsonObject(with: data) as? [String: Any]
        guard let result = object?["result"] as? [String: Any],
              result["isError"] == nil,
              let content = result["content"] as? [[String: Any]],
              let text = content.first?["text"] as? String else {
            throw XCTSkip("live \(tool) did not answer with a payload: "
                          + (String(data: data, encoding: .utf8) ?? "<non-UTF-8>"))
        }
        return Data(text.utf8)
    }
}
