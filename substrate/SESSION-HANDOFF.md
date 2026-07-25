# Session handoff — doc_type (§6a) + WRITING.md, then the real-content pilot

Written 2026-07-24 mid-task, for a fresh session after a restart. Branch `substrate-engine`, work
in `substrate/`. Read `VAULT-SPIKE-READOUT.md`, `HANDOFF.md`, `PRINCIPLES.md`, `doc2.md`, and
`vaults/core-vault/00-operator/WRITING.md` for background.

## Bottom line

**Phases 1 and 2 are both COMPLETE.** Read `PILOT-READOUT.md` first — it supersedes the "NEXT"
section below, which is kept for the record of what was planned.

State at 2026-07-24 end of session (all uncommitted):
- **Phase 1** — Doc-2 §6a `doc_type` + WRITING.md. Built, crosschecked, adversary-reviewed.
- **Phase 2** — the real-content pilot: `vaults/pilot-core-vault` + `vaults/scripta-vault`,
  12 real notes from ClaudeVault. Composed clean; all axes proven by query. See `PILOT-READOUT.md`.
- **Three defects found and fixed after the pilot:**
  - **F8 / A22** — `compose` reported PASS on a corpus containing a note `verify` fails. The
    per-document A-series now runs on the vault path, split fatal (loss/corruption) vs reported
    (quality), defaulting to fatal.
  - **F9** — `reference_domains` was swallowed into `[reference_pins]` by TOML table scoping, in
    BOTH manifests, shipped since the Phase-1 scaffold. Fixed.
  - **§6b confidence axis** — schema **v5**. `status` says whether a note is live; `confidence`
    (proposed/inferred/stated/verified, absent → `unstated`) says why its claims should be
    believed. Without it an unbuilt design retrieved reading as settled. A23 asserts it.
- **179 tests green** across 16 files. Eval signature `4a4f765c9ad75dc9` unmoved, proven twice
  (raw v2 read-only, and a fresh v5 reconcile of the same markdown).
- **Crosscheck on the confidence axis: COMPLETE**, 7 findings applied (see `PILOT-READOUT.md` §10).
  Two were vault-refusing landmines from promoting PDF-era assertions to gates over markdown
  (A1/A1b counting exclamation marks as hyphen artifacts; A17's denominator being the slice's max
  page anchor). One was the v5 bump silently emptying any existing index on `query`. One was
  `emit.py` not round-tripping the new axes, which laundered confidence on every regeneration
  cycle — applied to `emit.py`'s `frontmatter()` ONLY, a different function from the in-flight
  `_repair_blocks` work, so the two do not overlap.
- **A-series-vs-markdown sweep: DONE, before migration** (the sequencing matters — a refusal during
  a supervised migration is ambiguous otherwise). 29 fixtures of legitimate authored markdown,
  including every shape `reader.py` documents as "not structurally recognised" (setext headings,
  indented code, nested lists, wrapped list items, borderless tables) and real Obsidian idioms
  (callouts, task lists, wikilinks, footnotes, math, HTML, emoji headings, `---` dividers).
  **Result: the family had exactly two members, both already fixed** (A1/A1b, A17). Nothing else
  fires. A18 — the content-LOSS gate — fired on nothing, so the reader's "content preserved,
  hierarchy lost" promise holds under test. The only fires were quality-class WARNINGS on a
  3000-char unbreakable token, which is correct behaviour.
- **Both A22 regression tests are mutation-verified.** The first A17 fixture was vacuous (span 11%
  vs a 30% gate — it passed with AND without the fix); it now asserts it trips the pre-fix
  predicate before asserting the fix handles it. See PRINCIPLES.md "A second law".
- **The principle is named** in `PRINCIPLES.md`: promoting a check suite to a gate is an audit of
  every check in it, and should be expected to yield false-rejects proportional to how long the
  checks ran un-enforced.
- **VAULTS MOVED OUT OF THE REPO.** `substrate/vaults/` now holds only the EXAMPLE pair
  (`demo-core-vault` + `demo-vault`, tracked, synthetic, also the regression fixture). The real
  vaults are at `~/OneDrive/vaults/core-vault` and `~/OneDrive/vaults/scripta-vault`, untracked and **not** covered by
  `vault-sync.sh` (its allowlist names only ClaudeVault and PropertyPrismVault, and it skips
  non-git dirs). No manifest edit was needed — a bare `inherits` name resolves against the project
  vault's parent. Compose with `compose ~/OneDrive/vaults/scripta-vault --db out-vault/real.db`.
  **Follow-up:** the real vaults are unversioned; `git init` + remote + sync-allowlist is the
  obvious next step, and until then a bad edit has no undo.
