import Darwin
import Foundation

/// The engine socket's old path, kept reachable for clients registered before it moved.
///
/// Through 0.3.4 the engine listened at `~/Library/Application Support/Scripta/engine/substrate.sock`,
/// and Help registered every MCP client with that path spelled out (`--connect <path>`). The engine
/// now listens in its own home, `~/.substrate/run/substrate.sock`, and knows nothing about this app.
/// So the compatibility belongs here: the old path becomes a symlink to the new one, and every
/// registration keeps working without the user re-adding it.
///
/// The clients registered with the old path are `substrate-mcp --connect <old path>` bridges, and
/// their trust checks still hold through the link. They check the 0700 folder holding the link
/// (this app's own, never created or repaired here), follow ONE absolute level of link, check the
/// engine's directory it points into, and read the peer uid off whatever answers
/// (`local_socket._through_link`). This app's own client uses the new path and never the link.
///
/// DOWNGRADE IS NOT SUPPORTED. An engine from 0.3.4 started on the old path refuses to replace
/// anything that is not a socket, so it cannot start over the link. The remedy is to delete
/// `~/Library/Application Support/Scripta/engine/substrate.sock`.
public enum LegacyEngineSocket {
    public enum Outcome: Equatable, Sendable {
        /// The link is in place, already or now.
        case linked
        /// The old folder does not exist, so no client can have been registered against it.
        case noLegacyFolder
        /// The old path is in use: an engine on it holds its lock or answers (one started by hand
        /// with `--socket <old path>`), or another instance of this app is linking it right now.
        /// It is left alone.
        case liveListener
        /// The old path holds something that is neither a socket nor a link, and is left alone.
        case foreignFile
        /// A step failed, with errno's description.
        case failed(String)
    }

    /// The path every client registered before the move holds.
    public static var legacyPath: String {
        NSHomeDirectory() + "/Library/Application Support/Scripta/engine/substrate.sock"
    }

    /// Beside every engine socket, the lock its engine holds for life (`local_socket.claim`).
    /// `LegacyEngineSocketTests` holds this spelling to the engine's.
    public static let lockSuffix = ".lock"

    /// Make `legacy` a symlink to `target`, unless doing so would take the path from something
    /// that is still using it. Idempotent: once linked it is one `lstat` and one `readlink`.
    public static func link(legacy: String = legacyPath, to target: String) -> Outcome {
        // A link to itself would leave a path no engine can bind and no client can reach.
        guard (legacy as NSString).standardizingPath != (target as NSString).standardizingPath else {
            return .failed("the old socket path is the engine's socket path; nothing to link")
        }
        let folder = (legacy as NSString).deletingLastPathComponent
        var dir = stat()
        guard lstat(folder, &dir) == 0, (dir.st_mode & S_IFMT) == S_IFDIR else {
            return .noLegacyFolder
        }
        if isLink(legacy, to: target) { return .linked }
        // THE ENGINE'S LOCK DECIDES, as it does in `local_socket.claim`: an engine holds it beside
        // its socket for its whole life, and a live engine whose backlog is full refuses a
        // connection exactly like a leftover does. It is taken (created if absent) BEFORE the path
        // is read, and held until the link is in place, so no engine can claim the path in
        // between. The connection probe stays, for a listener outside that protocol, and it also
        // covers a link someone pointed at another live engine.
        let lock = open(legacy + lockSuffix, O_RDWR | O_CREAT | O_NOFOLLOW | O_CLOEXEC, 0o600)
        guard lock >= 0 else {
            let code = errno
            return .failed("open \(legacy + lockSuffix): \(String(cString: strerror(code)))")
        }
        defer { close(lock) }
        guard flock(lock, LOCK_EX | LOCK_NB) == 0 else {
            let code = errno
            if code == EWOULDBLOCK { return .liveListener }
            return .failed("flock \(legacy + lockSuffix): \(String(cString: strerror(code)))")
        }
        var st = stat()
        if lstat(legacy, &st) == 0 {
            switch st.st_mode & S_IFMT {
            case S_IFLNK:
                if isLink(legacy, to: target) { return .linked }
            case S_IFSOCK:
                break
            default:
                return .foreignFile
            }
            if answers(legacy) { return .liveListener }
            if unlink(legacy) != 0 {
                let code = errno
                if code != ENOENT {
                    return .failed("unlink \(legacy): \(String(cString: strerror(code)))")
                }
            }
        }
        guard symlink(target, legacy) == 0 else {
            let code = errno
            // Another instance of the app linked it first.
            if code == EEXIST, isLink(legacy, to: target) { return .linked }
            return .failed("symlink \(legacy): \(String(cString: strerror(code)))")
        }
        return .linked
    }

    /// Compared as paths, not strings, so a target spelled with `//` or `..` still counts.
    private static func isLink(_ path: String, to target: String) -> Bool {
        guard let points = try? FileManager.default.destinationOfSymbolicLink(atPath: path) else {
            return false
        }
        return (points as NSString).standardizingPath == (target as NSString).standardizingPath
    }

    /// Whether anything accepts a connection on `path`. Nothing is written to it. A probe that
    /// cannot be made at all answers YES: an unknown is never a reason to take a path.
    static func answers(_ path: String) -> Bool {
        let fd = socket(AF_UNIX, SOCK_STREAM, 0)
        guard fd >= 0 else { return true }
        defer { close(fd) }
        var address = sockaddr_un()
        address.sun_len = UInt8(MemoryLayout<sockaddr_un>.size)
        address.sun_family = sa_family_t(AF_UNIX)
        let bytes = Array(path.utf8)
        let capacity = MemoryLayout.size(ofValue: address.sun_path)
        guard bytes.count < capacity else { return true }
        withUnsafeMutableBytes(of: &address.sun_path) { raw in
            raw.copyBytes(from: bytes)
        }
        return withUnsafePointer(to: &address) {
            $0.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                connect(fd, $0, socklen_t(MemoryLayout<sockaddr_un>.size)) == 0
            }
        }
    }
}
