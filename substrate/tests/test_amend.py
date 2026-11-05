"""Amending an existing note: a diff to review, and a write that refuses if the note moved.

The add path refuses any existing target, so until this path existed an approved change to a note
had to be applied by hand: `diff` the two versions, then `cp`, from a shell that macOS may not let
reach the vault. Every guarantee below is one that manual sequence either got from a human
remembering to check, or did not get at all.

The refusals matter as much as the write. Each protects something a wrong edit would destroy
without trace: the bytes someone else wrote between plan and commit, a note outside the project
vault reached through a link, a transcript's record of what was said, a declared identity.

Runnable with plain `python tests/test_amend.py`; discovered by pytest.
"""

from __future__ import annotations

import os
import stat
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import notes  # noqa: E402

FRONT = b"---\nstatus: active\ndoc_type: decision\nconfidence: proposed\ndomains: [retrieval]\n---\n"
BODY = (b"\n# Retrieval stack decision\n\nThe MCP surface runs the measured stack, so a caller can "
        b"tell a 0.698 answer from a lexical one.\n")
CURRENT = FRONT + BODY
AMENDED = CURRENT + b"\n**Amended 2026-11-04:** previously lexical-only, now hybrid, because it measured better.\n"


def _vault() -> Path:
    """A project vault beside a core vault, the shape a composed scope has on disk."""
    root = Path(tempfile.mkdtemp())
    v = root / "demo-vault"
    for folder in notes.WRITABLE_FOLDERS:
        (v / folder).mkdir(parents=True)
    core = root / "demo-core-vault" / "00-operator"
    core.mkdir(parents=True)
    (core / "operator.md").write_bytes(CURRENT)
    return v


def _note(v: Path, rel: str = "04-synthesis/decision.md", data: bytes = CURRENT) -> Path:
    p = v / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)
    return p


def _plan(v: Path, book: notes.PlanBook, path: str = "04-synthesis/decision.md",
          content: bytes = AMENDED) -> notes.AmendPlan:
    return notes.plan_amend(project_vault=v, path=path, content=content, book=book)


def _commit(v: Path, book: notes.PlanBook, token: str, path: str = "04-synthesis/decision.md",
            content: bytes = AMENDED):
    return notes.commit_amend(project_vault=v, path=path, content=content, confirm_token=token,
                              book=book)


def _refuses(fn, *, containing: str = "") -> str:
    try:
        fn()
    except notes.NoteError as e:
        assert containing in str(e), f"expected {containing!r} in: {e}"
        return str(e)
    raise AssertionError("expected a NoteError")


def _pinned(content: bytes, base: bytes = CURRENT, stem: str = "decision") -> bytes:
    """`content` as amend writes it over an undeclared `base`: with the id `base` has now pinned as
    its first frontmatter line."""
    import hashlib

    from substrate.extract.base import doc_id_from

    did = doc_id_from(stem, hashlib.sha256(base).hexdigest())
    return content.replace(b"---\n", b"---\ndoc_id: " + did.encode() + b"\n", 1)


def _no_staging_left(d: Path) -> None:
    left = [p.name for p in d.iterdir() if p.name.endswith(".tmp")]
    assert not left, f"a staging file was left behind: {left}"


# ---------------------------------------------------------------- the plan

def test_plan_writes_nothing_and_shows_the_diff() -> None:
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    plan = _plan(v, book)
    assert p.read_bytes() == CURRENT, "a plan must not touch the note"
    assert plan.confirm_token
    assert plan.diff.startswith("--- a/04-synthesis/decision.md\n+++ b/04-synthesis/decision.md\n")
    assert "+**Amended 2026-11-04:**" in plan.diff
    import hashlib
    assert plan.base_sha256 == hashlib.sha256(CURRENT).hexdigest()
    assert plan.new_sha256 == hashlib.sha256(_pinned(AMENDED)).hexdigest()
    assert plan.passages >= 1


def test_plan_names_every_spine_field_that_changes() -> None:
    """Confidence laundering is the edit this review exists to catch: a `proposed` note quietly
    becoming `verified`. The plan says so as a field and as a warning, not only in the diff."""
    v, book = _vault(), notes.PlanBook()
    _note(v)
    plan = _plan(v, book, content=AMENDED.replace(b"confidence: proposed", b"confidence: verified"))
    assert "confidence" in plan.spine_changed
    assert plan.spine_before["confidence"] == "proposed"
    assert plan.spine_after["confidence"] == "verified"
    assert any("confidence changes proposed → verified" in w for w in plan.warnings)


def test_an_undeclared_id_is_pinned_as_the_id_the_note_has_now() -> None:
    """With no `doc_id:` line the id derives from the stem and a hash of the bytes, so every edit
    gave the note a new identity and broke whatever named it. The id it has now is written into
    the frontmatter in the same edit, where the diff shows it, and the reader takes it as given
    from then on — the new line changing the hashed bytes does not matter."""
    from substrate.extract.base import doc_id_for
    from substrate.markdown.reader import read_markdown

    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    now = doc_id_for(p)
    plan = _plan(v, book)
    assert plan.pinned_doc_id == now
    assert f"+doc_id: {now}" in plan.diff.split("\n")
    assert plan.spine_before["doc_id"] == plan.spine_after["doc_id"] == now
    assert "doc_id" not in plan.spine_changed
    assert any("doc_id pinned" in w and now in w for w in plan.warnings), plan.warnings

    _commit(v, book, plan.confirm_token)
    assert doc_id_for(p) != now, "the bytes changed, so a derived id would have moved"
    assert read_markdown(p)[0].doc_id == now, "the declared id is the one the reader takes"

    p.rename(p.with_name("renamed.md"))
    assert read_markdown(p.with_name("renamed.md"))[0].doc_id == now, "a rename keeps the id"


def test_compose_accepts_a_pinned_note_under_the_same_id() -> None:
    """The duplicate-id gate keys on the EFFECTIVE id, and the pin is the id the note had, so the
    scope composes and the note keeps its identity."""
    from substrate import vault as vault_mod
    from substrate.extract.base import doc_id_for

    v, book = _vault(), notes.PlanBook()
    (v / ".substrate.toml").write_text('name = "demo"\ninherits = []\n', encoding="utf-8")
    p = _note(v)
    _note(v, "02-areas/other.md", CURRENT + b"\nAnother note.\n")
    now = doc_id_for(p)
    plan = _plan(v, book)
    _commit(v, book, plan.confirm_token)
    scope = vault_mod.resolve_scope(v)
    assert any(n.path.resolve() == p.resolve() for n in scope.notes)
    from substrate.markdown.reader import read_markdown
    assert read_markdown(p)[0].doc_id == now


def test_a_crlf_note_is_pinned_with_its_own_line_ending() -> None:
    v = _vault()
    crlf = CURRENT.replace(b"\n", b"\r\n")
    _note(v, data=crlf)
    plan = _plan(v, notes.PlanBook(), content=crlf + b"\r\nA CRLF addition.\r\n")
    assert plan.pinned_doc_id
    assert f"+doc_id: {plan.pinned_doc_id}\u27e8U+000D\u27e9" in plan.diff.split("\n")


def test_a_hand_written_pin_must_be_the_current_id() -> None:
    from substrate.extract.base import doc_id_for

    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    now = doc_id_for(p)
    hand = AMENDED.replace(b"---\n", f"---\ndoc_id: {now}\n".encode(), 1)
    plan = _plan(v, book, content=hand)
    assert plan.pinned_doc_id == now
    assert plan.diff.count("doc_id:") == 1, "the pin is not added a second time"
    other = AMENDED.replace(b"---\n", b"---\ndoc_id: something-else\n", 1)
    _refuses(lambda: _plan(v, book, content=other), containing=f"Write the line as `doc_id: {now}`")