- **Open, decided but NOT built:** don't embed superseded notes (exclude from the vector arm, keep
  in FTS — "explicitly query the archive" stays supported; the content-addressed cache makes a
  later on-demand embed a clean cache miss). And `_read_manifest` should validate all four Doc-2 §2
  contract keys, not just `name`/`inherits` — its own small unit, next.

## What shipped this session (Phase 1 — the Doc-2 mid-build changelog)

The user handed a mid-build changelog with three deltas; all implemented:

1. **`doc_type` spine field** (Diátaxis: `decision` / `explanation` / `reference` / `how-to`),
   plumbed as an exact parallel to `status`:
   - `store/schema.py` — **v3→v4**: `documents.doc_type` + `chunks.doc_type NOT NULL DEFAULT
     'reference'` + indexes. doc_type is a new COLUMN, never in the `(chunk_id, text_with_path)` FTS
     signature → eval unmoved.
   - `models.py` `Document.doc_type`; `markdown/reader.py` parses it (pure); `spine.py`
     `DOC_TYPES` + `DEFAULT_DOC_TYPE='reference'` + `validate_doc_type` (lenient standalone→reference,
     strict vault path refuses absent, unknown→refuse).
   - `markdown/ingest.py` `override_doc_type` (from `_meta.md`), validates, writes to run.json spine +
     `IngestResult.doc_type`; `store/reconcile.py` reads it (pre-doc_type corpus → None → 'reference').
   - `store/index_store.py` upsert denormalizes onto both tables; `Hit.doc_type` + `_row_to_hit`;
     **A21** `assert_doc_type_valid` (validity + chunk↔doc denorm; no partition — every doc_type is
     retrievable, unlike status); `DocTypeError`.
   - `vault.py` `NoteRef.override_doc_type` + `_source_meta` + `_discover_notes`; **`WRITING.md` added
     to `SKIP_NAMES`** (read-wholesale standard, not chunked).
   - `cli.py` compose (override + A21 assert + prints), verify (A19 doc_type, lenient if absent),
     query (surfaces `doc_type` on the hit).
   - Server-side doc_type FILTERING **deferred** (carried + surfaced like domains; no gold cases).
2. **`WRITING.md`** at `vaults/core-vault/00-operator/WRITING.md` — Google devdocs baseline
   (referenced), 8 override rules, 4 doc_type templates, 10-term glossary.
3. **Glossary reserved-word check** (`status` vs `capability`): **verified NO-OP** — `status` in
   `retrieve/` is only the note-lifecycle filter; stack-state is already `capability`. Nothing to
   rename.

