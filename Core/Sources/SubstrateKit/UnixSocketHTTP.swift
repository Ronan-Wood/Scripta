import Foundation

// MARK: - One HTTP/1.1 exchange over a Unix-domain socket that only this user can own
//
// The engine used to listen on loopback TCP, and loopback authenticates nobody. Every user on the
// Mac could query every scope through it. While Scripta was closed, any process could bind the port
// and be sent every query, and its answers reached the reader as vault content. The engine now
// serves on a Unix socket in a 0700 directory (`substrate/substrate/local_socket.py`), and this
// side refuses anything that is not provably this user's, BEFORE a byte of the request is written:
//
//   the directory   lstat'd, not followed: a directory, owned by this uid, no group or other bits
//   the peer        `getpeereid` on the connected socket must name this uid
//
// POSIX SOCKETS, NOT Network.framework. `NWConnection` can reach an `NWEndpoint.unix` path, but it
// exposes no peer credentials, so it could check only the directory. URLSession cannot reach a Unix
// socket at all.
//
// Failures come back as `URLError`s with the codes URLSession used to produce, `.cannotConnectToHost`
// above all, because `VaultRefusal` and `isCancellation` already key off them. A listener that fails
// a check is `Untrusted`, a separate type, because "start the engine" is the wrong advice for it.

enum UnixSocketHTTP {

    /// `sun_path` is 104 bytes on Darwin, terminating NUL included.
    static let maxPathBytes = MemoryLayout.size(ofValue: sockaddr_un().sun_path) - 1

    /// A reply larger than this is not one the engine wrote. Every engine reply is a page of JSON.
    static let maxResponseBytes = 64 << 20
    static let maxHeaderBytes = 64 << 10

    /// Something is on the path, and it is not this user's engine. Nothing was sent to it.
    struct Untrusted: Error, CustomStringConvertible {
        let description: String
    }

    /// The far end answered with bytes that are not an HTTP response.
    struct Malformed: Error, CustomStringConvertible {
        let description: String
    }

    /// Who the far end has to be. Injected only by tests: another uid cannot be produced without
    /// root, so a test stands one in through `peerUID`.
    struct Trust: Sendable {
        var owner: uid_t = geteuid()
        var peerUID: @Sendable (Int32) -> uid_t? = { fd in
            var uid = uid_t()
            var gid = gid_t()
            return getpeereid(fd, &uid, &gid) == 0 ? uid : nil
        }
        /// Test seam: runs once the descriptor exists and before `connect`, the window in which a
        /// cancellation has no socket to shut down. Microseconds wide otherwise, so a test holds
        /// it open here.
        var beforeConnect: @Sendable () -> Void = {}
    }

