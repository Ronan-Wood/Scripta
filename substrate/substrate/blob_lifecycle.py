"""Which notes name which originals, and the operator's three store operations built on that.

A blob is referenced by THREE frontmatter keys, one more than `source-blob-store-proposal` lists:
`source_sha256` (the one original a derived note came from), `audio_sha256` (the call recording a
transcript's retention window keeps) and `raw_sha256`, Doc 2 §3b's pointer from a reference
source's `_meta.md` to its raw artifact, which predates the store and names exactly the same kind
of thing. Leaving it out would let `gc` remove the only copy of a hand-built source's PDF.

`gc` is the only one of these that deletes, so it is the one that refuses on incomplete knowledge:
an unreadable vault, a chain whose inherited vaults cannot be resolved, or a reference it cannot
parse would each make a held blob look unreferenced, and deleting on that would be silent loss.

**References are read by a scan deliberately LOOSER than the note reader.** The reader decides
what a note means for retrieval, and it drops a whole frontmatter block over one line it does not
recognise — a YAML block list, which is how Obsidian's Properties editor writes `tags`. Letting
that rule decide liveness would let an Obsidian edit make a note's original collectable. So any
line, anywhere in a note, that starts with a referencing key keeps every checksum on it (and on the
`- item` lines under it) alive; a BOM, quoted keys and repeated keys all count. Only inside the
leading `---` block is a value that is not a checksum an error, because only there is it a claim.

**The universe is the registry**, which `compose` rebuilds one scope at a time and calls safe to
delete. A plan therefore lists the vaults it read, and `gc` never removes a blob stored or found
present within `MIN_AGE_DAYS`: an ingest stores its original before the app promotes the note that
names it, and a fresh blob is exactly what that window looks like.

Plans are confirmed by token. `plan_token` hashes the plan itself — store, registry, vaults read
and what would change — so `--confirm` runs only the operation the operator was shown. It proves
that the plan is unchanged, NOT that a person read it, which is enough for an operator's CLI and is
why `gc` and `adopt` must never be exposed through MCP with it (compare `notes.py`, whose token is
a single-use nonce for exactly that reason).
"""

from __future__ import annotations

import errno
import hashlib
import json
import os
import re
import time
from dataclasses import dataclass, field, replace
from pathlib import Path

from substrate import blobs, scopes
from substrate import vault as _vault
from substrate.freshness import read_bounded

ORIGINAL_KEYS = ("source_sha256", "raw_sha256")
REF_KEYS = (*ORIGINAL_KEYS, "audio_sha256")
MIN_AGE_DAYS = 7
_MAX_NOTE = 8 * 1024 * 1024
_KEY_LINE = re.compile(r"""^\s*["']?(source_sha256|raw_sha256|audio_sha256)["']?\s*:(.*)$""")
# Anywhere in the text, a key followed by a checksum: inline mappings (`{source_sha256: …}`) and
# whatever other shape a writer produces. Keeps alive; never judged malformed.
_INLINE = re.compile(
    r"""(?:source_sha256|raw_sha256|audio_sha256)["']?\s*:\s*\[?\s*["']?([0-9a-fA-F]{64})""")
_FIELD = r"""^\s*["']?{key}["']?\s*:\s*(.*?)\s*$"""
_ITEM_LINE = re.compile(r"^\s*-(?:\s+(.*?))?\s*$")
_HEX = re.compile(r"[0-9a-fA-F]{64}")
_EMPTY = {"", "[]", "~", "null", "''", '""'}


@dataclass(frozen=True)
class Ref:
    note: Path
    key: str
    # Where the original was last known to be: `source_path`, or for `raw_sha256` the `_meta.md`'s
    # `raw_location`/`raw` when they name a file. Only a hint for `adopt` and `status`.
    hint: str | None


@dataclass
class Scan:
    refs: dict[str, list[Ref]] = field(default_factory=dict)
    vaults: list[Path] = field(default_factory=list)
    registry: str = ""
    # Each a human-readable line. Any of them makes the scan INCOMPLETE.
    errors: list[str] = field(default_factory=list)
    malformed: list[str] = field(default_factory=list)

    @property
    def complete(self) -> bool:
        return bool(self.vaults) and not self.errors and not self.malformed

    def checksums(self, keys: tuple[str, ...] = REF_KEYS) -> set[str]:
        return {c for c, rs in self.refs.items() if any(r.key in keys for r in rs)}


