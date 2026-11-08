"""`substrate blobs`: status, forget, gc and adopt over the notes of every registered vault.

`gc` is the one operation that deletes without the operator naming a blob, so most of these pin
what it must refuse: an unreadable vault, an unknown chain, a malformed reference. Each would make
a held blob look unreferenced.
"""

from __future__ import annotations

import contextlib
import hashlib
import io
import json
import os
from pathlib import Path

import pytest

from substrate import blob_lifecycle as life
from substrate import blobs, cli, scopes


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _world(tmp_path: Path) -> tuple[Path, Path]:
    vault = tmp_path / "v-vault"
    (vault / "03-references").mkdir(parents=True)
    (vault / ".substrate.toml").write_text('name = "v"\ninherits = []\n', "utf-8")
    registry = tmp_path / "scopes.toml"
    scopes.record("v", vault=vault, db=tmp_path / "v.db", index_root=tmp_path / "ir",
                  registry=registry)
    return vault, registry


def _note(vault: Path, rel: str, **front: str) -> Path:
    p = vault / rel
    p.parent.mkdir(parents=True, exist_ok=True)
    lines = "".join(f"{k}: {v}\n" for k, v in front.items())
    p.write_text(f"---\ntitle: t\n{lines}---\n\n# t\n\nbody\n", "utf-8")
    return p


def _original(tmp_path: Path, name: str, data: bytes) -> tuple[Path, str]:
    p = tmp_path / "originals" / name
    p.parent.mkdir(parents=True, exist_ok=True)
    p.write_bytes(data)
    return p, _sha(data)


def _age_all() -> None:
    """Every held blob made older than gc's minimum age, as a long-settled store's are."""
    old = 1_000_000_000
    for c in blobs.held():
        os.utime(blobs.blob_path(blobs.root(), c), (old, old))


