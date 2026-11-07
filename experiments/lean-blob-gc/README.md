# A Lean model of `substrate blobs gc --unreferenced`, checked against the real planner

**Result: the planning logic is proved safe, but the reference scan under it has a hole.** A note
can name a blob in valid YAML that the scan does not read. `gc_plan` then lists that blob for
removal once it is older than seven days. The repro is
[`harness/repro_hidden_reference.py`](harness/repro_hidden_reference.py). Nothing is fixed here;
the fix is for a normal PR.

This is a side experiment in the style of AWS Cedar: a Lean model with proofs, plus randomized
differential testing of the production code against the model. It runs in no CI and changes
nothing under `substrate/`.

## What is proved

The model is [`lean/BlobGc/Model.lean`](lean/BlobGc/Model.lean): `gcPlan : World → Result`, a pure
function from registered vaults, notes, the store, the ledger and `--retire-vault` to a refusal or
a plan. The proofs are in [`lean/BlobGc/Proofs.lean`](lean/BlobGc/Proofs.lean). None uses `sorry`,
and `lake env lean Axioms.lean` shows only Lean's standard axioms (`propext`, `Quot.sound`,
`Classical.choice`).

| theorem | says |
|---|---|
| `never_deletes_a_referenced_blob` | If there is a plan, then for every vault in a registered scope's inheritance chain, and every vault the ledger remembers that was not retired: every note in it was read whole (readable, with no malformed frontmatter claim), and none names a blob the plan removes. |
| `plan_safe` | Every blob in a plan is held and older than seven days, and no note in any vault the plan read names it. |
| `plan_reads_everything` | A plan read every vault reachable through `inherits` from a registered scope, and every remembered vault that was not retired. |
| `plan_removes_what_it_should` | The converse of safety: a plan removes every held blob that is old and that no note it read names. |
| `a_plan_exists` | A concrete world on which the planner removes a blob, so the safety theorems do not hold merely because the planner always refuses. |
| `malformed_reference_refuses`, `unreadable_note_refuses`, `missing_vault_refuses` | Any of these in any registered chain yields `.refuse .incomplete`, never a plan: a malformed frontmatter reference, an unreadable note, or a missing inherited vault (the moved core-vault blocker from #84's review). |
| `empty_registry_refuses` | With nothing registered, the result is `.refuse .noVault`. |
| `tombstones_irrelevant` | True by construction, since no definition reads tombstones. That the real code also ignores them is checked by the differential, which writes tombstones. |

The chain is computed by a bounded closure that is then *checked*: it must be closed under
`inherits`, every vault must exist, every registered vault must have a manifest, and it must be
acyclic. If any check fails, the planner refuses. So no proof depends on the closure being
complete. Were it incomplete, the differential would see the model refusing where the code plans.

## What was tested

[`harness/run.py`](harness/run.py) generates small worlds with Hypothesis
([`harness/world.py`](harness/world.py)): up to four vaults plus two that are named but absent,
inheritance with cycles, notes, the store, tombstones, a ledger and retirements. Each world runs
two ways:

- The real `gc_plan` runs in a temporary folder that holds its own `~/.substrate`, config,
  registry and store.
- The compiled Lean model reads it as JSON.

Refusal kinds and plans (removed, recent, vaults read, the ledger after) must match. PyYAML must
read every note's frontmatter as the abstract world says, or the harness stops with a `HarnessBug`
rather than reporting a finding. Runs are derandomized, so they are reproducible. Every check is an
explicit `raise`, so they hold under `python -O`.

| run | cases | result |
|---|---|---|
| `agree`: every spelling the scan's docstring says it reads | 10,000 | **no disagreement**: 1,885 plans that remove something, 3,664 that remove nothing, 4,451 refusals (2,827 incomplete, 1,548 unregistered, 76 no vault) |
| `agree --mutant …`: four planted regressions (lenient chain, no absent-vault guard, 6-day guard, `audio_sha256` not a key) | 3,000 each | each caught, with the disagreement each guard predicts |
| `survey`: those spellings plus eight hostile but valid YAML ones | 3,000 | 407 disagreements, 33 of them a code plan removing a blob a note names. In each, rewriting every hostile spelling to a faithful one makes the disagreement go away (0 remain), so each is caused by its spelling |
| `unsafe <spelling>`: search for a code plan that removes a blob named by a note in a vault the headline theorem protects (taken from the world, not from the code's scan) | 1,500 each | found for the five spellings in rows 1–3 below; none for `nextline`, `trailing_comment` or `folded` |
| `agree nextline` | 1,500 | row 5: an uppercase checksum on the line after the key is not flagged |

The faithful spellings are:
- a scalar: bare, `'`-quoted or `"`-quoted;
- a flow list, unwrapped or wrapped across lines;
- a block list, indented or flush;
- a quoted key, a BOM, or CRLF line endings;
- Obsidian `tags`/`aliases` properties before or after the fields;
- in the body: a key line, a flow list, a block list or an inline `{key: …}`.

## Disagreements found

Every disagreement is a code bug. In each one PyYAML reads the frontmatter the way the model does,
so none is a model bug.

| # | spelling (valid YAML) | what the code does | verdict |
|---|---|---|---|
| 1 | a blank line after `source_sha256:`, or between two `- item`s | every item after the blank line is dropped, and the blob is **planned for removal** | **code bug, safety** |
| 2 | a `# comment` line after the key, or between two items | the same | **code bug, safety** |
| 3 | a `# comment` line between the key and a next-line value | the value is dropped, and the blob is **planned for removal** | **code bug, safety** |
| 4 | a whole frontmatter written as one flow mapping, `{title: t, audio_sha256: [a, b]}` | only `a` is kept alive and nothing is flagged. Checked by hand; the generator does not produce this | **code bug, safety** |
| 5 | a non-checksum value on the line after the key (`source_sha256:` then `  TODO`) | not flagged malformed, so the code plans where the spec says refuse. `_INLINE` still keeps a checksum there alive. Junk under a commented list is also missed, but that list is case 2 | code bug, refusal gap |
| 6 | a trailing comment, `source_sha256: <c>  # pdf` | flagged malformed, so the code refuses | code over-refuses (safe direction) |
| 7 | a folded scalar, `source_sha256: >-` then the checksum | flagged malformed, and the code refuses | code over-refuses (safe direction) |

**Cause of 1–3:** for a key whose value is empty on its own line, `_text_refs` reads the `- item`
lines after it and stops at the first line that is not one, so any non-item line ends the list.
`_INLINE`, the backstop, crosses the newline, but not a `#`, and not the `-` of an item.

**Cause of 4:** the same backstop reads only the first checksum after `[`.

Obsidian's Properties editor writes neither comments nor blank lines, but a hand edit or another
tool can. The scan exists so that a note's spelling can never make its original collectable.

The minimal shrunk world for case 2 has one vault, one note, and one blob older than seven days:

```yaml
---
title: t
source_sha256:
  # the originals
  - e769af2e03f5226ab4af05db1842e4ea0d40468fd5a5d6875aaf35529cc8809d
---
```

Three harness bugs were found and fixed along the way, and none is a finding:
- an oracle expectation for empty values;
- attribution that counted vaults the scan had not read;
- a `no-ledger` mutant that was caught by the harness's own ledger readback rather than by the
  guard it disabled.

## Where the model is simpler than the code

| the model | the code | why the gap is acceptable |
|---|---|---|
| A note is a list of fields `(key, front/body, tokens)`. A token is `ok`, `upper`, `padded` or `junk`, and every non-junk token is a reference. | A line-based scan over each decoding of the bytes. It is deliberately looser than the spec: body lines, uppercase hex and trailing junk all count. | The proofs are about planning, not parsing. Parsing is what the differential checks against PyYAML, and it is where the bug was. Proving it would mean modelling YAML. |
| `readable : Bool` | a dangling link, an iCloud stub, EPERM, a FIFO, an oversize note, an unreadable folder | Each makes the scan incomplete in the same way. The harness generates the first two. |
| vault ids and a checked closure | realpaths and the DFS in `vault.resolve_vaults`; relative `inherits`; manifest validation; registry, ledger and store-location errors | The first pair agreed over 10,000 cases, including missing vaults, cycles and diamonds. Everything else is a refusal or an exception raised before any plan exists, which is the safe direction. |
| the planner only | `gc_apply`: a re-plan, the token, and an age re-check under the exclusive lock | By inspection, apply removes a subset of a fresh plan. That is not proved, and concurrency is not modelled. |

## Running it

```bash
cd experiments/lean-blob-gc/lean && lake build && lake env lean Axioms.lean
```

```bash
cd experiments/lean-blob-gc && uv venv .venv --python 3.13 && uv pip install --python .venv/bin/python hypothesis==6.170.15 pyyaml==6.0.3
```

```bash
cd experiments/lean-blob-gc/harness && ../.venv/bin/python run.py agree --cases 10000 && ../.venv/bin/python run.py survey --cases 3000 && ../.venv/bin/python run.py unsafe block_comment
```

```bash
cd experiments/lean-blob-gc && .venv/bin/python harness/repro_hidden_reference.py
```

The repro exits 1 while the bug is there, 0 once no spelling gets a named blob planned for removal,
and 2 if the repro itself is broken: an import or a case crashed, or one of its two controls
misbehaved.

`BLOBGC_TMP` sets where the per-case folders go; the default is `$TMPDIR`. Each folder is removed
when its case ends. Nothing is written under `substrate/`.
