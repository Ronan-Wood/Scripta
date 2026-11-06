"""The blob store: content-addressed, private, verified on read, and never in a sync folder."""

from __future__ import annotations

import hashlib
import os
import stat
from pathlib import Path

import pytest

from substrate import blobs


def _mode(p: Path) -> int:
    return stat.S_IMODE(os.lstat(p).st_mode)


def _file(tmp_path: Path, data: bytes = b"%PDF-1.7 an original\n", name: str = "a.pdf") -> Path:
    p = tmp_path / name
    p.write_bytes(data)
    return p


def test_put_files_the_bytes_under_their_checksum_privately(tmp_path):
    src = _file(tmp_path)
    old = os.umask(0o022)
    try:
        r = blobs.put(src)
    finally:
        os.umask(old)
    want = hashlib.sha256(src.read_bytes()).hexdigest()
    assert (r.checksum, r.outcome) == (want, "stored")
    store = blobs.root()
    assert r.path == store / "sha256" / want[:2] / want
    assert r.path.read_bytes() == src.read_bytes()
    assert _mode(r.path) == 0o400
    for d in (store, store / "sha256", store / "sha256" / want[:2], store / "tmp"):
        assert _mode(d) == 0o700, d
    assert blobs.exposed() == []
    assert blobs.leftovers() == []


def test_put_is_idempotent_and_verifies_what_it_already_holds(tmp_path):
    src = _file(tmp_path)
    first = blobs.put(src)
    assert blobs.put(src).outcome == "present"
    os.chmod(first.path, 0o600)
    first.path.write_bytes(b"rotted")
    again = blobs.put(src)
    assert again.outcome == "stored", "a corrupt blob is replaced by the verified copy"
    assert again.path.read_bytes() == src.read_bytes()
    assert {c: h.size for c, h in blobs.held().items()} == {first.checksum: len(src.read_bytes())}


def test_put_refuses_bytes_that_do_not_match_the_recorded_checksum(tmp_path):
    src = _file(tmp_path)
    with pytest.raises(blobs.BlobError, match="changed while it was being read"):
        blobs.put(src, expected="0" * 64)
    assert blobs.held() == {} and blobs.leftovers() == []


def test_verified_refuses_a_corrupt_blob(tmp_path):
    r = blobs.put(_file(tmp_path))
    assert blobs.verified(r.checksum) == r.path
    os.chmod(r.path, 0o600)
    r.path.write_bytes(b"rotted")
    with pytest.raises(blobs.BlobCorrupt):
        blobs.verified(r.checksum)


def test_forget_tombstones_first_and_ingest_does_not_re_add(tmp_path):
    src = _file(tmp_path)
    r = blobs.put(src)
    assert blobs.forget(r.checksum) is True
    assert blobs.state(r.checksum) == "discarded"
    assert not r.path.exists()
    assert blobs.put(src).outcome == "discarded"
    assert blobs.put(src, expected=r.checksum).outcome == "discarded"
    assert blobs.held() == {} and blobs.leftovers() == []
    assert blobs.forget(r.checksum) is False, "a second forget is a no-op, not an error"


def test_state_is_missing_for_an_unknown_checksum():
    assert blobs.state("a" * 64) == "missing"
    with pytest.raises(blobs.BlobError):
        blobs.state("not-a-checksum")


def test_config_moves_the_store(tmp_path, _private_blob_store):
    target = tmp_path / "elsewhere" / "blobs"
    (_private_blob_store / "config.toml").write_text(f'[blobs]\npath = "{target}"\n', "utf-8")
    assert blobs.root() == target
    r = blobs.put(_file(tmp_path))
    assert r.path.is_relative_to(target)


@pytest.mark.parametrize("body, match", [
    ('[blobs]\npath = "relative/blobs"\n', "relative"),
    ("[blobs]\npath = 3\n", "non-empty string"),
    ('blobs = "x"\n', "must be a table"),
    ("[blobs\n", "cannot read"),
])
def test_an_unusable_config_is_refused_not_defaulted(_private_blob_store, body, match):
    (_private_blob_store / "config.toml").write_text(body, "utf-8")
    with pytest.raises(blobs.StoreConfigError, match=match):
        blobs.root()


def test_a_store_in_a_sync_folder_is_refused(tmp_path, monkeypatch, _private_blob_store):
    home = tmp_path / "home"
    cloud = home / "Library" / "CloudStorage" / "CloudDrive"
    cloud.mkdir(parents=True)
    (home / "OneDrive").symlink_to(cloud)
    monkeypatch.setattr(Path, "home", lambda: home)
    for configured in (cloud / "blobs", home / "OneDrive" / "blobs"):
        (_private_blob_store / "config.toml").write_text(
            f'[blobs]\npath = "{configured}"\n', "utf-8")
        with pytest.raises(blobs.StoreConfigError, match="sync client"):
            blobs.root()


