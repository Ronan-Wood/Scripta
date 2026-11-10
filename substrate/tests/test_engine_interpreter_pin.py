"""The bundled interpreter is checked against a pin before it is run, and again before it is signed.

Through 0.3.3, `tools/build-bundled-engine` established WHERE its interpreter was (not a venv, under
`uv python dir`) and nothing about WHAT it was: whatever sat in uv's store was copied into
`runtime/`, signed with the Developer ID, and given allow-jit on `python3.14`. These pin the checker,
`tools/engine-interpreter-pin.py`, on small trees, and the build's use of it with a fake uv in front
of the real one, as `test_bundled_engine_runtime.py` does, in a copy of the repo carrying a pin for
a fake interpreter. No engine is built.
"""

from __future__ import annotations

import errno
import importlib.util
import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "tools" / "build-bundled-engine"
TOOL = ROOT / "tools" / "engine-interpreter-pin.py"
PIN = ROOT / "tools" / "engine-interpreter.pin"
SYSTEM_PYTHON = Path("/usr/bin/python3")
SYSCONFIG = "lib/python3.14/_sysconfigdata__darwin_darwin.py"
# The shape uv gives an install, and the minor-version link it puts beside it.
STORE, STORE_LINK = "cpython-3.14.7-macos-aarch64-none", "cpython-3.14-macos-aarch64-none"


