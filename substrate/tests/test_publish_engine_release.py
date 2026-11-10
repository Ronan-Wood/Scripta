"""`tools/publish-engine-release`, run for real in a throwaway engine repository.

`gh` is a stub that answers the two `gh api` reads from a JSON file the test writes and records
`gh release create`, so nothing leaves the machine. The tool refuses before it writes anything
unless the tag is GitHub's, signed and verified, and the version is the one `pyproject.toml` holds;
then the tarball must be the tagged commit byte for byte.
"""

from __future__ import annotations

import hashlib
import json
import os
import shutil
import subprocess
import sys
import tarfile
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "publish-engine-release"
REPO = "Ronan-Wood/substrate"

GH = """#!/usr/bin/env python3
import json, os, sys
answers = json.load(open(os.environ["GH_ANSWERS"]))
if sys.argv[1:2] == ["api"]:
    answer = answers.get(sys.argv[2])
    if answer is None:
        print("HTTP 404: Not Found", file=sys.stderr)
        sys.exit(1)
    print(answer if isinstance(answer, str) else json.dumps(answer))
    sys.exit(0)
with open(os.environ["GH_CALLS"], "a") as calls:
    calls.write(json.dumps(sys.argv[1:]) + "\\n")
# A tag moved on GitHub while the release was made: what the next read of it returns.
moved = answers.get("moved after release")
if moved:
    answers.update(moved)
    json.dump(answers, open(os.environ["GH_ANSWERS"], "w"))
"""


INHERITED = ("GIT_DIR", "GIT_WORK_TREE", "GIT_INDEX_FILE", "GIT_OBJECT_DIRECTORY",
             "GIT_ALTERNATE_OBJECT_DIRECTORIES", "GIT_COMMON_DIR")


def _git(repo: Path, *args: str, home: Path | None = None) -> str:
    # No global, system or XDG config or ignore file, and no repository inherited from a hook: the
    # fixture is the same on every machine, and git acts on `repo` alone.
    home = home or repo.parent / "home"
    home.mkdir(exist_ok=True)
    env = {k: v for k, v in os.environ.items() if k not in INHERITED}
    env |= {"HOME": str(home), "XDG_CONFIG_HOME": str(home),
           "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
           "GIT_AUTHOR_NAME": "t", "GIT_AUTHOR_EMAIL": "t@example.invalid",
           "GIT_COMMITTER_NAME": "t", "GIT_COMMITTER_EMAIL": "t@example.invalid"}
    return subprocess.run(["git", *args], cwd=repo, env=env, check=True, capture_output=True,
                          text=True).stdout.strip()


