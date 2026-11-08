"""`contract/contract.json` is what the engine states now (`tools/export-contract.py`).

Clients test against that file instead of reading this package's source, so a file that fell
behind the code would let a client pass against a contract the engine no longer keeps. Set
SUBSTRATE_CAPTURE_CONTRACT=1 to rewrite it, the way SUBSTRATE_CAPTURE_SWIFT_FIXTURES rewrites the
frames beside it: this test is the one writer, and it scans the bytes before writing them. Without
it, the committed bytes must equal a fresh export.

The export is only as good as what it can see, so the floors and the mutated trees below check the
reader itself: a renamed key and a moved wire version must each change the export, and anything it
cannot read with certainty must be refused rather than dropped.
"""

from __future__ import annotations

import importlib.util
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent))

import _swift_fixtures as fx  # noqa: E402

ROOT = Path(__file__).resolve().parents[1]
TOOL = ROOT / "tools" / "export-contract.py"
COMMITTED = ROOT / "contract" / "contract.json"
CAPTURE_ENV = "SUBSTRATE_CAPTURE_CONTRACT"
# The one path-shaped token the contract carries on purpose: the tail of the default socket,
# `~/.substrate/run/substrate.sock`, which names no machine.
SOCKET_TAIL = "/.substrate/run/substrate.sock"


def _tool():
    spec = importlib.util.spec_from_file_location("export_contract", TOOL)
    module = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(module)
    return module


tool = _tool()


def _leaks(text: str) -> list[str]:
    """This machine's tells, and any path but the socket's: the scans every frame gets."""
    return (fx.host_strings(text, also=(fx.ENGINE_ROOT.parent,))
            + fx.leaked_paths(json.loads(text), SOCKET_TAIL))


def _tree(tmp_path: Path) -> Path:
    """A copy of the engine tree the export reads."""
    root = tmp_path / "engine"
    shutil.copytree(ROOT / "substrate", root / "substrate",
                    ignore=shutil.ignore_patterns("__pycache__"))
    shutil.copy2(ROOT / "EXPERIMENTS.md", root / "EXPERIMENTS.md")
    return root


def _edit(path: Path, old: str, new: str) -> None:
    text = path.read_text(encoding="utf-8")
    assert old in text, f"{old!r} is not in {path.name}; the mutation would be vacuous"
    path.write_text(text.replace(old, new, 1), encoding="utf-8")


def _stale(root: Path) -> bool:
    """What the main test asserts, asked of another tree: is the committed file not its export?"""
    return tool.render(tool.export(root)) != COMMITTED.read_text(encoding="utf-8")


def test_the_committed_contract_is_what_the_engine_exports_now():
    text = tool.render(tool.export())
    if os.environ.get(CAPTURE_ENV) == "1":
        # `pytest.fail`, not `assert`: these guard a write, and `python -O` strips asserts.
        if found := _leaks(text):
            pytest.fail(f"the export would carry {found}; not written")
        folder = COMMITTED.parent
        if folder.is_symlink() or COMMITTED.is_symlink():
            pytest.fail(f"{COMMITTED} or its folder is a symlink; not written")
        folder.mkdir(exist_ok=True)
        COMMITTED.write_text(text, encoding="utf-8")
    assert COMMITTED.is_file(), f"{COMMITTED.name} missing — write it with {CAPTURE_ENV}=1"
    assert COMMITTED.read_text(encoding="utf-8") == text, (
        f"{COMMITTED.name} no longer says what the engine does — rewrite it with {CAPTURE_ENV}=1, "
        f"and update the clients' copies with it")


def test_the_contract_carries_nothing_of_this_machine():
    assert not (found := _leaks(COMMITTED.read_text(encoding="utf-8"))), (
        f"{COMMITTED.name} carries {found}")


def test_the_export_found_everything_it_should():
    """FLOORS: a reader that stopped recognising a declaration would otherwise export less and
    still match itself."""
    contract = tool.export()
    objects = contract["payloads"]
    assert sorted(objects) == sorted(tool.WIRE_OBJECTS)
    assert all(objects.values()), [name for name, keys in objects.items() if not keys]
    assert sum(map(len, objects.values())) >= 90
    for section in ("spine", "classes", "retrieval", "refresh"):
        for name, value in contract[section].items():
            assert value, f"{section}.{name} is empty"


