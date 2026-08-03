#!/usr/bin/env python3
"""The deployment record — written by `substrate-deploy`, checked by `substrate-refresh`.

    deployment.py --manifest <engine-root>     emit the manifest for a tree (deploy writes it)
    deployment.py --sign <manifest-file>       the signature that goes in the record
    deployment.py --verify <record-file>       prove a deployment, or refuse and say why

WHY THIS EXISTS. `com.ronanwood.substrate-refresh` execs the repo WORKING TREE every 900 seconds,
and on 2026-08-03 an UNCOMMITTED v8->v9 schema bump reached all six live scopes inside one tick.
`b334da4` caught that specific shape — a schema mismatch now REFUSES to recompose — and its own
message named what it did not fix: no separation between the code being edited and the code running
against real data. A chunker change, an `ingest` change, a `classes.py` change: none of them bump
the schema, all of them rewrite stored content, and none would have been caught.

THE OPTION TAKEN, AND THE TWO THAT WERE NOT.

  Refuse on a DIRTY tree. Total, and one line. But this operator edits this tree most days, so the
  refresh would be off most days and all six scopes would sit at `frozen: null`. A guard that is
  usually tripped is a guard that gets commented out — and this one would be tripped by editing
  HANDOFF.md.

  Refuse when the running code differs from what is COMMITTED. Narrower, and it does close
  2026-08-03. But it makes `git commit` the deployment action, and the log here is a working branch
  taking several commits a day. `git commit -m "wip: v9 schema"` and then waiting fifteen minutes
  reproduces the incident exactly, past a guard reporting everything clean. It closes the incident
  and leaves the hazard, which is what `b334da4` already did.

  A PINNED DEPLOYMENT — this. The engine that runs is an export of ONE COMMIT at
  `~/.substrate/engine`, made by an explicit `substrate-deploy`. Editing the tree cannot change it;
  committing cannot change it; only deploying can. That is the separation, and it is the only one
  of the three that keeps the refresh RUNNING while the engine is being worked on — which is what
  stops the guard from being disabled.

  The cost is real and it is stated: a second copy (2.4MB, 128 files) and a step to remember. The
  cost falls in the SAFE direction. A pin nobody updated keeps running the last engine the operator
  blessed, which is the state every scope is already in; forgetting to deploy loses a fix, never an
  index. That asymmetry is why the deploy step is explicit and never automatic.

WHAT A DEPLOYMENT IS. A directory of files, plus a manifest naming every one of them with its
sha256, plus a record naming the manifest and its signature. Verification re-hashes every listed
file, so a deployment that was clobbered, half-written, or hand-edited after the fact is refused
rather than run. It is deliberately NOT a git checkout: `git archive` output has no `.git`, so
nothing in it can be moved by a `git checkout` in a nearby shell, and `git` is not on the PATH
launchd hands the agent anyway.

Verification covers the MANIFEST, not the whole directory, and that is the reason the manifest
exists at all rather than one hash over the tree: `uv run` creates `.venv/` and Python creates
`__pycache__/` INSIDE the deployed tree after the deploy, so a whole-tree hash would refuse every
tick after the first. Files added under the engine root after deployment are therefore not seen.
They are also not reachable — every deployed file is verified, and a verified file cannot import a
module that did not exist when it was hashed.

RUNS ON THE PYTHON LAUNCHD HAS. `/usr/bin/python3` is 3.9 on this machine and that is what the
agent gets; no third-party imports, no 3.10+ syntax at runtime.
"""

from __future__ import annotations

import hashlib
import json
import os
import stat
import sys
from pathlib import Path

RECORD_VERSION = 1

# Both files are read on a path that must not be able to hang or blow up on a hostile shape. The
# record is ~400 bytes and the manifest is one line per deployed file; these caps are ~100x each.
MAX_RECORD_BYTES = 1 << 16
MAX_MANIFEST_BYTES = 1 << 22

