"""Every entry point must build the SAME retrieval stack from its own defaults.

Doc 3a §6 and `stack.py`'s own docstring require an MCP `search` and the equivalent CLI query to
return the same passages, capability and index_version — "if they diverge, logic leaked into a
transport". `stack.py` claims that is structurally guaranteed: "Two adapters that each wire their
own embedder/HyDE/reranker would satisfy that on the day they were written and drift the first time
one gained a flag. So the wiring is one function and both call it."

THEY DO BOTH CALL IT — WITH DIFFERENT ARGUMENTS, which the one-function guarantee does not cover.
Measured 2026-08-05 against one scope and one index (`scripta`, `v9:bcbc9997a142`), three clients
reported three stacks:

    client                        hyde     reranker   expected_mrr   unmeasured_reason
    MCP (via ~/.local/bin shim)   ran      skipped    null           unmeasured_rerank_model
    CLI, no flags                 off      off        null           unmeasured_arm_combination
    Scripta (states no models)    —        —          0.698 claimed  —

`stack.py:31` says "The defaults are the measured stack precisely so that a caller who changes
nothing gets the number, and a caller who changes one model gets an honest None." That is true of
the MCP server, whose argparse defaults ARE `stack.DEFAULT_*`, and false of the CLI, which wires
`hyde_model=DEFAULT_HYDE if args.full_stack else None`. So the word "default" means two different
things one function apart, and the parity Doc 3a §6 asserts is false by construction rather than by
drift.

These tests read the two parsers rather than restating what they should contain, so a flag added to
either side is caught without editing this file.
"""

from __future__ import annotations

import argparse
import sys
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from substrate import stack  # noqa: E402


def _parser_of(main_fn) -> argparse.ArgumentParser:
    """The parser a `main(argv)` builds, captured by letting it parse and intercepting the object.

    argparse offers no accessor for a parser built inside a function, and copying the flag list
    here would be a second source of truth for the one thing these tests measure. So the parser is
    caught the only way that does not restate it: `parse_args` is patched to raise with the parser
    it was called on, and the exception carries it back out.
    """
    captured: dict[str, argparse.ArgumentParser] = {}
    original = argparse.ArgumentParser.parse_args

    class _Caught(Exception):
        pass

    def spy(self, *a, **kw):  # noqa: ANN001
        captured["parser"] = self
        raise _Caught

    argparse.ArgumentParser.parse_args = spy
    try:
        main_fn([])
    except _Caught:
        pass
    except SystemExit:
        pass
    finally:
        argparse.ArgumentParser.parse_args = original
    parser = captured.get("parser")
    assert parser is not None, "could not capture the parser"
    return parser


def _defaults_of(parser: argparse.ArgumentParser, *dests: str) -> dict[str, object]:
    out: dict[str, object] = {}
    for action in parser._actions:  # noqa: SLF001 — argparse exposes no public accessor
        if action.dest in dests:
            out[action.dest] = action.default
    return out


def _cli_query_subparser() -> argparse.ArgumentParser:
    from substrate.cli import main as cli_main

    root = _parser_of(cli_main)
    for action in root._actions:  # noqa: SLF001
        if isinstance(action, argparse._SubParsersAction):  # noqa: SLF001
            return action.choices["query"]
    raise AssertionError("no subparsers on the CLI root parser")


def _mcp_parser() -> argparse.ArgumentParser:
    from substrate.mcp.server import main as mcp_main

    return _parser_of(mcp_main)


def test_the_mcp_server_defaults_to_the_measured_stack() -> None:
    """The half that is right. `stack.py:31`'s promise holds here: change nothing, get the number."""
    d = _defaults_of(_mcp_parser(), "embed_model", "hyde_model", "rerank_model")
    assert d["embed_model"] == stack.DEFAULT_EMBED, d
    assert d["hyde_model"] == stack.DEFAULT_HYDE, d
    assert d["rerank_model"] == stack.DEFAULT_RERANK, d


def test_a_bare_cli_query_does_not_wire_the_generator_arms() -> None:
    """The divergence, pinned as it is rather than as it should be.

    `cli.cmd_query` resolves `hyde_model=DEFAULT_HYDE if args.full_stack else None`, and
    `--full-stack` defaults False — so `substrate query --scope X "q"` wires embedder only, while
    the MCP's `search` on the same scope wires all three. Same engine, same index, different
    capability, and only one of them can carry the measured number.

    This test asserts the CURRENT behaviour. When the arms are aligned (Doc 4 §4) it will fail, and
    that failure is the signal to delete it — not to update it to the new value.
    """
    d = _defaults_of(_cli_query_subparser(), "full_stack", "cross_encoder")
    assert d["full_stack"] is False, (
        "if --full-stack now defaults True the CLI has been aligned with the MCP; "
        "check `cmd_query`'s arm resolution and retire this test"
    )


def test_the_two_entry_points_disagree_and_this_is_the_open_decision() -> None:
    """The finding itself, as one assertion, so it is visible in a test run rather than only in a doc.

    Doc 4 §4 leaves the resolution open: either the app and CLI name the arm and accept an honest
    null, or `stack.DEFAULT_RERANK` moves so one value serves CLI, MCP and app alike. Whichever is
    chosen, THIS assertion is what stops being true — so it is the gate on that decision.
    """
    mcp = _defaults_of(_mcp_parser(), "hyde_model", "rerank_model")
    cli_wires_generators = _defaults_of(_cli_query_subparser(), "full_stack")["full_stack"]

    mcp_wires_generators = mcp["hyde_model"] is not None and mcp["rerank_model"] is not None
    assert mcp_wires_generators, mcp
    assert not cli_wires_generators, (
        "the CLI now wires the generator arms by default; the entry points may finally agree — "
        "verify a bare `substrate query` and an MCP `search` report the same `retrieval_mode`, "
        "then retire this file"
    )


if __name__ == "__main__":
    _tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    _failed = 0
    for _t in _tests:
        try:
            _t()
            print(f"  PASS  {_t.__name__}")
        except Exception as e:  # noqa: BLE001
            _failed += 1
            print(f"  FAIL  {_t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(_tests) - _failed}/{len(_tests)} passed")
    raise SystemExit(1 if _failed else 0)
