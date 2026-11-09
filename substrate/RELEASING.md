# Releasing the engine

Commands run from this tree's root.

## A release

A release is a signed tag and the source tarball of the commit it names. A client pins that tarball
by its sha256: Scripta builds the engine it bundles from it.

1. On an up-to-date `main` with the `engine` check green, set `version` in `pyproject.toml` to the
   release (`X.Y.Z`, or `X.Y.ZrcN` for a pre-release) and merge that.
2. Make a signed, annotated tag on that commit, and push it:

   ```sh
   git tag -s vX.Y.Z -m "substrate X.Y.Z"
   git push origin vX.Y.Z
   ```

3. Publish it:

   ```sh
   tools/publish-engine-release --dry-run vX.Y.Z
   tools/publish-engine-release vX.Y.Z
   ```

`publish-engine-release` refuses before writing anything unless the tag is annotated, GitHub holds
the same tag object on the same commit and verifies its signature, and `pyproject.toml` at the tag
holds its version. It then writes `dist/substrate-<version>.tar.gz`, from `git archive` with the
prefix `substrate-<version>/`, and refuses it unless every file is the commit's byte for byte. It
writes `dist/SHA256SUMS` and creates the release with both. A `-rc.N` tag makes a pre-release, and
a release older than GitHub's current Latest (a patch on an older line) is not made Latest.
`--dry-run` stops before the release and prints the two files.

A pushed tag is never moved. A release that went wrong gets a new version.

## The interpreter pin

`tools/engine-interpreter.pin` names every file and symlink of the uv-managed CPython the
engine ships, with its sha256, and the install path it was made at. The engine build checks its copy
of the interpreter against it before anything runs or signs that copy, and refuses on any difference:

- **"was made for `<path>`"** — the interpreter is a different install: a new Python, or a uv store
  somewhere else. The pin is per install path, because uv writes that path into the interpreter.
- **"N changed, M missing, K unexpected"** — the same install, different contents. If you did not
  just update Python, something modified uv's store after the install: `uv python install --reinstall
  <version>` and build again. Do not re-pin to make it pass.

Bytecode is not pinned. The build deletes it from its copy, checks the copy a second time just
before signing, and only then compiles the bytecode from the sources it has just checked.

The pin covers the interpreter and nothing else. The engine's dependencies are installed from uv's
cache (`~/.cache/uv`), which the same user can write, and the pin does not check it.

**Re-pinning when Python changes.** Reinstall first, so the pin describes a fresh download rather
than whatever was on disk: uv checks the archive against its own checksum when it downloads it.

```sh
uv python install --reinstall 3.14.N
PY=$(uv python find 3.14 --python-preference only-managed --no-project --system)
/usr/bin/python3 -I tools/engine-interpreter-pin.py --write "$(cd "$(dirname "$PY")/.." && pwd -P)" tools/engine-interpreter.pin
git diff --stat tools/engine-interpreter.pin
```

Read the header the diff shows (the Python version, the python-build-standalone release and the
prefix) before committing. The pin is part of the build fingerprint, so the next build is a full one.