# A manifest that does not cover these does not describe a substrate engine, whatever else is in
# it. Checked so that a record pointed at some unrelated directory is refused with THAT reason
# rather than with a per-file hash mismatch that reads like corruption.
REQUIRED_PATHS = ("substrate/cli.py", "pyproject.toml", "uv.lock")

# Every field the record must carry as a non-empty single-line string. `version` is checked apart
# because it is an int; everything else is a path, a commit or a hash.
_STR_FIELDS = ("commit", "deployed_at", "engine_root", "source_repo", "data_root", "uv",
               "manifest", "signature")

# Enough to see the shape of a broken deployment without pasting a hundred lines into a log file
# that is read by tailing it.
_MAX_REPORTED = 5

_DIGEST_CHARS = 64
_SEP = "  "  # sha256sum's framing, so the file is readable by `shasum -c` as well as by this


class Refused(RuntimeError):
    """The deployment cannot be verified. One line, naming the reason — never a guessed value.

    The caller is a shell script whose only alternative to a verified answer is to refuse the whole
    tick, so a partial or best-guess result here is strictly worse than no result: it would put the
    working tree back on the live indexes with a verification step in front of it saying otherwise.
    """


def _read_regular(path: Path, cap: int, what: str) -> bytes:
    """Read a file that must be a regular file, bounded. Raises Refused, never OSError.

    Opened `O_NONBLOCK` and `S_ISREG`-checked ON THE DESCRIPTOR rather than stat-then-open: a FIFO
    left where the record belongs would otherwise block the open forever, and a refresh agent that
    hangs is the one failure mode worse than one that refuses — launchd will not start the next
    tick while the previous one is alive, so every scope silently keeps its last outcome.
    """
    try:
        fd = os.open(str(path), os.O_RDONLY | os.O_NONBLOCK)
    except OSError as e:
        raise Refused(f"the {what} at {path} could not be opened ({type(e).__name__})") from e
    try:
        if not stat.S_ISREG(os.fstat(fd).st_mode):
            raise Refused(f"the {what} at {path} is not a regular file")
        data = os.read(fd, cap + 1)
    except OSError as e:
        raise Refused(f"the {what} at {path} could not be read ({type(e).__name__})") from e
    finally:
        os.close(fd)
    if len(data) > cap:
        raise Refused(f"the {what} at {path} exceeds {cap} bytes")
    return data


def _sha256_file(path: Path) -> str:
    h = hashlib.sha256()
    with path.open("rb") as fh:
        while True:
            block = fh.read(1 << 20)
            if not block:
                break
            h.update(block)
    return h.hexdigest()


# ------------------------------------------------------------------ writing the manifest

def manifest_lines(root: Path) -> list[str]:
    """`<sha256>  <relative path>` for every regular file under `root`, sorted by path.

    Sorted by the ENCODED path so the ordering is a property of the bytes rather than of the
    locale, and so a re-run over an unchanged tree produces a byte-identical file — the signature
    is over this stream, and an ordering that could vary would make a stable deployment look
    tampered with on the next tick.

    Symlinks are refused rather than followed. A followed symlink hashes its target, so a deployed
    tree could pass verification while the bytes that actually get imported live somewhere nobody
    recorded — which is the hazard this whole file exists to close, reintroduced one indirection
    down. This repo has none; the refusal is here so that adding one is a deploy-time error and
    not a silent hole.
    """
    rows = []
    for path in sorted(root.rglob("*"), key=lambda p: str(p.relative_to(root)).encode("utf-8")):
        if path.is_symlink():
            raise Refused(f"{path.relative_to(root)} is a symlink; a deployment must be plain "
                          "files, so that what is hashed is what gets imported")
        if not path.is_file():
            continue
        rel = str(path.relative_to(root))
        # The framing is `<64 hex><two spaces><path><newline>`, which is injective only if the path
        # carries neither a newline nor a leading space. Refused rather than escaped: this tree is
        # `git archive` output, so a name that needs escaping is a surprise worth stopping on.
        if "\n" in rel or "\\" in rel or rel.startswith(" "):
            raise Refused(f"{rel!r} cannot be framed in a manifest line")
        rows.append(_sha256_file(path) + _SEP + rel)
    if not rows:
        raise Refused(f"{root} holds no files — refusing to sign an empty deployment")
    return rows


