# PropertyPrismVault → prism-vault — the vocabulary map

Step 1 of the project-vault migration. **Reports the mapping; applies none of it.** Written
2026-07-27 against `~/vaults/PropertyPrismVault` (read-only) and the engine at `76c3bdd`.

---

## 0. Verdict

**The engine is not the obstacle. All 187 durable notes ingest clean at compose strictness once a
spine is supplied — 0 fatal, 0 warnings, A18 coverage min 0.9906 against a 0.99 gate.** The
migration's entire cost is vocabulary and judgement, exactly as Doc 2 §8 and PILOT-READOUT §8
predicted, and none of it is engine work.

Two numbers set the real scale:

| | |
|---|---|
| notes whose `status` the engine already accepts | **2 of 187** |
| notes carrying a `doc_type` at all | **0 of 187** |

So every note needs both spine fields authored. `doc_type` does not exist upstream in any form —
the field this vault calls `type` is a 12-value taxonomy that answers a different question.

---

## 1. The corpus, exactly

266 markdown files. The brief's 261 was low; the durable count it quotes is right.

| group | selector | n |
|---|---|---|
| session logs | `07 - Sessions/*.md` | 74 |
| templates | `06 - Templates/*.md` | 5 |
| **durable** | `00 - MOC` + `02 - Notes/*/` + `03 - References` + `04 - Synthesis` | **187** |

The brief's field counts (`area` 174, `type` 170, `status` 166, `last-updated` 158, `supersedes` 13)
all reproduce exactly and are durable-scoped. 12 durable notes carry no frontmatter at all — six of
them are the entire `00 - MOC/` directory.

---

## 2. The assertion sweep — PRINCIPLES.md's second law, discharged

**Nothing to sweep. The calibration audit the second law demands has already been paid.**

`checks.py` disables or neutralises every PDF-calibrated check on the markdown path: A1/A1b are not
emitted (`checks.py:74`), and A14-coverage, A14-paths and A17 all evaluate `ok = <test> or is_md`
(`checks.py:128,147,150`). What remains fatal in A22 — A12, A18, A19×3 — restates a gate that
already raised inside `ingest_markdown`, so **A22's fatal tier cannot fire on a note ingested in the
same run.** The two live checks, `A13-fragments` and `A13-oversize-prose`, are warn-only by
`_QUALITY_CHECKS` (`checks.py:26`).

The refusal surface therefore sits upstream, in `ingest_markdown`. Measured there against the real
corpus, with a minimal valid spine synthesized so that only *content* defects could surface:

```
staged 187 notes · ingested 187 · FAILED 0
A22 sweep: FATAL 0 · WARNING 0
A18 source_coverage (gate 0.99): min 0.9906 · median 1.0000 · below 0.99: 0
```

**Mutation-verified**, per the second law's own rider that a sweep which cannot fail proves nothing.
Three notes replayed with their original frontmatter all refuse:

| note | outcome |
|---|---|
| `Go Backend Architecture.md` | `SpineError: status 'stable' is not one of [...]` |
| `Entitlements Layer Design.md` | `SpineError: no status` — though it declares `status: draft` |
| `Backend MOC.md` | `SpineError: no status` |

The second row is the interesting one and is covered in §6.

---

## 3. `type` → `doc_type`

170 durable notes carry `type`; 17 do not. The engine's set was closed to four when this survey
ran; it is five now (`spine.DOC_TYPES`) — see §11.

| source `type` | n | → `doc_type` | call |
|---|---|---|---|
| `concept` | 70 | `explanation` | **contested — see below** |
| `reference` | 51 | `reference` | clean |
| `adr` | 15 | `decision` | clean 1:1; distinct body shape |
| `glossary` | 12 | `reference` | clean |
| `runbook` | 11 | `how-to` | clean |
| `workflow` | 5 | `how-to` | clean |
| `audit` | 1 | `reference` | judgement — findings list |
| `debugging` | 1 | `explanation` | judgement — why it broke |
| `gotcha` | 1 | `explanation` | judgement |
| `process` | 1 | `how-to` | judgement |
| `design-sketch` | 1 | `decision` + `confidence: proposed` | judgement |
| `roadmap` | 1 | — | **misfit (§7)** |
| *(absent — 5 Synthesis)* | 5 | — | **misfit (§7)** |
| *(absent — 12 no frontmatter)* | 12 | 3 ADRs → `decision`; 3 notes by content; 6 MOCs → **misfit (§7)** | |

