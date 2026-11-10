#!/usr/bin/env python3
"""The engine's contract with its clients, as `contract/contract.json`.

    export-contract.py [--root DIR]    print the export of this engine tree (or of DIR)

A client decodes the engine's replies and declares the engine's vocabularies, so it needs the
engine's field names, closed vocabularies and wire constants. Read out of the Python by each client,
those were a second parser per client, coupled to the source's formatting and to the source being
present. This writes them down once, as data, beside the golden frames in `contract/frames/`. A
client tests against the file, and the engine's suite (`tests/test_contract.py`) fails when the file
no longer says what the code does. That test is also the one writer: SUBSTRATE_CAPTURE_CONTRACT=1
rewrites the file, after scanning it.

READ, NOT IMPORTED. The payload key sets can only come from reading the builders' source, so the
constants are read the same way: one mechanism, with `ast` (and three patterns over
`EXPERIMENTS.md`), and no engine code executed. It needs the engine's own interpreter (3.14): an
older `ast` cannot parse the engine's syntax.

REFUSED, NOT GUESSED. A value the reader cannot take from a literal, a name bound twice, a new dict
literal in a builder that no wire object below claims, or a non-literal key: each raises, by name.
An export that quietly lost a key would still match itself, and every client test would pass.

A WIRE OBJECT is a set of keys, sorted: what a client decodes, named for what it is rather than for
the function, variable or position that builds it. Each is declared in `WIRE_OBJECTS`: the builder,
which of its outermost dict literals make the object (several are branches of one object, and must
agree), and the local its keys are bolted onto afterwards (`out["key"] = …`), if any. A dict
nested inside a wire object's literal is refused: it would be a wire object nobody declared. Every literal
and every bolted-on name in a builder must belong to exactly one object. KNOWN LIMIT: literals are
matched to objects by their order in the builder, so two literals of one builder that swap places
swap objects. Each client's own decode tests (which pin every object's exact keys) catch that.
Also beyond it: a value changed through an alias or through its type (`p = POLICIES; p[k] = …`,
`dict.update(POLICIES, …)`); a word passed positionally to a constructor, or through an alias of
it; a `Capability` built in another module; keys a caller adds around a builder's result, unless
they are declared the way `scope_list_reply`'s are; and a wire object handed on through an alias or
a container (`r = out; fill(r)`). `tests/test_contract.py` holds the captured frames to the export,
which is the check on what this cannot see.

A key set is every key the engine MAY send: one bolted on under a condition, or present in a reply
the engine sometimes filters, is in it all the same. A nested dict with keys is refused; docstrings
and f-strings contribute nothing.

Exit 0: printed. 2: the export could not be made (or the arguments were wrong), and stderr says
why.
"""

from __future__ import annotations

import argparse
import ast
import functools
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
MINIMUM_PYTHON = (3, 14)

# wire object: (module under the package, builder, the literals that make it, the local its keys
# are bolted onto)
WIRE_OBJECTS: dict[str, tuple[str, str, tuple[int, ...], str | None]] = {
    "passage": ("render.py", "passage", (0,), "out"),
    # The keys an outline record ADDS to a passage (`EXTENDS`).
    "outline_record": ("render.py", "outline_record", (), "rec"),
    "retrieval_mode": ("render.py", "retrieval_mode", (0,), None),
    # Two branches, the unknown and the known stack: one object.
    "engine_health": ("render.py", "engine_health", (0, 1), None),
    "applied_filters": ("render.py", "applied_filters", (0,), None),
    "search": ("render.py", "search_payload", (0,), None),
    "document": ("render.py", "document_record", (0,), None),
    "documents": ("render.py", "documents_payload", (0,), None),
    "refresh": ("refresh_state.py", "_block", (0,), None),
    "arms": ("introspect.py", "arms", (0,), None),
    "vector": ("introspect.py", "vector_status", (0,), None),
    "status": ("introspect.py", "status_payload", (0,), "out"),
    # `status.drift` when the drift could not be checked: two branches.
    "drift_unchecked": ("introspect.py", "status_payload", (1, 2), None),
    "scope_row": ("introspect.py", "scopes_payload", (0,), "row"),
    "scope_list": ("introspect.py", "scopes_payload", (1,), None),
    # The roster an agent-mode server answers with, from its published snapshots.
    "agent_scope_row": ("agent.py", "scopes_payload", (0,), None),
    "agent_scope_list": ("agent.py", "scopes_payload", (1,), None),
    # An agent-mode scope's `refresh` block: the registry's (`EXTENDS`) plus how old the snapshot is.
    "agent_refresh": ("agent.py", "refresh", (), "block"),
    "snapshot": ("agent.py", "refresh", (0,), None),
    "drift": ("freshness.py", "drift", (0,), None),
    "expand": ("mcp/server.py", "_tool_expand", (0,), "out"),
    "expand_note": ("mcp/server.py", "_note_text", (0,), None),
    # What the `list_scopes` TOOL adds around the roster (`EXTENDS`), and the `server` block in it.
    "scope_list_reply": ("mcp/server.py", "_tool_list_scopes", (), "payload"),
    "server": ("mcp/server.py", "_tool_list_scopes", (0,), None),
    # What `refresh` answers: when the pass it brought forward starts.
    "refresh_request": ("mcp/server.py", "_tool_refresh", (0,), None),
}
# A wire object whose local starts as another one's: it carries the other's keys plus its own. Each
# base is named with the exact call that produces it, receiver included, and the local must be
# assigned from those calls and nothing else. Several bases are branches (`a() if x else b()`), each
# reached exactly once. Exported, so a change of base changes the contract.
EXTENDS: dict[str, tuple[tuple[str, str], ...]] = {
    "outline_record": (("passage", "passage"),),
    "scope_list_reply": (("agent_scope_list", "cfg.agent.scopes_payload"),   # agent mode
                         ("scope_list", "introspect.scopes_payload")),        # the registry's
    "agent_refresh": (("refresh", "refresh_state.block_for"),),
}