class Engine:
    """An engine repository holding the tool, a tag, and what GitHub says about the tag."""

    def __init__(self, tmp_path: Path, version: str = "1.2.3", tag: str = "v1.2.3") -> None:
        self.tmp = tmp_path
        self.repo = tmp_path / "engine"
        (self.repo / "tools").mkdir(parents=True)
        shutil.copy2(TOOL, self.repo / "tools" / "publish-engine-release")
        (self.repo / "pyproject.toml").write_text(f'[project]\nname = "substrate"\nversion = "{version}"\n')
        (self.repo / "substrate").mkdir()
        (self.repo / "substrate" / "wire.py").write_text("VERSION = 1\n")
        (self.repo / "run.sh").write_text("#!/bin/sh\n")
        (self.repo / "run.sh").chmod(0o755)
        (self.repo / ".gitignore").write_text("dist/\n")
        _git(self.repo, "init", "-q")
        _git(self.repo, "add", "-A")
        _git(self.repo, "commit", "-q", "-m", "release")
        self.commit = _git(self.repo, "rev-parse", "HEAD")
        self.tag = tag
        _git(self.repo, "tag", "-a", tag, "-m", f"substrate {tag}")
        self.tag_object = _git(self.repo, "rev-parse", f"refs/tags/{tag}")
        # After the tag: a later commit, with the next version, and an edit in the working tree,
        # none of them released.
        (self.repo / "LATER.md").write_text("later\n")
        (self.repo / "pyproject.toml").write_text('[project]\nname = "substrate"\nversion = "9.9.9"\n')
        _git(self.repo, "add", "LATER.md", "pyproject.toml")
        _git(self.repo, "commit", "-q", "-m", "after the release")
        self.main = _git(self.repo, "rev-parse", "HEAD")
        (self.repo / "substrate" / "wire.py").write_text("VERSION = 2\n")
        self.answers = {
            f"repos/{REPO}/git/ref/tags/{tag}": {"object": {"sha": self.tag_object, "type": "tag"}},
            f"repos/{REPO}/git/tags/{self.tag_object}": {
                "object": {"sha": self.commit, "type": "commit"},
                "verification": {"verified": True, "reason": "valid"},
            },
            # `main` (the branch, by its full ref) is ahead of the tagged commit: the commit merged.
            # Keyed by the branch's id, so a lookup of the bare name `main` finds nothing.
            f"repos/{REPO}/git/ref/heads/main": {"object": {"sha": self.main, "type": "commit"}},
            f"repos/{REPO}/compare/{self.commit}...{self.main}": {"status": "ahead"},
        }
        stubs = tmp_path / "stubs"
        stubs.mkdir()
        (stubs / "gh").write_text(GH)
        (stubs / "gh").chmod(0o755)
        self.calls = tmp_path / "gh-calls"

    def run(self, *args: str) -> subprocess.CompletedProcess:
        answers = self.tmp / "answers.json"
        answers.write_text(json.dumps(self.answers))
        env = {"PATH": f"{self.tmp / 'stubs'}:{os.environ['PATH']}", "HOME": str(self.tmp),
               "XDG_CONFIG_HOME": str(self.tmp),
               "GIT_CONFIG_GLOBAL": "/dev/null", "GIT_CONFIG_NOSYSTEM": "1",
               "GH_ANSWERS": str(answers), "GH_CALLS": str(self.calls)}
        return subprocess.run([sys.executable, "-I", str(self.repo / "tools" / "publish-engine-release"),
                               *args], cwd=self.repo, env=env, capture_output=True, text=True)

    @property
    def released(self) -> list[list[str]]:
        if not self.calls.exists():
            return []
        return [json.loads(line) for line in self.calls.read_text().splitlines()]

    def dist(self, name: str) -> Path:
        return self.repo / "dist" / name


def _assert_tarball_is_the_tagged_commit(engine: Engine, version: str) -> None:
    tarball = engine.dist(f"substrate-{version}.tar.gz")
    with tarfile.open(tarball, "r:gz") as tar:
        names = sorted(m.name for m in tar if not m.isdir())
        wire = tar.extractfile(f"substrate-{version}/substrate/wire.py").read()
    committed = sorted(f"substrate-{version}/{p}" for p in
                       _git(engine.repo, "ls-tree", "-r", "--name-only", engine.commit).splitlines())
    assert names == committed
    assert wire == b"VERSION = 1\n"
    digest = hashlib.sha256(tarball.read_bytes()).hexdigest()
    assert engine.dist("SHA256SUMS").read_text() == f"{digest}  substrate-{version}.tar.gz\n"


def test_a_release_attaches_the_tagged_source_and_its_sums(tmp_path: Path) -> None:
    engine = Engine(tmp_path)
    run = engine.run("v1.2.3")
    assert run.returncode == 0, run.stderr
    _assert_tarball_is_the_tagged_commit(engine, "1.2.3")
    [call] = engine.released
    assert call[:3] == ["release", "create", "v1.2.3"]
    assert call[3:5] == [str(engine.dist("substrate-1.2.3.tar.gz")), str(engine.dist("SHA256SUMS"))]
    assert call[call.index("--repo") + 1] == REPO
    assert "--verify-tag" in call and "--prerelease" not in call
    # There is no release yet, so this one is Latest.
    assert "--latest" in call


@pytest.mark.parametrize(("current", "flag"), [("v1.2.2", "--latest"), ("v1.2.3-rc.1", "--latest"),
                                               ("v1.3.0", "--latest=false"), ("v2.0.0", "--latest=false")])
def test_a_patch_on_an_older_line_does_not_take_latest(tmp_path: Path, current: str, flag: str) -> None:
    """GitHub makes every new release Latest unless told, so the tool says which it is."""
    engine = Engine(tmp_path)
    engine.answers[f"repos/{REPO}/releases/latest"] = {"tag_name": current}
    run = engine.run("v1.2.3")
    assert run.returncode == 0, run.stderr
    [call] = engine.released
    assert flag in call and ({"--latest", "--latest=false"} - {flag}).isdisjoint(call)