### The `concept` call is the biggest single bet in the migration

`concept` is 41% of the typed corpus, and the source vault's `concept` / `reference` distinction
**carries no body-shape signal**. Measured as the share of non-empty body lines that are table rows,
list items or fences:

| source `type` | n | mean structured | ≥60% structured |
|---|---|---|---|
| `concept` | 70 | 73% | 59 |
| `reference` | 51 | 73% | 41 |
| `glossary` | 12 | 80% | 11 |
| `adr` | 15 | 71% | 12 |
| `runbook` | 11 | 59% | 5 |

Identical means. By WRITING.md's shape rule — `reference` is "tables / definition lists, no
narrative", `explanation` is "prose acceptable" — 59 of the 70 `concept` notes are reference-shaped.
Mapping them to `explanation` is a claim about their **job** ("read once to understand") rather than
their shape, and nothing in the engine verifies it: A21 proves the value is one of the vocabulary and that
chunks agree with their document, never that the note does that job.

That is PILOT-READOUT F6b recurring at 70× the pilot's scale. **Recommended anyway** — the
alternative collapses `reference` + `concept` + `glossary` into 133 of 187 notes sharing one value,
which destroys the axis's ability to discriminate. Recorded here so the assertion is auditable
rather than silent.

---

## 4. `area` → `domains` — these are not the same axis

**`area` must not be mapped onto `domains`.** `area` partitions *this project* (which subsystem);
`domains` is the cross-vault retrieval axis (which field of knowledge), shared with core-vault and
five sibling scopes. Injecting `backend` / `cross-cutting` / `domain` into it would put project
folder names into a vocabulary every scope inherits — and `domain` as a domain is incoherent.

The established convention already proves the point: the four existing prism-vault notes use
`[software-dev, frontend, databases, networking]`, drawn from the shared 15-value vocabulary, not
from Prism's internal areas.

Proposed seed — a defensible default, not a substitute for the per-note decision F4 names:

| `area` | n | → `domains` seed | → folder |
|---|---|---|---|
| `domain` | 52 | `[cre]` | `02-areas/domain/` |
| `infrastructure` | 32 | `[software-dev, tooling]` | `02-areas/infrastructure/` |
| `cross-cutting` | 32 | `[software-dev, architecture]` | `02-areas/cross-cutting/` |
| `frontend` | 31 | `[software-dev, frontend]` | `02-areas/frontend/` |
| `backend` | 25 | `[software-dev, databases]` | `02-areas/backend/` |

`cre` exists today only in cbre-vault (4 uses). Both projects are commercial real estate, so the
value is right and the vocabulary is shared by design. `domains` is **open** — `reader.py:64`
shape-checks each tag and silently drops anything that fails, with no membership set anywhere — so
nothing refuses a new value, and nothing warns about a typo either.

`area` itself should be preserved as `source_area:` under the `source_*` convention, or dropped.
Two misfits: one capitalised `Frontend`, one `[domain, backend]` flow list.

---

## 5. `status` → `status`

163 of 165 parsed notes carry a value outside the engine's four (`spine.py:23`).

| source `status` | n | → `status` | note |
|---|---|---|---|
| `stable` | 135 | `active` | the vault is live work; `complete` means finished |
| `accepted` | 12 | `active` | an accepted ADR is a live decision |
| `populated` | 6 | `active` | the 5 Synthesis notes + 1 |
| `needs-input` | 5 | `active` | live and incomplete |
| `proposed` | 3 | `active` | **carries a confidence signal** |
| `resolved` | 1 | `complete` | |
| `draft` | 1 | `active` | **carries a confidence signal** |
| `design-agreed-unbuilt` | 1 | `active` | **carries a confidence signal** |
| `superseded` | 1 | `superseded` | **blocked — see §6** |
| `active` | 1 | `active` | already valid |
| *(absent)* | 21 | must be authored | 12 no-frontmatter + 9 with frontmatter |

`active` vs `complete` has **no retrieval consequence** — `INCLUDED_STATUSES` is
`{active, complete}` (`spine.py:24`), so both are in the default set. The distinction is semantic
only. `archived` is unused upstream and prism-vault has no `_archive/` folder.

`provisional` is **not available**: the four occurrences the target-vault survey reported are all in
`core-vault/99-templates/`, which is in `SKIP_DIRS`. Live content across all seven vaults uses the
engine's closed sets with zero exceptions.

---

## 6. Verified landmines

