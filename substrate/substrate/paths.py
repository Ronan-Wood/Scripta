"""Where docling's model weights are, when the operator has chosen a folder for them.

NOTHING HERE IS A FIXED LOCATION AND NOTHING HERE CREATES A DIRECTORY. A PDF is read from its own text
layer and an image or a scanned page by Apple's on-device recognizer (`extract/pdftext_arm.py`,
`extract/apple_arm.py`), and neither needs weights, so a Mac with nothing installed reads documents.
docling's layout and table models are an optional upgrade, better on tables and complex layouts: the
operator names a folder holding them (`substrate ingest --docling-models DIR`, which Scripta's
Settings passes), and `models_folder` checks it before anything loads.

This module used to pin the weights to one external drive by name and exit when it was not mounted,
so every PDF and image import failed on any Mac but the one it was written on.

`configure()` must run BEFORE docling is imported: HuggingFace reads its cache env at import time.
"""

from __future__ import annotations

import os
from pathlib import Path

# The two model repositories docling's PDF pipeline loads, laid out as `docling-tools models download
# layout tableformer -o DIR` writes them. Checked by name, so a wrong folder is refused here in a
# sentence rather than deep inside a model load.
LAYOUT_MODELS = "docling-project--docling-layout-heron"
TABLE_MODELS = "docling-project--docling-models"


class ModelsFolderError(ValueError):
    """The named models folder cannot be used. An input problem: nothing was read."""


def models_folder(value: str | os.PathLike[str]) -> Path:
    """The operator's docling models folder, checked. Raises ModelsFolderError.

    NEVER CREATED. A missing folder is almost always an unplugged drive or a moved folder; creating it
    would turn that into a failed model load later, and under /Volumes into a same-named directory on
    the boot disk that fills silently.
    """
    path = Path(value).expanduser()
    if not path.is_dir():
        raise ModelsFolderError(
            f"the docling models folder {path} is not there. If it is on an external drive, connect "
            "the drive; otherwise choose the folder again, or clear the setting to read documents "
            "without models."
        )
    missing = [name for name in (LAYOUT_MODELS, TABLE_MODELS) if not (path / name).is_dir()]
    if missing:
        raise ModelsFolderError(
            f"{path} is not a docling models folder: it has no {' or '.join(missing)}. "
            "`docling-tools models download layout tableformer -o DIR` creates one."
        )
    return path.resolve()


def configure(models: Path, offline: bool = True) -> dict[str, str]:
    """Point docling and HuggingFace at the operator's models folder. Returns the env it set.

    OFFLINE, so nothing is fetched: the folder holds the weights, or the load fails and says so. The
    HuggingFace cache is named inside the same folder rather than left at its default under the home
    directory, so nothing docling touches lands on the internal disk by default.
    """
    hf = models / ".hf"
    env = {
        "DOCLING_ARTIFACTS_PATH": str(models),
        "HF_HOME": str(hf),
        # Set explicitly: docling has a known issue where weights land in BOTH
        # artifacts_path and ~/.cache when only HF_HOME is set.
        "HF_HUB_CACHE": str(hf / "hub"),
        # exFAT has no symlinks; HF falls back to copying. Expected, not a bug.
        "HF_HUB_DISABLE_SYMLINKS_WARNING": "1",
    }
    if offline:
        env["HF_HUB_OFFLINE"] = "1"

    os.environ.update(env)
    return env


def internal_cache_footprint() -> str:
    """Report whether anything leaked to the internal disk. Used as a post-run assertion."""
    out = []
    # Three internal-disk leak paths: HF's cache, docling's OWN cache, and torch hub.
    for p in (
        Path.home() / ".cache" / "huggingface",
        Path.home() / ".cache" / "docling",
        Path.home() / ".cache" / "torch",
    ):
        if not p.exists():
            out.append(f"{p.name}=absent")
            continue
        total = sum(f.stat().st_size for f in p.rglob("*") if f.is_file())
        out.append(f"{p.name}={total / 1e6:.0f}MB")
    return "  ".join(out)
