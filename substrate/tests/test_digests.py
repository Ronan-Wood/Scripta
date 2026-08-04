"""A digest is measured against its own directory, or it is not measured at all.

The two failure modes are opposite, and both are worse than saying nothing:

  * claiming a membership set the vault does not express — research's `02-areas/scoop-watch.md`
    sits beside five unrelated synthesis notes, and a check that called those five its area would
    report it stale forever. `test_flat_digest_is_unmeasurable_not_stale` and
    `test_unmeasurable_digest_withholds_the_member_count` are that one, and they are the reason
    `stale` is tri-state rather than a bool.
  * reporting `stale: false` over notes it never read, which is the overstated completeness this
    project keeps retracting — `test_unreadable_note_makes_the_sweep_incomplete`.

`test_a_bulk_write_does_not_order_a_digest_against_its_area` is the first failure mode caught for
real: a naive `member.mtime > digest.mtime` reported all five of prism's digests behind, because the
migration wrote each area inside 25ms in arbitrary order.

Runnable with plain `python tests/test_digests.py`; discovered by pytest if added.
"""

from __future__ import annotations

import os
import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import digests  # noqa: E402
from substrate import vault as V  # noqa: E402

BODY = "Composition resolves the manifest and indexes the union."

# Distinct, ordered mtimes, chosen rather than slept for: a test that waited on the wall clock to
# separate two writes would be slow AND flaky on a filesystem with coarse timestamps.
OLD = 1_750_000_000.0
NEW = 1_760_000_000.0
# Inside one write event, the way the 2026-07-28 migration wrote each of prism's areas.
BURST = OLD + 0.02


def _note(dir_: Path, name: str, doc_type: str, *, mtime: float = OLD) -> Path:
    dir_.mkdir(parents=True, exist_ok=True)
    p = dir_ / name
    p.write_text(f"---\nstatus: active\ndoc_type: {doc_type}\n---\n\n# {name}\n\n{BODY}\n",
                 encoding="utf-8")
    os.utime(p, (mtime, mtime))
    return p


def _vault(inherits: str = "[]") -> Path:
    root = Path(tempfile.mkdtemp()) / "demo-vault"
    root.mkdir(parents=True)
    (root / ".substrate.toml").write_text(f'name = "demo"\ninherits = {inherits}\n')
    return root


def _audit(v: Path) -> dict:
    return digests.audit(V.resolve_scope(v))


def _only(out: dict) -> dict:
    assert len(out["digests"]) == 1, out
    return out["digests"][0]


def test_digest_with_a_newer_member_is_behind() -> None:
    v = _vault()
    area = v / "02-areas" / "frontend"
    _note(area, "frontend-digest.md", "digest", mtime=OLD)
    newer = _note(area, "bundle-optimization.md", "explanation", mtime=NEW)
    _note(area, "map-architecture.md", "explanation", mtime=OLD)
    out = _audit(v)
    r = _only(out)
    assert r["stale"] is True and r["measurable"] is True, r
    assert r["members"] == 2 and r["newer"] == [str(newer.resolve())]
    assert out["stale"] is True and out["behind"] == 1 and out["measured"] == 1


def test_digest_newer_than_its_area_is_current() -> None:
    """The other half of `stale` meaning something: always-true is the same defect as always-false."""
    v = _vault()
    area = v / "02-areas" / "frontend"
    _note(area, "frontend-digest.md", "digest", mtime=NEW)
    _note(area, "bundle-optimization.md", "explanation", mtime=OLD)
    r = _only(_audit(v))
    assert r["stale"] is False and r["newer"] == [] and r["members"] == 1


def test_a_bulk_write_does_not_order_a_digest_against_its_area() -> None:
    """The regression, and it was live: `member.mtime > digest.mtime` reported ALL FIVE prism
    digests behind areas nobody had touched, because the 2026-07-28 migration wrote each area inside
    25ms and whether the digest landed first is directory-iteration noise."""
    v = _vault()
    area = v / "02-areas" / "infrastructure"
    _note(area, "infrastructure-digest.md", "digest", mtime=OLD)
    for i in range(5):
        _note(area, f"ci-{i}.md", "explanation", mtime=BURST)
    r = _only(_audit(v))
    assert r["stale"] is False, "a bulk write is one event; its internal order is not authorship"
    assert r["newer"] == [] and r["members"] == 5


