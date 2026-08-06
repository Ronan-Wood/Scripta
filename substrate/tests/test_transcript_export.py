"""The Scripta corpus bridge — the spine an exported transcript declares, and the key it joins on.

`compose` refuses a whole SCOPE, not a note, when a spine field is missing or unknown, so this
exporter's output has to be right for the eleventh transcript nobody has recorded yet as well as
for the ten that exist. Each test below pins one way the bridge could break silently:

  * the four spine values are the ones argued for in `transcript_export`, and `class: conversation`
    is what keeps the corpus out of DEFAULT retrieval. A transcript exported as any other class
    reads as a settled note, which is the lie the class axis exists to prevent.
  * the doc_id is derived from the workspace-RELATIVE PATH and nothing else. Content-derived would
    mint a second document every time a call was re-transcribed and leave the old one answering
    queries beside it (reconcile keys on doc_id); absolute-path-derived would re-key the whole
    corpus the day the operator moved `outputFolderPath`.
  * the export is byte-idempotent. A re-export that rewrote unchanged notes would show up as a
    corpus-wide diff at every refresh tick.
  * the emitted frontmatter parses back through the ENGINE'S OWN reader. A frontmatter line without
    a colon is not treated as frontmatter at all — `_parse_frontmatter` returns the whole block as
    body — so a bad emitter would turn the entire spine into prose under a green export.
  * `domains` is never empty, because NOTHING IN THE ENGINE REFUSES AN EMPTY `domains`. Unlike
    status/doc_type/confidence there is no gate, so a transcript with no usable tags would land
    unfilterable and green.

Runnable with plain `python tests/test_transcript_export.py`.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from substrate import spine  # noqa: E402
from substrate.classes import DECLARABLE_CLASSES, EXCLUDED_CLASSES  # noqa: E402
from substrate.markdown.reader import _DOC_ID, _parse_frontmatter, read_markdown  # noqa: E402
from substrate.transcript_export import (  # noqa: E402
    BASE_DOMAIN,
    TRANSCRIPT_CLASS,
    TRANSCRIPT_CONFIDENCE,
    TRANSCRIPT_DOC_TYPE,
    TRANSCRIPT_MARKER,
    TRANSCRIPT_STATUS,
    ExportError,
    _identity,
    assert_not_overlapping,
    assert_not_synced,
    doc_id_for_transcript,
    export_workspace,
    render_note,
    scope_name,
    sync_root_for,
)

# The app's real output shape, trimmed: frontmatter with no spine, an H1, and `**[m:ss]**` turns.
TRANSCRIPT = """\
---
date: 2026-07-13
time: "15:39"
duration: "10:29"
participants: []
tags: ["call", "project management", "call-transcriber"]
app: call-transcriber
group: "default"
---

# Call — 2026-07-13 15:39

**[0:00]** hey how are you doing are you in radnor

**[0:11]** i live kind of upper derby
"""

# The 184-byte case that actually exists in the corpus: a call with nothing said in it.
EMPTY_TRANSCRIPT = """\
---
date: 2026-07-14
time: "15:10"
duration: "0:20"
participants: []
tags: ["call", "call-transcriber"]
app: call-transcriber
group: "default"
---

# Call — 2026-07-14 15:10

