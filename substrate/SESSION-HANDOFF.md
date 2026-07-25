# Session handoff — Doc 2 is built and migrated; next is the MCP client

Written 2026-07-24 at the end of a long session. Branch `substrate-engine`, work in `substrate/`.
Read `PRINCIPLES.md` first (three laws, all earned this session), then this. `PILOT-READOUT.md` has
the real-content pilot and migration findings in full; `HANDOFF.md` has the engine's history.

## Bottom line

**Doc 2 is built and the real content is migrated.** The engine reads Doc-2 vaults with a
four-field spine, seven vaults exist holding real operator and project knowledge, and the spec
family now lives in the vault it describes. 189 assertions green, schema **v6**, eval signature
`4a4f765c9ad75dc9` unmoved throughout — proven twice at every bump (raw v2 read-only, and a fresh
reconcile of the same markdown).

**Next: an MCP server over the engine**, so the core is usable while the frontend is separate work.
There is an uncommitted sketch at `substrate/substrate/mcp/` — a strawman, not a decision. A Doc 3a
defining it is being written.

## Where things live now (not guessable from the repo)

| | where | what |
|---|---|---|
| **real vaults** | `~/OneDrive/vaults/` | core-vault (46) · scripta (17) · cbre (11) · prism (6) · research (6) · school (4) · clovis (3) |
| **example pair** | `substrate/vaults/` | `demo-core-vault` + `demo-vault` — synthetic, tracked, **the engine's regression fixture** |
| **the spec family** | `~/OneDrive/vaults/core-vault/00-operator/specs/` | Doc 1, Doc 2, the LLM-Wiki adoption spec. `substrate/docs/README.md` is a pointer, never a copy |
| **derived indexes** | `substrate/out-vault/*.db` | gitignored, disposable, one per composed scope |
| **eval corpus** | `substrate/out/` | raw **v2**, 1811 chunks — read RAW read-only, NEVER via engine code |
| source vault | `~/vaults/ClaudeVault/` | untouched and still live; the migration COPIED |

Compose: `compose ~/OneDrive/vaults/<x>-vault --clean --index-root out-vault/<x>-index --db out-vault/<x>.db`.
core-vault has no manifest (it is the root), so it is only ever composed as part of a project scope.

## The spine — four axes, and why each exists

- **`status`** — the note lifecycle. active/complete included by default; archived/superseded
  excluded, with the supersession link surfacing via the note that replaced it.
- **`doc_type`** (§6a) — decision/explanation/reference/how-to. Refused when absent on the vault
  path, so a note blending two jobs cannot hide behind a default.
- **`confidence`** (§6b) — **settledness, independent of status**: proposed/inferred/stated/verified,
  absent → `unstated`. A note can be `active` AND `proposed`. It is a **kind, not a ladder** —
  `verified` does not outrank `stated`, because a measured number and a ratified decision are
  different kinds of true, and encoding an order would make retrieval prefer measurements over
  decisions. Two rules learned the hard way: **an inventory is `stated`, not `verified`** (it is
  confirmed against reality only when written, so its failure mode is silent staleness), and when
  the evidence is mixed, **choose the weaker value**.
- **`class: conversation`** — a SOURCE, not a note. Excluded from default retrieval on a separate
  axis from status, reachable via `--include-sources`. **Superseded is excluded because it was
  replaced (nobody wants it); a conversation is excluded because retrieval BY PASSAGE misrepresents
  it (the whole document is still wanted, on ask).** Same mechanism, opposite reasons — which is why
  they get different answers on embedding, and must not be collapsed into one rule.

Migration convention: a migrated note keeps its originals under `source_status:` /
`source_confidence:`, which the engine never reads, so every remap stays auditable.

## Assertions

A1/A1b (PDF path only) · A12 · A13 (quality-class, warns) · A14 · A17 (report-only on markdown) ·
A18 loss gate · A19 per-doc spine · **A20** status partition · **A21** doc_type · **A22** per-note
sweep at compose · **A23** confidence · A-compose.