def _blobs(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = cli.main(["blobs", *argv])
    return rc, out.getvalue(), err.getvalue()


def test_gc_removes_only_what_no_note_names(tmp_path):
    vault, reg = _world(tmp_path)
    live, live_c = _original(tmp_path, "live.pdf", b"live")
    archived, archived_c = _original(tmp_path, "old.pdf", b"archived")
    templ, templ_c = _original(tmp_path, "t.pdf", b"template")
    you, you_c = _original(tmp_path, "you.wav", b"you")
    them, them_c = _original(tmp_path, "them.wav", b"them")
    orphan, orphan_c = _original(tmp_path, "orphan.pdf", b"orphan")
    for p in (live, archived, templ, you, them, orphan):
        blobs.put(p)
    _note(vault, "03-references/live.md", source_sha256=live_c)
    # Archived, skipped and transcript notes still keep their originals alive.
    _note(vault, "_archive/old.md", status="archived", source_sha256=archived_c)
    _note(vault, "99-templates/t.md", source_sha256=templ_c)
    _note(vault, "calls/call.md", audio_sha256=f"[{you_c}, {them_c}]")
    _age_all()

    plan = life.gc_plan(reg)
    assert set(plan.remove) == {orphan_c}
    with pytest.raises(life.Refused, match="plan changed"):
        life.gc_apply("0" * 16, reg)
    assert blobs.state(orphan_c) == "stored"

    life.gc_apply(plan.token, reg)
    assert set(blobs.held()) == {live_c, archived_c, templ_c, you_c, them_c}
    assert blobs.state(orphan_c) == "missing", "gc is not forget: no tombstone"


def test_gc_refuses_when_a_registered_vault_is_not_there(tmp_path):
    vault, reg = _world(tmp_path)
    blobs.put(_original(tmp_path, "a.pdf", b"a")[0])
    vault.rename(tmp_path / "unmounted")
    with pytest.raises(life.Refused, match="could not be read"):
        life.gc_plan(reg)
    assert len(blobs.held()) == 1


def test_gc_refuses_on_a_malformed_reference(tmp_path):
    vault, reg = _world(tmp_path)
    p, c = _original(tmp_path, "a.pdf", b"a")
    blobs.put(p)
    _note(vault, "03-references/a.md", source_sha256=c.upper())
    _note(vault, "calls/c.md", audio_sha256=f"[{c}, not-a-checksum]")
    with pytest.raises(life.Refused) as e:
        life.gc_plan(reg)
    assert "a.md" in str(e.value) and "c.md" in str(e.value)


def test_gc_refuses_with_no_registered_vault(tmp_path):
    blobs.put(_original(tmp_path, "a.pdf", b"a")[0])
    with pytest.raises(life.Refused, match="no registered vault"):
        life.gc_plan(tmp_path / "none.toml")


def test_gc_refuses_an_unreadable_note(tmp_path):
    vault, reg = _world(tmp_path)
    blobs.put(_original(tmp_path, "a.pdf", b"a")[0])
    os.mkfifo(vault / "03-references" / "bad.md")
    with pytest.raises(life.Refused, match="bad.md"):
        life.gc_plan(reg)


def test_adopt_finds_originals_at_source_path_then_under_search(tmp_path):
    vault, reg = _world(tmp_path)
    at_path, at_c = _original(tmp_path, "kept.pdf", b"still where it was")
    _moved, moved_c = _original(tmp_path, "moved.pdf", b"moved later")
    _gone, gone_c = _original(tmp_path, "gone.pdf", b"gone for good")
    elsewhere = tmp_path / "Downloads"
    elsewhere.mkdir()
    (elsewhere / "renamed.pdf").write_bytes(b"moved later")
    _note(vault, "03-references/kept.md", source_sha256=at_c, source_path=str(at_path))
    _note(vault, "03-references/moved.md", source_sha256=moved_c,
          source_path=str(tmp_path / "nowhere.pdf"))
    _note(vault, "03-references/gone.md", source_sha256=gone_c)
    (tmp_path / "originals" / "gone.pdf").write_bytes(b"different bytes now")

    plan = life.adopt_plan([elsewhere], reg)
    assert plan.found == {at_c: at_path, moved_c: elsewhere / "renamed.pdf"}
    assert plan.missing == [gone_c]
    life.adopt_apply(plan.token, [elsewhere], reg)
    assert set(blobs.held()) == {at_c, moved_c}
    assert blobs.verified(moved_c).read_bytes() == b"moved later"


def test_adopt_never_takes_a_forgotten_original_or_audio(tmp_path):
    vault, reg = _world(tmp_path)
    p, c = _original(tmp_path, "a.pdf", b"a")
    w, wc = _original(tmp_path, "you.wav", b"you")
    blobs.forget(c)
    _note(vault, "03-references/a.md", source_sha256=c, source_path=str(p))
    _note(vault, "calls/c.md", audio_sha256=f"[{wc}]", source_path=str(w))
    plan = life.adopt_plan([tmp_path / "originals"], reg)
    assert plan.found == {} and plan.missing == []


def test_status_counts_what_is_missing_and_what_is_the_only_copy(tmp_path):
    vault, reg = _world(tmp_path)
    p, c = _original(tmp_path, "a.pdf", b"a")
    blobs.put(p)
    _note(vault, "03-references/a.md", source_sha256=c, source_path=str(p))
    _note(vault, "03-references/b.md", source_sha256="b" * 64)
    _note(vault, "calls/c.md", audio_sha256=f"[{'c' * 64}, {'d' * 64}]")
    st = life.status(reg)
    assert st["originals"] == {"named": 2, "stored": 1, "discarded": 0, "missing": 1}
    assert st["audio"] == {"named": 2, "stored": 0}, "audio is never counted missing"
    assert st["only_copy"] == 0
    p.unlink()
    assert life.status(reg)["only_copy"] == 1
    assert st["complete"] is True


def test_the_cli_round_trip(tmp_path):
    vault, reg = _world(tmp_path)
    p, c = _original(tmp_path, "orphan.pdf", b"orphan")
    blobs.put(p)
    _age_all()
    _note(vault, "03-references/x.md", source_sha256="e" * 64)
    rc, out, _ = _blobs("gc", "--unreferenced", "--registry", str(reg))
    assert rc == 0 and f"would remove {c}" in out.replace("  ", " ")
    token = out.rsplit("--confirm ", 1)[1].strip()
    rc, out, _ = _blobs("gc", "--unreferenced", "--registry", str(reg), "--confirm", token)
    assert rc == 0 and blobs.held() == {}
    rc, _out, err = _blobs("gc", "--unreferenced", "--registry", str(reg), "--confirm", "bad")
    assert rc == 2 and "REFUSED" in err
    rc, out, _ = _blobs("forget", c)
    assert rc == 0 and blobs.state(c) == "discarded"
    rc, _out, err = _blobs("forget", "nope")
    assert rc == 2 and "not a SHA-256" in err
    rc, out, _ = _blobs("status", "--registry", str(reg), "--json")
    assert rc == 0 and json.loads(out)["discarded"] == 1


@pytest.mark.parametrize("shape", ["block-list", "bom", "quoted-key", "duplicate", "crlf",
                                   "body-only", "uppercase-in-body"])
def test_a_reference_the_reader_would_not_parse_still_keeps_its_blob(tmp_path, shape):
    """Each of these hides `source_sha256` from the note reader, which drops a frontmatter block
    over one line it does not recognise. gc must not let that decide what is alive."""
    vault, reg = _world(tmp_path)
    p, c = _original(tmp_path, "a.pdf", b"kept")
    q, d = _original(tmp_path, "b.pdf", b"also kept")
    blobs.put(p)
    blobs.put(q)
    note = vault / "03-references" / "n.md"
    body = {
        "block-list": f"---\ntitle: t\ntags:\n  - a\n  - b\nsource_sha256: {c}\n---\n\n# t\n",
        "bom": f"\ufeff---\ntitle: t\nsource_sha256: {c}\n---\n\n# t\n",
        "quoted-key": f'---\ntitle: t\n"source_sha256": "{c}"\n---\n\n# t\n',
        "duplicate": f"---\ntitle: t\nsource_sha256: {d}\nsource_sha256: {c}\n---\n\n# t\n",
        "crlf": f"---\r\ntitle: t\r\nsource_sha256: {c}\r\n---\r\n\r\n# t\r\n",
        "body-only": f"# t\n\nsource_sha256: {c}\n",
        "uppercase-in-body": f"# t\n\nsource_sha256: {c.upper()}\n",
    }[shape]
    note.write_text(body, "utf-8", newline="")
    if shape != "duplicate":
        _note(vault, "03-references/other.md", source_sha256=d)
    _age_all()
    assert life.gc_plan(reg).remove == {}


def test_a_block_list_of_audio_checksums_is_read(tmp_path):
    vault, reg = _world(tmp_path)
    you, yc = _original(tmp_path, "you.wav", b"you")
    blobs.put(you)
    (vault / "calls").mkdir()
    (vault / "calls" / "c.md").write_text(f"---\ntitle: t\naudio_sha256:\n  - {yc}\n  - {'f' * 64}\n"
                                          "---\n\n# t\n", "utf-8")
    _age_all()
    assert life.gc_plan(reg).remove == {}


def test_an_empty_reference_is_no_reference_not_an_error(tmp_path):
    vault, reg = _world(tmp_path)
    p, c = _original(tmp_path, "a.pdf", b"a")
    blobs.put(p)
    _note(vault, "99-templates/derived.md", source_sha256="")
    _note(vault, "99-templates/call.md", audio_sha256="[]")
    _age_all()
    assert set(life.gc_plan(reg).remove) == {c}


def test_gc_refuses_when_an_inherited_vault_has_moved(tmp_path):
    """`registered_vaults` skips an inherited vault it cannot find. For gc that silently drops
    every reference the moved vault held."""
    core = tmp_path / "core-vault"
    (core / "02-areas").mkdir(parents=True)
    (core / ".substrate.toml").write_text('name = "core"\ninherits = []\n', "utf-8")
    vault, reg = _world(tmp_path)
    (vault / ".substrate.toml").write_text(f'name = "v"\ninherits = ["{core}"]\n', "utf-8")
    p, c = _original(tmp_path, "a.pdf", b"named only in core")
    blobs.put(p)
    _note(core, "02-areas/a.md", source_sha256=c)
    _age_all()
    assert life.gc_plan(reg).remove == {}
    core.rename(tmp_path / "moved")
    with pytest.raises(life.Refused, match="cannot all be resolved"):
        life.gc_plan(reg)


def test_raw_sha256_on_a_sources_meta_keeps_its_original_and_can_adopt_it(tmp_path):
    vault, reg = _world(tmp_path)
    p, c = _original(tmp_path, "ddia.pdf", b"a hand-built source's raw")
    src = vault / "10-reference" / "ddia"
    src.mkdir(parents=True)
    (src / "_meta.md").write_text(f"---\ntitle: DDIA\nraw: ddia.pdf\nraw_sha256: {c}\n"
                                  f"raw_location: {p.parent}\n---\n\n# DDIA\n", "utf-8")
    plan = life.adopt_plan([], reg)
    assert plan.found == {c: p}
    life.adopt_apply(plan.token, [], reg)
    _age_all()
    assert life.gc_plan(reg).remove == {}
    assert life.status(reg)["originals"]["stored"] == 1


def test_gc_keeps_an_unreferenced_blob_until_it_is_old_enough(tmp_path):
    """An ingest stores its original before the app promotes the note naming it."""
    _vault_dir, reg = _world(tmp_path)
    p, c = _original(tmp_path, "staged.pdf", b"staged, not promoted")
    blobs.put(p)
    plan = life.gc_plan(reg)
    assert plan.remove == {} and set(plan.recent) == {c}
    later = blobs.held()[c].mtime + (life.MIN_AGE_DAYS + 1) * 86400
    assert set(life.gc_plan(reg, now=later).remove) == {c}


def test_a_token_from_one_registry_does_not_confirm_another(tmp_path):
    _vault_dir, reg = _world(tmp_path)
    other = tmp_path / "other"
    other.mkdir()
    o_vault = other / "o-vault"
    o_vault.mkdir()
    (o_vault / ".substrate.toml").write_text('name = "o"\ninherits = []\n', "utf-8")
    o_reg = other / "scopes.toml"
    scopes.record("o", vault=o_vault, db=other / "o.db", index_root=other / "ir", registry=o_reg)
    blobs.put(_original(tmp_path, "a.pdf", b"a")[0])
    _age_all()
    plan = life.gc_plan(reg)
    with pytest.raises(life.Refused):
        life.gc_apply(plan.token, o_reg)
    assert len(blobs.held()) == 1


def test_the_printed_confirm_command_keeps_the_registry_and_quotes_paths(tmp_path):
    vault, reg = _world(tmp_path)
    p, c = _original(tmp_path, "a.pdf", b"a")
    spaced = tmp_path / "My Downloads"
    spaced.mkdir()
    (spaced / "a.pdf").write_bytes(b"a")
    _note(vault, "03-references/a.md", source_sha256=c)
    rc, out, _ = _blobs("adopt", "--search", str(spaced), "--registry", str(reg))
    assert rc == 0
    import shlex

    command = shlex.split(out.rsplit("To adopt them: ", 1)[1])
    assert command[command.index("--search") + 1] == str(spaced)
    assert command[command.index("--registry") + 1] == str(reg)
    rc, _out, _ = _blobs(*command[2:])
    assert rc == 0 and blobs.state(c) == "stored"


def test_a_bom_does_not_hide_a_malformed_frontmatter_reference(tmp_path):
    vault, reg = _world(tmp_path)
    blobs.put(_original(tmp_path, "a.pdf", b"a")[0])
    (vault / "03-references" / "n.md").write_text(
        "\ufeff---\ntitle: t\nsource_sha256: see-the-pdf\n---\n\n# t\n", "utf-8")
    with pytest.raises(life.Refused, match="n.md"):
        life.gc_plan(reg)


def test_a_store_error_from_the_filesystem_exits_2_not_a_traceback(tmp_path, monkeypatch):
    _vault_dir, reg = _world(tmp_path)

    def denied(*a, **kw):
        raise PermissionError(13, "Permission denied", str(blobs.root() / "sha256"))

    monkeypatch.setattr(blobs, "held", denied)
    rc, _out, err = _blobs("status", "--registry", str(reg))
    assert rc == 2 and "FATAL (blob store)" in err and "Permission denied" in err


def test_a_second_forget_of_the_same_checksum_is_not_an_error(tmp_path):
    p, c = _original(tmp_path, "a.pdf", b"a")
    blobs.put(p)
    assert _blobs("forget", c)[0] == 0
    assert _blobs("forget", c)[0] == 0


@pytest.mark.parametrize("shape", ["list-of-mappings", "inline-mapping", "wrapped-flow-list"])
def test_more_reference_shapes_keep_their_blobs(tmp_path, shape):
    vault, reg = _world(tmp_path)
    p, c = _original(tmp_path, "a.pdf", b"a")
    q, d = _original(tmp_path, "b.pdf", b"b")
    blobs.put(p)
    blobs.put(q)
    body = {
        "list-of-mappings": f"---\ntitle: t\n---\n\n# t\n\nsources:\n  - source_sha256: {c}\n"
                            f"  - source_sha256: {d}\n",
        "inline-mapping": f"# t\n\nmeta: {{source_sha256: {c}, raw_sha256: '{d}'}}\n",
        "wrapped-flow-list": f"---\ntitle: t\naudio_sha256: [{c},\n  {d}]\n---\n\n# t\n",
    }[shape]
    (vault / "03-references" / "n.md").write_text(body, "utf-8")
    _age_all()
    assert life.gc_plan(reg).remove == {}


def test_a_blob_refreshed_after_the_plan_is_kept(tmp_path, monkeypatch):
    """The vaults are read outside the lock, so an ingest can find a planned blob present — and
    then promote a note naming it — before gc takes the lock. Its refreshed age saves it."""
    _vault_dir, reg = _world(tmp_path)
    p, c = _original(tmp_path, "a.pdf", b"a")
    blobs.put(p)
    _age_all()
    plan = life.gc_plan(reg)
    assert set(plan.remove) == {c}
    real = life.gc_plan

    def then_an_ingest(*a, **kw):
        out = real(*a, **kw)
        blobs.put(p, expected=c)
        return out

    monkeypatch.setattr(life, "gc_plan", then_an_ingest)
    done = life.gc_apply(plan.token, reg)
    assert done.remove == {} and blobs.state(c) == "stored"


def test_a_gc_that_fails_partway_says_what_it_removed(tmp_path, monkeypatch):
    _vault_dir, reg = _world(tmp_path)
    for name in ("a", "b"):
        blobs.put(_original(tmp_path, f"{name}.pdf", name.encode())[0])
    _age_all()
    plan = life.gc_plan(reg)
    real, calls = blobs.remove, []

    def flaky(c, *, store):
        calls.append(c)
        if len(calls) == 2:
            raise PermissionError(1, "Operation not permitted", c)
        return real(c, store=store)

    monkeypatch.setattr(blobs, "remove", flaky)
    with pytest.raises(blobs.BlobError) as e:
        life.gc_apply(plan.token, reg)
    assert f"removing 1 of 2 ({calls[0]})" in str(e.value)
    assert blobs.state(calls[0]) == "missing" and blobs.state(calls[1]) == "stored"


def test_an_unreadable_registry_is_named_not_reported_as_empty(tmp_path):
    reg = tmp_path / "scopes.toml"
    reg.write_text("scopes = [", "utf-8")
    with pytest.raises(life.Refused, match="cannot read scope registry"):
        life.gc_plan(reg)



def test_a_dangling_link_or_evicted_note_in_a_vault_makes_gc_refuse(tmp_path):
    vault, reg = _world(tmp_path)
    blobs.put(_original(tmp_path, "a.pdf", b"a")[0])
    (vault / "linked").symlink_to(tmp_path / "unmounted-volume")
    with pytest.raises(life.Refused, match="target is not there"):
        life.gc_plan(reg)
    (vault / "linked").unlink()
    (vault / "03-references" / ".n.md.icloud").write_bytes(b"bplist")
    with pytest.raises(life.Refused, match="evicted iCloud note"):
        life.gc_plan(reg)


def test_a_utf16_note_keeps_its_references(tmp_path):
    vault, reg = _world(tmp_path)
    p, c = _original(tmp_path, "a.pdf", b"a")
    blobs.put(p)
    (vault / "03-references" / "n.md").write_text(f"---\ntitle: t\nsource_sha256: {c}\n---\n",
                                                 "utf-16")
    _age_all()
    assert life.gc_plan(reg).remove == {}


def test_adopt_reports_only_what_it_stored(tmp_path, monkeypatch):
    vault, reg = _world(tmp_path)
    p, c = _original(tmp_path, "a.pdf", b"a")
    _note(vault, "03-references/a.md", source_sha256=c, source_path=str(p))
    plan = life.adopt_plan([], reg)
    real = life.adopt_plan

    def forgotten_meanwhile(*a, **kw):
        out = real(*a, **kw)
        blobs.forget(c)
        return out

    monkeypatch.setattr(life, "adopt_plan", forgotten_meanwhile)
    assert life.adopt_apply(plan.token, [], reg).found == {}


def test_a_hint_is_an_absolute_file_or_nothing(tmp_path):
    folder = tmp_path / "Books"
    folder.mkdir()
    assert life._hint("raw_sha256", [f"raw_location: {folder}"]) is None
    assert life._hint("raw_sha256", [f"raw_location: {folder}", "raw: x.pdf"]) == str(folder / "x.pdf")
    assert life._hint("source_sha256", ["source_path: relative/x.pdf"]) is None


def test_gc_refuses_while_a_vault_an_earlier_sweep_read_is_unregistered(tmp_path, monkeypatch):
    """`scopes.toml` is rebuilt one scope at a time and is safe to delete. A vault that drops out of
    it must not make its originals collectable."""
    vault, reg = _world(tmp_path)
    monkeypatch.setenv(scopes.ENV_VAR, str(reg))
    other = tmp_path / "w-vault"
    other.mkdir()
    (other / ".substrate.toml").write_text('name = "w"\ninherits = []\n', "utf-8")
    scopes.record("w", vault=other, db=tmp_path / "w.db", index_root=tmp_path / "wir", registry=reg)
    p, c = _original(tmp_path, "w.pdf", b"named only in w")
    blobs.put(p)
    _note(other, "n.md", source_sha256=c)
    _age_all()
    first = life.gc_plan(reg)
    life.gc_apply(first.token, reg)
    reg.unlink()
    scopes.record("v", vault=vault, db=tmp_path / "v.db", index_root=tmp_path / "ir", registry=reg)
    with pytest.raises(life.Refused, match="no longer lists"):
        life.gc_plan(reg)
    assert blobs.state(c) == "stored"
    retired = life.gc_plan(reg, retire=[other])
    assert set(retired.remove) == {c}
    life.gc_apply(retired.token, reg, retire=[other])
    assert blobs.state(c) == "missing"
    assert str(other.resolve()) not in blobs.seen_vaults(blobs.root())


def test_a_plan_alone_records_the_vaults_it_read(tmp_path, monkeypatch):
    """No sweep need ever have removed anything for a vault to be remembered."""
    vault, reg = _world(tmp_path)
    monkeypatch.setenv(scopes.ENV_VAR, str(reg))
    assert life.gc_plan(reg).remove == {}
    assert str(vault.resolve()) in blobs.seen_vaults(blobs.root())
    reg.unlink()
    other = tmp_path / "x-vault"
    other.mkdir()
    (other / ".substrate.toml").write_text('name = "x"\ninherits = []\n', "utf-8")
    scopes.record("x", vault=other, db=tmp_path / "x.db", index_root=tmp_path / "xir", registry=reg)
    with pytest.raises(life.Refused, match="no longer lists"):
        life.gc_plan(reg)


def test_retiring_a_vault_needs_no_blob_to_remove(tmp_path, monkeypatch):
    vault, reg = _world(tmp_path)
    monkeypatch.setenv(scopes.ENV_VAR, str(reg))
    life.gc_plan(reg)
    reg.unlink()
    other = tmp_path / "x-vault"
    other.mkdir()
    (other / ".substrate.toml").write_text('name = "x"\ninherits = []\n', "utf-8")
    scopes.record("x", vault=other, db=tmp_path / "x.db", index_root=tmp_path / "xir", registry=reg)
    rc, out, _ = _blobs("gc", "--unreferenced", "--registry", str(reg), "--retire-vault", str(vault))
    assert rc == 0 and "--confirm" in out
    import shlex

    rc, _out, _ = _blobs(*shlex.split(out.rsplit("To remove them: ", 1)[1])[2:])
    assert rc == 0
    assert str(vault.resolve()) not in blobs.seen_vaults(blobs.root())


def test_a_ledger_write_that_fails_says_what_was_removed(tmp_path, monkeypatch):
    vault, reg = _world(tmp_path)
    monkeypatch.setenv(scopes.ENV_VAR, str(reg))
    life.gc_plan(reg)
    reg.unlink()
    other = tmp_path / "x-vault"
    other.mkdir()
    (other / ".substrate.toml").write_text('name = "x"\ninherits = []\n', "utf-8")
    scopes.record("x", vault=other, db=tmp_path / "x.db", index_root=tmp_path / "xir", registry=reg)
    blobs.put(_original(tmp_path, "a.pdf", b"a")[0])
    _age_all()
    plan = life.gc_plan(reg, retire=[vault])
    real, calls = blobs.record_vaults, []

    def full_disk_on_the_second(*a):
        calls.append(1)
        if len(calls) == 2:
            raise OSError(28, "No space left on device")
        return real(*a)

    monkeypatch.setattr(blobs, "record_vaults", full_disk_on_the_second)
    with pytest.raises(blobs.BlobError, match="removed all 1 planned blob.*not yet retired"):
        life.gc_apply(plan.token, reg, retire=[vault])


@pytest.mark.parametrize("encoding", ["utf-32", "utf-16-le", "utf-16-be"])
def test_wide_encodings_without_a_bom_or_with_utf32_keep_references(tmp_path, encoding):
    vault, reg = _world(tmp_path)
    p, c = _original(tmp_path, "a.pdf", b"a")
    blobs.put(p)
    (vault / "03-references" / "n.md").write_bytes(
        f"---\ntitle: t\nsource_sha256: {c}\n---\n".encode(encoding))
    _age_all()
    assert life.gc_plan(reg).remove == {}


def test_raw_location_naming_the_file_itself_is_the_hint(tmp_path):
    f = tmp_path / "ddia.pdf"
    f.write_bytes(b"x")
    assert life._hint("raw_sha256", [f"raw_location: {f}", "raw: ddia.pdf"]) == str(f)


def test_a_corrupt_ledger_stops_gc_cleanly(tmp_path, monkeypatch):
    _vault_dir, reg = _world(tmp_path)
    monkeypatch.setenv(scopes.ENV_VAR, str(reg))
    life.gc_plan(reg)
    ledger = blobs.root() / blobs.LEDGER
    ledger.write_text("not json", "utf-8")
    rc, _out, err = _blobs("gc", "--unreferenced", "--registry", str(reg))
    assert rc == 2 and "vault ledger" in err


def test_a_vault_path_with_a_newline_survives_the_ledger(tmp_path):
    blobs.put(_original(tmp_path, "a.pdf", b"a")[0])
    store = blobs.root()
    with blobs.locked(store, exclusive=True):
        blobs.record_vaults(store, {"/odd\nname", "/plain"})
    assert blobs.seen_vaults(store) == {"/odd\nname", "/plain"}



def test_a_one_off_registry_leaves_the_ledger_alone(tmp_path):
    _vault_dir, reg = _world(tmp_path)
    life.gc_plan(reg)
    assert blobs.seen_vaults(blobs.root()) == set()


def test_a_stray_nul_in_a_utf8_note_does_not_hide_its_references(tmp_path):
    vault, reg = _world(tmp_path)
    p, c = _original(tmp_path, "a.pdf", b"a")
    blobs.put(p)
    (vault / "03-references" / "n.md").write_bytes(
        f"---\ntitle: t\x00\nsource_sha256: {c}\n---\n".encode())
    _age_all()
    assert life.gc_plan(reg).remove == {}


def test_raw_location_on_an_unmounted_folder_still_joins_raw():
    assert life._hint("raw_sha256", ["raw_location: /Volumes/Gone/Books", "raw: x.pdf"]) \
        == "/Volumes/Gone/Books/x.pdf"



def test_a_malformed_reference_in_a_bomless_utf16_note_is_still_caught(tmp_path):
    vault, reg = _world(tmp_path)
    blobs.put(_original(tmp_path, "a.pdf", b"a")[0])
    (vault / "03-references" / "n.md").write_bytes(
        "---\ntitle: t\nsource_sha256: see-the-pdf\n---\n".encode("utf-16-le"))
    with pytest.raises(life.Refused, match="n.md"):
        life.gc_plan(reg)


# ---------------------------------------------------------------- spellings only YAML reads
#
# Found by the Lean model's differential survey (2026-11-06): valid YAML that names a blob, which the
# line scan stopped reading at the first line that was not a `- item`, so gc planned the blob's
# removal. Each holds the only reference to `c`.

_HIDDEN = {
    "blank line after the key": "source_sha256:\n\n  - {c}",
    "comment after the key": "source_sha256:\n  # the originals\n  - {c}",
    "comment before a next-line value": "source_sha256:\n  # the original\n  {c}",
    "comment between two items": "audio_sha256:\n  - {d}\n  # and the other side\n  - {c}",
    "blank line between two items": "audio_sha256:\n  - {d}\n\n  - {c}",
    "trailing comment": "source_sha256: {c}  # the pdf",
    "folded scalar": "source_sha256: >-\n  {c}",
    "line continuation in a quoted scalar": 'source_sha256: "{c1}\\\n  {c2}"',
}


def _two_blobs(tmp_path: Path) -> tuple[Path, Path, str, str]:
    vault, reg = _world(tmp_path)
    p, c = _original(tmp_path, "a.pdf", b"the only copy of a recording")
    q, d = _original(tmp_path, "b.pdf", b"the other side")
    blobs.put(p)
    blobs.put(q)
    return vault, reg, c, d


@pytest.mark.parametrize("shape", sorted(_HIDDEN))
def test_a_reference_spelled_in_valid_yaml_keeps_its_blob(tmp_path, shape):
    vault, reg, c, d = _two_blobs(tmp_path)
    value = _HIDDEN[shape].format(c=c, d=d, c1=c[:32], c2=c[32:])
    (vault / "03-references" / "n.md").write_text(f"---\ntitle: t\n{value}\n---\n\n# t\n", "utf-8")
    _note(vault, "03-references/other.md", source_sha256=d)
    _age_all()
    assert life.gc_plan(reg).remove == {}
    # Read as a claim under its key, not only kept by the hex backstop: `adopt` and `status` go by
    # the key. (For literal spellings the line scan names the key too; the refusals above are what
    # show YAML read them.)
    assert value.split(":")[0] in {r.key for r in life.scan(reg).refs[c]}


def test_a_frontmatter_written_as_one_flow_mapping_keeps_every_item(tmp_path):
    vault, reg, c, d = _two_blobs(tmp_path)
    (vault / "calls").mkdir()
    (vault / "calls" / "c.md").write_text(
        f"---\n{{title: t, audio_sha256: [{d}, {c}]}}\n---\n\n# t\n", "utf-8")
    _age_all()
    assert life.gc_plan(reg).remove == {}
    assert "audio_sha256" in {r.key for r in life.scan(reg).refs[c]}


@pytest.mark.parametrize("value", ["source_sha256:\n  TODO",
                                   "source_sha256:\n  # the originals\n  - TODO",
                                   "audio_sha256:\n  - {c}\n\n  - pending",
                                   "meta:\n  source_sha256: TODO",
                                   "source_sha256: {{nested: {c}}}"])
def test_a_claim_that_is_not_a_checksum_refuses_however_it_is_spelled(tmp_path, value):
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f"---\ntitle: t\n{value.format(c=c)}\n---\n\n# t\n", "utf-8")
    _age_all()
    with pytest.raises(life.Refused, match="n.md"):
        life.gc_plan(reg)