# ------------------------------------------------------------------ reading it back

def _parse_manifest(body: bytes) -> list[tuple[str, str]]:
    try:
        text = body.decode("utf-8")
    except UnicodeDecodeError as e:
        raise Refused("the deployment manifest is not UTF-8") from e
    out = []
    for n, line in enumerate(text.splitlines(), 1):
        if not line:
            continue
        if len(line) <= _DIGEST_CHARS + len(_SEP) or line[_DIGEST_CHARS:_DIGEST_CHARS + 2] != _SEP:
            raise Refused(f"manifest line {n} is not '<sha256>  <path>'")
        digest, rel = line[:_DIGEST_CHARS], line[_DIGEST_CHARS + 2:]
        if len(digest.strip("0123456789abcdef")) or "\\" in rel or rel.startswith((" ", "/")):
            raise Refused(f"manifest line {n} is malformed")
        # `..` is refused rather than resolved. A manifest entry that climbs out of the engine root
        # would have verification hashing a file the deployment does not contain and reporting the
        # tree clean on the strength of it.
        if ".." in Path(rel).parts:
            raise Refused(f"manifest line {n} names a path outside the deployment: {rel!r}")
        out.append((digest, rel))
    if not out:
        raise Refused("the deployment manifest is empty")
    return out


def verify(record_path: Path) -> dict:
    """Everything the agent needs to run the deployed engine, or Refused with the reason.

    ORDER IS DELIBERATE: the shape of the record, then the SEPARATION invariant, then the files.
    The separation check comes before the expensive hashing because it is the one that can fail
    while everything hashes perfectly — a record whose `engine_root` is the working tree describes
    a verifiable, self-consistent, completely pointless deployment.
    """
    # The bootstrap case gets its own sentence rather than arriving as an errno. "Nothing is
    # deployed" and "the deployment is broken" want different first moves from the reader, and a
    # FileNotFoundError on a path they have never heard of reads as the second.
    if not record_path.exists():
        raise Refused(f"nothing is deployed — there is no record at {record_path}. Run "
                      "tools/substrate-deploy from the repo to publish an engine.")
    rec_raw = _read_regular(record_path, MAX_RECORD_BYTES, "deployment record")
    try:
        rec = json.loads(rec_raw.decode("utf-8"))
    except Exception as e:  # noqa: BLE001 — any parse failure is one refusal with one reason
        raise Refused(f"the deployment record at {record_path} is not readable JSON "
                      f"({type(e).__name__})") from e
    if not isinstance(rec, dict):
        raise Refused(f"the deployment record at {record_path} is not an object")
    if rec.get("version") != RECORD_VERSION:
        raise Refused(f"deployment record version {rec.get('version')!r}, expected "
                      f"{RECORD_VERSION} — written by a substrate-deploy this agent does not know")

    vals = {}
    for field in _STR_FIELDS:
        v = rec.get(field)
        if not isinstance(v, str) or not v or v.strip() != v or "\n" in v:
            raise Refused(f"deployment record field {field!r} is missing or unusable")
        vals[field] = v

    engine, source, data = (Path(vals[k]) for k in ("engine_root", "source_repo", "data_root"))
    for name, p in (("engine_root", engine), ("source_repo", source), ("data_root", data)):
        if not p.is_absolute():
            raise Refused(f"{name} is not an absolute path: {p}")
    engine, source = engine.resolve(), source.resolve()

    # THE INVARIANT, stated as code because it is the whole point of the mechanism. A deployment
    # inside the tree the operator edits is not a deployment; it is the 2026-08-03 configuration
    # with a verification step in front of it, which is worse than no verification step because it
    # reports clean. `.git` is checked for the same reason one indirection over: a git checkout can
    # be moved to another commit by anything that runs `git checkout` with that directory as cwd,
    # which makes the pin a suggestion.
    if engine == source or _is_within(engine, source):
        raise Refused(f"engine_root {engine} is inside the source repo {source} — a deployment "
                      "inside the tree being edited is not a deployment")
    if (engine / ".git").exists():
        raise Refused(f"{engine} is a git checkout; a deployment must be an export, so that "
                      "nothing can move it to another commit behind the agent's back")
    if not engine.is_dir():
        raise Refused(f"engine_root {engine} is not a directory — nothing is deployed")
    if not data.is_dir():
        raise Refused(f"data_root {data} is not a directory; refusing to compose into a path that "
                      "does not exist, which would build six indexes somewhere nobody reads")
    uv = Path(vals["uv"])
    if not (uv.is_file() and os.access(str(uv), os.X_OK)):
        raise Refused(f"uv {uv} is missing or not executable — the deployed engine cannot be run")

    manifest = Path(vals["manifest"])
    if not manifest.is_absolute():
        manifest = record_path.parent / manifest
    body = _read_regular(manifest, MAX_MANIFEST_BYTES, "deployment manifest")
    if hashlib.sha256(body).hexdigest() != vals["signature"]:
        raise Refused(f"the manifest at {manifest} does not match the signature in the record — "
                      "one of the two was replaced without the other")

    entries = _parse_manifest(body)
    covered = {rel for _, rel in entries}
    absent = [r for r in REQUIRED_PATHS if r not in covered]
    if absent:
        raise Refused(f"the manifest does not cover {absent} — this record does not describe a "
                      "substrate engine")

    bad = []
    for digest, rel in entries:
        target = engine / rel
        try:
            if not target.is_file():
                bad.append(rel + ": missing")
            elif _sha256_file(target) != digest:
                bad.append(rel + ": changed since deployment")
        except OSError as e:
            bad.append(f"{rel}: unreadable ({type(e).__name__})")
        if len(bad) >= _MAX_REPORTED:
            break
    if bad:
        raise Refused("the deployed engine does not match its manifest [" + "; ".join(bad) +
                      "] — re-run substrate-deploy; the tick is refused rather than run against "
                      "code nobody deployed")

    return {"ENGINE": str(engine), "DATA": str(data), "UV": str(uv),
            "COMMIT": vals["commit"], "DEPLOYED_AT": vals["deployed_at"]}