**A22 splits fatal from reported, defaulting to FATAL:** loss/corruption refuses the scope; quality
failures are named against the note that produced them.

## Open, in the order I would take them

1. **The MCP client.** Doc 3a pending. Sketch at `substrate/substrate/mcp/` (uncommitted): stdio
   JSON-RPC 2.0, stdlib only, `--db` per composed index, three tools (`retrieve` / `expand` /
   `overview`). The property worth keeping whatever else changes: **the result contract crosses the
   boundary intact** — every passage carries status/doc_type/confidence/domains/vault/citation/
   supersedes, every response carries the capability envelope + `index_version`. A model that cannot
   see `confidence=proposed` reads an unbuilt design as settled.
2. **Doc 2's text is behind its own implementation.** §6 documents `status` and stops; `doc_type`,
   `confidence` and the conversation class appear nowhere in the body. The spec in core-vault
   describes a system with one spine axis while the engine enforces three plus a source class.
3. **`reference_pins` is the last unimplemented §2 feature.** Parsed and shape-validated, acted on
   by nothing; everything else Doc 2 leaves unbuilt it explicitly defers. Open fork: apply the pin
   at compose (index only the pinned version) or at query (filter, mirroring status — which the
   "superseded-for-this-context" framing argues for). **Prerequisite:** only one versioned source
   exists, so there is nothing to pin *against* — building it now yields a feature whose test cannot
   distinguish working from no-op.
4. **The cutover.** `~/.claude/CLAUDE.md` still points every session at ClaudeVault, so the migrated
   vaults are complete and read by nothing while ClaudeVault keeps accruing. Deliberately waiting on
   the project being usable — which is what the MCP unblocks.
5. **Deferred, with reasons:** don't-embed-superseded (cost, not correctness — and the conversation
   carve-out is recorded as an explicit exception ON that work, so a later `WHERE status NOT IN
   (...)` cannot sweep it up); domain soft-weighting (eval-gated, needs cross-domain gold cases);
   the index watcher; the weekly lint (now unblocked, migration is done).
6. **Housekeeping:** A23 duplicates A21; raw tuples where the repo models records as dataclasses;
   `document_checks` is assertion policy living in `cli.py`; `unstated` is declarable despite a
   comment saying it is not.

## Constraints that bite

- **EVAL MUST NOT MOVE** — `4a4f765c9ad75dc9`, 1811 chunks. Re-check after any schema change.
  `out/substrate.db` is raw **v2**: open it read-only with `sqlite3` and a `mode=ro` URI, NEVER
  through engine code (`migrate()` drops and rebuilds on a version mismatch).
- Schema is **v6**, drop-and-rebuild. Read paths refuse a rebuilt-empty index rather than answering
  `(no results)` from it.
- **14 pre-existing lint errors** at committed HEAD (reader.py E702 ×4, embed/engine.py ×3, chunker
  B905, tests). Not mine, not to be fixed opportunistically.
- Serial model work only; weights on `/Volumes/ExtremeSSD`.
- Discipline: audit → review → implement → verify. `/crosscheck` after implementing (auto-applies
  what clears its bar), `/adversary` last before presenting (report-only). **Refuse rather than
  mislead.**
- **Do not `git add -A` over the tree.** It swept the operator's in-flight repaired-samples work
  into an unrelated commit this session; the history had to be rebuilt to separate it. Stage
  explicit paths.

## What this session shipped

Seven commits on `substrate-engine`, nothing pushed: the `doc_type` + `confidence` axes (v3→v5);
the example-pair rename + manifest TOML fix; the writing standard + second law + pilot read-out;
the conversation class + declared-values guard; the spec-family move; §3b raw provenance + manifest
validation (v6); and the operator's own repaired-samples work as its own commit.

Migration: **55 of 57 notes**, supervised note-by-note. Three deliberately not migrated (root
`MEMORY.md` indexes the dead structure; the Conversations folder README is navigation for a folder
that no longer exists; the root README was rewritten as `curate-the-vault` rather than copied).