def test_a_dry_run_writes_and_lists_the_assets_and_releases_nothing(tmp_path: Path) -> None:
    engine = Engine(tmp_path)
    run = engine.run("--dry-run", "v1.2.3")
    assert run.returncode == 0, run.stderr
    assert run.stdout.splitlines() == ["dist/substrate-1.2.3.tar.gz", "dist/SHA256SUMS"]
    _assert_tarball_is_the_tagged_commit(engine, "1.2.3")
    assert engine.released == []


def test_an_rc_tag_is_a_prerelease_of_the_pep440_version(tmp_path: Path) -> None:
    engine = Engine(tmp_path, version="1.2.3rc1", tag="v1.2.3-rc.1")
    run = engine.run("v1.2.3-rc.1")
    assert run.returncode == 0, run.stderr
    _assert_tarball_is_the_tagged_commit(engine, "1.2.3rc1")
    [call] = engine.released
    assert "--prerelease" in call and not any(a.startswith("--latest") for a in call)


def _refused(engine: Engine, *args: str, says: str) -> None:
    run = engine.run(*args)
    assert run.returncode != 0
    assert says in run.stderr, run.stderr
    assert engine.released == []
    dist = engine.repo / "dist"
    assert not dist.exists() or list(dist.iterdir()) == [], list(dist.iterdir())


@pytest.mark.parametrize("tag", ["1.2.3", "v1.2", "v1.2.3-beta", "v1.2.3-rc1", "v01.2.3x", "v01.2.3",
                                 "v1.2.3-rc.0", "v\u0661.2.3", "v1.2.3\n"])
def test_a_tag_that_is_not_a_release_tag_is_refused(tmp_path: Path, tag: str) -> None:
    _refused(Engine(tmp_path), tag, says="is not a release tag")


@pytest.mark.parametrize("text", ['[project]  # the package\nversion = "1.2.3"\n',
                                  "[project]\nversion = '1.2.3'  # single quotes\n"])
def test_the_version_is_read_however_toml_spells_it(tmp_path: Path, text: str) -> None:
    import importlib.machinery
    import importlib.util
    loader = importlib.machinery.SourceFileLoader("publish_engine_release", str(TOOL))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    assert module.project_version(text) == "1.2.3"


def test_a_dry_run_says_whether_the_release_would_be_latest(tmp_path: Path) -> None:
    engine = Engine(tmp_path)
    engine.answers[f"repos/{REPO}/releases/latest"] = {"tag_name": "v2.0.0"}
    run = engine.run("--dry-run", "v1.2.3")
    assert run.returncode == 0, run.stderr
    assert "not Latest" in run.stderr


def test_a_latest_release_that_is_not_a_release_tag_is_refused_before_writing(tmp_path: Path) -> None:
    engine = Engine(tmp_path)
    engine.answers[f"repos/{REPO}/releases/latest"] = {"tag_name": "nightly"}
    _refused(engine, "--dry-run", "v1.2.3", says="Latest release is 'nightly'")


def test_a_version_the_pyproject_does_not_hold_is_refused(tmp_path: Path) -> None:
    _refused(Engine(tmp_path, version="1.2.2"), "v1.2.3", says="says version '1.2.2'")


def test_a_tag_github_does_not_hold_is_refused(tmp_path: Path) -> None:
    engine = Engine(tmp_path)
    del engine.answers[f"repos/{REPO}/git/ref/tags/v1.2.3"]
    _refused(engine, "v1.2.3", says=f"gh api repos/{REPO}/git/ref/tags/v1.2.3 failed: HTTP 404")


def test_an_answer_that_is_not_an_object_is_refused(tmp_path: Path) -> None:
    engine = Engine(tmp_path)
    engine.answers[f"repos/{REPO}/git/ref/tags/v1.2.3"] = "[]"
    _refused(engine, "v1.2.3", says="did not answer with a JSON object")


def test_an_answer_without_an_object_is_refused_not_a_traceback(tmp_path: Path) -> None:
    engine = Engine(tmp_path)
    engine.answers[f"repos/{REPO}/git/ref/tags/v1.2.3"] = {"object": None}
    _refused(engine, "v1.2.3", says="GitHub's v1.2.3 is None")


def test_a_github_tag_naming_another_commit_is_refused(tmp_path: Path) -> None:
    engine = Engine(tmp_path)
    engine.answers[f"repos/{REPO}/git/tags/{engine.tag_object}"]["object"]["sha"] = "0" * 40
    _refused(engine, "v1.2.3", says=f"names {'0' * 40}, not {engine.commit}")


