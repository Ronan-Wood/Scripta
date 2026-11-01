"""What the bundled engine may not carry, and the guard that keeps Sparkle's delta updates possible.

0.3.0 and 0.3.2 shipped 142 `.dSYM` bundles whose DWARF files the signing pass signed, and codesign
stored those signatures as `com.apple.cs.*` extended attributes. Sparkle refuses to diff any tree
that has one, so no delta could be built and every update was the full dmg. These run
`tools/slim-bundled-engine` against a synthetic engine tree; no engine, no network.
"""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
SLIM = ROOT / "tools" / "slim-bundled-engine"
BUILD = ROOT / "tools" / "build-bundled-engine"

SP = ".venv/lib/python3.14/site-packages"
STDLIB = "runtime/lib/python3.14"

REMOVED = [
    f"{SP}/PyObjCTest/NULL.cpython-314-darwin.so.dSYM/Contents/Resources/DWARF/NULL.cpython-314-darwin.so",
    f"{SP}/objc/_objc.cpython-314-darwin.so.dSYM/Contents/Resources/DWARF/_objc.cpython-314-darwin.so",
    f"{SP}/torch/include/ATen/ATen.h",
    "runtime/include/python3.14/Python.h",
    "runtime/lib/libtcl9.0.dylib",
    "runtime/lib/libtcl9tk9.0.dylib",
    "runtime/lib/tcl9.0/init.tcl",
    "runtime/lib/tk9.0/tk.tcl",
    "runtime/lib/itcl4.3.8/itcl.tcl",
    "runtime/lib/thread3.0.6/pkgIndex.tcl",
    f"{STDLIB}/tkinter/__init__.py",
    f"{STDLIB}/idlelib/idle.py",
    f"{STDLIB}/turtledemo/__main__.py",
    f"{STDLIB}/ensurepip/__init__.py",
    f"{STDLIB}/lib-dynload/_tkinter.cpython-314-darwin.so",
    f"{STDLIB}/site-packages/pip/__init__.py",
    f"{STDLIB}/site-packages/pip-25.2.dist-info/METADATA",
    "runtime/bin/pip3.14",
    "runtime/bin/idle3.14",
]

# What the engine runs, and the two classes kept on purpose (bytecode, imported `testing` packages).
KEPT = [
    f"{SP}/objc/_objc.cpython-314-darwin.so",
    f"{SP}/objc/__pycache__/__init__.cpython-314.pyc",
    f"{SP}/torch/__init__.py",
    f"{SP}/torch/lib/libtorch_cpu.dylib",
    f"{SP}/numpy/testing/__init__.py",
    f"{SP}/pyobjc_core-12.2.2.dist-info/include/pyobjc-api.h",
    "runtime/bin/python3.14",
    "runtime/lib/libpython3.14.dylib",
    f"{STDLIB}/os.py",
    f"{STDLIB}/unittest/__init__.py",
    f"{STDLIB}/lib-dynload/_json.cpython-314-darwin.so",
    f"{STDLIB}/site-packages/README.txt",
]


def _engine(tmp_path: Path) -> Path:
    root = tmp_path / "substrate-engine"
    for rel in REMOVED + KEPT:
        path = root / rel
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text("x")
    return root


def _run(*args: str) -> subprocess.CompletedProcess[str]:
    return subprocess.run([str(SLIM), *args], capture_output=True, text=True)


def test_removes_what_the_engine_never_runs_and_keeps_what_it_does(tmp_path: Path) -> None:
    root = _engine(tmp_path)
    result = _run(str(root))
    assert result.returncode == 0, result.stderr
    still_there = [rel for rel in REMOVED if (root / rel).exists()]
    assert not still_there, f"not removed: {still_there}"
    assert not list(root.rglob("*.dSYM")), "a .dSYM bundle survived"
    missing = [rel for rel in KEPT if not (root / rel).exists()]
    assert not missing, f"removed something the engine needs: {missing}"


