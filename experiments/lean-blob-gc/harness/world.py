"""Small vault/blob worlds: generated abstractly, written to disk for the real planner, and sent as
JSON to the Lean model.

A world is abstract (`World`), and a note's fields carry a `style`. The style says how a field is
spelled in markdown. The model never sees it, because a style changes the spelling, not the
meaning. Every frontmatter spelling is checked against PyYAML (`yaml_fields`), so a world on disk
says in YAML exactly what its abstract form says.
"""

from __future__ import annotations

import hashlib
import json
import os
from dataclasses import dataclass, field
from pathlib import Path

from hypothesis import strategies as st

NOW = 2_000_000_000
MIN_AGE = 7 * 86400
KEYS = {"source": "source_sha256", "raw": "raw_sha256", "audio": "audio_sha256"}
N_SHA = 6
JUNK = ("TODO", "pending", "abc123")


def sha_hex(i: int) -> str:
    return hashlib.sha256(blob_bytes(i)).hexdigest()


def blob_bytes(i: int) -> bytes:
    return f"blob {i}\n".encode()


# Every checksum the generator can name must hold a letter, or YAML would read it as a number.
if not all(any(ch.isalpha() for ch in sha_hex(i)) for i in range(N_SHA)):
    raise RuntimeError("a generated checksum is all digits; YAML would read it as a number")


# ---------------------------------------------------------------- the abstract world

@dataclass
class Tok:
    kind: str          # ok | upper | padded | junk
    sha: int = 0
    junk: str = "TODO"

    def text(self) -> str:
        h = sha_hex(self.sha)
        return {"ok": h, "upper": h.upper(), "padded": h + "zz", "junk": self.junk}[self.kind]

    def to_json(self) -> list:
        return [self.kind] if self.kind == "junk" else [self.kind, self.sha]


@dataclass
class Field:
    key: str           # source | raw | audio
    loc: str           # front | body
    toks: list[Tok]
    style: str
    quote: str = ""    # '' | "'" | '"', for the values of quoting styles
    quoted_key: bool = False

    def to_json(self) -> dict:
        return {"key": self.key, "loc": self.loc, "toks": [t.to_json() for t in self.toks]}

    # The next two are `Field.refs` and `Field.malformed` in lean/BlobGc/Model.lean.
    def refs(self) -> set[int]:
        return {t.sha for t in self.toks if t.kind != "junk"}

    def malformed(self) -> bool:
        return self.loc == "front" and bool(self.toks) and (
            any(t.kind != "ok" for t in self.toks) or (self.key != "audio" and len(self.toks) > 1))


@dataclass
class Note:
    readable: bool
    fields: list[Field]
    unreadable_as: str = "dangling"     # dangling | icloud
    bom: bool = False
    crlf: bool = False
    extra_props: str = ""               # '' | before | after: Obsidian's tags and aliases

    def to_json(self) -> dict:
        return {"readable": self.readable, "fields": [f.to_json() for f in self.fields]}

    def refs(self) -> set[int]:
        return {c for f in self.fields for c in f.refs()}


@dataclass
class Vault:
    id: int
    manifest: list[int] | None
    notes: list[Note]

    def to_json(self) -> dict:
        return {"id": self.id, "manifest": self.manifest, "notes": [n.to_json() for n in self.notes]}


@dataclass
class World:
    default: bool
    registry: list[int]
    vaults: list[Vault]
    blobs: list[tuple[int, int]]       # (sha id, mtime)
    tombstones: list[int]
    ledger: list[int]
    retire: list[int]
    now: int = NOW

    def to_json(self) -> dict:
        return {"now": self.now, "default": self.default, "registry": self.registry,
                "vaults": [v.to_json() for v in self.vaults],
                "blobs": [list(b) for b in self.blobs], "tombstones": self.tombstones,
                "ledger": self.ledger, "retire": self.retire}


# ---------------------------------------------------------------- spelling a field

# Frontmatter styles. FAITHFUL: shapes the scan's docstring says it reads. HOSTILE: valid YAML that
# names the same values in shapes the docstring does not mention.
FRONT_FAITHFUL = ("scalar", "flow", "flow_wrapped", "block", "block_flush")
FRONT_HOSTILE = ("block_blank", "block_comment", "block_blank_mid", "block_comment_mid",
                 "nextline", "nextline_comment", "trailing_comment", "folded")
# Styles that spell one value, not a list.
SINGLE = ("scalar", "nextline", "nextline_comment", "trailing_comment", "folded")
# Styles that put a line between two items, so they need at least two.
MID = ("block_blank_mid", "block_comment_mid")
BODY_STYLES = ("body_line", "body_flow", "body_block", "body_inline_map")


def _q(f: Field, text: str) -> str:
    return f"{f.quote}{text}{f.quote}"


def _key(f: Field) -> str:
    k = KEYS[f.key]
    return f'"{k}"' if f.quoted_key else k


