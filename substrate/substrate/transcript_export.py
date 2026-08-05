"""Scripta transcripts → a composable substrate vault. The corpus bridge (Doc 3 §4 step 3).

A Scripta transcript is already markdown with frontmatter, so this is not a converter: it is a
SPINE AUTHOR. The app writes `date/time/duration/participants/tags/app` and no spine at all, and
`compose` refuses a whole SCOPE — not a note — when any note fails to declare `status`, `doc_type`
and (on the write path) `confidence`. So the four decisions below are the module, and the copying
is incidental.

Two conditions are ratified by Doc 3 §4 and are structural here rather than advisory:

  * **`class: conversation`.** Substrate withholds conversation-class documents from DEFAULT
    retrieval because confidence varies WITHIN a transcript — a passage from mid-call can be
    reasoning the speaker abandoned ten minutes later, in the same register as the conclusion
    (classes.EXCLUDED_CLASSES carries the full argument). Exporting a transcript as any other
    class is the precise lie the class axis exists to prevent.
  * **Local, non-synced, one scope per workspace.** This module never resolves a destination for
    the caller and never registers a scope. Both are the operator's act. What it does enforce is
    that the vault it writes declares `inherits = []`: a transcript scope that inherited
    `core-vault` would compose an OneDrive-backed tier into the one index that must stay local,
    and the operator can add that line by hand if they later decide otherwise.

The doc_id is the join key, and it is derived from the transcript's WORKSPACE-RELATIVE PATH and
nothing else. Scripta keeps its own IndexStore and already owns (path → startMs, speaker, date), so
the engine does not carry those fields; `expand_ref` splits a chunk_id back to a doc_id and Scripta
joins on it. Content is deliberately NOT in the id — `extract.base.doc_id_for` mixes a content
fingerprint, which is right for an immutable PDF and wrong here: re-transcribing a call would mint
a second doc_id, and reconcile (keyed on doc_id) would leave the old one answering queries beside
the new one.
"""

from __future__ import annotations

import hashlib
import re
from dataclasses import dataclass, field
from pathlib import Path

from substrate.markdown.reader import _DOC_ID, _DOMAIN, _parse_frontmatter

# ---------------------------------------------------------------------------------------------
# The spine, decided once for every transcript. Each value is a judgement, so each carries its
# argument; a later reader changing one of these should have to disagree with the argument.
# ---------------------------------------------------------------------------------------------

# `complete`, not `active` and not `archived`.
#
#   * `active` says a note is live and may still be worked on. A call ended; it will not gain
#     turns. `classes.POLICIES["conversation"].frozen` is already True — `complete` is the status
#     that AGREES with the class policy instead of contradicting it.
#   * `archived` would be the seductive wrong answer, because it produces the observable behaviour
#     we want (out of default retrieval) for the wrong reason. Exclusion must come from exactly one
#     axis here — the class one, whose reason is "retrieval BY PASSAGE misrepresents this
#     document". Stacking a status exclusion on top makes "why did this not come back?"
#     unanswerable, and it breaks the day a caller asks with `--include-archived` and not the
#     conversation-class ask (or the reverse) and gets a silently half-open corpus.
#
# `complete` is in spine.INCLUDED_STATUSES, so this choice changes nothing about what retrieval
# returns — the class axis does all the withholding. It changes what the note says about itself,
# which is the entire job of the field.
TRANSCRIPT_STATUS = "complete"