def test_the_tolerance_is_reported_with_the_verdicts() -> None:
    """A verdict computed against an unstated tolerance is a number without its conditions."""
    v = _vault()
    _note(v / "02-areas" / "frontend", "frontend-digest.md", "digest", mtime=OLD)
    assert _audit(v)["same_write_seconds"] == digests.SAME_WRITE_SECONDS


def test_flat_digest_is_unmeasurable_not_stale() -> None:
    """Research's shape today: a digest directly in `02-areas/`, whose siblings are five unrelated
    synthesis notes. Folder position names no area here, so there is no verdict to give."""
    v = _vault()
    _note(v / "02-areas", "scoop-watch.md", "digest", mtime=OLD)
    for i in range(3):
        _note(v / "02-areas", f"research-{i}-synthesis.md", "explanation", mtime=NEW)
    out = _audit(v)
    r = _only(out)
    assert r["measurable"] is False
    assert r["stale"] is None, "a guessed membership set would report this stale forever"
    assert out["stale"] is False and out["unmeasurable"] == 1 and out["measured"] == 0
    assert "UNMEASURABLE" in r["reason"] and "02-areas" in r["reason"]


def test_unmeasurable_digest_withholds_the_member_count() -> None:
    """`members: null`, not a number. A count is a claim about the membership set, and this record
    is the one that declines to name one — stating it numerically while the verdict beside it
    abstains is the wrong answer wearing an honest verdict's clothes."""
    v = _vault()
    _note(v / "02-areas", "scoop-watch.md", "digest", mtime=OLD)
    _note(v / "02-areas", "research-0-synthesis.md", "explanation", mtime=NEW)
    assert _only(_audit(v))["members"] is None


def test_digest_at_the_vault_root_is_unmeasurable() -> None:
    v = _vault()
    _note(v, "everything.md", "digest", mtime=OLD)
    _note(v / "02-areas" / "frontend", "bundle.md", "explanation", mtime=NEW)
    r = next(d for d in _audit(v)["digests"] if d["path"].endswith("everything.md"))
    assert r["measurable"] is False and r["stale"] is None
    assert "root" in r["reason"]


def test_a_nested_area_is_measurable() -> None:
    """Depth is a FLOOR, not an equality — a source tree three levels down is still a directory
    whose contents are one area."""
    v = _vault()
    area = v / "10-reference" / "frozen" / "ddia-2e"
    _note(area, "ddia-digest.md", "digest", mtime=OLD)
    _note(area, "partitioning.md", "reference", mtime=NEW)
    r = _only(_audit(v))
    assert r["measurable"] is True and r["stale"] is True and r["members"] == 1


def test_a_sibling_digest_is_not_a_member() -> None:
    """A digest points at ATOMIC notes, so a newer digest beside it says nothing about whether this
    one is behind. Excluding every digest is also what makes two-digests-in-one-area need no rule."""
    v = _vault()
    area = v / "02-areas" / "frontend"
    _note(area, "frontend-digest.md", "digest", mtime=OLD)
    _note(area, "frontend-second-digest.md", "digest", mtime=NEW)
    _note(area, "bundle-optimization.md", "explanation", mtime=OLD)
    out = _audit(v)
    assert len(out["digests"]) == 2
    assert all(r["members"] == 1 for r in out["digests"]), out
    assert out["stale"] is False and out["behind"] == 0


def test_areas_do_not_leak_across_directories() -> None:
    """The whole membership rule: a note in a DIFFERENT area cannot make this digest stale."""
    v = _vault()
    _note(v / "02-areas" / "frontend", "frontend-digest.md", "digest", mtime=OLD)
    _note(v / "02-areas" / "backend", "pgx-pooling.md", "explanation", mtime=NEW)
    r = _only(_audit(v))
    assert r["members"] == 0 and r["stale"] is False