def test_a_hand_written_pin_the_reader_would_ignore_is_refused() -> None:
    """A note named `café.md` derives `café-xxxxxxxx`, outside the declared shape. Written by hand
    it matched the current id, so the plan reported it pinned, while the reader ignored the line
    and derived a new id from the changed bytes (crosscheck, 2026-11-04)."""
    from substrate.extract.base import doc_id_for

    v = _vault()
    p = _note(v, "04-synthesis/caf\u00e9.md")
    hand = AMENDED.replace(b"---\n", f"---\ndoc_id: {doc_id_for(p)}\n".encode(), 1)
    _refuses(lambda: _plan(v, notes.PlanBook(), path="04-synthesis/caf\u00e9.md", content=hand),
             containing="amend does not assign a new id")


def test_an_empty_or_ill_shaped_doc_id_line_is_pinned_not_honoured() -> None:
    """A blank `doc_id:` property, or `doc_id: Not Valid`, is ignored by the reader, so the note
    derives its id like an undeclared one. It counted as declared, so it was never pinned, moved on
    every edit, and could not even be fixed by hand (crosscheck, 2026-11-04)."""
    from substrate.extract.base import doc_id_for

    for bad in (b"doc_id:\n", b"doc_id: Not Valid\n"):
        v, book = _vault(), notes.PlanBook()
        base = CURRENT.replace(b"---\n", b"---\n" + bad, 1)
        p = _note(v, data=base)
        now = doc_id_for(p)
        # Sent back as it was, the bad line would switch the pin off: refused, with the fix.
        _refuses(lambda base=base, v=v, book=book: _plan(v, book, content=base + b"\nedited\n"),
                 containing=f"Write the line as `doc_id: {now}`")
        # Written as the current id: accepted, and reported as the pin.
        fixed = base.replace(bad, f"doc_id: {now}\n".encode()) + b"\nedited\n"
        plan = _plan(v, book, content=fixed)
        assert plan.pinned_doc_id == now
        assert "doc_id" not in plan.spine_changed
        # Left out: amend writes it in.
        plan = _plan(v, book, content=base.replace(bad, b"") + b"\nedited\n")
        assert plan.pinned_doc_id == now


def test_a_bare_cr_note_is_pinned() -> None:
    """The reader normalises a lone `\\r` to a line break, so it finds this frontmatter; the pin
    did not, and the id moved."""
    v = _vault()
    cr = CURRENT.replace(b"\n", b"\r")
    _note(v, data=cr)
    plan = _plan(v, notes.PlanBook(), content=cr + b"\rA CR addition.\r")
    assert plan.pinned_doc_id
    assert "doc_id" not in plan.spine_changed


def test_the_recovery_warning_says_to_restore_in_place() -> None:
    """A pre-amend copy restored beside the note either declares the same id (a note that
    already declared one) and compose refuses the scope, or derives its own and composes as a
    second, duplicate note. Restoring in place is the only clean recovery."""
    v = _vault()
    _note(v)
    warning = next(w for w in _plan(v, notes.PlanBook()).warnings if "restore it IN PLACE" in w)
    assert "claims the same doc_id" in warning and "duplicate note" in warning, warning


def test_a_second_doc_id_line_is_refused() -> None:
    """The reader keeps the last `doc_id:` of several, so a decoy above the real line passed the
    identity gate while the approved diff showed an identity being added, and YAML tooling that
    rejects duplicate keys drops the whole block (crosscheck, 2026-11-04)."""
    from substrate.extract.base import doc_id_for

    v = _vault()
    p = _note(v)
    now = doc_id_for(p)
    decoy = AMENDED.replace(b"---\n", f"---\ndoc_id: someone-else\ndoc_id: {now}\n".encode(), 1)
    _refuses(lambda: _plan(v, notes.PlanBook(), content=decoy),
             containing=f"keep exactly one, `doc_id: {now}`")

    declared = CURRENT.replace(b"---\n", b"---\ndoc_id: kept-id\n", 1)
    _note(v, "02-areas/declared.md", declared)
    decoy = declared.replace(b"---\n", b"---\ndoc_id: someone-else\n", 1) + b"\nedited\n"
    _refuses(lambda: _plan(v, notes.PlanBook(), path="02-areas/declared.md", content=decoy),
             containing="keep exactly one, `doc_id: kept-id`")

    # Hidden behind a separator the reader's `splitlines` breaks on but a plain `\\n` split does
    # not: the count must see it, because the reader does (crosscheck, 2026-11-04).
    for sep in ("\u2028", "\u2029", "\x85", "\x0c", "\x0b", "\x1c"):
        hidden = AMENDED.replace(
            b"---\n", f"---\ntitle: x{sep}doc_id: someone-else\ndoc_id: {now}\n".encode(), 1)
        _refuses(lambda hidden=hidden: _plan(v, notes.PlanBook(), content=hidden),
                 containing="2 `doc_id:` lines")


def test_an_empty_doc_id_line_sent_back_is_called_empty_not_missing() -> None:
    v = _vault()
    base = CURRENT.replace(b"---\n", b"---\ndoc_id:\n", 1)
    _note(v, data=base)
    _refuses(lambda: _plan(v, notes.PlanBook(), content=base + b"\nedited\n"),
             containing="`doc_id:` line is empty")


def test_the_pin_warning_names_the_copies_it_turns_into_a_refusal() -> None:
    """Before the pin an edited copy derived its own id and composed beside the note; after it,
    the copy claims the same id and compose refuses the scope. On OneDrive, conflict copies are
    routine, so the plan says so."""
    v = _vault()
    _note(v)
    warning = next(w for w in _plan(v, notes.PlanBook()).warnings if "doc_id pinned" in w)
    assert "sync conflict" in warning and "compose refuses the scope" in warning, warning


def test_the_unpinnable_refusal_tells_empty_from_absent() -> None:
    v = _vault()
    _note(v, "04-synthesis/caf\u00e9.md", CURRENT.replace(b"---\n", b"---\ndoc_id:\n", 1))
    msg = _refuses(lambda: _plan(v, notes.PlanBook(), path="04-synthesis/caf\u00e9.md",
                                 content=AMENDED.replace(b"---\n", b"---\ndoc_id: foo\n", 1)),
                   containing="as it was (empty), or leave it out")
    assert "absent" not in msg


def test_an_unchanged_note_with_a_bad_doc_id_line_is_told_the_line_to_write() -> None:
    """Sent back unchanged, `doc_id:` empty: the note still needs its pin, and "nothing to amend"
    hid the one line that would fix it (adversary, 2026-11-04)."""
    from substrate.extract.base import doc_id_for

    v = _vault()
    base = CURRENT.replace(b"---\n", b"---\ndoc_id:\n", 1)
    p = _note(v, data=base)
    _refuses(lambda: _plan(v, notes.PlanBook(), content=base),
             containing=f"Write the line as `doc_id: {doc_id_for(p)}`")


def test_a_pin_that_would_end_the_block_early_is_not_written() -> None:
    """A first frontmatter line that starts with `---` is a legal key, but once a line sits above
    it, it reads as the closing fence and the block ends at the pin, moving every key into the
    body. Unpinned, the caller's own content is judged instead (crosscheck, 2026-11-04)."""
    content = b"---\n---title: x\nstatus: active\n---\n\n# Body\n"
    assert notes._pin(content, "pinned-x") == content


def test_a_pin_amend_could_not_write_says_where_to_write_it() -> None:
    """`_pin` declines when the first frontmatter line starts with `---`. The content still has a
    status, so it reached the identity gate, which called the line "empty" and said to leave it out
    — advice that refuses again forever (adversary, 2026-11-04)."""
    from substrate.extract.base import doc_id_for

    v = _vault()
    odd = b"---\n---title: x\n" + CURRENT[len(b"---\n"):]
    p = _note(v, data=odd)
    now = doc_id_for(p)
    _refuses(lambda: _plan(v, notes.PlanBook(), content=odd + b"\nedited\n"),
             containing="directly below the '---title: x' line (the first key")
    written_below = odd.replace(b"---title: x\n", f"---title: x\ndoc_id: {now}\n".encode(), 1)
    plan = _plan(v, notes.PlanBook(), content=written_below + b"\nedited\n")
    assert plan.pinned_doc_id == now