_(No speech detected.)_
"""


def _in_group(text: str, group: str) -> str:
    """The same transcript filed under a different workspace. `group:` is what Scripta writes from
    `AppSettings.recordingGroup` at record time, and what selection is keyed on."""
    return text.replace('group: "default"', f'group: "{group}"', 1)


def _untagged(text: str) -> str:
    """A transcript with no `group:` — the real shape of the operator's recovered calls, which
    predate the workspace being set."""
    return text.replace('group: "default"\n', "", 1)


def _as_marker(text: str, marker: str) -> str:
    """The same file carrying one of Scripta's OTHER `app:` markers. Scripta writes four kinds of
    markdown into one output folder — transcripts, `Notes/` living notes, `Files/` extracted PDFs
    and `Entities/` wikilink stubs — and only the first names a conversation."""
    return text.replace(f"app: {TRANSCRIPT_MARKER}\n", f"app: {marker}\n", 1)


def _unmarked(text: str) -> str:
    """Markdown with no `app:` key at all — something the operator dropped in the folder, which
    Scripta did not write and this exporter does not own."""
    return text.replace(f"app: {TRANSCRIPT_MARKER}\n", "", 1)


def _workspace(files: dict[str, str]) -> tuple[Path, Path]:
    """(source dir, vault dir) inside a fresh temp dir the caller lets leak — tests are short."""
    tmp = Path(tempfile.mkdtemp())
    src = tmp / "transcripts"
    for name, text in files.items():
        path = src / name
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(text, "utf-8")
    return src, tmp / "vault"


def test_spine_values_are_in_the_engine_vocabularies() -> None:
    """Every declared value is one `compose` accepts. A typo here refuses the whole scope."""
    assert TRANSCRIPT_STATUS in spine.STATUSES
    assert TRANSCRIPT_DOC_TYPE in spine.DOC_TYPES
    assert TRANSCRIPT_CONFIDENCE in spine.DECLARABLE_CONFIDENCES
    assert TRANSCRIPT_CLASS in DECLARABLE_CLASSES
    # `unjudged` is the ABSENCE marker and raises on declaration — the value that would look like
    # the honest choice for a transcript is the one the engine refuses.
    assert TRANSCRIPT_CONFIDENCE != spine.UNJUDGED_CONFIDENCE


def test_status_stays_in_default_retrieval_and_class_does_the_withholding() -> None:
    """Exclusion comes from exactly ONE axis. Marking a transcript `archived` would produce the
    same observable behaviour for a different reason, and then `--include-archived` alone would
    open half the corpus."""
    assert TRANSCRIPT_STATUS in spine.INCLUDED_STATUSES
    assert TRANSCRIPT_CLASS in EXCLUDED_CLASSES


def test_doc_id_is_path_derived_not_content_derived() -> None:
    """Same path + different content = same doc_id, so re-transcribing a call UPDATES its document
    instead of minting a second one beside it."""
    src, vault = _workspace({"Call 2026-07-13 1539.md": TRANSCRIPT})
    text_a, rec_a = render_note(src / "Call 2026-07-13 1539.md", "Call 2026-07-13 1539.md")
    (src / "Call 2026-07-13 1539.md").write_text(TRANSCRIPT + "\n**[0:20]** and one more turn\n")
    text_b, rec_b = render_note(src / "Call 2026-07-13 1539.md", "Call 2026-07-13 1539.md")
    assert rec_a.doc_id == rec_b.doc_id, (rec_a.doc_id, rec_b.doc_id)
    assert text_a != text_b, "content change must still change the note"
    assert rec_a.source_sha256 != rec_b.source_sha256, "raw_sha256 must track the transcript"

    # Different path = different doc_id, even for a shared filename in another subdirectory.
    assert doc_id_for_transcript("a/Call.md") != doc_id_for_transcript("b/Call.md")
    _ = vault


def test_doc_id_is_doc_id_shaped_for_hostile_filenames() -> None:
    """`_DOC_ID` admits only `[a-z0-9][a-z0-9._-]{0,63}`. A filename with an em dash, uppercase,
    spaces, or nothing but punctuation must still produce a legal key rather than one the vault's
    own pre-scan silently replaces with a filename+content hash."""
    for rel in ("Project Management and Deal Negotiations — 2026-07-15 0932.md",
                "Call — 2026-07-14 1510.md",
                "———.md",
                "9.md",
                "ÜBER Käse Ω.md"):
        did = doc_id_for_transcript(rel)
        assert _DOC_ID.fullmatch(did), (rel, did)
        assert len(did) <= 64, (rel, did)


def test_emitted_frontmatter_parses_back_through_the_engine_reader() -> None:
    """The whole spine survives `_parse_frontmatter`. A single line without a colon makes the
    parser treat the block as body text, so the note would ingest with NO spine at all."""
    src, _ = _workspace({"Call 2026-07-13 1539.md": TRANSCRIPT})
    text, rec = render_note(src / "Call 2026-07-13 1539.md", "Call 2026-07-13 1539.md")
    front, body = _parse_frontmatter(text)
    assert front, "emitted frontmatter did not parse as frontmatter"
    assert front["doc_id"] == rec.doc_id
    assert front["status"] == TRANSCRIPT_STATUS
    assert front["doc_type"] == TRANSCRIPT_DOC_TYPE
    assert front["confidence"] == TRANSCRIPT_CONFIDENCE
    assert front["class"] == TRANSCRIPT_CLASS
    # The app's own metadata rides along and a quoted value round-trips unchanged.
    assert front["time"] == "15:39", front["time"]
    assert front["app"] == "call-transcriber"
    # The body is verbatim: the turns and their timestamps are what Scripta joins on.
    assert "**[0:11]** i live kind of upper derby" in body


def test_reader_lands_the_spine_the_export_declared() -> None:
    """End of the wire the exporter controls: what `read_markdown` actually produces."""
    src, _ = _workspace({"Call 2026-07-13 1539.md": TRANSCRIPT})
    text, rec = render_note(src / "Call 2026-07-13 1539.md", "Call 2026-07-13 1539.md")
    note = src.parent / "note.md"
    note.write_text(text, "utf-8")
    doc, _body, _stats = read_markdown(note)
    assert doc.doc_id == rec.doc_id
    assert doc.status == TRANSCRIPT_STATUS
    assert doc.doc_type == TRANSCRIPT_DOC_TYPE
    assert doc.confidence == TRANSCRIPT_CONFIDENCE
    assert doc.document_class == TRANSCRIPT_CLASS
    assert doc.raw_sha256 == rec.source_sha256
    assert doc.raw_location == str(src / "Call 2026-07-13 1539.md")
    assert BASE_DOMAIN in doc.domains


def test_domains_are_never_empty_and_tags_are_slugified() -> None:
    """`domains` is the one spine field with NO presence gate anywhere in the engine, so the floor
    is the exporter's job. A tag with a space is not a legal domain and `_parse_list` would drop it
    silently — slugify rather than lose it."""
    src, _ = _workspace({"c.md": TRANSCRIPT})
    _text, rec = render_note(src / "c.md", "c.md")
    assert rec.domains[0] == BASE_DOMAIN
    assert "project-management" in rec.domains, rec.domains

    tagless = TRANSCRIPT.replace('tags: ["call", "project management", "call-transcriber"]',
                                 "tags: []")
    (src / "c.md").write_text(tagless, "utf-8")
    _text, rec = render_note(src / "c.md", "c.md")
    assert rec.domains == [BASE_DOMAIN], rec.domains


def test_export_is_byte_idempotent() -> None:
    """Nothing derived from the clock or the run, so an unchanged corpus re-exports to the same
    bytes. Otherwise every refresh tick would see a corpus-wide diff."""
    src, vault = _workspace({"a.md": TRANSCRIPT, "b.md": EMPTY_TRANSCRIPT})
    first = export_workspace(src, vault, "default")
    before = {p: p.read_bytes() for p in sorted((vault / "_sources/transcripts").glob("*.md"))}
    second = export_workspace(src, vault, "default")
    after = {p: p.read_bytes() for p in sorted((vault / "_sources/transcripts").glob("*.md"))}
    assert before == after, "re-export changed bytes"
    assert [n.doc_id for n in first.notes] == [n.doc_id for n in second.notes]
    assert not second.pruned


def test_export_prunes_a_note_whose_transcript_is_gone() -> None:
    """`assert_composed` refuses an index holding a doc this compose did not ingest, so a left-over
    note fails the NEXT compose — after the operator already deleted the transcript deliberately."""
    src, vault = _workspace({"a.md": TRANSCRIPT, "b.md": EMPTY_TRANSCRIPT})
    export_workspace(src, vault, "default")
    (src / "b.md").unlink()
    rep = export_workspace(src, vault, "default")
    assert len(rep.notes) == 1
    assert len(rep.pruned) == 1, rep.pruned
    assert len(list((vault / "_sources/transcripts").glob("*.md"))) == 1


def test_manifest_does_not_inherit_a_synced_vault() -> None:
    """Doc 3 §4: the transcript corpus is local and non-synced. Every other scope inherits
    `core-vault` out of OneDrive; composing that tier into THIS index would put synced content in
    the one place that must stay local."""
    src, vault = _workspace({"a.md": _in_group(TRANSCRIPT, "work")})
    rep = export_workspace(src, vault, "work")
    manifest = (vault / ".substrate.toml").read_text("utf-8")
    assert 'name = "scripta-work"' in manifest
    assert "inherits = []" in manifest
    assert rep.scope == "scripta-work"


def test_scope_name_is_per_workspace() -> None:
    assert scope_name("Work Calls") == "scripta-work-calls"
    try:
        scope_name("———")
    except ExportError:
        pass
    else:
        raise AssertionError("a workspace that slugifies to nothing must be refused")


def test_sync_detection_is_identity_based_not_prefix_based() -> None:
    """A File-Provider folder presented at a second path has the SAME (st_dev, st_ino) and a
    different prefix. This is the property that catches `~/Documents` under "Desktop & Documents
    Folders" — a prefix test on `~/Library/Mobile Documents` returns clean for it."""
    tmp = Path(tempfile.mkdtemp())
    real = tmp / "provider-root"
    (real / "corpus").mkdir(parents=True)
    presented = tmp / "presented"
    presented.symlink_to(real)  # stands in for the provider's second presentation

    marks = {_identity(real)}
    # The presented path has a different prefix and the same identity.
    assert not str(presented).startswith(str(real))
    assert _identity(presented) in marks
    assert _identity(presented / "corpus") == _identity(real / "corpus")


