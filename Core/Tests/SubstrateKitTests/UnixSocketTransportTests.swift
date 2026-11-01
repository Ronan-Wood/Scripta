import Foundation
import XCTest
@testable import SubstrateKit

/// The client trusts only this user's engine, and decides that before it sends a byte.
///
/// Every test here fails against the URLSession-on-loopback-TCP client this replaced. That client
/// had no directory to check and no peer to identify, so it sent every query to whoever held port
/// 8765 and relayed the answer as vault content.
///
/// Another uid cannot be produced without root, so the peer check is exercised by injecting a
/// `peerUID` that reports one. `getpeereid` itself is exercised by every other test, against a real
/// listener that is this user.
final class UnixSocketTransportTests: XCTestCase {

    private struct Echo: Decodable, Equatable { let answer: Int }

    private static let okReply: Data = {
        let text = #"{\"answer\": 42}"#
        let frame = #"{"jsonrpc":"2.0","id":1,"result":{"content":[{"type":"text","text":"\#(text)"}]}}"#
        return httpReply(status: "200 OK", body: Data(frame.utf8))
    }()

    private static func httpReply(status: String, body: Data) -> Data {
        var data = Data("HTTP/1.1 \(status)\r\nContent-Type: application/json\r\nContent-Length: \(body.count)\r\n\r\n".utf8)
        data.append(body)
        return data
    }

    private func makeClient(_ listener: TestListener, peerUID: uid_t? = nil,
                        timeout: TimeInterval = 5) -> SubstrateClient {
        var trust = UnixSocketHTTP.Trust()
        if let peerUID { trust.peerUID = { _ in peerUID } }
        return SubstrateClient(socketPath: listener.path, timeout: timeout, trust: trust)
    }