def _tool():
    spec = importlib.util.spec_from_file_location("engine_interpreter_pin", TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def _sysconfig(root: object) -> str:
    # Every shape the real file spells a path in: followed by `/`, by a quote, by a space.
    return (f"build_time_vars = {{'INCLUDEPY': '{root}/include/python3.14', 'prefix': '{root}', "
            f"'DESTDIRS': '{root} {root}/lib'}}\n")


def _interpreter(root: Path) -> Path:
    """A standalone-shaped tree with every feature a rule applies to, as uv leaves it."""
    (root / "bin").mkdir(parents=True)
    root = Path(os.path.realpath(root))
    python = root / "bin" / "python3.14"
    python.write_bytes(b"\xcf\xfa\xed\xfe interpreter")
    python.chmod(0o755)
    (root / "bin" / "python3").symlink_to("python3.14")
    lib = root / "lib" / "python3.14"
    (lib / "site-packages").mkdir(parents=True)
    (lib / "os.py").write_text("import sys\n")
    # uv writes its install prefix here, and build tools read `Python.h`'s location from it.
    (root / SYSCONFIG).write_text(_sysconfig(root))
    (root / "lib" / "libpython3.14.dylib").write_bytes(b"\xcf\xfa\xed\xfe\0" + str(root).encode() + b"\0")
    (lib / "__pycache__").mkdir()
    (lib / "__pycache__" / "os.cpython-314.pyc").write_bytes(b"written by use")
    (root / "include" / "python3.14").mkdir(parents=True)
    (root / "include" / "python3.14" / "patchlevel.h").write_text('#define PY_VERSION              "3.14.7"\n')
    (root / "BUILD").write_text("20260805\n")
    return root


def _staged(store: Path, stage: Path) -> Path:
    staged = stage / "runtime"
    shutil.copytree(store, staged, symlinks=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    return Path(os.path.realpath(staged))


def _pinned(tmp_path: Path) -> tuple[Path, Path, Path]:
    """`(store, pin, staged copy with its bytecode deleted)`, the shape the build checks."""
    store = _interpreter(tmp_path / "uv" / "python" / STORE)
    pin = tmp_path / "engine-interpreter.pin"
    assert _tool().main(["--write", str(store), str(pin)]) == 0
    return store, pin, _staged(store, tmp_path / "stage")


def _run(*argv: object) -> int:
    return _tool().main([str(a) for a in argv])


# ------------------------------------------------------------------ the first check


def test_an_unchanged_copy_passes_and_bytecode_is_not_pinned(tmp_path: Path) -> None:
    store, pin, staged = _pinned(tmp_path)
    assert _run("--check", staged, store, pin) == 0
    assert stat.S_IMODE(pin.stat().st_mode) == 0o644  # `mkstemp` makes it 0o600
    text = pin.read_text()
    assert f"prefix\t{store}\n" in text
    assert "l\tpython3.14\tbin/python3\n" in text
    assert "lib/python3.14/os.py\n" in text
    assert "pyc" not in text and "__pycache__" not in text
    assert "# python 3.14.7, python-build-standalone 20260805" in text


@pytest.mark.parametrize(
    ("tamper", "expected"),
    [
        (lambda t: (t / "lib/python3.14/os.py").write_text("import evil\n"), "1 changed"),
        (lambda t: (t / "lib/python3.14/os.py").unlink(), "1 missing"),
        # The file `site` executes at startup: the shape of a planted payload that edits nothing.
        (lambda t: (t / "lib/python3.14/site-packages/evil.pth").write_text("import evil\n"), "1 unexpected"),
        (lambda t: ((t / "bin/python3").unlink(), (t / "bin/python3").symlink_to("/tmp/evil")), "1 changed"),
    ],
    ids=["changed-byte", "missing-file", "planted-pth", "retargeted-symlink"],
)
def test_a_modified_copy_is_refused_and_named(tmp_path: Path, capsys, tamper, expected: str) -> None:
    store, pin, staged = _pinned(tmp_path)
    tamper(staged)
    assert _run("--check", staged, store, pin) == 1
    err = capsys.readouterr().err
    assert "does not match engine-interpreter.pin before the build ran it: " in err
    assert expected in err
    assert "uv python install --reinstall" in err


@pytest.mark.parametrize(
    ("target", "mode"),
    [("bin/python3.14", 0o4755), ("lib/python3.14/os.py", 0o664), ("lib/python3.14/site-packages", 0o777)],
    ids=["setuid-interpreter", "group-writable-module", "world-writable-dir"],
)
def test_a_mode_the_bytes_do_not_show_is_refused(tmp_path: Path, capsys, target: str, mode: int) -> None:
    # `cp -p` carries modes into the signed bundle, and a setuid interpreter there runs as whoever
    # installed it for anyone who can reach it.
    store, pin, staged = _pinned(tmp_path)
    (staged / target).chmod(mode)
    try:
        assert _run("--check", staged, store, pin) == 1
    finally:
        (staged / target).chmod(0o755)
    assert "setuid, setgid, sticky or writable by group or others" in capsys.readouterr().err


def test_another_install_path_is_refused_by_name(tmp_path: Path, capsys) -> None:
    store, pin, staged = _pinned(tmp_path)
    assert _run("--check", staged, tmp_path / "elsewhere", pin) == 1
    err = capsys.readouterr().err
    assert f"the engine interpreter is {tmp_path / 'elsewhere'}, but engine-interpreter.pin was made for {store}" in err


def test_the_install_path_is_compared_resolved_as_write_records_it(tmp_path: Path) -> None:
    # `--write` records the real path; a caller reaching the same install through uv's minor-version
    # symlink must not be told it is a different one.
    store, pin, staged = _pinned(tmp_path)
    (tmp_path / "cpython-3.14").symlink_to(store)
    assert _run("--check", staged, tmp_path / "cpython-3.14", pin) == 0


@pytest.mark.parametrize(
    "bytecode",
    ["lib/python3.14/__pycache__/os.cpython-314.pyc", "lib/python3.14/sourceless.pyc"],
    ids=["pycache", "sourceless-pyc"],
)
def test_bytecode_in_the_checked_tree_is_refused(tmp_path: Path, capsys, bytecode: str) -> None:
    # A `.pyc` with a valid header is imported in place of its `.py`, and none is pinned, so the
    # checked tree may hold none. A sourceless `.pyc` beside the modules imports with no `.py` at all.
    store, pin, staged = _pinned(tmp_path)
    (staged / bytecode).parent.mkdir(parents=True, exist_ok=True)
    (staged / bytecode).write_bytes(b"planted")
    assert _run("--check", staged, store, pin) == 1
    assert "bytecode entries are in the checked tree" in capsys.readouterr().err


def test_a_special_file_is_refused(tmp_path: Path) -> None:
    store, pin, staged = _pinned(tmp_path)
    os.mkfifo(staged / "lib" / "fifo")
    assert _run("--check", staged, store, pin) == 1


# ------------------------------------------------------------------ a check that cannot run is not a refusal


@pytest.mark.parametrize(
    "body",
    [
        b"",
        b"f\tnot-a-digest\tBUILD\n",
        b"prefix\t/a\nf\t" + b"0" * 64 + b"\tx\nf\t" + b"0" * 64 + b"\tx\n",
        b"nonsense\n",
        b"prefix\t/a\n\xff\xfe\n",
    ],
    ids=["empty", "bad-digest", "repeated-path", "unparseable", "not-ascii"],
)
def test_an_unreadable_pin_is_a_broken_check_not_a_refusal(tmp_path: Path, capsys, body: bytes) -> None:
    store, _, staged = _pinned(tmp_path)
    bad = tmp_path / "bad.pin"
    bad.write_bytes(body)
    assert _run("--check", staged, store, bad) == 2
    assert "the check itself failed" in capsys.readouterr().err


def test_a_missing_pin_is_a_broken_check(tmp_path: Path) -> None:
    store, _, staged = _pinned(tmp_path)
    assert _run("--check", staged, store, tmp_path / "absent.pin") == 2


def test_an_unexpected_exception_is_a_broken_check_not_a_refusal(tmp_path: Path, monkeypatch, capsys) -> None:
    # Python exits 1 on an uncaught exception, which is the code the build reads as tampering.
    tool = _tool()
    store, pin, staged = _pinned(tmp_path)

    def broken(*args, **kwargs):
        raise ValueError("something nobody anticipated")

    monkeypatch.setattr(tool, "scan", broken)
    assert tool.main(["--check", str(staged), str(store), str(pin)]) == 2
    assert "the check itself failed: ValueError" in capsys.readouterr().err


# ------------------------------------------------------------------ relocation and the recheck


def test_relocation_points_the_copy_at_itself(tmp_path: Path) -> None:
    store, pin, staged = _pinned(tmp_path)
    assert _run("--relocate", staged, store) == 0
    assert (staged / SYSCONFIG).read_text() == _sysconfig(staged)
    # A dylib's own install name is binary and is left alone.
    assert str(store).encode() in (staged / "lib" / "libpython3.14.dylib").read_bytes()


def test_relocation_refuses_a_non_dylib_binary_that_names_the_store(tmp_path: Path, capsys) -> None:
    store, pin, staged = _pinned(tmp_path)
    (staged / "lib" / "helper.so").write_bytes(b"\0" + str(store).encode())
    assert _run("--relocate", staged, store) == 1
    assert "lib/helper.so" in capsys.readouterr().err


def _relocated(tmp_path: Path) -> tuple[Path, Path, Path]:
    store, pin, staged = _pinned(tmp_path)
    assert _run("--relocate", staged, store) == 0
    return store, pin, staged


def test_the_recheck_passes_a_relocated_slimmed_copy(tmp_path: Path) -> None:
    store, pin, staged = _relocated(tmp_path)
    shutil.rmtree(staged / "include")  # what the slimming step deletes
    assert _run("--recheck", staged, store, pin) == 0
    # The first check would refuse this tree: the recheck is the only one that allows missing files.
    assert _run("--check", staged, store, pin) == 1


def _store_spelt(name: str):
    def tamper(t: Path) -> None:
        # `_sysconfigdata` pointed back at uv's store: as the pinned path, it hashes exactly as pinned
        # once unmapped; as the minor-version link beside it, it names a directory the pin never saw.
        sysconfig = t / SYSCONFIG
        sysconfig.write_text(sysconfig.read_text().replace(str(t), str(t.parent.parent / "uv" / "python" / name)))
    return tamper


def _pycache_symlink(t: Path) -> None:
    (t / "lib/python3.14/__pycache__").symlink_to(t.parent)


@pytest.mark.parametrize(
    ("tamper", "expected"),
    [
        (lambda t: (t / "lib/python3.14/os.py").write_text("import evil\n"), "1 changed"),
        (lambda t: (t / SYSCONFIG).write_text("build_time_vars = {'INCLUDEPY': '/tmp/evil'}\n"), "1 changed"),
        (_store_spelt(STORE), "name the uv store again"),
        (_store_spelt(STORE_LINK), "name the uv store again"),
        (_store_spelt(STORE.upper()), "name the uv store again"),
        # A binary is hashed as it is: writing the copy's path into it is a change, not a relocation.
        (lambda t: (t / "lib/libpython3.14.dylib").write_bytes(b"\xcf\xfa\xed\xfe\0" + str(t).encode() + b"\0"),
         "1 changed"),
        (lambda t: (t / "lib/python3.14/site-packages/evil.pth").write_text("import evil\n"), "1 unexpected"),
        (lambda t: (t / "lib/python3.14/sourceless.pyc").write_bytes(b"planted"), "bytecode entries"),
        # The build deletes all bytecode before the recheck, so one inside a `__pycache__`, at any
        # optimisation level, is refused like any other.
        (lambda t: ((t / "lib/python3.14/__pycache__").mkdir(),
                    (t / "lib/python3.14/__pycache__/os.cpython-314.opt-1.pyc").write_bytes(b"planted")),
         "bytecode entries"),
        (_pycache_symlink, "bytecode entries"),
    ],
    ids=["changed-module", "changed-sysconfig", "store-named-again", "store-named-by-link", "store-named-in-capitals",
         "binary-relocated",
         "planted-pth",
         "sourceless-pyc", "opt-1-pyc", "symlinked-pycache"],
)
def test_the_recheck_refuses_what_ran_in_between_changing_the_copy(tmp_path: Path, capsys, tamper, expected) -> None:
    store, pin, staged = _relocated(tmp_path)
    tamper(staged)
    assert _run("--recheck", staged, store, pin) == 1
    assert expected in capsys.readouterr().err


@pytest.mark.skipif(os.geteuid() == 0, reason="root reads a mode-000 directory")
@pytest.mark.parametrize("mode", ["--check", "--recheck"])
def test_a_directory_the_check_cannot_read_is_a_broken_check(tmp_path: Path, capsys, mode: str) -> None:
    # `os.walk` skips what it cannot list; on the recheck, which allows missing files, that passed.
    store, pin, staged = _relocated(tmp_path) if mode == "--recheck" else _pinned(tmp_path)
    locked = staged / "lib" / "python3.14"
    locked.chmod(0o000)
    try:
        assert _run(mode, staged, store, pin) == 2
    finally:
        locked.chmod(0o755)
    assert "cannot read" in capsys.readouterr().err


@pytest.mark.parametrize("mode", ["--check", "--recheck"])
def test_a_tree_that_is_not_there_is_a_broken_check(tmp_path: Path, mode: str) -> None:
    store, pin, _ = _pinned(tmp_path)
    assert _run(mode, tmp_path / "absent", store, pin) == 2


def test_a_writable_root_is_refused(tmp_path: Path, capsys) -> None:
    # `os.walk` yields only the root's children, so the root's own mode went unchecked.
    store, pin, staged = _pinned(tmp_path)
    staged.chmod(0o777)
    try:
        assert _run("--check", staged, store, pin) == 1
    finally:
        staged.chmod(0o755)
    assert ". (drwxrwxrwx)" in capsys.readouterr().err


def _unspellable_name(lib: Path, name: str) -> None:
    (lib / name).write_text("")


def _unspellable_target(lib: Path, name: str) -> None:
    (lib / "link.py").symlink_to(name)


@pytest.mark.parametrize("plant", [_unspellable_name, _unspellable_target], ids=["name", "link-target"])
@pytest.mark.parametrize("name", ["carriage\rreturn.py", "form\x0cfeed.py", "caf\u00e9.py"],
                         ids=["cr", "formfeed", "non-ascii"])
def test_what_the_pin_cannot_spell_is_broken_when_writing(tmp_path: Path, capsys, plant, name: str) -> None:
    # Written, it made a pin that every later check read as broken.
    store = _interpreter(tmp_path / "store")
    plant(store / "lib" / "python3.14", name)
    pin = tmp_path / "engine-interpreter.pin"
    assert _run("--write", store, pin) == 2
    assert "the pin cannot spell" in capsys.readouterr().err
    assert not pin.exists()


def test_an_unspellable_directory_is_one_refusal_not_one_per_file(tmp_path: Path, capsys) -> None:
    store, pin, staged = _pinned(tmp_path)
    bad = staged / "lib" / "python3.14" / "caf\u00e9"
    bad.mkdir()
    for n in range(12):
        (bad / f"m{n}.py").write_text("")
    assert _run("--check", staged, store, pin) == 1
    assert "1 names in the copy no pin can spell" in capsys.readouterr().err


@pytest.mark.parametrize("plant", [_unspellable_name, _unspellable_target], ids=["name", "link-target"])
def test_what_the_pin_cannot_spell_is_refused_when_checking(tmp_path: Path, capsys, plant) -> None:
    # No pin names it, so it was added: a refusal, not a check that could not run.
    store, pin, staged = _pinned(tmp_path)
    plant(staged / "lib" / "python3.14", "caf\u00e9.py")
    assert _run("--check", staged, store, pin) == 1
    assert "no pin can spell" in capsys.readouterr().err


def test_a_failed_replace_leaves_the_previous_pin_and_nothing_beside_it(tmp_path: Path, monkeypatch) -> None:
    tool = _tool()
    store = _interpreter(tmp_path / "store")
    pin = tmp_path / "tools" / "engine-interpreter.pin"
    pin.parent.mkdir()
    assert tool.main(["--write", str(store), str(pin)]) == 0
    before = pin.read_bytes()

    def full_disk(src, dst):
        raise OSError(28, "No space left on device")

    monkeypatch.setattr(tool.os, "replace", full_disk)
    assert tool.main(["--write", str(store), str(pin)]) == 2
    assert pin.read_bytes() == before
    assert [p.name for p in pin.parent.iterdir()] == ["engine-interpreter.pin"]


def test_a_failed_write_leaves_the_previous_pin_whole(tmp_path: Path, monkeypatch) -> None:
    # `write_text` truncated the pin before finding a field it could not encode.
    tool = _tool()
    store = _interpreter(tmp_path / "store")
    pin = tmp_path / "engine-interpreter.pin"
    assert tool.main(["--write", str(store), str(pin)]) == 0
    before = pin.read_bytes()
    monkeypatch.setattr(tool, "_python_version", lambda root: "3.14.7\u00e9")
    assert tool.main(["--write", str(store), str(pin)]) == 2
    assert pin.read_bytes() == before


def test_a_pin_checked_out_with_crlf_line_endings_still_reads(tmp_path: Path) -> None:
    store, pin, staged = _pinned(tmp_path)
    pin.write_bytes(pin.read_bytes().replace(b"\n", b"\r\n"))
    assert _run("--check", staged, store, pin) == 0


@pytest.mark.parametrize(
    "stand_in",
    [None, "lib/python3.14/notes.txt", "lib/python3.14/site-packages/x/_sysconfigdata_x.py"],
    ids=["nothing-else", "another-file", "nested-sysconfigdata"],
)
def test_relocation_refuses_unless_sysconfigdata_is_what_it_rewrote(tmp_path: Path, capsys, stand_in) -> None:
    # The file build tools read headers from must be the one rewritten; nothing else stands in for it,
    # a `_sysconfigdata_` deeper in the tree included.
    store, pin, staged = _pinned(tmp_path)
    (staged / SYSCONFIG).write_text("build_time_vars = {}\n")
    if stand_in:
        (staged / stand_in).parent.mkdir(parents=True, exist_ok=True)
        (staged / stand_in).write_text(f"{store}\n")
    assert _run("--relocate", staged, store) == 1
    assert "_sysconfigdata does not name" in capsys.readouterr().err


def test_relocation_refuses_the_store_through_a_symlinked_directory_above_it(tmp_path: Path, capsys) -> None:
    # `/var` for `/private/var`, a symlinked `~/.local`: the path differs, the store's name does not.
    store, pin, staged = _pinned(tmp_path)
    (tmp_path / "alias").symlink_to(tmp_path)
    aliased = tmp_path / "alias" / store.relative_to(tmp_path)
    (staged / SYSCONFIG).write_text(f"build_time_vars = {{'INCLUDEPY': '{aliased}/include'}}\n")
    assert _run("--relocate", staged, store) == 1
    assert "name uv's store or its directory" in capsys.readouterr().err


def test_relocation_does_not_mistake_the_directory_above_uvs_for_the_store(tmp_path: Path) -> None:
    # A broad directory (`~/.local/share`, `/opt`) is named by text that has nothing to do with uv.
    store, pin, staged = _pinned(tmp_path)
    (staged / "lib" / "python3.14" / "notes.txt").write_text(f"{store.parent.parent}/somewhere-else\n")
    assert _run("--relocate", staged, store) == 0


@pytest.mark.parametrize(
    ("uv_dir", "text"),
    [
        (("usr", "local"), "see /usr/local/lib and /usr/local/include, and /usr/lib/../lib64\n"),
        # pip's own `locations/base.py` holds this comment, under a uv directory ending `python/uv`.
        (("python", "uv"), "# e.g. /path/to/python/bin/..\n"),
        # `..data` and `...` continue a name: neither is a climb out of the entry before it.
        (("uv", "python"), "see TMP/uv/python/x/..data, TMP/uv/python/x/..Data and TMP/uv/python/x/...\n"),
    ],
    ids=["usr-local", "python-uv", "dot-dot-names"],
)
def test_relocation_does_not_mistake_a_broad_uv_directory_for_an_interpreter(tmp_path: Path, uv_dir, text) -> None:
    # The stdlib's ordinary mentions of a broad directory mean nothing in uv's directory.
    store = _interpreter(tmp_path.joinpath(*uv_dir) / STORE)
    pin = tmp_path / "engine-interpreter.pin"
    assert _run("--write", store, pin) == 0
    staged = _staged(store, tmp_path / "stage")
    (staged / "lib" / "python3.14" / "notes.txt").write_text(text.replace("TMP", str(tmp_path)))
    assert _run("--relocate", staged, store) == 0


def test_a_climb_at_the_very_end_of_the_text_is_seen() -> None:
    tool = _tool()
    uv_ref = tool._uv_reference(b"/u/uv/python/" + STORE.encode())
    assert tool._in_uv(uv_ref, b"/u/uv/python/zzz/..")
    assert tool._in_uv(uv_ref, b"/u/uv/x/../python/zzz/..")


def test_a_uv_directory_with_a_space_or_quote_in_its_tail_is_a_broken_check() -> None:
    # Per-token stepping could not see such a tail whole once a `seg/..` before it collapsed.
    tool = _tool()
    for parent in (b"/x/my pythons/py store", b"/x/it's/python"):
        with pytest.raises(tool.Broken, match="space or quote"):
            tool._uv_reference(parent + b"/" + STORE.encode())
    # Above those two parts a space is ordinary (`/Volumes/Macintosh HD`), and references are seen.
    uv_ref = tool._uv_reference(b"/x/My Drive/uv/python/" + STORE.encode())
    assert tool._in_uv(uv_ref, b"/x/My Drive/uv/x/../python/cpython-3.13-macos-aarch64-none/../y")


def test_uvs_directory_must_have_two_components_to_be_told_apart() -> None:
    tool = _tool()
    with pytest.raises(tool.Broken, match="too short to be told apart"):
        tool._uv_reference(b"/py/" + STORE.encode())


@pytest.mark.parametrize(
    "where",
    [lambda store, tmp: store.parent / ".temp" / "x", lambda store, tmp: store.parent / "stage" / "x",
     lambda store, tmp: tmp / "other" / "uv" / "python" / "out-1" / "x"],
    ids=["dot-entry", "plain-name", "another-uv-shaped-directory"],
)
def test_a_copy_inside_uvs_directory_or_shaped_like_it_is_a_broken_check(tmp_path: Path, capsys, where) -> None:
    # Every relocated file would name the copy, and so read as naming uv's directory: a tampering
    # that never happened, answered with the wrong remedy.
    store, pin, staged = _pinned(tmp_path)
    inside = _staged(store, where(store, tmp_path))
    assert _run("--relocate", inside, store) == 2
    assert "is inside uv's directory, or looks it" in capsys.readouterr().err


def test_a_non_ascii_capital_above_uvs_directory_does_not_hide_a_copy_inside_it(tmp_path: Path, capsys) -> None:
    store = _interpreter(tmp_path / "\u00dcser" / "uv" / "python" / STORE)
    inside = _staged(store, store.parent / "stage" / "x")
    assert _run("--relocate", inside, store) == 2
    assert "is inside uv's directory" in capsys.readouterr().err


def test_relocate_resolves_the_store_once(tmp_path: Path, monkeypatch) -> None:
    # Names, prefix and uv's directory from one lookup: a store swapped between two could split them.
    tool = _tool()
    store, pin, staged = _pinned(tmp_path)
    real, calls = tool.os.path.realpath, []

    def counting(path):
        if os.fspath(path) == os.fspath(store):
            calls.append(path)
        return real(path)

    monkeypatch.setattr(tool.os.path, "realpath", counting)
    assert tool.main(["--relocate", str(staged), str(store)]) == 0
    assert len(calls) == 1


@pytest.mark.parametrize("fails", ["open", "sync"])
def test_a_directory_that_will_not_sync_does_not_fail_a_write_that_happened(tmp_path: Path, monkeypatch,
                                                                             capsys, fails: str) -> None:
    # The rename is done by then: reporting failure would deny a pin that is in place.
    tool = _tool()
    store = _interpreter(tmp_path / "store")
    pin = tmp_path / "engine-interpreter.pin"
    if fails == "open":
        real_open = tool.os.open

        def refuse_directories(path, flags, *args):
            if os.path.isdir(path):
                raise OSError(22, "Invalid argument")
            return real_open(path, flags, *args)

        monkeypatch.setattr(tool.os, "open", refuse_directories)
    else:
        real_sync = tool._sync

        def refuse_directory_fds(fd):
            if stat.S_ISDIR(os.fstat(fd).st_mode):
                raise OSError(5, "Input/output error")
            real_sync(fd)

        monkeypatch.setattr(tool, "_sync", refuse_directory_fds)
    assert tool.main(["--write", str(store), str(pin)]) == 0
    assert pin.read_text().startswith("# The engine interpreter")
    assert "its directory did not sync" in capsys.readouterr().err


@pytest.mark.skipif(not hasattr(__import__("fcntl"), "F_FULLFSYNC"), reason="no F_FULLFSYNC here")
@pytest.mark.parametrize(
    ("code", "falls_back"),
    [(errno.ENOTSUP, True), (errno.EINVAL, True), (errno.ENOSYS, True), (errno.EIO, False)],
    ids=["ENOTSUP", "EINVAL", "ENOSYS", "EIO"],
)
def test_full_sync_falls_back_only_where_the_filesystem_does_not_take_it(tmp_path: Path, monkeypatch,
                                                                        code: int, falls_back: bool) -> None:
    # After a real failure, `fsync` may succeed on data that never reached the disk.
    tool = _tool()
    synced = []

    def refuse(fd, op, *args):
        raise OSError(code, os.strerror(code))

    monkeypatch.setattr(tool.fcntl, "fcntl", refuse)
    monkeypatch.setattr(tool.os, "fsync", lambda fd: synced.append(fd))
    with open(tmp_path / "f", "wb") as f:
        if falls_back:
            tool._sync(f.fileno())
            assert synced == [f.fileno()]
        else:
            with pytest.raises(OSError):
                tool._sync(f.fileno())
            assert synced == []


def test_a_short_write_still_writes_the_whole_pin(tmp_path: Path, monkeypatch) -> None:
    # `os.write` may write less than it is given; one call would commit a truncated pin.
    tool = _tool()
    store = _interpreter(tmp_path / "store")
    whole = tmp_path / "whole.pin"
    assert tool.main(["--write", str(store), str(whole)]) == 0
    real = tool.os.write
    monkeypatch.setattr(tool.os, "write", lambda fd, data: real(fd, bytes(data[:7])))
    short = tmp_path / "short.pin"
    assert tool.main(["--write", str(store), str(short)]) == 0
    assert short.read_bytes() == whole.read_bytes()


@pytest.mark.parametrize(
    ("before", "after", "rewritten"),
    [
        ("'", "/include'", True), ('"', '"', True), (" ", " ", True), ("\t", "\n", True), ("", "", True),
        ("x", "/include", False), ("-I", "/include", False), ("=", "/include", False),
        (" ", "-x/include", False), (" ", ":x", False), (" ", "~old", False),
        (" ", "/../x", False), (" ", "//x", False), (" ", "/./x", False),
        (" ", "/include/../../x", False), (" ", "/lib/..", False), (" ", "/..data/x", True),
        ("\n", "/include", False), (":", "/include", False), (",", "/include", False), ("-L", "/lib", False),
        (" ", ";x", False), (" ", ",x", False),
    ],
    ids=["quote", "double-quote", "spaces", "tab-newline", "whole-file",
         "after-a-letter", "after-a-flag", "after-equals", "dash-suffix", "colon-suffix", "tilde-suffix",
         "dot-dot", "double-slash", "dot-slash", "deep-dot-dot", "trailing-dot-dot", "dot-dot-named-child",
         "after-newline", "after-colon", "after-comma", "after-L", "semicolon-suffix", "comma-suffix"],
)
def test_the_store_prefix_is_rewritten_only_as_a_whole_path(before: str, after: str, rewritten: bool) -> None:
    # Measured on the real `_sysconfigdata`: a quote, a space or a tab before; `/`, a quote or
    # whitespace after. Anything else is part of some other path and is left to be refused.
    old, new = b"/u/uv/python/" + STORE.encode(), b"/stage/runtime"
    data = before.encode() + old + after.encode()
    expected = before.encode() + new + after.encode() if rewritten else data
    assert _tool()._rewrite(data, old, new) == expected


def test_a_copy_whose_path_holds_the_stores_name_is_a_broken_check(tmp_path: Path, capsys) -> None:
    store = _interpreter(tmp_path / "uv-python" / STORE)
    pin = tmp_path / "engine-interpreter.pin"
    assert _run("--write", store, pin) == 0
    staged = _staged(store, tmp_path / f"{STORE}-builds" / "stage")
    assert _run("--relocate", staged, store) == 2
    assert "has the store's name in its own path" in capsys.readouterr().err


def test_relocation_refuses_the_store_through_its_minor_version_link(tmp_path: Path, capsys) -> None:
    # uv's `cpython-3.14-...` link sits beside the pinned directory and anyone who can write the store
    # can repoint it: rewriting only the pinned spelling would leave this one reading through it.
    store, pin, staged = _pinned(tmp_path)
    (staged / SYSCONFIG).write_text(f"build_time_vars = {{'INCLUDEPY': '{store.parent}/{STORE_LINK}/include'}}\n")
    assert _run("--relocate", staged, store) == 1
    assert "name uv's store or its directory" in capsys.readouterr().err


@pytest.mark.parametrize(
    "spelling",
    [lambda store: str(store).upper(), lambda store: f"{store}-debug"],
    ids=["capitals", "suffixed-directory"],
)
def test_relocation_refuses_a_spelling_it_would_not_rewrite(tmp_path: Path, capsys, spelling) -> None:
    # A case-insensitive volume reads the capitals as the store; `<store>-debug` does not stand as a
    # whole path, and rewriting its front would invent a directory.
    store, pin, staged = _pinned(tmp_path)
    (staged / SYSCONFIG).write_text(f"build_time_vars = {{'INCLUDEPY': '{spelling(store)}/include'}}\n")
    assert _run("--relocate", staged, store) == 1
    assert "name uv's store or its directory" in capsys.readouterr().err


OTHER = "cpython-3.13.14-macos-aarch64-none"


@pytest.mark.parametrize(
    "elsewhere",
    [
        lambda store, tmp: f"{store.parent}/{OTHER}",
        lambda store, tmp: f"{store.parent}/pypy-3.11.13-macos-aarch64-none",
        lambda store, tmp: f"{store.parent}/.temp/x",
        lambda store, tmp: f"{store}/../{OTHER}",
        lambda store, tmp: f"{tmp}/uv//python/{OTHER}",
        lambda store, tmp: f"{tmp}/uv/./python/{OTHER}",
        lambda store, tmp: f"{tmp}/alias/uv/python/{OTHER}",
        lambda store, tmp: f"{tmp}/uv/x/../python/{OTHER}",
        lambda store, tmp: f"{store.parent}/{OTHER}/../../x",
        lambda store, tmp: f"{store.parent}/.temp/../../x",
        # Another interpreter's minor-version link, so the store's own names play no part.
        lambda store, tmp: f"{tmp}/uv/x/../python/cpython-3.13-macos-aarch64-none/../../y",
        # Collapsed all at once, the reveal and the climb out of it vanish in the same pass.
        lambda store, tmp: f"{tmp}/uv/x/../python/cpython-3.13-macos-aarch64-none/../y",
        lambda store, tmp: f"{tmp}/uv/x/y/w/../../../python/cpython-3.13-macos-aarch64-none/../../z",
        lambda store, tmp: f"{tmp}/uv/x/../python/.temp/../y",
        # Any entry a climb leaves through, whatever its name: it may be a planted symlink.
        lambda store, tmp: f"{store.parent}/zzz/../y",
        # A `..` followed by anything outside `[a-z0-9._~@+-]` is a climb, even where a name could go on.
        lambda store, tmp: f"'{store.parent}/zzz/..'",
        lambda store, tmp: f"$({store.parent}/zzz/..)",
        lambda store, tmp: f"`{store.parent}/zzz/..`",
        lambda store, tmp: f"[{store.parent}/zzz/..]",
        lambda store, tmp: f"{store.parent}/zzz/..|x",
        lambda store, tmp: f"{store.parent}/zzz/..",
        # Stepped across tokens: decoys that collapse to nothing, then the reference.
        lambda store, tmp: f"a/b/../c 'q/r/../s' x\n{tmp}/uv/x/../python/cpython-3.13-macos-aarch64-none/../y",
    ],
    ids=["other-cpython", "pypy", "uv-temp", "dot-dot-from-the-store", "double-slash", "dot-slash", "symlinked-parent",
         "dot-dot-inside-the-tail", "through-a-link-and-out", "through-temp-and-out", "detour-then-link-and-out",
         "detour-then-link-and-one-out", "deep-detour", "detour-then-temp-and-out", "any-entry-and-out",
         "climb-then-quote", "climb-then-paren", "climb-then-backtick", "climb-then-bracket", "climb-then-pipe",
         "climb-then-newline", "after-decoy-tokens"],
)
def test_relocation_refuses_what_uv_keeps_or_a_climb_in_its_directory(tmp_path: Path, capsys, elsewhere) -> None:
    store, pin, staged = _pinned(tmp_path)
    (tmp_path / "alias").symlink_to(tmp_path)
    (staged / "lib" / "python3.14" / "notes.txt").write_text(f"{elsewhere(store, tmp_path)}\n")
    assert _run("--relocate", staged, store) == 1
    assert "name uv's store or its directory" in capsys.readouterr().err


def test_relocation_leaves_a_store_prefix_inside_another_path_and_refuses_it(tmp_path: Path, capsys) -> None:
    # `/tmp/evil<store>` is not the store: rewriting it would point at a directory nobody checked.
    store, pin, staged = _pinned(tmp_path)
    (staged / SYSCONFIG).write_text(_sysconfig(store) + f"EVIL = '/tmp/evil{store}/include'\n")
    assert _run("--relocate", staged, store) == 1
    assert "name uv's store or its directory" in capsys.readouterr().err


def test_relocation_refuses_a_sysconfigdata_it_did_not_rewrite_beside_one_it_did(tmp_path: Path, capsys) -> None:
    store, pin, staged = _pinned(tmp_path)
    (staged / "lib" / "python3.14t").mkdir()
    (staged / "lib" / "python3.14t" / "_sysconfigdata_t_darwin_darwin.py").write_text("build_time_vars = {}\n")
    assert _run("--relocate", staged, store) == 1
    assert "lib/python3.14t/_sysconfigdata_t_darwin_darwin.py" in capsys.readouterr().err


def _pinned_prefix() -> Path:
    return Path(_tool().parse(PIN.read_text())[0])


@pytest.mark.skipif(not _pinned_prefix().is_dir(), reason="the pinned interpreter is not installed here")
def test_the_real_store_passes_every_step_the_build_runs(tmp_path: Path) -> None:
    # On uv's own output, not a fixture: what the build does between its copy and signing.
    prefix = _pinned_prefix()
    staged = tmp_path / "stage" / "runtime"
    shutil.copytree(prefix, staged, symlinks=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    assert _run("--check", staged, prefix, PIN) == 0
    assert _run("--relocate", staged, prefix) == 0
    text = (staged / SYSCONFIG).read_text()
    assert str(prefix) not in text and "uv/python/" not in text
    assert _run("--recheck", staged, prefix, PIN) == 0


def test_the_store_names_are_its_directory_and_uvs_minor_version_link() -> None:
    tool = _tool()
    assert tool._store_names(f"/x/{STORE}") == (STORE_LINK.encode(), STORE.encode())
    assert tool._store_names("/x/cpython-3.14.7+freethreaded-macos-aarch64-none") == (
        b"cpython-3.14+freethreaded-macos-aarch64-none", b"cpython-3.14.7+freethreaded-macos-aarch64-none")
    assert tool._store_names("/x/cpython-3.15.0a1-macos-aarch64-none") == (
        b"cpython-3.15-macos-aarch64-none", b"cpython-3.15.0a1-macos-aarch64-none")


@pytest.mark.parametrize("name", ["pypy-3.11.13-macos-aarch64-none", "cpython-3.14.7", "python"])
def test_a_store_name_uv_does_not_write_is_a_broken_check(tmp_path: Path, capsys, name: str) -> None:
    # Its link could not be named, so a spelling through it could not be seen.
    store = _interpreter(tmp_path / "uv-python" / name)
    staged = _staged(store, tmp_path / "stage")
    assert _run("--relocate", staged, store) == 2
    assert "is not the name uv gives a CPython install" in capsys.readouterr().err


@pytest.mark.parametrize(
    ("rel", "matches"),
    [
        ("lib/python3.14/_sysconfigdata__darwin_darwin.py", True),
        ("lib/python3.14t/_sysconfigdata_t_darwin_darwin.py", True),
        ("lib/python3.14/site-packages/x/_sysconfigdata_x.py", False),
    ],
    ids=["default", "free-threaded", "nested"],
)
def test_the_sysconfigdata_that_counts_is_the_stdlibs_own(rel: str, matches: bool) -> None:
    assert bool(_tool().SYSCONFIG.fullmatch(rel)) is matches


def _clean_copy(script: str) -> str:
    return "clean_copy() {" + script.split("clean_copy() {", 1)[1].split("\n}\n", 1)[0] + "\n}\n"


def test_clean_copy_deletes_bytecode_in_every_shape_and_nothing_it_points_at(tmp_path: Path) -> None:
    # Run as the build defines it. A symlink named `__pycache__` survived `find -type d`.
    runtime = tmp_path / "stage" / "runtime"
    lib = runtime / "lib" / "python3.14"
    (lib / "__pycache__").mkdir(parents=True)
    (lib / "__pycache__" / "os.cpython-314.opt-1.pyc").write_bytes(b"x")
    (lib / "sourceless.pyc").write_bytes(b"x")
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "keep.pyc").write_bytes(b"x")
    (lib / "encodings").mkdir()
    (lib / "encodings" / "__pycache__").symlink_to(outside)
    (lib / "email").mkdir()
    (lib / "email" / "__pycache__").write_bytes(b"a file, not a directory")
    (lib / "os.py").write_text("")

    script = 'die() { echo "$*" >&2; exit 9; }\n' + _clean_copy(BUILD.read_text()) + "clean_copy\n"
    done = subprocess.run(["bash", "-c", script], env={**os.environ, "STAGE": str(tmp_path / "stage")},
                          capture_output=True, text=True)

    assert done.returncode == 0, done.stderr
    left = sorted(p.relative_to(runtime).as_posix() for p in runtime.rglob("*"))
    assert left == ["lib", "lib/python3.14", "lib/python3.14/email", "lib/python3.14/encodings",
                    "lib/python3.14/os.py"]
    assert (outside / "keep.pyc").exists(), "the clean followed a symlink out of the copy"


# ------------------------------------------------------------------ the real pin and the real checker host


@pytest.mark.skipif(not SYSTEM_PYTHON.exists(), reason="no /usr/bin/python3")
def test_the_checker_runs_on_the_python_the_build_gives_it(tmp_path: Path) -> None:
    # The build runs it as `/usr/bin/python3 -I`, which is 3.9 on macOS: nothing newer may be used.
    store, pin, staged = _pinned(tmp_path)

    def run(*argv: object) -> subprocess.CompletedProcess[str]:
        return subprocess.run([str(SYSTEM_PYTHON), "-I", str(TOOL), *map(str, argv)], capture_output=True, text=True)

    assert run("--check", staged, store, pin).returncode == 0
    assert run("--relocate", staged, store).returncode == 0
    assert run("--recheck", staged, store, pin).returncode == 0
    (staged / "lib/python3.14/os.py").write_text("import evil\n")
    assert run("--recheck", staged, store, pin).returncode == 1


@pytest.mark.skipif(not _pinned_prefix().is_dir(), reason="the pinned interpreter is not installed here")
def test_the_checked_in_pin_matches_the_installed_interpreter() -> None:
    tool = _tool()
    prefix, pinned = tool.parse(PIN.read_text())
    assert tool.scan(Path(prefix), checking=False) == pinned


# ------------------------------------------------------------------ the build, in a copy of the repo


def _repo(tmp_path: Path, store: Path) -> Path:
    """The parts of the repo the build reads before its first `uv venv`, with a pin for `store`."""
    repo = tmp_path / "repo"
    repo.mkdir()
    for name in ("pyproject.toml", "uv.lock"):
        shutil.copy2(ROOT / name, repo / name)
    for name in ("tools", "substrate", "third_party_licenses"):
        shutil.copytree(ROOT / name, repo / name, symlinks=True, ignore=shutil.ignore_patterns("__pycache__", "*.pyc"))
    assert _tool().main(["--write", str(store), str(repo / "tools" / "engine-interpreter.pin")]) == 0
    return repo


def _fake_uv(bin_dir: Path, body: str) -> None:
    bin_dir.mkdir()
    uv = bin_dir / "uv"
    uv.write_text(f"#!/usr/bin/env bash\n{body}\n")
    uv.chmod(uv.stat().st_mode | stat.S_IXUSR)


def _build(build: Path, dest: Path, bin_dir: Path) -> subprocess.CompletedProcess[str]:
    env = {k: v for k, v in os.environ.items() if k != "VIRTUAL_ENV"}
    env["PATH"] = f"{bin_dir}{os.pathsep}{env['PATH']}"
    return subprocess.run([str(build), str(dest)], cwd=build.parent, env=env, capture_output=True, text=True,
                          timeout=300)


def _setup(tmp_path: Path) -> tuple[Path, Path, Path]:
    """`(store, repo, out)`: a pinned interpreter under a fake `uv python dir`, and a fake uv that
    answers `find` and `dir` and, at the first thing that would RUN the copy, records what it was
    handed and stops the build."""
    managed = tmp_path / "uv-python"
    store = _interpreter(managed / "cpython-3.14.7-macos-aarch64-none")
    repo = _repo(tmp_path, store)
    seen = tmp_path / "seen"
    seen.mkdir()
    _fake_uv(
        tmp_path / "fakebin",
        f'[ "$1 $2" = "python find" ] && {{ echo "{store / "bin" / "python3.14"}"; exit 0; }}\n'
        f'[ "$1 $2" = "python dir" ] && {{ echo "{managed}"; exit 0; }}\n'
        f'echo "$@" >"{seen}/calls"\n'
        f'cp runtime/{SYSCONFIG} "{seen}/sysconfig" 2>/dev/null\n'
        f'grep -rlF "{store}" runtime >"{seen}/names-store"\n'
        f'find runtime -name "*.pyc" >"{seen}/bytecode"\n'
        f'pwd -P >"{seen}/stage"\n'
        "exit 3",
    )
    return store, repo, tmp_path / "out" / "substrate-engine"


def test_the_build_refuses_a_store_that_no_longer_matches_its_pin(tmp_path: Path) -> None:
    store, repo, dest = _setup(tmp_path)
    (store / "lib/python3.14/os.py").write_text("import evil\n")

    result = _build(repo / "tools" / "build-bundled-engine", dest, tmp_path / "fakebin")

    assert result.returncode != 0
    assert "was refused against tools/engine-interpreter.pin — not signing it" in result.stderr, result.stderr
    assert "changed: lib/python3.14/os.py" in result.stderr
    assert not (tmp_path / "seen" / "calls").exists(), "uv ran the unchecked interpreter"
    assert not dest.with_name("substrate-engine.staging").exists(), "the stage was left behind"


def test_the_build_hands_uv_a_checked_copy_that_points_at_itself(tmp_path: Path) -> None:
    store, repo, dest = _setup(tmp_path)

    result = _build(repo / "tools" / "build-bundled-engine", dest, tmp_path / "fakebin")

    seen = tmp_path / "seen"
    assert "checking the interpreter against tools/engine-interpreter.pin" in result.stdout, result.stderr
    assert (seen / "calls").read_text().startswith("venv .venv"), result.stderr
    # The store held bytecode; the copy uv runs holds none.
    assert (seen / "bytecode").read_text() == ""
    # Build tools reading sysconfig find the copy's headers, not the store's.
    stage = (seen / "stage").read_text().strip()
    assert (seen / "sysconfig").read_text() == _sysconfig(f"{stage}/runtime")
    assert (seen / "names-store").read_text().split() == ["runtime/lib/libpython3.14.dylib"]


def test_the_build_refuses_an_interpreter_the_pin_does_not_describe(tmp_path: Path) -> None:
    # The repo's own pin, and an interpreter at a path it was not made for.
    managed = tmp_path / "uv-python"
    store = _interpreter(managed / "cpython-3.14.7-macos-aarch64-none")
    calls = tmp_path / "calls"
    _fake_uv(
        tmp_path / "fakebin",
        f'[ "$1 $2" = "python find" ] && {{ echo "{store / "bin" / "python3.14"}"; exit 0; }}\n'
        f'[ "$1 $2" = "python dir" ] && {{ echo "{managed}"; exit 0; }}\n'
        f'echo "$@" >>"{calls}"\nexit 3',
    )

    result = _build(BUILD, tmp_path / "out" / "substrate-engine", tmp_path / "fakebin")

    assert result.returncode != 0
    assert "was made for" in result.stderr, result.stderr
    assert not calls.exists(), f"uv ran the unchecked interpreter: {calls.read_text()}"


# ------------------------------------------------------------------ where the steps sit


def test_the_checks_sit_between_the_copy_and_the_first_run() -> None:
    script = BUILD.read_text()
    order = [
        'cp -Rp "$PY_ROOT/" "$STAGE/runtime/"',
        'clean_copy\npin_tool --check "$STAGE/runtime" "$PY_ROOT" "$PIN"',
        'pin_tool --relocate "$STAGE/runtime" "$PY_ROOT"',
        '"$UV" venv .venv --relocatable --python ./runtime/bin/python3.14',
    ]
    positions = [script.index(step) for step in order]
    assert positions == sorted(positions)


def test_the_recheck_follows_everything_that_runs_the_copy_and_the_compile_follows_it() -> None:
    script = BUILD.read_text()
    order = [
        '"$REPO/tools/slim-bundled-engine" "$STAGE" || die',
        '"$STAGE/.venv/bin/python" -B -E -s -c "import numpy, scipy, pandas, torch, torchvision',
        '"$STAGE/.venv/bin/python" -m compileall -q "$STAGE/substrate"',
        'clean_copy\npin_tool --recheck "$STAGE/runtime" "$PY_ROOT" "$PIN"',
        '"$STAGE/runtime/bin/python3.14" -I -S -m compileall -q -j0 "$STAGE/runtime/lib/python3.14"',
        "# ------------------------------------------------------------------ sign",
    ]
    positions = [script.index(step) for step in order]
    assert positions == sorted(positions)


def test_the_checker_host_is_probed_by_running_it() -> None:
    # Without the command line tools `/usr/bin/python3` is an executable stub that fails: `-x` passes
    # it, and its exit 1 would read as a refusal.
    script = BUILD.read_text()
    assert "/usr/bin/python3 -I -c 'import sys; sys.exit(sys.version_info < (3, 9))'" in script
    assert "[ -x /usr/bin/python3 ]" not in script
    tool = script.split("pin_tool() {", 1)[1].split("\n}\n", 1)[0]
    assert '/usr/bin/python3 -I "$REPO/tools/engine-interpreter-pin.py" "$@" || status=$?' in tool
    assert "1) die \"the interpreter's copy was refused against tools/engine-interpreter.pin" in tool
    assert '*) die "the interpreter pin check could not run (exit $status)' in tool


def test_the_fingerprint_covers_the_pin_and_its_checker() -> None:
    # A re-pin must rebuild, or a stamped tree keeps the interpreter the previous pin described.
    fingerprint = BUILD.read_text().split("fingerprint() {", 1)[1].split("\n}\n", 1)[0]
    assert '"$REPO/tools/engine-interpreter.pin"' in fingerprint
    assert '"$REPO/tools/engine-interpreter-pin.py"' in fingerprint


# ------------------------------------------------------------------ where a refusal points


def test_every_refusal_and_the_pin_point_at_the_engines_own_runbook(tmp_path: Path, capsys) -> None:
    """The engine is its own repository, so what to do about a refusal is in its own `RELEASING.md`,
    never in a file of the app that bundles it, and that runbook holds the re-pin it points at."""
    store, pin, staged = _pinned(tmp_path)
    assert _run("--check", staged, tmp_path / "elsewhere", pin) == 1
    (staged / "lib/python3.14/os.py").write_text("import evil\n")
    assert _run("--check", staged, store, pin) == 1
    err = capsys.readouterr().err
    assert err.count("the engine's RELEASING.md") == 2, err
    assert "Distribution/" not in err
    assert "the engine's RELEASING.md" in pin.read_text() and "Distribution/" not in pin.read_text()
    runbook = (ROOT / "RELEASING.md").read_text()
    assert "tools/engine-interpreter-pin.py --write" in runbook
    assert "tools/engine-interpreter.pin" in runbook
    assert "substrate/tools/" not in runbook


def test_the_committed_pins_header_is_the_one_write_renders(tmp_path: Path) -> None:
    """The header's first two lines are fixed text, so the committed pin carries `render`'s."""
    _, pin, _ = _pinned(tmp_path)
    assert PIN.read_text().splitlines()[:2] == pin.read_text().splitlines()[:2]
