"""Differential testing: the real `blob_lifecycle.gc_plan` against the Lean model.

    python run.py agree --cases 10000       # faithful spellings: the two must agree on every case
    python run.py agree block_comment       # one spelling only: a minimal world on which they differ
    python run.py agree --mutant six-days   # a guard broken on purpose: the harness must notice
    python run.py survey --cases 3000       # every spelling: tally each disagreement by cause
    python run.py unsafe block_comment      # a minimal world on which the code removes a named blob

Runs are derandomized, so the same command gives the same counts. A script, not a module: it
refuses to be imported, because importing it would point `HOME` at a scratch folder.

Every check is an explicit `raise`, never an `assert`, so `python -O` cannot turn the harness into
one that passes without testing anything.

Each case gets its own temporary folder, removed when the case ends. That folder holds the engine
home (`~/.substrate`), the config, the registry, the store and the vaults. Nothing tracked is
written: no bytecode is written, and Hypothesis's cache goes to the gitignored `harness/.hypothesis`.
"""

from __future__ import annotations

import argparse
import collections
import contextlib
import copy
import json
import linecache
import os
import subprocess
import sys
import tempfile
from pathlib import Path

if __name__ != "__main__":
    raise ImportError("harness/run.py is a script: run it, do not import it")

sys.dont_write_bytecode = True
HERE = Path(__file__).resolve().parent
REPO = HERE.parents[2]
LEAN_BIN = HERE.parent / "lean" / ".lake" / "build" / "bin" / "blobgc"

_RUN_ROOT = Path(os.path.realpath(tempfile.mkdtemp(prefix="blobgc-diff-",
                                                   dir=os.environ.get("BLOBGC_TMP"))))
# `scopes.DEFAULT_REGISTRY` is `Path.home()` at import. Point it at a scratch home before the import,
# and patch it per case besides, so that no case can ever reach the real `~/.substrate`.
os.environ["HOME"] = str(_RUN_ROOT / "home")
os.environ.pop("SUBSTRATE_REGISTRY", None)
os.environ["HYPOTHESIS_STORAGE_DIRECTORY"] = str(HERE / ".hypothesis")
sys.path.insert(0, str(REPO / "substrate"))
sys.path.insert(0, str(HERE))

try:
    from hypothesis import HealthCheck, given, settings

    import world as W
    from substrate import blob_lifecycle as life
    from substrate import blobs, scopes
except BaseException:
    with contextlib.suppress(OSError):
        os.rmdir(_RUN_ROOT)
    raise


class HarnessBug(Exception):
    """The harness, not the code or the model, is wrong. Never caught: a finding cannot hide it."""


class Finding(Exception):
    """The code and the model disagree, or the code removes a named blob. Hypothesis shrinks on it."""


if not str(scopes.DEFAULT_REGISTRY).startswith(str(_RUN_ROOT)):
    with contextlib.suppress(OSError):
        os.rmdir(_RUN_ROOT)
    raise HarnessBug(f"the default registry {scopes.DEFAULT_REGISTRY} is outside the scratch home")


# ---------------------------------------------------------------- the two planners

class Lean:
    def __init__(self) -> None:
        self.p = subprocess.Popen([str(LEAN_BIN)], stdin=subprocess.PIPE, stdout=subprocess.PIPE,
                                  text=True)

    def plan(self, w: W.World) -> dict:
        self.p.stdin.write(json.dumps(w.to_json()) + "\n")
        self.p.stdin.flush()
        out = json.loads(self.p.stdout.readline())
        if "error" in out:
            raise HarnessBug(f"the model could not read the world: {out['error']}")
        if "refuse" in out:
            return {"refuse": out["refuse"]}
        return {k: sorted(v) for k, v in out.items()}


def _refusal(msg: str) -> str:
    for needle, kind in (("no registered vault", "noVault"), ("could not be read", "incomplete"),
                         ("no longer lists", "unregistered")):
        if needle in msg:
            return kind
    return f"other: {msg[:200]}"


