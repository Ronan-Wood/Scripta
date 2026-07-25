"""Manifest resolution + composition proof — the inheritance mechanism (Doc 2 §1–2).

Two halves, both the "loading the wrong/no sources" failure the spike is built to catch:

  * resolve_scope REFUSES rather than composes a silently-wrong scope — a missing/malformed
    manifest, an inherited vault that does not exist, an empty scope, a cross-vault doc_id
    collision, an inheritance cycle.
  * assert_composed is the POST-INDEX proof that inheritance actually composed — every scope vault
    present (no silently-dropped core tier), every ingested note indexed, no out-of-scope vault.

Runnable with plain `python tests/test_manifest.py`.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import vault as V  # noqa: E402
from substrate.models import Chunk, Document  # noqa: E402
from substrate.store.index_store import IndexStore  # noqa: E402


def _note(dir_: Path, name: str, body: str, status: str = "active", doc_id: str | None = None) -> None:
    dir_.mkdir(parents=True, exist_ok=True)
    fm = ["---", f"status: {status}"]
    if doc_id:
        fm.append(f"doc_id: {doc_id}")
    fm.append("---")
    (dir_ / name).write_text("\n".join(fm) + f"\n\n# {name}\n\n{body}\n")


def _core(root: Path) -> Path:
    c = root / "core-vault"
    _note(c / "00-operator", "cadence.md", "audit review implement verify cadence body.")
    return c


def _project(root: Path, inherits: str = '["core-vault"]') -> Path:
    p = root / "demo-vault"
    p.mkdir(parents=True, exist_ok=True)
    (p / ".substrate.toml").write_text(f'name = "demo"\ninherits = {inherits}\n')
    _note(p / "02-areas", "area.md", "project area note body about retrieval.")
    return p


def _fresh_root() -> Path:
    return Path(tempfile.mkdtemp())


# ---------------------------------------------------------------- resolve_scope

def test_valid_scope_composes_core_and_project() -> None:
    root = _fresh_root()
    _core(root)
    proj = _project(root)
    scope = V.resolve_scope(proj)
    assert scope.vault_names == {"core-vault", "demo-vault"}
    tiers = {n.path.name: n.tier for n in scope.notes}
    assert tiers["cadence.md"] == 1 and tiers["area.md"] == 3
    # core (root) comes before the project in the ordered list.
    assert [v.name for v in scope.vaults] == ["core-vault", "demo-vault"]


def test_missing_manifest_refused() -> None:
    root = _fresh_root()
    (root / "no-manifest").mkdir(parents=True)
    try:
        V.resolve_scope(root / "no-manifest")
    except V.VaultError:
        return
    raise AssertionError("expected VaultError for a project vault with no manifest")


def test_malformed_manifest_refused() -> None:
    root = _fresh_root()
    p = root / "demo-vault"
    p.mkdir(parents=True)
    (p / ".substrate.toml").write_text('name = "demo"\ninherits = [broken\n')
    _note(p / "02-areas", "a.md", "body.")
    try:
        V.resolve_scope(p)
    except V.VaultError:
        return
    raise AssertionError("expected VaultError for a malformed manifest")


def test_missing_inherited_vault_refused() -> None:
    root = _fresh_root()
    proj = _project(root, inherits='["nonexistent-core"]')  # no core created
    try:
        V.resolve_scope(proj)
    except V.VaultError:
        return
    raise AssertionError("expected VaultError when an inherited vault does not exist")


def test_empty_scope_refused() -> None:
    root = _fresh_root()
    p = root / "empty-vault"
    p.mkdir(parents=True)
    (p / ".substrate.toml").write_text('name = "empty"\ninherits = []\n')  # no notes at all
    try:
        V.resolve_scope(p)
    except V.VaultError:
        return
    raise AssertionError("expected VaultError for a scope that discovers zero notes")


def test_cross_vault_doc_id_collision_refused() -> None:
    root = _fresh_root()
    c = root / "core-vault"
    _note(c / "00-operator", "x.md", "core body.", doc_id="dup")
    p = _project(root)
    _note(p / "02-areas", "y.md", "project body.", doc_id="dup")  # same declared doc_id
    try:
        V.resolve_scope(p)
    except V.VaultError:
        return
    raise AssertionError("expected VaultError for a doc_id claimed by two composed notes")


def test_filename_derived_doc_id_collision_refused() -> None:
    # The subtle case: two byte-identical, same-stem notes in different vaults declare NO frontmatter
    # doc_id, so both resolve to the SAME filename+content id — one would silently overwrite the
    # other at reconcile. resolve_scope computes the EFFECTIVE id (not just declared ones) to catch it.
    root = _fresh_root()
    c = root / "core-vault"
    _note(c / "00-operator", "dup.md", "byte identical body across vaults.")  # no doc_id declared
    p = _project(root)
    _note(p / "02-areas", "dup.md", "byte identical body across vaults.")  # identical bytes, same stem
    try:
        V.resolve_scope(p)
    except V.VaultError:
        return
    raise AssertionError("expected VaultError for a filename-derived doc_id collision across vaults")


def test_inheritance_cycle_refused() -> None:
    root = _fresh_root()
    a = root / "a-vault"
    b = root / "b-vault"
    a.mkdir(parents=True)
    b.mkdir(parents=True)
    (a / ".substrate.toml").write_text('name = "a"\ninherits = ["b-vault"]\n')
    (b / ".substrate.toml").write_text('name = "b"\ninherits = ["a-vault"]\n')
    _note(a / "02-areas", "a.md", "body a.")
    _note(b / "02-areas", "b.md", "body b.")
    try:
        V.resolve_scope(a)
    except V.VaultError:
        return
    raise AssertionError("expected VaultError for an inheritance cycle")


def test_absolute_path_inherit_resolves() -> None:
    # Location is the user's: an inherited vault named by an absolute path (a cloud folder) resolves.
    root = _fresh_root()
    core = _core(root)
    other = _fresh_root()  # project lives elsewhere; core is referenced by absolute path
    p = other / "demo-vault"
    p.mkdir(parents=True)
    (p / ".substrate.toml").write_text(f'name = "demo"\ninherits = ["{core}"]\n')
    _note(p / "02-areas", "a.md", "body.")
    scope = V.resolve_scope(p)
    assert scope.vault_names == {"core-vault", "demo-vault"}


def test_relative_path_inherit_resolves_against_project_parent() -> None:
    # A relative inherits entry WITH a separator must resolve against the project vault's parent,
    # deterministically — not against the process CWD. Here core lives under a `shared/` subdir.
    root = _fresh_root()
    core = root / "shared" / "core-vault"
    _note(core / "00-operator", "c.md", "core body.")
    p = root / "demo-vault"
    p.mkdir(parents=True)
    (p / ".substrate.toml").write_text('name = "demo"\ninherits = ["shared/core-vault"]\n')
    _note(p / "02-areas", "a.md", "body.")
    scope = V.resolve_scope(p)
    assert scope.vault_names == {"core-vault", "demo-vault"}


def test_vault_under_skip_named_ancestor_still_discovers_notes() -> None:
    # SKIP_DIRS must match the vault-RELATIVE path: a vault that happens to live under an ancestor
    # named `99-templates` must still discover its own notes, not skip every one.
    root = _fresh_root() / "99-templates"
    p = root / "demo-vault"
    p.mkdir(parents=True)
    (p / ".substrate.toml").write_text('name = "demo"\ninherits = []\n')
    _note(p / "02-areas", "a.md", "real note body under a skip-named ancestor.")
    scope = V.resolve_scope(p)
    assert [n.path.name for n in scope.notes] == ["a.md"]


def test_meta_domains_flow_to_reference_passage() -> None:
    root = _fresh_root()
    src = root / "core-vault" / "10-reference" / "frozen" / "software-dev" / "ddia"
    (src / "passages").mkdir(parents=True)
    (src / "_meta.md").write_text(
        "---\nclass: reference-frozen\nstatus: active\n"
        "domains: [software-dev, distributed-systems]\n---\n\nmeta.\n"
    )
    (src / "passages" / "p.md").write_text("# Partitioning\n\nsharding body.\n")
    p = _project(root)
    scope = V.resolve_scope(p)
    ref = next(n for n in scope.notes if n.path.name == "p.md")
    assert ref.tier == 2
    assert ref.extra_domains == ["software-dev", "distributed-systems"]
    assert ref.override_status == "active" and ref.doc_class == "reference-frozen"


# ---------------------------------------------------------------- assert_composed

def _seed_doc(store: IndexStore, doc_id: str, vault: str, tier: int) -> None:
    doc = Document(doc_id=doc_id, source_path=f"/{doc_id}.md", source_sha256="s", source_pages=1,
                   document_class="reference-frozen", title=doc_id, status="active",
                   vault=vault, tier=tier)
    ch = Chunk(chunk_id=f"{doc_id}#c0", doc_id=doc_id, kind="passage", text="body",
               path=["R", doc_id], level=2, document_class="reference-frozen")
    store.upsert(doc, [ch], markdown_path=f"/{doc_id}.md", markdown_mtime=0.0, markdown_sha256="m")


def _db() -> str:
    return str(Path(tempfile.mkdtemp()) / "index.db")


def test_assert_composed_passes_when_indexed_equals_ingested() -> None:
    with IndexStore(_db()) as s:
        _seed_doc(s, "op", "core-vault", 1)
        _seed_doc(s, "pr", "demo-vault", 3)
        rep = V.assert_composed(s, ingested_doc_ids={"op", "pr"})
        assert rep["by_vault"] == {"core-vault": 1, "demo-vault": 1}
        assert rep["by_tier"] == {1: 1, 3: 1}


def test_assert_composed_refuses_silently_dropped_core_tier() -> None:
    # The chapter-title bug reincarnate: a core note was ingested but never reached the index, so a
    # query returns plausible project-only results while core is silently gone.
    with IndexStore(_db()) as s:
        _seed_doc(s, "pr", "demo-vault", 3)  # only the project doc indexed; the core doc was dropped
        try:
            V.assert_composed(s, ingested_doc_ids={"op", "pr"})  # op (core) ingested, not indexed
        except V.VaultError:
            return
        raise AssertionError("expected VaultError when an ingested core note is missing from index")


def test_assert_composed_refuses_ingested_but_not_indexed() -> None:
    with IndexStore(_db()) as s:
        _seed_doc(s, "op", "core-vault", 1)
        _seed_doc(s, "pr", "demo-vault", 3)
        try:
            V.assert_composed(s, ingested_doc_ids={"op", "pr", "ghost"})  # ghost never indexed
        except V.VaultError:
            return
        raise AssertionError("expected VaultError when an ingested note is missing from the index")


def test_assert_composed_refuses_stale_or_out_of_scope_doc() -> None:
    # A doc the index holds that this compose did NOT ingest — a stale ingest dir from a deleted
    # note left by a --clean-less run, or out-of-scope content — would keep answering queries.
    with IndexStore(_db()) as s:
        _seed_doc(s, "op", "core-vault", 1)
        _seed_doc(s, "pr", "demo-vault", 3)
        _seed_doc(s, "stale", "demo-vault", 3)  # in-scope vault, but NOT ingested this run
        try:
            V.assert_composed(s, ingested_doc_ids={"op", "pr"})
        except V.VaultError:
            return
        raise AssertionError("expected VaultError when the index holds a doc this compose didn't ingest")


def test_assert_composed_allows_empty_inherited_vault() -> None:
    # A vault that legitimately contributes zero notes (e.g. an empty core) must NOT fail — it adds
    # nothing to either side of indexed==ingested, so it is neither required nor flagged missing.
    with IndexStore(_db()) as s:
        _seed_doc(s, "pr", "demo-vault", 3)  # core-vault present in scope but empty; only project docs
        rep = V.assert_composed(s, ingested_doc_ids={"pr"})
        assert rep["by_vault"] == {"demo-vault": 1}


def test_manifest_refuses_the_f9_table_scoping_bug() -> None:
    """`reference_domains` written BELOW `[reference_pins]` parses as a KEY OF THAT TABLE, so the
    vault's declared domains never exist at top level. Shipped in both manifests for a whole phase
    and invisible, because the two features that would read those keys are deferred — the value was
    declared, valid-looking, and read by nobody. Parse-time shape checking is what makes it loud."""
    root = Path(tempfile.mkdtemp())
    p = root / "demo-vault"
    p.mkdir()
    (p / ".substrate.toml").write_text(
        'name = "demo"\ninherits = []\n\n[reference_pins]\ngo = "1.21"\n'
        'reference_domains = ["software-dev"]\n')
    try:
        V._read_manifest(p)
    except V.VaultError as e:
        assert "reference_pins" in str(e)
        return
    raise AssertionError("a swallowed reference_domains must be refused at parse time")


def test_manifest_refuses_malformed_pins_and_domains() -> None:
    root = Path(tempfile.mkdtemp())
    for i, body in enumerate((
        'name = "d"\ninherits = []\n\n[reference_pins]\ngo = 1.21\n',        # non-string pin
        'name = "d"\ninherits = []\nreference_domains = ["ok", "not a tag!"]\n',  # bad tag shape
        'name = "d"\ninherits = []\nreference_domains = "software-dev"\n',      # not a list
    )):
        p = root / f"v{i}"
        p.mkdir()
        (p / ".substrate.toml").write_text(body)
        try:
            V._read_manifest(p)
        except V.VaultError:
            continue
        raise AssertionError(f"manifest {i} should have been refused: {body!r}")


def test_a_correct_manifest_still_parses() -> None:
    """The guard must not reject the shape every shipped vault actually uses."""
    root = Path(tempfile.mkdtemp())
    p = root / "ok-vault"
    p.mkdir()
    (p / ".substrate.toml").write_text(
        'name = "ok"\ninherits = ["core-vault"]\n'
        'reference_domains = ["software-dev", "retrieval"]\n\n'
        '[reference_pins]\ngo = "1.21"\n')
    m = V._read_manifest(p)
    assert m["reference_domains"] == ["software-dev", "retrieval"]
    assert m["reference_pins"] == {"go": "1.21"}


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