def test_a_renamed_payload_key_changes_the_export(tmp_path):
    root = _tree(tmp_path)
    render = root / "substrate" / "render.py"
    passage = tool._Module(root, "render.py").function("passage")
    literal = tool._dict_literals(tool._body(passage), "passage")[0]
    key = sorted(tool._literal_keys(literal, "passage"))[0]
    lines = render.read_text(encoding="utf-8").split("\n")
    span = range(literal.lineno - 1, literal.end_lineno)
    hits = [i for i in span if f'"{key}":' in lines[i]]
    assert len(hits) == 1, f"{key!r} is not on exactly one line of passage's literal"
    lines[hits[0]] = lines[hits[0]].replace(f'"{key}":', f'"{key}_renamed":', 1)
    render.write_text("\n".join(lines), encoding="utf-8")

    assert f"{key}_renamed" in tool.export(root)["payloads"]["passage"]
    assert _stale(root)


def test_a_changed_wire_version_changes_the_export(tmp_path):
    root = _tree(tmp_path)
    version = tool.export(root)["wire"]["version"]
    _edit(root / "substrate" / "wire.py", f"\nVERSION = {version}\n", f"\nVERSION = {version + 1}\n")

    assert tool.export(root)["wire"]["version"] == version + 1
    assert _stale(root)