@pytest.mark.parametrize("title", ['Re: "the call"', "Re: $\\alpha$ and C:\\Users", '"\\UFFFFFFFF"'])
def test_frontmatter_in_the_engines_dialect_that_is_not_yaml_does_not_block_gc(tmp_path, title):
    """A title the engine's own writer can leave invalid (a colon, a backslash, an escape `chr`
    rejects) neither blocks gc nor crashes it."""
    vault, reg, c, d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(f"---\ntitle: {title}\n---\n\n# t\n", "utf-8")
    _note(vault, "03-references/other.md", source_sha256=d)
    _age_all()
    assert set(life.gc_plan(reg).remove) == {c}


def test_frontmatter_that_is_not_yaml_and_may_name_a_blob_refuses_and_says_where(tmp_path):
    """Not the engine's dialect (an indented list), so no reading is certain. The refusal names the
    note and the line PyYAML stopped at, which is what the operator has to fix."""
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f"---\ntitle: Lecture 3: Integrals\ntags:\n  - calc\nsource_sha256: {c}\n---\n", "utf-8")
    _age_all()
    with pytest.raises(life.Refused, match=r"n\.md: the frontmatter is not YAML \(line 2: mapping "
                                           r"values are not allowed here\).*Quote or fix"):
        life.gc_plan(reg)


