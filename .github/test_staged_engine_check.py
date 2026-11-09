"""`.github/staged-engine-check`, on small `.github` trees: the engine's staged copy must say what
this repository's says about the engine. Run by the `staged engine config` job with the engine's
locked `test` group, which holds the YAML reader the check uses.

TRICKS are changes the previous, line-by-line reader passed although the copy then behaved
differently; each must fail here.
"""

from __future__ import annotations

import importlib.machinery
import importlib.util
from pathlib import Path

import pytest

SCRIPT = Path(__file__).resolve().parent / "staged-engine-check"
CHECKOUT = "actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1"
CODEQL = "github/codeql-action/init@977e6ceaea7361825998245d787fa3b4d6b9e5df"

ROOT = {
    "dependabot.yml": """\
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    commit-message:
      prefix: "ci"

  - package-ecosystem: uv
    directory: /substrate
    schedule:
      interval: weekly   # a trailing comment
    groups:
      engine:
        patterns:
          - "*"

  - package-ecosystem: swift
    directory: /Core
    schedule:
      interval: weekly
""",
    "workflows/tests.yml": f"""\
name: tests
on:
  push:
    branches: [main]
  pull_request:
permissions:
  contents: read
concurrency:
  group: tests-${{{{ github.ref }}}}
jobs:
  engine:
    runs-on: ubuntu-latest
    steps:
      - uses: {CHECKOUT} # v7
      - run: |
          bash .github/engine-alone "$RUNNER_TEMP/engine"
          echo "PYTHONPATH=$RUNNER_TEMP/engine" >> "$GITHUB_ENV"
      - run: uv run pytest tests -q
        working-directory: ${{{{ runner.temp }}}}/engine

  docling:
    runs-on: macos-15
    timeout-minutes: 20
    continue-on-error: false
    env:
      HF_HUB_OFFLINE: "1"
      LABEL: "a #b"
    steps:
      - uses: {CHECKOUT}
      - run: |
          bash .github/engine-alone "$RUNNER_TEMP/engine"
          echo "PYTHONPATH=$RUNNER_TEMP/engine" >> "$GITHUB_ENV"
      - run: >-
          uv sync --frozen
          --no-install-package opencv-python-headless
        working-directory: ${{{{ runner.temp }}}}/engine
      - run: test -s "$RUNNER_TEMP/junit.xml"

  core:
    runs-on: macos-15
    steps:
      - uses: some/other-action@0000000000000000000000000000000000000000
""",
    "workflows/codeql.yml": f"""\
name: code scanning
on: [push]
permissions:
  contents: read
jobs:
  python:
    runs-on: ubuntu-latest
    steps:
      - uses: {CODEQL}
        with:
          languages: python
  swift:
    runs-on: macos-15
""",
}

STAGED = {
    "dependabot.yml": """\
# The engine's copy.
version: 2
updates:
  - package-ecosystem: github-actions
    directory: /
    schedule:
      interval: weekly
    commit-message:
      prefix: "ci"

  - package-ecosystem: uv
    directory: /
    schedule:
      interval: weekly
    # A comment the root does not have.
    groups:
      engine:
        patterns:
          - "*"
""",
    "workflows/tests.yml": f"""\
name: tests
on:
  push:
    branches: [main]
  pull_request:
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: tests-${{{{ github.ref }}}}
jobs:
  engine:
    runs-on: ubuntu-latest
    steps:
      - uses: {CHECKOUT}
      - run: echo "PYTHONPATH=$GITHUB_WORKSPACE" >> "$GITHUB_ENV"
      - run: uv run pytest tests -q
""",
    "workflows/docling.yml": f"""\
name: docling
on:
  pull_request:
    paths-ignore: ["*.md"]
permissions:
  contents: read
concurrency:
  group: docling-${{{{ github.ref }}}}
jobs:
  docling:
    runs-on: macos-15
    timeout-minutes: 20
    continue-on-error: false
    env:
      HF_HUB_OFFLINE: "1"
      LABEL: "a #b"
    steps:
      - uses: {CHECKOUT}
      - run: echo "PYTHONPATH=$GITHUB_WORKSPACE" >> "$GITHUB_ENV"
      - run: >-
          uv sync --frozen
          --no-install-package opencv-python-headless
      - run: test -s "$RUNNER_TEMP/junit.xml"
""",
    "workflows/codeql.yml": f"""\
name: code scanning
on: [push, pull_request]
permissions:
  contents: read
jobs:
  python:
    runs-on: ubuntu-latest
    steps:
      - uses: {CODEQL}
        with:
          languages: python
""",
}

