"""`engine-manifest.json`: what an engine root states about itself (`tools/engine-manifest.py`).

Scripta reads it to decide what to run, instead of looking for this tree's files. So what it states
has to be what this tree is: its version, its wire, and features each of which runs here.
"""

from __future__ import annotations

import importlib.util
import json
import stat
import subprocess
import sys
import tomllib
from pathlib import Path

import pytest

from substrate import wire

ROOT = Path(__file__).resolve().parent.parent
TOOL = ROOT / "tools" / "engine-manifest.py"
BUILD = ROOT / "tools" / "build-bundled-engine"


def _tool():
    spec = importlib.util.spec_from_file_location("_engine_manifest", TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tool = _tool()


def _tree(tmp_path: Path, pyproject: str, wire_py: str = "VERSION = 3\n") -> Path:
    (tmp_path / "substrate").mkdir()
    (tmp_path / "pyproject.toml").write_text(pyproject, encoding="utf-8")
    (tmp_path / "substrate" / "wire.py").write_text(wire_py, encoding="utf-8")
    return tmp_path


def _help(*module: str) -> str:
    r = subprocess.run([sys.executable, "-m", *module, "--help"], cwd=ROOT, capture_output=True,
                       text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    return r.stdout


# ---------------------------------------------------------------- what it states about this tree


def test_this_tree_states_its_own_version_and_wire():
    """Read the plain way the writer can on Python 3.9, and equal to what a real reader gets."""
    with (ROOT / "pyproject.toml").open("rb") as fh:
        version = tomllib.load(fh)["project"]["version"]
    assert tool.manifest(ROOT, None) == {"version": version, "commit": None, "wire": wire.VERSION,
                                         "features": ["serve", "refresh", "connect-unix"]}


def test_every_feature_it_states_runs_here():
    """A stated feature is a promise a client acts on without checking, so each is held to the
    entry point that keeps it."""
    assert set(tool.FEATURES) == {"serve", "refresh", "connect-unix"}
    server = _help("substrate.mcp.server")
    serve = _help("substrate.cli", "serve")
    assert "--socket" in server, "serve: `substrate-mcp --socket` answers on the socket"
    assert "--socket" in serve and "--every" in serve, "refresh: `substrate serve` keeps it current"
    assert "--connect" in server, "connect-unix: `substrate-mcp --connect` reaches the socket"


# ---------------------------------------------------------------- writing it


def test_it_writes_a_whole_readable_file_and_nothing_beside_it(tmp_path):
    root = _tree(tmp_path, '[project]\nname = "x"\nversion = "1.2.3"  # the release\n')
    sha = "a" * 40
    assert tool.main([str(root), "--commit", sha]) == 0
    written = root / "engine-manifest.json"
    assert json.loads(written.read_text("utf-8")) == {
        "version": "1.2.3", "commit": sha, "wire": 3,
        "features": ["serve", "refresh", "connect-unix"]}
    assert stat.S_IMODE(written.stat().st_mode) == 0o644
    assert sorted(p.name for p in root.iterdir()) == ["engine-manifest.json", "pyproject.toml",
                                                     "substrate"]


def test_an_empty_commit_is_stated_as_none(tmp_path):
    """The bundle build passes "" for a tree that is no commit's."""
    root = _tree(tmp_path, '[project]\nversion = "1"\n')
    assert tool.main([str(root), "--commit", ""]) == 0
    assert json.loads((root / "engine-manifest.json").read_text("utf-8"))["commit"] is None


@pytest.mark.parametrize("commit", ["abc123", "A" * 40, "a" * 41, "-" + "a" * 39, "a" * 40 + "\n"])
def test_a_commit_that_is_not_a_full_id_is_refused(tmp_path, commit):
    root = _tree(tmp_path, '[project]\nversion = "1"\n')
    assert tool.main([str(root), "--commit", commit]) == 1
    assert not (root / "engine-manifest.json").exists()


@pytest.mark.parametrize("pyproject", [
    '[project]\nname = "x"\n',                                    # no version
    '[project]\ndynamic = ["version"]\n',                         # not written down
    '[project]\nversion = "1"\nversion = "2"\n',                  # two
    "[project]\nversion = '1'\n",                                 # not the plain form
    '[tool.x]\nversion = "1"\n',                                  # another table's
])
def test_a_version_it_cannot_read_plainly_is_refused(tmp_path, pyproject):
    root = _tree(tmp_path, pyproject)
    assert tool.main([str(root)]) == 1
    assert not (root / "engine-manifest.json").exists()


@pytest.mark.parametrize("wire_py", ["", "VERSION = 0\n", "VERSION: int = 1\n",
                                     "VERSION = 1\nVERSION = 2\n", "    VERSION = 1\n"])
def test_a_wire_version_it_cannot_read_plainly_is_refused(tmp_path, wire_py):
    root = _tree(tmp_path, '[project]\nversion = "1"\n', wire_py)
    assert tool.main([str(root)]) == 1
    assert not (root / "engine-manifest.json").exists()


# ---------------------------------------------------------------- the bundle build writes it


def test_the_bundle_build_writes_it_after_signing_and_before_the_tree_is_checked_and_swapped():
    """After signing, because signing is the last step that rewrites the tree. Before the xattr
    check and the swap, so the file is checked with the rest and the swapped tree has it."""
    text = BUILD.read_text("utf-8")
    signing = text.index('say "signed and verified $count binaries"')
    write = text.index('/usr/bin/python3 -I "$REPO/tools/engine-manifest.py" "$STAGE"')
    check = text.index('"$REPO/tools/slim-bundled-engine" --check "$STAGE"')
    swap = text.index('mv "$STAGE" "$DEST"')
    assert signing < write < check < swap


def _clean_head(repo: Path) -> str:
    """The build's own `clean_head`, lifted out of the script and run against `repo`."""
    text = BUILD.read_text("utf-8")
    function = "clean_head() {" + text.split("\nclean_head() {", 1)[1].split("\n}\n", 1)[0] + "\n}"
    r = subprocess.run(["bash", "-c", f'set -euo pipefail; REPO="$1"; {function}; clean_head',
                        "clean_head", str(repo)], capture_output=True, text=True, timeout=60)
    assert r.returncode == 0, r.stderr
    return r.stdout.strip()


def _git(repo: Path, *args: str) -> str:
    return subprocess.run(["git", "-C", str(repo), "-c", "commit.gpgsign=false", *args],
                          capture_output=True, text=True, check=True).stdout.strip()


@pytest.fixture
def project(tmp_path):
    """A committed project with the bundle's shape: a package beside `pyproject.toml`, and a
    `.gitignore` like this one's."""
    (tmp_path / "substrate").mkdir()
    (tmp_path / "substrate" / "cli.py").write_text("x = 1\n", encoding="utf-8")
    (tmp_path / "pyproject.toml").write_text('[project]\nversion = "1"\n', encoding="utf-8")
    (tmp_path / ".gitignore").write_text("__pycache__/\n*.pyc\nbin/\n", encoding="utf-8")
    _git(tmp_path, "init", "-q")
    _git(tmp_path, "add", "-A")
    _git(tmp_path, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "t")
    return tmp_path


def test_a_clean_tree_is_stated_as_its_commit(project):
    assert _clean_head(project) == _git(project, "rev-parse", "HEAD")


def test_bytecode_is_not_a_difference_because_the_copy_leaves_it_out(project):
    (project / "substrate" / "__pycache__").mkdir()
    (project / "substrate" / "__pycache__" / "cli.cpython-314.pyc").write_bytes(b"\0")
    (project / "substrate" / "stray.pyc").write_bytes(b"\0")
    assert _clean_head(project) == _git(project, "rev-parse", "HEAD")


@pytest.mark.parametrize("edit", ["modified", "untracked", "ignored in the package"])
def test_a_tree_that_is_not_its_commit_is_stated_as_none(project, edit):
    """An IGNORED file inside the package ships too (the copy takes the whole package), and
    `git status` alone never lists it."""
    if edit == "modified":
        (project / "substrate" / "cli.py").write_text("x = 2\n", encoding="utf-8")
    elif edit == "untracked":
        (project / "substrate" / "new.py").write_text("", encoding="utf-8")
    else:
        (project / "substrate" / "bin").mkdir()
        (project / "substrate" / "bin" / "helper.py").write_text("", encoding="utf-8")
        assert _git(project, "status", "--porcelain") == "", "the case would be vacuous"
    assert _clean_head(project) == ""


def test_a_tree_outside_git_is_stated_as_none(tmp_path):
    (tmp_path / "substrate").mkdir()
    assert _clean_head(tmp_path) == ""


def test_the_bundle_states_a_commit_only_if_the_tree_was_it_when_copied_and_after():
    """Asked twice, around a build long enough to commit or check out during."""
    text = BUILD.read_text("utf-8")
    copied = text.index("COPIED_FROM=$(clean_head)")
    copy = text.index('rsync -a --exclude \'__pycache__\' --exclude \'*.pyc\' "$REPO/substrate/"')
    again = text.index("commit=$(clean_head)")
    assert copied < copy < again
    assert '[ "$commit" = "$COPIED_FROM" ] || commit=' in text[again:]


def test_the_bundle_fingerprint_covers_the_writer():
    """A changed writer changes the output, so it must rebuild."""
    fingerprint = BUILD.read_text("utf-8").split("fingerprint() {", 1)[1].split("\n}\n", 1)[0]
    assert '"$REPO/tools/engine-manifest.py"' in fingerprint