def test_an_unchanged_note_amend_could_not_pin_says_where_to_write_it() -> None:
    v = _vault()
    odd = b"---\n---title: x\n" + CURRENT[len(b"---\n"):]
    _note(v, data=odd)
    _refuses(lambda: _plan(v, notes.PlanBook(), content=odd),
             containing="directly below the '---title: x' line (the first key")


def test_the_declined_pin_advice_is_accepted_even_with_a_later_fence_like_line() -> None:
    """Advice to write the line "before the closing `---`" pointed at body text when a later key
    also started with `---` (the reader ends the block at the first `\\n---`), and the same refusal
    came back. Directly after the first line is a place a new line cannot move the end."""
    from substrate.extract.base import doc_id_for

    v = _vault()
    odd = (b"---\n---title: x\nstatus: active\ndoc_type: decision\nconfidence: proposed\n"
           b"---note: y\n---\n\n# Retrieval stack decision\n\nThe MCP surface runs the measured "
           b"stack, so a caller can tell a 0.698 answer from a lexical one.\n")
    p = _note(v, data=odd)
    now = doc_id_for(p)
    _refuses(lambda: _plan(v, notes.PlanBook(), content=odd + b"\nedited\n"),
             containing="directly below the '---title: x' line (the first key")
    followed = odd.replace(b"---title: x\n", f"---title: x\ndoc_id: {now}\n".encode(), 1)
    assert _plan(v, notes.PlanBook(), content=followed + b"\nedited\n").pinned_doc_id == now


def test_the_declined_pin_names_the_key_line_not_the_fence() -> None:
    """"The first line" also reads as the opening `---` fence, and a line written directly under
    the fence is exactly the placement that closes the block, so the refusal names the key line by
    its content, and the placement it rules out is refused (crosscheck, 2026-11-04)."""
    from substrate.extract.base import doc_id_for

    v = _vault()
    odd = b"---\n---title: x\n" + CURRENT[len(b"---\n"):]
    p = _note(v, data=odd)
    now = doc_id_for(p)
    msg = _refuses(lambda: _plan(v, notes.PlanBook(), content=odd + b"\nedited\n"),
                   containing="directly below the '---title: x' line (the first key")
    assert "not the opening `---` fence" in msg
    under_fence = odd.replace(b"---\n", f"---\ndoc_id: {now}\n".encode(), 1)
    _refuses(lambda: _plan(v, notes.PlanBook(), content=under_fence + b"\nedited\n"),
             containing="no status")


def test_the_named_key_line_is_marked_quoted_and_bounded() -> None:
    """The first key line is note content echoed into an error. Raw, a backtick broke the quoting,
    a bidi override or escape sequence reached the reader as-is, and a long line came back twice
    (crosscheck, 2026-11-05)."""
    v = _vault()
    first = "---title: `a` b \u202e x \x1b[2J " + "y" * 5_000
    odd = b"---\n" + first.encode() + b"\n" + CURRENT[len(b"---\n"):]
    _note(v, data=odd)
    msg = _refuses(lambda: _plan(v, notes.PlanBook(), content=odd + b"\nedited\n"),
                   containing="(the first key, not the opening `---` fence)")
    assert len(msg) < 1_000, len(msg)
    assert "\u202e" not in msg and "\x1b" not in msg
    assert "\u27e8U+202E\u27e9" in msg and "\u27e8U+001B\u27e9" in msg
    assert "'---title: `a` b" in msg


def test_an_unchanged_note_with_no_keys_has_nothing_to_amend() -> None:
    """The declined-pin refusal blamed a `---` first line for notes that have none: no frontmatter,
    an empty block, a thematic break. Sent back unchanged, those truly have nothing to amend."""
    v = _vault()
    for i, data in enumerate((b"# No frontmatter\n\nBody text.\n",
                              b"---\n\n---\n\nBody text.\n",
                              b"---\nprose line, not a key\n---\n\nBody text.\n")):
        _note(v, f"04-synthesis/n{i}.md", data)
        msg = _refuses(lambda i=i, data=data: _plan(v, notes.PlanBook(),
                                                    path=f"04-synthesis/n{i}.md", content=data),
                       containing="nothing to amend")
        assert "could not write" not in msg


def test_the_size_cap_is_exact_on_the_bytes_written() -> None:
    """Checked on the caller's bytes before the pin and on the bytes WRITTEN after it. A note whose
    pinned bytes land exactly on the cap passes the size checks and reaches the diff; one byte more
    is refused for its size."""
    from substrate.extract.base import doc_id_for

    v = _vault()
    p = _note(v)
    line = len(b"doc_id: \n") + len(doc_id_for(p))
    exact = CURRENT + b"x" * (notes.MAX_NOTE_BYTES - len(CURRENT) - line)
    assert _reaches_the_diff(lambda: _plan(v, notes.PlanBook(), content=exact)), \
        "pinned bytes exactly on the cap must pass the size check"
    _refuses(lambda: _plan(v, notes.PlanBook(), content=exact + b"x"),
             containing="with its pinned doc_id line is")
    by_hand = _pinned(CURRENT)
    full = by_hand + b"x" * (notes.MAX_NOTE_BYTES - len(by_hand))
    assert _reaches_the_diff(lambda: _plan(v, notes.PlanBook(), content=full)), \
        "a hand-written pin needs no room reserved"


def test_an_id_that_cannot_be_declared_is_left_unpinned_and_said_so() -> None:
    """A filename that is not ASCII derives an id outside the declared shape, which the reader
    would ignore and derive anyway. It is not pinned, and the plan says the id will change."""
    v = _vault()
    _note(v, "04-synthesis/caf\u00e9.md")
    plan = _plan(v, notes.PlanBook(), path="04-synthesis/caf\u00e9.md")
    assert plan.pinned_doc_id is None
    assert "doc_id" in plan.spine_changed
    assert any("cannot be pinned" in w for w in plan.warnings), plan.warnings


def test_plan_says_no_copy_of_the_old_version_is_kept() -> None:
    v, book = _vault(), notes.PlanBook()
    _note(v)
    assert any("keeps no copy" in w for w in _plan(v, book).warnings)


# ---------------------------------------------------------------- the write

def test_commit_with_the_plan_token_replaces_the_note() -> None:
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    os.chmod(p, 0o640)
    plan = _plan(v, book)
    target, previous, written = _commit(v, book, plan.confirm_token)
    assert target == p.resolve()
    assert p.read_bytes() == _pinned(AMENDED)
    import hashlib
    assert hashlib.sha256(p.read_bytes()).hexdigest() == plan.new_sha256, "the plan's bytes are written"
    assert written == plan.new_sha256
    assert previous == plan.base_sha256
    assert stat.S_IMODE(os.stat(p).st_mode) == 0o640, "the note's permissions must survive"
    assert not p.is_symlink()
    _no_staging_left(p.parent)
    assert len(book._issued) == 0, "a redeemed plan must leave the book empty"


def test_a_nested_area_note_is_reachable() -> None:
    """Most of atlas's and school's notes live under `02-areas/<area>/`. Addressing by folder and
    bare filename, as adding does, could not reach them."""
    v, book = _vault(), notes.PlanBook()
    p = _note(v, "02-areas/backend/decision.md")
    plan = _plan(v, book, path="02-areas/backend/decision.md")
    _commit(v, book, plan.confirm_token, path="02-areas/backend/decision.md")
    assert p.read_bytes() == _pinned(AMENDED)