SETUP_STAGED = '      - run: echo "PYTHONPATH=$GITHUB_WORKSPACE" >> "$GITHUB_ENV"\n'
UV_SYNC = "      - run: >-\n          uv sync --frozen\n          --no-install-package opencv-python-headless\n"


def _check_module():
    loader = importlib.machinery.SourceFileLoader("staged_engine_check", str(SCRIPT))
    spec = importlib.util.spec_from_loader(loader.name, loader)
    module = importlib.util.module_from_spec(spec)
    loader.exec_module(module)
    return module


CHECK = _check_module()


def _write(folder: Path, files: dict[str, str]) -> Path:
    for path, text in files.items():
        (folder / path).parent.mkdir(parents=True, exist_ok=True)
        (folder / path).write_text(text)
    return folder


def _changing(files: dict[str, str], path: str, old: str, new: str) -> dict[str, str]:
    assert files[path].count(old) == 1, f"{old!r} is not once in {path}"
    return {**files, path: files[path].replace(old, new)}


def _run(tmp_path: Path, capsys, root=ROOT, staged=STAGED) -> tuple[int, str]:
    status = CHECK.main([str(_write(tmp_path / "root", root)), str(_write(tmp_path / "staged", staged))])
    return status, capsys.readouterr().err


def test_the_engines_part_with_its_differences_passes(tmp_path: Path, capsys) -> None:
    status, err = _run(tmp_path, capsys)
    assert status == 0, err


def test_the_same_meaning_spelled_otherwise_passes(tmp_path: Path, capsys) -> None:
    """Read as YAML: flow style, quoting and comments are spelling, not meaning."""
    staged = _changing(STAGED, "workflows/codeql.yml",
                       f"      - uses: {CODEQL}\n        with:\n          languages: python\n",
                       f"      - {{uses: '{CODEQL}', with: {{languages: \"python\"}}}}  # flow\n")
    status, err = _run(tmp_path, capsys, staged=staged)
    assert status == 0, err


@pytest.mark.parametrize(("side", "path", "old", "new", "says"), [
    ("root", "dependabot.yml", "interval: weekly   # a trailing comment", "interval: daily", "uv Dependabot"),
    ("root", "dependabot.yml", 'prefix: "ci"', 'prefix: "chore"', "github-actions Dependabot"),
    ("staged", "dependabot.yml", "version: 2", "version: 2\nregistries: {}", "outside their entries"),
    ("root", "dependabot.yml", "directory: /substrate", "directory: /engine", "no uv entry at /substrate"),
    ("staged", "dependabot.yml", '          - "*"\n', '          - "*"\n  - package-ecosystem: pip\n    directory: /\n',
     "must have exactly"),
], ids=["root-setting", "other-entry", "top-level", "root-directory", "extra-entry"])
def test_dependabot_drift_fails_by_name(tmp_path: Path, capsys, side, path, old, new, says) -> None:
    files = _changing(ROOT if side == "root" else STAGED, path, old, new)
    status, err = _run(tmp_path, capsys, **{side: files})
    assert status == 1 and says in err, err


@pytest.mark.parametrize(("side", "path", "old", "new", "says"), [
    ("root", "workflows/tests.yml", f"      - uses: {CHECKOUT} # v7\n",
     f"      - uses: {CHECKOUT.replace('3d3c42e5', '11111111')}\n", "tests.yml engine"),
    ("root", "workflows/tests.yml", '      HF_HUB_OFFLINE: "1"\n', '      HF_HUB_OFFLINE: "1"\n      UV_EXTRA: "1"\n',
     "tests.yml docling"),
    ("root", "workflows/codeql.yml", "languages: python", "languages: python,go", "codeql.yml python"),
    ("root", "workflows/tests.yml", "permissions:\n  contents: read\n", "permissions:\n  contents: write\n",
     "differ outside their jobs"),
    ("staged", "workflows/docling.yml", "jobs:", "defaults:\n  run:\n    shell: bash {0}\njobs:",
     "differ outside their jobs"),
    ("staged", "workflows/tests.yml", "    runs-on: ubuntu-latest\n",
     "    runs-on: ubuntu-latest\n    continue-on-error: true\n", "tests.yml engine"),
    ("staged", "workflows/docling.yml", '      - run: test -s "$RUNNER_TEMP/junit.xml"\n', "", "tests.yml docling"),
    ("staged", "workflows/docling.yml", '      - run: test -s "$RUNNER_TEMP/junit.xml"\n',
     '      - run: test -s "$RUNNER_TEMP/junit.xml" || true\n', "tests.yml docling"),
], ids=["pin-bumped-here", "env-added", "input-changed", "permissions", "defaults", "job-setting",
        "step-dropped", "step-cannot-fail"])