### `superseded-by` vs `superseded_by` — a third-law instance, and it blocks one note

The vault writes **`superseded-by:`** (15 uses, zero with an underscore). The engine reads
**`superseded_by:`** (`reader.py:325,352`). The key is silently ignored.

`02 - Notes/Cross-Cutting/Auth (Clerk JWT and API Keys).md` is `status: superseded` and carries
`superseded-by: "[[Auth (WorkOS JWT and API Keys)]]"`. At compose it refuses with *"superseded with
no superseded_by"* while visibly carrying one. Two edits, not one: rename the key, **and** replace
the wikilink with the target's `doc_id` — `_DOC_ID` rejects brackets, spaces and uppercase, so the
value would be dropped even under the right key.

### `supersedes` is dead metadata

13 durable notes carry it; **12 are empty**, and the one populated value is free prose
(`parts of ADR-012 (WorkOS-side platform scope injection + in-app /platform page)`), not a link.
The only machine-resolvable supersession fact in the whole corpus is the `superseded-by` above.
Decision history in this vault lives in prose, not in frontmatter — WRITING.md rule 5 will have to
be satisfied by reading bodies.

### One note loses its entire frontmatter to a block list

`02 - Notes/Cross-Cutting/Entitlements Layer Design.md` writes `tags:` as a YAML block list. Any
non-blank frontmatter line without a `:` makes `_parse_frontmatter` return `{}` and treat the whole
block as body (`reader.py:116-117`), so the note's declared `status: draft` never reaches the
validator and it refuses as *"no status"*.

**Exactly one note of 187** — the risk is real in kind but not in scale, because this vault writes
flow lists everywhere else. Worth a one-line pre-flight grep regardless, since the failure names the
wrong cause.

### Clean, verified absent

`0` single-quoted scalars · `0` inline `#` comments in spine values · `0` declared `doc_id`s (so no
silent shape-drops) · `0` notes missing both `title:` and a heading · `0` duplicate filename stems
within the 187 · `0` stem collisions against core-vault's 46.

### Thin margins worth knowing

Two notes sit below 0.995 A18 coverage against a 0.99 gate (min 0.9906). 34 notes use code fences
with an info string richer than a bare language, and 2 have ordered lists reaching item 10+ — the
two known token-loss vectors. None fails today; edits during migration could move them.

---

## 7. The misfits — 12 notes with no `doc_type` home

They are not scattered. They are one shape: **navigational and running-summary documents.**

| what | n | why nothing fits |
|---|---|---|
| `00 - MOC/*.md` | 6 | 61–69% of non-empty lines are wikilinks; no frontmatter; pure link lists |
| `04 - Synthesis/*.md` | 5 | 167–286 lines; the only notes with `area` + `status` + `last-updated` and **no `type`** — the vault itself never named their kind |
| `type: roadmap` | 1 | forward-looking plan; nothing chosen (not `decision`), not look-up, not steps |

Doc 2 does have slots for the first group — `00-index/MEMORY.md` and `log.md` — and the prior
migration used them: all six ClaudeVault project `Index.md` notes were split that way, recorded in
each project vault's `log.md`. But **`MEMORY.md` and `log.md` are in `SKIP_NAMES`**
(`vault.py:44`), so that slot is deliberately outside retrieval.

The gap is therefore narrower and sharper than "Doc 2 is missing a tier":

> A project's running summary has a **physical** home and no **retrieval** home. Split it as
> prescribed and the map and the history become unsearchable; keep it whole and it has no
> `doc_type`.

The 5 Synthesis notes are the case that makes this bite. Each is a substantive 167–286-line
per-area summary that the MOC files explicitly route to (`> Entry point: [[<Area> - Synthesis]] —
read this first`). Under the current structure they are either chopped into atomic notes — losing
the summary that is their whole value — or filed as `MEMORY.md` content and never retrieved.

The identical complaint is already on record twice: PILOT-READOUT §9 logs an adversarial reviewer
on `WRITING.md` — *"unreachable by retrieval … 'how do I write a decision note' retrieves nothing"* —
and core-vault's own `log.md` records ClaudeVault's root `MEMORY.md` being refused migration outright.

**DECIDED 2026-07-27 — add a fifth `doc_type`, `digest`.** Shipped; see §11. The two rejected
alternatives were filing the Synthesis notes as `reference` (cheapest, but the label is wrong and
F6b guarantees nothing would ever catch it) and making `SKIP_NAMES` opt-in per file (fixes the
retrieval half but still leaves the shape unnamed, so the next writer has no word for it).