MODULES = ("agent.py", "markdown/yaml_scalar.py", "wire.py", "local_socket.py", "refresh.py",
           "spine.py", "classes.py", "stack.py",
           "retrieve/retriever.py", "refresh_state.py", "render.py", "introspect.py",
           "freshness.py", "mcp/server.py")


class ExportError(Exception):
    """The tree does not say something the contract needs, in a form this can read."""


class _Module:
    def __init__(self, root: Path, relative: str, base: str = "substrate"):
        self.name = relative if base == "substrate" else f"{base}/{relative}"
        path = root / base / relative
        try:
            self.tree = ast.parse(path.read_text(encoding="utf-8"), filename=self.name)
        except (OSError, SyntaxError, ValueError, RecursionError) as e:
            raise ExportError(f"cannot read {self.name}: {e}") from None

    def binding(self, name: str) -> ast.expr:
        """The value of the one module-level `NAME = …` or `NAME: T = …`. Any other binding of the
        name in module scope is refused — a second assignment, `NAME |= …`, an unpacking, an
        import, a def, one inside an `if` or `try`, a `global` in a function — because Python keeps
        the last value and a reader would report the first."""
        sites = _module_bindings(self.tree, name)
        simple = [n for n in self.tree.body
                  if (isinstance(n, ast.Assign) and len(n.targets) == 1
                      and isinstance(n.targets[0], ast.Name) and n.targets[0].id == name)
                  or (isinstance(n, ast.AnnAssign) and isinstance(n.target, ast.Name)
                      and n.target.id == name and n.value is not None)]
        if len(sites) != 1 or len(simple) != 1:
            raise ExportError(f"{self.name}: {name} is bound {len(sites)} times at module level, "
                              f"not once as `{name} = …`")
        return simple[0].value

    def string(self, name: str) -> str:
        value = self.binding(name)
        if isinstance(value, ast.Constant) and isinstance(value.value, str):
            return value.value
        raise ExportError(f"{self.name}: {name} is not a string literal")

    def integer(self, name: str) -> int:
        value = self.binding(name)
        sign = 1
        if isinstance(value, ast.UnaryOp) and isinstance(value.op, ast.USub):
            sign, value = -1, value.operand
        if isinstance(value, ast.Constant) and type(value.value) is int:
            return sign * value.value
        raise ExportError(f"{self.name}: {name} is not an integer literal")

    def members(self, name: str) -> list[str]:
        """A set of strings, sorted: a literal, `frozenset(…)` of one, or `|` of such sets and of
        other bindings like these."""
        return sorted(self._strings(self.binding(name), name))

    def _strings(self, value: ast.expr, name: str) -> set[str]:
        if (isinstance(value, ast.Call) and isinstance(value.func, ast.Name)
                and value.func.id == "frozenset" and len(value.args) == 1 and not value.keywords):
            return self._strings(value.args[0], name)
        if isinstance(value, ast.BinOp) and isinstance(value.op, ast.BitOr):
            return self._strings(value.left, name) | self._strings(value.right, name)
        if isinstance(value, ast.Name):
            return self._strings(self.binding(value.id), value.id)
        if isinstance(value, (ast.Set, ast.Tuple, ast.List)):
            out = set()
            for e in value.elts:
                if isinstance(e, ast.Constant) and isinstance(e.value, str):
                    out.add(e.value)
                elif isinstance(e, ast.Name):
                    out.add(self.string(e.id))
                else:
                    raise ExportError(f"{self.name}: {name} holds a member that is not a string "
                                      "literal or a string constant")
            return out
        raise ExportError(f"{self.name}: {name} is not a set of string literals")

    def keys(self, name: str) -> list[str]:
        """The string keys of a module-level dict literal, sorted."""
        value = self.binding(name)
        if isinstance(value, ast.Dict) and value.keys and all(
                isinstance(k, ast.Constant) and isinstance(k.value, str) for k in value.keys):
            return sorted({k.value for k in value.keys})
        raise ExportError(f"{self.name}: {name} is not a dict literal with string keys")

    def function(self, name: str) -> ast.FunctionDef | ast.AsyncFunctionDef:
        found = [n for n in ast.walk(self.tree)
                 if isinstance(n, (ast.FunctionDef, ast.AsyncFunctionDef)) and n.name == name]
        if len(found) != 1:
            raise ExportError(f"{self.name}: {len(found)} functions named {name}, not one")
        return found[0]


