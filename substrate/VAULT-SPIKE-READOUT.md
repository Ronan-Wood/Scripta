# Vault Structure Spike — read-out

A Phase-0-shaped de-risk spike. The question: **does Doc 2's structure survive contact with the
engine?** Answered on ONE composed vault (core + one project), with deliberately-created sample
notes. Migration of real content is explicitly out of scope. Success is this read-out, not a green
run.

---

## 0. Verdict

**Yes — Doc 2's structure survives contact, on one vault.** The engine reads a project vault's
`.substrate.toml`, resolves `inherits`, and indexes core + project as one scope; a project-scope
query retrieves from core (inheritance composed); `status` reshapes the default retrieval set
exactly as §6 specifies (archived/superseded excluded, the supersession link surfaces via the live
note); `domains` from `_meta.md` survive as fields; and the capability envelope reports correctly
for a vault-scope query. Every failure mode the task named (malformed manifest, missing inherited
vault, absent/invalid status) hard-fails with the condition attached rather than silently
narrowing scope.

The existing evals are **unmoved**: the v2→v3 schema rebuild is chunk-for-chunk identical and the
44-case ceiling reproduces `semantic_mrr = 0.6985` (§5).

---

## 1. The five questions, each with evidence

All queries below run against the composed index (`out-vault/index.db`), lexical-only
(`--no-vector`, no daemon needed), unless noted.

### Q1 — Does a chunk from a project note carry a correct path and provenance?

Yes. A project note's hit carries its structural path AND its origin vault:

```
$ substrate query "manifest inheritance composes core into project scope" --db out-vault/index.db --no-vector --k 1
  [passage] Manifest inheritance composes core into project scope · Manifest inheritance composes core into project scope · @demo-vault
    ↳ status=complete · domains=['software-dev', 'retrieval']
```

`@demo-vault` is the composition-provenance field (`documents.vault`), `status`/`domains` ride on
the hit (the Boundary Principle: a passage states its own currency/origin without a join). A
reference passage from core shows the structural path too: `Partitioning · Partitioning > Partitioning by hash of key · @core-vault`.

### Q2 — Did inheritance compose? Does a project-scope query retrieve from core?

Yes. The query below can ONLY be answered by the operator note that lives in **core-vault**, yet
it is retrieved while the engine is aimed at **demo-vault**:

```
$ substrate query "how does the operator run the audit review implement verify cadence" --db out-vault/index.db --no-vector --k 3
  [passage] Working cadence — audit, review, implement, verify · … · @core-vault
    ↳ status=active · domains=['operator', 'process']
  … (all 3 hits @core-vault)
```

`compose` also proves it structurally, post-index (the A-compose assertion, §4):
`by vault {'core-vault': 3, 'demo-vault': 6} · by tier {1: 1, 2: 2, 3: 6}`.

### Q3 — Is status respected? (archived excluded; superseded out but its link surfaces)

Yes, exactly per §6.

**Superseded** — default query returns the LIVE note, surfaces the supersession link, and the dead
note is absent:

```
$ substrate query "engine boundary python engine powers the app retrieval brain" --db … --no-vector --k 3
  [passage] The engine boundary — the Python engine powers the app · … · @demo-vault
    ↳ status=active · domains=[…] · supersedes=engine-boundary-old      ← link surfaces here
  (engine-boundary-old, status=superseded, is NOT in the results)
```

`--all-status` proves the superseded note IS indexed (rank 2), just filtered by default — not
dropped.

**Archived** — default query finds nothing; `--include-archived` surfaces it:

```
$ substrate query "phase 0 ingestion spike furniture validator batched extraction" --db … --no-vector
  status filter: active,complete
  (no results)
$ …  --include-archived
  status filter: active,archived,complete
  [passage] Phase 0 ingestion spike — working notes (archived) · … · @demo-vault
    ↳ status=archived · …
```

### Q4 — Do `domains` tags survive ingestion as fields?

Yes — including domains supplied by a reference source's `_meta.md` (the passage file itself
carries no frontmatter):

```
$ substrate query "partitioning data by hash of key sharding" --db … --no-vector --k 1
  [passage] Partitioning · Partitioning > Partitioning by hash of key · @core-vault
    ↳ status=active · domains=['software-dev', 'distributed-systems', 'databases']
```

Those three domains came from `ddia-2e/_meta.md`, merged onto the passage at ingest. `domains` is a
carried tag ONLY — no weighting or filtering (that Doc-2 feature is explicitly deferred).

