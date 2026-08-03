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

> **Superseded 2026-07-28 in VOCABULARY only — the policy itself stands.** Absence now stores
> `unjudged`; `unstated` is reserved for a note that DECLARES it makes no settledness claim.
>
> **The two counts in play have different cohorts and must not be compared.** The `165` tabled
> below is *this section's* cohort: the 187 durable PropertyPrismVault notes, projected before
> migration. The `530 of 657` quoted in `spine.py` and elsewhere is a different measurement
> entirely — **distinct documents across all six composed scopes, deduplicated by `doc_id`**
> (core-vault is re-counted in every scope), taken from the databases on 2026-07-28. One is a
> pre-migration projection over one vault; the other is a post-migration census over all of them.
>
> Those 165 declared no `confidence` key, so they store `unjudged`. Six notes corpus-wide — all
> `class: conversation` under `_sources/`, none of them in this cohort — do declare `unstated`
> deliberately, which is the distinction the split exists to keep.
>
> The tables are left as the dated record of the decision, per rule 5. `spine.validate_confidence`
> cites this section as the reason `compose` stays lenient, and that reason is unchanged: a
> guessed marker is still worse than an absent one. What changed is that absence is now
> nameable, so "nobody judged this" no longer masquerades as a judgement.

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

  **Corrected 2026-07-30.** That bullet fixed the ALIAS and left the DEFAULT, so it closed the
  conversation case and none of the general one: every note declaring no class still became
  `reference-frozen`, which measured 83 of 684 declaring across the seven vaults. The reader no
  longer defaults at all — `classes.apply` resolves absence to `unclassified` (schema v9) — so
  "cannot recur" is now true of the defect rather than of one instance of it.
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

---

## 13. The Backend slice — migrated 2026-07-27

**Nothing refused.** 26 notes into `prism-vault/02-areas/backend/`; the composed scope is 66
documents (36 core-vault + 30 prism-vault), every assertion PASS, **0 quality warnings**, vectors
1109/1109, freshness current. That is §2's prediction holding on real migrated content rather than
on a synthesized spine.

Built in a staging copy of the vault first and composed there; only after it passed clean were the
files copied into the live vault. A full backup was taken first, since the vault is unversioned.

| axis | outcome |
|---|---|
| `doc_type` | decision 6 · reference 8 · explanation 8 · how-to 4 |
| `status` | active 25 · complete 1 (the resolved debugging note) |
| `confidence` | stated 5 · proposed 1 · **verified 1** · unstated 19 |
| `domains` | seeded from `area`, refined per note; introduced `architecture`, `tooling`, `cre` |

**One deviation from §8's policy, named rather than buried.** `prism-rls-lookup-before-context`
takes `confidence: verified`, where §8 predicted zero. WRITING.md reserves `verified` for "a bug
confirmed and fixed", which is exactly what that note documents — symptom, root cause, fix,
lesson. The policy's "nothing was measured" held for the corpus as a whole and was wrong for the
one debugging note in this slice; expect the same for the other 7 `debugging`/`incident` notes.

**Two notes had a stale frontmatter `status` that the body contradicted**, and the body won:
`warehouse-integration` was `status: draft` while its body says *"Pull-first DECIDED (2026-06-25) …
first code shipped"* → `active` / `stated`; the two frontmatter-less ADRs carried their status in a
body header (`> Status: **Proposed**`, `> Status: **Accepted — shipped to qa**`) → `proposed` /
`stated`. **Reading only the frontmatter would have mislabelled three of 26.** The originals are
preserved verbatim under `source_status`, including the parenthetical form where there was none.

**Link repair is part of migrating, not a follow-up.** Renaming Title Case → kebab `doc_id` broke
107 intra-slice wikilinks across 22 targets — breakage the migration itself caused, so it was
repaired here: fence-aware rewrite to the new ids, verified 107 → 0. The 66 links that remain
unresolved all point at areas not yet migrated and will resolve as those land.

**Known rule-8 candidate, preserved rather than split:** `warehouse-integration` carries a
superseded push-centric proposal *and* the current pull-first implementation in one note, and has a
duplicated H1. Preserved verbatim per Doc 2 §8 (migration preserves; it does not silently rewrite),
flagged here so the split is a decision rather than an oversight.

`.substrate.toml`'s `reference_domains` was extended to the seven values now in use, so the manifest
and the corpus agree.

---

## 14. The MOC question — resolved 2026-07-27, and Backend done as the pattern

**§7 mapped `digest` to the wrong file, and this corrects it.** `digest` as written into Doc 2 §6a
is *"orientation in an AREA — links + one-line glosses; points, never contains"*. That is the **MOC**,
not the Synthesis note. Each area has both, and they point at each other.