# Methods that change a set or a dict in place.
_MUTATORS = ("add", "update", "setdefault", "pop", "popitem", "discard", "remove", "clear",
             "append", "extend", "insert",
             "__setitem__", "__delitem__", "intersection_update", "difference_update",
             "symmetric_difference_update")


def _changes_in_place(node: ast.AST, name: str) -> bool:
    """`NAME[…] = …`, `del NAME[…]`, or `NAME.add(…)`-style: the value changed, not rebound."""
    if isinstance(node, ast.Subscript) and isinstance(node.ctx, (ast.Store, ast.Del)):
        return isinstance(node.value, ast.Name) and node.value.id == name
    return (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
            and isinstance(node.func.value, ast.Name) and node.func.value.id == name
            and node.func.attr in _MUTATORS)


def _module_bindings(tree: ast.Module, name: str) -> list[ast.AST]:
    """Every place that binds or changes `name` in module scope — an assignment, an item or
    method that changes it in place, an import (a `*` one included), a def — or rebinds it from a
    function via `global`."""
    sites: list[ast.AST] = []

    def visit(node: ast.AST) -> None:
        for child in ast.iter_child_nodes(node):
            if isinstance(child, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                if child.name == name:
                    sites.append(child)
                # A function changes a module-level dict or set in place without `global`.
                sites.extend(n for n in ast.walk(child)
                             if (isinstance(n, ast.Global) and name in n.names)
                             or _changes_in_place(n, name))
                continue
            if isinstance(child, ast.Lambda):
                sites.extend(n for n in ast.walk(child) if _changes_in_place(n, name))
                continue
            if (isinstance(child, ast.Name) and child.id == name
                    and isinstance(child.ctx, (ast.Store, ast.Del))):
                sites.append(child)
            elif isinstance(child, (ast.Import, ast.ImportFrom)):
                sites.extend(child for a in child.names
                             if a.name == "*" or (a.asname or a.name.split(".")[0]) == name)
            elif _changes_in_place(child, name):
                sites.append(child)
            elif isinstance(child, (ast.ExceptHandler, ast.MatchAs, ast.MatchStar)) \
                    and child.name == name:
                sites.append(child)
            elif isinstance(child, ast.MatchMapping) and child.rest == name:
                sites.append(child)
            visit(child)

    visit(tree)
    return sites


def _body(function: ast.FunctionDef | ast.AsyncFunctionDef) -> list[ast.stmt]:
    body = function.body
    first = body[0] if body else None
    if (isinstance(first, ast.Expr) and isinstance(first.value, ast.Constant)
            and isinstance(first.value.value, str)):
        body = body[1:]
    return body


def _dict_literals(body: list[ast.stmt], where: str) -> list[ast.Dict]:
    """The outermost dict literals, in source order; an f-string is a string. A dict literal built
    inside a comprehension is refused: its keys would be a wire object nobody declared."""
    found: list[ast.expr] = []

    def visit(node: ast.AST) -> None:
        if isinstance(node, (ast.DictComp, ast.SetComp, ast.ListComp, ast.GeneratorExp,
                             ast.Lambda, ast.FunctionDef, ast.AsyncFunctionDef)):
            inner = next((n for n in ast.walk(node) if isinstance(n, ast.Dict)), None)
            if inner is not None:
                raise ExportError(f"{where}: the dict literal at line {inner.lineno} is built "
                                  "inside a comprehension or a nested function, which this does "
                                  "not read")
        if isinstance(node, (ast.Dict, ast.Set, ast.DictComp, ast.SetComp)):
            found.append(node)
            return
        if isinstance(node, ast.JoinedStr):
            return
        for child in ast.iter_child_nodes(node):
            visit(child)

    for statement in body:
        visit(statement)
    return [n for n in sorted(found, key=lambda n: (n.lineno, n.col_offset))
            if isinstance(n, ast.Dict)]


def _literal_keys(node: ast.Dict, where: str) -> set[str]:
    """A wire object's keys. A dict literal nested inside it is refused: its keys are a wire object
    of their own, which `WIRE_OBJECTS` has no way to name yet."""
    # An empty `{}` that is only an `or` fallback (`(m or {}).get(…)`) is not an object.
    fallbacks = {id(v) for n in ast.walk(node) if isinstance(n, ast.BoolOp) and isinstance(n.op, ast.Or)
                 for v in n.values if isinstance(v, ast.Dict) and not v.keys}
    nested = next((n for n in ast.walk(node)
                   if n is not node and isinstance(n, ast.Dict) and id(n) not in fallbacks), None)
    if nested is not None:
        raise ExportError(f"{where}: the dict literal at line {node.lineno} holds another at line "
                          f"{nested.lineno}, whose keys this does not export")
    keys = set()
    for k in node.keys:
        if not (isinstance(k, ast.Constant) and isinstance(k.value, str)):
            raise ExportError(f"{where}: a dict literal at line {node.lineno} has a key that is "
                              "not a string literal")
        keys.add(k.value)
    return keys


_KEY_METHODS = ("update", "setdefault", "pop", "popitem", "clear", "__setitem__", "__delitem__")


def _flat(target: ast.expr):
    if isinstance(target, (ast.Tuple, ast.List)):
        for e in target.elts:
            yield from _flat(e)
    elif isinstance(target, ast.Starred):
        yield from _flat(target.value)
    else:
        yield target


def _bolted_on(body: list[ast.stmt], where: str) -> dict[str, set[str]]:
    """`name["key"] = …` (also `name["key"]: T = …` and inside an unpacking), by target name. Any
    other way of changing a local's keys is refused: `del`, `+=` on a key, `.update()`,
    `.setdefault()`, `.pop()`, `|=`, or a `dict(…)` call."""
    out: dict[str, set[str]] = {}
    read: set[int] = set()
    nodes = [node for statement in body for node in ast.walk(statement)]
    for node in nodes:
        if isinstance(node, ast.Assign):
            targets = node.targets
        elif isinstance(node, ast.AnnAssign) and node.value is not None:
            targets = [node.target]
        else:
            continue
        for target in (t for whole in targets for t in _flat(whole)):
            if isinstance(target, ast.Subscript) and isinstance(target.value, ast.Name):
                read.add(id(target))
                if not (isinstance(target.slice, ast.Constant)
                        and isinstance(target.slice.value, str)):
                    raise ExportError(f"{where}: `{target.value.id}[…] =` at line "
                                      f"{node.lineno} has a key that is not a string literal")
                out.setdefault(target.value.id, set()).add(target.slice.value)
    for node in nodes:
        refused = None
        if (isinstance(node, ast.Subscript) and isinstance(node.ctx, (ast.Store, ast.Del))
                and not isinstance(node.value, ast.Name)):
            refused = "writes a key into something other than a local"
        elif (isinstance(node, ast.Subscript) and isinstance(node.value, ast.Name)
                and isinstance(node.ctx, (ast.Store, ast.Del)) and id(node) not in read):
            refused = f"changes a key of {node.value.id}"
        elif (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
              and isinstance(node.func.value, ast.Name) and node.func.attr in _KEY_METHODS):
            refused = f"calls {node.func.value.id}.{node.func.attr}()"
        elif isinstance(node, ast.Call) and (
                (isinstance(node.func, ast.Name) and node.func.id == "dict")
                or (isinstance(node.func, ast.Attribute) and isinstance(node.func.value, ast.Name)
                    and node.func.value.id == "dict")):
            refused = "builds a dict with dict()"
        elif isinstance(node, ast.AugAssign) and isinstance(node.op, ast.BitOr):
            refused = "merges into a local with |="
        elif (isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr)
              and any(isinstance(side, ast.Dict) for side in (node.left, node.right))):
            refused = "merges a dict literal with |"
        if refused:
            raise ExportError(f"{where}: line {node.lineno} {refused}, which this does not read")
    return out


