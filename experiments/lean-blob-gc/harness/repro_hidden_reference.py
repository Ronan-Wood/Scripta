"""`gc --unreferenced` plans to remove a blob that a note's frontmatter names.

Each note is valid YAML that names the blob's checksum. The scan nevertheless misses the reference
when a blank line or a comment line sits between the key and its value, or between two items:

    source_sha256:        source_sha256:        source_sha256:        audio_sha256:
                            # the originals         # the original        - <other>
      - <checksum>          - <checksum>          <checksum>              # and the other side
                                                                          - <checksum>

For a key whose value is empty on its own line, `blob_lifecycle._text_refs` reads the `- item`
lines that follow it, and stops at the first line that is not one. `_INLINE` crosses the newline,
but not a `#`, and not the `-` of a list item. So nothing keeps the blob alive, and once it is older
than seven days the plan lists it for removal.

    .venv/bin/python harness/repro_hidden_reference.py

Prints each case's YAML value, then what the plan does with the blob. The exit code says what
the run found:

- 1: the bug is there, because some case plans the named blob for removal;
- 0: no case does;
- 2: the repro itself is broken. An import or a case crashed, or a control misbehaved: the plain
  list must reach a plan that keeps the blob, and a note naming nothing must reach a plan that
  removes it.

Writes only under a temporary folder of its own, which it removes at the end.
"""

from __future__ import annotations

import hashlib
import os
import shutil
import sys
import tempfile
import traceback
from pathlib import Path

sys.dont_write_bytecode = True
ROOT = Path(os.path.realpath(tempfile.mkdtemp(prefix="blobgc-repro-")))
os.environ["HOME"] = str(ROOT / "home")
os.environ.pop("SUBSTRATE_REGISTRY", None)
sys.path.insert(0, str(Path(__file__).resolve().parents[3] / "substrate"))


def broken(why: str) -> None:
    """Exit 2: the repro could not run, which says nothing about the bug either way."""
    traceback.print_exc()
    shutil.rmtree(ROOT, ignore_errors=True)
    print(f"the repro is broken ({why}), so it says nothing about the bug")
    sys.exit(2)


try:
    import yaml

    from substrate import blob_lifecycle as life
    from substrate import blobs, scopes
except Exception:
    broken("an import failed")

DATA = b"the only copy of a recording\n"
C = hashlib.sha256(DATA).hexdigest()
OTHER = hashlib.sha256(b"the other side\n").hexdigest()
SHAPES = {
    "blank line": ("source_sha256", f"source_sha256:\n\n  - {C}"),
    "comment in a block list": ("source_sha256", f"source_sha256:\n  # the originals\n  - {C}"),
    "comment before the value": ("source_sha256", f"source_sha256:\n  # the original\n  {C}"),
    "comment between two items": (
        "audio_sha256", f"audio_sha256:\n  - {OTHER}\n  # and the other side\n  - {C}"),
    "blank line between two items": ("audio_sha256", f"audio_sha256:\n  - {OTHER}\n\n  - {C}"),
    "control: plain block list": ("source_sha256", f"source_sha256:\n  - {C}"),
    "control: names nothing": ("source_sha256", "source_sha256: []"),
}


def case(name: str, key: str, front: str) -> str:
    """`removed`, `kept` or `refused`: what the plan does with the blob."""
    root = ROOT / name.replace(" ", "-").replace(":", "")
    home, vault = root / "home", root / "v-vault"
    (vault / "03-references").mkdir(parents=True)
    (home / ".substrate").mkdir(parents=True)
    (vault / ".substrate.toml").write_text('name = "v"\ninherits = []\n', "utf-8")
    blobs.config_path = lambda: home / ".substrate" / blobs.CONFIG_NAME
    blobs.default_root = lambda: home / ".substrate" / "blobs"
    scopes.DEFAULT_REGISTRY = home / ".substrate" / "scopes.toml"
    registry = root / "scopes.toml"
    registry.write_text(f'[scopes.v]\nvault = "{vault}"\ndb = "{root / "v.db"}"\n', "utf-8")

    (root / "a.pdf").write_bytes(DATA)
    put = blobs.put(root / "a.pdf")
    old = 1_000_000_000
    os.utime(put.path, (old, old))
    (vault / "03-references" / "a.md").write_text(f"---\ntitle: t\n{front}\n---\n\n# t\n", "utf-8")

    named = yaml.safe_load(f"title: t\n{front}")[key]
    try:
        outcome = "removed" if C in life.gc_plan(registry).remove else "kept"
        detail = f"the plan {'removes' if outcome == 'removed' else 'keeps'} the blob"
    except life.Refused as e:
        outcome, detail = "refused", f"refused: {(str(e).splitlines() or [''])[0]}"
    print(f"{name}:\n  YAML says {key} = {named!r}\n  {detail}\n")
    return outcome


if __name__ == "__main__":
    try:
        removed = {name: case(name, key, front) for name, (key, front) in SHAPES.items()}
    except Exception:
        broken("a case crashed")
    shutil.rmtree(ROOT)
    kept, freed = removed.pop("control: plain block list"), removed.pop("control: names nothing")
    if (kept, freed) != ("kept", "removed"):
        print(f"the controls gave {kept!r} and {freed!r}, not 'kept' and 'removed': the repro is "
              "broken")
        sys.exit(2)
    hit = [n for n, r in removed.items() if r == "removed"]
    print(f"{len(hit)} of {len(removed)} spellings get a named blob planned for removal"
          + (f": {', '.join(hit)}" if hit else ""))
    sys.exit(1 if hit else 0)