def front_lines(f: Field) -> list[str]:
    k, items = _key(f), [_q(f, t.text()) for t in f.toks]
    s = f.style
    if not f.toks:
        return [f"{k}:" if s in ("block", "block_flush") else
                f"{k}: []" if s.startswith("flow") else f"{k}: {f.quote * 2 or '~'}"]
    if s == "scalar":
        return [f"{k}: {items[0]}"]
    if s == "flow":
        return [f"{k}: [{', '.join(items)}]"]
    if s == "flow_wrapped":
        return [f"{k}: [{items[0]},"] + [f"  {i}," for i in items[1:-1]] + \
            ([f"  {items[-1]}]"] if len(items) > 1 else ["  ]"])
    if s == "block":
        return [f"{k}:"] + [f"  - {i}" for i in items]
    if s == "block_flush":
        return [f"{k}:"] + [f"- {i}" for i in items]
    if s == "block_blank":
        return [f"{k}:", ""] + [f"  - {i}" for i in items]
    if s == "block_comment":
        return [f"{k}:", "  # the originals"] + [f"  - {i}" for i in items]
    if s == "block_blank_mid":
        return [f"{k}:", f"  - {items[0]}", ""] + [f"  - {i}" for i in items[1:]]
    if s == "block_comment_mid":
        return [f"{k}:", f"  - {items[0]}", "  # and the other side"] + \
            [f"  - {i}" for i in items[1:]]
    if s == "nextline":
        return [f"{k}:", f"  {items[0]}"]
    if s == "nextline_comment":
        return [f"{k}:", "  # the original", f"  {items[0]}"]
    if s == "trailing_comment":
        return [f"{k}: {items[0]}  # the original"]
    if s == "folded":
        return [f"{k}: >-", f"  {items[0]}"]
    raise ValueError(s)


def body_lines(f: Field) -> list[str]:
    k, items = KEYS[f.key], [t.text() for t in f.toks]
    s = f.style
    if s == "body_line":
        return [f"{k}: {items[0]}" if items else f"{k}:"]
    if s == "body_flow":
        return [f"{k}: [{', '.join(items)}]"]
    if s == "body_block":
        return [f"{k}:"] + [f"- {i}" for i in items]
    if s == "body_inline_map":
        return [f"See {{{k}: {items[0]}}} for the original."]
    raise ValueError(s)


def note_text(n: Note) -> str:
    props = ["tags:", "  - call", "  - pdf", "aliases: [x]"]
    front = ["---", "title: t"] + (props if n.extra_props == "before" else [])
    for f in n.fields:
        if f.loc == "front":
            front += front_lines(f)
    front += (props if n.extra_props == "after" else []) + ["---", "", "# t", "", "body", ""]
    for f in n.fields:
        if f.loc == "body":
            front += body_lines(f) + [""]
    text = ("\r\n" if n.crlf else "\n").join(front)
    return ("\ufeff" if n.bom else "") + text


def yaml_fields(n: Note) -> dict[str, object]:
    """What a YAML parser reads under the referencing keys of the note's frontmatter."""
    import yaml

    lines = note_text(n).lstrip("\ufeff").replace("\r\n", "\n").split("\n")
    end = lines.index("---", 1)
    data = yaml.safe_load("\n".join(lines[1:end])) or {}
    return {k: data[k] for k in KEYS.values() if k in data}


def expected_yaml(f: Field) -> object:
    """What the abstract field says the YAML value is."""
    texts = [t.text() for t in f.toks]
    if not f.toks:
        if f.style.startswith("flow"):
            return []
        return "" if f.style == "scalar" and f.quote else None
    if f.style in SINGLE:
        return texts[0]
    return texts


# ---------------------------------------------------------------- Hypothesis strategies

def rarely(n: int) -> st.SearchStrategy[bool]:
    """True about once in `n`. Over a wide range that excludes 0, because Hypothesis favours small
    integers: `integers(0, n - 1) == 0` comes out true far more often than one time in n."""
    return st.integers(1, 2**20 + 1).map(lambda r: r % n == 0)


def tok(clean: bool) -> st.SearchStrategy[Tok]:
    """`clean`: mostly well-formed, as a frontmatter value usually is. Otherwise any kind evenly."""
    sha = st.integers(0, N_SHA - 1)
    odd = st.one_of(st.builds(Tok, st.just("upper"), sha), st.builds(Tok, st.just("padded"), sha),
                    st.builds(Tok, st.just("junk"), st.just(0), st.sampled_from(JUNK)))
    good = st.builds(Tok, st.just("ok"), sha)
    if not clean:
        return st.one_of(good, odd)
    return rarely(40).flatmap(lambda r: odd if r else good)


def toks(max_size: int, clean: bool = False) -> st.SearchStrategy[list[Tok]]:
    return st.lists(tok(clean), max_size=max_size)


@st.composite
def front_field(draw, key: str, front_styles: tuple[str, ...]) -> Field:
    style = draw(st.sampled_from(front_styles))
    most = 1 if style in SINGLE else 3 if key == "audio" else 2 if draw(rarely(10)) else 1
    ts = draw(toks(most, clean=True))
    if not ts and style not in FRONT_FAITHFUL:
        style = "scalar"            # an empty value has no hostile spelling worth the name
    if style in MID and len(ts) < 2:
        style = "block"
    # Quoted values only where YAML allows them unambiguously; a folded scalar is never quoted.
    quote = draw(st.sampled_from(["", "'", '"'])) if style not in ("folded",) else ""
    return Field(key, "front", ts, style, quote, draw(st.booleans()))


