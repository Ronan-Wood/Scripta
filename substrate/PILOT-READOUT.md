# Real-content pilot — read-out

Phase 2 of the Doc-2 vault work: does the structure survive REAL content — real frontmatter, real
domains, a real superseded-vs-preserved call — that deliberately-created notes cannot test?
Supervised, hand-picked, note-by-note. Not an automated migration.

Source vault: ClaudeVault, read from disk. Derived index: `out-vault/pilot.db`, never `out/`.

---

## 0. Verdict

**The structure survives real content, and the migration is a rewrite, not a copy.**

Twelve real notes across two new vaults composed clean on the first run — all four statuses, all
four `doc_type` values, three tiers, inheritance and supersession both proven by query. **No engine
change was needed to read real content.** Every friction found was either migration labour or a
gap in what the engine *reports*, not in what it can read.

Two real defects were found and **both are now fixed**:

1. **`compose` reported PASS on a corpus containing a note that `verify` fails** (F8). One of
   twelve real notes fails assertion A13; none of the nine synthetic notes do. `compose` ran only
   A-compose/A20/A21, so the failure never surfaced — this project's signature shape, sitting
   directly on the path a hundred-note migration would take. Fixed: **A22**, the per-note assertion
   sweep, now runs on the vault path (§4).
2. **`reference_domains` was silently swallowed into `[reference_pins]`** in both manifests (F9) —
   a TOML table-header scoping bug, present in the shipped scaffold since Phase 1 and copied into
   the pilot. Found by adversarial review, verified, fixed in both vaults (§5).

Remaining recommendation: **bank the rest.** Details in §8.

---

## 1. What was built

```
vaults/
├── pilot-core-vault/                  # Tier 1 + 2, root, inherits nothing
│   ├── 00-operator/
│   │   ├── WRITING.md                     the standard (SKIP_NAMES — never indexed)
│   │   ├── operator-working-style.md      active · reference   ← real, body verbatim
│   │   ├── operator-preferences.md        active · reference   ← real, body verbatim
│   │   ├── audit-cycle-run.md             active · how-to      ← rewrite, split A
│   │   └── audit-cycle-why.md             active · explanation ← rewrite, split B
│   ├── 10-reference/frozen/software-dev/ddia-2e/
│   │   ├── _meta.md                       real raw_sha256 241254d3… · 3 domains
│   │   ├── structure.md                   (SKIP_NAMES)
│   │   └── passages/                      3 passages, real reviewed markdown, Ch. 7
│   ├── _index/MEMORY.md · log.md · 99-templates/
└── scripta-vault/                     # Tier 3, inherits pilot-core-vault
    ├── .substrate.toml
    ├── 04-synthesis/
    │   ├── model-engine-design.md         active · decision · supersedes →   ← real, verbatim
    │   ├── model-engine-panel-raw.md      superseded · decision (831 lines)  ← real, verbatim
    │   └── model-strategy-decisions.md    active · decision (elaboration)    ← real, verbatim
    ├── 03-references/transcript-format.md complete · reference               ← rewrite
    ├── _archive/on-device-table-llm-rejected.md  archived · decision         ← rewrite
    └── 00-index/MEMORY.md · log.md
```

20 markdown files on disk, **12 indexed** — the 8 skipped are `WRITING.md`, two `_meta.md`/
`structure.md`, two `MEMORY.md`, two `log.md`, one template. Nothing indexable went missing; the
count check in `assert_composed` is over the notes actually selected.

`compose` output:

```
scope: scripta-vault  <-  ['pilot-core-vault', 'scripta-vault']
  12 notes across 2 vault(s)
  A-compose PASS  by vault {'pilot-core-vault': 7, 'scripta-vault': 5} · by tier {1: 4, 2: 3, 3: 5}
  A20 status PASS  included 94 · excluded 134 · by status {'active': 9, 'archived': 1,
                                                           'complete': 1, 'superseded': 1}
  A21 doc_type PASS  by doc_type {'decision': 4, 'explanation': 1, 'how-to': 1, 'reference': 6}
  A23 confidence PASS  by confidence {'inferred': 1, 'proposed': 2, 'stated': 6,
                                      'unstated': 1, 'verified': 2}
  A22 per-note PASS (loss/corruption gates) · 1 QUALITY WARNING(S) across 1 of 12 note(s):
      …/vaults/scripta-vault/04-synthesis/model-engine-panel-raw.md: A13 no fragments — 1
  db: out-vault/pilot.db (schema v5) · index v5:9fb42d619efe
```

(A22 is the F8 fix (§4) and A23 the confidence axis (§6) — on the pilot's first run neither line
existed, and both the A13 defect and the unbuilt-design mislabel were invisible.)

---

## 2. The axes, proven by query

All lexical-only (`--no-vector`), against `out-vault/pilot.db`.

### Inheritance composes on real content

A scripta-scope query answered entirely from **pilot-core-vault**:

```
$ … query "how does the operator run the audit review implement verify cycle"
  [passage] Run the audit, review, implement, verify cycle · … · @pilot-core-vault
    ↳ status=active · doc_type=how-to · confidence=unstated · domains=['operator', 'process']
```

