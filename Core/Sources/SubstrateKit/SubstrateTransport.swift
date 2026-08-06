import Foundation

// MARK: - JSON-RPC 2.0 over loopback HTTP
//
// The engine (`substrate/substrate/mcp/server.py`) speaks one JSON-RPC frame per POST. There is no
// SSE stream and no request path: `do_GET` refuses with 405 and `do_POST` deliberately does not
// examine the URL, because every URL on that server is the one endpoint.
//
// THREE HEADER RULES ARE LOAD-BEARING, and `_guarded()` refuses without them:
//   `Host` must resolve to loopback   — enforced, not merely checked; an absent Host is refused
//   `Origin` must be ABSENT          — any Origin at all is refused; there is no page to allow-list
//   `Content-Type: application/json` — no form can send this without a preflight the server never
//                                      answers
// `URLSession` sets Host from the URL and sends no Origin, so only the content type is ours to set.
// A refusal comes back as a non-200 with a JSON-RPC error body, which is why `httpStatus` carries
// the body rather than discarding it.
//
// FOUR OUTCOMES, NOT ONE ERROR. The engine is explicit that a tool fault is not a transport
// failure: `_dispatch` catches every exception a handler can raise and returns it as a normal
// `result` carrying `isError: true`, "so the model sees the condition and can act on it (compose
// the scope, search again) rather than a transport error it cannot interpret". Collapsing that into
// the same `Error` as a refused connection would throw away the distinction the server goes out of
// its way to preserve.

/// What one `tools/call` produced. Not `throws`: a caller must name the case it is handling, and
/// `try?` must not be able to turn a tool fault into an absence.
public enum SubstrateCall<Payload> {
    /// A `result` with no `isError`, whose `content[0].text` decoded as `Payload`.
    case ok(Payload)

    /// A `result` with `isError: true`. The engine's deliberate design — a condition the caller can
    /// act on. The string is `content[0].text` verbatim; the engine writes an actionable sentence
    /// there ("unknown scope 'x'. Registered: …", "`ingest` is refused on this transport …").
    case toolFault(String)

    /// A JSON-RPC `error` object: the frame never reached a tool. `-32601` unknown method,
    /// `-32602` unknown tool or bad params, `-32700` parse error, `-32603` internal.
    case rpcError(code: Int, message: String)

    /// The call did not produce a JSON-RPC answer at all.
    case transportFailure(SubstrateTransportFailure)

    /// The payload, or nothing. Deliberately not named `value`: the other three cases are
    /// conditions to act on, and flattening them is only ever right in a test that has already
    /// asserted which case it got.
    public var payloadIfOK: Payload? {
        if case .ok(let payload) = self { return payload }
        return nil
    }
}

extension SubstrateCall: Sendable where Payload: Sendable {}

/// Why no JSON-RPC answer came back. Split rather than merged because the operator's next move
/// differs for each: start the engine, look at what the guard refused, or file a bug.
public enum SubstrateTransportFailure: Equatable, Sendable, CustomStringConvertible {
    /// The engine is DOWN, or the socket died mid-call. `code` is the `URLError.Code` when Foundation
    /// gave one — `.cannotConnectToHost` is the "not running" signal.
    case unreachable(reason: String, code: URLError.Code?)

    /// A non-200. The server refuses with 405 (GET), 415 (wrong content type), 403 (any Origin),
    /// 421 (non-loopback Host), 411/400/413 (framing), 503 (connection ceiling) — each with a
    /// JSON-RPC error body that says which, so the body is carried rather than dropped.
    case httpStatus(code: Int, body: String)

    /// A 200 whose body is not a JSON-RPC response: unparseable, no `result` and no `error`, an id
    /// that does not match the request, or a `result` with no text content.
    case malformedResponse(String)

    /// The frame was well-formed and `content[0].text` was not the payload this call expected.
    /// Carries the decoder's own description, which names the key or type that disagreed.
    case undecodablePayload(String)

