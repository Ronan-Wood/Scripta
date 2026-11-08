"""`substrate frontmatter check` and `fix`: find notes whose frontmatter is not YAML, or that YAML
reads differently from the engine, and rewrite the engine's own old dialect into YAML.

Until every writer went through `markdown/yaml_scalar` (the engine) and `Frontmatter.quoted` (the
app), frontmatter was written as unescaped `key: value` lines, and those notes are still in the
vaults. The engine and the app read them line by line; Obsidian reads YAML, and so does `blobs gc`,
which refuses what it cannot read except this dialect, admitted by a heuristic
(`blob_lifecycle._engine_dialect`). `check` exits 1 while a note needs it, and it can go when none
does.

`fix` rewrites only a note that is NOT YAML, where the engine's reading is the only reading there
is; it keeps that reading, changes only the lines YAML cannot read on their own, and keeps what gc
reads. A note that is YAML but reads differently is a judgement about which reading was meant, so it
is reported and left alone, and so is a note `fix` cannot rewrite with certainty. `--write` applies
the rewrites through `amend`'s own write, and only in project vaults unless the inherited ones are
asked for.
"""

from __future__ import annotations

import datetime
import os
import reprlib
import unicodedata
from collections import Counter
from dataclasses import dataclass, field
from pathlib import Path

import yaml

from substrate import blob_lifecycle, notes, scopes
from substrate import vault as _vault
from substrate.freshness import read_bounded
from substrate.markdown import reader, yaml_scalar

NOT_YAML = "not YAML"
READS_DIFFERENTLY = "read differently"

# Keys whose `[…]` value is a list to every reader, and keys whose value is text even when it starts
# with `[` (a title such as `[WIP] notes`). A `[…]` value under any other key is read either way.
LIST_KEYS = frozenset({"domains", "supersedes", "tags", "participants", "commitments", "aliases",
                       "cssclasses"})
SCALAR_KEYS = frozenset({"title", "doc_id", "status", "doc_type", "confidence", "superseded_by",
                         "source_path", "source_sha256", "raw", "raw_sha256", "raw_location",
                         "group", "app", "class", "document_class", "version", "version_date",
                         "extractor", "extractor_arm", "layout_model", "pipeline_version",
                         "date", "time", "duration", "created", "updated", "mode"})
# The two lists the engine itself splits, each on every comma, keeping what fits the shape.
_ENGINE_LISTS = {"domains": reader._DOMAIN, "supersedes": reader._DOC_ID}
_YAML_12_ONLY_BREAKS = ("\x85", " ", " ")

_short = reprlib.Repr(maxlevel=2, maxstring=60, maxother=60, maxlist=4, maxdict=4).repr


@dataclass
class Finding:
    path: Path
    kind: str           # NOT_YAML or READS_DIFFERENTLY
    reasons: list[str]
    fixed: bytes | None = None    # the rewritten note, when `fix` can rewrite it
    refused: str | None = None    # why `fix` will not, otherwise
    inherited: bool = False       # in a vault `--write` leaves alone without --include-inherited


@dataclass
class Report:
    vaults: list[Path] = field(default_factory=list)
    notes: int = 0
    findings: list[Finding] = field(default_factory=list)
    errors: list[str] = field(default_factory=list)
    written: list[Path] = field(default_factory=list)
    not_utf8: list[Path] = field(default_factory=list)   # not read: the engine refuses these too


def _is_space(ch: str) -> bool:
    """Whitespace as Swift's `CharacterSet.whitespaces` has it, which `parseList` trims: tab and
    the space separators. Python's `isspace` also takes controls and line breaks."""
    return ch == "\t" or unicodedata.category(ch) == "Zs"


def _trim(s: str) -> str:
    i, j = 0, len(s)
    while i < j and _is_space(s[i]):
        i += 1
    while j > i and _is_space(s[j - 1]):
        j -= 1
    return s[i:j]


def list_items(raw: str) -> list[tuple[str, bool]]:
    """A `[a, 'b', "c"]` value as the app reads it (`Frontmatter.parseList`): each item, and whether
    it was quoted. A `'` opening an item is a single-quoted scalar, a `"` a double-quoted one read
    verbatim to the next `"`, and a quote anywhere else is text."""
    v = _trim(raw)
    if v.startswith("["):
        v = v[1:]
    if v.endswith("]"):
        v = v[:-1]
    if '"' not in v and "'" not in v:
        return [(_trim(p), False) for p in v.split(",") if _trim(p)]
    items: list[tuple[str, bool]] = []
    i, n = 0, len(v)
    while i < n:
        while i < n and _is_space(v[i]):
            i += 1
        if i >= n:
            break
        if v[i] in "'\"":
            q, i, buf = v[i], i + 1, []
            while i < n:
                if v[i] == q:
                    if q == "'" and v[i + 1:i + 2] == "'":
                        buf.append("'")
                        i += 2
                        continue
                    i += 1
                    break
                buf.append(v[i])
                i += 1
            item = "".join(buf)
            if q == '"':
                item = _trim(item)
            if _trim(item):
                items.append((item, True))
            while i < n and v[i] != ",":
                i += 1
        else:
            start = i
            while i < n and v[i] != ",":
                i += 1
            if _trim(v[start:i]):
                items.append((_trim(v[start:i]), False))
        i += 1
    return items