def test_refuses_a_directory_that_is_not_an_engine(tmp_path: Path) -> None:
    (tmp_path / "x.dSYM").mkdir()
    result = _run(str(tmp_path))
    assert result.returncode != 0
    assert (tmp_path / "x.dSYM").exists(), "deleted from a tree it should have refused"


darwin_only = pytest.mark.skipif(sys.platform != "darwin", reason="BSD find -xattrname and xattr(1)")


@darwin_only
def test_check_refuses_an_unslimmed_tree_and_names_what_is_left(tmp_path: Path) -> None:
    root = _engine(tmp_path)
    result = _run("--check", str(root))
    assert result.returncode != 0
    assert "PyObjCTest" in result.stderr and "torch/include" in result.stderr


@darwin_only
def test_check_passes_a_slimmed_tree(tmp_path: Path) -> None:
    root = _engine(tmp_path)
    assert _run(str(root)).returncode == 0
    result = _run("--check", str(root))
    assert result.returncode == 0, result.stderr


@darwin_only
@pytest.mark.parametrize(
    "attribute",
    ["com.apple.cs.CodeDirectory", "com.apple.cs.CodeRequirements", "com.apple.cs.CodeSignature"],
)
def test_check_refuses_a_code_signature_in_extended_attributes(tmp_path: Path, attribute: str) -> None:
    """The exact failure that blocked 0.3.2's delta: a signature stored in xattrs, on a file that is
    not one of the removed classes, so only the xattr scan can catch it."""
    root = _engine(tmp_path)
    assert _run(str(root)).returncode == 0
    victim = root / KEPT[0]
    subprocess.run(["xattr", "-w", attribute, "x", str(victim)], check=True)
    result = _run("--check", str(root))
    assert result.returncode != 0
    assert str(victim) in result.stderr


@darwin_only
def test_check_ignores_other_extended_attributes(tmp_path: Path) -> None:
    """`com.apple.provenance` is on every file the OS has seen written and cannot be removed;
    Sparkle does not read it, so refusing it would refuse every build."""
    root = _engine(tmp_path)
    assert _run(str(root)).returncode == 0
    subprocess.run(["xattr", "-w", "com.example.unrelated", "x", str(root / KEPT[0])], check=True)
    assert _run("--check", str(root)).returncode == 0


def test_build_slims_before_the_import_check_and_checks_after_signing() -> None:
    """Order is the property. Slimming after the import check would ship an unverified tree;
    checking before signing would miss the xattrs signing writes."""
    text = BUILD.read_text("utf-8")
    slim = text.index('"$REPO/tools/slim-bundled-engine" "$STAGE"')
    imports = text.index("imports OK after prune")
    signing = text.index('say "signing Mach-O binaries')
    check = text.index('"$REPO/tools/slim-bundled-engine" --check "$STAGE"')
    swap = text.index('assert_whole "$STAGE" "the staged engine"')
    assert slim < imports < signing < check < swap


def test_the_release_checks_the_shipped_app_for_signature_xattrs_before_the_dmg() -> None:
    """The engine phase checks only its own stage. Xcode, Sparkle's helper phase, stapling and the
    copy into the dmg stage all run later, so the release must check the app it actually packs."""
    text = (ROOT.parent / "Distribution" / "build-and-notarize").read_text("utf-8")
    copy = text.index('cp -R "$APP" dist/stage/')
    check = text.index("find dist/stage/Scripta.app -xattrname com.apple.cs.CodeDirectory")
    create = text.index("hdiutil create")
    assert copy < check < create
    scan = text[check : text.index("\n", text.index("com.apple.cs.CodeSignature", check))]
    for attribute in ("CodeDirectory", "CodeRequirements", "CodeSignature"):
        assert f"com.apple.cs.{attribute}" in scan


def test_the_fingerprint_covers_the_slimming_recipe() -> None:
    """A recipe change must rebuild, or a stamped tree from the old recipe keeps shipping."""
    fingerprint = BUILD.read_text("utf-8").split("fingerprint() {", 1)[1].split("\n}\n", 1)[0]
    assert '"$REPO/tools/slim-bundled-engine"' in fingerprint
