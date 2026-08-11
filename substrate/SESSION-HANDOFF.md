# Session handoff — Doc 4 phases 0–3 are done; the app and the engine are one system

**Reconciled against the repo 2026-08-10.** The previous version of this file was 76 commits and
12 days stale and predated Doc 4 entirely — it opened "the MCP server is built, deployed, and
running", which is still true but now means the ENGINE's, because the Swift one was deleted. The
corrections that mattered are listed under *What the last handoff got wrong* below; the durable
sections it carried (recovery procedure, the constraints, the assertions) are kept where re-verified
and marked where not.

## Bottom line

The disconnect this project opened on — "there is the engine and there is the app, and the app is
old" — is closed for capture, retrieval, browse, identity AND documents. Calls are written straight into
workspace vaults, the engine is the only MCP server, the app reads the vault through it, and
`transcript_export` and transcript `group:` are deleted rather than maintained.

What is left is one Ask and the Swift retrieval stack.

| Doc 4 phase | state |
|---|---|
| 0 · six live defects | ✅ 2026-08-05 |
| 1 · capture declares the spine | ✅ |
| 2 · §7 vault migration; `transcript_export` + `group:` | ✅ 2026-08-07 / 2026-08-10 |
| 3 · one MCP server | ✅ 2026-08-07 (`adfe04e`) |
| 4 · identity; one document path | ✅ 2026-08-07 / 2026-08-10 |
| **5 · one Ask; four-section shell** | **◐ — the next task** |
| 6 · retire the Swift retrieval stack | open |

Doc 4 itself (`~/OneDrive/vaults/scripta-vault/03-references/doc4-engine-first.md`) is the decision
record and was reconciled against the repo in the same pass. Read it before the code.

## Open, in the order I would take them

**1. Doc 4 Phase 5 — one Ask, and the four-section shell. TWO CHANGES, and the first is the
largest single piece left in Doc 4.**

### 5a · One Ask

~1,780 lines across four files: `AskModel` (360) + `AskView` (283) + `SubstrateAskModel` (367) +
`SubstrateAskView` (769). Each model owns something the other does not, which is why neither can
simply absorb the other:

| `AskModel` (Clovis) | `SubstrateAskModel` (vault) |
|---|---|
| persisted per-workspace conversations, pruned on expiry | the engine envelope and `retrieval_mode` |
| streaming, `LanguageModelSession` | the disclosure contract — `ExclusionBar`, the filters block |
| a mid-stream workspace switch that abandons its writes (audit H3) | scope binding + `adoptBinding` |
| | the five refusal states, and the four engine-lifecycle cards |

Doc 4 §2 names the target: *"Clovis's generation, streaming and persisted conversations, carrying
the vault Ask's disclosure contract."*

**THE DIRECTION RULE IS THE WHOLE THING, and it is stated in §2 because it is easy to get backwards:
`ContextChunk` → `Passage`, NEVER the reverse.** A `Passage` carries `status`, `doc_type`,
`confidence`, `document_class`, `vault` and `supersedes`; a `ContextChunk` carries none of them.
Converting the other way to reuse Clovis's existing generation path would silently drop the spine —
and the spine is the reason a model does not read an unbuilt design as settled. Whatever the merge
does with the two view layers, generation must consume `Passage`.

Two things already decided elsewhere that constrain this:

- **Ask is a several-second operation** (item 5 below) and the operator has accepted that. Do not
  reopen it as part of the merge.
- **`LiveRecall` already consumes `Passage` and renders the spine** (`LiveRecallPanel`), including
  naming `conversation` FIRST. It is the smallest working example of what generation-side rendering
  has to preserve — read it before designing the merged view.

### 5b · The four-section shell

Independent of 5a, mostly mechanical, and safe to do first. `HubSection.primary` is
`[.home, .calls, .meetings, .ask, .library, .knowledge]` and `.secondary` is `[.settings, .docs]`;
the target is **Ask · Calls · Library · Settings**. Doc 4 §2: Home is Swift aggregates over the
local index, Meetings folds into Calls, Knowledge splits, Docs becomes a Help menu item.

**Knowledge is not a simple deletion any more** — it now holds the vault lens (`This workspace |
Vault`) added 2026-08-10, which is a real surface. Decide where the Vault lens lands before removing
the section that hosts it; "Knowledge splits" was written before it existed.

**2. Phase 6 — retire the Swift retrieval stack.** `Sources/Engine/Retriever.swift` (96 lines).
Doc 4 says this needs a live parity number first, and Doc 3 §6's Swift-side parity test still does
not exist — `TransportTests:159` never runs the CLI and compares one answer to its own round trip.

**3. `NoteStore` is the last holder of `group:`.** `DocumentImporter` is gone (Phase 4b), so the
document half is closed. Notes are app-local by construction, so location cannot answer for them
until §8's migration moves them into the vault. One change.