# `reference`, AND THIS IS THE VOCABULARY'S WEAKEST POINT, not a clean fit. Doc 2 §6a's five
# doc_types name the JOB A NOTE DOES, and `class: conversation` says in the same breath that this
# is not a note — "a SOURCE, not a note … raw material for notes, never a note itself"
# (classes.py). So the axis is being applied outside its domain of definition, and no value is
# right. What we can do is pick the one that asserts nothing false:
#
#   decision    — claims something was decided. A call may decide nothing, or five things, or
#                 decide and then reverse; nothing at the document level is true.
#   explanation — claims the document explains. A raw transcript explains nothing; it records.
#   how-to      — claims a procedure. No.
#   digest      — claims it POINTS at atomic notes and CONTAINS none. A transcript is all content
#                 and points at nothing: the exact inverse.
#   reference   — lookup material. TRUE of a transcript: you open it to look up what was said.
#
# It is also the vocabulary's own designated lenient value (`spine.DEFAULT_DOC_TYPE`), chosen there
# for exactly this situation — "treated as reference rather than mislabelled as a decision/
# explanation it may not be".
#
# NOTE the deliberate divergence from the six migrated `_sources/convo-*.md` notes, which declare
# `doc_type: explanation` under the same class. They are right and so is this: those are
# hand-written DISTILLATES with "## Key takeaways" sections — they do explain. A raw transcript
# does not. Two doc_types under one class is the honest state, not an inconsistency to normalise.
TRANSCRIPT_DOC_TYPE = "reference"

# `unstated` — DECLARED, and the difference from absence is the whole point.
#
# `spine.validate_confidence` is lenient on the compose path, so omitting the key would ingest
# fine and store `unjudged`. That would assert "nobody has judged this note", which is false the
# moment this exporter runs: the judgement was made, and it is that a transcript makes no
# settledness claim of its own. spine.py names this exact case — a transcript's settledness varies
# within it, so no single marker is true of the whole — and records that collapsing the two values
# was a real defect. Declaring `unstated` is what keeps this corpus distinguishable from the 530
# notes nobody has looked at.
#
# `unjudged` is not declarable at all (SpineError), so there is no third option.
TRANSCRIPT_CONFIDENCE = "unstated"

TRANSCRIPT_CLASS = "conversation"

# The `app:` value that means "this file is a call transcript". Scripta writes four markers into one
# output folder and only this one names a conversation:
#
#   call-transcriber          a call transcript          <output>/*.md
#   call-transcriber-note     a living note the operator writes by hand   <output>/Notes/
#   call-transcriber-doc      the extracted text of an imported PDF       <output>/Files/
#   call-transcriber-entity   a derived wikilink stub, near-contentless   <output>/Entities/<group>/
#
# THE MARKER IS THE ONLY THING THAT DISTINGUISHES THEM, and it went unread. `export_workspace`
# walked `rglob("*.md")`, so the other three carry a `group:` (all of them do — NoteStore, the
# DocumentImporter and EntityMirror each write one) and passed the workspace filter, and every one
# was written out as `class: conversation`. Measured 2026-08-05 on a four-file fixture: the exporter
# reported "4 transcript(s)" for one transcript, one private note, one PDF and one stub.
#
# Each of the three is a distinct failure, and none is cosmetic:
#
#   * `class: conversation` on a PDF is the precise lie this module's own header says the class axis
#     exists to prevent. Conversation-class withholding is justified by "confidence varies WITHIN a
#     transcript"; that argument is simply untrue of a reference document, which then sits outside
#     default retrieval for a reason that does not apply to it.
#   * A living note is the operator's own words, not something anyone said on a call. Exporting it
#     into the transcript scope puts private working notes into the one corpus Doc 3 §4 calls the
#     most sensitive content the app holds, labelled as a record of a conversation.
#   * An entity stub is a derived index artefact — a name and a list of `[[links]]`. As a note it is
#     contentless ballast that dilutes every ranking it appears in.
#
# The evidence was already in the artefact: `_RESERVED_KEYS` does not cover `app`, so each exported
# note carried `app: call-transcriber-doc` three lines under `class: conversation`. The key that
# disproved the classification was copied through, unread, by the code that made it.
TRANSCRIPT_MARKER = "call-transcriber"

