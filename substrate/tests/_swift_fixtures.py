"""What every test that captures a SubstrateKit golden frame shares: the folder, the shape check, the
leak scans and the all-or-nothing write.

Two tests capture frames into `contract/frames/` — `test_swift_golden_frames` (the demo vaults over
a real registry) and `test_agent_mode` (agent mode's published snapshot). The folder is the
engine's: it is the contract a client is tested against, so it lives beside the code that emits it
and the suite needs nothing outside this tree. A client vendors a byte-identical copy of the folder
and holds its copy to this one.
They held copies of these helpers, and the copies drifted: one shape check compared only the first
element of each list, and one leak scan lost its non-vacuity check. One copy cannot drift from
itself.

The repo is public, so every frame is scanned twice: once in capture mode before anything is
written, and again on every ordinary run, against the bytes already on disk.
"""

from __future__ import annotations

import json
import os
import re
from collections.abc import Callable, Iterable
from pathlib import Path

ENGINE_ROOT = Path(__file__).resolve().parents[1]
SWIFT_FIXTURES = ENGINE_ROOT / "contract" / "frames"
CAPTURE_ENV = "SUBSTRATE_CAPTURE_SWIFT_FIXTURES"

# Substrings no fixture may hold, scanned over the RAW text: a path-token scan reads a decoded
# payload, and its lookbehind cannot see a path glued to a scheme or a key (`file:///…`, `key:/…`).
HOST_STRINGS = ("/Users/", "OneDrive", "CloudStorage", "/var/folders", "/private/var")

PATH_TOKEN = re.compile(r"(?<![\w.-])/[\w.~-]+(?:/[\w.~-]+)*")
# The model daemon's address is the engine's default, not a path on this machine, and its `//` — or
# an endpoint after it, `/api/embed` — would otherwise read as one. The WHOLE loopback http(s) URL is
# removed, path included; a `file://` URL, or any other host's, is still scanned.
# The path part takes URL-path characters only, so a separator (`;`, `,`, `=`, `|`, `}`) ends the
# URL and a path glued on after one — `…/api/embed;db=/srv/x` — is still scanned.
_LOOPBACK_URL = re.compile(
    r"https?://(?:127\.0\.0\.1|localhost|\[::1\])(?::\d+)?(?:/[\w./%~-]*)?")


def capturing() -> bool:
    return os.environ.get(CAPTURE_ENV) == "1"


def shape(value):
    """Every key, and which values are null — every element of every list, not the first."""
    if isinstance(value, dict):
        return {k: shape(v) for k, v in value.items()}
    if isinstance(value, list):
        return [shape(v) for v in value]
    return "null" if value is None else type(value).__name__


def strings(value):
    """Every key and string value, decoded — so an escaped newline cannot hide a path. A string
    that is itself JSON (an MCP frame's `content[].text`) is yielded and then decoded in turn, so
    the scan reaches the strings inside it rather than their escaped spelling."""
    if isinstance(value, dict):
        for k, v in value.items():
            yield from strings(k)
            yield from strings(v)
    elif isinstance(value, list):
        for v in value:
            yield from strings(v)
    elif isinstance(value, str):
        yield value
        stripped = value.lstrip()
        if stripped[:1] in ("{", "["):
            try:
                nested = json.loads(value)
            except (ValueError, RecursionError):
                return
            yield from strings(nested)


def leaked_paths(payload, stand_in: str | tuple[str, ...], *,
                 require_paths: bool = True) -> list[str]:
    """Every path-shaped token in every key and value — prose included, so a path an engine message
    embeds mid-sentence is caught as surely as one in a `db` field — that is not the stand-in.

    `require_paths=False` only for a payload that names no path by design (a tool fault's sentence,
    a JSON-RPC error): everywhere else, finding none means the scan could not have failed. Several
    stand-ins may be named, for a scan over files written by different captures."""
    paths = [p for s in strings(payload) for p in PATH_TOKEN.findall(_LOOPBACK_URL.sub(" ", s))]
    if require_paths:
        assert paths, "no path at all: the scan would pass vacuously"
    allowed = (stand_in,) if isinstance(stand_in, str) else tuple(stand_in)
    return [p for p in paths
            if not any(p == a or (p.startswith(a + "/") and "/.." not in p) for a in allowed)]