# Titles that leave the engine's unescaped writers producing frontmatter PyYAML rejects, or reads
# as something other than a title: a colon with a quote or a backslash, and every YAML indicator.
_HOSTILE_TITLES = ['He said "hi": ok', "Regex: \\d+ and C:\\Users", '"quoted": then more', "*bold* intro",
                   "&anchor text", "!important", "> quoted", "| piped", "- dash", "@handle",
                   "`code`", "%percent", "? question", "[bracket", "{brace", "#hash", "'single",
                   "trailing \\", "tab\there", "ünïcödé: x", "a\u2028b: c",
                   "[WIP] notes", "{draft} notes", "[Draft] *bold*", "[Draft] $\\alpha$",
                   "{x} *y*", "'90s \\m/", '"C:\\Temp" setup']


def _app_scalar(value: str) -> str:
    """`SubstrateLibraryVault.scalar` in the app, which writes a `_meta.md`'s values."""
    cleaned = "".join(" " if ch in "\x0b\x0c\x85\u2028\u2029" or ord(ch) < 0x20 else ch
                      for ch in value).strip()
    if '"' in cleaned:
        return cleaned
    return f'"{cleaned}"' if ":" in cleaned or not cleaned else cleaned


@pytest.mark.parametrize("title", _HOSTILE_TITLES)
def test_frontmatter_the_engine_and_the_app_write_never_blocks_gc(tmp_path, title):
    """`emit.frontmatter` (every ingest), `amend`'s doc_id pin and the app's `_meta.md`: what each
    writes is read with certainty, whatever the title, and names its blob under its key."""
    from substrate import notes
    from substrate.markdown.emit import frontmatter
    from substrate.models import Document

    vault, reg, c, d = _two_blobs(tmp_path)
    doc = Document(doc_id="n", source_path=str(tmp_path / "originals" / "a.pdf"), source_sha256=c,
                   source_pages=1, document_class="reference-frozen", status="active",
                   doc_type="reference", title=title, domains=["calc"])
    emitted = frontmatter(doc) + "# t\n\nbody\n"
    pinned = notes._pin(emitted.replace("doc_id: n\n", "").encode(), "n").decode()
    meta = (f"---\ntitle: {_app_scalar(title)}\nstatus: active\ndoc_type: reference\n"
            f"confidence: unstated\ndomains: [calc]\nraw: b.pdf\nraw_sha256: {d}\n---\n\nbody\n")
    (vault / "10-reference" / "src").mkdir(parents=True)
    (vault / "03-references" / "emitted.md").write_text(emitted, "utf-8")
    (vault / "03-references" / "pinned.md").write_text(pinned, "utf-8")
    (vault / "10-reference" / "src" / "_meta.md").write_text(meta, "utf-8")
    _age_all()
    assert life.gc_plan(reg).remove == {}
    refs = life.scan(reg).refs
    assert {"source_sha256"} <= {r.key for r in refs[c]} and "raw_sha256" in {r.key for r in refs[d]}