# The domain floor. `domains` is what retrieval filters on and the exporter cannot infer topics
# deterministically, so it copies the app's own `tags` (slugified) and guarantees this one value
# underneath them. Without a floor, an eleventh transcript whose `tags` were empty or unslugifiable
# would carry zero domains — and NOTHING IN THE ENGINE REFUSES THAT (measured: no gate anywhere
# checks domains for presence, unlike status/doc_type/confidence), so it would land as a silently
# unfilterable note under a fully green compose.
BASE_DOMAIN = "transcript"

# Where exported notes land inside the vault. `_sources/` is where every existing conversation-class
# note in the operator's vaults already lives; the `transcripts/` level under it is what makes the
# prune in `export_workspace` safe to scope to a directory this module owns outright.
NOTE_SUBDIR = ("_sources", "transcripts")

# Frontmatter keys this module AUTHORS. A source key of the same name is dropped rather than
# carried through, so the app can never supply a spine value the exporter believes it decided.
# Wider than the keys actually written: every field the markdown reader acts on is here, because
# an app that later starts emitting e.g. `version:` must not silently reach the class gate.
_RESERVED_KEYS: frozenset[str] = frozenset({
    "doc_id", "title", "status", "doc_type", "confidence", "class", "document_class",
    "domains", "raw", "raw_sha256", "raw_location", "source_sha256", "source_pages",
    "page_label_offset", "version", "version_date", "supersedes", "superseded_by",
})

_SLUG_STRIP = re.compile(r"[^a-z0-9]+")
_H1 = re.compile(r"^#\s+(.+?)\s*#*\s*$", re.MULTILINE)
_CONTROL = re.compile(r"[\x00-\x1f\x7f]")

_MAX_SLUG = 48          # + '-' + 8 hex = 57, inside _DOC_ID's 64
_MAX_DOMAIN = 64        # _DOMAIN's own cap; truncate rather than let _parse_list drop it silently


# Cloud-sync roots, as GLOBS under $HOME. `Library/CloudStorage/*` is where macOS mounts every
# File-Provider service (OneDrive, Dropbox, Google Drive, Box).
#
# `Library/Mobile Documents/*` IS THE WHOLE DIRECTORY, not iCloud Drive's container within it, and
# naming only `com~apple~CloudDocs` was a hole rather than a narrower choice. Every child of Mobile
# Documents is a ubiquity container — that is what the directory IS — so an app-specific one is
# synced by exactly the same mechanism as iCloud Drive and by definition, not by configuration.
# Measured on the operator's machine 2026-08-04: `Library/Mobile Documents/iCloud~md~obsidian/
# Documents/` holds six Obsidian vaults and matched NONE of the old globs. That is the likeliest
# destination an operator who keeps vaults would pick for a transcript vault, and picking it passed
# this gate — sending call transcripts, the most sensitive content the app holds, to iCloud while
# the caller's UI stated the engine had refused a synced destination.
#
# A curated list cannot close this: the next container is named by whichever app is installed next.
# The glob matches the mechanism instead, so a container this file has never heard of is refused.
_CLOUD_ROOT_GLOBS = (
    "Library/CloudStorage/*",
    "Library/Mobile Documents/*",
    "Library/Mobile Documents/*/Documents",
    "Library/Mobile Documents/*/Desktop",
)


class ExportError(RuntimeError):
    """The transcript cannot be exported into a vault that would compose."""


def _identity(path: Path) -> tuple[int, int] | None:
    try:
        st = path.stat()
    except OSError:
        return None
    return (st.st_dev, st.st_ino)