def test_links_are_not_read() -> None:
    """Membership is folder position. A digest that links a note by title, or links nothing at all,
    is measured identically — reading `[[links]]` would make an unwritten convention load-bearing."""
    v = _vault()
    area = v / "02-areas" / "frontend"
    d = area / "frontend-digest.md"
    _note(area, "frontend-digest.md", "digest", mtime=OLD)
    d.write_text("---\nstatus: active\ndoc_type: digest\n---\n\n# frontend\n\n"
                 "- [[some-note-that-is-not-here]] — a title, not a resolvable ref.\n",
                 encoding="utf-8")
    os.utime(d, (OLD, OLD))
    unlinked = _note(area, "bundle-optimization.md", "explanation", mtime=NEW)
    r = _only(_audit(v))
    assert r["members"] == 1 and r["newer"] == [str(unlinked.resolve())]


def test_a_vault_without_digests_is_checkable_and_clean() -> None:
    v = _vault()
    _note(v / "02-areas" / "frontend", "bundle-optimization.md", "explanation", mtime=NEW)
    out = _audit(v)
    assert out["digests"] == [] and out["stale"] is False
    assert out["checkable"] is True, "always-false `checkable` is the same defect as always-true"


def test_unreadable_note_makes_the_sweep_incomplete() -> None:
    """Neither a confirmed member nor a ruled-out digest — so it is counted as unexamined rather
    than silently folded into the member set, where it could have decided a verdict.

    The scope is resolved BEFORE the note breaks, because that is the only way this state reaches
    `audit`: `resolve_scope` reads every note for its doc_id pre-scan and refuses the whole vault
    on an unreadable one. What is left is the race — a file that changes between the walk and the
    audit — which is precisely what the guard is for.

    The unreadable condition is a DIRECTORY where a note was, not `chmod 000`: permission bits do
    not stop uid 0, so the chmod version would pass as root while claiming to have tested this.
    """
    v = _vault()
    area = v / "02-areas" / "frontend"
    _note(area, "frontend-digest.md", "digest", mtime=OLD)
    broken = _note(area, "bundle-optimization.md", "explanation", mtime=NEW)
    scope = V.resolve_scope(v)
    broken.unlink()
    broken.mkdir()
    out = digests.audit(scope)
    assert out["unreadable"] == [str(broken.resolve())], out
    assert out["checkable"] is False
    # `stale` stays false — nothing was found to differ — but `checkable` says the sweep was
    # incomplete. Reporting only the first is an all-clear over a note that was never read.
    assert out["stale"] is False
    assert _only(out)["members"] == 0


def test_inherited_vault_digests_are_placed_in_their_own_vault() -> None:
    """A composed scope carries core-vault's notes too, and a digest there belongs to core-vault's
    directories — never to a same-named directory in the project."""
    root = Path(tempfile.mkdtemp())
    core = root / "core-vault"
    _note(core / "02-areas" / "cadence", "cadence-digest.md", "digest", mtime=OLD)
    proj = root / "demo-vault"
    proj.mkdir(parents=True)
    (proj / ".substrate.toml").write_text('name = "demo"\ninherits = ["core-vault"]\n')
    _note(proj / "02-areas" / "cadence", "project-note.md", "explanation", mtime=NEW)
    r = _only(digests.audit(V.resolve_scope(proj)))
    assert r["vault"] == "core-vault" and r["area"] == "02-areas/cadence"
    assert r["members"] == 0 and r["stale"] is False


def test_meta_override_supplies_doc_type_only_when_the_note_declares_none() -> None:
    """The precedence `markdown.ingest` applies, mirrored rather than re-derived: a second rule here
    would disagree with the index about which notes are digests."""
    v = _vault()
    src = v / "10-reference" / "frozen" / "src"
    src.mkdir(parents=True)
    (src / "_meta.md").write_text("---\nclass: reference-frozen\ndoc_type: digest\n---\n",
                                  encoding="utf-8")
    passages = src / "passages"
    undeclared = passages / "00-inherits.md"
    passages.mkdir(parents=True)
    undeclared.write_text(f"---\nstatus: active\n---\n\n# inherits\n\n{BODY}\n", encoding="utf-8")
    os.utime(undeclared, (OLD, OLD))
    _note(passages, "01-declares.md", "reference", mtime=NEW)
    r = _only(_audit(v))
    assert r["path"].endswith("00-inherits.md"), "the _meta doc_type reached the undeclared note"
    assert r["members"] == 1, "the note that declared `reference` kept it"


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
