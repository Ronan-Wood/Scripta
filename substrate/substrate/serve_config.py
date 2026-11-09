"""`~/.substrate/serve.toml`: the models and the refresh period `substrate serve` runs with.

The operator's, edited by hand. No client writes it, Scripta included, so an engine somebody else
started keeps the models its operator chose. `substrate serve` reads it once, at start, and a flag
given to `serve` overrides it, key by key: flag, then this file, then the engine's default.

    hyde_model   = "auto"                 # --hyde-model: a model name, "auto" or "off"
    rerank_model = "<model>"              # --rerank-model: a model name or "off"
    every        = 900                    # --every, seconds between refresh passes

A missing file is the defaults. A file that is there and cannot be read, does not parse, names a key
this build does not know, or holds a value of the wrong kind refuses the start, naming the file and
the key: an engine quietly running other models than the ones written down answers every question
from a stack nobody chose. So does a cloud model's name: search never sends a query off this Mac.

`"off"` turns an arm off, as `--hyde-model off` and an empty `--rerank-model=` do on the command
line.

NO `embed_model`, and a file naming one is refused. The embedder decides what every index holds:
the refresh pass and every `substrate embed` vector with their own model and drop any other's, so
a serve-only embedder would match no vectors and leave search lexical-only. Choosing one is a design
of its own, not a key here.

`~/.substrate/config.toml` beside it is the engine's other hand-edited file, read by every command
(`blobs`: where originals are stored). This one is `serve`'s alone, read once at its start, and
stricter: an unknown key here is a model the operator believes is running.
"""

from __future__ import annotations

import math
import tomllib
from pathlib import Path

from substrate import freshness, scopes
from substrate.retrieve import local_models

FILE = "serve.toml"
# The server flag each model key stands for. The values are handed to it as that flag, so a model
# name means here exactly what it means on the command line.
MODEL_FLAGS = {"hyde_model": "--hyde-model", "rerank_model": "--rerank-model"}
KEYS = (*MODEL_FLAGS, "every")
OFF = "off"
# What each arm would send off this Mac, for the refusal of a cloud model's name.
_SENDS = {"hyde_model": "every query it expands", "rerank_model": local_models.RERANK_SENDS}
# Read by no build: why each is refused, said in the refusal.
_NOT_HERE = {"embed_model": "the embedder decides what every index holds, and the refresh pass and "
                            "`substrate embed` vector with their own, so this file cannot choose "
                            "one"}
# A few keys and short strings. Anything near this is not that file.
_MAX_BYTES = 64 * 1024


class ServeConfigError(Exception):
    """The file is there and cannot be used: the engine does not start on a guess."""


def path() -> Path:
    """Beside the default registry, in the folder the engine owns (`scopes.engine_home`)."""
    return scopes.engine_home() / FILE


def load() -> dict[str, str | float]:
    """The keys the file sets, checked. `{}` when there is no file."""
    p = path()
    # Non-blocking and fstat'd (`read_bounded`): a FIFO left at the path would otherwise hold the
    # start in `open` with nothing said, until the host app gave up on it.
    try:
        raw = freshness.read_bounded(p, _MAX_BYTES)
    except FileNotFoundError:
        # A link to a file that has gone is a file the operator wrote and the engine cannot read,
        # not an absent one: running the defaults would be the quiet substitution refused here.
        if p.is_symlink():
            raise ServeConfigError(f"{p} is a link to a file that does not exist") from None
        return {}
    except freshness.FileTooLarge:
        raise ServeConfigError(f"{p} is over {_MAX_BYTES // 1024} KiB, which is not a serve.toml"
                               ) from None
    except OSError as e:
        raise ServeConfigError(f"{p} cannot be read: {e}") from None
    try:
        table = tomllib.loads(raw.decode("utf-8"))
    # RecursionError: nesting deep enough to fit under the cap still overflows the parser.
    except (UnicodeDecodeError, tomllib.TOMLDecodeError, RecursionError) as e:
        raise ServeConfigError(f"{p} does not parse as TOML: {type(e).__name__}: {e}") from None

    for key, why in _NOT_HERE.items():
        if key in table:
            raise ServeConfigError(f"{p} names {key!r}, which is not read here: {why}")
    unknown = sorted(set(table) - set(KEYS))
    if unknown:
        raise ServeConfigError(f"{p} names {', '.join(map(repr, unknown))}, which this engine does "
                               f"not read; the keys are {', '.join(KEYS)}")
    out: dict[str, str | float] = {}
    for key in MODEL_FLAGS:
        if key in table:
            value = table[key]
            if not isinstance(value, str) or not value.strip() or value != value.strip():
                raise ServeConfigError(f"{p}: {key} must be a model name or \"off\", a "
                                       f"non-empty string with no surrounding spaces; it is "
                                       f"{value!r}")
            if local_models.is_cloud({"name": value}):
                raise ServeConfigError(local_models.cloud_message(
                    f"{key} in {p}", value, sends=_SENDS[key]))
            out[key] = value
    if "every" in table:
        every = table["every"]
        # `bool` is an `int` in Python, and `every = true` is not a number of seconds.
        if isinstance(every, bool) or not isinstance(every, (int, float)) or not (
                math.isfinite(every) and every > 0):
            raise ServeConfigError(f"{p}: every must be a positive number of seconds; it is "
                                   f"{every!r}")
        out["every"] = float(every)
    return out


def server_flags(config: dict[str, str | float]) -> list[str]:
    """The model keys as server flags, one `--flag=value` element each, so a value starting with
    "-" stays a value. Placed BEFORE the flags `serve` was given: the server's parser keeps the last
    of a repeated flag, so a flag on the command line wins over the file."""
    return [f"{flag}={_flag_value(key, config[key])}" for key, flag in MODEL_FLAGS.items()
            if key in config]


def _flag_value(key: str, value: object) -> object:
    """HyDE has its own "off"; the reranker is turned off by an empty value."""
    return "" if value == OFF and key != "hyde_model" else value
