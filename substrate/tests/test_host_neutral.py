"""The engine does not name the app that hosts it.

The engine runs on its own (`substrate-mcp --socket`) and under any host. A message telling the
reader to "open Scripta" is wrong for every other host and for an engine with none. Before this,
seven runtime strings did that: the bridge's unreachable and refusal texts, and two `--help` lines.

Comments, docstrings nothing prints, and the SQL `--` comments in the schema may say where the
engine is deployed today. Only what a running engine can print or return is checked here.

Runnable with `python tests/test_host_neutral.py` or under pytest.
"""

from __future__ import annotations

import ast
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent.parent
sys.path.insert(0, str(ROOT))

PACKAGE = ROOT / "substrate"
HOSTS = ("Scripta",)


def _docstrings(tree: ast.AST) -> set[int]:
    ids: set[int] = set()
    for node in ast.walk(tree):
        if isinstance(node, (ast.Module, ast.ClassDef, ast.FunctionDef, ast.AsyncFunctionDef)):
            body = getattr(node, "body", [])
            if body and isinstance(body[0], ast.Expr) and isinstance(body[0].value, ast.Constant):
                ids.add(id(body[0].value))
    return ids


# SQL DDL, whose `--` comment lines go into the database's stored schema and are never shown.
DDL = PACKAGE / "store" / "schema.py"


def _names_a_host(text: str, path: Path) -> bool:
    """True if a line of `text` that a reader could see names a host."""
    return any(any(h in line for h in HOSTS)
               and not (path == DDL and line.lstrip().startswith("--"))
               for line in text.splitlines())


def _runtime_strings_naming_a_host() -> list[str]:
    hits: list[str] = []
    for path in sorted(PACKAGE.rglob("*.py")):
        source = path.read_text(encoding="utf-8")
        tree = ast.parse(source, filename=str(path))
        skip = _docstrings(tree)
        # A module that reads its own `__doc__` prints the first line (server.py's `--help`
        # description), so that line is checked like any other string.
        module_doc = ast.get_docstring(tree, clean=False) if "__doc__" in source else None
        if module_doc and _names_a_host(module_doc.split("\n")[0], path):
            hits.append(f"{path.relative_to(ROOT)}:1: {module_doc.split(chr(10))[0][:70]!r}")
        for node in ast.walk(tree):
            if (isinstance(node, ast.Constant) and isinstance(node.value, str)
                    and id(node) not in skip and _names_a_host(node.value, path)):
                hits.append(f"{path.relative_to(ROOT)}:{node.lineno}: {node.value[:70]!r}")
    return hits


def test_no_runtime_string_in_the_engine_names_its_host_app() -> None:
    hits = _runtime_strings_naming_a_host()
    assert not hits, "the engine names a host app in:\n  " + "\n  ".join(hits)


def test_the_unreachable_engine_message_says_how_to_start_it() -> None:
    from substrate.mcp import bridge

    remote = bridge.Remote(Path("/nonexistent-substrate-dir/substrate.sock"))
    text = remote._unreachable(1, "search", FileNotFoundError())["result"]["content"][0]["text"]
    assert "`substrate-mcp --socket`" in text, text
    assert "re-register it with `substrate-mcp --connect` and no path" in text, text


def test_the_start_hint_names_the_path_only_when_it_is_not_the_default() -> None:
    """A client registered with a path other than the default would otherwise be told to start
    an engine somewhere it is not looking, and see the same message again."""
    from substrate import local_socket
    from substrate.mcp import bridge

    assert bridge.Remote(local_socket.default_path()).start_hint.startswith(
        "`substrate-mcp --socket`")


def test_the_start_hint_never_starts_an_engine_on_a_clients_own_non_default_path() -> None:
    """A client registered with an app's old path, before the app has linked it, was told to start
    an engine there. That engine holds the old path for life, so the app can never link it, and two
    engines serve the same scopes."""
    from substrate.mcp import bridge

    hint = bridge.Remote(Path("/tmp/with space/substrate.sock")).start_hint
    assert "--socket /tmp" not in hint and "--socket '/tmp" not in hint, hint
    assert "--connect` and no path" in hint, hint


def test_the_start_hint_quotes_a_link_target_with_a_space() -> None:
    import tempfile

    from substrate.mcp import bridge

    with tempfile.TemporaryDirectory(dir="/tmp") as root:
        link = Path(root) / "substrate.sock"
        target = Path(root) / "with space" / "substrate.sock"
        link.symlink_to(target)
        hint = bridge.Remote(link).start_hint
        assert f"`substrate-mcp --socket '{target}'`" in hint, hint


def test_the_start_hint_through_a_link_names_where_the_engine_must_listen() -> None:
    """An engine refuses to bind over a link, so for a client registered with a host's linked old
    path, the hint must name the link's target, never the link."""
    import tempfile

    from substrate.mcp import bridge

    with tempfile.TemporaryDirectory(dir="/tmp") as root:
        link = Path(root) / "Application Support" / "substrate.sock"
        link.parent.mkdir()
        target = Path(root) / "run" / "substrate.sock"
        link.symlink_to(target)
        hint = bridge.Remote(link).start_hint
        assert f"--socket {target}`" in hint, hint
        assert "Application Support" not in hint, hint


def test_an_untrusted_path_is_not_blamed_on_the_link_that_reached_it() -> None:
    """The refusal can be about the folder a link points into. Telling the reader to remove the
    path they were registered with would delete the host's compatibility link."""
    from substrate import local_socket
    from substrate.mcp import bridge

    remote = bridge.Remote(Path("/tmp/old/substrate.sock"))
    why = local_socket.UntrustedSocket("/tmp/run is mode 755; it must be 700")
    text = remote._unreachable(1, "search", why)["result"]["content"][0]["text"]
    assert "Remove whatever holds" not in text, text
    assert "/tmp/run is mode 755" in text and "/tmp/old/substrate.sock" in text, text


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_") and callable(fn):
            fn()
            print(f"ok  {name}")
