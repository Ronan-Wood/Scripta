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


def _plan(vault: Path, **over):
    kw = dict(project_vault=vault, content=GOOD, filename="decision.md")
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
                                  confirm_token=""), containing="confirm_token")
    assert not (v / "04-synthesis" / "decision.md").exists()


def test_commit_with_the_plan_token_writes() -> None:
    v = _vault()
    p = _plan(v)
    written = notes.commit(project_vault=v, content=GOOD, filename="decision.md",
                           confirm_token=p.confirm_token)
    assert written.read_bytes() == GOOD
    # Resolved on both sides: the target is stored resolved, and on macOS a temp dir alone
    # differs (`/var` vs `/private/var`) — the same normalization trap freshness.drift hit.
    assert written == (v / "04-synthesis" / "decision.md").resolve()
    assert not written.with_name(written.name + ".tmp").exists(), "no staging file left behind"


def test_a_token_does_not_authorise_different_content() -> None:
    """The source changing between plan and commit must refuse, not write unreviewed bytes."""
    v = _vault()
    p = _plan(v)
    edited = GOOD.replace(b"proposed", b"verified")
    _refuses(lambda: notes.commit(project_vault=v, content=edited, filename="decision.md",
                                  confirm_token=p.confirm_token), containing="does not match")
    assert not (v / "04-synthesis" / "decision.md").exists()


def test_a_token_does_not_authorise_a_different_destination() -> None:
    """A token covering only the content would authorise writing it anywhere."""
    v = _vault()
    p = _plan(v)
    _refuses(lambda: notes.commit(project_vault=v, content=GOOD, filename="decision.md",
                                  folder="02-areas", confirm_token=p.confirm_token),
             containing="does not match")


def test_commit_revalidates_rather_than_trusting_the_token() -> None:
    """The token is not a capability to skip the gates — commit re-plans, so content that would
    now be refused is refused even holding a token that once matched it."""
    v = _vault()
    token = notes._digest((v / "04-synthesis" / "bad.md").resolve(), NO_SPINE)
    _refuses(lambda: notes.commit(project_vault=v, content=NO_SPINE, filename="bad.md",
                                  confirm_token=token))
    assert not (v / "04-synthesis" / "bad.md").exists()


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