@pytest.mark.parametrize("status", ["diverged", "behind"])
def test_a_commit_that_is_not_on_main_is_refused(tmp_path: Path, status: str) -> None:
    """A pushed tag carries its commit past `main`'s rules and checks."""
    engine = Engine(tmp_path)
    engine.answers[f"repos/{REPO}/compare/{engine.commit}...{engine.main}"]["status"] = status
    _refused(engine, "v1.2.3", says=f"is not on GitHub's main ({status})")


def test_a_tag_already_released_is_refused(tmp_path: Path) -> None:
    """A rerun after a release must not tell the operator to delete the good one."""
    engine = Engine(tmp_path)
    engine.answers[f"repos/{REPO}/releases/tags/v1.2.3"] = {"tag_name": "v1.2.3"}
    _refused(engine, "v1.2.3", says="already has a release for v1.2.3")


def test_a_tag_moved_while_the_release_was_made_is_reported(tmp_path: Path) -> None:
    engine = Engine(tmp_path)
    engine.answers["moved after release"] = {
        f"repos/{REPO}/git/ref/tags/v1.2.3": {"object": {"sha": "f" * 40, "type": "tag"}}}
    run = engine.run("v1.2.3")
    assert run.returncode == 1
    assert "changed while the release was made" in run.stderr, run.stderr


def test_a_tag_github_holds_as_another_object_is_refused(tmp_path: Path) -> None:
    engine = Engine(tmp_path)
    engine.answers[f"repos/{REPO}/git/ref/tags/v1.2.3"]["object"]["sha"] = "0" * 40
    _refused(engine, "v1.2.3", says="push the tag, and never move one")


def test_a_tag_github_does_not_verify_is_refused(tmp_path: Path) -> None:
    engine = Engine(tmp_path)
    engine.answers[f"repos/{REPO}/git/tags/{engine.tag_object}"]["verification"] = {
        "verified": False, "reason": "unsigned"}
    _refused(engine, "v1.2.3", says="does not verify v1.2.3's signature (unsigned)")


def test_a_lightweight_tag_is_refused(tmp_path: Path) -> None:
    engine = Engine(tmp_path)
    _git(engine.repo, "tag", "-d", "v1.2.3")
    _git(engine.repo, "tag", "v1.2.3", engine.commit)
    _refused(engine, "v1.2.3", says="is a lightweight tag")


def test_a_missing_tag_is_refused(tmp_path: Path) -> None:
    _refused(Engine(tmp_path), "v9.9.9", says="there is no tag v9.9.9 here")


def test_inside_another_repository_it_is_refused(tmp_path: Path) -> None:
    """As `substrate/` inside Scripta it would publish to the wrong place, so it does nothing."""
    engine = Engine(tmp_path)
    shutil.rmtree(engine.repo / ".git")
    _git(tmp_path, "init", "-q", home=tmp_path / "home")
    _refused(engine, "v1.2.3", says="this tree is not a repository's root")


@pytest.mark.parametrize("change", ["autocrlf", "attributes"])
def test_an_archive_that_is_not_the_commit_is_refused(tmp_path: Path, change: str) -> None:
    engine = Engine(tmp_path)
    if change == "autocrlf":
        _git(engine.repo, "config", "core.autocrlf", "true")
    else:
        (engine.repo / ".git" / "info" / "attributes").write_text("run.sh export-ignore\n")
    _refused(engine, "--dry-run", "v1.2.3", says=f"is not {engine.commit} byte for byte")


def test_a_replace_ref_does_not_change_what_is_released(tmp_path: Path) -> None:
    engine = Engine(tmp_path)
    _git(engine.repo, "replace", engine.commit, _git(engine.repo, "rev-parse", "HEAD"))
    run = engine.run("--dry-run", "v1.2.3")
    assert run.returncode == 0, run.stderr
    with tarfile.open(engine.dist("substrate-1.2.3.tar.gz"), "r:gz") as tar:
        assert "substrate-1.2.3/LATER.md" not in tar.getnames()


@pytest.mark.parametrize("args", [[], ["--dry-run"], ["v1.2.3", "v1.2.4"], ["--dryrun", "v1.2.3"]])
def test_a_wrong_invocation_prints_the_usage(tmp_path: Path, args: list[str]) -> None:
    engine = Engine(tmp_path)
    run = engine.run(*args)
    assert run.returncode == 2
    assert run.stderr.startswith("usage: tools/publish-engine-release")
    assert engine.released == []