def test_workflow_drift_fails_by_name(tmp_path: Path, capsys, side, path, old, new, says) -> None:
    files = _changing(ROOT if side == "root" else STAGED, path, old, new)
    status, err = _run(tmp_path, capsys, **{side: files})
    assert status == 1 and says in err, err


TRICKS = {
    # The setup step is exempt only exactly: one more command in it is not the copy.
    "setup-step-with-more": ("workflows/docling.yml", SETUP_STAGED,
                             '      - run: |\n          echo "PYTHONPATH=$GITHUB_WORKSPACE" >> "$GITHUB_ENV"\n'
                             '          echo SUBSTRATE_DOCLING_TESTS=0 >> "$GITHUB_ENV"\n'),
    # A continuation line folds into the one-line setup step's command.
    "setup-step-continued": ("workflows/docling.yml", SETUP_STAGED,
                             SETUP_STAGED + "          echo SUBSTRATE_DOCLING_TESTS=0\n"),
    # ` #` inside a quoted value is the value, not a comment.
    "hash-in-a-quoted-value": ("workflows/docling.yml", 'LABEL: "a #b"', 'LABEL: "a #c"'),
    # ` # ...` inside a folded command becomes a shell comment once folded, and drops the flags after it.
    "comment-in-a-folded-command": ("workflows/docling.yml", "          uv sync --frozen\n",
                                    "          uv sync --frozen # pinned\n"),
    # A line starting with `#` inside a block scalar is content.
    "hash-line-in-a-block": ("workflows/docling.yml", "          uv sync --frozen\n",
                             "          uv sync --frozen\n          # --no-dev\n"),
    # A blank line inside a folded scalar turns one command into two.
    "blank-line-in-a-folded-command": ("workflows/docling.yml", "          uv sync --frozen\n",
                                       "          uv sync --frozen\n\n"),
    # A working-directory the root does not have.
    "working-directory-elsewhere": ("workflows/docling.yml", UV_SYNC, UV_SYNC + "        working-directory: tests\n"),
    # YAML 1.1 reads these as the root's values; GitHub, reading 1.2, does not.
    "octal-timeout": ("workflows/docling.yml", "timeout-minutes: 20", "timeout-minutes: 024"),
    "no-for-false": ("workflows/docling.yml", "continue-on-error: false", "continue-on-error: no"),
    # A key given twice: GitHub refuses the file.
    "duplicate-key": ("workflows/docling.yml", "    timeout-minutes: 20\n",
                      "    timeout-minutes: 20\n    timeout-minutes: 20\n"),
}


@pytest.mark.parametrize("trick", sorted(TRICKS))
def test_a_trick_the_line_reader_passed_fails(tmp_path: Path, capsys, trick: str) -> None:
    path, old, new = TRICKS[trick]
    status, err = _run(tmp_path, capsys, staged=_changing(STAGED, path, old, new))
    assert status == 1, f"{trick} passed: {err}"


def test_an_extra_staged_job_or_workflow_fails(tmp_path: Path, capsys) -> None:
    extra_job = {**STAGED, "workflows/tests.yml": STAGED["workflows/tests.yml"] + "  publish:\n    runs-on: x\n"}
    status, err = _run(tmp_path / "job", capsys, staged=extra_job)
    assert status == 1 and "must have exactly ['engine']" in err, err
    extra_workflow = {**STAGED, "workflows/release.yml": "jobs:\n  release:\n    runs-on: x\n"}
    status, err = _run(tmp_path / "workflow", capsys, staged=extra_workflow)
    assert status == 1 and "has the workflows" in err, err


def test_a_missing_staged_job_fails(tmp_path: Path, capsys) -> None:
    staged = {**STAGED, "workflows/docling.yml": "jobs:\n  other:\n    runs-on: macos-15\n"}
    status, err = _run(tmp_path, capsys, staged=staged)
    assert status == 1 and "there is no job staged docling.yml docling" in err, err
