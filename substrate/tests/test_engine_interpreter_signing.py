"""The bundled interpreter's one entitlement, and the render check that proves it is needed.

0.3.0-0.3.2 signed `runtime/bin/python3.14` with the hardened runtime and no entitlements. docling-
parse draws PDF pages with Blend2D, whose JIT the hardened runtime then refuses, and Blend2D returns
the page buffer undrawn. The layout model read noise, so every PDF converted with the models folder
set came out as loose text blocks: no title, no table, and nothing raised. A signed bundle is not
built here; these pin what `tools/build-bundled-engine` signs with and the check it runs afterwards.
"""

from __future__ import annotations

import importlib.util
import plistlib
import subprocess
import sys
from pathlib import Path

import numpy as np
import pytest

ROOT = Path(__file__).resolve().parents[1]
BUILD = ROOT / "tools" / "build-bundled-engine"
ENTITLEMENTS = ROOT / "tools" / "engine-interpreter.entitlements"
CHECK = ROOT / "tools" / "check-page-render.py"


def _check_module():
    spec = importlib.util.spec_from_file_location("check_page_render", CHECK)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


def test_the_interpreter_is_entitled_to_jit_and_nothing_else() -> None:
    entitlements = plistlib.loads(ENTITLEMENTS.read_bytes())
    # Not allow-unsigned-executable-memory, which also cures the render and permits any W+X mapping;
    # not disable-library-validation, which does not cure it.
    assert entitlements == {"com.apple.security.cs.allow-jit": True}


def test_the_build_signs_the_interpreter_with_those_entitlements() -> None:
    script = BUILD.read_text()
    assert 'INTERPRETER="$STAGE/runtime/bin/python3.14"' in script
    assert 'ENTITLEMENTS="$REPO/tools/engine-interpreter.entitlements"' in script
    assert '[ "$1" = "$INTERPRETER" ] && ent=(--entitlements "$ENTITLEMENTS")' in script
    # ONE codesign call carries both optional flags, so a timestamped (shipping) build cannot sign
    # the interpreter through a branch that forgot the entitlements.
    sign_one = script.split("sign_one() {", 1)[1].split("\n  }\n", 1)[0]
    assert sign_one.count("codesign ") == 1
    assert '${ts[@]+"${ts[@]}"} ${ent[@]+"${ent[@]}"} "$1"' in sign_one


def test_the_build_refuses_entitlements_anywhere_else_and_checks_the_render() -> None:
    script = BUILD.read_text()
    assert "binaries other than the interpreter carry entitlements" in script
    assert "not exactly allow-jit" in script
    # `-I`, so nothing in tools/ can shadow a module the check imports.
    assert '"$STAGE/.venv/bin/python" -B -I "$REPO/tools/check-page-render.py"' in script
    # An undrawn page (1), a broken check (2) and a killed process are reported as different things.
    assert 'check-page-render.py" || render_status=$?' in script
    assert '1) die "docling cannot draw a PDF page under this signature' in script
    assert '2) die "the render check could not reach a page' in script
    assert '*) die "the render check died (exit $render_status' in script


def test_the_fingerprint_covers_both_inputs() -> None:
    # A stamped tree must rebuild when either changes, or it ships the previous signature.
    fingerprint = BUILD.read_text().split("fingerprint() {", 1)[1].split("\n}\n", 1)[0]
    assert '"$REPO/tools/engine-interpreter.entitlements"' in fingerprint
    assert '"$REPO/tools/check-page-render.py"' in fingerprint


def _clean_page() -> np.ndarray:
    page = np.full((792, 612), 255, dtype=np.uint8)
    page[90:112, 72:260] = 0  # a title's worth of ink, under 1% of the page
    return page


@pytest.mark.parametrize(
    ("gray", "reason"),
    [
        # What 7.24.2 returned under the hardened runtime: the whole buffer dark, the same twice.
        (np.zeros((792, 612), dtype=np.uint8), "allow-jit"),
        (np.random.default_rng(0).integers(0, 256, (792, 612), dtype=np.uint8), "allow-jit"),
        (np.full((792, 612), 255, dtype=np.uint8), "blank"),
    ],
    ids=["undrawn-dark", "undrawn-noise", "blank"],
)
def test_an_undrawn_page_is_refused(gray: np.ndarray, reason: str) -> None:
    assert reason in _check_module().verdict(gray)


def test_a_drawn_page_passes() -> None:
    assert _check_module().verdict(_clean_page()) is None


def test_an_undrawn_page_exits_1(monkeypatch: pytest.MonkeyPatch) -> None:
    check = _check_module()
    monkeypatch.setattr(check, "render", lambda pdf: np.zeros((792, 612), dtype=np.uint8))
    assert check.main() == 1


def test_a_check_that_breaks_exits_2_not_1(monkeypatch: pytest.MonkeyPatch, capsys) -> None:
    # A docling API change must not read as an undrawn page, or the build blames the signature.
    check = _check_module()

    def broken(pdf):
        raise AttributeError("'InputDocument' object has no attribute '_backend'")

    monkeypatch.setattr(check, "render", broken)
    assert check.main() == 2
    assert "the check itself failed" in capsys.readouterr().err


@pytest.mark.skipif(importlib.util.find_spec("docling") is None, reason="docling is not installed")
def test_this_interpreter_draws_the_check_page() -> None:
    # The dev interpreter is not under the hardened runtime, so this proves the check's own path —
    # pdfium writes the page, docling's default backend draws it — against the docling that is locked.
    # `-B -I`, exactly as the build runs it.
    result = subprocess.run([sys.executable, "-B", "-I", str(CHECK)], capture_output=True, text=True)
    assert result.returncode == 0, result.stderr
    assert "clean page" in result.stdout
