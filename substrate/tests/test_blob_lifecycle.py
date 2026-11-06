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