def sync_root_for(path: Path) -> Path | None:
    """The cloud-sync root `path` lives under, or None. `path` need not exist yet.

    Compares (st_dev, st_ino) against each root rather than testing a path PREFIX, and that is the
    whole reason this function is worth having. With "Desktop & Documents Folders" enabled, macOS
    presents the iCloud folder at `~/Documents` through a File Provider — no symlink, so
    `resolve()` does not rewrite it and no prefix test on `~/Library/Mobile Documents` matches.
    Measured 2026-08-03: `~/Documents/CallTranscriber/Call 2026-07-13 1222.md` and
    `~/Library/Mobile Documents/com~apple~CloudDocs/Documents/CallTranscriber/Call 2026-07-13
    1222.md` are inode 473504905 — ONE file. The app's default `outputFolderPath` is already an
    iCloud folder, and a prefix check would have reported it clean.
    """
    home = Path.home()
    marks: dict[tuple[int, int], Path] = {}
    for pattern in _CLOUD_ROOT_GLOBS:
        try:
            roots = list(home.glob(pattern))
        except OSError:
            continue
        for root in roots:
            ident = _identity(root)
            if ident is not None:
                marks[ident] = root
    if not marks:
        return None
    node = path.expanduser().absolute()
    while True:
        # A not-yet-created destination simply has no identity; the walk continues to its parent,
        # which is what actually decides whether the export lands in a synced tree.
        hit = marks.get(_identity(node))  # type: ignore[arg-type]
        if hit is not None:
            return hit
        if node.parent == node:
            return None
        node = node.parent


def assert_not_synced(dest: Path) -> None:
    """Refuse an export destination inside a cloud-synced tree (Doc 3 §4's ratified condition).

    Enforced rather than documented, because "local, non-synced" is the kind of condition that is
    true on the day it is written and false three months later when a folder is moved — and the
    failure is silent and unrecoverable: transcripts do not come back out of a provider's servers
    because the local copy was deleted.
    """
    root = sync_root_for(dest)
    if root is not None:
        raise ExportError(
            f"{dest} is inside the cloud-synced tree {root}. Doc 3 §4 puts the exported transcript "
            "corpus at a LOCAL, non-synced path — call transcripts are the most sensitive content "
            "the app holds, and every other scope already points into OneDrive. Choose a "
            "destination outside every provider root (e.g. ~/.substrate/scripta/)."
        )


@dataclass(frozen=True)
class ExportedNote:
    doc_id: str
    source: Path            # the transcript, absolute
    rel_source: str         # workspace-relative POSIX path — what the doc_id is derived from
    note: Path              # the written vault note
    title: str
    domains: list[str]
    source_sha256: str


@dataclass
class ExportReport:
    scope: str
    vault: Path
    notes: list[ExportedNote] = field(default_factory=list)
    pruned: list[Path] = field(default_factory=list)
    skipped: list[tuple[Path, str]] = field(default_factory=list)
    # Transcripts belonging to a DIFFERENT workspace, with the group they carry. Separate from
    # `skipped` because this is the wall doing its job, not a problem: reporting "14 transcripts
    # belong to other workspaces" is how an operator sees that the filter ran at all. Folded into
    # `skipped` it would read as 14 things that went wrong.
    foreign: list[tuple[Path, str]] = field(default_factory=list)
    # Markdown under `source_dir` that is not a call transcript, with the `app:` value that says so
    # (or "" where there is none). A THIRD bucket rather than a reuse of `skipped`, because these
    # three outcomes send an operator to three different places: `skipped` is "something went wrong
    # with this file", `foreign` is "the privacy wall held", and this is "correctly not a
    # transcript". A note and an entity stub landing in `skipped` would read as two defects in an
    # export that did exactly the right thing.
    not_transcripts: list[tuple[Path, str]] = field(default_factory=list)
    # The sync root the SOURCE transcripts sit in, when they sit in one. Reported, never refused:
    # where Scripta writes transcripts is the app's setting, not this exporter's to veto, and
    # refusing would refuse the only corpus that exists. Reporting it is the point — the condition
    # Doc 3 §4 states is about the export, and a clean export out of a synced source is a half-met
    # condition that should be visible rather than implied.
    source_sync_root: Path | None = None