Plus: `substrate/CLAUDE.md` (points sessions at WRITING.md; user chose "substrate for now, but the
rules apply to the vault content — that's the bigger thing"); scaffold notes + templates + `_meta.md`
carry `doc_type`; `tests/test_doc_type.py` + doc_type tests in `tests/test_spine.py`.

## Verification done (all passing)

- **154 tests green** — `for t in tests/test_*.py; do uv run python "$t"; done`.
- **compose** — `uv run python -m substrate.cli compose vaults/demo-vault --clean` → A-compose,
  A20, **A21 PASS** (by doc_type: decision 2 / explanation 4 / reference 3), schema v4.
- **doc_type surfaces on hits** (`↳ status=… · doc_type=… · domains=…`); supersession link + inheritance intact.
- **EVAL UNMOVED (proven)** — `uv run python <scratchpad>/eval_safety.py`: raw v2 `out/substrate.db`
  reproduces `4a4f765c9ad75dc9`; fresh v4 reconcile of `out/` yields the identical signature; v2==v4
  under all 42 candidate recipes at 1811 chunks. Recipe: sort by chunk_id, `cid\x00text_with_path`
  per row, `\n`-joined, `sha256[:16]`. (The scratchpad is session-specific and gone after restart —
  re-derive with the recipe if needed; read `out/substrate.db` RAW read-only, NEVER via engine code.)
- **Standalone `ingest-md`** — absent doc_type → `reference` (exit 0); unknown → `FATAL (spine)`;
  `verify` shows `A19 spine doc_type valid PASS`.
- **Lint** — my edits are clean. There are **14 PRE-EXISTING lint errors** (reader.py E702 semicolons
  168/181/194/222, chunker B905, embed B904, test B011) present at committed HEAD — NOT mine, NOT to
  be fixed here (the spike readout's "lint clean" claim was inaccurate; flag, don't fix).

## Crosscheck (Phase 1 change set) — COMPLETE

Three fresh-context reviewers (correctness / architecture / security), report-only, diff-scoped.
**Verdict: the change set is sound** — all agreed no injection (doc_type always parameterized),
validation airtight (runs before any write on both ingest paths), eval unmoved, INSERT counts correct
(documents 27/27, chunks 28/28), A21 SQL mirrors A20. No blocker/important+high finding.

**APPLIED (1):** the `assert_doc_type_valid` docstring falsely claimed a NULL chunk is caught by the
`NOT IN` test (SQL `NULL NOT IN (...)` is NULL, not true) — flagged by BOTH security + architecture,
high confidence, my code. Corrected to attribute NULL-prevention to the `NOT NULL DEFAULT` schema +
the drift check. Zero behavior change. (index_store.py `assert_doc_type_valid`.)

**THE ONE DECISION FOR THE USER — A1 (important, medium confidence, single reviewer → below auto-apply
bar):** doc_type is denormalized onto `chunks` (the *status* idiom) but is currently only *surfaced*,
never *filtered* — which is the *domains* idiom (documents-only, surfaced via `d.domains` join). The
chunks column + `DEFAULT` + `idx_chunks_doc_type` + INSERT plumbing + the drift half of A21 exist to
support a chunk-level WHERE filter that was **deferred**. Reviewer: carry it document-level like domains,
surface via `d.doc_type`, drop the chunk column + drift check; re-add them when the filter lands.
**My recommendation: KEEP the current (chunk-denormalized) shape.** Rationale: doc_type is a hard
FILTER axis per the changelog's own motivation ("a query can ask for the reference and not the
explanation") — more like `status` than like `domains` (whose filtering is deep-deferred soft-weighting
needing cross-domain gold cases). The v4 bump is happening now, so the column is free now vs. a v5
rebuild later; the filter then lands as a one-line `_add_doc_type_filter` mirroring `_add_status_filter`;
and A21 mirrors A20 cheaply. It's a doctrine-consistency-vs-YAGNI call — surface it explicitly, let the
user pick. NOT a blocker for Phase 2 (doc_type surfaces on hits either way).

**REPORTED, not applied (all nit/minor, below bar — triage in /adversary or fold into a cleanup):**
- **N-C1 (correctness nit):** `require_status` now also gates `validate_doc_type`; name/docstring
  under-describe it. Rename `require_status`→`require_spine` (ripples to 2 cli.py call sites) or add a
  docstring line.
- **S1 (security nit):** bare `cmd_index` (reconcile→upsert) runs NO A21/A20 re-check, so a hand-edited
  `run.json` doc_type reaches the DB unvalidated. **Symmetric with status** (index skips A20 too), no
  injection, and anyone who can write run.json already controls chunks.jsonl (indexed verbatim). Design
  treats `out/` as trusted; `compose` is the strict gate. Leave as-is or add the asserts to `cmd_index`.
- **S3 (security nit):** `WRITING.md` in `SKIP_NAMES` is a basename match anywhere in the tree, so any
  file named `WRITING.md` in any subdir is skipped (can only HIDE a note, never inject). Consistent with
  every other SKIP_NAMES entry. Root-only match or document it.
- **A3 (arch minor):** `DEFAULT_DOC_TYPE` is defined but used once; `"reference"` is inlined at
  index_store.py:61/143/198 and the constant lacks `: str`. Either use the constant at those sites or
  drop it (status inlines `"active"` with no constant).