    /// Whether this "failure" is really the caller's own cancellation coming back as one.
    ///
    /// It arrives as `.unreachable` because that is literally what URLSession reports — a request
    /// that was torn down did not reach the host — and at the transport layer those are the same
    /// event. One layer up they are opposites: `cannotConnectToHost` means start the engine, and
    /// `cancelled` means nothing happened at all. Rendering the second as the first tells a reader
    /// their engine is down because they changed tabs.
    ///
    /// Answered HERE rather than at each call site because there is more than one caller and they
    /// were not treating it alike: the search path guarded cancellation and the scope roster did
    /// not, so leaving Ask drew a red fault card about a healthy engine — and it persisted, because
    /// the roster only re-lists from its unasked state.
    public var isCancellation: Bool {
        if case .unreachable(_, let code) = self { return code == .cancelled }
        return false
    }

    public var description: String {
        switch self {
        case .unreachable(let reason, let code):
            let suffix = code.map { " (URLError \($0.rawValue))" } ?? ""
            return "the substrate engine is unreachable: \(reason)\(suffix)"
        case .httpStatus(let code, let body):
            return "HTTP \(code) from the substrate engine: \(body)"
        case .malformedResponse(let why):
            return "the substrate engine's reply is not a JSON-RPC response: \(why)"
        case .undecodablePayload(let why):
            return "the tool's payload did not decode: \(why)"
        }
    }
}

// MARK: - Tool arguments

/// `search`. `docType` is absent on purpose: the server REFUSES it (Doc 2 §6a ships the axis and
/// defers the filter), and offering it here would only let a caller construct a call that cannot
/// succeed.
public struct SubstrateSearchRequest: Encodable, Sendable {
    public let scope: String
    public let query: String
    /// Clamped server-side; a clamp arrives back in `filters.notes`.
    public let k: Int?
    public let includeArchived: Bool?
    public let includeSources: Bool?

    /// Embedder only — no HyDE, no reranker. For a caller that must answer inside a turn of speech.
    ///
    /// Measured against the live engine 2026-08-06 on the `cbre` scope: 17,274ms considered against
    /// 286ms fast. The reply SAYS which it got — a fast answer reports `hyde=off · rerank=off` and a
    /// null `expected_mrr` with `unmeasured_arm_combination` — so a live hit can never be read as
    /// carrying the measured stack's number. Anything the reader is waiting on deliberately should
    /// leave this off.
    public let fast: Bool?

    public init(scope: String, query: String, k: Int? = nil,
                includeArchived: Bool? = nil, includeSources: Bool? = nil,
                fast: Bool? = nil) {
        self.scope = scope
        self.query = query
        self.k = k
        self.includeArchived = includeArchived
        self.includeSources = includeSources
        self.fast = fast
    }

    enum CodingKeys: String, CodingKey {
        case scope, query, k, fast
        case includeArchived = "include_archived"
        case includeSources = "include_sources"
    }
}

public struct SubstrateExpandRequest: Encodable, Sendable {
    /// The `expand_ref` a search result handed over — `"<scope>/<chunk_id>"`.
    public let expandRef: String
    /// `"passage"` or `"note"`.
    public let mode: String

    public init(expandRef: String, mode: String = "passage") {
        self.expandRef = expandRef
        self.mode = mode
    }

    enum CodingKeys: String, CodingKey {
        case expandRef = "expand_ref"
        case mode
    }
}

public struct SubstrateScopeRequest: Encodable, Sendable {
    public let scope: String
    public init(scope: String) { self.scope = scope }
}

public struct SubstrateNoArguments: Encodable, Sendable {
    public init() {}
}

// MARK: - Client