| | `00 - MOC/<Area> MOC.md` | `04 - Synthesis/<Area> - Synthesis.md` |
|---|---|---|
| shape | pure link index, no frontmatter | 286 lines, **five** jobs |
| becomes | `doc_type: digest`, no rewrite needed | split by job |

The Synthesis note was doing five jobs, not the three §7 assumed: §1–9 orientation, §10 a 30-entry
gotcha catalogue, §11 a running activity log, §12 an open-work register, §13 related links.

**Backend, as the pattern for the other four areas:**

| source | → | doc_type |
|---|---|---|
| `Backend MOC` | `02-areas/backend/backend-digest.md` | `digest` |
| Synthesis §1–9 | `02-areas/backend/backend-overview.md` | `explanation` |
| Synthesis §10 | `03-references/backend-sharp-edges.md` | `reference` |
| Synthesis §11 | `log.md`, area-tagged, merged chronologically | — |
| Synthesis §12 | `log.md` → `## Open follow-ups`, area-scoped | — |

**Measured, not asserted:** after the split the digest carries a wikilink on **96%** of its body
lines, the overview on **21%**, the sharp-edges reference on 26%. That is §6a's "points, does not
contain" holding as a number.

**One deviation from how the option was framed.** §10's gotchas were to merge into the existing
`prism-sharp-edges`. They did not: 30 entries × 5 areas would make one ~150-entry mixed-area note,
so they became an area-scoped `prism-backend-sharp-edges` with a pointer from the cross-area one.

### Two things the split surfaced

