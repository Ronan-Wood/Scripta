# The Boundary Principle

> **This document is also the operator note `boundary-principle` in core-vault's
> `00-operator/patterns/`.** The vault copy is the migrated home; this file stays as the
> repo's working doc. They are byte-identical below the frontmatter — keep them so.

> **Information that exists but does not cross the boundary to its consumer reads as
> absence — and absence reads as fine.**

This is the dominant failure shape of this project. Five distinct incidents, different
subsystems, different weeks of work, one structure. In every case the missing information was
*already available*; the failure was attaching it to the thing that crossed the boundary.

The table below holds the five that were **discovered**. A sixth is recorded under *Where it must
be applied next* and is kept separate on purpose: it was **predicted in this document before the
mechanism that caused it existed**, which makes it evidence about the pattern rather than another
instance of being caught out by it.

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
| `refresh` | what the unattended agent last managed on THIS scope | **built** — outcome plus tri-state `frozen`: `true` (a recompose refused, results are superseded), `false` (index and vault agreed), `null` (no basis). Read by `render` and `introspect`, never attached by an adapter |

The `expected_quality` numbers here supersede an earlier sketch (`0.698 full · 0.375 no generator ·
0.21 no embedder`) that was **mixed-cohort** — 0.375 is a 24-case figure and 0.21 a 7-case one, so
quoting them beside the 44-case 0.698 would be the cross-cohort subtraction HANDOFF §6 forbids. The
implemented tiers (`retrieve/retriever.py:_STACKS`) are all 44-case and model-specific; a config
that was never measured at 44 cases returns `None` rather than importing a lower-cohort number.

**Be precise about those last two rows.** `index_version` converts *silent omission* into
*detectable omission*, which by this document's own argument is the whole game. But detection is
not freshness, and for a long time nothing closed that gap: no watcher, so the caller had to
check, and the discipline was pushed onto every consumer.

**The sixth occurrence then arrived, and this paragraph predicted it.** It used to end: *a version
stamp that implied staleness was handled would be the sixth occurrence.* What produced it was the
fix for the manual half. An unattended agent (`tools/substrate-refresh`, every fifteen minutes)
made freshness automatic — and `compose` returns before it opens the database, so a scope whose
recompose REFUSED simply kept its old index and went on answering in an envelope byte-identical to
a healthy run. The agent converted freshness a human checked into freshness a human assumes. The
producer knew the rebuild had failed; none of that crossed. `index_version` could not show it,
because the index really was built from what the stamp said.

The cure was the cure: `refresh` is a field ON the envelope, tri-state so "no basis" stays
distinguishable from "clean", and read by the shared render layer rather than attached by each
adapter — an adapter that has to remember to attach it is one that eventually will not. So the
honest statement is now **"staleness detectable, freshness automatic and self-reporting."**

Note what did *not* happen: the argument was not corrected. It was written before the mechanism
existed, named the failure that mechanism would introduce, and specified the shape of the fix. A
pattern that holds when its domain expands is worth more than one that was merely right once.

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

---

## A third law: a declared value that is never read is invisible to every assertion

The Boundary Principle is about information failing to reach a *consumer*. The second law is about
un-gated assertions accumulating miscalibration. This is a third shape, and the one the A-series
structurally cannot see.

**Assertions validate values they RECEIVE. A value dropped upstream of the validator is
indistinguishable from a value never declared** — the declaration and the default produce identical
downstream state. So correctness becomes unfalsifiable from inside the system: no assertion can
catch it, because every assertion runs downstream of the drop.

**Observed.** Six migrated conversations declared `class: conversation` — the spelling Doc 2 §3 uses,
and the one `vault._source_meta` already maps. The note reader honoured only `document_class:`. All
six fell through to the `reference-frozen` default and composed **fully green**: A21, A22 and A23 all
passed on a corpus where every conversation was mislabelled.

Three properties make this the nastiest of the three shapes:

1. **The defense existed and could not fire.** An unknown class was already refused by
   `classes.apply()`. The value never reached it.
2. **The failure was inclusion, not absence.** The default `reference-frozen` is retrieved BY
   DEFAULT, so the symptom was conversations silently answering every query forever — the exact
   opposite of what declaring the class was for, and indistinguishable from normal operation.
3. **The mechanism was two names for one field.** `class:` per the spec, `document_class:` per the
   reader. The information existed, was written correctly, and did not cross into the parser.

It was caught by verifying an outcome, not by reading a status. Nothing in the system reported it.

### The defense

**For any field where absence has a meaningful default, assert that a declared value survives
parsing.** Not "is the value valid" — that is what the spine validators already do — but "did a
declared value reach the store unchanged." `tests/test_declared_survives.py`.