def test_an_absolute_path_inside_the_vault_is_accepted() -> None:
    """`expand` reports a note's absolute path, so that is what a caller will have in hand."""
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    plan = _plan(v, book, path=str(p.resolve()))
    _commit(v, book, plan.confirm_token, path=str(p.resolve()))
    assert p.read_bytes() == _pinned(AMENDED)


# ---------------------------------------------------------------- compare-and-swap

def test_a_note_edited_after_the_plan_is_refused_and_keeps_the_edit() -> None:
    """THE concurrent-edit case: the human approved a diff against version A, someone saved
    version B in Obsidian, and the commit must not overwrite B with a change nobody reviewed
    against it. On the add path's semantics there was no check at all — the hand-run `diff` was it."""
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    plan = _plan(v, book)
    theirs = CURRENT + b"\nEdited in Obsidian while the plan was open.\n"
    p.write_bytes(theirs)
    _refuses(lambda: _commit(v, book, plan.confirm_token), containing="changed after the plan")
    assert p.read_bytes() == theirs, "the concurrent edit must survive"
    assert len(book._issued) == 0, "a plan against a moved note is burned, not left to retry"


def test_an_edit_landing_during_the_commit_is_caught_before_the_rename() -> None:
    """The last checksum is taken after staging, immediately before `rename`. Simulated by editing
    the note once the commit's own gate run has finished — after the first compare, before the
    swap — which is the window the first compare alone would leave open."""
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    plan = _plan(v, book)
    theirs = CURRENT + b"\nSaved by a sync mid-commit.\n"
    real = notes._check_amend

    def edit_after_gates(**kw):
        out = real(**kw)
        p.write_bytes(theirs)
        return out

    notes._check_amend = edit_after_gates
    try:
        _refuses(lambda: _commit(v, book, plan.confirm_token), containing="changed after the plan")
    finally:
        notes._check_amend = real
    assert p.read_bytes() == theirs
    _no_staging_left(p.parent)


def test_a_failed_swap_leaves_the_original_and_no_staging_file() -> None:
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    plan = _plan(v, book)
    real = os.rename

    def broken(*a, **k):
        raise OSError(28, "No space left on device")

    os.rename = broken
    try:
        _refuses(lambda: _commit(v, book, plan.confirm_token), containing="failed replacing")
    finally:
        os.rename = real
    assert p.read_bytes() == CURRENT
    _no_staging_left(p.parent)


# ---------------------------------------------------------------- the token

def test_commit_without_a_plan_is_impossible() -> None:
    v = _vault()
    p = _note(v)
    _refuses(lambda: _commit(v, notes.PlanBook(), "anything"), containing="not issued")
    assert p.read_bytes() == CURRENT


def test_a_token_does_not_authorise_different_content() -> None:
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    plan = _plan(v, book)
    other = AMENDED + b"\nA sentence nobody reviewed.\n"
    _refuses(lambda: _commit(v, book, plan.confirm_token, content=other), containing="not issued")
    assert p.read_bytes() == CURRENT


def test_a_token_is_single_use() -> None:
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    plan = _plan(v, book)
    _commit(v, book, plan.confirm_token)
    p.write_bytes(CURRENT)  # back to the planned base, so only the token can refuse
    _refuses(lambda: _commit(v, book, plan.confirm_token), containing="already been used")
    assert p.read_bytes() == CURRENT


def test_an_add_token_cannot_authorise_an_amend() -> None:
    """One PlanBook holds both kinds of token. An add plan for a new note must not become a way to
    replace an existing one."""
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    add = notes.plan(project_vault=v, content=AMENDED, filename="fresh.md", book=book)
    _refuses(lambda: _commit(v, book, add.confirm_token), containing="not issued")
    assert p.read_bytes() == CURRENT


# ---------------------------------------------------------------- symlinks and core

def test_a_symlinked_note_is_refused_wherever_it_points() -> None:
    v, book = _vault(), notes.PlanBook()
    outside = Path(tempfile.mkdtemp()) / "outside.md"
    outside.write_bytes(CURRENT)
    (v / "04-synthesis" / "out.md").symlink_to(outside)
    _refuses(lambda: _plan(v, book, path="04-synthesis/out.md"), containing="is a symlink")

    real = _note(v, "02-areas/real.md")
    (v / "04-synthesis" / "in.md").symlink_to(real)
    _refuses(lambda: _plan(v, book, path="04-synthesis/in.md"), containing="is a symlink")

    assert outside.read_bytes() == CURRENT and real.read_bytes() == CURRENT


def test_a_symlinked_folder_is_refused() -> None:
    v, book = _vault(), notes.PlanBook()
    elsewhere = Path(tempfile.mkdtemp())
    (elsewhere / "decision.md").write_bytes(CURRENT)
    (v / "02-areas" / "linked").symlink_to(elsewhere, target_is_directory=True)
    _refuses(lambda: _plan(v, book, path="02-areas/linked/decision.md"), containing="is a symlink")
    assert (elsewhere / "decision.md").read_bytes() == CURRENT


def test_a_symlink_planted_between_plan_and_commit_is_refused() -> None:
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    plan = _plan(v, book)
    outside = Path(tempfile.mkdtemp()) / "outside.md"
    outside.write_bytes(CURRENT)
    p.unlink()
    p.symlink_to(outside)
    _refuses(lambda: _commit(v, book, plan.confirm_token), containing="is a symlink")
    assert outside.read_bytes() == CURRENT, "nothing outside the vault was written"
    assert p.is_symlink()
    assert not book._issued, "a refused commit burns the token, whatever refused it"


def test_core_vault_is_never_amended() -> None:
    """Doc 2 §2: nothing auto-writes into the tier every scope inherits. Reached by `..`, by an
    absolute path into the core vault, and by naming a core folder."""
    v, book = _vault(), notes.PlanBook()
    core_note = v.parent / "demo-core-vault" / "00-operator" / "operator.md"
    _refuses(lambda: _plan(v, book, path="../demo-core-vault/00-operator/operator.md"))
    _refuses(lambda: _plan(v, book, path="04-synthesis/../../demo-core-vault/00-operator/operator.md"))
    _refuses(lambda: _plan(v, book, path=str(core_note)), containing="outside the project vault")
    _note(v, "00-operator/operator.md")
    _refuses(lambda: _plan(v, book, path="00-operator/operator.md"),
             containing="not in a writable project folder")
    assert core_note.read_bytes() == CURRENT
    assert not book._issued, "no refused plan may mint a token"


# ---------------------------------------------------------------- what may not be amended

def test_a_missing_note_points_at_ingest() -> None:
    _refuses(lambda: _plan(_vault(), notes.PlanBook(), path="04-synthesis/nope.md"),
             containing="use `ingest`")


def test_an_identical_note_is_refused() -> None:
    v = _vault()
    declared = CURRENT.replace(b"---\n", b"---\ndoc_id: decision\n", 1)
    _note(v, data=declared)
    _refuses(lambda: _plan(v, notes.PlanBook(), content=declared), containing="nothing to amend")


def test_an_unchanged_undeclared_note_can_be_amended_to_pin_its_id() -> None:
    """Sending the note back unchanged is a pin and nothing else: one added line."""
    v = _vault()
    _note(v)
    plan = _plan(v, notes.PlanBook(), content=CURRENT)
    changed = [line for line in plan.diff.split("\n")
               if line.startswith(("+", "-")) and not line.startswith(("+++", "---"))]
    assert changed == [f"+doc_id: {plan.pinned_doc_id}"], changed