def _is_list(key: str, raw: str) -> bool:
    return raw.startswith("[") and raw.endswith("]") and key not in SCALAR_KEYS


def _same(y: object, text: str, quoted: bool) -> bool:
    """Whether YAML's value `y` is what a line reader reads as `text`: the same string, or a plain
    scalar YAML resolves to a value spelled exactly that way (`3`, `1.5`, `true`, a date, an empty
    value). `0123` is 83, `1.10` is 1.1, `no` is False and `null` is None to YAML, so those differ."""
    if isinstance(y, str):
        # PyYAML reads `1e5` and `0o17` as text; YAML 1.2 (Obsidian) reads numbers.
        return y == text and (quoted or not yaml_scalar.resolves_in_yaml_12(text))
    if quoted:
        return False
    if y is None:
        return text == ""
    if isinstance(y, bool):
        return text.lower() == str(y).lower()
    if isinstance(y, (int, float)):
        return text == str(y)
    if isinstance(y, (datetime.date, datetime.datetime)):
        return text in (str(y), y.isoformat())
    return False


def _line_agrees(key: str, raw: str, y: object) -> bool:
    if raw[:1] in ("!", "&", "*"):
        return False  # a tag, an anchor or an alias: YAML reads something the line readers do not
    scalar = _same(y, yaml_scalar.decode(raw), raw[:1] in ("'", '"'))
    if not _is_list(key, raw):
        return scalar
    items = list_items(raw)
    as_list = (isinstance(y, list) and len(y) == len(items)
               and all(_same(a, t, q) for a, (t, q) in zip(y, items, strict=True)))
    if key in _ENGINE_LISTS:
        shape = _ENGINE_LISTS[key]
        as_list = as_list and reader._parse_list(raw, shape) == list(
            dict.fromkeys(t for t, _ in items if shape.fullmatch(t)))
    return as_list if key in LIST_KEYS else as_list or scalar


def _load(block: str) -> tuple[object, str | None]:
    """YAML's reading, or why there is none. Any exception is "not YAML": PyYAML also raises
    ValueError for an impossible date, AttributeError for a bad `!!timestamp`, RecursionError for
    deep nesting, and none of those may take a compose or a check down with them."""
    try:
        return yaml.safe_load(block), None
    except Exception as e:  # noqa: BLE001
        mark = getattr(e, "problem_mark", None)
        where = f", line {mark.line + 2}" if mark is not None else ""
        return None, f"{getattr(e, 'problem', None) or type(e).__name__ + ': ' + str(e)[:120]}{where}"


_GC_ONLY = "`blobs gc` reads this frontmatter only through its allowance for the old dialect"


def assess(text: str | None, data: bytes | None = None) -> tuple[str, list[str]] | None:
    """(kind, reasons) when the note's frontmatter, as the engine reads `text`, is not YAML or YAML
    reads it differently, or when `blobs gc` reads the note's bytes `data` (`text` encoded when not
    given) only through its old-dialect heuristic, in any decoding and by its own fences; None when
    every reader agrees. `text` is None for a note that is not UTF-8, which only gc reads."""
    found = _assess(text) if text is not None else None
    if not blob_lifecycle.admitted_only_by_dialect(data if data is not None else text.encode()):
        return found
    return NOT_YAML, (found[1] if found else []) + [_GC_ONLY]