    func testAnEngineOnAPrivateSocketAnswers() async throws {
        let listener = try TestListener(reply: Self.okReply)
        let call: SubstrateCall<Echo> = await makeClient(listener).call(tool: "status",
                                                                    arguments: SubstrateNoArguments())
        XCTAssertEqual(call.payloadIfOK, Echo(answer: 42), "\(call)")
        let request = String(decoding: listener.received(), as: UTF8.self)
        // The three headers the engine's `_guarded()` requires.
        XCTAssertTrue(request.hasPrefix("POST / HTTP/1.1\r\n"), request)
        XCTAssertTrue(request.contains("\r\nHost: localhost\r\n"), request)
        XCTAssertTrue(request.contains("\r\nContent-Type: application/json\r\n"), request)
        XCTAssertFalse(request.lowercased().contains("origin:"), request)
        XCTAssertTrue(request.contains(#""method":"tools\/call""#)
                      || request.contains(#""method":"tools/call""#), request)
    }

    func testAListenerOfAnotherUIDIsSentNothing() async throws {
        let listener = try TestListener(reply: Self.okReply)
        let call: SubstrateCall<Echo> = await makeClient(listener, peerUID: geteuid() + 1)
            .call(tool: "search", arguments: SubstrateSearchRequest(scope: "atlas",
                                                                   query: "the private question"))
        guard case .transportFailure(.untrusted(let why)) = call else {
            return XCTFail("expected .untrusted, got \(call)")
        }
        XCTAssertTrue(why.contains("uid \(geteuid() + 1)"), why)
        XCTAssertTrue(listener.waitForAccept(), "the client never connected, so nothing was checked")
        XCTAssertTrue(listener.waitForFinish())
        XCTAssertEqual(listener.received(), Data(),
                       "the query reached a listener that is not this user")
    }

    func testALooseDirectoryIsRefusedBeforeConnecting() async throws {
        let listener = try TestListener(reply: Self.okReply, directoryMode: 0o755)
        let call: SubstrateCall<Echo> = await makeClient(listener).call(tool: "status",
                                                                    arguments: SubstrateNoArguments())
        guard case .transportFailure(.untrusted(let why)) = call else {
            return XCTFail("expected .untrusted, got \(call)")
        }
        XCTAssertTrue(why.contains("must be 700"), why)
        XCTAssertFalse(listener.waitForAccept(timeout: 0.5))
    }

    func testASymlinkedDirectoryIsRefusedNotFollowed() async throws {
        let listener = try TestListener(reply: Self.okReply)
        let link = listener.directory + "-link"
        XCTAssertEqual(symlink(listener.directory, link), 0)
        defer { unlink(link) }
        let viaLink = SubstrateClient(socketPath: link + "/s.sock", timeout: 5)
        let call: SubstrateCall<Echo> = await viaLink.call(tool: "status",
                                                           arguments: SubstrateNoArguments())
        guard case .transportFailure(.untrusted(let why)) = call else {
            return XCTFail("expected .untrusted, got \(call)")
        }
        XCTAssertTrue(why.contains("symlink"), why)
        XCTAssertFalse(listener.waitForAccept(timeout: 0.5))
    }

    /// No engine is the ordinary state while Scripta is starting. It must read as "start it", the
    /// code `VaultRefusal` maps to `.engineDown`, and not as a hostile listener.
    func testNoListenerAndAStaleSocketAreBothEngineDown() async throws {
        let listener = try TestListener(reply: Self.okReply)
        listener.close()   // A crashed engine's socket file: present, nothing accepting on it.
        let stale: SubstrateCall<Echo> = await makeClient(listener).call(
            tool: "status", arguments: SubstrateNoArguments())
        guard case .transportFailure(.unreachable(_, let code)) = stale else {
            return XCTFail("expected .unreachable, got \(stale)")
        }
        XCTAssertEqual(code, .cannotConnectToHost)

        unlink(listener.path)
        let missing: SubstrateCall<Echo> = await makeClient(listener).call(
            tool: "status", arguments: SubstrateNoArguments())
        guard case .transportFailure(.unreachable(_, let missingCode)) = missing else {
            return XCTFail("expected .unreachable, got \(missing)")
        }
        XCTAssertEqual(missingCode, .cannotConnectToHost)
    }

    func testAnOverlongPathIsRefused() async {
        let path = "/tmp/" + String(repeating: "x", count: 120) + "/s.sock"
        let call: SubstrateCall<Echo> = await SubstrateClient(socketPath: path, timeout: 5)
            .call(tool: "status", arguments: SubstrateNoArguments())
        guard case .transportFailure(.unreachable(_, let code)) = call else {
            return XCTFail("expected .unreachable, got \(call)")
        }
        XCTAssertEqual(code, .badURL)
    }

    func testAReplyThatIsNotHTTPIsMalformed() async throws {
        let listener = try TestListener(reply: Data("hello there\r\n\r\n".utf8))
        let call: SubstrateCall<Echo> = await makeClient(listener).call(tool: "status",
                                                                    arguments: SubstrateNoArguments())
        guard case .transportFailure(.malformedResponse) = call else {
            return XCTFail("expected .malformedResponse, got \(call)")
        }
        // The request DID reach this listener. Only `.untrusted` means nothing was sent, which is
        // why the app words `aStranger` and `untrusted` differently.
        XCTAssertTrue(listener.waitForFinish())
        XCTAssertFalse(listener.received().isEmpty)
    }

    func testANonOKStatusCarriesItsBody() async throws {
        let body = Data(#"{"jsonrpc":"2.0","id":null,"error":{"code":-32600,"message":"no"}}"#.utf8)
        let listener = try TestListener(reply: Self.httpReply(status: "415 Unsupported", body: body))
        let call: SubstrateCall<Echo> = await makeClient(listener).call(tool: "status",
                                                                    arguments: SubstrateNoArguments())
        guard case .transportFailure(.httpStatus(415, let text)) = call else {
            return XCTFail("expected .httpStatus(415), got \(call)")
        }
        XCTAssertTrue(text.contains("-32600"), text)
    }

    /// A blocked read is woken by cancellation and reported as one, not as a dead engine.
    func testCancellingAHungCallReportsCancellation() async throws {
        let listener = try TestListener(reply: nil)
        let client = makeClient(listener, timeout: 30)
        let task = Task { () -> SubstrateCall<Echo> in
            await client.call(tool: "status", arguments: SubstrateNoArguments())
        }
        XCTAssertTrue(listener.waitForAccept())
        task.cancel()
        let started = Date()
        let call = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "cancellation did not wake the read")
        guard case .transportFailure(let failure) = call, failure.isCancellation else {
            return XCTFail("expected a cancellation, got \(call)")
        }
    }

    /// A cancel that lands before `connect` shuts down a socket that is not connected, which
    /// does nothing. Without a check after the connect, the query still went out and the read
    /// blocked for the whole timeout.
    func testACancelBeforeConnectIsNotLost() async throws {
        let listener = try TestListener(reply: nil)
        let reachedConnect = DispatchSemaphore(value: 0)
        let cancelled = DispatchSemaphore(value: 0)
        var trust = UnixSocketHTTP.Trust()
        trust.beforeConnect = {
            reachedConnect.signal()
            _ = cancelled.wait(timeout: .now() + 5)
        }
        let client = SubstrateClient(socketPath: listener.path, timeout: 30, trust: trust)
        let task = Task { () -> SubstrateCall<Echo> in
            await client.call(tool: "search", arguments: SubstrateSearchRequest(
                scope: "atlas", query: "asked, then abandoned"))
        }
        XCTAssertEqual(reachedConnect.wait(timeout: .now() + 5), .success)
        task.cancel()   // runs the cancellation handler before it returns
        cancelled.signal()
        let started = Date()
        let call = await task.value
        XCTAssertLessThan(Date().timeIntervalSince(started), 5, "the cancel was lost")
        guard case .transportFailure(let failure) = call, failure.isCancellation else {
            return XCTFail("expected a cancellation, got \(call)")
        }
        if listener.waitForAccept(timeout: 1) { XCTAssertTrue(listener.waitForFinish()) }
        XCTAssertEqual(listener.received(), Data(), "a cancelled query was still sent")
    }
}

/// One AF_UNIX listener in a fresh directory under /tmp, accepting ONE connection. It records what
/// the client wrote, and then writes `reply` once a whole request has arrived. A nil reply never
/// answers.
private final class TestListener: @unchecked Sendable {
    let directory: String
    let path: String
    private var fd: Int32
    private let lock = NSLock()
    private var bytes = Data()
    private let accepted = DispatchSemaphore(value: 0)
    private let finished = DispatchSemaphore(value: 0)

    init(reply: Data?, directoryMode: mode_t = 0o700) throws {
        var template = Array("/tmp/sk-XXXXXX".utf8CString)
        guard let made = mkdtemp(&template) else { throw POSIXError(.EIO) }
        directory = String(cString: made)
        path = directory + "/s.sock"
        chmod(directory, directoryMode)

        fd = socket(AF_UNIX, SOCK_STREAM, 0)
        // On the LISTENING socket, so every accepted one inherits it. A client that refused this
        // listener has hung up before the reply is written, and SIGPIPE would kill the test
        // process. Set on the accepted socket instead, it did not take once the peer had closed.
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let pathBytes = Array(path.utf8)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        let bound = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                bind(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard bound == 0, listen(fd, 4) == 0 else { throw POSIXError(.EADDRINUSE) }

        let listening = fd
        Thread.detachNewThread { [self] in
            let conn = accept(listening, nil, nil)
            guard conn >= 0 else { return }
            accepted.signal()
            defer { finished.signal() }
            var tv = timeval(tv_sec: 2, tv_usec: 0)
            setsockopt(conn, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
            var chunk = [UInt8](repeating: 0, count: 65536)
            while true {
                let n = chunk.withUnsafeMutableBytes { recv(conn, $0.baseAddress, $0.count, 0) }
                if n <= 0 { break }
                lock.lock()
                bytes.append(contentsOf: chunk[0..<n])
                let complete = Self.isComplete(bytes)
                lock.unlock()
                if complete { break }
            }
            if let reply {
                _ = reply.withUnsafeBytes { send(conn, $0.baseAddress, $0.count, 0) }
                Darwin.close(conn)
            } else {
                // Hold the connection open, unanswered, until the client gives up.
                _ = chunk.withUnsafeMutableBytes { recv(conn, $0.baseAddress, $0.count, 0) }
                Darwin.close(conn)
            }
        }
    }

    private static func isComplete(_ data: Data) -> Bool {
        guard let end = data.range(of: Data("\r\n\r\n".utf8)),
              let head = String(data: data[..<end.lowerBound], encoding: .utf8) else { return false }
        let length = head.components(separatedBy: "\r\n")
            .first { $0.lowercased().hasPrefix("content-length:") }
            .flatMap { Int($0.split(separator: ":")[1].trimmingCharacters(in: .whitespaces)) } ?? 0
        return data.count - end.upperBound >= length
    }

    func received() -> Data {
        lock.lock()
        defer { lock.unlock() }
        return bytes
    }

    /// The one connection has been read to its end and closed, so `received()` is final.
    func waitForFinish(timeout: TimeInterval = 5) -> Bool {
        finished.wait(timeout: .now() + timeout) == .success
    }

    func waitForAccept(timeout: TimeInterval = 5) -> Bool {
        accepted.wait(timeout: .now() + timeout) == .success
    }

    /// Stop listening and leave the socket file behind, as a crashed engine does.
    func close() {
        if fd >= 0 { Darwin.close(fd) }
        fd = -1
    }

    deinit {
        close()
        unlink(path)
        rmdir(directory)
    }
}
