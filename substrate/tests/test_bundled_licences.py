"""The guards that a dependency bump cannot pass by being green.

CI installs four packages and never resolves the engine's locked set, so a lock change that would
stop `tools/build-bundled-engine` dead — a new OpenCV with no vendored notice, or a prebuilt wheel
carrying FFmpeg — passes every test and fails hours later at bundle time. Measured 2026-09-16: a
Dependabot pull request moving OpenCV across a major reported five green checks and would have
failed the build at its licence step.

These read `pyproject.toml` and `uv.lock` as text. No network, no imports, no engine.
"""

from __future__ import annotations

import re
import tomllib
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
LOCK = ROOT / "uv.lock"
PYPROJECT = ROOT / "pyproject.toml"
LICENCES = ROOT / "third_party_licenses"


def _locked_version(package: str) -> str:
    """The version `uv.lock` pins for one package."""
    for block in LOCK.read_text("utf-8").split("[[package]]"):
        if re.search(rf'^name = "{re.escape(package)}"$', block, re.M):
            match = re.search(r'^version = "([^"]+)"$', block, re.M)
            assert match, f"{package} has no version in uv.lock"
            return match.group(1)
    raise AssertionError(f"{package} is not in uv.lock")


def test_opencv_has_a_vendored_notice_for_the_version_that_is_locked() -> None:
    """OpenCV's own notice describes its prebuilt wheels, which this build does not use, so the
    build replaces it and refuses when no notice matches. A bump lands here first."""
    version = _locked_version("opencv-python-headless")
    notice = LICENCES / f"opencv-python-headless-{version}-third-party.txt"
    assert notice.is_file(), (
        f"OpenCV is locked at {version} and {notice.name} does not exist. "
        "`tools/build-bundled-engine` refuses a bundle whose OpenCV notice does not match, so this "
        "bump breaks the build until the notice is regenerated (third_party_licenses/README.md)."
    )
    # The word appears in the header, which exists to say FFmpeg is NOT here. What must not appear is
    # an FFmpeg LICENCE SECTION, which is how the prebuilt wheels' notice describes it.
    sections = [line for line in notice.read_text("utf-8").splitlines() if line.startswith("License: ")]
    assert sections, "the notice has no licence sections"
    body = notice.read_text("utf-8")
    assert "\nFFmpeg\n" not in body and "LGPL" not in body and "GPL version" not in body, (
        "the vendored notice carries a copyleft media-library section, which this build compiles out"
    )


def test_opencv_is_still_built_from_source() -> None:
    """The FFmpeg-free guarantee is the source build. A prebuilt macOS wheel bundles a GPL-3.0+
    FFmpeg, and every one of them does, so losing this line ships GPL binaries with no source."""
    config = tomllib.loads(PYPROJECT.read_text("utf-8"))
    uv = config["tool"]["uv"]
    assert "opencv-python-headless" in uv["no-binary-package"], (
        "opencv-python-headless is no longer in no-binary-package, so the build would install the "
        "prebuilt wheel, which carries FFmpeg under GPL-3.0-or-later"
    )
    flags = uv["extra-build-variables"]["opencv-python-headless"]["CMAKE_ARGS"]
    assert "-DWITH_FFMPEG=OFF" in flags, "the source build no longer switches FFmpeg off"


def test_the_gpl_ocr_stack_stays_excluded() -> None:
    """`rapidocr` is the only package that DECLARES OpenCV, and `opencv-python` is the desktop wheel
    with the same FFmpeg. Both are excluded by a marker that can never be true."""
    config = tomllib.loads(PYPROJECT.read_text("utf-8"))
    overrides = " ".join(config["tool"]["uv"]["override-dependencies"])
    for package in ("rapidocr", "opencv-python;"):
        assert package in overrides, f"{package.rstrip(';')} is no longer overridden out"
    assert "sys_platform == 'never'" in overrides


def test_every_vendored_notice_names_a_package_that_is_locked() -> None:
    """A notice left behind after an upgrade is a licence text for something that no longer ships,
    which is how a bundle comes to carry a stale claim about its own contents."""
    stale = []
    for notice in LICENCES.glob("*.txt"):
        match = re.fullmatch(r"(.+?)-(\d[^-]*(?:\.\d+)*)(?:-third-party)?", notice.stem)
        if not match:
            continue
        package, version = match.groups()
        try:
            locked = _locked_version(package)
        except AssertionError:
            stale.append(f"{notice.name} (package not locked)")
            continue
        if locked != version:
            stale.append(f"{notice.name} (locked at {locked})")
    assert not stale, "vendored licence texts no longer match the lock: " + ", ".join(stale)
