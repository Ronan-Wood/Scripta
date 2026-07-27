"""The write gate has no path that writes without a plan.

Doc 3a §2 requires human confirmation for ingest, and the server cannot enforce that socially — a
client may auto-approve every tool call. So the gate is structural: a token exists only after a
plan was returned for someone to read, and it is bound to BOTH the content and the destination.
`test_commit_without_a_token_is_impossible` and the token-mismatch tests are that argument.

The refusals matter as much as the writes. Every one of them protects an invariant the vault
model depends on — additive-only, never into core, never outside the project vault — and a write
that violated one would look, on disk, exactly like a legitimate note.

Runnable with plain `python tests/test_notes.py`; discovered by pytest if added.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import notes  # noqa: E402

GOOD = b"""---
status: active
doc_type: decision
confidence: proposed
domains: [retrieval]
---

# Retrieval stack decision

The MCP surface runs the measured stack, so a caller can tell a 0.698 answer from a lexical one.
"""

NO_SPINE = b"# Just a heading\n\nNo frontmatter at all, so the vault path must refuse it.\n"


def _vault() -> Path:
    root = Path(tempfile.mkdtemp()) / "demo-vault"
    for folder in notes.WRITABLE_FOLDERS:
        (root / folder).mkdir(parents=True)
    return root


def _book() -> notes.PlanBook:
    return notes.PlanBook()


def _plan(vault: Path, book: notes.PlanBook | None = None, **over):
    kw = dict(project_vault=vault, content=GOOD, filename="decision.md", book=book or _book())
    kw.update(over)
    return notes.plan(**kw)


def _refuses(fn, *, containing: str = "") -> str:
    try:
        fn()
    except notes.NoteError as e:
        assert containing in str(e), f"expected {containing!r} in: {e}"
        return str(e)
    raise AssertionError("expected a NoteError")


# ---------------------------------------------------------------- plan writes nothing

def test_plan_writes_nothing() -> None:
    v = _vault()
    p = _plan(v)
    assert not p.target.exists(), "planning must not touch the vault"
    assert list((v / "04-synthesis").iterdir()) == []


def test_plan_reports_the_spine_it_would_get() -> None:
    """The human confirming the write is confirming THESE values, so they must be the real ones
    the ingestion produced, not a guess parsed separately."""
    p = _plan(_vault())
    assert (p.status, p.doc_type, p.confidence) == ("active", "decision", "proposed")
    assert p.domains == ["retrieval"]
    assert p.doc_id and p.passages >= 1


def test_plan_names_what_it_did_not_check() -> None:
    """A22 runs at compose. A plan that implied it had run would overstate its own coverage."""
    assert any("A22" in w for w in _plan(_vault()).warnings)


def test_plan_refuses_a_note_compose_would_refuse() -> None:
    """The vault path requires a declared status and doc_type. Catching it here means the note
    never lands in the vault to refuse the whole scope's next compose."""
    v = _vault()
    _refuses(lambda: _plan(v, content=NO_SPINE))
    assert list((v / "04-synthesis").iterdir()) == [], "a refused plan leaves nothing behind"


# ---------------------------------------------------------------- the token gate

def test_commit_without_a_token_is_impossible() -> None:
    v = _vault()
    _refuses(lambda: notes.commit(project_vault=v, content=GOOD, filename="decision.md",
                                  confirm_token="", book=_book()), containing="confirm_token")
    assert not (v / "04-synthesis" / "decision.md").exists()


def test_a_derived_token_is_worthless() -> None:
    """THE regression. The token used to be sha256(target + content) — both caller-supplied — so a
    first call carrying a self-computed digest wrote a note with no plan ever issued. Anything
    derivable from what the caller already knows is not a gate."""
    import hashlib

    v = _vault()
    target = (v / "04-synthesis" / "decision.md").resolve()
    forged = hashlib.sha256(str(target).encode() + b"\0" + GOOD).hexdigest()
    _refuses(lambda: notes.commit(project_vault=v, content=GOOD, filename="decision.md",
                                  confirm_token=forged, book=_book()),
             containing="not issued by this server")
    assert not target.exists(), "a forged token must never reach the vault"