def test_synced_destination_is_refused() -> None:
    """The one half of Doc 3 §4's privacy condition this module can enforce. Skipped when the
    machine has no cloud root to test against, rather than passing vacuously."""
    home = Path.home()
    roots = [r for pattern in ("Library/CloudStorage/*",
                               "Library/Mobile Documents/com~apple~CloudDocs")
             for r in home.glob(pattern)]
    if not roots:
        print("      (no cloud root on this machine — nothing to test against)")
        return
    dest = roots[0] / "substrate-export-test-should-never-be-created"
    assert sync_root_for(dest) is not None, dest
    try:
        assert_not_synced(dest)
    except ExportError as e:
        assert "cloud-synced" in str(e), e
    else:
        raise AssertionError(f"{dest} is inside {roots[0]} and was not refused")
    assert not dest.exists(), "the guard must refuse BEFORE anything is written"


def test_local_destination_passes() -> None:
    src, vault = _workspace({"a.md": TRANSCRIPT})
    assert sync_root_for(vault) is None, sync_root_for(vault)
    assert_not_synced(vault)
    assert export_workspace(src, vault, "default").notes


def test_empty_source_dir_is_refused() -> None:
    """A vault composing zero notes is refused by `resolve_scope` one step later and less clearly.
    Refuse here, before anything is written."""
    src, vault = _workspace({"a.md": TRANSCRIPT})
    (src / "a.md").unlink()
    try:
        export_workspace(src, vault, "default")
    except ExportError as e:
        assert "zero notes" in str(e), e
    else:
        raise AssertionError("an empty transcript folder must be refused")