### Q5 — What does the capability envelope report for a vault-scope query?

The envelope crosses the boundary intact, plus the status filter that produced the result:

```
  status filter: active,complete
  capability: embedder=lexical-only · hyde=off · rerank=off
  expected mrr: n/a — lexical-only (no vector arm) · index v3:2ba6d5b3bad9
```

With an embedder wired it names the measured tier; lexical-only it says so rather than claiming a
number it isn't. `index_version` rides along for staleness detection.

---

## 2. What was built (three reviewable change sets)

1. **Scaffold** (`vaults/`, content only) — an empty `core-vault` (00-operator, 10-reference with
   frozen + versioned + domain folders, `_index/MEMORY.md`, `log.md`, 99-templates) and one
   project `demo-vault` from the skeleton (00-index, 02-areas, 03-references, 04-synthesis,
   `_archive`, `log.md`, 99-templates) with its root `.substrate.toml`. Deliberately-created sample
   notes only: one per status, the superseded+superseding pair, a multi-domain reference stub.

2. **Spine fields** — `status` (+ `superseded_by`/`supersedes`) and `domains` plumbed
   reader → `spine.validate_status` → schema (v3) → store (denormalized `status` on chunks) →
   retriever (default set `{active,complete}`). Assertions **A19** (per-doc spine validity, in
   `verify`) and **A20** (`assert_status_partition`).

3. **Manifest reading + composition** — `substrate/vault.py` (`resolve_scope` +
   `assert_composed`) and a `compose` CLI command. Inheritance = "which source paths to index,"
   nothing more.

Shared plumbing: `markdown/ingest.py` (one ingest body for both `ingest-md` and `compose`).

Diff: ~10 engine files touched (+3 new modules), 3 new test files. `git diff --stat`:
`cli.py, emit.py, reader.py, models.py, retriever.py, index_store.py, reconcile.py, schema.py` +
`spine.py, vault.py, markdown/ingest.py` + `tests/test_{spine,status_filter,manifest}.py`.

---

## 3. The scaffold

```
vaults/
├── core-vault/                      # Tier 1 + 2, inherits nothing (the root)
│   ├── 00-operator/working-cadence.md                 (status active)
│   ├── 10-reference/
│   │   ├── frozen/software-dev/ddia-2e/               _meta.md → domains [software-dev,
│   │   │     ├── _meta.md · structure.md · passages/    distributed-systems, databases]
│   │   └── versioned/software-dev/go/1.21/            _meta.md → class reference-versioned,
│   │         ├── _meta.md · passages/                   version 1.21
│   ├── _index/MEMORY.md · log.md · 99-templates/
└── demo-vault/                      # Tier 3, inherits core-vault
    ├── .substrate.toml              # name="demo", inherits=["core-vault"], reference_pins, domains
    ├── 02-areas/       retrieval-tuning (active) · manifest-inheritance (complete)
    ├── 03-references/  local-glossary (active, project-local)
    ├── 04-synthesis/   engine-boundary-current (active, supersedes →) · engine-boundary-old (superseded)
    ├── _archive/       phase0-spike-notes (archived)
    └── 00-index/MEMORY.md · log.md · 99-templates/
```

---

## 4. Assertions & the refuse-rather-than-mislead matrix

"Green gates, silent loss" is this project's signature failure; a composed-scope query returning
correct-looking results from the wrong source set is exactly that shape. New assertions guard it:

| assertion | where | catches |
|---|---|---|
| **A19** spine status valid | `verify` (per ingested doc) | status outside the four; superseded with no link |
| **A20** status partition | `store.assert_status_partition` (compose) | unknown/NULL status silently excluded; chunk↔doc status drift; filter excluding ≠ {archived, superseded} (checked two independent ways) |
| **A-compose** | `vault.assert_composed` (compose) | a scope vault with **0** indexed docs (silent core-tier drop); a note ingested-but-not-indexed; an out-of-scope vault polluting the index |

Every refusal is a hard fail with the condition attached (verified via the CLI, real exit codes):