---

## 8. `confidence` — DECIDED: the source-signal default

Adopted 2026-07-27. Nothing is invented; every value traces to declared source signal, and the
absence of signal is carried as `unstated` rather than filled.

| → `confidence` | n | drawn from |
|---|---|---|
| `proposed` | 5 | source says `proposed` ×3, `draft`, `design-agreed-unbuilt` |
| `stated` | 12 | `type: adr` + `status: accepted` — a ratified decision |
| `stated` | 5 | the Synthesis digests — inventories, per WRITING.md |
| `unstated` | 165 | no signal |
| `verified` | **0** | nothing in this corpus was measured |

The zero is the point: `verified` is reserved for a claim testing could have shown wrong, and a
vault of architecture notes contains none.

What the source actually supports:

| population | n | evidence |
|---|---|---|
| source states unsettledness — `proposed` ×3, `draft`, `design-agreed-unbuilt` | 5 | declared settledness; `confidence: proposed` is carried signal, not inference |
| `type: adr` + `status: accepted` | 12 | a ratified decision — `stated` is defensible |
| the 5 Synthesis notes | 5 | inventories; WRITING.md forces `stated`, never `verified` |
| everything else | 165 | **no signal** — `unstated` is the honest value |

WRITING.md is explicit that an invented marker is worse than an absent one and that `unstated` is
what the axis is for. There is no `confidence` field upstream at all, so nothing needs preserving
under `source_confidence:` — unlike ClaudeVault, which wrote a high/medium/low certainty scale.

---

## 9. Recommended order

1. **Partly decided.** §8 confidence and the session logs (§10) are settled, and `digest` closes
   the 5 Synthesis notes. **Two of §7's twelve misfits are still open** and need a disposition
   before the full pass:
   - **the 6 MOC files** — pure link lists that route to the Synthesis notes. Folding them into
     `00-index/MEMORY.md` keeps them unretrievable; merging each into its area's `digest` is the
     alternative, and is probably right since a MOC and a Synthesis note are the same job at two
     densities. Not decided.
   - **`type: roadmap` (1 note)** — still fits none of the five. Doc 2 §6a's new boundary rule says
     a sixth value needs a *job* none of the five expresses; a roadmap plausibly reads as
     `explanation` (current plan and why) or `decision` (what was sequenced). Pick one; do not add
     a sixth value for one note.

   `claude-vault` MCP retirement remains open and does not gate this work.
2. `git init` the target vault. `PILOT-READOUT §11`: the real vaults are unversioned and there is no
   undo.
3. **Rewrite `prism-vault/00-index/MEMORY.md`.** It currently states *"Not a copy of
   PropertyPrismVault"* as a deliberate scoping decision. Migrating 187 notes makes that false.
4. Migrate the 26-note Backend slice, compose to a **repo-local** `--index-root`, report refusals.
5. `.substrate.toml` — `reference_domains` currently declares `[software-dev, frontend, databases]`
   and the vault already uses `networking`. Extend it; keep it **above** `[reference_pins]` (F9).

**Never point `--index-root` at a vault.** `cli.py:346-349` runs `shutil.rmtree(index_root)`
unconditionally under `--clean`, with no guard that it differs from the vault path.

---

## 10. The 74 session logs — DECIDED: migrate as `class: conversation`

They go to `prism-vault/_sources/`, the established home — `cbre-vault`, `core-vault` and
`school-vault` already use it, and `EXCLUDED_CLASSES = {"conversation"}` (`classes.py:123`) keeps
them out of default retrieval while leaving them reachable on request. This takes the corpus from
187 to **261 notes**.

Two things to carry into that pass:

- **`class:` and `document_class:` are both read now** (`reader.py:338-339`), so PRINCIPLES.md's
  third-law incident — six conversations silently defaulting to `reference-frozen` — cannot recur.
  Verify it anyway on the first batch: that law's whole point is that the failure is invisible from
  inside the system.
- **`_sources/` is not in Doc 2 §4's skeleton** even though three vaults use it. §4 permits added
  folders, so this is legal, but the skeleton should probably name it. Left as a spec observation,
  not changed here.

---

## 11. What shipped this session

The `digest` doc_type, end to end.