def python_plan(w: W.World, lay: W.Layout) -> tuple[dict, life.Scan]:
    W.write_world(w, lay)
    store = lay.store
    blobs.config_path = lambda: lay.home / ".substrate" / blobs.CONFIG_NAME
    blobs.default_root = lambda: store
    scopes.DEFAULT_REGISTRY = lay.default_registry()
    src = lay.root / "src"
    src.mkdir()
    for s, mtime in w.blobs:
        (src / f"b{s}").write_bytes(W.blob_bytes(s))
        put = blobs.put(src / f"b{s}", store=store)
        if put.outcome != "stored" or put.checksum != W.sha_hex(s):
            raise HarnessBug(f"storing blob {s} gave {put}")
        os.utime(put.path, (mtime, mtime))
    if w.tombstones:
        d = blobs._ensure(store, "tombstones")
        for s in w.tombstones:
            (d / W.sha_hex(s)).write_text("forgotten = test\n")
    if w.ledger:
        blobs.record_vaults(store, {str(lay.vault(i)) for i in w.ledger})

    registry = None if w.default else lay.other_registry()
    by_sha = {W.sha_hex(i): i for i in range(W.N_SHA)}
    by_vault = {str(lay.vault(i)): i for i in range(len(w.vaults) + 4)}
    # The scan for attribution runs first, on exactly the state `gc_plan` will see. `scan` neither
    # reads nor writes the ledger; `gc_plan` is the only one of the two that writes it.
    scan = life.scan(registry)
    try:
        plan = life.gc_plan(registry, store, now=float(w.now),
                            retire=[lay.vault(i) for i in w.retire])
    except life.Refused as e:
        return {"refuse": _refusal(str(e))}, scan
    # Read straight from the file: `blobs.seen_vaults` is what a mutant may replace.
    ledger = store / blobs.LEDGER
    seen = json.loads(ledger.read_text("utf-8")) if ledger.exists() else []
    return {
        "remove": sorted(by_sha[c] for c in plan.remove),
        "recent": sorted(by_sha[c] for c in plan.recent),
        "vaults": sorted(by_vault[str(v)] for v in plan.vaults),
        "ledger": sorted(by_vault[v] for v in seen),
    }, scan


# ---------------------------------------------------------------- where a disagreement comes from

def check_spelling(w: W.World) -> None:
    """The YAML on disk must say what the abstract world says."""
    for v in w.vaults:
        for n in v.notes:
            if not n.readable:
                continue
            got = W.yaml_fields(n)
            want = {W.KEYS[f.key]: W.expected_yaml(f) for f in n.fields if f.loc == "front"}
            if got != want:
                raise HarnessBug(f"YAML reads {got}, the world says {want}\n" + W.note_text(n))


def _read(w: W.World, lay: W.Layout, scan: life.Scan):
    read = {str(p) for p in scan.vaults}
    for v in w.vaults:
        if str(lay.vault(v.id)) in read:
            for k, n in enumerate(v.notes):
                if n.readable:
                    yield lay.vault(v.id) / "notes" / f"n{k}.md", n


def per_field(w: W.World, lay: W.Layout, scan: life.Scan) -> list[tuple]:
    """For every field of every readable note the scan read, how the scan's reading differs from
    the model's: a reference missed or added, a malformed claim missed or added. A malformed claim
    is matched to its field by key, since the scan names the key in its message."""
    out = []
    for path, n in _read(w, lay, scan):
        p_refs = {c for c, rs in scan.refs.items() if any(r.note == path for r in rs)}
        for f in n.fields:
            flagged = any(m.startswith(f"{path}: {W.KEYS[f.key]} ") for m in scan.malformed)
            if {W.sha_hex(c) for c in f.refs()} - p_refs:
                out.append((f.style, "scan misses a reference"))
            if f.malformed() and not flagged:
                out.append((f.style, "scan misses a malformed claim"))
            if f.loc == "front" and not f.malformed() and flagged:
                out.append((f.style, "scan reports a malformed claim the field does not make"))
        if p_refs - {W.sha_hex(c) for c in n.refs()}:
            out.append(("-", "scan reads a reference the note does not carry"))
    return out