And the Tier-2 reference, reached from the project scope, carrying a **real page label from the
real 673-page ingest**:

```
$ … query "sharding data by hash of the partition key hot spots"
  [passage] Sharding by Hash of Key · … > Sharding by hash range · p285 · @pilot-core-vault
    ↳ status=active · doc_type=reference · confidence=stated · domains=['software-dev',…]
```

`p285` is provenance that survived PDF → reviewed markdown → vault → index. The three domains came
from `_meta.md`; the passage files carry no frontmatter of their own.

### Supersession — and it is doing real work

Default retrieval returns the **live synthesis**, with the supersession link on the hit:

```
$ … query "one in flight generation per endpoint semaphore fallback policy per task"
  [passage] Local Model Engine — synthesized design · … · @scripta-vault
    ↳ status=active · doc_type=decision · confidence=proposed · … · supersedes=model-engine-panel-raw
```

`--all-status` shows what the filter suppressed — **the superseded raw panel takes ranks 1, 2 and 3**:

```
$ … --all-status
  [passage] Model Engine Design Panel — raw output (SUPERSEDED) · … > Judge synthesis
    ↳ status=superseded · doc_type=decision · …
  (two more, also the raw panel)
```

This is the difference from the synthetic pair: the raw panel is *genuinely* the better lexical
match for its own content, so §6's exclusion is changing the answer, not decorating it.

### Supersession vs. elaboration — the real §6 judgment

`model-strategy-decisions` **elaborates** `model-engine-design`; it does not replace it. Both stay
`active`, and a query hits both:

```
$ … query "Apple FM is the permanent default and the endpoint is opt in via settings"
  [passage] Model strategy decisions · … > Decided · @scripta-vault          status=active
  [passage] Local Model Engine — synthesized design · … · supersedes=…       status=active
```

Getting this wrong in either direction is a silent loss: marking it superseded would bury a live
decision set; marking the raw panel active would let a rejected design answer as current.

Second judgment on the same note: it carries an **"Open (not yet decided)"** section, so it is
`active`, not `complete`. `complete` means done and correct; open questions disqualify it.

### Status

Archived is excluded by default and surfaces on request:

```
$ … query "on device model produced factually wrong tables from OCR misassigned columns"
  status filter: active,complete
  (the archived note is absent; unrelated notes rank instead)

$ …  --include-archived
  status filter: active,archived,complete
  [passage] No in-app LLM for screen-context tables · …
    ↳ status=archived · doc_type=decision · confidence=verified
```

### doc_type

All four values present, denormalized onto chunks, surfaced on every hit:

| doc_type | active | complete | archived | superseded | chunks |
|---|---|---|---|---|---|
| decision | 2 | — | 1 | 1 | 166 |
| reference | 5 | 1 | — | — | 58 |
| explanation | 1 | — | — | — | 2 |
| how-to | 1 | — | — | — | 2 |

And confidence, the second axis (§6) — note that it cuts across status independently:

| confidence | notes | e.g. |
|---|---|---|
| `stated` | 6 | the ratified decisions; the DDIA source; the operator's explicit preferences |
| `verified` | 2 | the measured rejection; the shipped transcript format |
| `proposed` | 2 | the model-engine design **and** its superseded panel — active/superseded, both proposed |
| `inferred` | 1 | the working-style note, read off usage data |
| `unstated` | 1 | left unmarked deliberately, so absence stays a visible outcome |

---

## 3. Frictions — the pilot's payload

Each was predicted in the handoff or found during the build. Verified and quantified.

### F1 — `status` is free text upstream, an enum here. 12/12 notes needed a hand remap.

Not merely "a value outside the four." The raw panel's status was **prose containing a wiki-link**:

```yaml
status: raw panel output; synthesis in [[2026-07-14 - Local Model Engine Design]]
```

The operator notes used `status: verified`; the others `proposed, not implemented` and `ratified in
conversation 2026-07-14/15`. **Zero notes could be copied.** Every one needed a judgment, and two of
them (F4) were non-obvious.

Technique used: remap to the enum, and preserve the original verbatim as `source_status:` so the
remap is auditable rather than lost. **The engine drops that key** — see F3.

### F2 — One source note = two `doc_type` jobs, so migration is a rewrite.

`01 - Patterns/Audit-Implement-Verify Cycle.md` did a how-to job ("The shape", "How to honor it",
"When NOT to use") and an explanation job ("Why it matters", "Anti-patterns to avoid") in one note.
Rule 8 forces the split: it became `audit-cycle-run.md` (how-to) and `audit-cycle-why.md`
(explanation), both written to the WRITING.md templates.

The project `Index.md` is worse — 130 lines doing **three** jobs: a content map, an append-only
running log, and a decisions/gotchas reference. Doc 2 already has a slot for each, so it split
three ways: map → `00-index/MEMORY.md`, log → `log.md`, the locked decisions → a `03-references`
note. That is the shape most real project notes will take.

Rate on hand-picked content: **1 of 4 operator notes and 1 of 1 project index needed splitting.**
The three model-engine notes did not — they were already single-job, because they were written as
design artefacts rather than as running notes.

### F3 — Frontmatter the engine silently drops · **RESOLVED for the confidence axis (§6)**