def host_strings(text: str, *, also: Iterable[Path] = ()) -> list[str]:
    """Which of this machine's tells the raw text holds: the fixed list, the home folder, and any
    folder the caller names (its temp folder, the repo). The root is skipped; every path holds it."""
    found = [s for s in HOST_STRINGS if s in text]
    for local in (Path.home(), *also):
        if str(local) != "/" and str(local) in text:
            found.append(str(local))
    return found


def check_before_write(bodies: dict[str, str], *, payload_of: Callable[[str], object],
                       stand_in: str, local: Iterable[Path] = (),
                       no_path: Iterable[str] = ()) -> None:
    """Every body scanned before ANY is written, so a leak in one frame never leaves the frames
    before it overwritten and the set mixed."""
    local, no_path = list(local), set(no_path)
    for name, body in bodies.items():
        assert not (found := host_strings(body, also=local)), f"{name} would carry {found}"
        assert not (leaked := leaked_paths(payload_of(body), stand_in,
                                           require_paths=name not in no_path)), (
            f"{name} would carry {leaked}")


def write_all(bodies: dict[str, str]) -> None:
    """Write the already-checked bodies, refusing before the first write if any target, or the
    folder, is a symlink."""
    assert SWIFT_FIXTURES.resolve() == SWIFT_FIXTURES, "the fixture folder is a symlink"
    targets = {name: SWIFT_FIXTURES / name for name in bodies}
    for target in targets.values():
        assert not target.is_symlink(), f"{target} is a symlink; refusing to write through it"
    for name, body in bodies.items():
        targets[name].write_text(body, encoding="utf-8")


def assert_clean_folder(stand_ins: tuple[str, ...]) -> None:
    """Every file in the folder, not only the frames a capture writes: a hand-kept body (the HTTP
    415 refusal) or a file someone dropped in would otherwise never be scanned at all.

    Finder's `.DS_Store` and AppleDouble `._*` metadata are skipped; any other dotfile is scanned.
    Each is read as bytes and decoded with replacement, so a binary file is scanned rather than
    crashing the scan. Every `*.json` file also gets the path scan, over every decoded string in
    it, allowing only the stand-ins the captures write."""
    files = sorted(p for p in SWIFT_FIXTURES.iterdir()
                   if p.is_file() and p.name != ".DS_Store" and not p.name.startswith("._"))
    assert files, f"no fixtures under {SWIFT_FIXTURES.name}: the scan would pass vacuously"
    for path in files:
        text = path.read_bytes().decode("utf-8", errors="replace")
        assert not (found := host_strings(text)), f"{path.name} carries {found}"
        if path.suffix == ".json":
            assert not (leaked := leaked_paths(json.loads(text), stand_ins,
                                               require_paths=False)), (
                f"{path.name} carries a path other than {', '.join(stand_ins)}: {leaked}")


# "No id was expected", distinct from a JSON-RPC `null` id, which is a real value to compare.
NO_ID = object()


def assert_matches(name: str, fresh_payload, *, payload_of: Callable[[str], object],
                   stand_in: str, require_paths: bool = True,
                   expected_id: object = NO_ID) -> None:
    """The committed fixture is clean, answers the request it was captured for, and has the shape
    the engine emits now."""
    path = SWIFT_FIXTURES / name
    assert path.is_file(), f"{name} missing — recapture with {CAPTURE_ENV}=1"
    text = path.read_text(encoding="utf-8")
    if expected_id is not NO_ID:
        frame = json.loads(text)
        assert "id" in frame, f"{name} carries no JSON-RPC id"
        assert frame["id"] == expected_id, (
            f"{name} answers id {frame['id']!r}; its call sends {expected_id!r}")
    assert not (found := host_strings(text)), f"{name} carries {found}"
    captured = payload_of(text)
    assert not (leaked := leaked_paths(captured, stand_in, require_paths=require_paths)), (
        f"{name} carries a path other than {stand_in}: {leaked}")
    assert shape(captured) == shape(fresh_payload), (
        f"{name} no longer matches what the engine sends — recapture it with {CAPTURE_ENV}=1 and "
        f"re-run the Swift decoder tests")
