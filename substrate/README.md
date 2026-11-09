# substrate

A local knowledge engine for Markdown vaults. It composes a project vault and the vaults it
inherits into a named **scope**, indexes that scope, and answers search over it. You can reach it
from a command line or through an MCP server, which talks over stdio, a Unix socket or loopback
HTTP. It runs on
your machine, and it sends model requests only to a model server on loopback, refusing any other
host (`substrate/net.py`).

[Scripta](https://github.com/Ronan-Wood/Scripta), a macOS app, bundles this engine. The engine
also runs on its own.

## Status

- **Supported:** macOS on Apple silicon, with Python 3.14. This is the platform the engine is
  developed and shipped on, and some extraction arms (Apple Vision OCR, the Swift helpers under
  `tools/`) exist only there.
- **Tested on Linux:** CI runs the core test suite on Ubuntu. Linux packaging, a wheel and a
  container image are planned and not yet published.
- **Build tools are macOS-only by design.** `tools/build-bundled-engine`, `slim-bundled-engine`,
  `engine-interpreter-pin.py` and `tools/*.swift` build the signed bundle Scripta ships.

## Install from source

You need [uv](https://docs.astral.sh/uv/). It installs a managed Python 3.14 and the locked
dependencies:

```sh
uv sync
```

The first sync is slow: OpenCV builds from source, because every prebuilt macOS wheel bundles a
GPL FFmpeg (`pyproject.toml` explains this).

## Try it on the demo vaults

`vaults/demo-vault` (a project) and `vaults/demo-core-vault` (the vault it inherits) are synthetic
and double as the test fixtures. These commands keep the registry and the index in a scratch
folder, so nothing is written to `~/.substrate`:

```sh
demo=$(mktemp -d)
uv run python -m substrate.cli compose vaults/demo-vault \
  --registry "$demo/scopes.toml" --index-root "$demo/index" --db "$demo/index.db"
uv run python -m substrate.cli query "engine boundary" --scope demo \
  --registry "$demo/scopes.toml" --no-vector
```

`--no-vector` searches without embeddings. Run `substrate.cli embed` against a local Ollama for
vector search.

To keep those scopes refreshed and serve them over a socket in the same folder, run the command
below. Without `--socket` it serves `~/.substrate/run/substrate.sock`, which is where Scripta looks.

```sh
uv run python -m substrate.cli serve --registry "$demo/scopes.toml" --socket "$demo/substrate.sock"
```

Each subcommand's `--help` describes the rest.

## Layout

| path | what |
|---|---|
| `substrate/` | the engine package: ingestion, composition, the index, retrieval, the MCP server |
| `contract/` | what clients rely on: `contract.json` and the golden wire frames, generated and checked by the test suite |
| `tests/` | the test suite (`uv run python -m pytest tests -q`) |
| `tools/` | the bundle build, the interpreter pin, the release script, and macOS helpers |
| `vaults/` | the synthetic demo vaults |
| `third_party_licenses/` | licences of the components the bundle ships |

`PRINCIPLES.md` describes how the engine is built and how it fails, and `RELEASING.md` covers
releases and the interpreter pin.

## Licence

GPL-3.0-or-later. See `LICENSE`. Each release attaches its source tarball and a `SHA256SUMS`.

## Security

See `SECURITY.md`.