@pytest.mark.parametrize("claim", [
    "source_sha256:\n  \"\\x{h}{rest}\"",
    "source_sha256:\n  \"{c1}\\\n  {c2}\"",
    "audio_sha256:\n  - {d}\n  # x\n  - \"\\x{h}{rest}\"",
    "\"source_sha\\x3256\": \"\\x{h}{rest}\"",
    "x: &k \"source_s\\x68a256\"\n*k : \"\\x{h}{rest}\"",
    "notes: |\n a\n\tsource_sha256: \"\\x{h}{rest}\"",
    "x: [\na: b, {{source_sha256: \"\\x{h}{rest}\"}}]",
    "x: [ \"abc\n#\", {{source_sha256: \"\\x{h}{rest}\"}}]",
    "x: &k \"source_s\\x68a256\"\ny: [\n*k : {d}]",
    "title: [bracket\nsource_sha256: \"{c1}",
    "x: [a,\ny: b, {{\"\\x73ource_sha256\": \"\\x{h}{rest}\"}}]",
    "x: &a{{\"\\x73ource_sha256\": \"\\x{h}{rest}\"}}",
    "k1: &k source_sha256\nk2: &v \"\\x{h}{rest}\"\nx: {{*k : *v}}",
    "x: &k source_sha256\ny: {{*k : TODO}}",
    "title: \"source_sha\\x3256\": \"\\x{h}{rest}\"",
    "title: \"a\\\"\nnote: x \"y\\x{h}{rest}\"",
    "x: &k source_sha256\ny: {{*k: TODO}}",
])
def test_a_claim_hidden_from_the_line_scan_in_a_block_pyyaml_rejects_refuses(tmp_path, claim):
    """`[b, :c]` is YAML 1.2 that PyYAML rejects. A 1.2 reader then reads each of these claims, and
    the line scan reads none: a value on the next line, a list past a comment, an escaped key."""
    vault, reg, c, d = _two_blobs(tmp_path)
    value = claim.format(h=format(ord(c[0]), "02x"), rest=c[1:], c1=c[:32], c2=c[32:], d=d)
    (vault / "03-references" / "n.md").write_text(f"---\nodd: [b, :c]\n{value}\n---\n", "utf-8")
    _age_all()
    with pytest.raises(life.Refused, match="n.md"):
        life.gc_plan(reg)


