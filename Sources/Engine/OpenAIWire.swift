import Foundation

/// Hand-rolled OpenAI-wire-format client for a user-run local server (Ollama / LM Studio / MLX).
/// No SDK, no vendor-specific fields. Enforces locality on every request and rejects any redirect
/// that would leave the configured host.
final class OpenAIWire: NSObject, URLSessionTaskDelegate {
    typealias Message = [String: String]   // {"role": ..., "content": ...}

    let baseURL: URL
    let lanConfirmed: Bool
    private lazy var session: URLSession = {
        let config = URLSessionConfiguration.ephemeral
        // Hard wall-clock cap for a whole request/response — a connection-level backstop against a
        // server that stays alive but trickles forever. `req.timeoutInterval` only bounds IDLE time
        // between bytes (which a keepalive resets), so that alone can never terminate such a stream.
        // Generous, because memory is bounded independently below; this only kills stalled sockets.
        config.timeoutIntervalForResource = 900
        return URLSession(configuration: config, delegate: self, delegateQueue: nil)
    }()

    /// Streaming safety caps: a hostile/buggy local server could stream forever. A real chat answer
    /// is far smaller than either; hitting one aborts the stream rather than growing memory unbounded.
    /// `maxStreamBytes` bounds BOTH a single SSE line and the accumulated answer.
    private static let maxStreamBytes = 4 * 1024 * 1024
    private static let maxStreamChunks = 200_000
    /// Cap for a non-streaming response body. `data(for:)` buffers the whole body unbounded, so a
    /// hostile/buggy local server could OOM the app (audit L9).
    private static let maxResponseBytes = 32 * 1024 * 1024
    /// Embeddings responses are legitimately the largest (every chunk of a transcript, high-dim
    /// vectors as JSON), so they get a bigger ceiling so a real batch isn't rejected — still bounded.
    private static let maxEmbeddingsBytes = 128 * 1024 * 1024

    init(baseURL: URL, lanConfirmed: Bool) {
        self.baseURL = baseURL
        self.lanConfirmed = lanConfirmed
    }

    private func endpoint(_ path: String) throws -> URL {
        let host = baseURL.host ?? "?"
        guard Locality.isAllowedForRequest(baseURL, lanConfirmed: lanConfirmed) else {
            throw EngineError.refusedHost(host)
        }
        // Resolve-and-verify: a hostname (localhost, *.local) must resolve ONLY to local addresses,
        // so a name pointed at a public IP (static /etc/hosts, misconfig, naive spoof) is refused.
        // IP literals short-circuit (no DNS). Runs off the main actor inside the request Task.
        // (Residual: URLSession re-resolves at connect, so a name rebound between here and connect
        // isn't fully closed — see Locality; IP-literal and https configs are unaffected.)
        guard Locality.resolvedIsLocal(host: host) else {
            throw EngineError.refusedHost(host)
        }
        return baseURL.appendingPathComponent(path)
    }

    /// Reads a non-streaming response with a hard size cap so a hostile/buggy local server can't OOM
    /// the app — `session.data(for:)` buffers the whole body with no limit (audit L9).
    private func dataCapped(for req: URLRequest, max: Int = maxResponseBytes) async throws -> (Data, URLResponse) {
        let (bytes, resp) = try await session.bytes(for: req)
        // Reject a declared-oversized body up front; otherwise read into Data with a running cap so
        // a chunked/lying server can't push us past the ceiling either.
        if resp.expectedContentLength > Int64(max) { throw EngineError.responseTooLarge }
        var data = Data()
        data.reserveCapacity(64 * 1024)
        for try await b in bytes {
            data.append(b)
            if data.count > max { throw EngineError.responseTooLarge }
        }
        return (data, resp)
    }