def test_frozen_classes_are_never_edited() -> None:
    """A transcript is the record of what someone SAID; a frozen edition does not change by
    definition. Refused on the note as it is AND on the note as it would become."""
    v, book = _vault(), notes.PlanBook()
    convo = (b"---\ntitle: Call\nclass: conversation\nstatus: active\ndoc_type: reference\n"
             b"confidence: unstated\n---\n" + BODY)
    _note(v, "03-references/call.md", convo)
    _refuses(lambda: _plan(v, book, path="03-references/call.md", content=convo + b"\nedited\n"),
             containing="frozen class")

    frozen = (b"---\ntitle: Book\nclass: reference-frozen\nsource_sha256: " + b"a" * 64
              + b"\nstatus: active\ndoc_type: reference\nconfidence: stated\n---\n" + BODY)
    _note(v, "03-references/book.md", frozen)
    _refuses(lambda: _plan(v, book, path="03-references/book.md", content=frozen + b"\nedited\n"),
             containing="frozen class")

    # Declassifying is the edit the before-check exists for: dropping `class: conversation` would
    # otherwise pass every gate on the new side and turn a transcript into an ordinary note.
    declassified = convo.replace(b"class: conversation\n", b"")
    _refuses(lambda: _plan(v, book, path="03-references/call.md", content=declassified),
             containing="frozen class")
    assert (v / "03-references" / "call.md").read_bytes() == convo

    _note(v)
    into_convo = AMENDED.replace(b"---\nstatus", b"---\ntitle: T\nclass: conversation\nstatus", 1)
    _refuses(lambda: _plan(v, book, content=into_convo), containing="frozen class")
    assert not book._issued


def test_a_superseded_note_is_history_and_is_not_edited() -> None:
    v = _vault()
    dead = CURRENT.replace(b"status: active", b"status: superseded\nsuperseded_by: decision-v2")
    _note(v, data=dead)
    _refuses(lambda: _plan(v, notes.PlanBook(), content=dead + b"\nedited\n"),
             containing="is superseded")


def test_superseding_a_note_goes_through_amend() -> None:
    """The dead note itself declares `superseded_by` (spine.py), so superseding is an edit. The
    spine gate still refuses one without the link, and the plan flags the status change."""
    v, book = _vault(), notes.PlanBook()
    _note(v)
    no_link = CURRENT.replace(b"status: active", b"status: superseded")
    _refuses(lambda: _plan(v, book, content=no_link), containing="superseded_by")

    linked = CURRENT.replace(b"status: active", b"status: superseded\nsuperseded_by: decision-v2")
    plan = _plan(v, book, content=linked)
    assert {"status", "superseded_by"} <= set(plan.spine_changed)
    assert any("leaves default retrieval" in w for w in plan.warnings)
    assert any("not checked to exist" in w for w in plan.warnings)


def test_a_declared_doc_id_is_identity() -> None:
    v, book = _vault(), notes.PlanBook()
    declared = CURRENT.replace(b"---\nstatus", b"---\ndoc_id: retrieval-decision\nstatus", 1)
    _note(v, data=declared)
    changed = declared.replace(b"doc_id: retrieval-decision", b"doc_id: something-else")
    removed = declared.replace(b"doc_id: retrieval-decision\n", b"")
    for bad in (changed, removed):
        _refuses(lambda bad=bad: _plan(v, book, content=bad + b"\nedited\n"),
                 containing="declared doc_id changes")

    # Kept: the id does not change, so it is not reported as changing.
    plan = _plan(v, book, content=declared + b"\nedited\n")
    assert "doc_id" not in plan.spine_changed
    assert plan.pinned_doc_id is None


def test_the_write_gate_requires_a_confidence_to_amend_an_unjudged_note() -> None:
    """Most migrated notes declare no confidence. Amending one requires judging it — the same
    asymmetry the add path holds, which is what stops the unjudged count growing."""
    v, book = _vault(), notes.PlanBook()
    unjudged = CURRENT.replace(b"confidence: proposed\n", b"")
    _note(v, data=unjudged)
    _refuses(lambda: _plan(v, book, content=unjudged + b"\nedited\n"), containing="confidence")
    plan = _plan(v, book, content=CURRENT + b"\nedited\n")
    assert plan.spine_before["confidence"] is None
    assert plan.spine_after["confidence"] == "proposed"


def test_paths_outside_the_note_skeleton_are_refused() -> None:
    v, book = _vault(), notes.PlanBook()
    for rel, why in (("_sources/call.md", "writable project folder"),
                     ("_archive/old.md", "writable project folder"),
                     ("02-areas/.hidden/n.md", "hidden"),
                     ("02-areas/99-templates/t.md", "skip list"),
                     ("02-areas/log.md", "skip list"),
                     ("03-references/book/passages/p1.md", "reference passage"),
                     ("02-areas/paper.pdf", "not markdown")):
        _note(v, rel)
        _refuses(lambda rel=rel: _plan(v, book, path=rel), containing=why)


def test_a_path_spelled_in_another_case_cannot_walk_around_the_refusals() -> None:
    """APFS is case-insensitive, so `PASSAGES/` reached the real `passages/` while the lexical
    refusal compared only the caller's string. A frozen source's passage was rewritten that way
    (crosscheck, 2026-11-04): staged validation never sees the inherited `_meta.md` class, which is
    why passages are refused at all."""
    v, book = _vault(), notes.PlanBook()
    passage = _note(v, "03-references/book/passages/p1.md")
    meta = _note(v, "03-references/book/_meta.md",
                 b"---\nclass: reference-frozen\nstatus: active\n---\n")
    _note(v, "02-areas/x/99-templates/t.md")
    structure = _note(v, "02-areas/x/structure.md")
    _note(v)
    for rel in ("03-references/book/PASSAGES/p1.md", "03-references/book/_META.md",
                "02-areas/x/99-Templates/t.md", "02-areas/x/Structure.md",
                "04-synthesis/DECISION.md"):
        _refuses(lambda rel=rel: _plan(v, book, path=rel))
    assert passage.read_bytes() == CURRENT and meta.read_bytes().startswith(b"---\nclass")
    assert structure.read_bytes() == CURRENT
    assert not book._issued


def test_a_last_line_without_a_newline_cannot_hide_an_added_line() -> None:
    """Unmarked, the removed final line ran into the first added one, and the reviewer saw
    `-old last line+new last line` as a single removal (crosscheck, 2026-11-04)."""
    v = _vault()
    _note(v, data=CURRENT + b"old last line")
    plan = _plan(v, notes.PlanBook(), content=CURRENT + b"new last line\nsecret extra line")
    lines = plan.diff.splitlines()
    assert "-old last line" in lines and "+new last line" in lines and "+secret extra line" in lines
    assert lines.count("\\ No newline at end of file") == 2


def test_a_folder_swapped_for_a_symlink_after_the_walk_cannot_redirect_the_write() -> None:
    """Every syscall after the walk is relative to the folder descriptor it ended on. The earlier
    version re-resolved the path string for the read, the staging open and the rename, so swapping
    `02-areas/backend` for a link (into core-vault, say) mid-commit steered the write there."""
    v, book = _vault(), notes.PlanBook()
    _note(v, "02-areas/backend/decision.md")
    plan = _plan(v, book, path="02-areas/backend/decision.md")
    outside = Path(tempfile.mkdtemp())
    (outside / "decision.md").write_bytes(CURRENT)
    real = notes._check_amend

    def swap_after_gates(**kw):
        out = real(**kw)
        (v / "02-areas" / "backend").rename(v / "02-areas" / "backend-moved")
        (v / "02-areas" / "backend").symlink_to(outside, target_is_directory=True)
        return out

    notes._check_amend = swap_after_gates
    try:
        _commit(v, book, plan.confirm_token, path="02-areas/backend/decision.md")
    finally:
        notes._check_amend = real
    assert (outside / "decision.md").read_bytes() == CURRENT, "the write followed the swapped link"
    assert not [p.name for p in outside.iterdir() if p.name.endswith(".tmp")]
    # It landed in the folder that was checked, wherever that folder now sits.
    assert (v / "02-areas" / "backend-moved" / "decision.md").read_bytes() == _pinned(AMENDED)