**4. Ask is a several-second operation.** Warm, end-to-end through MCP on fresh queries: median
5.6s. Dominated by HyDE generation, not reranking. A first query after the engine starts pays
~23–26s of model loading, because Ollama's default `keep_alive` is 5 minutes and the engine sets
none. **Operator has accepted this** (2026-08-10) — recorded so it is not re-opened as a bug. The
fix, if ever wanted, is residency (`keep_alive`, or pre-warming on launch), not the arms.

**5. `reference_pins` is still the last unimplemented Doc 2 §2 feature.** Prerequisite unchanged.

## What this session shipped — 2026-08-10

Range `0a143f7..9fe7974`, 84 commits. Highlights, in dependency order:

- **`documents` — the engine's browse tool.** What a scope HOLDS, as opposed to what it matched.
  Needed because the app must be able to SHOW the vault and `search(query="")` is not a listing.
  Every row carries `vault` and `tier`, which is the part a directory listing cannot answer:
  measured on the live `cbre` scope, 62 notes of which 33 are in `core-vault`, a vault the workspace
  folder does not contain.
- **`VaultDocument` + the Knowledge vault lens.** Knowledge gained a `This workspace | Vault` switch;
  the right side is the composed scope read through the engine.
- **`LiveRecallPanel`** — the vault answers during a call, on the fast arm, with the weaker ranking
  on screen (`fast retrieval · ranking unmeasured`).
- **`transcript_export` DELETED** (675 lines + 29 tests). It had already become unrunnable: it
  refuses a destination inside the source, and refuses OneDrive under a Doc 3 §4 rule that §7
  withdrew. Its one irreplaceable capability — MOVING a flat transcript into a vault — is now
  `TranscriptGroupRepair.file`.
- **Transcript `group:` retired.** The workspace is derived from the vault the file sits in, reading
  the manifest for the operator's casing (not the slug — every query site partitions on the raw
  name). "Unfiled" now means *in no vault*, not *no label*.
- **Refresh agent: two live defects.** It composed from `$HOME/OneDrive/vaults/$s-vault`, a path
  derived from the scope NAME — so the next recorded CBRE call would have rebuilt `cbre` from the
  wrong vault and dropped every call from the scope. And it never checked vector coverage, so a
  degraded index stayed `unchanged` forever once the vault went quiet.
- **Embedder: one chunk 34 chars too long cost a 321-note corpus its vector arm.** A failed batch is
  now bisected and a single refused input shrunk until accepted, with the truncation reported.
- **v9 → v10 migration of all six scopes**, fully embedded, all `unchanged`, none frozen.
- **The rerank default moved to the cross-encoder** and kept its number — `_STACKS` became a
  sequence so one embedder can front two measured stacks. On the vault corpus the shipped listwise
  arm measured BELOW no reranker at all (semantic MRR 0.426 against 0.494); the cross-encoder is
  0.679 and faster end-to-end.
- **Phase 4b, all four steps: one document path.** `DocumentImporter` (339 lines) deleted along with
  its `Files/` pass, `indexDoc`, `DocumentDetailView`, `DocumentSheet` and `OpenDocTarget`. Both
  ingest paths became `SubstrateLibraryModel.performAdd`; the shelf reads the vault; the operator's
  one existing document was migrated and verified retrievable. Delete now routes through
  `remove(source:)` — `expand` gives the note path, up two components is the source directory.

## What the last handoff got wrong

Corrections found by reconciling, not by being told:

- **"there is no pytest; expect 412 assertions across 27 files"** — false. `uv run pytest tests/ -q`
  works and reports **587 passed**.
- **"14 pre-existing lint errors"** — was 15 at `5855f60` and is **16** now. Two of the delta were
  mine and are fixed; the rest is pre-existing and stays.
- **Phase rows 3 and 4 sat at their pre-`adfe04e` state for three days** while both had shipped.
  Doc 4's own §5 table, not this file — corrected there.
- The doc's mutual-block note for phases 3 and 4 was resolved the same day it was written, by
  DELETING the four entity tools rather than porting them. That closure was never recorded.

## Failure patterns this session earned

- **Quoting a number without its conditions — twice, in both directions.** I reported Ask at 17s
  (a cold model load, not the stack), then reported the reranker's `expected_mrr` gain as a quality
  measurement when it is a DECLARED tier from a different corpus — with the contradicting measured
  figure two sections up in the same document. Then I quoted an eval p50 (586ms, HyDE expansions
  cached) as user-facing latency, and separately alarmed at 17.6s that was an engine I had restarted
  seconds earlier. The generalisable shape: a number without its conditions is not a small error,
  it is a different claim.
- **"Pre-existing" is not the same as "not mine to care about."** Four `ScriptaVaultTests` were
  failing. I checked, confirmed they predated my change, and nearly moved on. They were a live bug
  from `69ec829`: the manifest declared the identity registry at the vault root while
  `EntityRegistry` writes one shared roster at the output-folder root, and the engine hard-fails a
  declared-but-missing identity file. The operator's `cbre` vault was one recorded call away from
  never composing again. The check that established the failures predated me is the check that
  almost buried them.
