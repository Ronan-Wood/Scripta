# The Boundary Principle

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
| `capabilities` | which of embedder / generator / rerank are live | design |
| `expected_quality` | measured MRR for THIS degradation, not a flag | 0.698 full · 0.375 no generator · 0.21 no embedder |
| `index_version` | what the index was built from | **surfaces staleness; does not solve it** |

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
