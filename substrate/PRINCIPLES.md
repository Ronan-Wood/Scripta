# The Boundary Principle

> **This document is also the operator note `boundary-principle` in core-vault's
> `00-operator/patterns/`.** The vault copy is the migrated home; this file stays as the
> repo's working doc. They are byte-identical below the frontmatter — keep them so.

> **Information that exists but does not cross the boundary to its consumer reads as
> absence — and absence reads as fine.**

This is the dominant failure shape of this project. Five distinct incidents, different
subsystems, different weeks of work, one structure. In every case the missing information was
*already available*; the failure was attaching it to the thing that crossed the boundary.

---

## The five

| # | incident | what existed | what crossed the boundary |
|---|---|---|---|
| 1 | **Stale-ancestor paths** (Phase 0) | the heading stack knew its chapter was 300 pages back | a well-formed `path` naming the wrong chapter |
| 2 | **Four retracted measurements** | the code knew there were zero vectors / a doc filter matching nothing / a document-ordered list fed to rank fusion | a plausible MRR figure |
| 3 | **Cohort-scale distortion** | every measurement knew its cohort size | a five-step ladder implying one instrument |
| 4 | **`Trace.degraded`** | degradation captured in a field, deliberately | a result with no quality signal |
| 5 | **Docling's silent deletions** | the dropped blocks were classified and known | markdown with the sentence simply gone |

Note what is *not* the problem in any of them: nobody failed to think about the risk. #4 is the
clearest — the capture line exists **because** the failure was anticipated:

```python
except Exception as e:
    trace.degraded = str(e)[:120]   # written, then never surfaced to any consumer
```

The failure was not ignorance. It was that the information lived one layer away from the
consumer, and closing that gap felt like plumbing rather than substance.

---

## Why it is so hard to see

An output missing its conditions is **indistinguishable from an output that had none**. A path
with a stale chapter is a well-formed path. An MRR computed with no vectors is a valid float.
A ladder without cohort sizes is a coherent ladder. Degraded results are still results.

Every one of them **passes inspection**, because the thing that would have failed inspection is
the thing that did not travel. This is why gates do not catch it: gates check the artifact, and
the artifact is fine. The defect is in what the artifact *omits about itself*.

---

## The cure

**Attach the condition to the output as an un-smoothable field.**

- **A field, not prose.** Prose can be paraphrased away — by a model summarising, by a human
  skimming, by a commit message nobody rereads. A field survives being passed on.
- **On the output, not beside it.** `Trace.degraded` existed *beside* the result. The
  boundary is where it must live.
- **Quantified where possible.** Provenance normally answers *where did this come from*. With
  an eval you can also answer *how much should this be trusted* — an empirical number, not a
  vibe. That is a level most systems cannot reach, and it is only available because the eval
  exists to ground it.

The engine already applies this to passages: every chunk carries `document_class`, `version`,
`source_sha256`, page label and structural path, denormalized, so a retrieved passage can state
whether it is current **without a join**. The five incidents are all cases of that same rule
not being applied to something else — to a measurement, to a ladder, to the engine's own
health.

---

## Where it must be applied next

The result envelope handed to any consumer (skill, CLI, MCP, GUI) carries:

| field | states | honest status |
|---|---|---|
| `passages[]` | snippet-first, expandable by id | design |
| `capabilities` | which of embedder / generator / rerank are live | **built** — `retrieve()` returns a `Capability` (embedder / hyde / reranker: ran / skipped / off / fell_back) |
| `expected_quality` | measured MRR for THIS exact stack, not a flag | **built** — same-cohort 44-case tiers: 0.698 full-Ollama · 0.593 full-Apple · 0.343 Apple-embedder-alone; unmeasured stacks return `None`, not a guess |
| `index_version` | what the index was built from | **surfaces staleness; does not solve it** |