def test_a_token_from_another_process_is_refused() -> None:
    """A PlanBook is per-process on purpose: a token surviving a restart would authorise a write
    against a plan nobody in this session ever saw."""
    v = _vault()
    p = _plan(v, _book())                       # issued by one book…
    _refuses(lambda: notes.commit(project_vault=v, content=GOOD, filename="decision.md",
                                  confirm_token=p.confirm_token, book=_book()),  # …redeemed by another
             containing="not issued by this server")


def test_commit_with_the_plan_token_writes() -> None:
    v, book = _vault(), _book()
    p = _plan(v, book)
    written = notes.commit(project_vault=v, content=GOOD, filename="decision.md",
                           confirm_token=p.confirm_token, book=book)
    assert written.read_bytes() == GOOD
    # Resolved on both sides: the target is stored resolved, and on macOS a temp dir alone
    # differs (`/var` vs `/private/var`) — the same normalization trap freshness.drift hit.
    assert written == (v / "04-synthesis" / "decision.md").resolve()
    assert not written.with_name(written.name + ".tmp").exists(), "no staging file left behind"


def test_a_token_is_single_use() -> None:
    """One plan authorises one write. A replayable token would let a confirmed plan be redeemed
    again after the human's attention has moved on."""
    v, book = _vault(), _book()
    p = _plan(v, book)
    notes.commit(project_vault=v, content=GOOD, filename="decision.md",
                 confirm_token=p.confirm_token, book=book)
    (v / "04-synthesis" / "decision.md").unlink()      # clear the additive-only refusal
    _refuses(lambda: notes.commit(project_vault=v, content=GOOD, filename="decision.md",
                                  confirm_token=p.confirm_token, book=book),
             containing="already been used")


def test_the_book_does_not_grow_on_commit() -> None:
    """commit() used to call plan(), minting a nonce nobody could ever redeem — one stale entry
    per call, successful or refused, in a per-process dict on a long-lived server. Measured: after
    three failed commits the book held four entries."""
    v, book = _vault(), _book()
    p = _plan(v, book)
    assert len(book._issued) == 1
    for _ in range(3):
        try:
            notes.commit(project_vault=v, content=GOOD, filename="decision.md",
                         confirm_token="bogus", book=book)
        except notes.NoteError:
            pass
    assert len(book._issued) == 1, "a failed commit must not mint a token"

    notes.commit(project_vault=v, content=GOOD, filename="decision.md",
                 confirm_token=p.confirm_token, book=book)
    assert len(book._issued) == 0, "a redeemed plan must leave the book empty"


def test_a_token_does_not_authorise_different_content() -> None:
    """The source changing between plan and commit must refuse, not write unreviewed bytes."""
    v, book = _vault(), _book()
    p = _plan(v, book)
    edited = GOOD.replace(b"proposed", b"verified")
    _refuses(lambda: notes.commit(project_vault=v, content=edited, filename="decision.md",
                                  confirm_token=p.confirm_token, book=book))
    assert not (v / "04-synthesis" / "decision.md").exists()


def test_a_token_does_not_authorise_a_different_destination() -> None:
    """A token covering only the content would authorise writing it anywhere."""
    v, book = _vault(), _book()
    p = _plan(v, book)
    _refuses(lambda: notes.commit(project_vault=v, content=GOOD, filename="decision.md",
                                  folder="02-areas", confirm_token=p.confirm_token, book=book))


def test_commit_revalidates_rather_than_trusting_the_token() -> None:
    """The token is not a capability to skip the gates — commit re-plans, so content that would be
    refused is refused before redemption is even attempted."""
    v = _vault()
    _refuses(lambda: notes.commit(project_vault=v, content=NO_SPINE, filename="bad.md",
                                  confirm_token="anything", book=_book()))
    assert not (v / "04-synthesis" / "bad.md").exists()


# ---------------------------------------------------------------- the write itself