def protected(w: W.World) -> set[int]:
    """The vaults `never_deletes_a_referenced_blob` protects: every vault reachable through
    `inherits` from a registered one, and every remembered vault that was not retired. Taken from
    the world, not from the code's scan, so a scan that skips a vault cannot hide a removal."""
    manifests = {v.id: v.manifest or [] for v in w.vaults}
    seen, todo = set(), list(w.registry)
    while todo:
        v = todo.pop()
        if v not in seen:
            seen.add(v)
            todo += manifests.get(v, [])
    return seen | (set(w.ledger) - set(w.retire))


def unsafe_removals(w: W.World, py: dict) -> list[int]:
    """Blobs the code plans to remove that a note in a protected vault names, in the model's
    reading. Unreadable notes count too: a note the code could not read still names its blobs."""
    keep = protected(w)
    named = {c for v in w.vaults if v.id in keep for n in v.notes for c in n.refs()}
    return sorted(set(py.get("remove", [])) & named)


def verdict(model: dict, py: dict) -> str | None:
    if model == py:
        return None
    if "refuse" in model and "refuse" in py:
        return f"refuse {model['refuse']} vs {py['refuse']}"
    if "refuse" in model:
        return f"model refuses ({model['refuse']}), code plans"
    if "refuse" in py:
        return f"code refuses ({py['refuse']}), model plans"
    extra = sorted(set(py["remove"]) - set(model["remove"]))
    if extra:
        return f"code removes blobs the model keeps: {extra}"
    return "plans differ: " + ", ".join(k for k in model if model[k] != py[k])


def run_case(w: W.World) -> tuple[dict, dict, list[tuple], list[int]]:
    check_spelling(w)
    with tempfile.TemporaryDirectory(dir=_RUN_ROOT) as d:
        lay = W.Layout(Path(os.path.realpath(d)))
        model = LEAN.plan(w)
        py, scan = python_plan(w, lay)
        fields = per_field(w, lay, scan) if model != py else []
        unsafe = unsafe_removals(w, py)
    return model, py, fields, unsafe


def faithful_twin(w: W.World) -> W.World:
    """The same world with every hostile spelling replaced by a faithful one."""
    twin = copy.deepcopy(w)
    for v in twin.vaults:
        for n in v.notes:
            for f in n.fields:
                if f.style in W.FRONT_HOSTILE:
                    f.style = "scalar" if f.style in W.SINGLE else "block"
    return twin


def describe(w: W.World) -> str:
    lines = [json.dumps(w.to_json())]
    for v in w.vaults:
        for k, n in enumerate(v.notes):
            if n.readable and n.fields:
                lines.append(f"--- vault v{v.id} notes/n{k}.md ---")
                lines.append(W.note_text(n))
    return "\n".join(lines)


def report(model, py, fields, unsafe, w) -> str:
    return (f"{verdict(model, py)}\nmodel {model}\ncode  {py}\n{sorted(set(fields))}\n"
            + (f"SAFETY: the code plans to remove {unsafe}, which a note names\n" if unsafe else "")
            + describe(w))


# ---------------------------------------------------------------- mutants

def _lenient_chain():
    from substrate import vault as V
    life._vault.resolve_vaults = lambda p: tuple(
        V.VaultRef(name=x.name, path=x) for x in V.chain_best_effort(p))


def _no_absent_guard():
    """The ledger reads as empty to the line that computes `absent`, and only to it: the ledger
    write and everything else see the real one."""
    real = blobs.seen_vaults

    def seen(store):
        caller = sys._getframe(1)
        line = linecache.getline(caller.f_code.co_filename, caller.f_lineno)
        return set() if "absent" in line else real(store)

    blobs.seen_vaults = seen


def _six_days():
    life.MIN_AGE_DAYS = 6


def _audio_not_a_key():
    import re
    life._KEY_LINE = re.compile(r"""^\s*["']?(source_sha256|raw_sha256)["']?\s*:(.*)$""")
    life._INLINE = re.compile(
        r"""(?:source_sha256|raw_sha256)["']?\s*:\s*\[?\s*["']?([0-9a-fA-F]{64})""")


# Each is a plausible regression of one guard the planner has, applied to the real code in this
# process only.
MUTANTS = {"lenient-chain": _lenient_chain, "no-absent-guard": _no_absent_guard,
           "six-days": _six_days, "audio-not-a-key": _audio_not_a_key}


SETTINGS = dict(deadline=None, database=None, derandomize=True,
                suppress_health_check=list(HealthCheck), print_blob=True)