def test_a_tilde_path_is_expanded() -> None:
    """A person types `~/OneDrive/...`. It was checked unexpanded, so `~` became a folder name and
    the path was refused as not being in a writable folder."""
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    old = os.environ.get("HOME")
    os.environ["HOME"] = str(v.parent)
    try:
        plan = _plan(v, book, path="~/demo-vault/04-synthesis/decision.md")
    finally:
        if old is None:
            del os.environ["HOME"]
        else:
            os.environ["HOME"] = old
    assert plan.target == p.resolve()


def test_a_tilde_path_outside_the_vault_is_refused() -> None:
    _refuses(lambda: _plan(_vault(), notes.PlanBook(), path="~/Documents/x.md"),
             containing="outside the project vault")


def test_a_nul_in_the_path_is_a_refusal_not_a_crash() -> None:
    _refuses(lambda: _plan(_vault(), notes.PlanBook(), path="04-synthesis/d\x00.md"),
             containing="NUL")


def test_the_diff_splits_on_newlines_only() -> None:
    """`str.splitlines` also breaks on a form feed or U+2028, so the reviewer was shown lines the
    file does not have, and a false "No newline at end of file" marker in the middle."""
    v = _vault()
    _note(v, data=CURRENT + "page\fbreak and a\u2028separator\n".encode())
    plan = _plan(v, notes.PlanBook(),
                 content=CURRENT + "page\fbreak and a\u2028separator\nadded line\n".encode())
    assert "No newline at end of file" not in plan.diff
    assert "+added line" in plan.diff.splitlines()
    assert sum(1 for line in plan.diff.split("\n") if line.startswith("+")
               and not line.startswith(("+++", "+doc_id:"))) == 1


def test_characters_a_viewer_would_hide_are_shown_in_the_diff() -> None:
    """A lone `\r` returns the cursor and overwrites the `+`, U+2028 breaks the line in a viewer
    with no `+` on its second half, a bidi override reorders the text, and CRLF -> LF is invisible.
    Each made the approved diff differ from the approved bytes (adversary, 2026-11-04)."""
    v = _vault()
    _note(v, data=CURRENT + b"line one\r\n")
    plan = _plan(v, notes.PlanBook(), content=CURRENT + (
        "line one\n+ fake context\rhidden\nsplit\u2028here\nR\u202eLO\n").encode())
    lines = plan.diff.split("\n")
    assert "-line one⟨U+000D⟩" in lines, "the CRLF -> LF change must be visible"
    assert "++ fake context⟨U+000D⟩hidden" in lines
    assert "+split⟨U+2028⟩here" in lines
    assert "+R⟨U+202E⟩LO" in lines
    assert not any(ch in plan.diff for ch in "\r\u2028\u202e")
    warning = next(w for w in plan.warnings if "a viewer would hide" in w)
    assert "3 in added lines" in warning and "1 in removed lines" in warning, warning


def test_invisible_text_cannot_ride_into_a_note_unseen() -> None:
    """Unicode tag characters (U+E0000-E007F) spell ASCII that no viewer draws, a known way to
    smuggle an instruction to the next model that reads the note; a zero-width space silently
    breaks a `[[link]]`. A hand-picked list of hidden characters missed both (crosscheck,
    2026-11-04), so the approved diff showed only the visible half of the line."""
    v = _vault()
    _note(v)
    smuggled = "".join(chr(0xE0000 + ord(c)) for c in "ignore prior instructions")
    plan = _plan(v, notes.PlanBook(), content=CURRENT + (
        "Visible sentence." + smuggled + "\nsee [[deci\u200bsion]] and \u2060\u00ad\u061c\n").encode())
    added = [line for line in plan.diff.split("\n") if line.startswith("+") and "Visible" in line]
    assert added and added[0].count("⟨U+E00") == len(smuggled), added
    assert "+see [[deci⟨U+200B⟩sion]] and ⟨U+2060⟩⟨U+00AD⟩⟨U+061C⟩" \
        in plan.diff.split("\n")
    assert not any(0xE0000 <= ord(c) <= 0xE007F or c in "\u200b\u2060\u00ad\u061c" for c in plan.diff)
    assert any(f"{len(smuggled) + 4} in added lines" in w for w in plan.warnings), plan.warnings


def test_the_marks_cannot_be_forged_by_the_note() -> None:
    """A literal `⟨` is escaped too, so every `⟨` in the diff opens a mark. Escaping it hides
    nothing, so it is not counted as hidden: `⟨x, y⟩` is ordinary notation in a maths note."""
    v = _vault()
    _note(v)
    plan = _plan(v, notes.PlanBook(), content=CURRENT + "fake ⟨U+2028⟩ mark\n".encode())
    assert "+fake ⟨U+27E8⟩U+2028⟩ mark" in plan.diff.split("\n")
    assert not any("a viewer would hide" in w for w in plan.warnings), plan.warnings
    assert any("literal `⟨`" in w for w in plan.warnings)


def test_an_ordinary_diff_carries_no_visibility_warning() -> None:
    """Tabs and emoji (a joiner and a presentation selector between pictographs) stay as they are:
    marking every emoji would teach a reviewer to ignore marks."""
    v = _vault()
    _note(v)
    text = "tab\there, \U0001F469\u200d\U0001F4BB, ❤\ufe0f, \U0001F3F3\ufe0f\u200d\U0001F308\n"
    plan = _plan(v, notes.PlanBook(), content=CURRENT + text.encode())
    assert not any("a viewer would hide" in w or "literal" in w for w in plan.warnings), plan.warnings
    assert "+" + text[:-1] in plan.diff.split("\n")


def test_marks_are_counted_on_the_side_of_the_diff_they_are_on() -> None:
    """The file headers were recognised by their `---`/`+++` prefix, so a removed YAML fence
    (`----`) or an added `++` line was counted as unchanged (adversary, 2026-11-04)."""
    v = _vault()
    _note(v, data=CURRENT.replace(b"---\n", b"---\r\n", 1))
    plan = _plan(v, notes.PlanBook(), content=CURRENT + "++ tagged\u200b\n".encode())
    warning = next(w for w in plan.warnings if "a viewer would hide" in w)
    assert "1 in added lines" in warning and "1 in removed lines" in warning, warning
    assert "unchanged" not in warning, warning


def test_skin_tone_and_keycap_emoji_carry_no_mark() -> None:
    v = _vault()
    _note(v)
    text = "\U0001F469\U0001F3FD\u200d\U0001F4BB, \U0001F44D\U0001F3FB, 1\ufe0f⃣, #\ufe0f⃣\n"
    plan = _plan(v, notes.PlanBook(), content=CURRENT + text.encode())
    assert not any("a viewer would hide" in w for w in plan.warnings), plan.warnings
    assert "+" + text[:-1] in plan.diff.split("\n")


def test_the_emoji_exemption_does_not_cover_ascii_modifier_letters() -> None:
    """Category Sk holds ASCII `` ` `` and `^` as well as the skin tones. Exempting the category let
    a VS16 after a backtick pass unmarked, so `` `\ufe0f`` `` read as a code fence in the approved
    diff while the reader parsed text; `[^1]` footnotes and `^block` ids broke the same way."""
    v = _vault()
    _note(v)
    text = "`\ufe0f``python\n[^\ufe0f1] and ^\u200d© and ˂\ufe0f\n"
    plan = _plan(v, notes.PlanBook(), content=CURRENT + text.encode())
    added = [line for line in plan.diff.split("\n") if line.startswith("+") and not line.startswith("+++")]
    assert added[-2] == "+`⟨U+FE0F⟩``python", added
    assert added[-1] == ("+[^⟨U+FE0F⟩1] and ^⟨U+200D⟩© and "
                         "˂⟨U+FE0F⟩"), added
    assert any("4 in added lines" in w for w in plan.warnings), plan.warnings