# Calls that take a wire object without changing its keys: collecting it, measuring it, or turning
# it into text. Handing it to anything else is refused, because that call could add keys.
_READ_ONLY_METHODS = ("append", "extend", "insert", "add")
_READ_ONLY_FUNCTIONS = ("len", "list", "tuple", "str", "repr", "sorted", "dumps", "isinstance")


def _dotted(node: ast.expr) -> str | None:
    if isinstance(node, ast.Name):
        return node.id
    if isinstance(node, ast.Attribute):
        head = _dotted(node.value)
        return f"{head}.{node.attr}" if head else None
    return None


def _bases_reached(value: ast.expr, bases: tuple[tuple[str, str], ...]) -> list[str] | None:
    """Which declared bases `value` starts from: one per branch of a conditional, each matched by
    its exact call path (`introspect.scopes_payload`, receiver and all). None if any branch is
    something else."""
    if isinstance(value, ast.IfExp):
        body, orelse = _bases_reached(value.body, bases), _bases_reached(value.orelse, bases)
        return None if body is None or orelse is None else body + orelse
    if not isinstance(value, ast.Call):
        return None
    called = _dotted(value.func)
    return next(([base] for base, call in bases if call == called), None)


def _reads_only(call: ast.Call) -> bool:
    func = call.func
    if isinstance(func, ast.Attribute):
        return func.attr in _READ_ONLY_METHODS or func.attr in _READ_ONLY_FUNCTIONS
    return isinstance(func, ast.Name) and func.id in _READ_ONLY_FUNCTIONS