| | |
|---|---|
| `spine.py:38` | `DOC_TYPES` gains `digest`, with the rationale and the points-not-contains rule |
| `models.py` · `render.py` · `cli.py` · `mcp/server.py` · `store/schema.py` | five prose enumerations that would have gone stale — a docstring is a claim |
| Doc 2 | **§6a written** — it was cited by WRITING.md and `spine.py` and did not exist. Closes part of SESSION-HANDOFF open item #2 |
| `WRITING.md` ×2 | five-row table, the digest discipline, a template; both copies verified byte-identical |
| `tests/test_spine.py` | a literal vocabulary pin **and** an iterating validator check — see below |
| `tests/test_doc_type.py` | seeds `digest`; asserts the seed covers all of `DOC_TYPES` |

**No schema bump.** `doc_type` is TEXT; the vocabulary lives in `spine.DOC_TYPES`. Schema stays v6,
and `store/schema.py`'s v4 changelog entry now says so explicitly rather than reading as the current
value set.

**A defect this pass introduced and the mutation check caught.** Replacing the hardcoded four-value
tuple in `test_each_valid_doc_type_accepted` with an iteration over `DOC_TYPES` made the test
*unable to detect a value being removed* — shrinking the constant just shrinks the loop. That is
PRINCIPLES.md's "a test that cannot fail is worse than no test", introduced while fixing a different
smell. The fix is that both assertions are needed and they are different: a **literal pin** catches
deletion, an **iteration** catches the validator falling behind an addition. Both are present, and
both were mutation-verified.

**Verified unmoved:** `out/substrate.db` FILE sha256 `7311ffbf3180…`, 1811 chunks, `user_version`
2, read via `mode=ro`. "Unmoved" is a claim about the DATABASE, not the directory — the sidecar
`-shm` is touched by any read-only open and `-wal` stays 0 bytes, so the artifact set is not
byte-frozen even though the DB is. Note this is the file hash the session brief supplied, NOT the
`4a4f765c9ad75dc9` *content signature* the other readouts quote — a byte-identical file is the
stronger claim, but the two are different artifacts and must not be conflated. **The content
signature's derivation is recorded nowhere**: 17 plausible constructions over
`(chunk_id, text_with_path)` reproduce none of it, so no one can currently re-check it. That is
WRITING.md rule 7 failing on the project's hardest invariant — see §12. demo-vault composes
identically (`9 documents · 13 passages · 13 outlines`, `v6:58a05fa702ca`). 318 assertions green
across 23 files, lint clean on every changed file.

---

## 12. Open, found while shipping §11

- **The eval content signature has no recorded derivation.** `SESSION-HANDOFF.md`,
  `VAULT-SPIKE-READOUT.md` and `PILOT-READOUT.md` all quote `4a4f765c9ad75dc9` over
  `(chunk_id, text_with_path)` as the project's hardest invariant. 17 plausible constructions
  (sort orders × separators × sha256/sha1/md5/blake2b × a rolling per-row digest) reproduce none of
  it. The number is therefore unverifiable by anyone who did not write the original script, which
  is WRITING.md rule 7 failing exactly where it matters most. The **file** sha256 is a stronger and
  checkable substitute (`7311ffbf3180…`) — but if the content signature is to stay in the docs as an
  invariant, the derivation has to travel with it.
- **`_sources/` is used by three vaults and is not in Doc 2 §4's skeleton.** §4 permits added
  folders, so nothing is broken; the skeleton should probably name it.
- ~~**`digest` collides with "content hash" in engine prose.**~~ **CLOSED** — all 14 hash-sense
  uses across `freshness.py`, `models.py`, `notes.py`, `reader.py`, `cli.py` and `mcp/server.py`
  are now `checksum`, and WRITING.md's Glossary pins both senses.
- **`cli.py:346-349` still `shutil.rmtree(index_root)` with no guard** that it differs from a vault
  path. Pre-existing, confirmed, out of scope here — but the migration ahead runs `compose` against
  real vault paths repeatedly, and the vaults are unversioned. A comment is the only guard.
- **`demo-vault` has no `digest` note**, so the value has never traversed the real
  read→compose→index path inside the regression fixture. It was proven on a real PropertyPrism
  Synthesis note and on a scratch vault instead. Extending the fixture is a deliberate change to a
  regression baseline and is left to you.
- **`status` reports `freshness: UNCHECKABLE` for an authoring fault.** `introspect.status_payload`
  replaces the whole drift payload with `{"error": …}` for ANY `VaultError`, so a misplaced digest
  now reads the same as a vault that no longer exists. Accurate but coarse; the comment there now
  says so.