def test_an_oversized_note_is_refused_before_any_work() -> None:
    v = _vault()
    _note(v)
    assert not _reaches_the_diff(lambda: _refuses(
        lambda: _plan(v, notes.PlanBook(), content=CURRENT + b"x" * (notes.MAX_NOTE_BYTES + 1)),
        containing="bytes, over the"))


def test_a_token_for_another_note_is_not_reported_as_this_note_moving() -> None:
    v, book = _vault(), notes.PlanBook()
    _note(v)
    other = _note(v, "02-areas/other.md", CURRENT + b"\nA different note.\n")
    plan = _plan(v, book)
    msg = _refuses(lambda: _commit(v, book, plan.confirm_token, path="02-areas/other.md"),
                   containing="not issued")
    assert "changed after the plan" not in msg
    assert other.read_bytes() == CURRENT + b"\nA different note.\n"


def test_a_failed_chmod_closes_the_staging_descriptor() -> None:
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    plan = _plan(v, book)
    real = os.fchmod

    def refuse(*a, **k):
        raise OSError(1, "Operation not permitted")

    before = len(os.listdir("/dev/fd"))
    os.fchmod = refuse
    try:
        _refuses(lambda: _commit(v, book, plan.confirm_token), containing="failed staging")
    finally:
        os.fchmod = real
    assert len(os.listdir("/dev/fd")) == before, "a descriptor leaked on the error path"
    assert p.read_bytes() == CURRENT
    _no_staging_left(p.parent)


def _reaches(owner, name: str, fn) -> bool:
    """Whether `fn` got as far as `owner.name`, stubbed to a sentinel while it runs. What these
    tests prove is how far a plan got, not what the stubbed step would have said."""

    class Reached(Exception):
        pass

    def sentinel(*a, **k):
        raise Reached

    real = getattr(owner, name)
    setattr(owner, name, sentinel)
    try:
        fn()
    except Reached:
        return True
    finally:
        setattr(owner, name, real)
    return False


def _reaches_the_diff(fn) -> bool:
    return _reaches(notes, "_render_diff", fn)


def _reaches_the_gates(fn) -> bool:
    import substrate.markdown.ingest as ingest

    return _reaches(ingest, "ingest_markdown", fn)


def _lines_of(n: int, head: bytes = CURRENT) -> bytes:
    """`head` padded with distinct lines to exactly `n` lines."""
    return head + b"".join(b"line %d\n" % i for i in range(n - head.count(b"\n")))


def test_the_line_count_is_the_diffs_line_count() -> None:
    for data in (b"", b"a", b"a\n", b"a\nb", b"a\n\n", b"\n", b"a\rb\n", "a b\n".encode(),
                 b"\xff\n\xfe"):
        assert notes._line_count(data) == len(notes._lines(data)), data


def test_an_amended_note_over_the_line_cap_is_refused_before_the_diff() -> None:
    """Exact: a note at the cap reaches the diff, one line more does not."""
    cap = notes.AMEND_LINE_CAP
    v = _vault()
    near = _lines_of(cap - 1, _pinned(CURRENT))
    _note(v, data=near)
    assert _reaches_the_diff(lambda: _plan(v, notes.PlanBook(), content=near + b"at the cap\n"))
    assert not _reaches_the_diff(lambda: _refuses(
        lambda: _plan(v, notes.PlanBook(), content=near + b"at the cap\none over\n"),
        containing=f"has {cap + 1} lines, over"))


def test_the_line_cap_counts_the_pinned_doc_id_line() -> None:
    """The line amend adds is a line the diff compares: a caller's note at the cap is one over it
    once pinned, and one line under the cap lands on it exactly."""
    cap = notes.AMEND_LINE_CAP
    v = _vault()
    _note(v, data=_lines_of(cap - 1))
    assert not _reaches_the_diff(lambda: _refuses(
        lambda: _plan(v, notes.PlanBook(), content=_lines_of(cap)),
        containing=f"with its pinned doc_id line has {cap + 1} lines"))
    assert _reaches_the_diff(lambda: _plan(v, notes.PlanBook(), content=_lines_of(cap - 1)))


def test_a_current_note_over_the_line_cap_is_refused_before_it_is_parsed() -> None:
    """Reading a long note as markdown is the costly part — 4 s for an 8 MiB list — so the cap is
    checked on the raw bytes, before it."""
    v = _vault()
    _note(v, data=_lines_of(notes.AMEND_LINE_CAP + 1))
    assert not _reaches(notes, "_spine_of", lambda: _refuses(
        lambda: _plan(v, notes.PlanBook()), containing="that one plan can diff"))


def test_the_bounded_diff_is_difflibs_diff() -> None:
    """`_unified` copies `unified_diff`'s formatting to put a clock on its matcher; this holds the
    copy to the original, empty sides and unterminated last lines included."""
    import difflib
    import random

    rng = random.Random(7)
    for _ in range(400):
        a = [rng.choice("abcdefg") + "\n" for _ in range(rng.randrange(0, 40))]
        b = [x for x in a if rng.random() > 0.2] + [rng.choice("abxyz") + "\n"
                                                   for _ in range(rng.randrange(0, 6))]
        if rng.random() < 0.3:
            rng.shuffle(b)
        for side in (a, b):
            if side and rng.random() < 0.3:
                side[-1] = side[-1].rstrip("\n")
        assert list(notes._unified(a, b, "a/x.md", "b/x.md")) == \
            list(difflib.unified_diff(a, b, fromfile="a/x.md", tofile="b/x.md")), (a, b)


def test_a_costly_reordering_is_refused_within_the_diff_budget() -> None:
    """Values each repeated just under `difflib`'s 1% junk cut-off, permuted: 10,000 lines of this
    held one plan for 32.6 s. Under the line cap, so only the clock stops it."""
    import time

    v = _vault()
    head = _pinned(CURRENT)
    n = 9_000 - head.count(b"\n")
    _note(v, data=head + b"".join(b"v%d\n" % (i % 300) for i in range(n)))
    content = head + b"".join(b"v%d\n" % ((i * 3) % 300) for i in range(n))
    t = time.perf_counter()
    _refuses(lambda: _plan(v, notes.PlanBook(), content=content), containing="to work out")
    # Unbounded, this input runs for 25 s here; the margin is for a slower CI runner.
    assert time.perf_counter() - t < notes.AMEND_DIFF_SECONDS + 5


def test_the_clock_is_what_refuses_a_costly_diff() -> None:
    v = _vault()
    _note(v)
    real = notes.AMEND_DIFF_SECONDS
    notes.AMEND_DIFF_SECONDS = -1.0
    try:
        assert not _reaches_the_gates(lambda: _refuses(lambda: _plan(v, notes.PlanBook()),
                                                       containing="to work out"))
    finally:
        notes.AMEND_DIFF_SECONDS = real


def test_a_few_huge_lines_are_refused_before_any_is_rendered_or_gated() -> None:
    """The line cap says nothing about long lines: one 2 MB line spent seconds being marked for
    hidden characters, after the gates had run over it, and was then refused for its length."""
    v = _vault()
    _note(v)
    seen = []
    real = notes._visible

    def recording(text):
        seen.append(len(text))
        return real(text)

    notes._visible = recording
    try:
        assert not _reaches_the_gates(lambda: _refuses(
            lambda: _plan(v, notes.PlanBook(), content=CURRENT + b"y" * 2_000_000 + b"\n"),
            containing=f"over the {notes.AMEND_DIFF_CHAR_CAP} characters"))
    finally:
        notes._visible = real
    assert max(seen, default=0) <= notes.AMEND_DIFF_CHAR_CAP, max(seen)


def test_a_diff_that_grows_past_the_cap_when_marked_is_refused() -> None:
    """Under the cap as raw text, over it once each zero-width space shows as `⟨U+200B⟩`."""
    v = _vault()
    _note(v)
    marks = AMENDED + "\u200b".encode() * 8_000 + b"\n"
    _refuses(lambda: _plan(v, notes.PlanBook(), content=marks), containing="show whole")