- **A piped exit code is the pipe's.** `pytest … | tail -2` reports `tail`'s status, so `&&` ran and
  two failing tests were committed. Read the count, not the chain.
- **File size is not liveness.** Subagent transcript files sat at 152 bytes for minutes while the
  agents worked; I read that as stalled and killed three reviewers that were fine.

## Constraints that bite

- **EVAL MUST NOT MOVE** — signature `4a560ce34aa6378a`, 1811 chunks. *Re-verified 2026-08-10:*
  `uv run python tools/fixture-signature.py out/substrate.db`.
- **The refresh agent runs the DEPLOYED engine, but the agent SCRIPT is the repo's.**
  `~/.local/bin/substrate-refresh` is a shim that `exec`s `substrate/tools/substrate-refresh`
  directly — so editing that file changes what runs every 900 seconds IMMEDIATELY, with no deploy.
  I edited it mid-session and it was live before it was committed, including a window where it had
  a syntax error. Only `tools/substrate-deploy` moves the ENGINE.
- **Deploying is not free.** It moved the engine to schema v10 against v9 indexes and put five of
  six scopes into `schema_mismatch`, breaking every read on them until they were migrated. Check
  `SCHEMA_VERSION` against the live indexes before deploying.
- **A schema bump silently breaks every already-running MCP client** — Python imports at process
  start; a long-lived server keeps the old module.
- **Do not `git add -A` over the tree.** Stage explicit paths. (And note `git add -A <dir>` resolves
  against the shell's cwd, which persists between tool calls — that is how a commit landed without
  its tests this session.)
- **`~/vaults/ClaudeVault/` is untouched and still live.**

## Assertions

Claims the next session may rely on without re-verifying, each with what established it.

| assertion | verified by |
|---|---|
| 587 engine tests pass | `uv run pytest tests/ -q`, 2026-08-10 |
| Zero `DocumentImporter` references remain | `grep -rn DocumentImporter Sources Core`, 2026-08-10 |
| The migrated document is retrievable at tier 2 of `cbre` | `browse(vault: "cbre")` → one tier-2 row, 2026-08-10 |
| 220 Core tests pass (1 skipped — needs a live engine) | `cd Core && swift test`, 2026-08-10 |
| The app builds | `xcodebuild -scheme Scripta build`, 2026-08-10 |
| All six scopes are v10, fully embedded, `unchanged`, `frozen=false` | per-scope `status`/`query`, 2026-08-10 |
| The deployed engine is `dc0de78`'s ancestor `67948ac` or later | `tools/substrate-deploy --show` |
| No Swift MCP server exists | `SourcesMCP/` is empty; only `MCPStateFile.swift` remains, feeding `guard_state` |
| The shipped default rerank stack has a measured number (0.708) | `test_the_shipped_default_stack_has_a_number` |

## Ready-to-paste next-session prompt

> Working on Scripta (branch `substrate-engine`, repo `~/CodeHome/CallTranscriber`; the engine is in
> `substrate/`). Read `substrate/PRINCIPLES.md` (four laws), then `substrate/SESSION-HANDOFF.md`,
> then Doc 4 at `~/OneDrive/vaults/scripta-vault/03-references/doc4-engine-first.md` §§2–5. Doc 2
> lives in `~/OneDrive/vaults/core-vault/00-operator/specs/` — the repo has a pointer, not a copy.
>
> First item: **Doc 4 Phase 5 — one Ask, and the four-section shell.** It is TWO changes and the
> handoff scopes both. 5b (the shell) is independent and mostly mechanical; 5a (one Ask) is the
> largest single piece left in Doc 4 — ~1,780 lines across `AskModel`, `AskView`,
> `SubstrateAskModel` and `SubstrateAskView`, each model owning something the other does not.
>
> The rule that decides 5a is Doc 4 §2's: **`ContextChunk` → `Passage`, never the reverse.** A
> `Passage` carries the spine and a `ContextChunk` carries none of it, so converting the other way
> to reuse Clovis's generation path silently drops `confidence` and `document_class` — which is the
> whole reason the spine exists. Read `Sources/App/LiveRecallPanel.swift` first: it is the smallest
> working example of generation-side rendering that preserves the spine.
>
> Read first: `Sources/App/AskModel.swift`, `Sources/App/SubstrateAskModel.swift`,
> `Sources/App/SubstrateAskView.swift`, and `Sources/App/Navigator.swift` (`HubSection.primary`).
> Note that Knowledge now hosts the vault lens, so "Knowledge splits" needs a destination for it
> before that section can move.
>
> Before changing anything: `cd substrate && ./lint.sh` (16 pre-existing errors, not yours),
> `uv run python tools/fixture-signature.py out/substrate.db` (must print `4a560ce34aa6378a`,
> 1811 chunks), `uv run pytest tests/ -q` (587), and `cd Core && swift test` (220). Discipline is
> audit → review → implement → verify, `/crosscheck` then `/adversary`.