def test_an_escaped_claim_in_frontmatter_yaml_cannot_parse_refuses(tmp_path):
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f'---\ntitle: Re: "x"\nsource_sha256: "\\x{ord(c[0]):02x}{c[1:]}"\n---\n', "utf-8")
    with pytest.raises(life.Refused, match="n.md"):
        life.gc_plan(reg)


def test_a_block_pyyaml_rejects_and_yaml_1_2_reads_is_read_as_1_2(tmp_path):
    """A tab after a colon is YAML 1.2, which Obsidian reads, and PyYAML rejects. The line scan does
    not decode the escape, and stops at the comment besides, so only a 1.2 reading keeps `c`."""
    vault, reg, c, d = _two_blobs(tmp_path)
    (vault / "calls").mkdir()
    (vault / "calls" / "c.md").write_text(
        f'---\ntitle:\tt\naudio_sha256:\n  - {d}\n  # the other side\n'
        f'  - "\\x{ord(c[0]):02x}{c[1:]}"\n---\n', "utf-8")
    _age_all()
    assert life.gc_plan(reg).remove == {}
    assert "audio_sha256" in {r.key for r in life.scan(reg).refs[c]}


@pytest.mark.parametrize("brk", ["\u2028", "\u2029", "\x85"])
def test_a_line_break_only_yaml_1_1_has_does_not_hide_a_claim(tmp_path, brk):
    """YAML 1.1 ends the comment at `brk` and opens a quoted value that swallows the claim; YAML 1.2
    runs the comment on and reads the claim on the next line."""
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f"---\ntitle: t #{brk}y: '\nsource_sha256: \"\\x{ord(c[0]):02x}{c[1:]}\"\n#'\n---\n",
        "utf-8")
    _age_all()
    assert c not in life.gc_plan(reg).remove


def test_an_indented_fence_is_text_in_the_block_not_its_end(tmp_path):
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f'---\nnotes: |\n  ---\n  more\nsource_sha256: "\\x{ord(c[0]):02x}{c[1:]}"\n---\n',
        "utf-8")
    _age_all()
    assert c not in life.gc_plan(reg).remove
    assert "source_sha256" in {r.key for r in life.scan(reg).refs[c]}


def test_a_dot_fence_still_ends_the_block_before_a_rule_in_the_body(tmp_path):
    vault, reg, c, d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f"---\ntitle: t\nsource_sha256: {c}\n...\n\nsource_sha256: see the pdf\n\n---\n\nmore\n",
        "utf-8")
    _note(vault, "03-references/other.md", source_sha256=d)
    _age_all()
    assert life.gc_plan(reg).remove == {}


def test_a_key_line_yaml_reads_as_text_still_names_its_key_for_adopt(tmp_path):
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f"---\nnotes: |\n  source_sha256: {c}\n---\n", "utf-8")
    assert "source_sha256" in {r.key for r in life.scan(reg).refs[c]}


@pytest.mark.parametrize("value", ['"null"', "'~'", '""', "''"])
def test_a_quoted_empty_value_is_no_reference_not_an_error(tmp_path, value):
    vault, reg, c, d = _two_blobs(tmp_path)
    _note(vault, "03-references/n.md", source_sha256=value)
    _note(vault, "03-references/other.md", source_sha256=d)
    _age_all()
    assert set(life.gc_plan(reg).remove) == {c}


def test_aliases_do_not_multiply_what_a_claim_costs(tmp_path):
    """300 keys aliasing one 300-item list: each item is one reference, not one per key."""
    items = [hashlib.sha256(str(i).encode()).hexdigest() for i in range(300)]
    front = "x: &a\n" + "".join(f"  - {h}\n" for h in items) + "".join(
        f"y{i}: {{audio_sha256: *a}}\n" for i in range(300))
    scan = life.Scan()
    life._text_refs(Path("n.md"), f"---\n{front}---\n", scan)
    assert not scan.malformed
    assert all(sum(r.key == "audio_sha256" for r in scan.refs[h]) == 1 for h in items)


def test_frontmatter_nested_too_deep_to_parse_refuses_cleanly(tmp_path):
    vault, reg, _c, _d = _two_blobs(tmp_path)
    deep = "[" * 20_000 + "]" * 20_000
    (vault / "03-references" / "n.md").write_text(
        f"---\ntitle: t\nsource_sha256: {deep}\n---\n", "utf-8")
    with pytest.raises(life.Refused, match="n.md"):
        life.gc_plan(reg)


@pytest.mark.parametrize("body", ["See {c} for the original.",
                                  "source_sha256:\n\n- {c}",
                                  "source_sha256:\n# Originals\n- {c}"])
def test_a_checksum_anywhere_in_the_body_keeps_its_blob(tmp_path, body):
    vault, reg, c, d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(f"# t\n\n{body.format(c=c)}\n", "utf-8")
    _note(vault, "03-references/other.md", source_sha256=d)
    _age_all()
    assert life.gc_plan(reg).remove == {}