@pytest.mark.parametrize("module, old, new, refusal", [
    # A constant that is not a literal.
    ("wire.py", "\nVERSION = 1\n", "\nVERSION = int(1)\n", "not an integer literal"),
    # A name bound twice: Python keeps the last, a first-match reader would keep the first.
    ("wire.py", "\nVERSION = 1\n", "\nVERSION = 1\nVERSION = 2\n", "bound 2 times"),
    # A vocabulary member that is not a string.
    ("spine.py", '"active", "complete", "archived"', '"active", "complete", ARCHIVED',
     "ARCHIVED is bound 0 times"),
    # An arm state assigned something the reader cannot name.
    ("retrieve/retriever.py", 'reranker = "skipped"', 'reranker = "skipped" if pool else "off"',
     "not a string literal"),
    # A second lock suffix.
    ("local_socket.py", 'path.with_name(path.name + ".lock")',
     'path.with_name(path.name + ".lock"), path.with_name(path.name + ".lk")', "suffix"),
    # A new dict literal in a builder, which no wire object claims.
    ("render.py", "arms = {a: wiring.get(a, ARM_OFF) for a in ARMS}",
     'arms = {a: wiring.get(a, ARM_OFF) for a in ARMS}; extra = {"x": 1}', "Say which wire object"),
    # The two branches of one object disagreeing.
    ("render.py", '"known": True, "state": state,', '"known": True, "status": state,',
     "branches of engine_health emit different keys"),
    # A key that is not a string literal, and a spread, which hides keys.
    ("render.py", '"known": True, "state": state,', '"known": True, KEY: state,',
     "has a key that is not a string literal"),
    ("render.py", '"known": True, "state": state,', '**extra, "known": True, "state": state,',
     "has a key that is not a string literal"),
    # A vocabulary member that is not a string at all.
    ("spine.py", '"active", "complete", "archived"', '"active", "complete", 1',
     "holds a member that is not a string literal"),
    # A module-level rebinding, `|=`-style.
    ("wire.py", "\nVERSION = 1\n", "\nVERSION = 1\nVERSION += 1\n", "bound 2 times"),
    # An arm state rebound in a form the reader does not read.
    ("retrieve/retriever.py", 'reranker = "skipped"', 'reranker += "skipped"',
     "binds reranker in a form"),
    # A state unpacked from something that is not a tuple literal.
    ("render.py", 'state, note = "ready", None', "state, note = _ready()", "unpacks into state"),
    # A bolted-on key whose key is not a literal; one onto a second local; one in a builder whose
    # wire object takes none.
    ("introspect.py", 'row["sources"] = None', "row[KEY] = None",
     "has a key that is not a string literal"),
    ("introspect.py", 'row["sources"] = None', 'row["sources"] = None; tmp["x"] = 1',
     "Say which wire object each belongs to"),
    ("render.py", "    c = result.capability\n",
     '    c = result.capability\n    res = make()\n    res["x"] = 1\n',
     "Say which wire object each belongs to"),
    # Rebindings a first-match reader would miss: inside an `if`, by import, from a function.
    ("wire.py", "\nVERSION = 1\n", "\nVERSION = 1\nif True:\n    VERSION = 2\n", "bound 2 times"),
    ("wire.py", "\nVERSION = 1\n", "\nVERSION = 1\nfrom os import sep as VERSION\n",
     "bound 2 times"),
    ("wire.py", "\nVERSION = 1\n", "\nVERSION = 1\n\n\ndef _f():\n    global VERSION\n    VERSION = 3\n",
     "bound 2 times"),
    # An arm state bound by a `for`.
    ("retrieve/retriever.py", 'reranker = "skipped"', 'for reranker in ("skipped",): pass',
     "binds reranker in a form"),
    # Keys changed in ways the reader does not follow.
    ("introspect.py", 'row["sources"] = None', 'row["sources"] = None; row.update(x=1)',
     "calls row.update"),
    ("introspect.py", 'row["sources"] = None', 'row["sources"] = None; del row["sources"]',
     "changes a key of row"),
    ("introspect.py", 'row["sources"] = None', 'row["sources"] = None; _z = dict(a=1)',
     "dict\\(\\)"),
    # A dict nested in a wire object, and one built in a comprehension.
    ("render.py", '"known": True, "state": state,', '"known": {"x": 1}, "state": state,',
     "holds another"),
    ("render.py", "arms = {a: wiring.get(a, ARM_OFF) for a in ARMS}",
     'arms = {a: {"x": 1} for a in ARMS}', "inside a comprehension"),
    # A vocabulary changed in place at module level, and a `*` import that could rebind anything.
    ("classes.py", "\nEXCLUDED_CLASSES", '\nPOLICIES["x"] = None\nEXCLUDED_CLASSES',
     "POLICIES is bound 2 times"),
    ("refresh_state.py", "\nOUTCOMES", "\nOUTCOMES.update({})\nOUTCOMES", "OUTCOMES is bound 2 times"),
    ("wire.py", "\nVERSION = 1\n", "\nVERSION = 1\nfrom os import *\n", "bound 2 times"),
    # A bolt target whose base keys come from something the reader cannot see.
    ("introspect.py", 'row["sources"] = None', 'row["sources"] = None; row = make()',
     "neither a dict literal"),
    ("introspect.py", 'row["sources"] = None', 'row["sources"] = None; _z = dict.fromkeys("a")',
     "dict\\(\\)"),
    # A health state that could arrive through a parameter.
    ("render.py", "unavailable: tuple[str, ...] = ()) -> dict:",
     'unavailable: tuple[str, ...] = (), state: str = "x") -> dict:', "takes a parameter named"),
    # A wire object built on a base other than the one declared in EXTENDS.
    ("render.py", "rec = passage(h, scope=scope, chars=chars)",
     "rec = document_record(h, scope=scope, chars=chars)", "its declared base"),
    # A bolt target bound by `:=`, and a key written into something nested.
    ("introspect.py", 'row["sources"] = None', 'row["sources"] = None; (row := make())',
     "binds row in a form"),
    ("introspect.py", 'row["sources"] = None', 'row["sources"] = None; row["a"]["b"] = 1',
     "something other than a local"),
    # A vocabulary changed in place from inside a function, with no `global` needed.
    ("classes.py", "\nEXCLUDED_CLASSES", '\ndef _register(k):\n    POLICIES[k] = None\n\n\nEXCLUDED_CLASSES',
     "POLICIES is bound 2 times"),
    # A list vocabulary grown in place.
    ("spine.py", "\nINCLUDED_STATUSES", '\nSTATUSES.append("x")\nINCLUDED_STATUSES',
     "STATUSES is bound 2 times"),
    # A bolt target the builder never assigns: its base keys are unreadable.
    ("render.py", "    rec = passage(h, scope=scope, chars=chars)",
     "    _rec = passage(h, scope=scope, chars=chars)", "rec is never assigned"),
    # A word put on the wire through a name other than the local the reader follows.
    ("render.py", '"known": True, "state": state,', '"known": True, "state": READY,',
     "nor the local this reads"),
    # Arm states set on an attribute, or through setattr().
    ("retrieve/retriever.py", 'reranker = "skipped"', 'reranker = "skipped"; cap.reranker = "x"',
     "sets .reranker"),
    ("retrieve/retriever.py", 'reranker = "skipped"',
     'reranker = "skipped"; setattr(cap, "reranker", "x")', "setattr"),
    # A bolt target handed to a call that could add keys, merged with |, or rebound by an import.
    ("introspect.py", 'row["sources"] = None', 'row["sources"] = None; _fill(row)',
     "hands row to a call"),
    ("introspect.py", 'row["sources"] = None', 'row["sources"] = None; _m = row | extra',
     "merges row with"),
    ("introspect.py", 'row["sources"] = None', 'row["sources"] = None; _m = extra | {}',
     "merges a dict literal"),
    ("introspect.py", 'row["sources"] = None', 'row["sources"] = None; import json as row',
     "binds row in a form"),
    # A reply returned from something the reader cannot see, and a dict kept in an undeclared local.
    ("render.py", "    c = result.capability\n",
     "    c = result.capability\n    if c is None:\n        return base\n", "returns something"),
    ("render.py", '    return {"known": True, "state": state, "arms": arms, "note": note}',
     '    reply = {"known": True, "state": state, "arms": arms, "note": note}\n    return reply',
     "keeps a dict literal in reply"),
    # An arm state stored under its key in a dict.
    ("retrieve/retriever.py", 'reranker = "skipped"', 'reranker = "skipped"; d["reranker"] = "x"',
     "stores under"),
    # Arm states leaving `_capability` some other way than the Capability it builds, or a
    # Capability built elsewhere in the module.
    ("retrieve/retriever.py", "    return Capability(\n",
     "    if hyde is None:\n        return _fallback()\n    return Capability(\n", "returns at line"),
    ("retrieve/retriever.py", "\ndef _capability(",
     '\ndef _other():\n    return Capability(reranker="timeout")\n\n\ndef _capability(',
     "builds a Capability outside"),
    # A Capability built from **keywords, or copied with a new arm state.
    ("retrieve/retriever.py", "    return Capability(\n", "    return Capability(**extra,\n",
     "from \\*\\*keywords"),
    ("retrieve/retriever.py", "\ndef _capability(",
     '\ndef _other(cap):\n    return replace(cap, reranker="timeout")\n\n\ndef _capability(',
     "copies a value with a new reranker"),
    # A dict literal in a nested function inside a builder.
    ("render.py", "    c = result.capability\n",
     '    c = result.capability\n\n    def _h():\n        return {"x": 1}\n', "nested function"),
    # Nesting deeper than the reader recurses: refused, not a traceback.
    ("render.py", 'state, note = "ready", None',
     'state, note = "ready", None; _x = ' + "+".join(["1"] * 3000), "nests too deeply|cannot read"),
])
def test_what_the_reader_cannot_read_with_certainty_is_refused(tmp_path, module, old, new, refusal):
    root = _tree(tmp_path)
    _edit(root / "substrate" / module, old, new)

    with pytest.raises(tool.ExportError, match=refusal):
        tool.export(root)
    assert tool.main(["--root", str(root)]) == 2