**A digest competes lexically with the notes it points at — but rarely.** Measured over 6 backend
queries, the digest reached the top 3 exactly **once**, on a query whose gloss text ("Middleware
Stack — 14-stage HTTP chain") happened to match. It did not crowd out the substance on the other
five. Worth re-measuring once four more digests exist; not worth acting on at n=1.

**A core-vault note asserted the old convention and outranked the new one.**
`vault-structure-numbering` said *"Each area has one long-form Synthesis … This is the LLM entry
point"* — accurate for the source vaults, inherited by all six scopes, and it beat the new digest on
*"what is in the backend area and where do I start"*. Amended in place rather than deleted (rule 5):
the Johnny Decimal pattern still describes `~/vaults/*`, and a `**Superseded for migrated vaults**`
block now records that a migrated vault's entry point is its digest. **All six scopes recomposed** so
none keeps serving the old claim.

### Still open

- **The 6th MOC, `00 - MOC/Index.md`** — the vault-level router, prose-heavy. Maps to
  `00-index/MEMORY.md`, which already exists and now points at the Backend digest. No decision
  needed; it just has not been merged.
- **`type: roadmap`** (1 note) — still unmapped. Doc 2 §6a's boundary rule says a sixth doc_type
  needs a *job* none of the five expresses; a roadmap plausibly reads as `explanation`.

---

## 15. Migration complete — all five areas, 2026-07-28

**187 durable notes → 196, composed clean.** 232 documents in scope (36 core-vault + 196
prism-vault), 3814/3814 vectors, freshness current, **0 fatal**, 1 quality warning (A13 fragments,
warn-only by design).

| source | n | → |
|---|---|---|
| `02 - Notes/<Area>/` | 169 | `02-areas/<area>/` — 26 backend + 143 across four areas |
| `03 - References/` | 7 | `03-references/` — vendor notes |
| `00 - MOC/<Area> MOC` | 5 | 5 × `doc_type: digest` |
| `00 - MOC/Index.md` | 1 | `00-index/MEMORY.md` + [[prism-platform-now]] |
| `04 - Synthesis/` | 5 | 5 × `*-overview` (explanation) + 5 × `*-sharp-edges` (reference) + `log.md` |

Final axes: decision 19 · **digest 5** · explanation 56 · how-to 27 · reference 125. Status: active
228 · complete 2 · superseded 2. Confidence: unstated 163 · stated 34 · verified 23 · proposed 6.

### The finding the Backend slice could not have surfaced

**`type: concept` does different jobs in different areas.** In backend/frontend/infrastructure/
cross-cutting it is architectural understanding → `explanation`. In **domain** it is an entity
definition with an Attributes list — *"what is a Building and what fields does it have"* is look-up,
so those 34 notes are `reference`. §3's flat `concept → explanation` rule would have mislabelled
every Domain note. One source vocabulary, two jobs, decided by area.

### Everything else that needed a judgement

- **Two real supersessions encoded.** `prism-auth-clerk → prism-auth-workos` (the source's only
  working `superseded-by` link, re-keyed to the underscore spelling the engine reads), and
  `prism-domain-spaces-lineage → prism-spaces` — the source said `design-agreed-unbuilt` while
  `prism-spaces` records it shipping 2026-06-22. Verified by query: excluded by default, and under
  `--all-status` the superseded note ranks **first** for its own content, so the exclusion changes
  the answer rather than decorating it.
- **`Index.md`'s substance was not buried in MEMORY.md.** The platform inventory and the skills
  table became [[prism-platform-now]] (`reference` · `stated`, with `last-updated`) precisely
  because `MEMORY.md` is never indexed. An inventory in an unindexed file is an inventory nobody
  can retrieve.
- **`type: roadmap`** → `explanation`. Doc 2 §6a's boundary rule: a sixth doc_type needs a job none
  of the five expresses, and "the current plan and why" is explanation.

### Link integrity

2015 wikilinks; **1902 resolve**. The 113 that do not break down as 74 session logs (still in
PropertyPrismVault — the `_sources/` migration is the remaining decided-but-undone work), 14 Linear
tickets that were never vault notes, and 25 forward-references to notes the source vault never had.

Three link defects were introduced by the migration and repaired: cross-area links left unrewritten
because each pass only knew its own slice's names (199 fixed by a final full-map sweep), 107
intra-Backend links broken by the rename, and **9 wikilinks split across a line by the log's
`textwrap`** — a defect of my own tooling, caught only by re-running the resolver after the merge.

### Two defects found by verifying rather than by any gate

- **Four of five `*-overview` notes carried a duplicate H1**, because the H1-stripping regex was
  `\A#` and a blank line preceded the heading after frontmatter removal. Every assertion passed;
  the symptom was a chunk path reading `Cross-Cutting — Synthesis` under a note titled
  *"Cross-cutting — how it fits together"*. Provenance pointing at the wrong name is the
  chapter-title bug's shape, and only reading a real result surfaced it.
- ~~`prism-sharp-edges` and the five area catalogues now overlap.~~ **Measured, and the claim was
  wrong: the overlap is ZERO.** Comparing bolded lead-ins and table-row keys across all six notes,
  `prism-sharp-edges` (10 entries) shares nothing with backend (26), cross-cutting (16), domain
  (14), frontend (17) or infrastructure (21). The cross-area note holds failure *classes* — Swagger
  contract drift, CSP gaps, ad blockers eating analytics — and the area notes hold specific traps.
  The split was cleaner than the claim assumed; recorded because an unmeasured claim in a readout
  is the same defect as an unchecked docstring.

---

## 16. The remaining open items, closed 2026-07-28

**All seven vaults are under version control.** `git init --separate-git-dir` per vault, with the
repos in `~/.local/share/vault-git/` — the working tree stays cloud-synced (Doc 2 §0 sanctions
that for markdown) while `.git` does not, so a concurrent OneDrive sync cannot corrupt a repo
mid-write. An earlier caution here was **wrong**: `vault-sync.sh` selects vaults from an explicit
`VAULTS` allowlist naming only the two `~/vaults/` repos, so its `.git` test is a guard inside the
loop, not the selector. Adding `.git` to a OneDrive vault opts nothing into anything.

**The 74 session logs are migrated** to `prism-vault/_sources/` as `class: conversation`, following
the convention core-vault, cbre-vault and school-vault already use. `status: complete` — a session
log is done and correct — and they are excluded from default retrieval by CLASS, not by status, so
the two axes stay independent. Verified both ways: a default query returns the durable notes, and
`--include-sources` puts the session log first for its own content.

Scope is now **306 documents · 3001 passages · 5798 vectors**, freshness current, 0 fatal, 3
quality warnings.

**Link integrity ended at 2348 of 2428 resolving.** The 80 that do not are 25 Linear tickets that
were never vault notes and 55 forward-references the source vault never had. Migrating the sessions
resolved 200 links in one sweep — each migration pass only knows its own slice's names, so a final
full-map sweep is part of the pattern, not an afterthought.

**`--clean` can no longer delete a vault.** `cli.py:_refuse_destructive_clean` refuses three shapes
before `shutil.rmtree`: a directory holding a `.substrate.toml` (that makes it a vault, whoever
owns it), a path equal to / inside / a parent of any vault in the scope, and a directory holding
markdown this tool did not write. A genuine index root stays deletable or `--clean` is useless.
Four regression tests, mutation-verified.

Worth recording: the first version of that guard referenced a module the CLI imports *inside*
`cmd_compose`, so it raised `NameError` — and because it raised before the `rmtree`, it failed
closed. A guard that crashes is still a bug, but the direction of failure was the safe one, which
is the property PRINCIPLES.md's second law says to prefer.

---

## 17. Four more vaults — and the audit that found them, 2026-07-28

**"Are all vaults migrated" was answered NO, by an audit that nearly repeated this project's
signature failure.** After prism completed, a coverage check across `~/vaults` and `~/OneDrive`
looked complete. It was not: six Obsidian vaults live in
`~/Library/Mobile Documents/iCloud~md~obsidian/Documents/` and **`find` does not follow symlinks
without `-L`**, so `~/Documents/SchoolVault` — a symlink into that tree — reported zero notes. The
brief warned that a previous session "measured against ClaudeVault, declared victory, and missed a
261-note vault entirely"; this was the same shape, one directory further out.

| iCloud vault | notes | verdict |
|---|---|---|
| ClaudeVault (38) · PropertyPrismVault (255) | — | **stale duplicates** — superseded by the `~/vaults` copies, which are newer and larger |
| **ResearchVault** | 98 | live, **modified the same day**, while the `research` scope held 8 notes |
| **SchoolVault** | 93 | live; `school-context.md` already said the substance lived here |
| **NoteVault** | 276 | **named in no handoff, spec or CLAUDE.md** |
| WorkVault | 7 | 1 substantive note |

Containment measured 0 of 94 ResearchVault and 0 of 89 SchoolVault notes present in substrate.
These were never partially migrated; they were never touched.

### The Tier 2 question, answered no

Research papers looked like Tier 2 material. They are not: `02 - Papers` holds notes **about**
papers — `## Summary` / `## Key Findings` / `## Methodology` with `doi`, `authors` and a
`zotero://` pointer. Doc 2's Tier 2 is the ingested SOURCE TEXT, chunked into `passages/` under a
`_meta.md`. A reading note is the operator's synthesis of an external work, which is Tier 3. Real
Tier 2 here means ingesting the PDFs out of Zotero — Doc 2's "reference-tier ingestion at scale"
thread, a separate job. The `zotero://` links are already the §3b raw pointer done right.

### A reserved-key collision that would have refused the scope

SchoolVault puts a COURSE NAME in `class:` — "Catholic Social Tradition" (60), "Philosophy of Karl
Marx" (25). The reader treats `class` as an alias for `document_class` and `classes.apply` refuses
anything outside the three known classes, so all 85 would have refused `school` at ingest. Renamed
to `course:`, preserving the value as documentation. Same family as the `confidence: high`
collision, on a different reserved key — worth expecting once per source vault.

### An engine defect real content found

`school-mv-phl-154-exam-two-review-questions` — a 17-item numbered list — was **refused for content
it had not lost**: A18 coverage 0.9554 against the 0.99 gate, `missing` naming exactly
`['10','11',…,'17']`. `_LIST_MARKER` strips ordered-list markers from what the extractor stores,
but `content_coverage` counted them on the source side. `_TOKEN` requires ≥2 characters, so
markers `1.`–`9.` were never counted and **the asymmetry was invisible until a list reached item
10**. `reader.py`'s own comment stated the assumption — "a bare list-marker digit (1.–9.) is not a
phantom token" — and stopped there. Fixed by stripping markers from the source side too;
regression test mutation-verified.

That is the Rank-3 hazard the pre-migration engine survey predicted and the 187-note prism corpus
never triggered. Two notes there sat at 0.9906 against the gate; it took a different vault to cross
it.

### Routed

| from | n | to |
|---|---|---|
| SchoolVault | 82 | `school` — readings → `03-references`, topics → `02-areas` |
| ResearchVault | 95 | `research` — papers → `03-references` (`reference`), synthesis → `explanation` |
| NoteVault subject folders | 142 | `school` 102 · `cbre` 22 (incl. WorkVault) · `prism` 13 · `research` 5 |
| NoteVault `Daily` + `Quick Note` | 135 | **not migrated** — a capture inbox, not curated knowledge |

**NoteVault carried no spine to remap: 5 of 276 notes had frontmatter.** Every field was authored,
which is different in kind from every other migration here, and each note records
`source_status: "(mobile capture; no frontmatter in the source)"` so a reader knows the spine was
assigned rather than carried. The register is informal in-class writing; routing 102 of them into
`school` puts uncurated captures beside SchoolVault's 82 curated notes, which is worth revisiting
if `school` retrieval gets noisy.

**Final:** prism 319 · school 222 · research 140 · cbre 67 · scripta 51 · clovis 37. All six
vector-complete, freshness current, 0 fatal.