def test_a_symlink_inside_the_store_is_refused(tmp_path):
    blobs.put(_file(tmp_path, b"first", "first.pdf"))
    store = blobs.root()
    (store / "tmp").rmdir()
    (tmp_path / "outside").mkdir()
    (store / "tmp").symlink_to(tmp_path / "outside")
    with pytest.raises(blobs.BlobError, match="not a directory"):
        blobs.put(_file(tmp_path))
    assert list((tmp_path / "outside").iterdir()) == []


def test_a_loose_store_is_reported(tmp_path):
    r = blobs.put(_file(tmp_path))
    assert blobs.exposed() == []
    os.chmod(r.path.parent, 0o755)
    assert blobs.exposed() == [str(blobs.root())]


def _case_insensitive(p: Path) -> bool:
    try:
        return os.stat(str(p).swapcase()) == os.stat(p) if p.exists() else False
    except OSError:
        return False


def test_a_sync_folder_is_recognised_by_identity_not_spelling(tmp_path, monkeypatch,
                                                            _private_blob_store):
    home = tmp_path / "home"
    cloud = home / "Library" / "CloudStorage"
    cloud.mkdir(parents=True)
    monkeypatch.setattr(Path, "home", lambda: home)
    spelled = home / "library" / "cloudstorage" / "blobs"
    if _case_insensitive(cloud):
        (_private_blob_store / "config.toml").write_text(f'[blobs]\npath = "{spelled}"\n', "utf-8")
        with pytest.raises(blobs.StoreConfigError, match="sync client"):
            blobs.root()


def test_a_folder_marked_by_icloud_desktop_and_documents_is_refused(tmp_path, monkeypatch,
                                                                     _private_blob_store):
    import subprocess
    import sys

    docs = tmp_path / "Documents"
    docs.mkdir()
    if sys.platform != "darwin":
        monkeypatch.setattr(blobs, "_has_xattr", lambda p, n: Path(p) == docs
                            and n == "com.apple.icloud.desktop")
    else:
        subprocess.run(["xattr", "-w", "com.apple.icloud.desktop", "1", str(docs)], check=True)
    (_private_blob_store / "config.toml").write_text(f'[blobs]\npath = "{docs / "b"}"\n', "utf-8")
    with pytest.raises(blobs.StoreConfigError, match="sync client"):
        blobs.root()


def test_an_inheritable_acl_on_the_store_is_refused(tmp_path, monkeypatch):
    import subprocess
    import sys

    store = blobs.root()
    store.mkdir(parents=True)
    if sys.platform == "darwin":
        subprocess.run(["chmod", "+a", "everyone allow read,file_inherit,directory_inherit",
                        str(store)], check=True)
    else:
        monkeypatch.setattr(blobs, "_has_acl", lambda fd: True)
    with pytest.raises(blobs.BlobError, match="ACL"):
        blobs.put(_file(tmp_path))
    assert blobs.held() == {}


def test_an_existing_folder_that_is_not_a_store_is_not_taken_over(tmp_path, _private_blob_store):
    home = tmp_path / "someones-folder"
    home.mkdir()
    (home / "notes.txt").write_text("mine", "utf-8")
    os.chmod(home, 0o755)
    (_private_blob_store / "config.toml").write_text(f'[blobs]\npath = "{home}"\n', "utf-8")
    with pytest.raises(blobs.StoreConfigError, match="not a blob store"):
        blobs.put(_file(tmp_path))
    assert _mode(home) == 0o755, "a refused folder is not chmod-ed"


def test_a_store_under_a_folder_others_can_write_is_refused(tmp_path, _private_blob_store):
    shared = tmp_path / "shared"
    shared.mkdir()
    os.chmod(shared, 0o777)
    (_private_blob_store / "config.toml").write_text(
        f'[blobs]\npath = "{shared / "blobs"}"\n', "utf-8")
    with pytest.raises(blobs.StoreConfigError, match="cannot be trusted"):
        blobs.put(_file(tmp_path))


def test_forget_also_removes_an_interrupted_copy(tmp_path):
    src = _file(tmp_path)
    c = blobs.put(src).checksum
    leftover = blobs.root() / "tmp" / ".crashed"
    leftover.write_bytes(src.read_bytes())
    unrelated = blobs.root() / "tmp" / ".other"
    unrelated.write_bytes(b"something else")
    blobs.forget(c)
    assert not leftover.exists() and unrelated.exists()


def test_a_writer_waits_for_forget_and_gc(tmp_path):
    import threading

    src = _file(tmp_path)
    done = threading.Event()
    with blobs.locked(blobs.root(), exclusive=True):
        t = threading.Thread(target=lambda: (blobs.put(src), done.set()))
        t.start()
        assert not done.wait(0.3), "put ran while forget/gc held the store"
    t.join(5)
    assert done.is_set()