def _is_within(child: Path, parent: Path) -> bool:
    try:
        child.relative_to(parent)
    except ValueError:
        return False
    return True


# ------------------------------------------------------------------ CLI

_EMIT_ORDER = ("ENGINE", "DATA", "UV", "COMMIT", "DEPLOYED_AT")


def main(argv: list[str]) -> int:
    if len(argv) != 3 or argv[1] not in ("--manifest", "--sign", "--verify"):
        print("usage: deployment.py (--manifest <root> | --sign <file> | --verify <record>)",
              file=sys.stderr)
        return 2
    mode, arg = argv[1], Path(argv[2]).expanduser()
    try:
        if mode == "--manifest":
            for line in manifest_lines(arg.resolve()):
                print(line)
            return 0
        if mode == "--sign":
            print(hashlib.sha256(_read_regular(arg, MAX_MANIFEST_BYTES, "manifest")).hexdigest())
            return 0
        plan = verify(arg)
    except Refused as e:
        # stderr, because the agent captures stdout as the verified plan and pipes stderr into its
        # own log. A reason on stdout would be parsed as a deployment.
        print(str(e), file=sys.stderr)
        return 1
    except OSError as e:
        print(f"the deployment could not be read ({type(e).__name__})", file=sys.stderr)
        return 1
    for key in _EMIT_ORDER:
        print(f"{key}={plan[key]}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main(sys.argv))