def wire_objects(modules: dict[str, _Module]) -> dict[str, list[str]]:
    by_builder: dict[tuple[str, str], list[tuple[str, tuple[int, ...], str | None]]] = {}
    for name, (module, builder, literals, target) in WIRE_OBJECTS.items():
        by_builder.setdefault((module, builder), []).append((name, literals, target))
    out: dict[str, list[str]] = {}
    for (module, builder), objects in by_builder.items():
        where = f"{module}:{builder}"
        body = _body(modules[module].function(builder))
        literals = _dict_literals(body, where)
        bolted_on = _bolted_on(body, where)
        claims = [i for _, idx, _ in objects for i in idx]
        if sorted(claims) != list(range(len(literals))):
            raise ExportError(f"{where} builds {len(literals)} dict literals, and WIRE_OBJECTS "
                              f"claims {sorted(claims)}: each must belong to exactly one wire "
                              "object. Say which wire object a new literal belongs to")
        targets = [t for _, _, t in objects if t is not None]
        if len(set(targets)) != len(targets) or set(bolted_on) - set(targets):
            raise ExportError(f"{where} bolts keys onto {sorted(bolted_on) or 'nothing'}, and "
                              f"WIRE_OBJECTS names {sorted(targets) or 'no local'}. Say which wire "
                              "object each belongs to")
        # Every reply the builder can return is one this reads: a literal it claims, a local it
        # declares, or None. And the only dict locals are the declared ones, so nothing else can
        # carry keys out of it.
        for node in (n for statement in body for n in ast.walk(statement)):
            if isinstance(node, ast.Return) and node.value is not None and not (
                    isinstance(node.value, ast.Dict)
                    or (isinstance(node.value, ast.Name) and node.value.id in targets)
                    or (isinstance(node.value, ast.Constant) and node.value.value is None)):
                raise ExportError(f"{where}: line {node.lineno} returns something that is neither "
                                  "a dict literal nor a declared local, which this does not read")
            if isinstance(node, (ast.Assign, ast.AnnAssign)) and isinstance(node.value, ast.Dict):
                whole = node.targets if isinstance(node, ast.Assign) else [node.target]
                for t in (t for w in whole for t in _flat(w)):
                    if isinstance(t, ast.Name) and t.id not in targets:
                        raise ExportError(f"{where}: line {node.lineno} keeps a dict literal in "
                                          f"{t.id}, which no wire object declares")
        function = modules[module].function(builder)
        params = function.args.posonlyargs + function.args.args + function.args.kwonlyargs + [
            a for a in (function.args.vararg, function.args.kwarg) if a]
        for name, _, target in objects:
            if target is None:
                continue
            bases = EXTENDS.get(name, ())
            if any(a.arg == target for a in params):
                raise ExportError(f"{where}: {target} is a parameter, whose keys this does not read")
            read: set[int] = set()
            for node in (n for statement in body for n in ast.walk(statement)):
                if not isinstance(node, (ast.Assign, ast.AnnAssign)):
                    continue
                whole = node.targets if isinstance(node, ast.Assign) else [node.target]
                hits = [t for w in whole for t in _flat(w)
                        if isinstance(t, ast.Name) and t.id == target]
                if not hits:
                    continue
                read.update(id(t) for t in hits)
                reached = _bases_reached(node.value, bases)
                from_base = reached is not None and sorted(reached) == sorted(b for b, _ in bases)
                if not (isinstance(node.value, ast.Dict) or from_base):
                    raise ExportError(f"{where}: line {node.lineno} gives {target} keys that are "
                                      "neither a dict literal nor exactly its declared bases' "
                                      f"({', '.join(c for _, c in bases) or 'none declared'})")
            if not read:
                raise ExportError(f"{where}: {target} is never assigned in the builder, so its "
                                  "base keys are not readable")
            for node in (n for statement in body for n in ast.walk(statement)):
                bound = None
                if isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
                    bound = node.id if id(node) not in read else None
                elif isinstance(node, (ast.Global, ast.Nonlocal)) and target in node.names:
                    bound = target
                elif isinstance(node, ast.MatchMapping):
                    bound = node.rest
                elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)):
                    bound = node.name
                elif isinstance(node, (ast.Import, ast.ImportFrom)):
                    bound = next((a.asname or a.name.split(".")[0] for a in node.names
                                  if (a.asname or a.name.split(".")[0]) == target), None)
                elif (isinstance(node, ast.Call) and not _reads_only(node) and any(
                        isinstance(a, ast.Name) and a.id == target
                        for a in [*node.args, *(k.value for k in node.keywords)])):
                    raise ExportError(f"{where}: line {node.lineno} hands {target} to a call that "
                                      "could change its keys, which this does not read")
                elif (isinstance(node, ast.BinOp) and isinstance(node.op, ast.BitOr)
                      and any(isinstance(side, ast.Name) and side.id == target
                              for side in (node.left, node.right))):
                    raise ExportError(f"{where}: line {node.lineno} merges {target} with |, which "
                                      "this does not read")
                elif isinstance(node, (ast.ExceptHandler, ast.MatchAs, ast.MatchStar)):
                    bound = node.name
                if bound == target:
                    raise ExportError(f"{where}: line {node.lineno} binds {target} in a form "
                                      "this does not read")
        for name, idx, target in objects:
            branches = [_literal_keys(literals[i], where) for i in idx]
            if any(b != branches[0] for b in branches[1:]):
                raise ExportError(f"{where}: the branches of {name} emit different keys")
            keys = set(branches[0]) if branches else set()
            if target is not None:
                keys |= bolted_on.get(target, set())
            if not keys:
                raise ExportError(f"{where}: {name} has no keys")
            out[name] = sorted(keys)
    return dict(sorted(out.items()))


