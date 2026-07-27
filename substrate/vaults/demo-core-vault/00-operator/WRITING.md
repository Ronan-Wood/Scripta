# WRITING.md — how notes in this vault are written

Every note follows these rules. Most notes here are model-written, so the rules cost nothing to
enforce and everything to skip: consistent, single-job, decision-preserving notes are what make
the vault readable and the retrieval predictable (consistent terms → lexical match + less
embedding drift). This file is the authority; it is read wholesale, not retrieved in pieces.

## Baseline

The [Google developer documentation style guide](https://developers.google.com/style) — referenced,
not restated. Follow it for anything the rules below do not override.

## Rules that override the baseline

Google targets public docs for an audience needing onboarding; these notes target a reader already
inside the project. Where they conflict, these win.

| # | rule | why |
|---|---|---|
| 1 | **Lead with the conclusion.** First sentence states the finding / decision / answer. | The reader is inside the project; the headline is the value. |
| 2 | **No preamble, no postamble.** No "this note covers…", no closing recap. | Both are zero-information framing. |
| 3 | **Terser than public docs.** Assume project context; don't re-derive known background. | The reader has the context a public doc must supply. |
| 4 | **Structure over prose for anything enumerable.** Decisions, tradeoffs, options, findings → tables/lists. Prose only for reasoning that doesn't decompose. | A table is scannable; a paragraph of five options is not. |
| 5 | **Preserve decision history — never flatten it.** "Previously X, now Y because Z" is the required form. | Deleting superseded reasoning destroys the note's main value. |
| 6 | **Preserve confidence markers.** `[inferred]` stays `[inferred]`; "provisional" stays provisional. | Smoothing a hedge into confident prose is a silent falsification. |
| 7 | **Attach conditions to numbers.** Every figure carries cohort / config / date. Never subtract or compare figures from different conditions. | A number without its conditions reads authoritative while being wrong. |
| 8 | **One note, one job.** If a note does two `doc_type` jobs, split it. | Blending jobs is the dominant cause of a slow-to-read note. |

Rules 5–7 are the ones no external style guide provides — they are the substrate spine applied at
write time. Every failure this project has hit (the five retractions, the cohort distortion, the
chapter-title bug) is a version of one of them being violated.

## doc_type — the five jobs (Doc 2 §6a)

Every note declares one `doc_type` in frontmatter. It is a retrieval axis alongside `status` and
`domains`, and declaring it forces rule 8's split.

| doc_type | orientation | shape |
|---|---|---|
| `decision` | what was chosen and why | decision / why / rejected / consequence |
| `explanation` | understanding — why it is the way it is | prose acceptable; conclusion first |
| `reference` | look-up, stable, scannable | tables / definition lists, no narrative |
| `how-to` | task steps for a reader who knows why | prerequisites / steps / verify |
| `digest` | orientation in an AREA — what it holds, what state it is in, where to go next | links + one-line glosses; **points, never contains** |

If a note answers two of these, it is two notes.

**`digest` is the one that can be abused, so it carries an extra rule: a digest POINTS, it does not
CONTAIN.** It links to the atomic notes and says in one line why you'd open each; the substance
lives in them. The moment a digest inlines the decision instead of linking it, it is two notes
wearing one filename — the exact shape rule 8 exists to split. Write one per area, not per topic,
and treat its length as a warning sign.

A digest is an inventory, so `stated` is its **ceiling** and `verified` is never right. That is a
cap, not a default: if the digest makes no claim of its own, omit the key — the rule below against
picking a value to fill the field applies here too.

**A digest is an ordinary note and lives in an indexed folder** — `02-areas/<area>-digest.md` or
`04-synthesis/<area>.md`. Never write one as `00-index/MEMORY.md` or `log.md`: those keep their own
jobs (the human content map, the append-only history), are never indexed, and putting a spine on one
is refused rather than silently dropped.

## confidence — how settled a claim is (Doc 2 §6b)

`status` and `confidence` are independent axes, and rule 6 is unenforceable without the second one.
`status` answers *is this note live?*; `confidence` answers *why should I believe it?* A note can be
`active` and `proposed` — a design that was written, is current, and was never built. Collapsing the
two lets a proposal retrieve reading as a settled decision, which is confidence laundering.

| confidence | the claim was… | typical note |
|---|---|---|
| `proposed` | put forward as a design or suggestion; not built, ratified, or tested | a design doc awaiting a decision |
| `inferred` | derived from observation or reasoning; could be wrong | a pattern read off usage data |
| `stated` | asserted directly by an authority — the operator, or a published source | a ratified decision; a textbook passage |
| `verified` | measured, tested, or confirmed against reality | a finding with a number and conditions behind it |

**Omit the line entirely if the note makes no claim** — do not write a placeholder, and do not
leave a trailing `# comment` on the value. Frontmatter values are taken verbatim to end-of-line, so
`confidence: proposed   # omit if …` parses as that whole string and is refused at ingest.

Declaring it is OPTIONAL. A note that omits it stores and surfaces `unstated`, which is honest —
the note made no claim about how settled it is. Never pick a value to fill the field; an invented
confidence marker is worse than an absent one, and `unstated` is what the axis is for.

**An inventory is `stated`, not `verified`.** A list of what is installed, connected, or present is
confirmed against reality only at the instant it is written, and establishes nothing durable — its
failure mode is silent staleness, not wrongness. Reserve `verified` for a claim that testing could
have shown wrong: a measurement, a reproduction, a bug confirmed and fixed. When the evidence is
mixed, choose the weaker value; understating costs a reader a little trust, while overstating hands
them a stale snapshot as established fact.

It is a **provenance-of-claim axis, not a ranking**. `verified` does not outrank `stated`; a
measured number and a decision the operator ratified are different kinds of true. Nothing filters on
confidence by default — it is carried onto every passage and surfaced on every hit, so a retrieved
proposal states that it is one without a join.

**Certainty is a different thing and does not belong on this key.** "How sure am I"
(high/medium/low) and settledness are orthogonal — a design can be high-certainty and unbuilt — so
the engine refuses a certainty word here rather than carrying an axis value nothing can act on.
Where certainty goes depends on where the note came from:

- **Written here:** body prose, or an inline `[inferred]`-style marker beside the claim it qualifies.
- **Migrated:** the source vault's own value is preserved verbatim under `source_confidence:`, and a
  settledness value is chosen for `confidence:`. See *Reserved frontmatter keys* — `source_*` is
  documentation the engine never reads, not a second spine field.


## Templates

### decision
```markdown
---
title: <what was decided>
status: active
doc_type: decision
confidence: <proposed | inferred | stated | verified>
domains: [<domain>]
---

# <what was decided>

<The decision, stated. One sentence.>

**Why:** <the reasoning that forced it.>
**Rejected:** <the alternatives and why each lost.>
**Consequence:** <what this commits us to / what it forecloses.>
```

### explanation
```markdown
---
title: <the thing understood>
status: active
doc_type: explanation
confidence: <proposed | inferred | stated | verified>
domains: [<domain>]
---

# <the thing understood>

<The conclusion first — the understanding, in one sentence. Then the reasoning that grounds it.
Prose is acceptable here; this is the one type where it is.>
```

### reference
```markdown
---
title: <what this lists>
status: active
doc_type: reference
confidence: <proposed | inferred | stated | verified>
domains: [<domain>]
---

# <what this lists>

| term / key | value |
|---|---|
| … | … |

<Definition lists or tables. No narrative — a reference is scanned, not read.>
```

### how-to
```markdown
---
title: <the task>
status: active
doc_type: how-to
confidence: <proposed | inferred | stated | verified>
domains: [<domain>]
---

# <the task>

**Prerequisites:** <what must be true before starting.>

1. <step>
2. <step>

**Verify:** <how to know it worked.>
```

### digest
```markdown
---
title: <the area>
status: active
doc_type: digest
domains: [<domain>]
---

# <the area>

<What this area is, and its current state. Two sentences.>

## <grouping>
- [[note-id]] — <doc_type> · <confidence>. <One line: why you would open this one.>

## Open
<What is unresolved here, or a pointer to the log.>
```

## Glossary

One word per concept. Consistent terminology is the one style property that measurably helps
retrieval. Start here; grow from observed drift.

| Use | Not |
|---|---|
| passage | chunk, snippet, excerpt, fragment |
| supersede | deprecate, replace, obsolete, retire |
| vault | repo, folder, library, notebook |
| tier | layer, level, section |
| engine | backend, service, core |
| retrieval | search, lookup, query (as a noun) |
| ingest | import, load, absorb |
| manifest | config, settings file |
| domain | category, topic, subject area |
| capability | mode, state, status (of the retrieval stack) |
| confidence | settledness, maturity, certainty, sureness (of a claim) |
| digest | (the `doc_type` only — a per-area summary note) |
| checksum | digest, hash (of bytes — never call a content hash a "digest") |

## Reserved frontmatter keys

Three names that a reader or a model could plausibly write for the wrong thing. Each is reserved to
exactly one meaning, because a key that means two things is a value nobody can act on.

| key | means ONLY | read by the engine? |
|---|---|---|
| `status` | the note LIFECYCLE — active / complete / archived / superseded | yes — drives the default retrieval set |
| `confidence` | how SETTLED a claim is — proposed / inferred / stated / verified, absent → `unstated` | yes — carried onto every passage, surfaced on every hit |
| `capability` | the RETRIEVAL STACK's state (which arms ran) | n/a — a result-envelope field, never note frontmatter |

- Never use `status` for the stack; that is `capability`.
- Never use `confidence` for how sure the author feels. **Certainty and settledness are orthogonal
  — a design can be high-certainty and unbuilt**, which is precisely why a certainty value on this
  key is refused at ingest rather than carried.

### The `source_*` namespace — preserved originals, never read

A note migrated from another vault keeps its original value under `source_<key>`, verbatim, so the
remap is auditable instead of lost: `source_status: "proposed, not implemented"`,
`source_confidence: high`.

**`source_*` keys are documentation, not spine.** The engine does not read them, nothing filters or
surfaces them, and they carry the *old* vault's vocabulary — including axes this standard does not
use, like the high/medium/low certainty scale. Do not reach for `source_confidence` when you mean
`confidence`; if a note was written here rather than migrated, it has no `source_*` keys at all.