| condition | command | outcome |
|---|---|---|
| inherited vault missing | `compose` | `FATAL (manifest): … does not exist` · exit 2 |
| malformed `.substrate.toml` | `compose` | `FATAL (manifest): malformed manifest …` · exit 2 |
| note with no status (vault path) | `compose` | `FATAL … no status … refusing to default it` · exit 3 |
| `superseded` with no `superseded_by` | `ingest-md`/`compose` | `FATAL (spine)` · exit 3 |
| unknown status value | `ingest-md`/`compose` | `FATAL (spine)` · exit 3 |
| unknown `--status` in a query | `query` | `FATAL: unknown status ['bogus']` · exit 2 |
| valid single-file ingest (control) | `ingest-md` | exit 0 |

Standalone `ingest-md` is LENIENT (absent status → `active`, keeping the existing corpus
ingesting); the `compose`/vault path is STRICT (`require_status=True`).

---

## 5. Eval-safety proof (the existing 0.698/0.593 must not move)

This work touches ingestion/scope, not retrieval tuning, so no eval number should change. Proven
two ways, without disturbing the live eval DB:

1. **Structural.** Rebuilt a v3 DB from the same `out/` markdown and diffed it against the intact
   v2 `out/substrate.db` (read raw, read-only): **identical** doc/chunk counts (3 / 1811), an
   **identical** `(chunk_id, text_with_path)` signature (`4a4f765c9ad75dc9`), all docs
   `status=active`, A20 `excluded=0`. Retrieval inputs are byte-identical, and vectors are
   content-sha keyed on unchanged text → cache stays valid.
2. **Numeric.** Restored vectors from the cache (1811, 0 re-embedded) and ran the full ceiling eval
   on the v3 rebuild: **passes the no-regression gate**, per-case ranks unchanged (`(was N) =`),
   capability reports the 0.698 tier. Baseline `semantic_mrr = 0.6985` reproduced. The two `gap`
   cases are pre-existing baseline misses, not regressions.