def _lock_suffix(module: _Module) -> str:
    """The `<socket>.lock` suffix, from `path.with_name(path.name + ".lock")`."""
    found = []
    for node in ast.walk(module.tree):
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Attribute)
                and node.func.attr == "with_name" and len(node.args) == 1):
            arg = node.args[0]
            if (isinstance(arg, ast.BinOp) and isinstance(arg.op, ast.Add)
                    and isinstance(arg.left, ast.Attribute) and arg.left.attr == "name"
                    and isinstance(arg.right, ast.Constant) and isinstance(arg.right.value, str)):
                found.append(arg.right.value)
    if len(set(found)) != 1:
        raise ExportError(f"{module.name}: expected one `path.with_name(path.name + SUFFIX)` "
                          f"suffix, found {sorted(set(found)) or 'none'}")
    return found[0]


def _assigned_words(module: _Module, names: tuple[str, ...], within: str | None = None,
                    built_by: str | None = None) -> list[str]:
    """Every string literal assigned to one of `names` (also through `a, b = "x", …`), in the module
    or in one function of it, sorted. Every other binding of them is refused — `+=`, `:=`, a `for`
    or `with` target, an `except … as`, a `match` capture, a nested unpacking — because a word bound
    that way would reach the wire without reaching the contract."""
    scope = module.function(within) if within else module.tree
    if built_by:
        # The words leave `within` only through the `built_by(...)` it returns, and nothing else in
        # the module builds one with a word this cannot see.
        for node in ast.walk(scope):
            if isinstance(node, ast.Return) and not (
                    isinstance(node.value, ast.Call) and isinstance(node.value.func, ast.Name)
                    and node.value.func.id == built_by):
                raise ExportError(f"{module.name}: {within} returns at line {node.lineno} something "
                                  f"other than the {built_by}(…) it builds")
        inside = {id(n) for n in ast.walk(scope)}
        for node in ast.walk(module.tree):
            if not isinstance(node, ast.Call):
                continue
            callee = (node.func.id if isinstance(node.func, ast.Name)
                      else node.func.attr if isinstance(node.func, ast.Attribute) else None)
            if callee == built_by and any(k.arg is None for k in node.keywords):
                raise ExportError(f"{module.name}: line {node.lineno} builds a {built_by} from "
                                  "**keywords, which this does not read")
            if callee == built_by and id(node) not in inside:
                raise ExportError(f"{module.name}: line {node.lineno} builds a {built_by} outside "
                                  f"{within}, whose words this does not read")
            if callee in ("replace", "_replace") and any(k.arg in names for k in node.keywords):
                raise ExportError(f"{module.name}: line {node.lineno} copies a value with a new "
                                  f"{', '.join(k.arg for k in node.keywords if k.arg in names)}, "
                                  "which this does not read")
    if within:
        arguments = scope.args
        params = arguments.posonlyargs + arguments.args + arguments.kwonlyargs + [
            a for a in (arguments.vararg, arguments.kwarg) if a]
        if any(a.arg in names for a in params):
            raise ExportError(f"{module.name}: {within} takes a parameter named one of "
                              f"{', '.join(names)}, whose values this does not read")
    words = set()
    read: set[int] = set()
    assigned_here: set[str] = set()
    for node in ast.walk(scope):
        if isinstance(node, ast.AnnAssign) and node.value is not None:
            node = ast.Assign(targets=[node.target], value=node.value, lineno=node.lineno)
        if not isinstance(node, ast.Assign):
            continue
        for target in node.targets:
            pairs = [(target, node.value)]
            if isinstance(target, ast.Tuple):
                if not (isinstance(node.value, ast.Tuple)
                        and len(node.value.elts) == len(target.elts)):
                    if any(isinstance(t, ast.Name) and t.id in names for t in target.elts):
                        raise ExportError(f"{module.name}: line {node.lineno} unpacks into "
                                          f"{', '.join(names)} from something not a tuple literal")
                    continue
                pairs = list(zip(target.elts, node.value.elts))
            for t, v in pairs:
                if isinstance(t, ast.Name) and t.id in names:
                    if not (isinstance(v, ast.Constant) and isinstance(v.value, str)):
                        raise ExportError(f"{module.name}: line {node.lineno} assigns {t.id} "
                                          "something that is not a string literal")
                    read.add(id(t))
                    assigned_here.add(t.id)
                    words.add(v.value)
    for node in ast.walk(scope):
        # The same words written straight onto the wire: `{"state": "x"}` or `Capability(hyde="x")`.
        pairs = []
        if isinstance(node, ast.Dict):
            pairs = [(k.value, v) for k, v in zip(node.keys, node.values)
                     if isinstance(k, ast.Constant) and k.value in names]
        elif isinstance(node, ast.Call):
            pairs = [(k.arg, k.value) for k in node.keywords if k.arg in names]
        if (isinstance(node, ast.Subscript) and isinstance(node.ctx, ast.Store)
                and isinstance(node.slice, ast.Constant) and node.slice.value in names):
            raise ExportError(f"{module.name}: line {node.lineno} stores under "
                              f"[{node.slice.value!r}], which this does not read")
        if isinstance(node, ast.Attribute) and isinstance(node.ctx, ast.Store) \
                and node.attr in names:
            raise ExportError(f"{module.name}: line {node.lineno} sets .{node.attr}, which this "
                              "does not read")
        if (isinstance(node, ast.Call) and isinstance(node.func, ast.Name)
                and node.func.id == "setattr"):
            raise ExportError(f"{module.name}: line {node.lineno} calls setattr(), which this does "
                              "not read")
        for key, v in pairs:
            if isinstance(v, ast.Constant) and isinstance(v.value, str):
                words.add(v.value)
            elif not ((isinstance(v, ast.Name) and v.id in assigned_here)
                      or (isinstance(v, ast.Constant) and v.value is None)):
                raise ExportError(f"{module.name}: line {v.lineno} puts on the wire under {key} "
                                  "something that is neither a string literal nor the local "
                                  "this reads")
    for node in ast.walk(scope):
        bound = None
        if isinstance(node, ast.Name) and isinstance(node.ctx, (ast.Store, ast.Del)):
            bound = node.id if id(node) not in read else None
        elif isinstance(node, (ast.ExceptHandler, ast.MatchAs, ast.MatchStar)):
            bound = node.name
        elif isinstance(node, ast.MatchMapping):
            bound = node.rest
        elif isinstance(node, (ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef)) \
                and node is not scope:
            bound = node.name
        elif isinstance(node, (ast.Import, ast.ImportFrom)):
            bound = next((a.asname or a.name.split(".")[0] for a in node.names
                          if (a.asname or a.name.split(".")[0]) in names), None)
        elif isinstance(node, (ast.Global, ast.Nonlocal)):
            bound = next((n for n in node.names if n in names), None)
        if bound in names:
            raise ExportError(f"{module.name}: line {node.lineno} binds {bound} in a form this "
                              "does not read")
    if not words:
        raise ExportError(f"{module.name}: no string assigned to any of {', '.join(names)}")
    return sorted(words)