def test_another_workspaces_transcripts_are_not_exported() -> None:
    """THE WALL IS THE FILTER. One `outputFolderPath` holds every workspace's calls, so without
    selection each workspace's scope held all of them and `scripta-personal` answered with work
    calls — the privacy wall Doc 3 §4 names being a label rather than a boundary."""
    src, vault = _workspace({
        "mine.md": _in_group(TRANSCRIPT, "personal"),
        "theirs.md": _in_group(TRANSCRIPT, "CBRE"),
    })
    rep = export_workspace(src, vault, "personal")
    assert len(rep.notes) == 1, rep.notes
    assert [g for _, g in rep.foreign] == ["CBRE"], rep.foreign
    # The excluded transcript is not merely absent from the report — it is absent from the vault.
    written = sorted(p.name for p in (vault / "_sources" / "transcripts").glob("*.md"))
    assert len(written) == 1, written


def test_group_is_matched_as_a_slug_because_the_scope_name_is() -> None:
    """`scope_name` slugifies, so "CBRE" and "cbre" name ONE scope and must select one set of
    transcripts. Matching raw would let two spellings write the same scope with different
    contents depending on which was typed."""
    src, vault = _workspace({"a.md": _in_group(TRANSCRIPT, "CBRE")})
    rep = export_workspace(src, vault, "cbre")
    assert len(rep.notes) == 1, rep.notes
    assert rep.scope == scope_name("CBRE") == "scripta-cbre"


