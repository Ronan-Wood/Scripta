"""`Stack.unavailable_arms` recovers each arm's NAME from `unavailable`'s prose, by its leading
token, and a client's `health.arms` is built from it. So every entry must lead with its arm, and
the one spelling that guarantees it is `stack._unreachable`. The first test checks the output; the
second checks this package's own source, where a rule about how the engine is written belongs —
a client used to check both by reading this source."""

from __future__ import annotations

import ast
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate import stack  # noqa: E402

STACK_SOURCE = Path(stack.__file__).read_text(encoding="utf-8")


@pytest.mark.parametrize("arm", stack.ARMS)
@pytest.mark.parametrize("cloud", [False, True])
def test_an_unavailable_entry_leads_with_its_arm(arm, cloud):
    entry = stack._unreachable(arm, "some-model", "http://127.0.0.1:1", cloud=cloud)
    assert entry.split(" ", 1)[0] == arm
    assert stack.Stack(unavailable=(entry,)).unavailable_arms == (arm,)


def test_every_unavailable_entry_is_built_by_the_one_spelling():
    """A hand-built `unavailable.append(f"…")` would not be covered by the test above."""
    appends = [n for n in ast.walk(ast.parse(STACK_SOURCE))
               if isinstance(n, ast.Call) and isinstance(n.func, ast.Attribute)
               and n.func.attr == "append" and isinstance(n.func.value, ast.Name)
               and n.func.value.id == "unavailable"]
    assert len(appends) == len(stack.ARMS), "expected one append per arm"
    built = sorted(a.args[0].args[0].value for a in appends
                   if a.args and isinstance(a.args[0], ast.Call)
                   and getattr(a.args[0].func, "id", None) == "_unreachable"
                   and a.args[0].args and isinstance(a.args[0].args[0], ast.Constant))
    assert built == sorted(stack.ARMS), "an `unavailable` entry is built other than by _unreachable"