def _assess(text: str) -> tuple[str, list[str]] | None:
    got = reader.raw_frontmatter(text)
    if got is None or not got[1]:
        return None
    block, raw = got
    if len(block) > blob_lifecycle._MAX_FRONTMATTER:
        return NOT_YAML, [f"longer than {blob_lifecycle._MAX_FRONTMATTER // 1024} KiB, more than "
                          f"any frontmatter needs"]
    if any(ch in block for ch in _YAML_12_ONLY_BREAKS):
        return NOT_YAML, ["NEL, LS or PS: a line break to the engine and YAML 1.1, not to YAML 1.2"]
    counts = Counter(yaml_scalar.decode(k) for k, _ in raw)  # `"title"` is `title` to YAML
    repeated = sorted(k for k, n in counts.items() if n > 1)
    if repeated:
        return NOT_YAML, [f"{k}: written more than once, and readers keep different ones"
                          for k in repeated]
    loaded, problem = _load(block)
    if problem is not None:
        return NOT_YAML, [problem]
    if not isinstance(loaded, dict):
        return NOT_YAML, ["YAML reads the block as something other than a mapping of keys"]
    reasons = []
    for k, r in raw:
        if k not in loaded:
            reasons.append(f"{k}: YAML does not read this key")
        elif not _line_agrees(k, r, loaded[k]):
            reasons.append(f"{k}: the engine reads {_short(yaml_scalar.decode(r))}, "
                           f"YAML {_short(loaded[k])}")
    return (READS_DIFFERENTLY, reasons) if reasons else None


def _engine_view(text: str) -> tuple[list[tuple[str, object]], str]:
    """What the engine and the app read from `text`: each key's text, or a list's items as the app
    reads them and as the engine's own list parser does; and the body."""
    view: list[tuple[str, object]] = []
    for k, r in reader.raw_frontmatter(text)[1]:
        if _is_list(k, r):
            shape = _ENGINE_LISTS.get(k)
            view.append((k, ([t for t, _ in list_items(r)],
                             reader._parse_list(r, shape) if shape else None)))
        else:
            view.append((k, yaml_scalar.decode(r)))
    return view, reader._parse_frontmatter(text)[1]


def rewrite(data: bytes) -> bytes:
    """`data` with each frontmatter line YAML cannot read on its own rewritten through
    `yaml_scalar.encode`, keeping the engine's value. Raises ValueError, naming why, for a note it
    cannot rewrite with certainty."""
    try:
        text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise ValueError("the note is not UTF-8") from e
    if reader.raw_frontmatter(reader.normalized_text(data)) is None:
        raise ValueError("the engine reads no frontmatter here, so it has no reading to keep; "
                         "edit it by hand")
    for eol in ("\r\n", "\n", "\r"):
        if text.startswith("---" + eol):
            break
    else:
        raise ValueError("the frontmatter does not open on a line of its own")
    lines = text.split(eol)
    # Where the reader ends the block: the first later line that STARTS with `---`.
    close = next((i for i in range(1, len(lines)) if lines[i].startswith("---")), None)
    if close is None or lines[close] != "---":
        raise ValueError("the frontmatter's closing `---` is not on a line of its own")
    block = lines[1:close]
    if any(("\r" in ln or "\n" in ln) for ln in block):
        raise ValueError("the frontmatter mixes line endings")
    out = []
    for ln in block:
        if not ln.strip():
            out.append(ln)
            continue
        if ln[:1].isspace() or ln[:1] in ("-", "#") or ":" not in ln:
            raise ValueError(f"line {ln!r} is not a first-column `key: value`, so this is not the "
                             f"engine's dialect; edit it by hand")
        k, _, rv = ln.partition(":")
        key, r = k.strip(), rv.strip()
        alone, problem = _load(ln)
        if problem is None and isinstance(alone, dict) and list(alone) == [key]:
            if _line_agrees(key, r, alone[key]):
                out.append(ln)
                continue
            raise ValueError(f"line {ln!r} is YAML read as {_short(alone[key])}, where the engine "
                             f"reads {_short(yaml_scalar.decode(r))}; which was meant is for a "
                             f"person to decide")
        if k != key or not key:
            raise ValueError(f"line {ln!r} has a key YAML and the engine split differently")
        if _is_list(key, r):
            if key not in LIST_KEYS:
                raise ValueError(f"line {ln!r} may be a list or text; edit it by hand")
            enc = "[" + ", ".join(yaml_scalar.encode(t, flow=True) for t, _ in list_items(r)) + "]"
        else:
            enc = yaml_scalar.encode(yaml_scalar.decode(r))
        out.append(f"{key}: {enc}")
    new = eol.join([lines[0], *out, *lines[close:]]).encode("utf-8")
    before, after = reader.normalized_text(data), reader.normalized_text(new)
    if _engine_view(after) != _engine_view(before):
        raise ValueError("a rewrite would change what the engine or the app reads")
    left = assess(after, new)
    if left is not None:
        raise ValueError(f"a rewrite still leaves it {left[0]}: {'; '.join(left[1])}")
    (refs, malformed), (refs_after, malformed_after) = _gc_reading(data), _gc_reading(new)
    if refs_after != refs or not malformed_after <= malformed:
        raise ValueError("a rewrite would change what `blobs gc` reads a checksum under, or make "
                         "it refuse the note; edit it by hand")
    return new