def test_finding_an_original_present_refreshes_its_age(tmp_path):
    src = _file(tmp_path)
    r = blobs.put(src)
    os.utime(r.path, (1_000_000, 1_000_000))
    assert blobs.put(src, expected=r.checksum).outcome == "present"
    assert blobs.held()[r.checksum].mtime > 1_000_000


def test_finder_metadata_in_the_store_does_not_stop_ingest(tmp_path):
    blobs.put(_file(tmp_path, b"first", "a.pdf"))
    (blobs.root() / ".DS_Store").write_bytes(b"Bud1")
    assert blobs.put(_file(tmp_path, b"second", "b.pdf")).outcome == "stored"


def test_a_new_store_folder_holding_only_finder_metadata_is_taken(tmp_path, _private_blob_store):
    fresh = tmp_path / "fresh"
    fresh.mkdir()
    (fresh / ".DS_Store").write_bytes(b"Bud1")
    (_private_blob_store / "config.toml").write_text(f'[blobs]\npath = "{fresh}"\n', "utf-8")
    assert blobs.put(_file(tmp_path)).outcome == "stored"


def test_a_short_write_is_completed_not_filed_truncated(tmp_path, monkeypatch):
    data = os.urandom(10_000)
    src = _file(tmp_path, data)
    real = os.write
    monkeypatch.setattr(blobs.os, "write", lambda fd, b: real(fd, bytes(b[:7])))
    r = blobs.put(src)
    assert r.checksum == hashlib.sha256(data).hexdigest()
    assert r.path.read_bytes() == data


def test_an_unreadable_blob_is_replaced_by_the_verified_copy(tmp_path):
    src = _file(tmp_path)
    r = blobs.put(src)
    os.chmod(r.path, 0o000)
    if os.access(r.path, os.R_OK):
        return  # root reads anything; the condition cannot be built
    assert blobs.put(src, expected=r.checksum).outcome == "stored"
    assert blobs.verified(r.checksum).read_bytes() == src.read_bytes()


def test_a_fifo_or_link_in_the_store_is_reported_without_hanging(tmp_path):
    blobs.put(_file(tmp_path))
    os.mkfifo(blobs.root() / "tmp" / "pipe")
    (blobs.root() / "tmp" / "link").symlink_to(tmp_path)
    found = blobs.exposed()
    assert any("link inside the store" in line for line in found), found


def test_held_skips_a_blob_removed_while_it_is_listed(tmp_path, monkeypatch):
    """Two blobs in one fan-out folder, the first removed mid-listing: the second is still held."""
    first = blobs.put(_file(tmp_path, b"0", "0.pdf"))
    n = 1
    while True:
        data = str(n).encode()
        if hashlib.sha256(data).hexdigest()[:2] == first.checksum[:2]:
            break
        n += 1
    second = blobs.put(_file(tmp_path, data, "n.pdf"))
    gone_one = min(first.checksum, second.checksum)
    real = os.lstat

    def gone(p, *a, **kw):
        if Path(p).name == gone_one:
            raise FileNotFoundError(2, "No such file", str(p))
        return real(p, *a, **kw)

    monkeypatch.setattr(blobs.os, "lstat", gone)
    assert set(blobs.held()) == {max(first.checksum, second.checksum)}



def test_a_folder_with_a_lone_tmp_is_not_taken_for_a_store(tmp_path, _private_blob_store):
    project = tmp_path / "project"
    (project / "tmp").mkdir(parents=True)
    os.chmod(project, 0o755)
    (_private_blob_store / "config.toml").write_text(f'[blobs]\npath = "{project}"\n', "utf-8")
    with pytest.raises(blobs.StoreConfigError, match="not a blob store"):
        blobs.put(_file(tmp_path))
    assert _mode(project) == 0o755


def test_forget_does_not_hang_on_a_fifo_in_tmp(tmp_path):
    import threading

    r = blobs.put(_file(tmp_path))
    os.mkfifo(blobs.root() / "tmp" / "pipe")
    done = threading.Event()
    t = threading.Thread(target=lambda: (blobs.forget(r.checksum), done.set()), daemon=True)
    t.start()
    assert done.wait(5), "forget opened the FIFO while holding the store's exclusive lock"


def test_two_writers_initialising_one_store_both_succeed(tmp_path, monkeypatch):
    """Both list the new folder as empty; the second finds the first's 0400 marker already there."""
    store = blobs.root()
    store.mkdir(parents=True, mode=0o700)
    (store / blobs.MARKER).touch(mode=0o400)
    real = os.listdir
    monkeypatch.setattr(blobs.os, "listdir", lambda p: [] if Path(p) == store else real(p))
    assert blobs.put(_file(tmp_path)).outcome == "stored"