def main() -> int:
    ap = argparse.ArgumentParser()
    ap.add_argument("mode", choices=["agree", "survey", "unsafe"])
    ap.add_argument("style", nargs="?", choices=W.FRONT_FAITHFUL + W.FRONT_HOSTILE,
                    help="agree, unsafe: generate frontmatter in this spelling only")
    ap.add_argument("--cases", type=int, default=2000)
    ap.add_argument("--dump", default=None, help="survey: one example per cause, into this folder")
    ap.add_argument("--mutant", choices=sorted(MUTANTS), default=None,
                    help="break the real planner on purpose, to show the harness notices")
    a = ap.parse_args()
    if a.mutant:
        MUTANTS[a.mutant]()
    label = a.style or "faithful spellings"

    if a.mode == "agree":
        n = collections.Counter()

        @settings(max_examples=a.cases, **SETTINGS)
        @given(W.world((a.style,) if a.style else W.FRONT_FAITHFUL))
        def agree(w):
            model, py, fields, unsafe = run_case(w)
            n["model " + (f"refuses {model['refuse']}" if "refuse" in model else
                          "plans" + (" a removal" if model["remove"] else " nothing"))] += 1
            if model != py:
                raise Finding(report(model, py, fields, unsafe, w))

        try:
            agree()
        except Finding as e:
            print(f"agree {label}: minimal disagreement\n{e}")
            return 1
        print(f"agree {label}: {sum(n.values())} cases, no disagreement")
        for k, v in sorted(n.items()):
            print(f"  {v:6d}  {k}")
        return 0

    if a.mode == "unsafe":
        ran = [0]

        @settings(max_examples=a.cases, **SETTINGS)
        @given(W.world((a.style,) if a.style else W.FRONT_FAITHFUL + W.FRONT_HOSTILE))
        def unsafe(w):
            ran[0] += 1
            model, py, fields, hit = run_case(w)
            if hit:
                raise Finding(report(model, py, fields, hit, w))

        try:
            unsafe()
        except Finding as e:
            print(f"unsafe {a.style or 'any spelling'}: minimal safety violation\n{e}")
            return 1
        print(f"unsafe {a.style or 'any spelling'}: {ran[0]} cases, no safety violation")
        return 0

    tally: collections.Counter = collections.Counter()
    causes: collections.Counter = collections.Counter()
    total, safety, persists = [0], [0], [0]

    @settings(max_examples=a.cases, **SETTINGS)
    @given(W.world(W.FRONT_FAITHFUL + W.FRONT_HOSTILE))
    def survey(w):
        total[0] += 1
        model, py, fields, unsafe = run_case(w)
        v = verdict(model, py)
        if not v:
            return
        tally[v.split(":")[0]] += 1
        safety[0] += bool(unsafe)
        # Causal check: with every hostile spelling made faithful, the disagreement must go away.
        tm, tp, *_ = run_case(faithful_twin(w))
        persists[0] += tm != tp
        for cause in set(fields) or {("?", "no per-field cause")}:
            causes[cause] += 1
            if a.dump and causes[cause] == 1:
                name = "-".join(cause).replace(" ", "_").replace(",", "+")
                (Path(a.dump) / f"{name}.txt").write_text(
                    report(model, py, fields, unsafe, w) + "\n", "utf-8")

    survey()
    print(f"survey: {total[0]} cases, {sum(tally.values())} disagreements, {safety[0]} of them "
          f"a code plan removing a blob a note names, {persists[0]} still disagreeing with every "
          "spelling made faithful")
    for k, v in tally.most_common():
        print(f"  {v:6d}  {k}")
    print("by cause (spelling, what the scan did):")
    for (style, what), v in causes.most_common():
        print(f"  {v:6d}  {style:24s} {what}")
    return 0


if __name__ == "__main__":
    LEAN = None
    try:
        LEAN = Lean()
        sys.exit(main())
    finally:
        if LEAN is not None:
            LEAN.p.stdin.close()
            LEAN.p.wait()
        # Every case folder is already gone; this is the empty run folder that held them.
        with contextlib.suppress(OSError):
            os.rmdir(_RUN_ROOT)