def test_a_builder_defined_twice_is_refused(tmp_path):
    root = _tree(tmp_path)
    with (root / "substrate" / "render.py").open("a", encoding="utf-8") as f:
        f.write("\n\ndef engine_health():\n    return {}\n")

    with pytest.raises(tool.ExportError, match="2 functions named engine_health"):
        tool.export(root)


def test_an_annotated_bolted_on_key_is_read(tmp_path):
    root = _tree(tmp_path)
    _edit(root / "substrate" / "introspect.py", 'row["sources"] = None',
          'row["sources"] = None; row["annotated"]: int = 1')

    assert "annotated" in tool.export(root)["payloads"]["scope_row"]


def test_an_arm_name_used_outside_the_capability_does_not_block_the_export(tmp_path):
    """The arm-state words are read from `_capability` alone, so another function's local of the
    same name is none of the contract's business."""
    root = _tree(tmp_path)
    _edit(root / "substrate" / "retrieve" / "retriever.py", "\ndef _capability(",
          "\ndef _unrelated():\n    reranker = make()\n    return reranker\n\n\ndef _capability(")

    assert tool.export(root)["retrieval"]["arm_states"] == tool.export()["retrieval"]["arm_states"]


def test_keys_bolted_on_through_an_unpacking_are_read(tmp_path):
    root = _tree(tmp_path)
    _edit(root / "substrate" / "introspect.py", 'row["sources"] = None',
          'row["sources"], row["pair"] = None, 1')

    assert "pair" in tool.export(root)["payloads"]["scope_row"]