> The settledness half of this finding is now fixed: `confidence` is a spine axis, carried onto
> every chunk and surfaced on every hit (§6). The rest of the dropped keys (`type`, `project`,
> `created`, `sources`, `last-updated`) remain dropped, and the original analysis stands below.


Migrated notes carry `type`, `project`, `created`, `sources`, `last-updated` and the `source_status`
audit key. The reader parses frontmatter into a dict and reads exactly seven spine fields; **the
rest are discarded with no warning.** They never reach a hit.

`confidence` is the sharp case. `documents.confidence` **exists as a column** — but it is the
ingest pipeline's extraction confidence, not the note's. The two operator notes declare
`confidence: high`; the column holds `NULL`:

```
  model-engine-design        confidence=None   coverage=0.9383
  operator-preferences       confidence=None   coverage=0.9239
  operator-working-style     confidence=None   coverage=0.9232
```

So a name-identical column sits beside the dropped value, which is how a check on this would be
fooled — mine was, on the first pass.

**This directly violates WRITING.md rule 6** ("preserve confidence markers — smoothing a hedge into
confident prose is a silent falsification"). The rule is enforced at write time and has no carrier
at retrieval time: a `[inferred]` note and a `confidence: high` note produce identical hits. That
is the Boundary Principle exactly — the information exists, does not cross, and absence reads as
fine. It is also the same collision class that WRITING.md's `status`/`capability` reservation
exists to prevent, one term further down.

This is a **design question, not a bug**: does the spine get a provenance/confidence field, or is
confidence body prose? Doc 2 §6 currently says neither.

### F4 — No domains upstream; every note needed one assigned

ClaudeVault frontmatter carries no `domains`. All 12 notes needed an assignment, and the assignment
is a retrieval decision, not a filing one — the operator notes took `[operator, process]`, the
model-engine lineage `[software-dev, architecture, retrieval]`, and the DDIA source inherited its
three from `_meta.md`. Cheap per note, but it is 12 decisions with no upstream signal.

### F5 — One superseded note is 58% of the index

| status | chunks | share |
|---|---|---|
| active | 92 | 40.4% |
| **superseded** | **132** | **57.9%** |
| archived | 2 | 0.9% |
| complete | 2 | 0.9% |

The 831-line raw panel alone is 132 of 228 chunks. Superseded content is not a rounding error —
here it is the majority of the index while being excluded from every default query. Lexically that
costs nothing; with the vector arm on it is real embedding spend on content no default query can
reach. Worth a policy decision before scale, not an engine change.

It also chunks worse: 20 of its chunks exceed the 1400-char target (34 across the whole corpus),
because judge-panel prose runs to 2,500-character paragraphs the chunker will not split
mid-sentence.

### F6 — Body links break under partial migration; frontmatter links do not

Ten distinct `[[…]]` targets in migrated bodies resolve to nothing in scope, including the raw
panel's own pointer at `[[2026-07-14 - Local Model Engine Design]]` — the source-vault filename of
the note that is now `model-engine-design`. **The supersession link works (it is frontmatter, which
the engine reads); the human-navigation link is broken (it is a body wiki-link, which it does not).**

Retrieval is unaffected. Obsidian browsing is not. Any future link-integrity lint must also skip
code fences: the raw panel contains `func embed(_ texts: [String]) async throws -> [[Float]]`, and
a naive `[[…]]` scan reports `[[Float]]` as a broken link.

### F6b — declaring `doc_type` on *preserved* content is guesswork, and nothing checks it

Surfaced by adversarial review, and a fair hit on my own labels. The `doc_type` values I assigned
to real, body-verbatim notes do not match the shapes `WRITING.md` defines in the same change:

| note | declared | WRITING.md says that shape is | what the body actually is |
|---|---|---|---|
| `operator-working-style` | `reference` | "tables / definition lists, **no narrative**" | narrative bullets, zero tables — and a descriptive job blended with a prescriptive "Calibration" section |
| `operator-preferences` | `reference` | same | narrative bullets + a "What this calibrates" job |
| `model-engine-design` | `decision` | decision / why / rejected / consequence | an 83-line architecture spec with none of that structure |
| `model-engine-panel-raw` | `decision` | same | an 831-line dump: judge scoring **plus two complete alternative designs** |

The notes I *rewrote* (`audit-cycle-run`, `audit-cycle-why`, `transcript-format`,
`on-device-table-llm-rejected`) match their declared shape, because writing to the template is what
rewriting means. The notes I *preserved* do not, because their bodies predate the standard.

Two things follow. First, this is crosscheck's A5 finding recurring on real content rather than on
scaffold notes, which means it is systematic and not a one-off. Second — and this is the part worth
carrying — **nothing in the engine checks a declared `doc_type` against the body it labels.** A21
proves the value is one of four and that chunks agree with their document; it cannot prove the note
does that job. So `doc_type` on migrated content is an assertion by the migrator, not a verified
property, and a retrieval axis built on it inherits that. Rule 8 is enforced by whoever is writing,
or not at all.

### F7 — `doc_id` derivation held under real conditions

The DDIA passages carry no frontmatter, so they took filename-derived ids with hash suffixes
(`00-sharding-key-range-c7265b57`). This is the exact collision surface the crosscheck fix
addressed — three same-shaped `NN-*.md` files under one source, in a vault composed with another.
No collision; `resolve_scope`'s effective-id check passed.

---

## 4. F8 — the engine gap, and the fix

**`compose` reports PASS on a corpus containing a note that `verify` fails.**

```
$ … verify out-vault/pilot-index/scripta-vault__model-engine-panel-raw__*
  FAIL  A13 no fragments          1
  PASS  A17 no stale ancestor · A14 coverage 0.9535 · A18 md source coverage 1.0
  PASS  A19 spine status valid    superseded · domains [...]
  PASS  A19 spine doc_type valid  decision
  1 FAILED
```

The fragment is a 370-character chunk (`MIN` is 400) emitted as part 1 of 4 of the Judge synthesis —
a split remainder, so it carries a path it shares with three siblings while holding a quarter of
the content.

Run across every note, real and synthetic:

| corpus | notes | fail a per-document assertion |
|---|---|---|
| pilot (real content) | 12 | **1** |
| demo-vault (synthetic) | 9 | 0 |

`cmd_compose` runs `assert_composed`, `assert_status_partition` and `assert_doc_type_valid` — the
cross-document assertions. The per-document A-series (A13, A14, A17, A18, A19) lives in
`cmd_verify`, which the vault path never calls. So a real content defect passed a green compose and
would have gone into the index unremarked.

Two things make this the finding rather than a nit:

1. **Synthetic notes could not have found it.** Nine hand-made notes, uniformly short and
   well-formed, fail nothing. The defect requires 2,500-character paragraphs — which is what real
   judge-panel and design content looks like.
2. **It is on the migration path.** Migrating a hundred real notes through a gate that does not run
   the per-document checks means defects land silently and at scale. That is the chapter-title bug's
   shape: a well-formed artefact, every gate green, the defect in what the artefact omits about
   itself.

Note the asymmetry is deliberate elsewhere and defensible here: `compose` ingests N notes and
`verify` is written against one ingest dir. The gap is real regardless of whether it was intended.

### The fix — A22

`cmd_verify`'s check list is extracted into `document_checks(dir)`, which now returns
`(check_id, display name, ok, detail)`. The id is stable; the display name is not (A14's label
changes with the source format), so a caller classifying a failure never matches on the label.
`cmd_verify` keeps byte-identical output and exit semantics.

`compose` runs the sweep over every ingested note **before indexing**, and splits failures two ways:

| tier | checks | behaviour |
|---|---|---|
| loss / corruption | A1, A1b, A12, A17, **A18**, A19 — and anything unclassified | **refuses the scope**, exit 3, naming each note |
| quality | `A13-fragments`, `A13-oversize-prose` | **reported**, named per note, never fatal |

The split defaults to fatal: only the two ids in `_QUALITY_CHECKS` warn, so an assertion added later
fails closed rather than silently joining the report-only tier. Quality failures are reported rather
than fatal because Doc 2 §8 makes migration a supervised job over content the engine does not own —
a faithfully-preserved 2,500-character paragraph and the short remainder its split leaves are not
losses, and refusing them would make faithful migration impossible. Swallowing them would rebuild
the gap this check exists to close, so they are printed with the note that produced them:

```
  A22 per-note PASS (loss/corruption gates) · 1 QUALITY WARNING(S) across 1 of 12 note(s):
      …/vaults/scripta-vault/04-synthesis/model-engine-panel-raw.md: A13 no fragments — 1
```

The synthetic vault stays clean (`A22 per-note PASS  9 note(s) · 0 quality warnings`). Seven
regression tests in `tests/test_compose_assertions.py` cover stable ids, the fatal/warning split in
both directions, fail-closed on an unclassified check, and that a failure names its note.

---

## 5. F9 — the manifest bug adversarial review caught

```toml
[reference_pins]
go = "1.21"

reference_domains = ["software-dev", "distributed-systems"]   # ← NOT top-level
```

In TOML every key after a table header belongs to that table. `reference_domains` was therefore
parsed as `reference_pins.reference_domains` — the vault's declared domains never existed at top
level, and `reference_pins` carried a bogus entry:

```
before:  {'name': 'demo', 'inherits': [...],
          'reference_pins': {'go': '1.21', 'reference_domains': [...]}}
after:   {'name': 'demo', 'inherits': [...],
          'reference_domains': [...], 'reference_pins': {'go': '1.21'}}
```

**This was shipped in the Phase-1 scaffold**, not introduced by the pilot — the pilot manifest
copied the pattern. `VAULT-SPIKE-READOUT.md` §3 describes the manifest as carrying
`reference_pins, domains`; that was not true of the parsed result. No live impact today because
`_read_manifest` only acts on `name` and `inherits` — which is exactly why it survived: the two
features that would have noticed are both deferred. Fixed in both vaults, with the ordering
constraint stated in a comment.

**Recommended, not done** (it is new scope, not a defect repair): `_read_manifest` validates the
shape of `name` and `inherits` but not `reference_pins` or `reference_domains`. Validating all four
against the Doc 2 §2 contract would have refused this at parse time and would stop it recurring the
next time someone edits a manifest by hand.

---

## 6. The confidence axis — F3's settledness half, fixed

`status` answers *is this note live?*. Nothing answered *why should I believe it?*, so the two
collapsed and an unbuilt design retrieved reading as a settled decision. WRITING.md rule 6
("preserve confidence markers") was unenforceable prose: the marker lived only in note text, where
it gets chunked away from the claim it qualifies and returns looking authoritative.

**The axis.** A provenance-of-claim vocabulary, not a ranking — `verified` does not outrank
`stated`; a measured number and a ratified decision are different kinds of true.

| confidence | the claim was… |
|---|---|
| `proposed` | put forward as a design or suggestion; not built, ratified, or tested |
| `inferred` | derived from observation or reasoning; could be wrong |
| `stated` | asserted directly by an authority — the operator, or a published source |
| `verified` | measured, tested, or confirmed against reality |

**Declaring it is optional, and that is load-bearing.** An absent marker stores and surfaces
`unstated`. Defaulting to anything confident would *be* the laundering the axis exists to stop, and
requiring it would force a guess per note during migration — a guessed confidence marker is worse
than an absent one. `unstated` is a real stored value, never a NULL: a NULL would reintroduce the
`NULL NOT IN (…)` hole the doc_type audit had to correct, and would read as absence rather than as
"the note did not say".

**The fix, end to end.** Schema v4→v5: `documents.confidence TEXT` +
`chunks.confidence TEXT NOT NULL DEFAULT 'unstated'`, denormalized like status and doc_type so a
passage states its settledness without a join. `spine.validate_confidence` gates it — deliberately
*not* wired to `require_status`, because confidence is optional on every path; only an unknown value
is refused. **A23** mirrors A21 (validity + chunk↔document drift). Surfaced on every hit, including
`unstated` — a field that disappears when inconvenient is prose, not a field.

The dead `confidence REAL` columns on both tables (declared, bound to `None` at every insert, never
read) are deleted rather than kept beside the new one; the extractor's run stats keep their only
real home in `run.json`, and `Document.confidence` → `extract_confidence` frees the name.

**The failure, before and after:**

```
before:  ↳ status=active · doc_type=decision · domains=[…] · supersedes=…
after:   ↳ status=active · doc_type=decision · confidence=proposed · domains=[…] · supersedes=…
```

Same note — the Local Model Engine design, whose source frontmatter said "proposed, not
implemented". `status=active` is *correct*: it is the current design. `confidence=proposed` is what
was missing, and the pair is only expressible with two axes.

```
  A23 confidence PASS  by confidence {'inferred': 1, 'proposed': 2, 'stated': 6,
                                      'unstated': 1, 'verified': 2}
```

`audit-cycle-run` is deliberately left unmarked: the axis is only honest if absence is a visible
outcome rather than a value everything acquires.

### The migration cost this vocabulary carries

ClaudeVault already writes `confidence:` — as **high / medium / low**, in 40 notes. That is a
*certainty* scale ("how sure am I"), a different axis from settledness ("how settled is this"), and
it does not fix the failure: a design can be high-confidence and unbuilt. So `high` is refused on
this axis rather than carried as a value nothing can act on, and migrating a note means renaming its
original to `source_confidence:` and picking a settledness value. Both pilot operator notes hit this
collision immediately — two `confidence:` keys in one frontmatter block, last-write-wins, which
would have silently taken the wrong one. The engine refusing loudly is the correct behaviour and is
how it surfaced.

That is the honest cost of the choice: 40 real notes need a two-line edit each, and the vault gains
a vocabulary it does not currently use.

---

## 7. What did not move

- **Eval signature `4a4f765c9ad75dc9` — unmoved**, re-derived from `out/substrate.db` read raw and
  read-only (`mode=ro` URI, never through engine code): schema v2, 3 documents, 1811 chunks,
  signature matches. `out/substrate.db` mtime is unchanged from before this session. Proven a
  second way for the v5 bump: a fresh v5 reconcile of the same `out/` markdown reproduces
  `4a4f765c9ad75dc9` at 1811 chunks — confidence is a new COLUMN, never in the
  `(chunk_id, text_with_path)` FTS signature.
- **179 tests green** across 16 files. Lint clean on changed files; the 4 remaining
  `reader.py` E702s are pre-existing at committed HEAD.
- **demo-vault compose unchanged** except for the new A22 line — same assertions, same counts,
  `9 documents · 13 passages · 13 outlines`. The pilot uses its own index root and DB.
- **Engine changes in this phase:** F8 (A22 + the `document_checks` extraction) and the
  confidence axis (§6, schema v5). The pilot content itself is markdown plus a manifest.
- Untouched, as instructed: `markdown/emit.py`, `report/review.py`, `tests/test_repaired_samples.py`.

---

## 8. Recommendation — bank vs. migrate vs. fix an engine gap

**F8 and F9 are fixed. Bank the rest; do not start the broad migration yet.**

| | call | why |
|---|---|---|
| ~~Fix now~~ **DONE** | F8 — per-document assertions on the vault path (A22) | It was a gate reporting PASS while the condition it named was unestablished, sitting directly on the migration path. Fixing it after migrating a hundred notes would have meant re-verifying a hundred notes. |
| ~~Fix now~~ **DONE** | F9 — the manifest TOML scoping bug | A shipped defect that made a documented manifest key silently non-existent. |
| **Decide, don't build** | F3 — confidence/provenance has no carrier | A Doc-2 §6 amendment (does the spine get a provenance field?), not a bug. It silently breaks WRITING.md rule 6 today, so it deserves an explicit answer — including "body prose is enough" — rather than drifting. Adversarial review sharpened this: `model-engine-design` declares `status: active` while its source said "proposed, not implemented", so an unbuilt design retrieves as live. |
| **Decide, don't build** | F6b — nothing checks a declared `doc_type` against its body | `doc_type` on migrated content is the migrator's assertion, not a verified property. Either accept that, or the lint (below) is where it gets checked. |
| **Policy, before scale** | F5 — superseded content dominates the index | Decide whether superseded notes are embedded at all, before the vector arm meets a real vault. Cheap now, expensive to reverse. |
| **Recommended, small** | manifest shape validation | Would have refused F9 at parse time; stops it recurring. Not done — new scope, not a defect repair. |
| **Bank** | F1, F2, F4, F6, F7 | Migration labour, not engine work. The structure held; the cost is judgment per note, which Doc 2 §8 already says is supervised and manual. |
| **Do not build yet** | the weekly lint | Doc 2 §8 is right that it needs a migrated corpus to audit against. F6 also shows it needs a code-fence-aware link scanner, and F6b shows body-vs-`doc_type` is the check worth putting in it. |

The honest summary of the pilot's own question: **the structure is ready and the engine is one
assertion-wiring change away from being ready.** What is not ready is the *volume* — F1 (a status
judgment per note), F2 (a rewrite for every blended note), and F4 (a domain assignment per note)
mean a hundred-note migration is a hundred judgments, not a script. That was Doc 2 §8's claim, and
the pilot confirms it at a measured rate rather than as an assumption.

---

## 9. Adversarial review — the final gate

Two reviewers, each given **only** the 2,858-line diff (46 files, Phase 1 engine + Phase 2 pilot,
including the full 838-line real note) and told to assume it is broken. No author reasoning, no
repo access. Report-only by the skill's rules — the one exception is noted below.

### Acted on

| # | finding | disposition |
|---|---|---|
| **A-H1** | `reference_domains` swallowed into `[reference_pins]` (HIGH, reviewer A) | **Verified and FIXED** (F9, §5). A genuine shipped defect in content, worse than reported — the pre-existing demo-vault manifest had it too. Fixed rather than merely reported because it is a defect in content authored in this change; everything else below is left for your call. |
| **A-L / B-H** | operator notes declared `reference` are narrative; `decision` notes don't match the decision shape | **Accepted as a finding**, written up as F6b (§3). Both reviewers landed on it independently. My labels, my error — corrected in the read-out rather than by relabelling the notes, because the honest finding is that nothing verifies the label at all. |
| **B-M** | dangling body wiki-links | Independently confirms F6, found during the build. |

### Dismissed with evidence

Each was checked against running code, not argued away.

| finding | why it does not hold |
|---|---|
| **v3→v4 raises `no such column`** (both, MED/LOW) — "the DDL is all `IF NOT EXISTS`, the drop path is asserted only by a comment" | `migrate()` drops and rebuilds on a version mismatch. Verified concretely: built a fake v3 DB with the old column set, opened it with the new code → `user_version` 4, `documents.doc_type` present, rows rebuilt to 0, `SELECT doc_type FROM chunks` runs with no `OperationalError`. Same result the spike readout documented for v2→v3. |
| **orphan chunk with NULL `doc_type` escapes both halves of A21** (both, MED/LOW) | `chunks.doc_type` is `NOT NULL` — the insert is refused by the schema, so the state cannot exist. An orphan chunk with an *invalid* value is caught: A21's chunk validity scan is independent of the drift join (verified — inserted an orphan with `doc_type='tutorial'`, A21 refused: `chunks=1`). What genuinely escapes is an orphan with a *valid* doc_type, which is a reconcile defect caught by A-compose's `indexed ⊆ ingested` check, not a doc_type one. |
| **`_col(r, "doc_type", "reference")` fabricates a job when a SELECT omits the column** (both, MED) | Every `_row_to_hit` caller projects `c.*` — the shared `_SELECT` constant and the vector path's inline select both do. Verified all six call sites. The default is defensive, not live. Fair as a future hazard if someone writes a hand-rolled projection; nothing today. |
| **A21 asserts a property it never establishes — a corpus where nothing declared prints `PASS by doc_type {'reference': N}`** (B, HIGH) | True on the bare `index` path, false on the vault path this change is about: `compose` passes `require_status=True`, so an absent doc_type is refused at ingest before any write. It restates the known `cmd_index` asymmetry (crosscheck S1), which is symmetric with `status` and documented. |
| **`_source_meta` makes any note beneath a source dir inherit its `doc_type`** (B, MED) | The inheritance is gated on `"passages" in parts` — only files under a `passages/` directory. A note in a source folder but outside `passages/` inherits nothing. Overstated. |
| **`doc_type: null` reports FAIL while an omitted key is N/A** (A, LOW) | Correct as described, and correct as designed: a key present with an explicit null is a malformed spine block; an absent key is a pre-doc_type ingest dir. The leniency is deliberate and documented. |

### Reported, not acted on — your call

Neither reviewer's remaining findings clear the bar for me to change code unasked; all are recorded
here so none is silent.

- **A21's drift half is tautological for engine-written data** (A, HIGH). Fair: both columns are
  assigned from one local inside one transaction, so only out-of-band SQL can trip it — which is
  what its test does. Counter: that is what a denormalization invariant is *for*, catching a future
  writer that updates one table and not the other, and A20 has the identical shape. Worth an
  explicit "keep or drop" the same way A1 was.
- **`require_status` now gates `doc_type` too** (B, MED) — one flag, two contracts. Independently
  re-found; this is crosscheck's N-C1. A rename to `require_spine` touches two call sites.
- **`WRITING.md` is unreachable by retrieval** (B, MED). True and deliberate (`SKIP_NAMES`), but the
  consequence is real: "how do I write a decision note" retrieves nothing. Read-wholesale is a
  correct call for a multi-job document; whether the standard should *also* be retrievable is a
  question the diff answers implicitly.
- **Two byte-identical copies of `WRITING.md`** (both) — core-vault and pilot-core-vault, no
  generation step, nothing keeping them in sync. The next edit to one forks the standard.
- **Rule 7 violated inside migrated content** (B, MED) — `model-strategy-decisions` says "the
  measured 0.79→1.00" with no metric, cohort, config or date. Real, and a good illustration: the
  standard is not retroactive, and preserving content verbatim preserves its rule violations.
- **`source_status` is a second `status`-suffixed key** (B, LOW) — against WRITING.md's reservation
  of `status`. My migration technique; defensible as an audit trail, but it does bend the rule.
- **A20 counts chunks, A21 counts documents, on adjacent lines with no unit named** (both, LOW).
- **`idx_chunks_doc_type` is unused** (B, LOW) — the deferred-filter cost you accepted in A1.
- **`Hit.doc_type` inserted mid-dataclass** (A, MED) — positional construction outside `_row_to_hit`
  would shift fields silently. No such construction exists today.

---


## 10. Crosscheck — the implementation pass

Three fresh-context reviewers (correctness / simplicity+architecture / security), each given the
diff plus the touched files opened for full context. 27 findings. Every claim below was verified
against running code before being applied or dismissed.

### Applied — 7

| # | finding | lenses | evidence |
|---|---|---|---|
| 1 | **A1/A1b were fatal gates over authored markdown.** `residue()` matches `[a-z]\s*[!­‐‑]\s*[a-z]` — `!` is in that class because Docling renders DDIA's soft hyphen as `!`. On markdown it counts ordinary exclamations. | arch + correctness | `residue("Wow! it works. No! and then. Yes! but only sometimes.") == 3`, gate is `<= 2`. Three such sentences in one migrated note refuse the **entire composed vault**, with a message about hyphens. Now PDF-path only. |
| 2 | **A17 could refuse a vault over a faithful book slice.** Its denominator is the max page anchor *in the slice*, not the book's page count. | correctness | The pilot's DDIA passages pass only because they came from pp. 280–292 (denominator ~282). The same slice from Chapter 1 fails at 56%. Now report-only for markdown, matching A14. |
| 3 | **The v5 bump silently wiped any existing index on `query`.** Only `cmd_index` checked `store.rebuilt`. | security | Reproduced: a v4 index reopens with `documents=0` and `search` returns `[]`, shown as `(no results)` — indistinguishable from a genuine no-match. Read paths (`query`, `embed`, `eval`) now refuse with exit 2 and name the fix. |
| 4 | **`cmd_index` wrote unvalidated spine values.** | security + correctness | A hand-edited `run.json` with `confidence: "verified-by-me"` reached the index and printed on every hit. Sharper for confidence than status: an invalid status is *filtered out*, an invalid confidence is *displayed*. Now runs A21/A23 — verified refused at exit 3. |
| 5 | **`emit.py` did not round-trip `doc_type`/`confidence`.** | **all three** | §3b makes re-ingestion a designed operation, so every regeneration cycle turned `decision`/`proposed` into `reference`/`unstated` — the laundering the axis exists to stop, produced by the engine on its own artifact, under a comment asserting the invariant it broke. Two lines + a round-trip test. |
| 6 | **`_source_meta` resolved `passages/` on the ABSOLUTE path.** | security | A vault living under any directory named `passages` inherited an out-of-scope `_meta.md` — which, after this change, could set settledness. Now vault-relative, `rindex` (nearest source wins), and asserted inside the vault root. `_discover_notes` already guarded SKIP_DIRS this way. |
| 7 | **A template trap I introduced in 10 sites.** `confidence: <…>   # omit if the note makes no claim` — the parser takes everything after `:` verbatim, so following the instruction yields an invalid value that refuses the whole scope. | correctness | Guidance moved into prose. General rule now stated: no explanatory comments inside a parsed frontmatter value. |

Plus the doc/attribution sweep: the schema changelog reordered (it listed v5 above v4) and its
docstring's denormalized-columns list corrected to include `confidence`; `cmd_compose`'s docstring
now names all five assertions rather than two; and a `SpineError` on an inherited value now names
the `_meta.md` that supplied it rather than the passage that merely received it — the
naming-the-wrong-component failure this project already paid for once.

`chunks.superseded_by` is deleted too. It was dead by the exact criterion this change used to
delete the `confidence REAL` columns, and keeping one while deleting the other would leave the next
reader unable to tell which dead columns are intentional.

### Dismissed with evidence

- **Orphan chunk with a NULL confidence escapes A23** — `chunks.confidence` is `NOT NULL`; the
  insert is refused by the schema. An orphan with an *invalid* value IS caught (verified: A23
  refused `doc_type='tutorial'` on an orphan via the standalone chunk scan).
- **`_col` fabricates a value when a SELECT omits the column** — all six `_row_to_hit` callers
  project `c.*`. Defensive, not live.
- **A21/A23 "PASS" overclaims on a corpus where nothing declared** — true on the bare `index` path,
  which is what finding #4 closed; on the vault path `require_status=True` refuses absence at ingest.

### Reported, not applied — housekeeping for a tidy-up pass

`assert_confidence_valid` duplicates `assert_doc_type_valid` (three SQL statements; the narrating
docstrings are the part that earns its keep and should survive any extraction); `document_checks`
returns raw 4-tuples where this repo models records as dataclasses; assertion *policy* lives in
`cli.py` rather than a `substrate/checks.py`; `unstated` is declarable despite a comment saying it
is not (the `CONFIDENCES`/`STORED_CONFIDENCES` split is unenforced at the one call site that would
justify it); four indexes serve filtering that is still deferred.

**A pattern worth carrying forward:** findings #1 and #2 are the same shape — an assertion
calibrated on PDF extraction physics, silently inherited by the markdown path, where it can only
false-reject. A22 is what exposed both, by promoting the per-document suite to a gate. Every
remaining A-series check deserves the same re-examination as markdown ingestion matures.

---

---

## 11. Where the vaults live

After the core-tier migration the vaults were split by purpose, because one directory was doing two
jobs — shipping an engine example and holding the operator's real knowledge.

| | location | tracked | what it is |
|---|---|---|---|
| `demo-core-vault` + `demo-vault` | `substrate/vaults/` | **yes** | synthetic example pair; also the engine's regression fixture (9 notes, every status, clean assertions) |
| `core-vault` | `~/OneDrive/vaults/core-vault` | no | the real Tier 1+2 — 27 operator notes migrated from ClaudeVault, plus the DDIA reference |
| `scripta-vault` | `~/OneDrive/vaults/scripta-vault` | no | the real Tier 3 for the call-capture project |

`~/OneDrive` is a symlink to `~/Library/CloudStorage/OneDrive-Personal`. Markdown on a cloud drive is
explicitly sanctioned — Doc 2 §0 names iCloud, Dropbox and a NAS as equally fine, because the engine
reads whatever paths the manifest points at. The DERIVED INDEX stays in the repo's gitignored
`out-vault/`, which is what Doc 2 §5 actually warns about: a live SQLite file over file-sync
corrupts. That separation is now load-bearing rather than incidental.

This is Doc 2 §0 working as specified: the engine has an opinion on **shape** and none on
**location**. No manifest edit was needed — `inherits = ["core-vault"]` is a bare name, which
resolves against the *project vault's parent*, so moving both together kept the link intact. The
index signature was identical before and after (`v5:9db7461acae8`), which is the proof the move was
content-neutral.

The operator chose OneDrive Personal. Their
`vault-sync.sh` uses an **explicit allowlist** and skips any directory without a `.git`, so the two
new vaults are not synced to GitHub and nothing propagated on the move. Opting them in is a
deliberate act: `git init` each, add a remote, add the path to `VAULTS=(…)`.

**Consequences worth knowing.** The real vaults are now unversioned — until they are git-init'd,
there is no undo for a bad edit, and the migration that produced them took a day of judgment.
`substrate/CLAUDE.md` was repointed at the in-repo example copy of `WRITING.md`; the real copy lives
in `~/OneDrive/vaults/core-vault` and the two have no generation step keeping them in step, which is the
fork hazard both adversarial reviewers flagged, now spanning a repo boundary. The derived index
still writes to the repo's gitignored `out-vault/`, which is fine per Doc 2 §5 (disposable,
per-machine, never cloud-synced) but is worth moving if the repo is ever cloned elsewhere.

## 12. Reproduce

The vaults moved out of the repo after the migration (§11). The repo keeps only the example pair.

```bash
cd substrate

# the operator's real vaults — outside the repo, per Doc 2 §0
uv run python -m substrate.cli compose ~/OneDrive/vaults/scripta-vault --clean \
    --index-root out-vault/real-index --db out-vault/real.db
uv run python -m substrate.cli query "<q>" --db out-vault/real.db --no-vector

# the example pair — synthetic, in-repo, doubles as the regression fixture
uv run python -m substrate.cli compose vaults/demo-vault --clean

uv run python -m substrate.cli verify out-vault/real-index/scripta-vault__model-engine-panel-raw__*
uv run python tests/test_compose_assertions.py && uv run python tests/test_confidence.py
```