def test_a_commit_does_not_diff() -> None:
    """The plan showed the diff and the binding holds the bytes to it. Diffing again, against the
    clock, could refuse the approved edit because the second run was slower."""
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    plan = _plan(v, book)
    assert not _reaches_the_diff(lambda: _commit(v, book, plan.confirm_token))
    assert p.read_bytes() == _pinned(AMENDED)


def test_a_real_token_sent_with_other_content_buys_no_gates() -> None:
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    plan = _plan(v, book)
    assert not _reaches_the_gates(lambda: _refuses(
        lambda: _commit(v, book, plan.confirm_token, content=AMENDED + b"\nUnapproved.\n"),
        containing="not issued"))
    assert p.read_bytes() == CURRENT
    _refuses(lambda: _commit(v, book, plan.confirm_token), containing="not issued")


def test_a_diff_too_large_to_show_is_refused_before_the_gates() -> None:
    v = _vault()
    _note(v)
    huge = CURRENT + b"\n" + b"".join(b"Line %d of a rewrite.\n\n" % i for i in range(3000))
    assert not _reaches_the_gates(lambda: _refuses(
        lambda: _plan(v, notes.PlanBook(), content=huge), containing="split the change"))


def test_an_invented_token_buys_no_work() -> None:
    """Commit ran every gate and the whole diff before looking the token up, so a token nobody
    issued cost as much as a plan — 32.8 s on the costliest note — with no human anywhere."""
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    add_token = book.issue("an add plan's binding")
    _note(v, "02-areas/other.md", CURRENT + b"\nA different note.\n")
    other = _plan(v, book, path="02-areas/other.md", content=AMENDED).confirm_token
    for token in ("made-up", add_token, other):
        assert not _reaches(notes, "_read_at", lambda t=token: _refuses(
            lambda: _commit(v, book, t), containing="not issued"))
    assert p.read_bytes() == CURRENT


def test_a_read_only_note_is_refused_at_plan() -> None:
    """`rename` replaces the folder entry and never asks the note's own permissions, so a note made
    read-only was replaced as if it were writable."""
    _needs_non_root()
    v = _vault()
    p = _note(v)
    p.chmod(0o444)
    try:
        _refuses(lambda: _plan(v, notes.PlanBook()), containing="read-only")
    finally:
        p.chmod(0o644)
    assert p.read_bytes() == CURRENT


def test_a_read_only_note_amend_would_refuse_anyway_is_told_the_real_reason() -> None:
    _needs_non_root()
    v = _vault()
    p = _note(v, data=CURRENT.replace(b"status: active",
                                      b"status: superseded\nsuperseded_by: decision-v2"))
    p.chmod(0o444)
    try:
        msg = _refuses(lambda: _plan(v, notes.PlanBook()), containing="is superseded")
    finally:
        p.chmod(0o644)
    assert "read-only" not in msg


def test_a_note_made_read_only_after_the_plan_is_not_replaced() -> None:
    _needs_non_root()
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    plan = _plan(v, book)
    p.chmod(0o444)
    try:
        _refuses(lambda: _commit(v, book, plan.confirm_token), containing="read-only")
        assert p.read_bytes() == CURRENT
        assert stat.S_IMODE(p.stat().st_mode) == 0o444
    finally:
        p.chmod(0o644)
    _refuses(lambda: _commit(v, book, plan.confirm_token), containing="not issued")
    assert p.read_bytes() == CURRENT
    _no_staging_left(p.parent)


def test_a_note_made_read_only_while_the_commit_runs_its_gates_is_not_replaced() -> None:
    """A `chmod` changes no byte, so the last checksum before the rename cannot see it, and the
    gates and the diff before it are seconds long. The check sits beside the rename."""
    _needs_non_root()
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    plan = _plan(v, book)
    real = notes._check_amend

    def then_chmod(**kw):
        out = real(**kw)
        p.chmod(0o444)
        return out

    notes._check_amend = then_chmod
    try:
        _refuses(lambda: _commit(v, book, plan.confirm_token), containing="read-only")
    finally:
        notes._check_amend = real
        p.chmod(0o644)
    assert p.read_bytes() == CURRENT
    _no_staging_left(p.parent)


def test_a_folder_made_read_only_during_the_commit_is_refused_not_raised() -> None:
    """The staging file cannot be removed from a folder that turned read-only under it. The
    cleanup's own error replaced the refusal, so the caller got a bare PermissionError and the
    token survived it."""
    _needs_non_root()
    v, book = _vault(), notes.PlanBook()
    p = _note(v)
    plan = _plan(v, book)
    real = notes._require_writable_note

    def then_lock_the_folder(*a):
        real(*a)
        p.parent.chmod(0o555)

    notes._require_writable_note = then_lock_the_folder
    try:
        _refuses(lambda: _commit(v, book, plan.confirm_token), containing="failed replacing")
    finally:
        notes._require_writable_note = real
        p.parent.chmod(0o755)
    assert p.read_bytes() == CURRENT
    _refuses(lambda: _commit(v, book, plan.confirm_token), containing="not issued")


def _needs_non_root() -> None:
    """Root is granted write access whatever a file's mode says, so a read-only note cannot be made
    for it. The CI runner is not root; a container might be."""
    if os.geteuid() == 0:
        import pytest

        pytest.skip("root can write a read-only file")


def _needs_chflags() -> None:
    """Finder's Locked is a BSD file flag; the engine CI job runs on Linux, which has none."""
    if not hasattr(os, "chflags"):
        import pytest

        pytest.skip("no file flags (Finder's Locked) on this platform")


def test_a_finder_locked_note_is_refused_at_plan_not_at_the_rename() -> None:
    """Finder's Locked is the user-immutable flag. The rename onto it fails, so the note planned
    fine and every commit of that plan failed."""
    _needs_chflags()
    v = _vault()
    p = _note(v)
    os.chflags(p, stat.UF_IMMUTABLE)
    try:
        _refuses(lambda: _plan(v, notes.PlanBook()), containing="read-only")
    finally:
        os.chflags(p, 0)
    assert p.read_bytes() == CURRENT


def test_a_note_in_a_folder_that_cannot_take_the_staging_file_is_refused_at_plan() -> None:
    """The commit writes a staging file beside the note. A read-only or Locked folder planned fine
    and then refused every commit with "cannot stage"."""
    _needs_non_root()
    locks = [(lambda d: d.chmod(0o555), lambda d: d.chmod(0o755))]
    if hasattr(os, "chflags"):
        locks.append((lambda d: os.chflags(d, stat.UF_IMMUTABLE), lambda d: os.chflags(d, 0)))
    for lock, unlock in locks:
        v = _vault()
        p = _note(v)
        lock(p.parent)
        try:
            msg = _refuses(lambda v=v: _plan(v, notes.PlanBook()), containing="read-only")
        finally:
            unlock(p.parent)
        assert str(p.parent) in msg


def test_a_note_name_at_the_length_limit_commits() -> None:
    """The staging file was the note's name plus 22 characters, so any name over 233 characters
    planned and then failed every commit. 255 is the filesystem's limit: in characters on APFS, in
    bytes on Linux, where 252 `é` do not fit and that name is not tried."""
    import errno
    import hashlib

    for stem in ("a" * 252, "é" * 252):
        v, book = _vault(), notes.PlanBook()
        rel = f"04-synthesis/{stem}.md"
        try:
            p = _note(v, rel)
        except OSError as e:
            if e.errno != errno.ENAMETOOLONG or stem.isascii():
                raise
            continue
        plan = _plan(v, book, path=rel)
        _commit(v, book, plan.confirm_token, path=rel)
        assert hashlib.sha256(p.read_bytes()).hexdigest() == plan.new_sha256
        assert b"Amended 2026-11-04" in p.read_bytes()
        _no_staging_left(p.parent)


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print(f"ok  {name}")