def _printable(module: _Module) -> list[list[int]]:
    """The code points a one-line quoted YAML scalar may hold, as `[first, last]` ranges: every code
    point the pattern `_UNSAFE` compiles does NOT match. The pattern is read as a literal and
    compiled here, so whatever class syntax it uses is read the way the engine's `re` reads it, and
    no engine code runs."""
    value = module.binding("_UNSAFE")
    if not (isinstance(value, ast.Call) and _dotted(value.func) == "re.compile"
            and len(value.args) == 1 and not value.keywords
            and isinstance(value.args[0], ast.Constant) and isinstance(value.args[0].value, str)):
        raise ExportError(f"{module.name}: _UNSAFE is not re.compile of one string literal")
    try:
        ranges = _kept_ranges(value.args[0].value)
    except re.error as e:
        raise ExportError(f"{module.name}: _UNSAFE does not compile: {e}") from None
    if not ranges:
        raise ExportError(f"{module.name}: _UNSAFE refuses every character")
    return [list(r) for r in ranges]


@functools.lru_cache(maxsize=8)
def _kept_ranges(pattern: str) -> tuple[tuple[int, int], ...]:
    """The code points `pattern` does not match, as ranges. Scanning all of Unicode takes most of a
    second, so it is done once per pattern per process: an export reads the same rule every time."""
    unsafe = re.compile(pattern)
    ranges: list[list[int]] = []
    for cp in range(0x110000):
        if unsafe.fullmatch(chr(cp)):
            continue
        if ranges and ranges[-1][1] == cp - 1:
            ranges[-1][1] = cp
        else:
            ranges.append([cp, cp])
    return tuple((lo, hi) for lo, hi in ranges)


def _one(text: str, pattern: str, what: str) -> str:
    values = set(re.findall(pattern, text))
    if len(values) != 1:
        raise ExportError(f"EXPERIMENTS.md: expected one {what}, found {sorted(values) or 'none'}")
    return values.pop()


def _tiers(root: Path) -> dict:
    """The measured tiers a client may show, from the sections of `EXPERIMENTS.md` that hold them."""
    try:
        text = (root / "EXPERIMENTS.md").read_text(encoding="utf-8")
    except (OSError, ValueError) as e:
        raise ExportError(f"cannot read EXPERIMENTS.md: {e}") from None
    try:
        cases = int(_one(text, r"Measured at (\d+) cases", "case count"))
        tiers = {
            "case_count": cases,
            "ceiling": float(_one(text, r"\(shipped ceiling\)\s+(\d+\.\d+)", "shipped ceiling")),
            "floor": float(_one(text, r"nothing installed\. (\d+\.\d+)", "floor")),
        }
    except ValueError as e:
        raise ExportError(f"EXPERIMENTS.md: a tier number cannot be read: {e}") from None
    if not re.search(rf"(?<!\d){cases}-case cohort", text):
        raise ExportError(f"EXPERIMENTS.md has no {cases}-case cohort section")
    return tiers