@pytest.mark.parametrize("front, hint", [
    ("{{title: t, source_path: {p}, source_sha256: {c}}}", "p"),
    ("title: t\nsource_path: {p}  # where it was\nsource_sha256: {c}", "p"),
    ("{{source_path: {p}, source_path: /elsewhere.pdf, source_sha256: {c}}}", "p"),
    ("{{source_path: ~, source_sha256: {c}}}", None),
    ('{{source_path: "/x/\\0a.pdf", source_sha256: {c}}}', None),
    ('{{source_path: "/x/\\ud800.pdf", source_sha256: {c}}}', None),
    ("{{source_path: /x/\x01a.pdf, source_sha256: {c}}}", None),
])
def test_the_adopt_hint_is_read_from_the_same_yaml_as_the_claim(tmp_path, front, hint):
    vault, reg, c, _d = _two_blobs(tmp_path)
    where = tmp_path / "originals" / "a.pdf"
    (vault / "03-references" / "n.md").write_text(
        f"---\n{front.format(p=where, c=c)}\n---\n", "utf-8")
    hints = {r.hint for r in life.scan(reg).refs[c] if r.key == "source_sha256"} - {None}
    if hint:
        assert str(where) in hints
    assert not any("\x00" in h or "\x01" in h or "\ufffd" in h or "\ud800" in h for h in hints)


def test_a_body_reference_takes_its_hint_from_the_yaml_frontmatter(tmp_path):
    vault, reg, c, _d = _two_blobs(tmp_path)
    where = tmp_path / "originals" / "Screenshot at 10.00.00\u202fAM.png"
    (vault / "03-references" / "n.md").write_text(
        f"---\ntitle: t\nsource_path: {where}  # where it was\n---\n\nsource_sha256: {c}\n", "utf-8")
    assert str(where) in {r.hint for r in life.scan(reg).refs[c] if r.key == "source_sha256"}


@pytest.mark.parametrize("loc", ['"~x\\0y"', '"~\\ud800"', "~x\0y"])
def test_a_raw_location_no_path_can_hold_is_no_hint_not_a_crash(tmp_path, loc):
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "_meta.md").write_text(
        f"---\nraw: a.pdf\nraw_location: {loc}\nraw_sha256: {c}\n---\n", "utf-8")
    assert {r.hint for r in life.scan(reg).refs[c]} == {None}


@pytest.mark.parametrize("value", ["  - source_sha256: \"\\x{h}{rest}\"",
                                   "meta: {{source_sha256: \"\\x{h}{rest}\"}}"])
def test_an_escaped_nested_claim_in_a_block_pyyaml_rejects_refuses(tmp_path, value):
    """`[b, :c]` is YAML 1.2 that PyYAML rejects, so the block falls to the line scan, which reads
    neither a nested key nor an escape."""
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f"---\nodd: [b, :c]\nsources:\n{value.format(h=format(ord(c[0]), '02x'), rest=c[1:])}\n---\n",
        "utf-8")
    _age_all()
    with pytest.raises(life.Refused, match="n.md"):
        life.gc_plan(reg)


@pytest.mark.parametrize("value", ["' {c} '", ">\n  {c}\ntitle2: t"])
def test_a_checksum_with_surrounding_whitespace_is_still_one_checksum(tmp_path, value):
    vault, reg, c, d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f"---\ntitle: t\nsource_sha256: {value.format(c=c)}\n---\n", "utf-8")
    _note(vault, "03-references/other.md", source_sha256=d)
    _age_all()
    assert life.gc_plan(reg).remove == {}


def test_a_null_tag_on_a_value_does_not_make_it_empty(tmp_path):
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f'---\ntitle: t\nsource_sha256: !!null "\\x{ord(c[0]):02x}{c[1:]}"\n---\n', "utf-8")
    _age_all()
    assert c not in life.gc_plan(reg).remove
    assert "source_sha256" in {r.key for r in life.scan(reg).refs[c]}


@pytest.mark.parametrize("block", ['title: Lecture 3: Integrals\ntags:\n  - "$\\int$"',
                                   '?\n  "source_sha\\x3256" # c\n: "x"\nodd: [b, :c]'])
def test_frontmatter_that_is_not_yaml_refuses_even_when_no_key_shows(tmp_path, block):
    """Outside the engine's dialect no text test can rule a claim out (an explicit key, an alias, a
    comment between key and escape), so the block refuses, and says where."""
    vault, reg, _c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(f"---\n{block}\n---\n", "utf-8")
    with pytest.raises(life.Refused, match=r"n\.md: the frontmatter is not YAML \(line \d+: "):
        life.gc_plan(reg)


def test_a_tab_indenting_a_line_is_not_read_as_a_space(tmp_path):
    """Read as a space, the tab would fold the claim into the block scalar above as its text."""
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f'---\nnotes: |\n a\n\tsource_sha256: "\\x{ord(c[0]):02x}{c[1:]}"\n---\n', "utf-8")
    _age_all()
    with pytest.raises(life.Refused, match="n.md"):
        life.gc_plan(reg)


def test_a_control_character_on_a_claim_line_refuses(tmp_path):
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f'---\ntitle: t\n\x0csource_sha256: "\\x{ord(c[0]):02x}{c[1:]}"\n---\n', "utf-8")
    _age_all()
    with pytest.raises(life.Refused, match="n.md: a control character"):
        life.gc_plan(reg)


@pytest.mark.parametrize("brk", ["\x85", "\u2028", "\u2029"])
@pytest.mark.parametrize("claim", ['"source_sha\\x3256": "\\x{h}{rest}"',
                                   "*k : *v"])
def test_a_claim_only_yaml_1_1_reads_is_read(tmp_path, brk, claim):
    """YAML 1.1 breaks the line at NEL, LS and PS and reads what follows as a claim, which 1.2
    reads as the rest of a comment: both readings are taken."""
    vault, reg, c, _d = _two_blobs(tmp_path)
    after = claim.format(h=format(ord(c[0]), "02x"), rest=c[1:])
    (vault / "03-references" / "n.md").write_text(
        f'---\nk1: &k source_sha256\nk2: &v "\\x{ord(c[0]):02x}{c[1:]}"\ntitle: t #{brk}{after}\n'
        "---\n", "utf-8")
    _age_all()
    assert c not in life.gc_plan(reg).remove
    assert "source_sha256" in {r.key for r in life.scan(reg).refs[c]}


def test_a_control_character_before_an_escaped_key_refuses(tmp_path):
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f'---\ntitle: t #\x0c"source_sha\\x3256": "\\x{ord(c[0]):02x}{c[1:]}"\n---\n', "utf-8")
    _age_all()
    with pytest.raises(life.Refused, match="n.md: a control character"):
        life.gc_plan(reg)


def test_a_key_line_pyyaml_reads_into_a_quoted_value_refuses(tmp_path):
    vault, reg, _c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        '---\nx: "a\nsource_sha256: TODO"\n---\n', "utf-8")
    with pytest.raises(life.Refused, match="n.md: frontmatter line 3 names a checksum key"):
        life.gc_plan(reg)


def test_a_dialect_value_that_splits_a_key_out_refuses(tmp_path):
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f'---\nodd: [b, :c]\ntitle: see source_sha256: "\\x{ord(c[0]):02x}{c[1:]}"\n---\n',
        "utf-8")
    _age_all()
    with pytest.raises(life.Refused, match="n.md"):
        life.gc_plan(reg)


def test_items_under_a_key_in_an_open_tail_refuse(tmp_path):
    vault, reg, _c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        "---\ntitle: [WIP notes\nsource_sha256:\n  # the originals\n  - TODO\n---\n", "utf-8")
    with pytest.raises(life.Refused, match="n.md"):
        life.gc_plan(reg)