Note the symmetry that did NOT imply itself: the emit round-trip tests
(`tests/test_confidence.py`) guard the EMITTER dropping declared values; this guards the READER
dropping them. Same defect, opposite ends of the pipeline, and fixing one gave no warning about the
other. Anywhere a value is written by one component and read by another, both directions need a
test, because each is invisible from the other side.

The cheapest form of the check is vocabulary agreement between parsers: if one component maps a key
and another ignores it, that is alias drift and it will default silently. That test catches the bug
before the bug is written.

### The known second instance, not yet fixed

Doc 2 §3b calls the markdown→raw pointer **"system-contract provenance"** — `raw`, `raw_sha256`,
`raw_location` in a source's `_meta.md`, whose stated purpose is that the regeneration path cannot
be lost. It is written correctly in the real DDIA `_meta.md`. **Neither parser reads it and no
column holds it.** A retrieved passage carries `source_sha256` — of the passage FILE, not of the
source PDF — so it answers a different question than the one a reader would assume, which is why
this one survives inspection.

This is a different subclass from the alias drift: not "declared, valid, silently defaulted" but
"declared in the spec, never implemented at all." Both are invisible; they need different fixes.

---

## A fourth law: a claim that reads as verification, with nothing behind it, is worse than silence

The Boundary Principle is about information that fails to cross. The second law is about un-gated
assertions accumulating miscalibration. The third is about a declared value dropped upstream of
every validator. This is the inverse of all three: the *claim* crosses perfectly, and there is
nothing behind it.

**Silence leaves the next reader to check. A claim stops them checking.** That is why this is worse
than omission rather than merely equal to it — the artifact does not simply fail to inform, it
spends the one budget that would have caught it.

Five instances, one structure. All were found by review rather than by testing, which is itself the
signature: nothing goes red for a claim that nothing executes.

| # | the claim | what stood behind it |
|---|---|---|
| 1 | a docstring asserting a property | nothing — written last, never checked against the code |
| 2 | a test named for a property | a comparison over a named SUBSET, green while the objects differed |
| 3 | a guard constant quoted in three readouts | no derivation anyone could reproduce |
| 4 | a refusal naming a remedy | a command verified to be a no-op on the state it was printed for |
| 5 | `PRAGMA user_version` | migration history, not the column shape it was read as describing |

**(1) The docstring.** Four in one session: *"a caller that never received a plan cannot produce a
token"* (the token was a derivable digest); *"ONE definition both adapters call"* (only one called
it); *"the same envelope the MCP server returns"* (each adapter bolted on its own field); *"same
envelope … so a consumer never has to reconcile two passage shapes"* (two key sets). In every case
the prose was written last and nothing checked it against the code.

**(2) The test.** The §6 equivalence test asserted five keys and passed while both adapters emitted
structurally different envelopes; it also ran both sides lexical-only, so it compared two
identically-empty stacks and could not see the divergence it existed to catch. Proven, not assumed:
reinstating the old hand-wired CLI branch left it green. **Assert the whole object, and assert
AGREEMENT rather than a value** — the second is what makes a test independent of whether a daemon
happens to be running.

**(3) The guard nobody runs.** `4a4f765c9ad75dc9` guarded the eval fixture in three readouts for
months; its derivation was recorded nowhere, and a later session tried seventeen constructions over
`(chunk_id, text_with_path)` without reproducing it. Its replacement then reproduced the defect one
level down: recomputable from its first commit and recomputed by nothing — the database is
gitignored, no test asserted the value, and the tool's only caller in the repo was its own test.

**Recomputable-in-principle is the same defect as unrecomputable, and it hides better**, because
the mechanism looks finished. The cure is not a better number; it is a caller in a path someone
already runs. `run.sh` now refuses to report an MRR when the fixture disagrees with
`eval/fixture.sig`.

**(4) The remedy.** This project's rule is *refuse rather than mislead*. A refusal message naming a
fix is a claim like any other, and an untested one turns the rule into *refuse AND mislead*: a
`journal_mode=PERSIST` database that the tool could read perfectly was refused permanently, and the
remedy printed for it — a WAL checkpoint — is a verified no-op on a rollback journal, returning
`(0,-1,-1)` and leaving the file byte-identical. The operator was left with a refusal and no way
out of it.

**A refusal is complete only when its remedy has been executed against the state that triggers it.**

**(5) The stamp read as a description.** `out/substrate.db.v2-frozen-…` is stamped `user_version=2`
and carries 26 columns including `confidence`. The stamp is a claim about migration history, not
about what a `SELECT` will find. Trusting it put a wrong sentence in the session handoff and nearly
produced a wrong reading of the mutation evidence that justified the replacement signature.

### The test to apply

Mirroring the first law's:

1. Does this sentence assert a property?
2. Is there something that FAILS when the property stops holding?
3. If no to (2) — delete the sentence, or write the thing that fails.

The third option, leaving it and intending to check later, is how all five of these were made.
