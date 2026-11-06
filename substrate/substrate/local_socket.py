"""The shared engine's socket: a Unix-domain path that only this user can reach, checked both ways.

Loopback TCP authenticates nobody. Any macOS user on the machine could connect to 127.0.0.1:8765
and query every scope, which undid the per-user scope restriction an agent account is given. And
while Scripta was closed, any local process could bind the port and receive every query a client
sent. It could also answer `list_scopes` with a matching registry, and its answers would then reach
the model as vault content.

A Unix socket under a 0700 directory moves that decision to the kernel. Another uid can neither
traverse the directory to connect nor create the path to squat on it. Two checks back the
permissions up, because a permission is only as good as whoever last ran chmod:

  * the CLIENT reads the server's uid off the connected socket (LOCAL_PEERCRED) and refuses a
    listener that is not this user, BEFORE it writes a byte of the request;
  * the SERVER reads every caller's uid the same way and drops one that is not this user.

There is no token and no key. A secret sent upstream is handed to whoever is listening, and the
squatter is exactly who that is. A challenge-response would rest on the same same-uid file
permissions as this does, with a protocol on top that has to be got right.

Stdlib only: `substrate-mcp --connect` imports this, and it is meant to hold nothing heavier.
"""

from __future__ import annotations

import errno
import fcntl
import http.client
import os
import socket
import stat
import struct
import sys
from pathlib import Path

# Where the shared engine listens: under the engine's own home (`scopes.engine_home()`), which an
# app hosting the engine reaches like any other client. It is not under any app's directory. One
# level down, because `~/.substrate` is 0755 and the socket needs a 0700 parent, which `claim`
# creates.
DEFAULT_SOCKET = "~/.substrate/run/substrate.sock"

# `sun_path` is 104 bytes on macOS (108 on Linux), and that includes the terminating NUL. A longer
# path is truncated by some callers and refused by others, so it is refused here, loudly, whichever
# side asks.
MAX_PATH_BYTES = 103

# <sys/un.h> and <sys/ucred.h>. Python exposes LOCAL_PEERCRED but not SOL_LOCAL, and both are
# fixed ABI values on Darwin.
_SOL_LOCAL = 0
_LOCAL_PEERCRED = getattr(socket, "LOCAL_PEERCRED", 1)
# struct xucred { u_int cr_version; uid_t cr_uid; short cr_ngroups; gid_t cr_groups[16]; }
_XUCRED = struct.Struct("=IIh2x16I")


class UntrustedSocket(OSError):
    """The path, its directory or the process on the far end is not this user's. Raised before any
    request byte is written, so nothing has reached whoever is listening."""


def default_path() -> Path:
    return Path(DEFAULT_SOCKET).expanduser()


def peer_uid(sock: socket.socket) -> int:
    """The uid of the process on the other end of a connected AF_UNIX socket, from the kernel."""
    if sys.platform == "darwin":
        raw = sock.getsockopt(_SOL_LOCAL, _LOCAL_PEERCRED, _XUCRED.size)
        return _XUCRED.unpack_from(raw)[1]
    if hasattr(socket, "SO_PEERCRED"):
        # struct ucred { pid_t pid; uid_t uid; gid_t gid; }
        raw = sock.getsockopt(socket.SOL_SOCKET, socket.SO_PEERCRED, struct.calcsize("3i"))
        return struct.unpack("3i", raw)[1]
    raise UntrustedSocket(f"cannot read a peer's credentials on {sys.platform}, so no peer on "
                          f"this socket can be trusted")


def check_length(path: Path) -> None:
    n = len(os.fsencode(str(path)))
    if n > MAX_PATH_BYTES:
        raise ValueError(f"socket path {str(path)!r} is {n} bytes; a Unix socket path may be at "
                         f"most {MAX_PATH_BYTES}")


def check_directory(directory: Path) -> None:
    """Refuse a socket directory another user could reach or write.

    lstat, not stat: a symlink is refused rather than followed. Following it would judge whatever
    the link points at, and the link itself can be swapped after the check.
    """
    st = os.lstat(directory)
    if not stat.S_ISDIR(st.st_mode):
        raise UntrustedSocket(f"{directory} is not a directory (a symlink is refused, not "
                              f"followed)")
    if st.st_uid != os.geteuid():
        raise UntrustedSocket(f"{directory} is owned by uid {st.st_uid}, not by this user "
                              f"({os.geteuid()})")
    if st.st_mode & 0o077:
        raise UntrustedSocket(f"{directory} is mode {stat.S_IMODE(st.st_mode):o}; it must be 700 "
                              f"so no other user can reach or replace the socket inside it")