def _slug(text: str, limit: int) -> str:
    """Lowercase ASCII slug, `-`-separated, truncated to `limit` with no trailing separator."""
    s = _SLUG_STRIP.sub("-", text.lower()).strip("-")
    return s[:limit].strip("-")


def doc_id_for_transcript(rel_source: str) -> str:
    """The stable join key for a transcript at `rel_source` (workspace-relative, POSIX).

    Path-derived and content-free, so re-exporting an edited transcript updates the same document
    instead of minting a second one beside it (see the module docstring). Relative rather than
    absolute so that moving the workspace folder — which Scripta's `outputFolderPath` lets the
    operator do at any time — does not re-key the corpus.

    The 8-hex path digest is what disambiguates two transcripts that share a filename in different
    subdirectories; the readable slug is what lets an operator recognise a doc_id in a query result
    without a lookup.
    """
    digest = hashlib.sha256(rel_source.encode("utf-8")).hexdigest()[:8]
    slug = _slug(Path(rel_source).stem, _MAX_SLUG)
    # _DOC_ID requires a leading [a-z0-9]. A filename that is entirely punctuation slugs to "" and
    # one starting with a digit is fine, so only the empty case needs a stand-in.
    if not slug:
        slug = "transcript"
    doc_id = f"{slug}-{digest}"
    if not _DOC_ID.fullmatch(doc_id):  # unreachable by construction; a refusal beats a bad key
        raise ExportError(f"derived doc_id {doc_id!r} is not doc_id-shaped for {rel_source!r}")
    return doc_id


def _title_for(front: dict[str, str], body: str, source: Path) -> str:
    """The note title: the app's `title`, else the body's H1, else the filename stem.

    Surrounding double quotes are stripped at derivation, not at emission, so the value is
    idempotent under the frontmatter round-trip — `_parse_frontmatter` strips a matched pair, and a
    title that both starts and ends with one would otherwise lose them on the next re-export and
    change the file's bytes for no reason.
    """
    for candidate in (front.get("title", ""), (m.group(1) if (m := _H1.search(body)) else ""),
                      source.stem):
        t = _CONTROL.sub(" ", candidate).strip()
        if len(t) >= 2 and t[0] == t[-1] == '"':
            t = t[1:-1].strip()
        if t:
            return t
    return source.name  # a file named ".md" — vanishingly unlikely, never empty


def _domains_for(front: dict[str, str]) -> list[str]:
    """BASE_DOMAIN plus the app's `tags`, slugified. Order preserved, deduplicated.

    Tags are copied rather than interpreted: they are data the app produced from the call, and an
    exporter that editorialised them would be inventing a retrieval axis. Slugified because a tag
    like `project management` has a space and `_DOMAIN` does not admit one — and truncated to
    `_MAX_DOMAIN` here rather than left to `_parse_list`, which DROPS an over-long entry silently.
    """
    out = [BASE_DOMAIN]
    raw = front.get("tags", "").strip()
    if raw.startswith("[") and raw.endswith("]"):
        raw = raw[1:-1]
    for part in raw.split(","):
        tag = _slug(part.strip().strip('"').strip("'"), _MAX_DOMAIN)
        if tag and tag not in out and _DOMAIN.fullmatch(tag):
            out.append(tag)
    return out


def _scalar(value: str) -> str:
    """A frontmatter scalar the engine's own parser reads back unchanged.

    `_parse_frontmatter` splits on the FIRST colon and strips a matched pair of surrounding double
    quotes, so: quote a value containing a colon (otherwise nothing marks where the value begins),
    leave a value that already contains a quote alone (the parser does no unescaping, so adding
    quotes around one would round-trip wrong), and never emit a newline or control byte — a
    frontmatter block with a line that has no colon is not treated as frontmatter AT ALL, which
    would silently turn the whole spine into body text.
    """
    v = _CONTROL.sub(" ", value).strip()
    if '"' in v:
        return v
    if ":" in v or not v:
        return f'"{v}"'
    return v