def _strip(v: str) -> str:
    return v.strip().strip("'\"").strip()


def _field(lines: list[str], key: str) -> str | None:
    pat = re.compile(_FIELD.format(key=re.escape(key)))
    for line in lines:
        if m := pat.match(line):
            return _strip(m.group(1)) or None
    return None


def _hint(key: str, block: list[str]) -> str | None:
    """An absolute path to the file the original was last known as, or None. A relative one would
    mean something different from every working directory, and a folder is not the file."""
    if key != "raw_sha256":
        hint = _field(block, "source_path")
    else:
        loc, raw = _field(block, "raw_location"), _field(block, "raw")
        # Joined unless `raw_location` IS the file: a folder that is unmounted right now is not a
        # directory to `isdir`, and the hint must not change with what happens to be mounted.
        is_file = loc and os.path.isfile(os.path.expanduser(loc))
        hint = str(Path(loc, raw)) if loc and raw and not is_file else loc
    if not hint:
        return None
    path = Path(os.path.expanduser(hint))
    return str(path) if path.is_absolute() and not path.is_dir() else None


def _decodings(data: bytes) -> list[str]:
    """A note's text, decoded every way it plausibly could be. References are kept from all of them,
    and a malformed one in any decoding that finds a frontmatter block is reported: a wrong
    decoding finds no `---` block at all, so it cannot raise a false one.

    A BOM settles it. Without one, NUL bytes mean either a wide encoding saved without a BOM — read
    as UTF-8, every character interleaves with NULs and every reference vanishes — or a UTF-8 note
    with a stray NUL, which a wide decode would turn to mojibake. Guessing either way loses one of
    the two, so both are read. Undecodable bytes become replacement characters: a checksum is ASCII,
    and one stray byte must not block `gc`."""
    for bom, encoding in ((b"\xff\xfe\x00\x00", "utf-32"), (b"\x00\x00\xfe\xff", "utf-32"),
                          (b"\xff\xfe", "utf-16"), (b"\xfe\xff", "utf-16")):
        if data.startswith(bom):
            return [data.decode(encoding, errors="replace").lstrip("\ufeff")]
    texts = [data.decode("utf-8", errors="replace").lstrip("\ufeff")]
    if b"\x00" in data:
        texts += [data.decode(e, errors="replace")
                  for e in ("utf-16-le", "utf-16-be", "utf-32-le", "utf-32-be")]
    return texts


def _note_refs(path: Path, scan: Scan) -> None:
    try:
        data = read_bounded(path, _MAX_NOTE)
    except OSError as e:
        scan.errors.append(f"{path}: {e.strerror or e}")
        return
    for text in _decodings(data):
        _text_refs(path, text, scan)