The `expected_quality` numbers here supersede an earlier sketch (`0.698 full · 0.375 no generator ·
0.21 no embedder`) that was **mixed-cohort** — 0.375 is a 24-case figure and 0.21 a 7-case one, so
quoting them beside the 44-case 0.698 would be the cross-cohort subtraction HANDOFF §6 forbids. The
implemented tiers (`retrieve/retriever.py:_STACKS`) are all 44-case and model-specific; a config
that was never measured at 44 cases returns `None` rather than importing a lower-cohort number.

**Be precise about that last row.** `index_version` converts *silent omission* into *detectable
omission*, which by this document's own argument is the whole game. But detection is not
freshness: the Python side has no watcher, so the caller must check, and the discipline is
pushed onto every consumer. Scripta gets automatic freshness from FSEvents; this side does not.

The honest statement is **"staleness detectable, freshness still manual"** — surfaced, not
solved. Recording it that way is itself an instance of this principle: a version stamp that
implied staleness was handled would be the sixth occurrence.

---

## The test to apply

Before any output crosses a boundary, ask:

1. What did the producer know that the consumer will not?
2. Would the output look identical if that condition were absent?
3. If yes to (2) — attach it as a field, or expect to retract the result later.

---

## A second law: promoting a check suite to a gate is an audit of every check in it

The Boundary Principle above is about information that fails to cross. This is its inverse — a
check that never *ran* against the thing it now judges.

**An assertion that is not a gate is a suggestion, and suggestions accumulate miscalibration
silently.** Nothing forces a non-gating check to be right; if it is wrong, it prints a row nobody
acts on. The moment it becomes a gate, every latent calibration error becomes a refusal — all at
once, proportional to how long the check ran un-enforced.

So promoting a suite to gate status is not a safety improvement with no downside. It is an audit of
the entire suite, executed in one step, and the correct expectation is a crop of false-rejects.

**Observed.** The per-document A-series lived only in `verify`, which the vault path never called
(F8). Wiring it into `compose` as **A22** immediately exposed two checks that had been wrong on the
markdown path since markdown ingestion existed:

| check | calibrated for | what it did on markdown |
|---|---|---|
| **A1 hyphen residue** | Docling renders a soft hyphen as `!` | counted ordinary exclamations — `"Wow! it works. No! and then. Yes! but only sometimes."` scores 3 against a gate of 2, so three such sentences in one note refused an entire composed vault |
| **A17 stale ancestor** | a book's page count as the denominator | for a slice, the denominator is the max page anchor *in the slice* — a faithful Chapter-1 excerpt computes an implausible share, while the same excerpt from page 280 passes only because the denominator is inflated |

Both were latent for as long as the markdown path existed, and both were invisible precisely
because nothing gated on them.

### The direction of failure is the consolation

These fail **closed**: a false-reject is loud. The dangerous direction — a check calibrated so
loosely that it passes real damage — is the one this document's five incidents are about. That
makes this family annoying rather than dangerous, but it does mean a composed vault will refuse
legitimate content until the suite is swept.

### The sequencing rule that follows

**Sweep before the migration, not during it.** Hitting these refusals mid-migration makes every
refusal ambiguous — is the note wrong, or the assertion? Sweeping first means every refusal during
migration is signal.

### And the sweep needs its own guard

A sweep proves nothing unless its fixtures reach the state the check objects to. Writing the A17
regression test, the first fixture produced `span = 11%` against a `> 30%` gate: it passed with the
fix and *also* without it. A test that cannot fail is worse than no test, because it manufactures
confidence. The corrected fixture asserts it trips the pre-fix predicate before asserting the fix
handles it, and both regression tests were then verified by mutation — revert the fix, watch the
test fail, restore it.

That is the same defect as the tautological A20 check this project already retracted once
(`EXCLUDED = STATUSES − INCLUDED`, which restated its own definition). A check and a test are the
same kind of object: both are worthless if they cannot distinguish the world where they hold from
the world where they do not.