def render_note(source: Path, rel_source: str) -> tuple[str, ExportedNote]:
    """One transcript → (note text, its record). Pure apart from reading `source`.

    The body is copied VERBATIM — including `## Screen Context` OCR noise and a
    `_(No speech detected.)_` placeholder. Dropping either would be the exporter deciding what a
    transcript contains, and A18 (source→chunk coverage) measures the exported file against
    itself, so anything omitted here is omitted invisibly rather than caught.
    """
    data = source.read_bytes()
    try:
        raw_text = data.decode("utf-8")
    except UnicodeDecodeError as e:
        raise ExportError(f"{source} is not valid UTF-8: {e}") from e
    raw_text = raw_text.replace("\r\n", "\n").replace("\r", "\n")

    front, body = _parse_frontmatter(raw_text)
    doc_id = doc_id_for_transcript(rel_source)
    title = _title_for(front, body, source)
    domains = _domains_for(front)

    lines = [
        "---",
        f"doc_id: {doc_id}",
        f"title: {_scalar(title)}",
        f"status: {TRANSCRIPT_STATUS}",
        f"doc_type: {TRANSCRIPT_DOC_TYPE}",
        f"confidence: {TRANSCRIPT_CONFIDENCE}",
        f"class: {TRANSCRIPT_CLASS}",
        f"domains: [{', '.join(domains)}]",
        # §3b provenance, and the second half of the join: `raw_location` is the absolute path the
        # operator (and Scripta) can open, `raw` the workspace-relative one the doc_id is derived
        # from, `raw_sha256` the digest of the TRANSCRIPT — not of this note — so a stale export is
        # detectable without re-reading both files.
        f"raw: {_scalar(rel_source)}",
        f"raw_sha256: {hashlib.sha256(data).hexdigest()}",
        f"raw_location: {_scalar(str(source))}",
    ]
    # The app's own metadata rides along under the spine. It is not engine state — the reader
    # ignores every key it does not know — but the export has to be readable on its own, and
    # `date`/`duration`/`participants` are what makes a note in this vault recognisable as a call.
    for key, value in front.items():
        if key not in _RESERVED_KEYS:
            lines.append(f"{key}: {_scalar(value)}")
    lines.append("---")

    text = "\n".join(lines) + "\n" + body.lstrip("\n")
    record = ExportedNote(
        doc_id=doc_id, source=source, rel_source=rel_source,
        note=Path(*NOTE_SUBDIR) / f"{doc_id}.md", title=title, domains=domains,
        source_sha256=hashlib.sha256(data).hexdigest(),
    )
    return text, record


MANIFEST_TEMPLATE = """\
# Scripta transcript corpus — written by `substrate export-transcripts`. Regenerated in place.
#
# `inherits` is deliberately EMPTY. Every other scope the operator composes inherits `core-vault`
# out of OneDrive; this one must not, because Doc 3 §4 puts the transcript corpus at a local,
# non-synced path and makes the scope name the privacy wall. Inheriting a synced vault here would
# compose that tier into the one index that is supposed to be local-only. Adding core-vault back is
# a one-line edit the operator can make deliberately — it is not this exporter's call.
name = "{scope}"
inherits = []

reference_domains = ["{base_domain}"]

[reference_pins]
# Transcripts are frozen conversations; nothing here is versioned.
"""


def write_manifest(vault_dir: Path, scope: str) -> Path:
    path = vault_dir / ".substrate.toml"
    path.write_text(MANIFEST_TEMPLATE.format(scope=scope, base_domain=BASE_DOMAIN), "utf-8")
    return path


def scope_name(workspace: str) -> str:
    """`scripta-<workspace>` — Doc 3 §4's per-workspace scope name, the privacy wall."""
    slug = _slug(workspace, _MAX_SLUG)
    if not slug:
        raise ExportError(f"workspace {workspace!r} slugifies to nothing; give it a name.")
    return f"scripta-{slug}"