def test_an_untagged_transcript_refuses_the_export_and_names_the_remedy() -> None:
    """Neither filing nor dropping it is acceptable: filing asserts a claim nothing on disk
    supports, dropping leaves a call in NO scope — unreachable from every corpus that claims to
    cover it, with nothing saying so."""
    src, vault = _workspace({
        "tagged.md": TRANSCRIPT,
        "recovered.md": _untagged(TRANSCRIPT),
    })
    try:
        export_workspace(src, vault, "default")
    except ExportError as e:
        assert "recovered.md" in str(e), e          # names the file
        assert 'group: "default"' in str(e), e      # names the remedy
    else:
        raise AssertionError("an untagged transcript must refuse the export")


def test_a_refused_export_writes_nothing() -> None:
    """The refusal is free of side effects because selection completes before any write. Deciding
    and writing in one pass would leave however many notes preceded the first untagged file."""
    src, vault = _workspace({
        "a-tagged.md": TRANSCRIPT,
        "z-untagged.md": _untagged(TRANSCRIPT),
    })
    try:
        export_workspace(src, vault, "default")
    except ExportError:
        pass
    notes = vault / "_sources" / "transcripts"
    assert not notes.exists() or not list(notes.glob("*.md")), list(notes.glob("*.md"))


def test_all_foreign_is_refused_with_the_groups_that_do_exist() -> None:
    """An empty folder and a folder full of OTHER workspaces' calls need different remedies —
    transcripts vs the right workspace name — so they must not collapse into one message."""
    src, vault = _workspace({"a.md": _in_group(TRANSCRIPT, "CBRE")})
    try:
        export_workspace(src, vault, "personal")
    except ExportError as e:
        assert "'CBRE'" in str(e), e
        assert "zero notes" in str(e), e
    else:
        raise AssertionError("a workspace with no transcripts of its own must be refused")


def test_only_the_transcript_marker_is_exported() -> None:
    """Scripta writes four `app:` markers into ONE output folder and all four carry a `group:`, so
    the workspace filter alone passed every one of them. Measured 2026-08-05 before this gate: a
    four-file folder reported "4 transcript(s)" for one transcript, one living note, one extracted
    PDF and one entity stub — each written out as `class: conversation`."""
    src, vault = _workspace({
        "Call.md": TRANSCRIPT,
        "Notes/Deal thoughts.md": _as_marker(TRANSCRIPT, "call-transcriber-note"),
        "Files/Report — extracted.md": _as_marker(TRANSCRIPT, "call-transcriber-doc"),
        "Entities/default/Jerry.md": _as_marker(TRANSCRIPT, "call-transcriber-entity"),
    })
    rep = export_workspace(src, vault, "default")
    assert [n.rel_source for n in rep.notes] == ["Call.md"], rep.notes
    assert sorted(m for _, m in rep.not_transcripts) == [
        "call-transcriber-doc", "call-transcriber-entity", "call-transcriber-note",
    ], rep.not_transcripts
    # Absent from the vault, not merely from the count.
    written = sorted(p.name for p in (vault / "_sources" / "transcripts").glob("*.md"))
    assert len(written) == 1, written


