# Migrating an existing vault onto the spine — the vocabulary lessons

What the engine learned from moving pre-existing Obsidian vaults onto Doc 2's spine
(`status`, `doc_type`, `confidence`, `domains`). The per-vault inventory that produced these
lessons is kept outside this repo; this file keeps only what applies to any vault.
§8 is cited from engine code and tests; the other section numbers are kept so references outside
this file still resolve, which is why the numbering has gaps.

---

## 0. Verdict

**The engine is not the obstacle.** A real vault of a couple of hundred durable notes ingested
clean at compose strictness once a spine was supplied: 0 fatal, 0 warnings, minimum A18 coverage
0.9906 against the 0.99 gate (measured 2026-07-27, engine `76c3bdd`). The cost of a migration is vocabulary and judgement, not engine work.

Expect both spine fields to need authoring on almost every note. An upstream `type` field is
usually a taxonomy answering a different question from `doc_type`, and an upstream `status` rarely
uses the lifecycle words the engine accepts.

---

## 3. `type` → `doc_type`

An upstream `type` maps onto `spine.DOC_TYPES` many-to-one, and some values have no home at all.
Map each value explicitly and route the misfits by hand; never default them.

## 4. `area` → `domains`

An upstream `area` is usually a folder or a product area, which is not the same axis as `domains`
(what the note is about). Derive `domains` from content, and carry the old value under a
`source_*` key if it is worth keeping.

## 5. `status` → `status`

`status` is the note lifecycle only (WRITING.md Glossary). Upstream values that describe
settledness (`proposed`, `draft`, `design-agreed-unbuilt`) belong on `confidence`, not `status`.

---

## 6. Verified landmines

### `superseded-by` vs `superseded_by`

Vaults commonly write **`superseded-by:`**. The engine reads **`superseded_by:`**
(`reader.py`). The hyphenated key is silently ignored, so a `status: superseded` note refuses at
compose with *"superseded with no superseded_by"* while visibly carrying one. Two edits, not one:
rename the key, **and** replace a `[[wikilink]]` value with the target's `doc_id`, because
`_DOC_ID` rejects brackets, spaces and uppercase.

### `supersedes` is often dead metadata

Upstream `supersedes` values tend to be empty or free prose rather than links. Decision history in
such a vault lives in bodies, so WRITING.md rule 5 has to be satisfied by reading them.

### One block list loses the whole frontmatter

`tags:` written as a YAML block list puts a non-blank line without a `:` in the frontmatter, which
makes `_parse_frontmatter` return `{}` and treat the block as body (`reader.py`). The note's
declared `status` never reaches the validator and it refuses as *"no status"*, which names the
wrong cause. A one-line pre-flight grep for block lists is worth running before any migration.

### Thin margins

Code fences with an info string richer than a bare language, and ordered lists reaching item 10+,
are the two known token-loss vectors for A18 coverage. Notes just above the gate can fall below it
when edited during migration.

---

## 8. `confidence` — DECIDED: the source-signal default

Adopted 2026-07-27. Nothing is invented: every value traces to a signal the source declared, and
the absence of signal is carried as such rather than filled.

> **Superseded 2026-07-28 in VOCABULARY only — the policy itself stands.** Absence now stores
> `unjudged`; `unstated` is reserved for a note that DECLARES it makes no settledness claim.
> `spine.validate_confidence` cites this section as the reason `compose` stays lenient, and that
> reason is unchanged: a guessed marker is still worse than an absent one.

| source signal | → `confidence` |
|---|---|
| source says `proposed`, `draft`, `design-agreed-unbuilt` | `proposed` |
| a ratified decision (an ADR with `status: accepted`) | `stated` |
| a digest or inventory note | `stated` (WRITING.md forbids `verified`) |
| no signal | absent, stored as `unjudged` |
| a claim testing could have shown wrong, and was tested | `verified` |

In a vault of architecture notes `verified` is expected to be rare or zero, and that is the point.
Where an upstream vault wrote its own certainty scale, keep it under `source_confidence:`.

---

## 10. Session logs migrate as `class: conversation`

Captured session logs are what someone said, not settled notes. They migrate under `_sources/` as
`class: conversation`, so default retrieval withholds them.

---

## 12. Open items found while migrating

- ~~**The eval content signature had no recorded derivation.**~~ **CLOSED** — found 2026-07-27
  and replaced as described at the end of this item. The readouts quoted
  `4a4f765c9ad75dc9` over `(chunk_id, text_with_path)` as the project's hardest invariant, and 17
  plausible constructions (sort orders × separators × sha256/sha1/md5/blake2b × a rolling per-row
  digest) reproduced none of it. An invariant nobody can recompute is an unchecked claim
  (WRITING.md rule 7). `tools/fixture-signature.py` and `tests/test_fixture_signature.py` replace
  it with a recomputable one.
- **`_sources/` is not in Doc 2 §4's skeleton.** §4 permits added folders, so nothing is broken;
  the skeleton should probably name it.
- **`status` reports `freshness: UNCHECKABLE` for an authoring fault.** `introspect.status_payload`
  replaces the whole drift payload with `{"error": …}` for any `VaultError`, so a misplaced digest
  reads the same as a vault that no longer exists. Accurate but coarse.

---

## 17. Reserved keys, and an engine defect real content found

### A reserved-key collision refuses the whole scope

A source vault can already use a key the engine reserves. One vault used `class:` for its own
grouping label; the reader treats `class` as an alias for `document_class`, and `classes.apply`
refuses anything outside the three known classes, so every such note would have refused the scope
at ingest. Rename the key (keeping the value as documentation). The same family as a
`confidence: high` collision, on a different reserved key: expect it once per source vault.

### Ordered lists past item 9 were refused for content they had not lost

A 17-item numbered list scored A18 coverage 0.9554 against the 0.99 gate (2026-07-28), with `missing` naming
exactly `['10','11',…,'17']`. `_LIST_MARKER` strips ordered-list markers from what the extractor
stores, but `content_coverage` counted them on the source side. `_TOKEN` requires ≥2 characters, so
markers `1.`–`9.` were never counted and the asymmetry was invisible until a list reached item 10.
Fixed by stripping markers from the source side too; the regression test is mutation-verified.

### Notes with no frontmatter at all

A capture-style vault may carry no spine to remap. Every field is then authored rather than
carried, and each note should record that (`source_status: "(no frontmatter in the source)"`) so a
reader knows the spine was assigned.