def test_a_run_of_tabs_after_a_colon_is_still_yaml_1_2(tmp_path):
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f"---\ntitle:\t\tt\ntags:\n  - a\nsource_sha256:\t\t{c}\n---\n", "utf-8")
    _age_all()
    assert c not in life.gc_plan(reg).remove
    assert "source_sha256" in {r.key for r in life.scan(reg).refs[c]}


def test_a_bare_scalar_frontmatter_naming_a_key_refuses(tmp_path):
    vault, reg, _c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text("---\nsource_sha256:TODO\n---\n", "utf-8")
    with pytest.raises(life.Refused, match="n.md: frontmatter line 2 names a checksum key"):
        life.gc_plan(reg)


def test_many_escapes_in_an_unclosed_quote_do_not_stall_the_scan():
    import time

    block = ["title: \"" + "\\x" * 200_000, "odd: [b, :c]"]
    t0 = time.monotonic()
    life._engine_dialect(block)
    assert time.monotonic() - t0 < 1.0


@pytest.mark.parametrize("block", ["a: b #\u2028c: d\nx: 'foo\nsource_sha256: \"\\x{h}{rest}\"'",
                                   "title: t\u2028y: '\nsource_sha256: \"\\x{h}{rest}\"\n#'"])
def test_yaml_1_2_decides_and_its_lines_are_the_ones_checked(tmp_path, block):
    """YAML 1.1 breaks at LS where 1.2 does not, so its line numbers are not the block's, and a
    block only 1.1 parses is not YAML to Obsidian: neither may switch the checks off."""
    vault, reg, c, _d = _two_blobs(tmp_path)
    text = block.format(h=format(ord(c[0]), "02x"), rest=c[1:])
    (vault / "03-references" / "n.md").write_text(f"---\n{text}\n---\n", "utf-8")
    _age_all()
    with pytest.raises(life.Refused, match="n.md"):
        life.gc_plan(reg)


def test_frontmatter_that_is_not_yaml_and_cannot_spell_a_key_does_not_block_gc(tmp_path):
    """No reader makes a checksum key out of text with no `sha256` in it and no escape."""
    vault, reg, c, d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        "---\ntitle: Lecture 3: Integrals\ntags:\n  - calc\n---\n", "utf-8")
    _note(vault, "03-references/other.md", source_sha256=d)
    _age_all()
    assert set(life.gc_plan(reg).remove) == {c}


@pytest.mark.parametrize("block", ["meta:\n  x: 'a\n  source_sha256: \"\\x{h}{rest}\"'",
                                   'meta:\n  x: "a\n  source_sha256: TODO"'])
def test_an_indented_line_pyyaml_reads_into_a_quoted_value_refuses(tmp_path, block):
    """YAML 1.2 wants the continuation deeper than its mapping; PyYAML takes it anyway."""
    vault, reg, c, _d = _two_blobs(tmp_path)
    text = block.format(h=format(ord(c[0]), "02x"), rest=c[1:])
    (vault / "03-references" / "n.md").write_text(f"---\n{text}\n---\n", "utf-8")
    _age_all()
    with pytest.raises(life.Refused, match="n.md: frontmatter line 4 names a checksum key"):
        life.gc_plan(reg)


def test_a_bom_inside_the_block_does_not_hide_a_key(tmp_path):
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f'---\ntitle: t\n\ufeffsource_sha256: "\\x{ord(c[0]):02x}{c[1:]}"\n---\n', "utf-8")
    _age_all()
    assert c not in life.gc_plan(reg).remove
    assert "source_sha256" in {r.key for r in life.scan(reg).refs[c]}


def test_a_block_too_long_for_frontmatter_is_not_composed(tmp_path, monkeypatch):
    vault, reg, c, d = _two_blobs(tmp_path)
    monkeypatch.setattr(life, "_MAX_FRONTMATTER", 200)
    composed = []
    monkeypatch.setattr(life.yaml, "compose", lambda *a, **k: composed.append(1))
    (vault / "03-references" / "n.md").write_text(
        "---\n" + "prose line about the call\n" * 10 + "---\n", "utf-8")
    _note(vault, "03-references/other.md", source_sha256=d)
    _age_all()
    life.scan(reg)
    assert len(composed) == 1  # `other.md` only


def test_a_value_an_emitter_wraps_does_not_block_gc(tmp_path):
    """PyYAML's own dumper wraps a long quoted string onto indented lines full of escapes, which
    every YAML reader reads the same way."""
    import yaml

    vault, reg, c, d = _two_blobs(tmp_path)
    title = 'He said "the original is at C:\\Temp\\call.wav" ' * 6
    front = yaml.safe_dump({"title": title, "nested": {"summary": title}, "source_sha256": c},
                           width=60, default_style=None)
    # wrapped, with a backslash on an indented continuation line
    assert any(line.startswith(" ") and "\\" in line for line in front.splitlines()[1:])
    (vault / "03-references" / "n.md").write_text(f"---\n{front}---\n", "utf-8")
    _note(vault, "03-references/other.md", source_sha256=d)
    _age_all()
    assert life.gc_plan(reg).remove == {}


def test_a_tab_does_not_cost_the_yaml_1_1_reading(tmp_path):
    vault, reg, c, _d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        f'---\ntitle:\tt #\u2028source_sha256: "\\x{ord(c[0]):02x}{c[1:]}"\n---\n', "utf-8")
    _age_all()
    assert c not in life.gc_plan(reg).remove
    assert "source_sha256" in {r.key for r in life.scan(reg).refs[c]}


def test_a_line_separator_in_a_dialect_comment_leaves_the_dialect():
    assert life._engine_dialect(["title: t", "#\u2028x"]) is False
    assert life._engine_dialect(["title: t", "# x"]) is True


def test_a_note_that_opens_with_a_rule_and_holds_latex_does_not_block_gc(tmp_path):
    vault, reg, c, d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        "---\nThe integral $\\int_0^1 x\\,dx$ is a half.\nSo is $\\frac{1}{2}$.\n---\n\nmore\n",
        "utf-8")
    _note(vault, "03-references/other.md", source_sha256=d)
    _age_all()
    assert set(life.gc_plan(reg).remove) == {c}


def test_a_list_item_spaced_from_its_dash_wraps_without_blocking_gc(tmp_path):
    vault, reg, c, d = _two_blobs(tmp_path)
    (vault / "03-references" / "n.md").write_text(
        "---\nnotes:\n-   'the pdf is at\n  C:\\Users\\me: here'\n---\n", "utf-8")
    _note(vault, "03-references/other.md", source_sha256=d)
    _age_all()
    assert set(life.gc_plan(reg).remove) == {c}


@pytest.mark.parametrize("front, key", [
    ("raw: Call #3.m4a\nraw_location: {d}\nraw_sha256: {c}", "raw_sha256"),
    ("source_path: {d}/Call #3.pdf\nsource_sha256: {c}", "source_sha256"),
])
def test_a_hint_the_engine_writes_unquoted_survives_yaml_reading_it(tmp_path, front, key):
    """YAML cuts `Call #3.pdf` at the comment; the writer meant the whole name."""
    vault, reg, c, _d = _two_blobs(tmp_path)
    folder = tmp_path / "originals"
    (vault / "03-references" / "_meta.md").write_text(
        f"---\n{front.format(d=folder, c=c)}\n---\n", "utf-8")
    hints = {r.hint for r in life.scan(reg).refs[c] if r.key == key}
    name = "Call #3.m4a" if key == "raw_sha256" else "Call #3.pdf"
    assert str(folder / name) in hints