/// The loopback JSON-RPC client.
///
/// An `actor` rather than a struct with a lock: the only mutable state is the request id counter,
/// and `Core` is on `.macOS(.v14)` where `Mutex` does not exist. Nothing here is `@MainActor` — the
/// engine is a subprocess on a socket and no view is wired to this yet.
public actor SubstrateClient {
    /// `http://127.0.0.1:8765` — what `substrate-mcp --http 127.0.0.1:8765` binds.
    public static let defaultEndpoint = URL(string: "http://127.0.0.1:8765")!

    public let endpoint: URL
    private let session: URLSession
    private var nextID = 0

    public init(endpoint: URL = SubstrateClient.defaultEndpoint, timeout: TimeInterval = 120) {
        self.endpoint = endpoint
        let configuration = URLSessionConfiguration.ephemeral
        configuration.timeoutIntervalForRequest = timeout
        // FAIL FAST when the engine is down. With this on, Foundation parks the request until the
        // host answers, which turns "the engine is not running" — the state a fresh machine is in —
        // into a hang instead of the outcome this enum exists to report.
        configuration.waitsForConnectivity = false
        configuration.httpShouldSetCookies = false
        configuration.requestCachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        self.session = URLSession(configuration: configuration)
    }

    public func search(_ request: SubstrateSearchRequest) async -> SubstrateCall<WireSearchResult> {
        await call(tool: "search", arguments: request)
    }

    public func status(_ request: SubstrateScopeRequest) async -> SubstrateCall<WireStatusResult> {
        await call(tool: "status", arguments: request)
    }

    public func listScopes() async -> SubstrateCall<WireScopeList> {
        await call(tool: "list_scopes", arguments: SubstrateNoArguments())
    }

    public func expand(_ request: SubstrateExpandRequest) async -> SubstrateCall<WireExpandResult> {
        await call(tool: "expand", arguments: request)
    }

    /// One `tools/call`, start to finish.
    public func call<Arguments: Encodable, Payload: Decodable>(
        tool: String, arguments: Arguments
    ) async -> SubstrateCall<Payload> {
        nextID += 1
        let id = nextID

        let body: Data
        do {
            body = try JSONEncoder().encode(RPCRequest(id: id, tool: tool, arguments: arguments))
        } catch {
            // Encoding our own request cannot fail for the argument types above; if it ever does it
            // is a bug here, not a fault of the engine, so it does not masquerade as either.
            return .transportFailure(.malformedResponse("could not encode the request: \(error)"))
        }

        var request = URLRequest(url: endpoint)
        request.httpMethod = "POST"
        // Required by `_guarded()`; anything else is refused with 415.
        request.setValue("application/json", forHTTPHeaderField: "Content-Type")
        request.httpBody = body

        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await session.data(for: request)
        } catch let error as URLError {
            return .transportFailure(.unreachable(reason: error.localizedDescription,
                                                  code: error.code))
        } catch {
            return .transportFailure(.unreachable(reason: "\(error)", code: nil))
        }

        return Self.interpret(body: data, response: response, expectedID: id)
    }

    // MARK: Frame handling

    /// The status check, then the frame.
    ///
    /// STATUS FIRST, and the ordering is a decision. Every guard refusal (`_refuse`) answers with a
    /// perfectly well-formed JSON-RPC error body — a 415 carries `{"error": {"code": -32600, …}}` —
    /// so reading the body first would report a wrong Content-Type as an ordinary protocol error.
    /// It is not: the frame never reached the dispatcher, and the operator's fix is a header rather
    /// than a different call. The body is carried along because it says which of the six guards
    /// refused.
    public static func interpret<Payload: Decodable>(
        body: Data, response: URLResponse?, expectedID: Int?
    ) -> SubstrateCall<Payload> {
        if let http = response as? HTTPURLResponse, http.statusCode != 200 {
            return .transportFailure(.httpStatus(
                code: http.statusCode,
                body: String(data: body, encoding: .utf8) ?? "<\(body.count) bytes, not UTF-8>"
            ))
        }
        return interpret(frame: body, expectedID: expectedID)
    }

    /// One JSON-RPC frame's decision table. `static` and pure so the four outcomes can be exercised
    /// against the CAPTURED frames without a live socket.
    public static func interpret<Payload: Decodable>(
        frame: Data, expectedID: Int?
    ) -> SubstrateCall<Payload> {
        let envelope: RPCResponse
        do {
            envelope = try JSONDecoder().decode(RPCResponse.self, from: frame)
        } catch {
            return .transportFailure(.malformedResponse("\(error)"))
        }

        // The ERROR object is read before the result. A conformant server sends one or the other,
        // and preferring `result` would make a malformed both-fields frame read as a success.
        //
        // It is also read BEFORE the id check, and that ordering is deliberate: JSON-RPC gives an
        // error `id: null` when the frame was too broken to recover one, and the engine's
        // `_internal_error` says so explicitly. Requiring a matching id here would turn the most
        // informative failures into "malformed response".
        if let rpcError = envelope.error {
            return .rpcError(code: rpcError.code, message: rpcError.message)
        }

        guard let result = envelope.result else {
            return .transportFailure(.malformedResponse("neither `result` nor `error` is present"))
        }

        // A JSON-RPC client matches a response to a pending request BY ID; the engine's own
        // `_internal_error` says so and goes to some length to carry the id through. An answer to a
        // different request is not this call's answer.
        if let expectedID, envelope.id != expectedID {
            let got = envelope.id.map(String.init) ?? "null"
            return .transportFailure(.malformedResponse(
                "id \(got) does not match the request id \(expectedID)"))
        }

        guard let text = result.content?.first(where: { $0.text != nil })?.text else {
            return .transportFailure(.malformedResponse("`result` carries no text content"))
        }

        // MCP omits `isError` on success, so absent means "not a fault" — and that default is safe
        // here rather than a `?? false` inverting a signal: were a server ever to report a fault by
        // omitting it, the fault sentence would not decode as `Payload` and the call would come
        // back as `.undecodablePayload`, which is loud. The false-clean reading is unreachable.
        if result.isError == true {
            return .toolFault(text)
        }

        guard let payloadData = text.data(using: .utf8) else {
            return .transportFailure(.malformedResponse("the tool's text is not UTF-8"))
        }
        do {
            return .ok(try JSONDecoder().decode(Payload.self, from: payloadData))
        } catch {
            return .transportFailure(.undecodablePayload("\(error)"))
        }
    }

    // MARK: Frames

    private struct RPCRequest<Arguments: Encodable>: Encodable {
        let jsonrpc = "2.0"
        let id: Int
        let method = "tools/call"
        let params: Params

        init(id: Int, tool: String, arguments: Arguments) {
            self.id = id
            self.params = Params(name: tool, arguments: arguments)
        }

        struct Params: Encodable {
            let name: String
            let arguments: Arguments
        }
    }

    public struct RPCResponse: Decodable, Sendable {
        public let id: Int?
        public let error: RPCError?
        public let result: ToolResult?

        enum CodingKeys: String, CodingKey { case id, error, result }

        public init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            // The id can legitimately be null (a batch, or a frame too broken to parse), and
            // JSON-RPC also permits a string. Only the Int form is ever sent back to us, so
            // anything else decodes as "no id" rather than failing the whole frame.
            id = try? c.decodeIfPresent(Int.self, forKey: .id)
            error = try c.decodeIfPresent(RPCError.self, forKey: .error)
            result = try c.decodeIfPresent(ToolResult.self, forKey: .result)
        }
    }

    public struct RPCError: Decodable, Equatable, Sendable {
        public let code: Int
        public let message: String
    }

    public struct ToolResult: Decodable, Sendable {
        public let content: [ContentBlock]?
        public let isError: Bool?
    }

    public struct ContentBlock: Decodable, Sendable {
        public let type: String?
        public let text: String?
    }
}