@st.composite
def body_field(draw) -> Field:
    style = draw(st.sampled_from(BODY_STYLES))
    ts = draw(toks(1 if style in ("body_line", "body_inline_map") else 3))
    if style == "body_inline_map" and not ts:
        style = "body_line"
    return Field(draw(st.sampled_from(list(KEYS))), "body", ts, style)


@st.composite
def note(draw, front_styles: tuple[str, ...]) -> Note:
    keys = draw(st.lists(st.sampled_from(list(KEYS)), unique=True, max_size=2))
    fields = [draw(front_field(k, front_styles)) for k in keys]
    fields += draw(st.lists(body_field(), max_size=1))
    readable = not draw(rarely(80))
    return Note(readable, fields, draw(st.sampled_from(["dangling", "icloud"])),
                draw(st.booleans()), draw(st.booleans()),
                draw(st.sampled_from(["", "before", "after"])))


MTIMES = (NOW - MIN_AGE - 1, NOW - MIN_AGE, NOW - MIN_AGE + 1, NOW - 30 * 86400, NOW - 3600,
          NOW + 100)


@st.composite
def world(draw, front_styles: tuple[str, ...] = FRONT_FAITHFUL) -> World:
    n_disk = draw(st.integers(1, 4))
    disk = list(range(n_disk))
    ghosts = [n_disk, n_disk + 1]          # named somewhere, not on disk

    def some_vault():
        return st.sampled_from(ghosts) if draw(rarely(30)) else st.sampled_from(disk)

    vaults = []
    for i in disk:
        if draw(rarely(25)):
            manifest = None
        else:
            manifest = sorted({draw(some_vault()) for _ in range(draw(st.integers(0, 2)))})
            # A vault inheriting itself, or a cycle through another, only now and then.
            if not draw(rarely(25)):
                manifest = [j for j in manifest if j < i or j in ghosts]
        vaults.append(Vault(i, manifest, draw(st.lists(note(front_styles), max_size=3))))
    registry = sorted({draw(some_vault()) for _ in range(draw(st.integers(0, 3)))}) \
        if draw(rarely(30)) else sorted({draw(some_vault()) for _ in range(draw(st.integers(1, 3)))})
    shas = draw(st.lists(st.integers(0, N_SHA - 1), unique=True, max_size=N_SHA))
    ever = list(range(n_disk + 4))         # the ledger may remember vaults long gone
    return World(
        default=draw(st.booleans()),
        registry=registry,
        vaults=vaults,
        blobs=[(s, draw(st.sampled_from(MTIMES))) for s in shas],
        tombstones=draw(st.lists(st.integers(0, N_SHA - 1), unique=True, max_size=2)),
        ledger=draw(st.lists(st.sampled_from(ever) if draw(rarely(4)) else st.sampled_from(disk),
                             unique=True, max_size=2)),
        retire=draw(st.lists(st.sampled_from(ever), unique=True, max_size=1)),
    )


# ---------------------------------------------------------------- on disk

@dataclass
class Layout:
    root: Path
    home: Path = field(init=False)
    store: Path = field(init=False)

    def __post_init__(self):
        self.home = self.root / "home"
        self.store = self.home / ".substrate" / "blobs"

    def vault(self, i: int) -> Path:
        return self.root / "vaults" / f"v{i}"

    def default_registry(self) -> Path:
        return self.home / ".substrate" / "scopes.toml"

    def other_registry(self) -> Path:
        return self.root / "other-scopes.toml"


def write_world(w: World, lay: Layout) -> None:
    """Every file the abstract world describes, except the store, which `run.py` writes through
    `blobs` itself."""
    (lay.home / ".substrate").mkdir(parents=True)
    (lay.root / "vaults").mkdir()
    for v in w.vaults:
        d = lay.vault(v.id)
        (d / "notes").mkdir(parents=True)
        if v.manifest is not None:
            inh = ", ".join(json.dumps(str(lay.vault(j))) for j in v.manifest)
            (d / ".substrate.toml").write_text(f'name = "v{v.id}"\ninherits = [{inh}]\n', "utf-8")
        for k, n in enumerate(v.notes):
            p = d / "notes" / f"n{k}.md"
            if n.readable:
                p.write_bytes(note_text(n).encode("utf-8"))
            elif n.unreadable_as == "dangling":
                os.symlink(lay.root / "nowhere" / f"n{k}.md", p)
            else:
                (d / "notes" / f".n{k}.md.icloud").write_bytes(b"bplist00")
    reg = lay.default_registry() if w.default else lay.other_registry()
    rows = "".join(
        f'[scopes.s{i}]\nvault = {json.dumps(str(lay.vault(i)))}\n'
        f'db = {json.dumps(str(lay.root / "db" / f"s{i}.db"))}\n' for i in w.registry)
    reg.write_text(rows, "utf-8")