def _text_refs(path: Path, text: str, scan: Scan) -> None:
    """References in one decoding of a note."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    end = None
    if lines and lines[0].strip() == "---":
        end = next((i for i in range(1, len(lines)) if lines[i].strip() in ("---", "...")), None)
    block = lines[1:end] if end else []
    i = 0
    while i < len(lines):
        m = _KEY_LINE.match(lines[i])
        if not m:
            i += 1
            continue
        key, value, in_block = m.group(1), m.group(2).strip(), end is not None and i < end
        if _strip(value) in _EMPTY:
            items, j = [], i + 1
            while j < len(lines) and (im := _ITEM_LINE.match(lines[j])):
                items.append(_strip(im.group(1) or ""))
                j += 1
            raw = " ".join(items)
        else:
            j, raw = i + 1, value
            # A flow list a YAML dumper wrapped: two 64-character checksums exceed its 80 columns.
            while raw.startswith("[") and "]" not in raw and j < len(lines):
                raw += " " + lines[j].strip()
                j += 1
            inner = raw[1:raw.index("]")] if raw.startswith("[") and "]" in raw else raw
            items = [_strip(e) for e in inner.split(",") if e.strip()]
        if in_block and items:
            bad = [e for e in items if not blobs.is_checksum(e)]
            if bad or (key != "audio_sha256" and len(items) > 1):
                scan.malformed.append(f"{path}: {key} {raw!r} is not "
                                      + ("a list of checksums" if key == "audio_sha256"
                                         else "one checksum"))
        hint = _hint(key, block)
        for c in _HEX.findall(raw):
            scan.refs.setdefault(c.lower(), []).append(Ref(path, key, hint))
        i = j
    for c in _INLINE.findall(text):
        scan.refs.setdefault(c.lower(), []).append(Ref(path, "inline", None))


def _walk(vault: Path, scan: Scan) -> None:
    """Every `.md` under `vault`, archived, superseded, template and hidden folders included: a
    reference anywhere keeps a blob alive. Directory links are followed once each, so a vault built
    from links is read whole and a link cycle ends."""
    seen: set[tuple[int, int]] = set()

    def record(e: OSError) -> None:
        scan.errors.append(f"{e.filename or vault}: {e.strerror or e}")

    for dirpath, dirnames, filenames in os.walk(vault, followlinks=True, onerror=record):
        try:
            st = os.stat(dirpath)
        except OSError as e:
            record(e)
            dirnames[:] = []
            continue
        if (st.st_dev, st.st_ino) in seen:
            dirnames[:] = []
            continue
        seen.add((st.st_dev, st.st_ino))
        for name in filenames:
            p = Path(dirpath, name)
            lower = name.lower()
            if lower.endswith(".md.icloud"):
                # Evicted by iCloud: the note exists, its text is not on this Mac.
                scan.errors.append(f"{p}: an evicted iCloud note; download it to read its references")
            elif os.path.islink(p) and not os.path.exists(p):
                # `os.walk` lists a link it cannot resolve as a file, whether it pointed at a note or
                # at a whole folder of them. Either way something is unread.
                try:
                    os.stat(p)
                    why = "a link that cannot be followed"
                except OSError as e:
                    why = ("a link whose target is not there (unmounted or moved?)"
                           if e.errno == errno.ENOENT else
                           f"a link that cannot be followed ({e.strerror or e})")
                scan.errors.append(f"{p}: {why}")
            elif lower.endswith(".md"):
                _note_refs(p, scan)


def scan(registry: str | Path | None = None) -> Scan:
    """Every reference in every registered vault, and everything that stopped one being read.

    Each scope's chain is resolved STRICTLY. `scopes.registered_vaults` falls back to a best-effort
    chain that silently skips an inherited vault it cannot find — right for the protections it
    serves, and exactly wrong here, where a moved core vault would make all of its references
    vanish. The best-effort chain is still read, so `status` and `adopt` see what they can."""
    out = Scan(registry=str(scopes.registry_path(registry)))
    try:
        entries = scopes.load(registry)
    except scopes.ScopeError as e:
        out.errors.append(str(e))
        return out
    for entry in entries.values():
        try:
            chain = [v.path for v in _vault.resolve_vaults(entry.vault)]
        except (_vault.VaultError, OSError, RuntimeError, ValueError) as e:
            out.errors.append(f"scope {entry.name}: its vaults cannot all be resolved ({e})")
            try:
                chain = list(_vault.chain_best_effort(entry.vault))
            except (_vault.VaultError, OSError, ValueError):
                chain = [entry.vault]
        for v in chain:
            real = Path(os.path.realpath(v))
            if real in out.vaults:
                continue
            out.vaults.append(real)
            if not real.is_dir():
                out.errors.append(f"{v}: the vault is not there (unmounted, moved or offline?)")
                continue
            _walk(real, out)
    return out


def plan_token(store: Path, s: Scan, plan: object) -> str:
    body = [str(store), s.registry, sorted(str(v) for v in s.vaults), plan]
    return hashlib.sha256(json.dumps(body, sort_keys=True).encode()).hexdigest()[:16]


class Refused(Exception):
    """The operation would act on incomplete or changed knowledge. Nothing was done."""


# ---------------------------------------------------------------- gc

@dataclass(frozen=True)
class GcPlan:
    store: Path
    remove: dict[str, int]      # checksum → size
    recent: dict[str, int]      # unreferenced but younger than MIN_AGE_DAYS: kept
    vaults: list[Path]
    registry: str
    token: str
    retired: list[str] = field(default_factory=list)


def gc_plan(registry: str | Path | None = None, store: Path | None = None, *,
            now: float | None = None, retire: list[Path] | None = None) -> GcPlan:
    """What a sweep would remove.

    Every confirmed sweep records the vaults it read in the store's ledger, and a later sweep
    REFUSES while any of them is missing from the registry: `scopes.toml` is rebuilt one scope at a
    time and is safe to delete, so a vault that dropped out of it is far likelier to be
    unregistered than gone. `retire` names vaults the operator says are gone for good."""
    store = store or blobs.root()
    s = scan(registry)
    if not s.vaults and not s.errors:
        raise Refused(f"no registered vault was found in {s.registry}, so every blob would look "
                      "unreferenced. Compose a scope first.")
    if not s.complete:
        raise Refused("some notes could not be read, so a blob they name would look unreferenced:\n"
                      + "\n".join(f"  {line}" for line in (s.errors + s.malformed)[:20]))
    retired = {os.path.realpath(p) for p in retire or []}
    current = {str(v) for v in s.vaults}
    absent = blobs.seen_vaults(store) - current - retired
    if absent:
        raise Refused("an earlier sweep read these vaults, and the registry no longer lists them:\n"
                      + "\n".join(f"  {v}" for v in sorted(absent))
                      + "\nCompose them again, or, if one is gone for good, name it with "
                        "--retire-vault and its originals become collectable.")
    # Recorded by every complete scan of the DEFAULT registry, not only by a sweep that removed
    # something: the ledger exists to remember a vault before it drops out of the registry. A
    # one-off `--registry` (another profile, a test) records nothing, or its vaults would block
    # every later sweep of the real one.
    if s.registry == str(scopes.registry_path(None)):
        with blobs.locked(store, exclusive=True):
            blobs.record_vaults(store, blobs.seen_vaults(store) | current)
    cutoff = (now if now is not None else time.time()) - MIN_AGE_DAYS * 86400
    loose = {c: h for c, h in blobs.held(store).items() if c not in s.refs}
    remove = {c: h.size for c, h in loose.items() if h.mtime < cutoff}
    recent = {c: h.size for c, h in loose.items() if h.mtime >= cutoff}
    return GcPlan(store, remove, recent, s.vaults, s.registry,
                  plan_token(store, s, [sorted(remove), sorted(retired)]), sorted(retired))


def gc_apply(token: str, registry: str | Path | None = None, store: Path | None = None, *,
             now: float | None = None, retire: list[Path] | None = None) -> GcPlan:
    """Re-plan, refuse unless the plan is the one confirmed, then remove — returning the plan with
    only what was removed.

    The vaults are read OUTSIDE the store lock: a slow or hung vault must not stall every ingest.
    Under the exclusive lock each blob's age is checked again, because the window between the two
    is exactly when an ingest might find one present (refreshing it) and promote a note naming it.
    """
    store = store or blobs.root()
    plan = gc_plan(registry, store, now=now, retire=retire)
    if plan.token != token:
        raise Refused("the plan changed since it was shown (a note, a vault, the registry or the "
                      "store moved). Run it again without --confirm and review the new plan.")
    cutoff = (now if now is not None else time.time()) - MIN_AGE_DAYS * 86400
    removed: dict[str, int] = {}
    with blobs.locked(store, exclusive=True):
        try:
            for c, size in plan.remove.items():
                try:
                    mtime = os.lstat(blobs.blob_path(store, c)).st_mtime
                except FileNotFoundError:
                    continue
                if mtime < cutoff and blobs.remove(c, store=store):
                    removed[c] = size
        except (OSError, blobs.BlobError) as e:
            raise blobs.BlobError(f"stopped after removing {len(removed)} of {len(plan.remove)}"
                                  f" ({', '.join(removed) or 'none'}): {e}") from e
        if plan.retired:
            try:
                blobs.record_vaults(store, blobs.seen_vaults(store) - set(plan.retired))
            except (OSError, blobs.BlobError) as e:
                raise blobs.BlobError(
                    f"removed all {len(removed)} planned blob(s), but the vault ledger could not "
                    f"be updated, so {', '.join(plan.retired)} is not yet retired: {e}") from e
    return replace(plan, remove=removed)


# ---------------------------------------------------------------- adopt

@dataclass(frozen=True)
class AdoptPlan:
    store: Path
    found: dict[str, Path]      # checksum → the file whose bytes match it
    missing: list[str]
    token: str
    scan_errors: list[str]


def _hash(path: Path, cache: dict[tuple[int, int, int, int], str]) -> str | None:
    try:
        if not os.path.isfile(path):
            return None
        st = os.stat(path)
        key = (st.st_dev, st.st_ino, st.st_size, st.st_mtime_ns)
        if key not in cache:
            cache[key] = blobs.sha256_file(path)
        return cache[key]
    except OSError:
        return None


def adopt_plan(search: list[Path] | None = None, registry: str | Path | None = None,
               store: Path | None = None) -> AdoptPlan:
    """For every original a note names that the store lacks: where the note says it was, then any
    file under `search`. A file is adopted only on an exact checksum match. Audio is never adopted:
    it enters the store only through Scripta's retention window.

    `--confirm` walks `search` again rather than trusting the plan's paths: the token binds the plan
    to what is on disk NOW, and `put(expected=)` checks each file's bytes besides."""
    store = store or blobs.root()
    s = scan(registry)
    held, gone = blobs.held(store), blobs.tombstones(store)
    wanted = sorted(c for c in s.checksums(ORIGINAL_KEYS) if c not in held and c not in gone)
    cache: dict[tuple[int, int, int, int], str] = {}
    found: dict[str, Path] = {}
    for c in wanted:
        for r in s.refs[c]:
            if r.key in ORIGINAL_KEYS and r.hint:
                p = Path(os.path.expanduser(r.hint))
                if p.is_absolute() and _hash(p, cache) == c:
                    found[c] = p
                    break
    remaining = {c for c in wanted if c not in found}
    for folder in search or []:
        if not remaining:
            break
        for dirpath, _dirs, files in os.walk(folder):
            for name in files:
                p = Path(dirpath, name)
                c = _hash(p, cache)
                if c in remaining:
                    found[c] = p
                    remaining.discard(c)
    plan = sorted((c, str(p)) for c, p in found.items())
    return AdoptPlan(store, found, sorted(remaining), plan_token(store, s, plan),
                     s.errors + s.malformed)