Note (standard for this repo's drop-and-rebuild schema): the schema bump to **v3** means the first
`index`/`eval` against the old `out/substrate.db` rebuilds it from `out/` markdown. `./run.sh`
(index → eval) handles this; a bare `query` against a not-yet-reindexed v2 DB would find it rebuilt
empty until reindexed.

---

## 6. Decisions I made — flag any you'd correct

- **status required in the vault path, lenient standalone.** Doc 2 §6 says "every note carries a
  status," and the task's refuse-constraint points the same way — so `compose` refuses a
  status-less note, while single-file `ingest-md` defaults absent→`active` (keeps the PDF corpus
  ingesting). If you'd rather the vault path also default, it's a one-line flip.
- **`inherits` resolution: sibling-name OR explicit path.** A bare name resolves beside the project
  vault (ergonomic default); an absolute path or one with a separator is honored as-is — so
  core-vault can live in a cloud folder (Doc 2 §0: location is the user's). 
- **notes ingest under the `reference-frozen` chunk policy.** There is no dedicated `note`/operator
  document-class yet; the spine field that matters for notes (`status`) is what I added. A
  note-specific class is a future refinement, out of scope here.
- **`_meta.md` supplies class/status/domains/version to reference passages** that carry no
  frontmatter of their own (a passage's own value always wins; the source only fills absences).
  This is what makes the multi-domain reference stub work faithfully.
- **derived index in `out-vault/` (gitignored), never `out/`.** Keeps the spike fully isolated from
  the eval corpus, and honors Doc 2 §5 (don't cloud-sync the live index DB).
- **`domains` carried as a tag only** — no weighting/filtering (explicitly deferred).

---

## 7. Scope boundaries honored

Did NOT: migrate any real vault content (ClaudeVault/prism/school untouched); implement domain
weighting/filtering; build the lint automation; touch the app; extract to a separate repo; build
the PyMuPDF arm. Nothing outside `substrate/` and the new `vaults/` was touched.

---

## 8. Review cycle

**Crosscheck** (3 fresh-context reviewers: correctness / architecture / security). The correctness
reviewer independently **verified all five critical invariants hold** (eval unmoved; status filter
excludes exactly archived+superseded; every refusal hard-fails; denormalization can't drift at
write; round-trip/reconcile sound). No blocker/important findings. Applied (all my own new code):

| # | lens | finding | applied |
|---|---|---|---|
| 1 | correctness | cross-vault **doc_id collision** for two byte-identical, same-stem notes with no frontmatter id — the filename-derived ids match, one silently overwrites the other at reconcile while every gate stays green (the signature silent-loss shape) | `resolve_scope` now checks the **effective** doc_id (frontmatter *or* filename-derived) for every note, not just declared ones; + a regression test |
| 2 | correctness | A19 `verify` spuriously FAILED a markdown ingest dir written before this feature (no spine block) | A19 now only asserts when a spine block is present (a stale dir is N/A, not invalid) |
| 3 | security | manifest / `_meta.md` / doc_id-scan reads bypassed the note reader's `_MAX_MD_BYTES` cap | routed all three through a size-checked `_read_capped` (mirrors the existing guard) |
| 4 | architecture | `spine.effective_status` was dead (only tests called it) | deleted (its logic is `validate_status`'s return) |
| 5 | architecture | `IngestResult.passages`/`outlines` and `Hit.superseded_by`/`tier` were carried but never read | removed; the counts live in `run["chunk"]`, and `documents.tier`/`superseded_by` stay on the row |
| 6 | architecture | `ingest-md --vault/--tier` flags had no single-file use case | removed (compose sets provenance directly) |

Reported, not applied: **inherits accepts absolute/`../` paths** (security, low) — by design (Doc 2
§0, "location is the user's"); no exfil channel in a local single-user tool. Flagged for a future
untrusted-vault threat model only. All applied fixes re-verified: full test suite green, lint
clean, compose assertions green, eval-safety signature still `4a4f765c…` (unchanged).

**Adversary** (2 diff-only reviewers, told to assume the diff is broken). Report-only — **nothing
below is applied**; these are for your review/pick.

_Dismissed with evidence (reviewers couldn't see code outside the diff):_
- **"v2 DB → `no such column`" (both, HIGH/MED).** `schema.migrate()` drops-and-rebuilds on a
  version mismatch — verified concretely: a fake v2 DB (old columns) opened with the new code
  rebuilds to v3, `store.search` runs, no `OperationalError`. Documented in §5.
- **except-order masks `ClassPolicyError` (both, LOW).** `ClassPolicyError`/`SpineError`/`Coverage
  Error` are `RuntimeError`, not `ValueError`; no masking.
- **domains round-trip (both, LOW).** The serializer emits `domains: [a, b]`; `_parse_list` parses
  exactly that — verified by the compose→query e2e (domains surfaced).
- **`emit.py` `hyp["samples"]` KeyError (both, LOW).** Out of scope — that's the concurrent
  `repaired_samples`/`review.py` work, not this change (and the key exists in `dehyphenate`).

_Real findings — **all 5 applied** (you chose "fix all 5"; a gated implement pass after the review).
All my own code, none broke demonstrated behavior:_
1. **A20 no longer overclaims (was HIGH).** The old "two independent ways" was tautological
   (`EXCLUDED = STATUSES − INCLUDED`). Rewrote check 3 to run the **production** `_add_status_filter`
   (the exact code the query path uses) and assert it selects the included set and partitions the
   corpus — a real independent check. Docstring now states what it proves AND what it deliberately
   doesn't (that `INCLUDED == {active,complete}` is a spec fact, pinned by `test_status_filter`).
2. **`_resolve_inherit` (was MED).** Only absolute paths pass through as-is now; every relative
   entry (bare name or `../core`) resolves against `project_dir.parent`, never CWD — deterministic.
   Test added.
3. **`assert_composed` strengthened (was LOW).** Now asserts `indexed == ingested` (both `ingested −
   indexed` *and* `indexed − ingested`), so a stale ingest dir / out-of-scope doc that keeps
   answering is refused — and a legitimately-empty inherited vault is no longer conflated with a
   silently-dropped one. Two tests added.
4. **`_resolve_statuses` (was LOW).** `--status ,,` (parses to empty) is now refused with a FATAL,
   not silently zero results.
5. **`_discover_notes` SKIP_DIRS (was LOW).** Matches the vault-relative path now; a vault under a
   `99-templates` ancestor still discovers its notes. Test added.

Re-verified after the fixes: **145 tests green**, lint clean, compose assertions green, eval-safety
signature still `4a4f765c…` (unchanged), and the inheritance / supersession-link / archived-exclusion
behaviors all still hold.

---

## 9. Reproduce

```bash
cd substrate
uv run python -m substrate.cli compose vaults/demo-vault --clean          # resolve + ingest + index + assert
uv run python -m substrate.cli query "<q>" --db out-vault/index.db --no-vector
uv run python tests/test_spine.py && uv run python tests/test_status_filter.py && uv run python tests/test_manifest.py
```