    /// Drop any redirect that would leave the box. Re-applies the full locality gate to the redirect
    /// target — same string + resolved-address checks as the initial request — and keeps it pinned
    /// to the configured host, so a local server can't 302 us onto a public address.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        guard let url = request.url, let host = url.host, host == baseURL.host,
              Locality.isAllowedForRequest(url, lanConfirmed: lanConfirmed),
              Locality.resolvedIsLocal(host: host) else {
            completionHandler(nil); return
        }
        completionHandler(request)
    }

    // MARK: - Models (health)

    func models(timeout: TimeInterval = 2) async throws -> [String] {
        var req = URLRequest(url: try endpoint("models"))
        req.timeoutInterval = timeout
        let (data, resp) = try await dataCapped(for: req)
        guard let http = resp as? HTTPURLResponse else { throw EngineError.badResponse }
        guard http.statusCode == 200 else { throw EngineError.http(http.statusCode) }
        struct List: Decodable { struct M: Decodable { let id: String }; let data: [M] }
        guard let list = try? JSONDecoder().decode(List.self, from: data) else { throw EngineError.badResponse }
        return list.data.map(\.id)
    }

    // MARK: - Chat completions

    private func body(model: String, messages: [Message], stream: Bool, jsonMode: Bool) -> Data {
        var dict: [String: Any] = ["model": model, "messages": messages, "stream": stream]
        // json_object (not json_schema — servers disagree on the latter). Retried off on a 400.
        if jsonMode { dict["response_format"] = ["type": "json_object"] }
        return (try? JSONSerialization.data(withJSONObject: dict)) ?? Data()
    }

    private struct RetrySansJSON: Error {}

    /// Non-streaming completion (enrichment). Retries once without `response_format` on a 400 —
    /// some servers reject it.
    func complete(model: String, messages: [Message], jsonMode: Bool, timeout: TimeInterval) async throws -> String {
        func attempt(json: Bool) async throws -> String {
            var req = URLRequest(url: try endpoint("chat/completions"))
            req.httpMethod = "POST"
            req.timeoutInterval = timeout
            req.setValue("application/json", forHTTPHeaderField: "Content-Type")
            req.httpBody = body(model: model, messages: messages, stream: false, jsonMode: json)
            let (data, resp) = try await dataCapped(for: req)
            guard let http = resp as? HTTPURLResponse else { throw EngineError.badResponse }
            if http.statusCode == 400 && json { throw RetrySansJSON() }
            guard http.statusCode == 200 else { throw EngineError.http(http.statusCode) }
            struct Resp: Decodable { struct C: Decodable { struct M: Decodable { let content: String }; let message: M }; let choices: [C] }
            guard let r = try? JSONDecoder().decode(Resp.self, from: data), let text = r.choices.first?.message.content else {
                throw EngineError.badResponse
            }
            return text
        }
        do { return try await attempt(json: jsonMode) }
        catch is RetrySansJSON { return try await attempt(json: false) }
    }

    /// Streaming completion (Ask). Yields the cumulative answer as SSE deltas arrive. A generous
    /// timeout covers a cold model load on the server (that's the feature working, not a hang).
    func stream(model: String, messages: [Message], timeout: TimeInterval = 60) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                do {
                    var req = URLRequest(url: try endpoint("chat/completions"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = timeout
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = body(model: model, messages: messages, stream: true, jsonMode: false)
                    let (bytes, resp) = try await session.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw EngineError.badResponse }
                    guard http.statusCode == 200 else { throw EngineError.http(http.statusCode) }
                    // Parse SSE from the RAW byte stream (not bytes.lines): a single un-terminated
                    // line can't then buffer without bound — each line and the running answer are
                    // both capped, so a hostile/slow server can't grow memory even within the 900s.
                    var accumulated = ""
                    var accumBytes = 0
                    var chunks = 0
                    var lineBuf = [UInt8]()
                    loop: for try await byte in bytes {
                        if byte != 0x0A {                              // not "\n": keep buffering the line
                            if byte != 0x0D { lineBuf.append(byte) }   // ignore "\r"
                            guard lineBuf.count <= Self.maxStreamBytes else { throw EngineError.responseTooLarge }
                            continue
                        }
                        defer { lineBuf.removeAll(keepingCapacity: true) }
                        guard let line = String(bytes: lineBuf, encoding: .utf8), line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break loop }
                        if let delta = Self.delta(String(payload)) {
                            accumulated += delta
                            accumBytes += delta.utf8.count
                            chunks += 1
                            guard accumBytes <= Self.maxStreamBytes, chunks <= Self.maxStreamChunks else {
                                throw EngineError.responseTooLarge
                            }
                            continuation.yield(accumulated)
                        }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            // Consumer stopped iterating (e.g. the user switched conversation) → cancel the in-flight
            // request instead of leaking the connection until it finishes on its own (audit L10).
            continuation.onTermination = { @Sendable _ in task.cancel() }
        }
    }

    private static func delta(_ json: String) -> String? {
        struct Chunk: Decodable { struct C: Decodable { struct D: Decodable { let content: String? }; let delta: D }; let choices: [C] }
        guard let data = json.data(using: .utf8), let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { return nil }
        return chunk.choices.first?.delta.content
    }

    // MARK: - Vision (screen captioning)

    /// Captions an image with a local vision model (e.g. qwen2.5vl). OpenAI multimodal wire format:
    /// a message whose content is [text, image_url(data URI)]. Non-streaming.
    func caption(model: String, imageData: Data, prompt: String, timeout: TimeInterval = 90) async throws -> String {
        let dataURI = "data:image/png;base64,\(imageData.base64EncodedString())"
        let messages: [[String: Any]] = [[
            "role": "user",
            "content": [
                ["type": "text", "text": prompt],
                ["type": "image_url", "image_url": ["url": dataURI]],
            ],
        ]]
        var req = URLRequest(url: try endpoint("chat/completions"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "messages": messages, "stream": false])
        let (data, resp) = try await dataCapped(for: req)
        guard let http = resp as? HTTPURLResponse else { throw EngineError.badResponse }
        guard http.statusCode == 200 else { throw EngineError.http(http.statusCode) }
        struct Resp: Decodable { struct C: Decodable { struct M: Decodable { let content: String }; let message: M }; let choices: [C] }
        guard let r = try? JSONDecoder().decode(Resp.self, from: data), let text = r.choices.first?.message.content else {
            throw EngineError.badResponse
        }
        return text
    }

    // MARK: - Embeddings (Phase B)

    func embeddings(model: String, input: [String], timeout: TimeInterval = 30) async throws -> [[Float]] {
        var req = URLRequest(url: try endpoint("embeddings"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "input": input])
        let (data, resp) = try await dataCapped(for: req, max: Self.maxEmbeddingsBytes)
        guard let http = resp as? HTTPURLResponse else { throw EngineError.badResponse }
        guard http.statusCode == 200 else { throw EngineError.http(http.statusCode) }
        struct Resp: Decodable { struct E: Decodable { let embedding: [Float] }; let data: [E] }
        guard let r = try? JSONDecoder().decode(Resp.self, from: data) else { throw EngineError.badResponse }
        return r.data.map(\.embedding)
    }
}