def adopt_apply(token: str, search: list[Path] | None = None,
                registry: str | Path | None = None, store: Path | None = None) -> AdoptPlan:
    plan = adopt_plan(search, registry, store)
    if plan.token != token:
        raise Refused("the plan changed since it was shown. Run it again without --confirm and "
                      "review the new plan.")
    adopted: dict[str, Path] = {}
    try:
        for c, p in plan.found.items():
            if blobs.put(p, expected=c, store=plan.store).outcome in ("stored", "present"):
                adopted[c] = p
    except (OSError, blobs.BlobError) as e:
        raise blobs.BlobError(f"stopped after adopting {len(adopted)} of {len(plan.found)}"
                              f" ({', '.join(adopted) or 'none'}): {e}") from e
    return replace(plan, found=adopted)


# ---------------------------------------------------------------- status

def status(registry: str | Path | None = None, store: Path | None = None) -> dict:
    """What the store holds, what notes name, and how the two disagree. `only_copy` counts stored
    originals no longer where any note last saw them: for those the store is the ONLY local copy,
    so it must never be treated as a cache. `still_held` is a blob that was forgotten and is still
    on disk, which `forget` is supposed to make impossible and is reported if it ever is not."""
    store = store or blobs.root()
    held, gone = blobs.held(store), blobs.tombstones(store)
    s = scan(registry)
    originals = s.checksums(ORIGINAL_KEYS)
    audio = s.checksums(("audio_sha256",)) - originals
    only_copy = 0
    for c in held:
        hints = [r.hint for r in s.refs.get(c, []) if r.hint]
        if hints and not any(Path(os.path.expanduser(h)).exists() for h in hints):
            only_copy += 1
    return {
        "store": str(store),
        "config": str(blobs.config_path()),
        "registry": s.registry,
        "vaults": [str(v) for v in s.vaults],
        "blobs": len(held),
        "bytes": sum(h.size for h in held.values()),
        "discarded": len(gone),
        "still_held": sorted(gone & held.keys()),
        "leftovers": [str(p) for p in blobs.leftovers(store)],
        "exposed": blobs.exposed(store),
        "originals": {
            "named": len(originals),
            "stored": len(originals & held.keys()),
            "discarded": len(originals & gone),
            "missing": len(originals - held.keys() - gone),
        },
        "audio": {"named": len(audio), "stored": len(audio & held.keys())},
        "unreferenced": len(held.keys() - s.refs.keys()),
        "only_copy": only_copy,
        "complete": s.complete,
        "problems": s.errors + s.malformed,
    }