- **A4 (arch minor, low):** the validity+drift scan is now near-duplicated between `assert_status_partition`
  and `assert_doc_type_valid` (~15 lines). Extract a helper, OR keep explicit (the repo's audits are
  deliberately self-narrating — reviewer's own counter).
- **A5 (arch nit, low):** scaffold `engine-boundary-{current,old}.md` are labeled `doc_type: decision`
  but written as explanation prose (don't use WRITING.md's decision/why/rejected/consequence template).
  The label is defensible (superseded boundary claim = a decision); reshape to the template OR relabel
  `explanation`. Address when writing the REAL decision notes in Phase 2.

Disposition rule (crosscheck): apply only blocker/important + high-confidence(or ≥2 reviewers) + in-scope;
report the rest. `/adversary` (the final gate) re-checks the full diff diff-only before presenting.

## NEXT — Phase 2: the supervised real-content pilot (track A)

Goal: does the Doc-2 structure survive REAL content (real frontmatter, real domains, a real
superseded-vs-preserved call) that synthetic notes can't test? Source vault: **ClaudeVault**
(`~/vaults/ClaudeVault/`, read from disk — the Obsidian REST API/MCP is down; filesystem works).
Supervised, hand-picked 5–10 notes, NOT automated migration.

Pilot layout (build under `substrate/vaults/`, derived index in `out-vault/`, NEVER `out/`):
- **`pilot-core-vault`** — `00-operator/` (real operator notes + `WRITING.md`) + `10-reference/` a
  real multi-domain reference copied from `out/ddia-2e` (domains `[software-dev, distributed-systems,
  databases]`, doc_type `reference`).
- **`scripta-vault`** (Tier 3, inherits pilot-core-vault) — `04-synthesis/` holding the real
  **Model Engine superseded lineage** from ClaudeVault `02 - Projects/CallTranscriber/`:
  `Model Engine Design Panel (raw)` = **superseded** (superseded_by the synthesis, doc_type decision);
  `Local Model Engine Design` (synthesis) = **active** (supersedes the raw panel, doc_type decision);
  `Decisions - Model Strategy` = active/complete, doc_type decision. NOTE: synthesis→decisions is
  *elaboration, not supersession* (both stay active) — a real §6 judgment.

Real-content frictions already identified (the pilot's payload — verify + quantify, then report):
1. ClaudeVault `00 - User/` notes use **`status: verified`** — NOT one of Doc-2's four → straight move
   is refused by `validate_status`; needs a real remap (verified→active/complete).
2. The raw-panel note (judge scores + 2 designs + synthesis) and the CallTranscriber Index (running
   log) **blend jobs** → WRITING.md rule 8 violations → migration is a rewrite/split, not a copy.
3. ClaudeVault frontmatter is `type:`/`confidence:`/`sources:` and carries **no domains** → schema map
   + domain assignment per note.
4. The superseded chain nuance in #NEXT above (supersession vs elaboration).

Steps: hand-build the notes (WRITING.md-compliant where you rewrite; where you preserve real content
as-is, FLAG the WRITING.md gaps in the read-out rather than silently fixing) → `compose vaults/scripta-vault
--clean` (→ `out-vault/index.db`) → queries proving inheritance/supersession/status+doc_type axes →
re-confirm eval signature `4a4f765c9ad75dc9` → short read-out with the **bank-vs-migrate vs. fix-an-
engine-gap** recommendation.

## Then — the final gate

`/adversary` on the FULL diff (Phase 1 engine + Phase 2 pilot), diff-only, report-only — the last gate
before presenting. Then present the read-out + diff for the user's review.

## Constraints / gotchas (load-bearing)

- **DO NOT TOUCH** the user's uncommitted in-flight work: `substrate/markdown/emit.py`,
  `substrate/report/review.py`, `tests/test_repaired_samples.py` (their "repaired words → long words"
  work). doc_type deliberately routes around emit.py.
- **EVAL MUST NOT MOVE** (0.698/0.593; semantic_mrr=0.6985; signature `4a4f765c9ad75dc9`). Re-check
  after any schema/scope change. Read `out/substrate.db` RAW read-only (it's raw **v2**, 1811 chunks) —
  NEVER open it with engine code (migrate() drops+rebuilds). Derived vault index → `out-vault/`, never `out/`.
- Schema is now **v5** (drop-and-rebuild). First index/eval against `out/substrate.db` rebuilds it.
- **WRITING.md governs the vault content itself** (the bigger thing per the user), not just CC sessions.
- Discipline: audit → review → implement → verify. `/crosscheck` after implementing, `/adversary` last.
  Serial model work only; weights on `/Volumes/ExtremeSSD`. Refuse rather than mislead.