def export(root: Path = ROOT) -> dict:
    """The contract the engine tree at `root` states. Raises ExportError."""
    try:
        return _export(root)
    except RecursionError:
        raise ExportError("a construct nests too deeply to read") from None


def _export(root: Path) -> dict:
    if sys.version_info < MINIMUM_PYTHON:
        raise ExportError(f"needs Python {'.'.join(map(str, MINIMUM_PYTHON))}, the engine's own; "
                          f"this is {sys.version.split()[0]}")
    m = {name: _Module(root, name) for name in MODULES}
    wire, spine, classes, stack = m["wire.py"], m["spine.py"], m["classes.py"], m["stack.py"]
    retriever = m["retrieve/retriever.py"]
    manifest = _Module(root, "engine-manifest.py", base="tools")
    return {
        "wire": {
            "version": wire.integer("VERSION"),
            "min_version": wire.integer("MIN_VERSION"),
            "header": wire.string("HEADER"),
            "mismatch": wire.integer("MISMATCH"),
            "unstated": wire.integer("UNSTATED"),
        },
        "socket": {
            "default": m["local_socket.py"].string("DEFAULT_SOCKET"),
            "lock_suffix": _lock_suffix(m["local_socket.py"]),
        },
        "cli": {"declined_exit": m["refresh.py"].integer("EX_DECLINED")},
        # The note format a writer must produce for this engine to index it, as a range
        # (`spine.NOTES_VERSION`): an attached client writes notes, and this engine indexes them.
        "notes": {"version": spine.integer("NOTES_VERSION"),
                  "min_version": spine.integer("NOTES_MIN_VERSION")},
        "spine": {
            "statuses": spine.members("STATUSES"),
            "included_statuses": spine.members("INCLUDED_STATUSES"),
            "doc_types": spine.members("DOC_TYPES"),
            "confidences": spine.members("CONFIDENCES"),
            "declarable_confidences": spine.members("DECLARABLE_CONFIDENCES"),
            "stored_confidences": spine.members("STORED_CONFIDENCES"),
            "unstated_confidence": spine.string("UNSTATED_CONFIDENCE"),
            "unjudged_confidence": spine.string("UNJUDGED_CONFIDENCE"),
        },
        "classes": {
            "policies": classes.keys("POLICIES"),
            "excluded": classes.members("EXCLUDED_CLASSES"),
        },
        "retrieval": {
            "arms": stack.members("ARMS"),
            "arm_wired": stack.string("ARM_WIRED"),
            "arm_unavailable": stack.string("ARM_UNAVAILABLE"),
            "arm_off": stack.string("ARM_OFF"),
            "arm_states": _assigned_words(retriever, ("hyde", "reranker", "embedder_state"),
                                          "_capability", built_by="Capability"),
            "engine_health_states": _assigned_words(m["render.py"], ("state",), "engine_health"),
            "unmeasured_reasons": retriever.keys("UNMEASURED_REASONS"),
        },
        "refresh": {"outcomes": m["refresh_state.py"].keys("OUTCOMES")},
        # What a one-line quoted frontmatter scalar may hold; every other character becomes a space.
        # A writer that keeps a different set writes notes this engine reads differently.
        "yaml": {"printable": _printable(m["markdown/yaml_scalar.py"])},
        # The file at an engine root that says what the engine there is and what a client may run
        # (`tools/engine-manifest.py`), and the features it may name.
        "engine_manifest": {"file": manifest.string("NAME"),
                            "features": manifest.members("FEATURES")},
        "payloads": wire_objects(m),
        "extends": {name: sorted(b for b, _ in bases) for name, bases in sorted(EXTENDS.items())},
        "tiers": _tiers(root),
    }


def render(contract: dict) -> str:
    """The committed bytes: stable, so a re-export of an unchanged tree changes nothing."""
    try:
        return json.dumps(contract, indent=2, ensure_ascii=False, allow_nan=False) + "\n"
    except ValueError as e:
        raise ExportError(f"the export is not valid JSON: {e}") from None


def main(argv: list[str]) -> int:
    ap = argparse.ArgumentParser(description=(__doc__ or "").split("\n\n")[0])
    ap.add_argument("--root", type=Path, default=ROOT, help="the engine tree to read")
    args = ap.parse_args(argv)
    try:
        text = render(export(args.root))
    except ExportError as e:
        print(f"export-contract: {e}", file=sys.stderr)
        return 2
    try:
        sys.stdout.buffer.write(text.encode("utf-8"))
        # Flushed here, inside the handler: left to interpreter shutdown, a closed pipe would exit
        # 120 with no message instead of 2 with one.
        sys.stdout.buffer.flush()
    except OSError as e:
        print(f"export-contract: cannot write the export: {e}", file=sys.stderr)
        # What is still buffered would fail again at shutdown and turn this 2 into 120; the
        # standard remedy is to point stdout at the null device.
        try:
            os.dup2(os.open(os.devnull, os.O_WRONLY), sys.stdout.fileno())
        except (OSError, ValueError):
            pass
        return 2
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
