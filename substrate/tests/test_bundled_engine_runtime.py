"""The bundled engine's `runtime/` is a standalone interpreter, whatever directory the build ran from.

Run from `substrate/`, `tools/build-bundled-engine` asked uv for a managed CPython and got the dev
`.venv` instead: `uv python find --no-project` still prefers a virtual environment in the working
directory or `$VIRTUAL_ENV`. The engine shipped that venv as its interpreter — 2.0 GB, dev group
included — and no check refused it. These stand a wrapper in front of uv on PATH and stop the build
before it copies anything; no engine is built.
"""

from __future__ import annotations

import os
import shutil
import stat
import subprocess
from pathlib import Path

import pytest

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "tools" / "build-bundled-engine"
REAL_UV = shutil.which("uv")


def _fake_uv(bin_dir: Path, body: str) -> None:
    bin_dir.mkdir()
    uv = bin_dir / "uv"
    uv.write_text(f"#!/usr/bin/env bash\n{body}\n")
    uv.chmod(uv.stat().st_mode | stat.S_IXUSR)


def _build(dest: Path, cwd: Path, bin_dir: Path, **env: str) -> subprocess.CompletedProcess[str]:
    base = {k: v for k, v in os.environ.items() if k != "VIRTUAL_ENV"}
    base["PATH"] = f"{bin_dir}{os.pathsep}{base['PATH']}"
    return subprocess.run(
        [str(BUILD), str(dest)], cwd=cwd, env={**base, **env}, capture_output=True, text=True, timeout=300
    )


def test_refuses_a_virtual_environment_as_the_interpreter(tmp_path: Path) -> None:
    venv = tmp_path / "venv"
    (venv / "bin").mkdir(parents=True)
    (venv / "pyvenv.cfg").write_text("home = /nowhere\n")
    python = venv / "bin" / "python3.14"
    python.write_text("")
    python.chmod(0o755)
    _fake_uv(
        tmp_path / "fakebin",
        f'[ "$1 $2" = "python find" ] && {{ echo "{python}"; exit 0; }}\nexit 3',
    )
    dest = tmp_path / "out" / "substrate-engine"

    result = _build(dest, ROOT, tmp_path / "fakebin")

    assert result.returncode != 0
    assert "is a virtual environment, not a standalone interpreter" in result.stderr, result.stderr
    assert not (tmp_path / "out").exists(), "the build went past the interpreter check"


def test_refuses_an_interpreter_outside_uvs_managed_directory(tmp_path: Path) -> None:
    # A standalone-shaped prefix outside uv's store with no `pyvenv.cfg` — a conda base, say. uv
    # 0.12.2 does not return one under `only-managed`; this pins the guard for a uv that would.
    conda = tmp_path / "miniconda3"
    (conda / "bin").mkdir(parents=True)
    python = conda / "bin" / "python3.14"
    python.write_text("")
    python.chmod(0o755)
    managed = tmp_path / "uv-python"
    managed.mkdir()
    _fake_uv(
        tmp_path / "fakebin",
        f'[ "$1 $2" = "python find" ] && {{ echo "{python}"; exit 0; }}\n'
        f'[ "$1 $2" = "python dir" ] && {{ echo "{managed}"; exit 0; }}\n'
        "exit 3",
    )
    dest = tmp_path / "out" / "substrate-engine"

    result = _build(dest, ROOT, tmp_path / "fakebin")

    assert result.returncode != 0
    assert "is not a uv-managed interpreter" in result.stderr, result.stderr
    assert not (tmp_path / "out").exists(), "the build went past the interpreter check"


def _managed_314() -> str | None:
    if REAL_UV is None:
        return None
    found = subprocess.run(
        [REAL_UV, "python", "find", "3.14", "--python-preference", "only-managed", "--system"],
        cwd="/", capture_output=True, text=True,
    )
    return found.stdout.strip() if found.returncode == 0 else None


@pytest.mark.skipif(_managed_314() is None, reason="needs uv and a uv-managed CPython 3.14")
@pytest.mark.parametrize("how", ["cwd", "VIRTUAL_ENV"])
def test_a_venv_beside_the_build_is_never_the_interpreter(tmp_path: Path, how: str) -> None:
    project = tmp_path / "project"
    project.mkdir()
    subprocess.run(
        [REAL_UV, "venv", "--quiet", "--python", "3.14", "--python-preference", "only-managed", ".venv"],
        cwd=project, check=True,
    )
    # The real uv answers `python find` and `python dir`, and the first answer is recorded; anything
    # after that stops.
    found = tmp_path / "found"
    _fake_uv(
        tmp_path / "fakebin",
        f'[ "$1 $2" = "python find" ] && {{ "{REAL_UV}" "$@" | tee "{found}"; exit "${{PIPESTATUS[0]}}"; }}\n'
        f'[ "$1 $2" = "python dir" ] && exec "{REAL_UV}" "$@"\n'
        "exit 3",
    )
    # A destination whose parent cannot be written: the build fails at `mkdir` of its stage, after
    # resolving the interpreter and before copying 80 MB of it.
    locked = tmp_path / "locked"
    locked.mkdir()
    locked.chmod(0o555)
    try:
        if how == "cwd":
            result = _build(locked / "substrate-engine", project, tmp_path / "fakebin")
        else:
            result = _build(
                locked / "substrate-engine", ROOT, tmp_path / "fakebin", VIRTUAL_ENV=str(project / ".venv")
            )
    finally:
        locked.chmod(0o755)

    interpreter = Path(found.read_text().strip())
    assert not interpreter.is_relative_to(project), f"the build resolved the venv: {interpreter}"
    assert interpreter == Path(_managed_314())
    # Past both interpreter guards to the stage `mkdir`: they accept the managed install itself.
    assert "Permission denied" in result.stderr, result.stderr
