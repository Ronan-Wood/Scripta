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
that rule decide liveness would let an Obsidian edit make a note's original collectable. So three
readings are unioned, and a blob any of them names is alive:

- the leading `---` block as YAML, which is what a note declares to every YAML reader. A line scan
  stopped at the first line that was not a `- item`, so a comment or a blank line inside a list hid
  every reference after it (found by the Lean model's differential survey, 2026-11-06);
- every other line that starts with a referencing key, with the `- item` lines under it;
- every run of 64 hex digits anywhere in the note, read from where the run starts, so a checksum
  written out anywhere stays alive and
  the two above matter for which key names a blob (`adopt`, `status`) and for spellings that are
  not literal (escapes).

Only in the leading block is a value an error, because only there is it a claim: a referencing key
whose value is not a checksum (or, except `audio_sha256`, is more than one, or has an empty item)
makes gc refuse. The block is read as YAML 1.2 reads it, which is what Obsidian reads, not as
PyYAML's 1.1 does where the two differ (tabs, and three characters 1.1 takes as line breaks). A
block that is still not YAML refuses, naming its line, since a reader more lenient than PyYAML
could read a claim in it that no line scan can. The one exception is the dialect the engine and the
app write themselves (`_engine_dialect`), unescaped first-column `key: value` lines, which the line
scan provably reads whole.

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

import yaml

from substrate import blobs, scopes
from substrate import vault as _vault
from substrate.freshness import read_bounded

ORIGINAL_KEYS = ("source_sha256", "raw_sha256")
REF_KEYS = (*ORIGINAL_KEYS, "audio_sha256")
MIN_AGE_DAYS = 7
_MAX_NOTE = 8 * 1024 * 1024
# Read as YAML only up to this: a stray `---` rule can make most of a note look like its block.
_MAX_FRONTMATTER = 1024 * 1024
_KEY_LINE = re.compile(r"""^\s*["']?(source_sha256|raw_sha256|audio_sha256)["']?\s*:(.*)$""")
# What YAML refuses to read at all (PyYAML's own `Reader.NON_PRINTABLE`, which is not public API).
# YAML 1.1 breaks lines at NEL, LS and PS, and 1.2 does not: left in, PyYAML ends a comment or a
# key line there that a 1.2 reader runs on, and can then read a claim as the text of another value.
_NOT_A_BREAK = re.compile("[\x85\u2028\u2029]")
_DIALECT_LINE = re.compile(r"([A-Za-z0-9_][A-Za-z0-9_-]*):(?:[ \t](.*))?$")
_PROPERTIES = re.compile(r"(?:[&!][^\s\[{]*\s*)*")  # an anchor or a tag before a value
_ALIAS = re.compile(r"\*([^\s,\[\]{}]+)")
_ANCHOR = re.compile(r"&([^\s,\[\]{}]+)")
_ANCHOR_11, _ALIAS_11 = re.compile(r"&([\w-]+)"), re.compile(r"\*([\w-]+)")
_QUOTE_COLON = re.compile(r'"[ \t]*:')
# A one-line flow collection that cannot hold a claim: flat, closed, no quote, escape or checksum key.
_CLOSED_FLOW = re.compile(r"(?i)\[(?:(?!sha256)[^\[\]{}'\"\\])*\]|\{(?:(?!sha256)[^\[\]{}'\"\\])*\}")
_NON_PRINTABLE = re.compile("[^\x09\x0A\x0D\x20-\x7E\x85\xA0-\uD7FF\uE000-\uFFFD\U00010000-\U0010FFFF]")
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


def _hint(key: str, fields: list[str] | dict[str, str]) -> str | None:
    """An absolute path to the file the original was last known as, or None. A relative one would
    mean something different from every working directory, and a folder is not the file. `fields`
    is a block's lines, or the scalars of the YAML mapping that holds the claim."""
    def get(name: str) -> str | None:
        value = fields.get(name, "").strip() if isinstance(fields, dict) else _field(fields, name)
        if not value or "\ufffd" in value or any(ord(ch) < 0x20 for ch in value):
            return None  # U+FFFD stands for what was unread, and a control byte is no path
        try:
            value.encode("utf-8")  # a YAML escape can decode to a lone surrogate, which no path holds
        except UnicodeEncodeError:
            return None
        return value

    if key != "raw_sha256":
        hint = get("source_path")
    else:
        loc, raw = get("raw_location"), get("raw")
        # Joined unless `raw_location` IS the file: a folder that is unmounted right now is not a
        # directory to `isdir`, and the hint must not change with what happens to be mounted.
        is_file = loc and os.path.isfile(os.path.expanduser(loc))
        hint = str(Path(loc, raw)) if loc and raw and not is_file else loc
    if not hint:
        return None
    path = Path(os.path.expanduser(hint))
    return str(path) if path.is_absolute() and not path.is_dir() else None


def _candidates(*hints: str | None) -> list[str | None]:
    """Where the original may be, one per reading that found it: `adopt` tries each, and `status`
    counts it the only copy only when none of them is there."""
    found = list(dict.fromkeys(h for h in hints if h))
    return found or [None]


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


def _claim_error(key: str, values: list[str], shapeless: bool = False) -> str | None:
    """What a referencing key's values fail to be, or None when they are a valid claim."""
    if not shapeless and all(blobs.is_checksum(e) for e in values) and (
            key == "audio_sha256" or len(values) <= 1):
        return None
    return "a list of checksums" if key == "audio_sha256" else "one checksum"


def _yaml_claim(node: yaml.Node) -> tuple[list[str], bool]:
    """The values a referencing key's YAML node names, and whether it is neither a scalar nor a list
    of scalars. An empty value names nothing, quoted or not, as the line scan has always read it."""
    if isinstance(node, yaml.ScalarNode):
        empty = node.value.strip() in _EMPTY  # by what it says: `!!null x` still says `x`
        return ([] if empty else [node.value.strip()]), False
    if not isinstance(node, yaml.SequenceNode):
        return [], True
    scalars = [n for n in node.value if isinstance(n, yaml.ScalarNode)
               and n.tag != "tag:yaml.org,2002:null"]
    return [n.value.strip() for n in scalars], len(scalars) != len(node.value)


def _scalars(node: yaml.MappingNode) -> dict[str, str]:
    """A mapping's scalar values by key, the first of a repeated key, as the line reader takes it."""
    fields: dict[str, str] = {}
    for a, b in node.value:
        if isinstance(a, yaml.ScalarNode) and isinstance(b, yaml.ScalarNode) \
                and b.tag != "tag:yaml.org,2002:null":
            fields.setdefault(a.value, b.value)
    return fields


def _readings(block: list[str]) -> list[str]:
    """The block as each YAML reader sees it: as 1.2 (Obsidian), and, where they differ, as 1.1
    (PyYAML and what is built on it), which breaks lines at NEL, LS and PS where 1.2 does not.
    Characters every YAML reader rejects become U+FFFD in both."""
    text = _NON_PRINTABLE.sub("\ufffd", "\n".join(block))
    as_12 = _NOT_A_BREAK.sub("\ufffd", text)
    return [as_12] if as_12 == text else [as_12, text]


def _tabs_as_spaces(source: str) -> str:
    """PyYAML rejects a tab after a colon or a dash, which 1.2 allows. Tabs after content only: a
    tab indenting a line is not YAML to 1.2 either, and read as a space it would fold the line into
    the one above."""
    return re.sub(r"(?<=\S)[ \t]*\t", lambda m: m[0].replace("\t", " "), source)


def _compose(block: list[str]) -> tuple[yaml.Node | None | bool, yaml.Node | None | bool]:
    """The block's node graph as YAML 1.2 reads it, then as 1.1 does where the two differ; False
    for a reading that is not YAML (or, for 1.1, is the same as 1.2's)."""
    if sum(map(len, block)) > _MAX_FRONTMATTER:
        return False, False
    readings = _readings(block)
    as_12: yaml.Node | None | bool = False
    for attempt in (readings[0], _tabs_as_spaces(readings[0])):
        try:
            as_12 = yaml.compose(attempt, Loader=yaml.SafeLoader)
            break
        except Exception:  # any failure is "not YAML"; `_why_not_yaml` says which
            continue
    as_11: yaml.Node | None | bool = False
    for attempt in (readings[1], _tabs_as_spaces(readings[1])) if len(readings) > 1 else ():
        try:
            as_11 = yaml.compose(attempt, Loader=yaml.SafeLoader)
            break
        except Exception:  # noqa: BLE001 — not YAML to 1.1 either
            continue
    return as_12, as_11


def _why_not_yaml(block: list[str]) -> str:
    """Where and why PyYAML stops reading the block, as 1.2 reads it with tabs as spaces, in the
    note's own line numbers."""
    if sum(map(len, block)) > _MAX_FRONTMATTER:
        return f"longer than {_MAX_FRONTMATTER // 1024} KiB, more than any frontmatter needs"
    try:
        yaml.compose(_tabs_as_spaces(_readings(block)[0]), Loader=yaml.SafeLoader)
    except yaml.MarkedYAMLError as e:
        mark = e.problem_mark or e.context_mark
        where = f"line {mark.line + 2}: " if mark else ""
        return where + (e.problem or e.context or "not YAML")
    except Exception as e:  # noqa: BLE001 — nesting too deep, an escape `chr` rejects
        return f"{type(e).__name__}: {str(e)[:80]}"
    return "not YAML"


def _may_claim(text: str) -> bool:
    """Whether `text` could name a blob to any reader: a key is either spelled out, escaped, or an
    alias of a node whose own text does one of the two. Characters YAML rejects are dropped first,
    since a reader that skips them reads `sha2<NUL>56` as `sha256`."""
    text = _NON_PRINTABLE.sub("", text)
    return "sha256" in text.lower() or "\\" in text


def _may_key(line: str) -> bool:
    """Whether a line a reader takes for a key line could make a claim: it must hold the `:` an
    implicit key ends at (one on its own line, or one an explicit `?` key already began)."""
    return ":" in line and _may_claim(line)


def _has_escaped_key(text: str) -> bool:
    """Whether a line holds an escape before a `"` that a `:` follows: the shape of a key only an
    escape spells. A linear test, and looser than the YAML grammar, so it can only refuse more."""
    for line in text.split("\n"):
        slash = line.find("\\")
        if slash != -1 and any(m.start() > slash for m in _QUOTE_COLON.finditer(line)):
            return True
    return False


def _engine_dialect(block: list[str]) -> bool:
    """Every line a first-column `key: value`, as the engine's emitter, `amend`'s pin and the app's
    `_meta.md` write them, unescaped: a value may start with anything, and quoting a colon does not
    quote a quote, so such a block is often not YAML. A YAML reader that accepts it anyway finds a
    key at the start of a line, where the line scan reads it; inside a flow collection a value
    opens; spelled by an escape; or behind an alias whose anchor the block defines. So when no
    resolvable alias and no escaped key appear, every flow value is flat and free of quotes,
    escapes and checksum keys, and every claim line is literal and closed, the line scan reads
    all the block can claim.

    The app leaves a value with a quote in it unquoted, so a title can open a quote or a bracket it
    never closes, which then runs on through the lines below it (a `#` line included). That tail is
    certain only if `_open_tail_is_literal`."""
    text = "\n".join(block)
    # Names as 1.2 reads them, and as PyYAML does, which ends one at `:` (`{*k: v}` is `*k`).
    anchors = set(_ANCHOR.findall(text)) | set(_ANCHOR_11.findall(text))
    aliases = set(_ALIAS.findall(text)) | set(_ALIAS_11.findall(text))
    if anchors & aliases or _has_escaped_key(text):
        return False
    for n, line in enumerate(block):
        if line.startswith("#") and _NOT_A_BREAK.search(line):
            return False  # YAML 1.1 ends the comment there, and reads what follows
        if not line.strip() or line.startswith("#"):
            continue
        m = _DIALECT_LINE.match(line)
        if not m:
            return False
        value = (m.group(2) or "").strip()
        rest = value[_PROPERTIES.match(value).end():]
        if rest[:1] in ("'", '"'):
            unclosed = _quote_end(rest) is None
        else:
            unclosed = rest[:1] in ("{", "[") and not _CLOSED_FLOW.fullmatch(rest)
        if m.group(1) in REF_KEYS and ("\\" in value or unclosed):
            return False
        if m.group(1) not in REF_KEYS and "sha256" in value.lower() and (
                "\\" in value or ":" in value):
            return False  # a lenient reader may split a key out of the value
        if unclosed:
            return _open_tail_is_literal(block[n:])
    return True


def _quote_end(rest: str) -> int | None:
    """Where the quoted scalar opening `rest` closes, or None when it runs on past the line."""
    quote, i = rest[0], 1
    while i < len(rest):
        if quote == '"' and rest[i] == "\\":
            i += 2
        elif rest[i] == quote and quote == "'" and rest[i + 1:i + 2] == "'":
            i += 2
        elif rest[i] == quote:
            return i
        else:
            i += 1
    return None


def _open_tail_is_literal(tail: list[str]) -> bool:
    """Lines a value left open on its own line runs on into, where a key can sit anywhere in a
    line. Nothing in them names a blob the line scan cannot read if each is a first-column
    `key: value` line (so no item sits under a key), no escape follows a double quote that may
    have opened (only there does YAML decode one), and a checksum key appears only as a line's own
    key, which the scan reads."""
    text = "\n".join(tail)
    quote = text.find('"')
    if quote != -1 and "\\" in text[quote:]:
        return False
    for line in tail:
        if not line.strip():
            continue
        m = _DIALECT_LINE.match(line)
        if not m or ("sha256" in line.lower() and m.group(1) not in REF_KEYS):
            return False
    return True


def _yaml_refs(path: Path, block: list[str],
               scan: Scan) -> tuple[dict[str, str] | None, set[int], bool]:
    """The claims in a frontmatter block as YAML reads it, as 1.2 and, where they differ, as 1.1:
    a blob either names is alive. Returns the top level's scalars, for the hints of references in
    the body (None when neither reading is YAML); the block lines a mapping key starts on in the
    1.2 reading, the only one whose lines are the block's; and whether 1.2 read it at all, which
    is what decides that a block is YAML, since it is what Obsidian reads.

    Every mapping key equal to a referencing key is a claim, at any depth and however the
    document is spelled, so comments, blank lines, flow mappings, folding and escapes all read as
    they mean. Composed, not loaded: the node graph keeps a repeated key's every value, where a
    loaded dict keeps the last, and it constructs nothing. Characters YAML rejects outright become
    U+FFFD first, as undecodable bytes already have, so one stray byte does not cost the parse.
    An empty item in a list is malformed, as it always was to the line scan; only a whole value
    that is empty names nothing.

    An alias shares its node, so each node is walked once and each (key, value node) claimed
    once: 3,000 keys aliasing one 3,000-item list are 3,000 references, not nine million."""
    as_12, as_11 = _compose(block)
    claimed: set[tuple[str, int]] = set()
    key_lines: set[int] = set()
    hints: dict[tuple[str, int], list[str | None]] = {}
    reported: set[str] = set()
    for root, lines_are_the_block in ((as_12, True), (as_11, False)):
        if root is not False and root is not None:
            _walk_claims(path, root, block, scan, claimed, hints,
                         key_lines if lines_are_the_block else set(), lines_are_the_block, reported)
    front = next((r for r in (as_12, as_11) if r is not False), False)
    if front is False:
        return None, key_lines, False
    return (_scalars(front) if isinstance(front, yaml.MappingNode) else {}), key_lines, as_12 is not False


def _walk_claims(path: Path, root: yaml.Node, block: list[str], scan: Scan,
                 claimed: set[tuple[str, int]], hints: dict[tuple[str, int], list[str | None]],
                 key_lines: set[int], spans: bool, reported: set[str]) -> None:
    # Each node with the indentation its continuation lines must exceed under YAML 1.2: that of
    # the block mapping key or sequence dash it hangs from (-1 at the top, where any will do).
    stack: list[tuple[yaml.Node, int]] = [(root, -1)]
    seen: set[int] = set()
    while stack:
        node, floor = stack.pop()
        if id(node) in seen:
            continue
        seen.add(id(node))
        if spans and isinstance(node, yaml.ScalarNode) and node.style in (None, "'", '"'):
            # PyYAML runs a quoted or plain value on into lines YAML 1.2 rejects as too shallow,
            # and a line reader takes one of them for a key: what it names depends on the reader.
            # A block scalar's lines both specs require indented, and agree on.
            for n in range(node.start_mark.line + 1, min(node.end_mark.line + 1, len(block))):
                line = block[n]
                if len(line) - len(line.lstrip(" ")) <= floor and _may_key(line):
                    msg = (f"{path}: frontmatter line {n + 2} names a checksum key or holds an "
                           "escape, but YAML reads it as part of the value before it, so readers "
                           "disagree on what it names. Quote or close that value and run gc again.")
                    if msg not in reported:
                        reported.add(msg)
                        scan.malformed.append(msg)
                    break
        if isinstance(node, yaml.SequenceNode):
            stack.extend((item, floor if node.flow_style else node.start_mark.column)
                         for item in node.value)
        elif isinstance(node, yaml.MappingNode):
            for k, v in node.value:
                below = floor if node.flow_style else k.start_mark.column
                stack += [(k, below), (v, below)]
                key_lines.add(k.start_mark.line)
                # A BOM mid-block is part of the key to PyYAML, and nothing to a reader that drops it.
                key = k.value.replace("\ufeff", "") if isinstance(k, yaml.ScalarNode) else None
                if key not in REF_KEYS:
                    continue
                if (key, id(v)) in claimed:
                    continue
                claimed.add((key, id(v)))
                values, shapeless = _yaml_claim(v)
                if what := _claim_error(key, values, shapeless):
                    shown = f" ({', '.join(values[:3])[:120]!r})" if values else ""
                    where = (f"on frontmatter line {v.start_mark.line + 2}" if spans
                             else "as YAML 1.1 reads it")  # whose line numbers are not the note's
                    msg = f"{path}: {key} {where} is not {what}{shown}"
                    if msg not in reported:  # both readings may report the same claim
                        reported.add(msg)
                        scan.malformed.append(msg)
                if (key, id(node)) not in hints:
                    # As YAML reads the path, and at the top as the writer wrote it: the engine and
                    # the app write `Call #3.pdf` unquoted, which YAML reads as `Call`.
                    hints[key, id(node)] = _candidates(
                        _hint(key, _scalars(node)), _hint(key, block) if node is root else None)
                for c in (h for e in values for h in _HEX.findall(e)):
                    scan.refs.setdefault(c.lower(), []).extend(
                        Ref(path, key, h) for h in hints[key, id(node)])


def _text_refs(path: Path, text: str, scan: Scan) -> None:
    """References in one decoding of a note: the frontmatter as YAML, every other line by the key
    scan, and every checksum anywhere in the text by the backstop."""
    lines = text.replace("\r\n", "\n").replace("\r", "\n").split("\n")
    end = None
    if lines and lines[0].rstrip() == "---":
        # Fences in the first column only, as the note reader and Obsidian take them: an indented
        # one is text inside a block, not its end.
        end = next((i for i in range(1, len(lines)) if lines[i].rstrip() in ("---", "...")), None)
    block = lines[1:end] if end else []
    front, key_lines, as_12 = _yaml_refs(path, block, scan) if end is not None else (None, set(), False)
    unparsed = end is not None and not as_12
    if any(_may_claim(line) and _NON_PRINTABLE.search(line) for line in block):
        # YAML rejects the character, which is read here as U+FFFD; a reader that skips it instead
        # could read a key spelled out or escaped on that line as a claim.
        scan.malformed.append(f"{path}: a control character on a frontmatter line that names a "
                              "checksum key or holds an escape leaves what it names uncertain. "
                              "Remove it and run gc again.")
    if unparsed and _may_claim("\n".join(block)) and not _engine_dialect(block):
        # A reader more lenient than PyYAML may still accept it and read a claim the line scan
        # cannot (under a comment, nested, escaped, aliased), so nothing it names is certain.
        scan.malformed.append(
            f"{path}: the frontmatter is not YAML ({_why_not_yaml(block)}), so what it names "
            "cannot be read for certain. Quote or fix that line and run gc again; if the note "
            "opens with a `---` rule rather than frontmatter, put a line of text above it.")
    if as_12:
        # PyYAML runs a quoted value on into a first-column line, which YAML 1.2 rejects there and
        # a line reader takes for a new key: what such a line names depends on who reads it.
        for n, line in enumerate(block):
            if line[:1] in ("", " ", "\t", "-", "#", ":", "?") or n in key_lines:
                continue
            if _may_key(line):
                scan.malformed.append(
                    f"{path}: frontmatter line {n + 2} names a checksum key or holds an escape, "
                    "but YAML reads it as part of the value before it, so readers disagree on what "
                    "it names. Quote or close that value and run gc again.")
                break
    i = 0
    while i < len(lines):
        m = _KEY_LINE.match(lines[i])
        if not m:
            i += 1
            continue
        key, value, in_block = m.group(1), m.group(2).strip(), unparsed and i < end
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
        if in_block and items and (what := _claim_error(key, items)):
            scan.malformed.append(f"{path}: {key} {raw[:120]!r} is not {what}")
        # Where YAML read the block, its hints are YAML's: a line's regex keeps a trailing comment.
        if front is None:
            found = _candidates(_hint(key, block))
        else:
            found = [None] if i < end else _candidates(_hint(key, front), _hint(key, block))
        for c in _HEX.findall(raw):
            scan.refs.setdefault(c.lower(), []).extend(Ref(path, key, h) for h in found)
        i = j
    for c in _HEX.findall(text):
        scan.refs.setdefault(c.lower(), []).append(Ref(path, "text", None))


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