def test_no_reachable_path_writes_through_a_symlink() -> None:
    """The escape this closes: the write used to stage through a fixed `<note>.md.tmp` and
    `replace()` it into place, so a symlink planted at either name redirected the content OUTSIDE
    the vault, past containment checks that had only ever examined the intended path.

    This asserts the OUTCOME — no reachable call writes through a symlink — and names the
    mechanism that actually fires for each case. It deliberately does NOT claim to exercise
    O_NOFOLLOW: `_resolve_target` dereferences before the open, so every symlink reachable from
    here is refused earlier, and the flag covers only the residual window between resolve and
    open, which no deterministic test can reach.
    """
    v, book = _vault(), _book()
    outside = Path(tempfile.mkdtemp()) / "outside.md"
    outside.write_bytes(b"# Untouched\n")

    # (a) symlink pointing OUT of the vault: resolves outside, containment refuses.
    (v / "04-synthesis" / "decision.md").symlink_to(outside)
    _refuses(lambda: _plan(v, book), containing="resolves outside the project vault")

    # (b) planted between plan and commit: commit re-validates, so it refuses on the same check
    # rather than writing against the plan it was holding.
    p = notes.plan(project_vault=v, content=GOOD, filename="third.md", book=book)
    (v / "04-synthesis" / "third.md").symlink_to(outside)
    _refuses(lambda: notes.commit(project_vault=v, content=GOOD, filename="third.md",
                                  confirm_token=p.confirm_token, book=book),
             containing="resolves outside the project vault")

    # (c) symlink pointing INSIDE the vault at an existing note: additive-only refuses.
    (v / "02-areas" / "real.md").write_bytes(b"# Real\n")
    (v / "04-synthesis" / "fourth.md").symlink_to(v / "02-areas" / "real.md")
    _refuses(lambda: _plan(v, book, filename="fourth.md"), containing="additive-only")

    assert outside.read_bytes() == b"# Untouched\n", "nothing outside the vault was written"
    assert (v / "02-areas" / "real.md").read_bytes() == b"# Real\n", "no in-vault note overwritten"


# ---------------------------------------------------------------- destination refusals

def test_additive_only_never_overwrites() -> None:
    v = _vault()
    existing = v / "04-synthesis" / "decision.md"
    existing.write_bytes(b"# Existing\n\nwork the human did.\n")
    _refuses(lambda: _plan(v), containing="additive-only")
    assert existing.read_bytes().startswith(b"# Existing")


def test_escaping_the_project_vault_refuses() -> None:
    v = _vault()
    for bad in ("../../etc/passwd.md", "/tmp/absolute.md", "sub/dir/note.md"):
        _refuses(lambda bad=bad: _plan(v, filename=bad))


def test_a_folder_outside_the_skeleton_refuses() -> None:
    """Including the one that matters: nothing auto-writes into the shared core tier."""
    v = _vault()
    for bad in ("00-operator", "10-reference", "_archive", ".."):
        _refuses(lambda bad=bad: _plan(v, folder=bad), containing="writable project folder")


def test_non_markdown_refuses() -> None:
    _refuses(lambda: _plan(_vault(), filename="paper.pdf"), containing="not markdown")


def test_ingest_refuses_a_skip_list_filename() -> None:
    """A skip-list name in a writable folder plans fine, writes, then refuses every later compose.

    `notes.py` is additive-only, so the MCP surface has no way to undo such a write — the refusal
    has to happen at plan time, before anything reaches disk.
    """
    import tempfile
    from substrate.notes import NoteError, _resolve_target
    from substrate.vault import SKIP_NAMES

    with tempfile.TemporaryDirectory() as td:
        v = Path(td) / "proj"
        (v / "02-areas").mkdir(parents=True)
        for name in sorted(SKIP_NAMES):
            try:
                _resolve_target(v, "02-areas", name)
            except NoteError as e:
                assert name in str(e), e
                continue
            raise AssertionError(f"{name} was accepted into a writable folder")
        # an ordinary filename is unaffected
        assert _resolve_target(v, "02-areas", "area-digest.md").name == "area-digest.md"


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
