"""Model-artifact paths, pinned to the external SSD.

Model weights never land on the internal disk. If the drive is not mounted we exit
non-zero rather than fall back — macOS will happily create /Volumes/ExtremeSSD as a
plain directory on the boot volume and silently fill it.

configure() must run BEFORE docling is imported: HuggingFace reads its cache env at
import time.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

DRIVE = Path("/Volumes/ExtremeSSD")
ARTIFACTS = DRIVE / "docling-models"

# Deliberately NOT the drive's 380 GB huggingface_cache/. Docling's weights live inside
# ARTIFACTS so they survive that cache being wiped during HF decommissioning. After the
# one-time prefetch nothing here contacts HuggingFace again.
HF_CACHE = ARTIFACTS / ".hf"


def is_real_mount(p: Path) -> bool:
    """True only for an actual mount point — not a same-named directory on the boot volume."""
    return p.is_dir() and os.path.ismount(p)


def require_drive() -> None:
    if not is_real_mount(DRIVE):
        sys.exit(
            f"FATAL: {DRIVE} is not a mounted volume.\n"
            "Model weights must never land on the internal disk.\n"
            "Mount ExtremeSSD and retry."
        )


def configure(offline: bool = True) -> dict[str, str]:
    """Point every model-download mechanism at the drive. Returns the env it set."""
    require_drive()
    ARTIFACTS.mkdir(parents=True, exist_ok=True)
    HF_CACHE.mkdir(parents=True, exist_ok=True)

    env = {
        "DOCLING_ARTIFACTS_PATH": str(ARTIFACTS),
        "HF_HOME": str(HF_CACHE),
        # Set explicitly: docling has a known issue where weights land in BOTH
        # artifacts_path and ~/.cache when only HF_HOME is set.
        "HF_HUB_CACHE": str(HF_CACHE / "hub"),
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
