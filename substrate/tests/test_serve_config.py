"""`~/.substrate/serve.toml`: the models and the period `substrate serve` runs with.

Read once at start, by `substrate serve` alone, with a flag winning over the file and the file over
the default, key by key. A file that is there and cannot be used refuses the start.
"""

from __future__ import annotations

import shutil
import sys
import tempfile
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import cli, refresh, serve_config, stack  # noqa: E402
from substrate.mcp import server  # noqa: E402


class _Built(BaseException):
    """Raised where the server would build its stack: past every check, before anything binds."""

    def __init__(self, args) -> None:
        self.args_seen = args


@pytest.fixture
def conf() -> Path:
    """The suite's own serve.toml: conftest points `serve_config.path` at a folder per test."""
    return serve_config.path()


@pytest.fixture
def started(tmp_path: Path, monkeypatch):
    """Run `substrate serve` up to the stack build: the models it would build with, and the period
    it would refresh on."""
    seen: dict = {}
    real_main = server.main

    def main(argv, *, refresh_every=None):
        seen["every"] = refresh_every
        return real_main(argv, refresh_every=refresh_every)

    def build_args(args):
        raise _Built(args)

    monkeypatch.setattr(server, "main", main)
    monkeypatch.setattr(server, "_build_args", build_args)
    registry = tmp_path / "scopes.toml"
    registry.write_text("")
    # A Unix socket path has a length limit the pytest folder is past. Nothing binds it.
    short = Path(tempfile.mkdtemp(dir="/tmp"))

    def run(*flags: str):
        with pytest.raises(_Built) as built:
            cli.main(["serve", "--socket", str(short / "s.sock"), "--registry", str(registry),
                      *flags])
        a = built.value.args_seen
        return {"hyde_model": a.hyde_model, "rerank_model": a.rerank_model,
                "embed_model": a.embed_model, "every": seen["every"]}

    yield run
    shutil.rmtree(short, ignore_errors=True)


DEFAULTS = {"hyde_model": stack.DEFAULT_HYDE, "rerank_model": stack.DEFAULT_RERANK,
            "embed_model": stack.DEFAULT_EMBED, "every": refresh.DEFAULT_EVERY}


def test_no_file_is_the_defaults(conf, started) -> None:
    assert not conf.exists()
    assert started() == DEFAULTS


def test_the_file_sets_what_no_flag_does(conf, started, capsys) -> None:
    conf.write_text('hyde_model = "off"\nrerank_model = "r-model"\nevery = 120\n')
    assert started() == {"hyde_model": "off", "rerank_model": "r-model",
                         "embed_model": stack.DEFAULT_EMBED, "every": 120.0}
    said = capsys.readouterr().err
    assert f"{conf} sets" in said and "hyde_model='off'" in said and "every=120.0" in said


def test_a_flag_wins_over_the_file_key_by_key(conf, started) -> None:
    conf.write_text('hyde_model = "off"\nrerank_model = "r-model"\nevery = 120\n')
    assert started("--hyde-model", "auto", "--every", "60") == {
        "hyde_model": "auto", "rerank_model": "r-model", "embed_model": stack.DEFAULT_EMBED,
        "every": 60.0}


@pytest.mark.parametrize("key", list(serve_config.MODEL_FLAGS))
@pytest.mark.parametrize("spell", ["--{flag} {v}", "--{flag}={v}", "--{short} {v}"])
def test_every_spelling_of_every_model_flag_wins_over_the_file(conf, started, key, spell) -> None:
    """Scripta passes `--flag=value`; a person may type the flag apart or shortened, which the
    server's parser takes as the same flag. Each must still be the last word."""
    conf.write_text("".join(f'{k} = "file-{k}"\n' for k in serve_config.MODEL_FLAGS))
    flag = serve_config.MODEL_FLAGS[key].removeprefix("--")
    words = spell.format(flag=flag, short=flag.split("-")[0], v="from-flag").split()
    got = started(*words)
    assert got[key] == "from-flag"
    assert all(got[k] == f"file-{k}" for k in serve_config.MODEL_FLAGS if k != key)


def test_an_empty_flag_clears_what_the_file_set(conf, started) -> None:
    conf.write_text('rerank_model = "r-model"\n')
    assert started("--rerank-model=")["rerank_model"] == ""


def test_off_turns_an_arm_off_as_the_command_line_does(conf, started) -> None:
    conf.write_text('hyde_model = "off"\nrerank_model = "off"\n')
    got = started()
    assert (got["hyde_model"], got["rerank_model"]) == ("off", "")


def test_no_refresh_wins_over_the_files_period(conf, started) -> None:
    conf.write_text("every = 120\n")
    assert started("--no-refresh")["every"] is None


def test_a_value_starting_with_a_dash_stays_a_value(conf, started) -> None:
    conf.write_text('rerank_model = "-not-a-flag"\n')
    assert started()["rerank_model"] == "-not-a-flag"


@pytest.mark.parametrize("text, says", [
    ("hyde_model = ", "does not parse as TOML"),
    ('models = "x"\n', "'models', which this engine does not read"),
    ("hyde_model = 3\n", "hyde_model must be a model name"),
    ('rerank_model = ""\n', "rerank_model must be a model name"),
    ('rerank_model = "gpt-oss:120b-cloud"\n', "rerank_model in"),
    ('embed_model = "e-model"\n', "'embed_model', which is not read here: the embedder"),
    ('hyde_model = "gpt-oss:120b-cloud"\n', "is a cloud model"),
    ('hyde_model = " h "\n', "hyde_model must be a model name"),
    ("every = true\n", "every must be a positive number"),
    ("every = 0\n", "every must be a positive number"),
    ("every = -5\n", "every must be a positive number"),
    ("every = inf\n", "every must be a positive number"),
    ('every = "900"\n', "every must be a positive number"),
])
def test_a_file_that_cannot_be_used_refuses_the_start(conf, started, capsys, text, says) -> None:
    conf.write_text(text)
    with pytest.raises(serve_config.ServeConfigError, match=says):
        serve_config.load()
    assert cli.main(["serve", "--socket", str(conf.parent / "s.sock")]) == 2
    err = capsys.readouterr().err
    assert says in err and "Nothing was started" in err


def test_an_unreadable_file_refuses(conf) -> None:
    conf.write_text("every = 60\n")
    conf.chmod(0)
    try:
        with pytest.raises(serve_config.ServeConfigError, match="cannot be read"):
            serve_config.load()
    finally:
        conf.chmod(0o600)


def test_an_oversized_file_refuses(conf) -> None:
    conf.write_text("# " + "x" * (70 * 1024) + "\n")
    with pytest.raises(serve_config.ServeConfigError, match="over 64 KiB"):
        serve_config.load()


def test_a_fifo_at_the_path_refuses_rather_than_hangs(conf) -> None:
    import os

    os.mkfifo(conf)
    with pytest.raises(serve_config.ServeConfigError, match="not a regular file"):
        serve_config.load()


def test_nesting_too_deep_to_parse_refuses(conf) -> None:
    conf.write_text("x = " + "[" * 30000 + "]" * 30000 + "\n")
    with pytest.raises(serve_config.ServeConfigError, match="does not parse as TOML"):
        serve_config.load()


def test_a_link_to_a_file_that_is_gone_refuses(conf) -> None:
    """Not the defaults: the operator wrote a file, and the engine cannot read it."""
    conf.symlink_to(conf.parent / "moved-away.toml")
    with pytest.raises(serve_config.ServeConfigError, match="link to a file that does not exist"):
        serve_config.load()