def test_a_cohort_named_only_inside_a_longer_number_is_not_the_cohort(tmp_path):
    root = _tree(tmp_path)
    cases = tool.export(root)["tiers"]["case_count"]
    path = root / "EXPERIMENTS.md"
    path.write_text(path.read_text(encoding="utf-8").replace(
        f"{cases}-case cohort", f"1{cases}-case cohort"), encoding="utf-8")

    with pytest.raises(tool.ExportError, match="cohort section"):
        tool.export(root)


def test_a_word_written_straight_onto_the_wire_is_in_the_vocabulary(tmp_path):
    """Not only assignments to the local: a literal under the same key in a dict, or passed as the
    same keyword, reaches the wire too."""
    root = _tree(tmp_path)
    _edit(root / "substrate" / "render.py", '"known": True, "state": state,',
          '"known": True, "state": "degraded",')
    _edit(root / "substrate" / "retrieve" / "retriever.py", 'reranker = "skipped"',
          'reranker = "skipped"; _probe = dict_like(reranker="kw_word")')

    contract = tool.export(root)
    assert "degraded" in contract["retrieval"]["engine_health_states"]
    assert "kw_word" in contract["retrieval"]["arm_states"]


# What each captured frame holds, by the wire object that must describe it. The frames are the
# engine's real replies, so this is the check on everything the static reader cannot see: a key the
# engine sends that the contract lacks fails here, whatever code added it.
FRAME_OBJECTS = {
    "search.frame.json": [((), "search"), (("passages", "*"), "passage"),
                          (("filters",), "applied_filters"), (("retrieval_mode",), "retrieval_mode"),
                          (("refresh",), "refresh")],
    "status.frame.json": [((), "status"), (("drift",), "drift"), (("refresh",), "refresh"),
                          (("retrieval_arms",), "arms")],
    "documents.frame.json": [((), "documents"), (("documents", "*"), "document"),
                             (("refresh",), "refresh")],
    "expand.frame.json": [((), "expand"), (("note",), "expand_note")],
    "list_scopes.frame.json": [((), "scope_list"), (("scopes", "*"), "scope_row"),
                               (("retrieval_arms",), "arms")],
}
# Keys a caller adds around a builder's result, which the export does not see yet: the
# `list_scopes` tool (`mcp/server.py:_tool_list_scopes`) adds these two around `scopes_payload`.
ADDED_AROUND = {"list_scopes.frame.json": {"retrieval_arms", "server"}}


def _at(value, path):
    if not path:
        yield value
        return
    head, rest = path[0], path[1:]
    if head == "*":
        if not (isinstance(value, list) and value):
            pytest.fail("a frame no longer holds a non-empty list where FRAME_OBJECTS expects one")
        items = value
    else:
        if not (isinstance(value, dict) and head in value):
            pytest.fail(f"a frame no longer holds {head!r}; update FRAME_OBJECTS")
        items = [value[head]]
    for item in items:
        if not rest and not isinstance(item, dict):
            pytest.fail(f"a frame holds no object where FRAME_OBJECTS expects one under {head!r}")
        yield from _at(item, rest)