def _gc_reading(data: bytes) -> tuple[set[tuple[str, str]], set[str]]:
    """What `blobs gc` reads in the note `data`: each (checksum, key) it names, and its refusals."""
    scan = blob_lifecycle.Scan()
    for text in blob_lifecycle._decodings(data):
        blob_lifecycle._text_refs(Path("note"), text, scan)
    return {(c, r.key) for c, rs in scan.refs.items() for r in rs}, set(scan.malformed)


def vaults_of(scope: str | None, registry: str | Path | None) -> tuple[list[Path], set[Path]]:
    """Every vault of one registered scope, or of all of them, roots first and each once; and which
    of those are project vaults (the rest are inherited)."""
    path = scopes.registry_path(registry)
    entries = scopes.load(registry)
    if not entries:
        raise scopes.ScopeError(f"no scope is registered in {path}, so there is nothing to check")
    if scope is not None:
        if scope not in entries:
            raise scopes.ScopeError(f"no scope {scope!r} in {path}; registered: {sorted(entries)}")
        entries = {scope: entries[scope]}
    out: list[Path] = []
    projects: set[Path] = set()
    for entry in entries.values():
        projects.add(Path(os.path.realpath(entry.vault)))
        for v in _vault.resolve_vaults(entry.vault):
            real = Path(os.path.realpath(v.path))
            if real not in out:
                out.append(real)
    return out, projects


def check(vaults: list[Path], *, fix: bool = False, write: bool = False,
          writable: set[Path] | None = None) -> Report:
    """Assess every note in `vaults`; with `fix`, also plan each rewrite of a note that is not YAML,
    and with `write`, apply them in the vaults of `writable` (all of `vaults` when None)."""
    rep = Report(vaults=list(vaults))
    chosen: dict[str, tuple[Path, Path]] = {}
    for v in vaults:
        for path in blob_lifecycle.iter_notes(v, rep.errors):
            # A vault inside another, or a link to a note, reaches one note twice: it is read once,
            # at its own path when one of the two is that.
            real = os.path.realpath(path)
            if real not in chosen or str(path) == real:
                chosen[real] = (v, path)
    for real, (v, path) in chosen.items():
        try:
            data = read_bounded(path, notes.MAX_NOTE_BYTES)
        except OSError as e:
            rep.errors.append(f"{path}: {e.strerror or e}")
            continue
        try:
            text = reader.normalized_text(data)
        except UnicodeDecodeError:
            rep.not_utf8.append(path)
            text = None
        else:
            rep.notes += 1
        found = assess(text, data)
        if found is None:
            continue
        f = Finding(path, *found)
        rep.findings.append(f)
        if not fix:
            continue
        if f.kind == READS_DIFFERENTLY:
            f.refused = "it is YAML, read differently; which reading is meant is for a person"
            continue
        try:
            f.fixed = rewrite(data)
        except ValueError as e:
            f.refused = str(e)
            continue
        f.inherited = writable is not None and _owner(real, vaults) not in writable
        if not write:
            continue
        if f.inherited:
            f.refused, f.fixed = ("it is in an inherited vault; pass --include-inherited to "
                                  "rewrite those too"), None
            continue
        try:
            _commit(v, path.relative_to(v).parts, data, f.fixed)
            rep.written.append(path)
        except (OSError, notes.NoteError, ValueError) as e:
            f.refused, f.fixed = f"could not write it: {e}", None
    return rep


def _owner(real: str, vaults: list[Path]) -> Path | None:
    """The innermost of `vaults` the note at `real` lives in: a vault inside another owns its own
    notes, whichever root the walk reached them through."""
    inside = [v for v in vaults if real.startswith(str(v).rstrip(os.sep) + os.sep)]
    return max(inside, key=lambda v: len(v.parts), default=None)


def _commit(root: Path, parts: tuple[str, ...], expected: bytes, new: bytes) -> None:
    """Replace the note at `root/parts` with `new`, only if it still holds `expected`, through
    `amend`'s own write: every folder opened without following a link, the note a regular file."""
    dfd = notes._open_note_dir(root, parts)
    name, target = parts[-1], root.joinpath(*parts)
    try:
        if notes._read_at(dfd, name, target) != expected:
            raise ValueError("the note changed while it was being checked")
        notes._replace_at(dfd, name, target, content=new, stage="frontmatter",
                          unchanged=lambda now: now == expected,
                          changed=lambda: ValueError("the note changed while it was being checked"))
    finally:
        os.close(dfd)