def test_markdown_with_no_marker_is_not_ours_to_export() -> None:
    """The RetentionPruner's invariant in the other direction: the app never deletes what it does
    not own, and publishing what it does not own into a queryable corpus is the same claim."""
    src, vault = _workspace({"Call.md": TRANSCRIPT, "README.md": _unmarked(TRANSCRIPT)})
    rep = export_workspace(src, vault, "default")
    assert [n.rel_source for n in rep.notes] == ["Call.md"], rep.notes
    assert [(p.name, m) for p, m in rep.not_transcripts] == [("README.md", "")], rep.not_transcripts


def test_a_non_transcript_cannot_refuse_the_export_over_its_group() -> None:
    """THE MARKER GATE RUNS FIRST, and this is why. An entity stub for an ungrouped call carries no
    usable `group:`, so checked second it would abort an export of real transcripts — naming a file
    the operator cannot fix by tagging, because a derived stub is not theirs to tag."""
    src, vault = _workspace({
        "Call.md": TRANSCRIPT,
        "Entities/Ungrouped/Jerry.md": _untagged(_as_marker(TRANSCRIPT, "call-transcriber-entity")),
    })
    rep = export_workspace(src, vault, "default")     # must not raise
    assert [n.rel_source for n in rep.notes] == ["Call.md"], rep.notes


def test_the_marker_that_disproved_the_class_was_being_copied_through() -> None:
    """`_RESERVED_KEYS` does not cover `app`, so a note exported before this gate carried
    `app: call-transcriber-doc` three lines under `class: conversation`. The key that disproved the
    classification was copied through, unread, by the code that made it — so the guard belongs on
    the selection, and `app` stays carried through as honest provenance for a real transcript."""
    src, _ = _workspace({"Call.md": TRANSCRIPT})
    text, _ = render_note(src / "Call.md", "Call.md")
    assert f"app: {TRANSCRIPT_MARKER}" in text, text
    assert f"class: {TRANSCRIPT_CLASS}" in text, text


def test_an_overlapping_destination_is_refused() -> None:
    """THE PRUNE IS WHY. This module deletes every `*.md` in `<dest>/_sources/transcripts/` it did
    not write, claiming to own that directory — and capture now writes its ONLY copy of every call
    into exactly that relative path. Reproduced 2026-08-06 before this guard: source == dest read
    `Call — 2026-08-06 0900.md`, wrote `call-…-d6148da9.md` beside it, and unlinked the original.
    The audio is deleted after a successful transcript write, so that is the only copy."""
    src, _ = _workspace({"a.md": TRANSCRIPT})
    for source, dest in [(src, src), (src, src / "sub"), (src / "inner", src)]:
        try:
            assert_not_overlapping(source, dest)
        except ExportError as e:
            assert "overlaps" in str(e), e
            assert "PRUNES" in str(e), e
        else:
            raise AssertionError(f"{dest} overlapping {source} must be refused")


def test_a_separate_destination_is_allowed() -> None:
    """The ordinary case still passes — the guard is about overlap, not about strictness."""
    src, vault = _workspace({"a.md": TRANSCRIPT})
    assert_not_overlapping(src, vault)
    rep = export_workspace(src, vault, "default")
    assert len(rep.notes) == 1, rep.notes


if __name__ == "__main__":
    _tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    _failed = 0
    for _t in _tests:
        try:
            _t()
            print(f"  PASS  {_t.__name__}")
        except Exception as e:  # noqa: BLE001
            _failed += 1
            print(f"  FAIL  {_t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(_tests) - _failed}/{len(_tests)} passed")
    raise SystemExit(1 if _failed else 0)
