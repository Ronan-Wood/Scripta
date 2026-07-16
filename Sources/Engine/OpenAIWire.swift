import Foundation

/// Hand-rolled OpenAI-wire-format client for a user-run local server (Ollama / LM Studio / MLX).
/// No SDK, no vendor-specific fields. Enforces locality on every request and rejects any redirect
/// that would leave the configured host.
final class OpenAIWire: NSObject, URLSessionTaskDelegate {
    typealias Message = [String: String]   // {"role": ..., "content": ...}

    let baseURL: URL
    let lanConfirmed: Bool
    private lazy var session = URLSession(configuration: .ephemeral, delegate: self, delegateQueue: nil)

    init(baseURL: URL, lanConfirmed: Bool) {
        self.baseURL = baseURL
        self.lanConfirmed = lanConfirmed
    }

    private func endpoint(_ path: String) throws -> URL {
        guard Locality.isAllowedForRequest(baseURL, lanConfirmed: lanConfirmed) else {
            throw EngineError.refusedHost(baseURL.host ?? "?")
        }
        return baseURL.appendingPathComponent(path)
    }

    /// Drop any redirect that changes host — a local server must never bounce us off-box.
    func urlSession(_ session: URLSession, task: URLSessionTask,
                    willPerformHTTPRedirection response: HTTPURLResponse, newRequest request: URLRequest,
                    completionHandler: @escaping (URLRequest?) -> Void) {
        completionHandler(request.url?.host == baseURL.host ? request : nil)
    }

    // MARK: - Models (health)

    func models(timeout: TimeInterval = 2) async throws -> [String] {
        var req = URLRequest(url: try endpoint("models"))
        req.timeoutInterval = timeout
        let (data, resp) = try await session.data(for: req)
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
            let (data, resp) = try await session.data(for: req)
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
            Task {
                do {
                    var req = URLRequest(url: try endpoint("chat/completions"))
                    req.httpMethod = "POST"
                    req.timeoutInterval = timeout
                    req.setValue("application/json", forHTTPHeaderField: "Content-Type")
                    req.httpBody = body(model: model, messages: messages, stream: true, jsonMode: false)
                    let (bytes, resp) = try await session.bytes(for: req)
                    guard let http = resp as? HTTPURLResponse else { throw EngineError.badResponse }
                    guard http.statusCode == 200 else { throw EngineError.http(http.statusCode) }
                    var accumulated = ""
                    for try await line in bytes.lines {
                        guard line.hasPrefix("data:") else { continue }
                        let payload = line.dropFirst(5).trimmingCharacters(in: .whitespaces)
                        if payload == "[DONE]" { break }
                        if let delta = Self.delta(payload) { accumulated += delta; continuation.yield(accumulated) }
                    }
                    continuation.finish()
                } catch {
                    continuation.finish(throwing: error)
                }
            }
        }
    }

    private static func delta(_ json: String) -> String? {
        struct Chunk: Decodable { struct C: Decodable { struct D: Decodable { let content: String? }; let delta: D }; let choices: [C] }
        guard let data = json.data(using: .utf8), let chunk = try? JSONDecoder().decode(Chunk.self, from: data) else { return nil }
        return chunk.choices.first?.delta.content
    }

    // MARK: - Embeddings (Phase B)

    func embeddings(model: String, input: [String], timeout: TimeInterval = 30) async throws -> [[Float]] {
        var req = URLRequest(url: try endpoint("embeddings"))
        req.httpMethod = "POST"
        req.timeoutInterval = timeout
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = try? JSONSerialization.data(withJSONObject: ["model": model, "input": input])
        let (data, resp) = try await session.data(for: req)
        guard let http = resp as? HTTPURLResponse else { throw EngineError.badResponse }
        guard http.statusCode == 200 else { throw EngineError.http(http.statusCode) }
        struct Resp: Decodable { struct E: Decodable { let embedding: [Float] }; let data: [E] }
        guard let r = try? JSONDecoder().decode(Resp.self, from: data) else { throw EngineError.badResponse }
        return r.data.map(\.embedding)
    }
}