def test_every_key_in_the_captured_frames_is_in_the_contract():
    objects = json.loads(COMMITTED.read_text(encoding="utf-8"))["payloads"]
    checked = 0
    for name, paths in FRAME_OBJECTS.items():
        frame = json.loads((ROOT / "contract" / "frames" / name).read_text(encoding="utf-8"))
        payload = json.loads(frame["result"]["content"][0]["text"])
        for path, obj in paths:
            for value in _at(payload, path):
                # `status.drift` has two shapes: the drift itself, or the refusal to check it.
                shape = "drift_unchecked" if obj == "drift" and "error" in value else obj
                allowed = set(objects[shape]) | (ADDED_AROUND.get(name, set()) if not path else set())
                assert not (extra := set(value) - allowed), (
                    f"{name} {'.'.join(path) or '(top)'} sends {sorted(extra)}, which the contract's "
                    f"{shape} lacks")
                checked += 1
    assert checked >= len(FRAME_OBJECTS) + 5, "the frames held too little to check"
    # The gap is named, not open-ended: the reply carries exactly those two beyond the builder.
    frame = json.loads((ROOT / "contract" / "frames" / "list_scopes.frame.json").read_text(encoding="utf-8"))
    top = set(json.loads(frame["result"]["content"][0]["text"]))
    assert top - set(objects["scope_list"]) == ADDED_AROUND["list_scopes.frame.json"]


def test_an_unwritable_output_is_exit_2():
    """A real closed pipe, in a real process: the failure at interpreter shutdown is the one that
    exits 120 rather than 2, and only a separate process can show it."""
    read, write = os.pipe()
    os.close(read)
    try:
        run = subprocess.run([sys.executable, "-I", str(TOOL)], stdout=write,
                             stderr=subprocess.PIPE, text=True, timeout=60)
    finally:
        os.close(write)
    assert run.returncode == 2, (run.returncode, run.stderr)
    assert "cannot write the export" in run.stderr


def test_a_word_written_into_the_returned_capability_is_read(tmp_path):
    root = _tree(tmp_path)
    _edit(root / "substrate" / "retrieve" / "retriever.py", "hyde=hyde, reranker=reranker,",
          'hyde=hyde, reranker="timeout",')

    assert "timeout" in tool.export(root)["retrieval"]["arm_states"]


def test_a_repeated_key_is_one_key(tmp_path):
    (tmp_path / "substrate").mkdir()
    (tmp_path / "substrate" / "sample.py").write_text('X = {"a": 1, "a": 2, "b": 3}\n',
                                                      encoding="utf-8")
    assert tool._Module(tmp_path, "sample.py").keys("X") == ["a", "b"]


def test_an_ambiguous_tier_is_refused(tmp_path):
    root = _tree(tmp_path)
    cases = tool.export(root)["tiers"]["case_count"]
    with (root / "EXPERIMENTS.md").open("a", encoding="utf-8") as f:
        f.write(f"\nMeasured at {cases + 1} cases, elsewhere.\n")

    with pytest.raises(tool.ExportError, match="case count"):
        tool.export(root)


def test_tuple_assignments_reach_the_vocabularies():
    """Two of `engine_health`'s three states are assigned as `state, note = "…", …`."""
    assert tool.export()["retrieval"]["engine_health_states"] == ["lexical_only", "ready",
                                                                  "unreachable"]


def test_a_payload_is_read_past_comments_docstrings_and_f_strings(tmp_path):
    (tmp_path / "substrate").mkdir()
    (tmp_path / "substrate" / "sample.py").write_text('''
def payload(a, b) -> dict:
    """A docstring with a { brace and a "quoted key": that is not one."""
    # A comment with "another": decoy
    out = {
        "scope": a,       # trailing comment
        "note": f"an f-string with {a} braces",
    }
    out["added_later"] = b
    return out
''', encoding="utf-8")
    body = tool._body(tool._Module(tmp_path, "sample.py").function("payload"))
    literals = tool._dict_literals(body, "sample")
    assert [tool._literal_keys(d, "sample") for d in literals] == [{"scope", "note"}]
    assert tool._bolted_on(body, "sample") == {"out": {"added_later"}}