def connect(path: Path, timeout: float | None) -> socket.socket:
    """A connected socket to this user's engine, or an exception. Nothing is written to it here.

    FileNotFoundError and ConnectionRefusedError both mean "no engine is serving", and callers treat
    them the same. UntrustedSocket means something IS there and it is not ours.

    A path that is a symlink is followed ONE level, and the directory it points into is checked
    too. That is how a client registered with a host app's old socket path reaches the engine's
    socket, through a link the host keeps there. Checking only the link's own directory would let a
    loosened engine directory pass for exactly those clients. Connecting to the checked target,
    rather than to the link again, means a link that was there at the check is never re-read. A
    link swapped in after the check is outside what this guards: only this uid can write inside a
    0700 directory, and the peer-uid check below still runs.
    """
    check_length(path)
    check_directory(path.parent)
    path = _through_link(path)
    sock = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        sock.settimeout(timeout)
        sock.connect(str(path))
        uid = peer_uid(sock)
        if uid != os.geteuid():
            raise UntrustedSocket(f"the process listening on {path} runs as uid {uid}, not as "
                                  f"this user ({os.geteuid()})")
    except BaseException:
        sock.close()
        raise
    return sock


def link_target(path: Path) -> Path | None:
    """The absolute path `path` links to, or None when it is not a link (or names nothing).
    Nothing is checked here: this says where an engine would have to listen, not whether to trust
    it."""
    try:
        if not stat.S_ISLNK(os.lstat(path).st_mode):
            return None
        target = Path(os.readlink(path))
    except OSError:
        return None
    return target if target.is_absolute() else None


def _through_link(path: Path) -> Path:
    """`path`, or the socket its symlink names once that target's directory has been checked."""
    try:
        if not stat.S_ISLNK(os.lstat(path).st_mode):
            return path
    except FileNotFoundError:
        return path
    try:
        target = Path(os.readlink(path))
    except OSError as e:
        # It was a link at the lstat. Connecting to `path` now would follow whatever replaced it,
        # unchecked.
        raise UntrustedSocket(f"{path} changed while it was being checked ({e})") from None
    if not target.is_absolute():
        raise UntrustedSocket(f"{path} is a symlink to a relative path ({target}); only an "
                              f"absolute target is followed")
    check_length(target)
    check_directory(target.parent)
    try:
        if stat.S_ISLNK(os.lstat(target).st_mode):
            raise UntrustedSocket(f"{path} links to {target}, which is itself a symlink; only one "
                                  f"level is followed")
    except FileNotFoundError:
        pass
    return target


def claim(path: Path) -> int:
    """Make `path` this engine's to bind, or refuse. Returns a lock descriptor the caller holds
    for as long as it serves, and closes to give the path up.

    The directory is created 0700 if missing, and refused, never repaired, if it already exists
    looser than that. While it was loose, another user could have planted something inside.

    THE LOCK IS WHAT DECIDES, not a probe. Every engine holds an exclusive lock beside the socket
    for its whole life, so failing to take it means another engine owns the path, and this one
    leaves it alone. Probing alone could not tell. A crashed engine's leftover and a live engine
    whose backlog is momentarily full both refuse a connection. And two engines starting together
    over a leftover could each see "stale", so the second unlinked the first's fresh socket and
    orphaned it: still running, never reachable again. Holding the lock, a leftover socket is
    removed. One that still ANSWERS is served by something outside this protocol, and is refused
    rather than stolen. Anything that is not a socket is left alone and refused.
    """
    check_length(path)
    directory = path.parent
    directory.parent.mkdir(parents=True, exist_ok=True)
    try:
        directory.mkdir(mode=0o700)
    except FileExistsError:
        pass
    check_directory(directory)
    lock = os.open(path.with_name(path.name + ".lock"),
                   os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW | os.O_CLOEXEC, 0o600)
    try:
        try:
            fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            raise OSError(errno.EADDRINUSE, f"an engine is already serving on {path}") from None
        _remove_leftover(path)
    except BaseException:
        os.close(lock)
        raise
    return lock


def _remove_leftover(path: Path) -> None:
    try:
        st = os.lstat(path)
    except FileNotFoundError:
        return
    if not stat.S_ISSOCK(st.st_mode):
        raise UntrustedSocket(f"{path} exists and is not a socket; refusing to replace it")
    probe = socket.socket(socket.AF_UNIX, socket.SOCK_STREAM)
    try:
        probe.settimeout(1.0)
        probe.connect(str(path))
    except (ConnectionRefusedError, FileNotFoundError):
        pass
    else:
        raise OSError(errno.EADDRINUSE, f"something already serves on {path}, outside the "
                                        f"engine lock; refusing to replace it")
    finally:
        probe.close()
    try:
        os.unlink(path)
    except FileNotFoundError:
        pass


class UnixHTTPConnection(http.client.HTTPConnection):
    """http.client framing over `connect()`. The Host header reads `localhost`, which is what the
    server's Host guard admits; nothing is resolved."""

    def __init__(self, path: Path, *, timeout: float) -> None:
        super().__init__("localhost", timeout=timeout)
        self.path = path

    def connect(self) -> None:
        self.sock = connect(self.path, self.timeout)


def post(path: Path, body: bytes, *, timeout: float) -> tuple[int, bytes]:
    """One JSON-RPC POST to the engine on `path`: (HTTP status, body), whatever the status.

    One connection per call. The server closes an idle connection after 30s, and a client's next
    call can come minutes later. Raises OSError (UntrustedSocket among them) or HTTPException.
    """
    conn = UnixHTTPConnection(path, timeout=timeout)
    try:
        conn.request("POST", "/", body=body, headers={"Content-Type": "application/json"})
        resp = conn.getresponse()
        return resp.status, resp.read()
    finally:
        conn.close()