    /// POST `body` to `/` on the socket at `path` and return the status and body. One connection
    /// per call, closed afterwards. `timeout` bounds each read and write, as URLSession's
    /// `timeoutIntervalForRequest` did. It is not a deadline on the whole call.
    static func post(path: String, body: Data, timeout: TimeInterval,
                     trust: Trust = Trust()) async throws -> (status: Int, body: Data) {
        let connection = Connection()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                // Off the cooperative pool: every call below blocks, for up to `timeout`.
                DispatchQueue.global(qos: .userInitiated).async {
                    continuation.resume(with: Result {
                        try exchange(path: path, body: body, timeout: timeout, trust: trust,
                                     connection: connection)
                    })
                }
            }
        } onCancel: {
            connection.cancel()
        }
    }

    // MARK: The exchange

    private static func exchange(path: String, body: Data, timeout: TimeInterval, trust: Trust,
                                 connection: Connection) throws -> (status: Int, body: Data) {
        let pathBytes = Array(path.utf8)
        guard pathBytes.count <= maxPathBytes else {
            throw URLError(.badURL, userInfo: [NSLocalizedDescriptionKey:
                "the engine's socket path is \(pathBytes.count) bytes, and a Unix socket path "
                + "may be at most \(maxPathBytes): \(path)"])
        }
        try checkDirectory((path as NSString).deletingLastPathComponent, owner: trust.owner)

        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { let code = errno; throw posix("socket", code) }
        guard connection.adopt(fd) else {
            Darwin.close(fd)
            throw URLError(.cancelled)
        }
        defer { connection.close() }
        do {
            return try converse(fd, path: path, body: body, timeout: timeout, trust: trust,
                                connection: connection)
        } catch {
            // Whatever the shutdown made the blocked call report (EOF, ENOTCONN, a short read),
            // a cancelled call is a cancellation.
            throw connection.isCancelled ? URLError(.cancelled) : error
        }
    }

    private static func converse(_ fd: Int32, path: String, body: Data, timeout: TimeInterval,
                                 trust: Trust,
                                 connection: Connection) throws -> (status: Int, body: Data) {
        let pathBytes = Array(path.utf8)
        var on: Int32 = 1
        setsockopt(fd, SOL_SOCKET, SO_NOSIGPIPE, &on, socklen_t(MemoryLayout<Int32>.size))
        var tv = timeval(tv_sec: Int(timeout), tv_usec: Int32((timeout - timeout.rounded(.down)) * 1e6))
        setsockopt(fd, SOL_SOCKET, SO_RCVTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))
        setsockopt(fd, SOL_SOCKET, SO_SNDTIMEO, &tv, socklen_t(MemoryLayout<timeval>.size))

        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: pathBytes)
            raw[pathBytes.count] = 0
        }
        trust.beforeConnect()
        let connected = withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                Darwin.connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size))
            }
        }
        guard connected == 0 else { let code = errno; throw posix("connect", code) }
        // A cancel that landed before this point shut down a socket that was not connected yet,
        // which Darwin ignores, and nothing after it would ever notice: the query would go out
        // and the read would block for the whole timeout. Under the same lock as `cancel`, so a
        // later cancel finds the socket connected and its shutdown takes effect.
        try connection.markConnected()

        // THE CHECK THAT MATTERS, and it runs before the first write. The query names a scope and
        // carries the reader's own words, so a request sent to the wrong process has already leaked.
        guard let peer = trust.peerUID(fd) else {
            throw Untrusted(description: "could not read the uid of the process listening on "
                            + "\(path), so it cannot be trusted")
        }
        guard peer == trust.owner else {
            throw Untrusted(description: "the process listening on \(path) runs as uid \(peer), "
                            + "not as this user (\(trust.owner))")
        }

        var request = Data((
            "POST / HTTP/1.1\r\n"
            + "Host: localhost\r\n"
            + "Content-Type: application/json\r\n"
            + "Content-Length: \(body.count)\r\n"
            + "Connection: close\r\n\r\n"
        ).utf8)
        request.append(body)
        try request.withUnsafeBytes { raw in
            var sent = 0
            while sent < raw.count {
                let n = Darwin.send(fd, raw.baseAddress! + sent, raw.count - sent, 0)
                if n < 0 {
                    let code = errno
                    if code == EINTR { continue }
                    throw posix("send", code)
                }
                sent += n
            }
        }
        return try readResponse(fd)
    }

    private static func checkDirectory(_ directory: String, owner: uid_t) throws {
        var st = stat()
        guard lstat(directory, &st) == 0 else {
            // No directory means no engine has served on this Mac, which is the state before
            // Scripta first starts one. It reads as "nothing is listening", not as a threat.
            let code = errno
            throw posix("lstat \(directory)", code)
        }
        guard st.st_mode & S_IFMT == S_IFDIR else {
            throw Untrusted(description: "\(directory) is not a directory (a symlink is refused, "
                            + "not followed)")
        }
        guard st.st_uid == owner else {
            throw Untrusted(description: "\(directory) is owned by uid \(st.st_uid), not by this "
                            + "user (\(owner))")
        }
        guard st.st_mode & 0o077 == 0 else {
            throw Untrusted(description: "\(directory) is mode \(String(st.st_mode & 0o777, radix: 8)); "
                            + "it must be 700 so no other user can reach or replace the socket")
        }
    }

    /// Headers up to the blank line, then exactly Content-Length bytes. The engine always sends
    /// Content-Length (its 202 carries `0`), so a reply without one is malformed rather than
    /// read to EOF.
    private static func readResponse(_ fd: Int32) throws -> (status: Int, body: Data) {
        var buffer = Data()
        let separator = Data("\r\n\r\n".utf8)
        var chunk = [UInt8](repeating: 0, count: 65536)

        func fill() throws -> Bool {
            let n = chunk.withUnsafeMutableBytes { Darwin.recv(fd, $0.baseAddress, $0.count, 0) }
            if n < 0 {
                let code = errno
                if code == EINTR { return true }
                throw posix("recv", code)
            }
            if n == 0 { return false }
            buffer.append(contentsOf: chunk[0..<n])
            return true
        }

        var headerEnd = buffer.range(of: separator)
        while headerEnd == nil {
            guard buffer.count <= maxHeaderBytes else {
                throw Malformed(description: "no end of headers within \(maxHeaderBytes) bytes")
            }
            guard try fill() else {
                if buffer.isEmpty {
                    throw URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey:
                        "the engine closed the connection without answering"])
                }
                throw Malformed(description: "the connection closed inside the headers")
            }
            headerEnd = buffer.range(of: separator)
        }
        guard let headerEnd,
              let head = String(data: buffer[..<headerEnd.lowerBound], encoding: .utf8) else {
            throw Malformed(description: "the headers are not UTF-8")
        }
        let lines = head.components(separatedBy: "\r\n")
        let statusParts = lines[0].split(separator: " ", maxSplits: 2)
        guard statusParts.count >= 2, statusParts[0].hasPrefix("HTTP/1."),
              let status = Int(statusParts[1]) else {
            throw Malformed(description: "not an HTTP status line: \(lines[0].prefix(80))")
        }
        let lengths = lines.dropFirst().compactMap { line -> String? in
            let pair = line.split(separator: ":", maxSplits: 1)
            guard pair.count == 2,
                  pair[0].trimmingCharacters(in: .whitespaces).lowercased() == "content-length"
            else { return nil }
            return pair[1].trimmingCharacters(in: .whitespaces)
        }
        guard lengths.count == 1, let length = Int(lengths[0]), length >= 0,
              lengths[0].allSatisfy(\.isASCII), lengths[0].allSatisfy(\.isNumber) else {
            throw Malformed(description: "expected exactly one numeric Content-Length, got "
                            + "\(lengths)")
        }
        guard length <= maxResponseBytes else {
            throw Malformed(description: "a \(length)-byte reply is over the \(maxResponseBytes) "
                            + "byte ceiling")
        }

        let bodyStart = headerEnd.upperBound
        while buffer.count - bodyStart < length {
            guard try fill() else {
                throw URLError(.networkConnectionLost, userInfo: [NSLocalizedDescriptionKey:
                    "the engine closed the connection after \(buffer.count - bodyStart) of "
                    + "\(length) body bytes"])
            }
        }
        return (status, Data(buffer[bodyStart..<(bodyStart + length)]))
    }

    /// The URLError URLSession would have reported for the same condition. Every caller reads
    /// `errno` into a local FIRST, on the line after the failing call: building this function's
    /// arguments (an interpolated path allocates) can run code that sets errno, and a missing
    /// directory read as anything but ENOENT turns "engine down" into a stranger on the socket.
    private static func posix(_ call: String, _ code: Int32) -> URLError {
        let what = "\(call): \(String(cString: strerror(code)))"
        let urlCode: URLError.Code
        switch code {
        case ENOENT, ECONNREFUSED, ENOTDIR: urlCode = .cannotConnectToHost
        case EAGAIN, ETIMEDOUT: urlCode = .timedOut
        case ECONNRESET, EPIPE, ENOTCONN, ESHUTDOWN: urlCode = .networkConnectionLost
        default: urlCode = .unknown
        }
        return URLError(urlCode, userInfo: [NSLocalizedDescriptionKey: what])
    }

    // MARK: Cancellation

    /// The descriptor, shared with the cancellation handler. `shutdown` wakes a blocked `recv` or
    /// `send`, and the lock keeps a cancel that lands after `close` from shutting down a descriptor
    /// number the process has already handed to someone else.
    final class Connection: @unchecked Sendable {
        private let lock = NSLock()
        private var fd: Int32 = -1
        private var cancelled = false

        func adopt(_ descriptor: Int32) -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !cancelled else { return false }
            fd = descriptor
            return true
        }

        func cancel() {
            lock.lock()
            defer { lock.unlock() }
            cancelled = true
            if fd >= 0 { Darwin.shutdown(fd, SHUT_RDWR) }
        }

        func close() {
            lock.lock()
            defer { lock.unlock() }
            if fd >= 0 { Darwin.close(fd) }
            fd = -1
        }

        func markConnected() throws {
            lock.lock()
            defer { lock.unlock() }
            if cancelled { throw URLError(.cancelled) }
        }

        var isCancelled: Bool {
            lock.lock()
            defer { lock.unlock() }
            return cancelled
        }
    }
}