def export_workspace(source_dir: Path, vault_dir: Path, workspace: str) -> ExportReport:
    """Export the transcripts under `source_dir` that BELONG TO `workspace` into a vault at
    `vault_dir`.

    Selection is by each transcript's own `group:` frontmatter, compared as a slug so it agrees with
    `scope_name`. One `outputFolderPath` holds every workspace's calls, so exporting without this
    filter gave each workspace a scope containing all of them — the privacy wall Doc 3 §4 names being
    a label rather than a boundary. A transcript with no `group:` REFUSES the whole export; see the
    message raised below for why neither filing nor dropping it is acceptable.

    Idempotent: an unchanged transcript produces a byte-identical note (nothing derived from the
    clock or the run), so re-exporting is a no-op the index sees as no diff.

    Stale notes ARE pruned. `assert_composed` refuses an index holding a doc this compose did not
    ingest, so a note left behind by a deleted transcript would fail the next compose loudly — but
    only after the operator had already deleted the transcript for a reason. The prune is scoped to
    the `_sources/transcripts/` directory this module owns and to `*.md`, so nothing the operator
    put in the vault by hand is in reach.
    """
    source_dir = source_dir.expanduser().resolve()
    vault_dir = vault_dir.expanduser().resolve()
    if not source_dir.is_dir():
        raise ExportError(f"{source_dir} is not a directory — nothing to export.")
    # Before anything is on disk: the destination is the one half of the privacy condition this
    # module can actually enforce.
    assert_not_synced(vault_dir)

    scope = scope_name(workspace)
    notes_dir = vault_dir / Path(*NOTE_SUBDIR)
    notes_dir.mkdir(parents=True, exist_ok=True)
    report = ExportReport(scope=scope, vault=vault_dir,
                          source_sync_root=sync_root_for(source_dir))

    # THE WALL IS THE FILTER, NOT THE NAME. `scope_name` returns `scripta-<workspace>` and Doc 3 §4
    # calls that name the privacy wall between workspaces — but a name is only a wall if the contents
    # match it. This loop walked every `*.md` under `source_dir` and exported all of them under
    # whichever name it was handed, so exporting workspace A and workspace B out of one
    # `outputFolderPath` produced two scopes with IDENTICAL contents and different labels. An
    # operator asking `scripta-personal` got their work calls back.
    #
    # `group:` is already on each transcript — Scripta writes it from `AppSettings.recordingGroup`,
    # captured at record time — and the app's own local index partitions on the same value. Nothing
    # here had to be inferred or added; the data was on disk and unread.
    #
    # Compared as SLUGS, not as raw strings, because `scope_name` slugifies: "CBRE" and "cbre" name
    # one scope, so they have to select one set of transcripts. Comparing raw would let two spellings
    # write the same scope with different contents on alternate runs.
    want = _slug(workspace, _MAX_SLUG)

    # CLASSIFY EVERYTHING BEFORE WRITING ANYTHING. The selection can refuse — on an untagged
    # transcript — and this module's contract is that it never leaves a partial set. Deciding in one
    # pass and writing in the next is what makes the refusal free of side effects; interleaving them
    # would leave however many notes had been written before the first untagged file was reached.
    untagged: list[Path] = []
    selected: list[tuple[Path, str]] = []
    for src in sorted(source_dir.rglob("*.md")):
        rel = src.relative_to(source_dir).as_posix()
        if any(part.startswith(".") for part in Path(rel).parts):
            report.skipped.append((src, "dotfile"))
            continue
        try:
            front, _ = _parse_frontmatter(src.read_text("utf-8", errors="replace"))
        except OSError as exc:
            report.skipped.append((src, f"unreadable: {exc}"))
            continue
        # THE MARKER GATE COMES FIRST, and the order is load-bearing rather than tidy. The `group:`
        # rule below REFUSES THE WHOLE EXPORT over an untagged file, and every one of the four
        # artefact types can be untagged — an entity stub for an ungrouped call carries `group: ""`.
        # Checked second, a contentless stub would abort an export of real transcripts and name a
        # file the operator cannot fix by tagging, because it is not theirs to tag. Checked first,
        # the refusal below can only ever fire for something that really is a call.
        #
        # Absence is treated the same as a foreign marker: markdown with no `app:` at all was not
        # written by Scripta, so it is not this exporter's to publish. That agrees with the
        # RetentionPruner's own invariant (SPEC: "deletes ONLY app-authored files") — the app is
        # already careful never to DELETE what it does not own, and exporting what it does not own
        # into a queryable corpus is the same claim in the other direction.
        marker = front.get("app", "").strip().strip('"').strip("'")
        if marker != TRANSCRIPT_MARKER:
            report.not_transcripts.append((src, marker))
            continue
        group = front.get("group", "").strip()
        if not group:
            # COLLECTED, NOT SKIPPED, and the export refuses below rather than omitting them here.
            # An untagged transcript belongs to no workspace, so silently leaving it out puts it in
            # NO scope at all — present on disk, absent from every corpus that claims to cover it.
            # That is the silent-absence state, and it is worse than a refusal the operator can act
            # on: the call is gone from search and nothing ever said so.
            untagged.append(src)
            continue
        if _slug(group, _MAX_SLUG) != want:
            report.foreign.append((src, group))
            continue
        selected.append((src, rel))

    if untagged:
        shown = "\n".join(f"    {p.name}" for p in sorted(untagged)[:10])
        more = f"\n    … and {len(untagged) - 10} more" if len(untagged) > 10 else ""
        raise ExportError(
            f"{len(untagged)} transcript(s) under {source_dir} carry no `group:`, so this export "
            f"cannot say whether they belong to {workspace!r}:\n{shown}{more}\n"
            "Refusing rather than guessing. Filing them under the workspace being exported would "
            "assert a claim about the operator's data that nothing on disk supports, and dropping "
            "them would leave calls that exist in no scope at all — unreachable from every corpus "
            "that claims to cover them, with nothing saying so.\n"
            f"Remedy: add `group: \"{workspace}\"` to each transcript's frontmatter (or the group it "
            "does belong to), then export again. Scripta writes this key itself for calls recorded "
            "after a workspace is set; these predate that or were recovered without one."
        )

    written: set[Path] = set()
    for src, rel in selected:
        text, record = render_note(src, rel)
        target = vault_dir / record.note
        # Written only when the bytes differ, so an unchanged corpus does not restat every note's
        # mtime — the refresh agent's freshness check reads mtimes.
        if not target.exists() or target.read_bytes() != text.encode("utf-8"):
            target.write_text(text, "utf-8")
        written.add(target)
        report.notes.append(record)

    if not report.notes:
        # Two different facts, and collapsing them sends the operator to the wrong remedy: an empty
        # folder needs transcripts, while a folder full of OTHER workspaces' calls needs the right
        # workspace name. The second is the ordinary consequence of the filter now working.
        if report.foreign:
            groups = sorted({g for _, g in report.foreign})
            raise ExportError(
                f"No transcript under {source_dir} belongs to workspace {workspace!r}. "
                f"{len(report.foreign)} belong to: {', '.join(repr(g) for g in groups)}. "
                "Refusing to write a vault that composes zero notes. Export one of those "
                "workspaces, or set the workspace to match the calls you meant."
            )
        raise ExportError(
            f"{source_dir} holds no transcripts. Refusing to write a vault that composes zero "
            "notes — `resolve_scope` would refuse it anyway, one step later and less clearly."
        )

    for stale in sorted(notes_dir.glob("*.md")):
        if stale not in written:
            stale.unlink()
            report.pruned.append(stale)

    write_manifest(vault_dir, scope)
    return report
