# Session handoff — Doc 4 phases 0–5 are done; the app and the engine are one system

**Reconciled against the repo 2026-08-10.** The previous version of this file was 76 commits and
12 days stale and predated Doc 4 entirely — it opened "the MCP server is built, deployed, and
running", which is still true but now means the ENGINE's, because the Swift one was deleted. The
corrections that mattered are listed under *What the last handoff got wrong* below; the durable
sections it carried (recovery procedure, the constraints, the assertions) are kept where re-verified
and marked where not.

## Bottom line

The disconnect this project opened on — "there is the engine and there is the app, and the app is
old" — is closed for capture, retrieval, browse, identity, documents AND asking. Calls are written
straight into workspace vaults, the engine is the only MCP server, the app reads the vault through
it, there is one Ask over one corpus behind a four-section shell, and `transcript_export`,
transcript `group:` and the second Ask are deleted rather than maintained.

What is left is the Swift retrieval stack.

| Doc 4 phase | state |
|---|---|
| 0 · six live defects | ✅ 2026-08-05 |
| 1 · capture declares the spine | ✅ |
| 2 · §7 vault migration; `transcript_export` + `group:` | ✅ 2026-08-07 / 2026-08-10 |
| 3 · one MCP server | ✅ 2026-08-07 (`adfe04e`) |
| 4 · identity; one document path | ✅ 2026-08-07 / 2026-08-10 |
| 5 · one Ask; four-section shell | ✅ 2026-08-10 |
| **6 · retire the Swift retrieval stack** | **◐ — the next task, and 5a did most of it** |

Doc 4 itself (`~/OneDrive/vaults/scripta-vault/03-references/doc4-engine-first.md`) is the decision
record and was reconciled against the repo in the same pass. Read it before the code.

## Open, in the order I would take them

**1. Phase 6 — retire the Swift retrieval stack, and 5a already stranded it.**
`Sources/Engine/Retriever.swift` (96 lines) now has **zero callers**: `AskModel` was its last one,
and the merged Ask retrieves through the engine. So the deletion is no longer a migration, it is a
deletion — what remains of the phase is the verification Doc 4 asks for, not the work.

Doc 4 still says this needs a live parity number, and Doc 3 §6's Swift-side parity test still does
not exist — `TransportTests:159` never runs the CLI and compares one answer to its own round trip.
**Note the parity test got harder, not easier:** Ask no longer returns a result object to compare,
it returns a generated answer over one. The comparable surface is the `search` call inside
`AskModel.run`, not Ask's output.

`IndexStore` is NOT stranded with it — the Calls list, the digest lens, entities, commitments and
`RelatedItemsPanel` all still read it. Phase 6 is the RETRIEVAL half only.

**2. `NoteStore` is the last holder of `group:`.** `DocumentImporter` is gone (Phase 4b), so the
document half is closed. Notes are app-local by construction, so location cannot answer for them
until §8's migration moves them into the vault. One change.

**3. Ask is a several-second operation.** Warm, end-to-end through MCP on fresh queries: median
5.6s. Dominated by HyDE generation, not reranking. A first query after the engine starts pays
~23–26s of model loading, because Ollama's default `keep_alive` is 5 minutes and the engine sets
none. **Operator has accepted this** (2026-08-10) — recorded so it is not re-opened as a bug. The
fix, if ever wanted, is residency (`keep_alive`, or pre-warming on launch), not the arms.

**4. `reference_pins` is still the last unimplemented Doc 2 §2 feature.** Prerequisite unchanged.

**5. `WorkspaceDeleter` does not purge `conversations.json`, and Phase 5 raised what that costs.**
Surfaced by review, NOT applied — widening a destructive operation is the operator's call. The
deleter cascades transcripts, index rows, FTS, the WAL, the entity registry under both name and
slug, entity mirrors and `WorkspaceBindings`; it has never touched chat history. Two consequences,
and the second is the one that changed:

- Threads now store `StoredPassage.snippet` — verbatim excerpts of the wiped workspace's notes and
  calls — where the pre-merge `Source` stored a title and a path. So "wipe Family before lending the
  laptop" now leaves more behind than it used to.
- `conversations(in:)` matches the workspace NAME exactly, so orphaned threads are invisible until
  someone creates a workspace with the same name, at which point every thread and passage from the
  wiped one is silently re-adopted. The deleter already reasons about exactly this hazard for
  bindings — "It also stops a later workspace of the same name silently re-adopting a wiped one's
  binding" — and the same argument was never applied here.

Default retention is `0` (keep forever), so nothing ages these out. One method on `AskModel`
(`forget(workspace:)`) plus a call in `WorkspaceDeleter.delete` closes it.

**6. Eighteen `/adversary` findings on the Phase 5 diff are UNTRIAGED — the operator had not picked
when the session ended.** Report-only by design, so none is fixed. Full list in the session log; the
seven ranked high, with the three one-liners first:

| # | where | what |
|---|---|---|
| 1 | `AskModel.bind(scope:)` | never clears `chat`, so the generator keeps the PREVIOUS scope's expanded context and can answer out of it while every control names the new one. Five other transitions clear it; this is the one that does not |
| 2 | `AskModel.pruneExpiredConversations` | bumps the epoch without clearing `running` or cancelling `task` — the only epoch path that does not. Orphans an in-flight run, and `running == nil` gates `start()` and both `canSend`s, so Ask locks until a workspace switch |
| 3 | `AskView` per-turn `ExclusionBar(filter:)` | takes the default no-op toggle, but `Pill` still wraps it in `Pressable` — every historical turn draws chips that hover, focus, press and do nothing. `VaultInclusionRefusal` exists to prevent exactly this |
| 4 | `AskModel.stop()` | epoch bump makes `run` return before the interrupted marker, so a stopped answer reads as a finished one (partial text, or a blank bubble if stopped before the first token) and persists on the next `syncCurrent`. Needs a decision, not a line |
| 5 | `AskModel.bind(scope:)` doc | first line still promises "and re-ask the standing question against it"; the body three lines down says "NOT RE-ASKED" |
| 6 | `nothingMatched` / `generationUnavailable` | both say "the bar above names what was not searched" — `VaultTurn` draws the answer FIRST and the bars after, so the bar is below |
| 7 | `AskView` | `ClovisAnswerFooter` is gone from the Ask pane and survives only in the drawer, so "copy answer" and "add to note" left the main surface. A silently deleted feature that this handoff did not notice — unlike the citation-navigation loss below, which was |

**A third of them are comments asserting properties the code does not have** (5, 6, and four mediums),
all written during this session and several while fixing `/crosscheck` findings. That is PRINCIPLES'
fourth law at roughly one per major edit, and it is the argument for `/adversary` being diff-only:
crosscheck had the files open and read those same comments as CONTEXT, which is how a false claim
survives a review that is otherwise looking straight at it.

**7. Ask lost citation→call navigation, and it is a real capability, not a rendering detail.**
Clovis's source rows opened the call at the spoken timestamp, which they could do because a
`ContextChunk` carried a local file path and a `startMs`. A `Passage` carries neither: its `path` is
structural (`"Oldfield Agency Call > Summary"`) and its `id` is an expand ref. The route back exists
— `expand(mode: "note")` returns `note.path`, a real file — so this is one round trip plus a rule
for which passages are app-recorded calls (a curated `class: conversation` note in `cbre-vault` is
NOT one, and routing it into the transcript reader would open a file that reader cannot show). It
was left undone rather than half-built; the citations render with the full spine and no affordance
that promises navigation.

## What Phase 5 shipped — 2026-08-10

**5b · the four-section shell.** `HubSection` is now `Ask · Calls · Library · Settings`.

| went | into | note |
|---|---|---|
| `home` (510 LOC) | the dashboard deleted; **the recording screen moved to Calls** | two things were parked in that file and neither was Home — see the failure pattern below. `CallsRecordingScreen` is now a `.recording` lens the recording lifecycle selects |
| `meetings` | Calls → Calendar lens | **and it gained a workspace filter it never had.** It listed every transcript on the machine, which was defensible as its own section and is not inside a surface whose scope indicator claims otherwise |
| `knowledge` | Library (vault lens) + Calls (Digest lens) | it was two unrelated surfaces sharing a picker |
| `docs` | Help menu (⌘?), own window | help is read BESIDE the thing it explains; a hub section replaced it |

**5a · one Ask.** `AskModel` + `AskView` (Clovis) and `SubstrateAskModel` + `SubstrateAskView`
became one `AskModel` + `AskView`. Retrieval is the engine's, generation consumes `Passage`.

- **The direction rule held.** Generation's context is built from passages, each labelled with its
  citation AND its spine, so `from a call · complete · unstated` reaches the model and not just the
  screen. `PromptCatalog.askInstructions` was rewritten to say what those labels mean — the corpus
  is no longer "your calls", and text telling a model otherwise made it describe a note as something
  someone said.
- **`Retriever.context` has no caller left.** That is Phase 6 arriving early, not scope creep: the
  direction rule makes the local retrieval path unreachable from Ask by construction.
- **Search returns snippets; generation needs full text.** Each passage is `expand`ed concurrently,
  so k round trips cost about one. The assembled context is budgeted PER PASSAGE from
  `enrichCharCap` rather than by dropping the tail — a dropped passage is one cited on screen that
  the generator never saw.
- **`askContextChunks` (6/14) was deleted, not re-pointed.** It counted cut fragments of one call;
  `k` is now 8 whole notes. The same integers under the new unit would be a number quoted without
  its conditions.
- **`Grounding` was deleted rather than ported.** Its two inputs (`isTopic` counts, a retrieval
  fallback flag) are properties of the local index and do not exist on this path, so carrying the
  strong/partly/thin label would have meant a new heuristic wearing a name calibrated for a
  different one. `EngineBar` replaces it: what ran, and the measured tier for that exact stack.
- **Persistence keeps the spine.** `AskConversation` / `AskMessage` / `StoredPassage` live in
  SubstrateKit, not the app target, because Doc 4 §6 says anything rebuilt lands where `swift test`
  can reach it. `StoredPassage` is a total, invertible projection — `unreported` round-trips as an
  ABSENT key (it has no wire token, and writing one would invent an engine verdict), and an
  unreadable token withholds the citation rather than relabelling it.
- **The old `conversations.json` still loads.** Decoding is tolerant in both directions: `workspace`
  falls back to the retired `group`, and absent keys read as absence. This was not optional — the
  store is one array read with `try?`, so a single missing key throws and the `?? []` behind it
  turns every conversation the operator ever had into a first launch. An old answer that HAD
  citations is flagged `citationsNotCarried` rather than rendering as one that cited nothing.
- **A filter change no longer rewrites the answer above it.** The exclusion and tier controls
  describe the NEXT question; each answered turn keeps a read-only record of what the engine
  actually did. A record a later control mutates is not a record.
- **Envelopes are live-session only.** `index_version` persists per answer (Doc 3 §6's parity
  value); arms and `expected_mrr` do not, because they describe a run that is over.
- **`ExclusionFilter` gained `vaults`.** The engine has always sent which tiers answered and the
  mapping dropped it. That was harmless only while the tier chips re-ran the query on toggle — the
  selection and the result were then in sync by construction. The thread breaks that sync
  deliberately, so the axis now travels with the RESULT.

**What the review caught, kept here because the build did not.** `/crosscheck` returned 23 findings
across three lenses; 15 were applied. The one that mattered is under *Failure patterns* below — the
`HomeView` deletion took the in-call recording screen with it, silently. Others worth knowing:
`bind(scope:)` did not fence its in-flight run (a `cbre` answer could land on the thread under
`prism`, permanently, because a turn records `index_version` and not scope); `AskModel.shared` was
never initialised unless the Ask pane had been opened with a serving engine, which left the Clovis
drawer showing an empty thread with a live send button that did nothing; and `Stop` was unreachable
during generation — `running` was cleared when retrieval returned, so the one control documented as
"the answer to a spinner that never resolves" was absent from exactly the state that produces one.

## What this session shipped earlier — 2026-08-10

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
- **A handoff's own effort estimate is a claim like any other.** This file called 5b "independent
  and mostly mechanical, safe to do first" and scoped 5a at "~1,780 lines across four files". Both
  were wrong in the same direction and for the same reason — they counted what was named rather than
  what was reachable. 5b's Knowledge half was ~2,100 lines across fifteen files with no stated
  destination, and 5a's blast radius included `ClovisDrawer` (238 lines, shares the same model and
  rendered the badge that had to go), which nothing in the estimate mentioned. **Grep for the
  consumers before quoting a size.**
- **Deleting a file deletes what was parked in it — and the compiler only warns you SOMETIMES,
  which is the trap.** `HomeView.swift` held two things that were not Home. `FlexWrap` (a `Layout`
  with six call sites in `Sources/Knowledge/`) failed the build immediately, so it looked like the
  compiler had the problem covered. It did not: the same file also held `recordingScreen`, the sole
  host of `LiveTranscriptPane`, `NoteComposer`, `LevelPane`, `RelatedCallsPanel` AND
  `LiveRecallPanel` — the live-vault surface shipped earlier the same day. **An unreferenced SwiftUI
  view compiles perfectly**, so the build stayed green while the app lost the entire screen it shows
  during a call, and `AppModel.syncRecordingClock` went on paying for a `LiveRecall` query every
  twenty seconds that nothing could render.

  Two rules out of it. **"This view is being deleted" and "everything in this file is dead" are
  different claims**, and only the second is safe to act on. And **a green build is evidence about
  types, not about reachability** — before deleting a view file, grep for every type declared in it,
  not just the one named in the plan. The Phase 5 audit named `HomeView` at 510 lines and never
  asked what those lines were.

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
- **`xcodebuild -scheme Scripta build` fails — the repo root holds TWO `.xcodeproj`.** It refuses
  with "contains 2 projects" rather than picking one; use `-project Scripta.xcodeproj`. And
  `Scripta.xcodeproj` is xcodegen-generated and untracked, so **adding or deleting a file needs
  `xcodegen generate --spec project.yml` before the build sees it** — sources are a directory sweep
  (`- path: Sources` with excludes), not a file list.
- **Do not `git add -A` over the tree.** Stage explicit paths. (And note `git add -A <dir>` resolves
  against the shell's cwd, which persists between tool calls — that is how a commit landed without
  its tests this session.)
- **`~/vaults/ClaudeVault/` is untouched and still live.**

## Assertions

Claims the next session may rely on without re-verifying, each with what established it.

| assertion | verified by |
|---|---|
| 587 engine tests pass | `uv run pytest tests/ -q`, 2026-08-10 |
| 229 Core tests pass (1 skipped) — 220 + Phase 5's 9 | `cd Core && swift test`, 2026-08-10 |
| The app builds after Phase 5 | `xcodebuild -project Scripta.xcodeproj -scheme Scripta build`, 2026-08-10 |
| The stored-passage spine survives JSON for EVERY value of all four axes | `AskConversationTests`, mutation-verified: nil→`unclassified` fails 3 of them, restored passes |
| Pre-merge `conversations.json` still decodes, `group` included | `testPreMergeConversationsStillDecode` |
| `Retriever.context` has zero callers | `grep -rn "Retriever.context" Sources Core`, 2026-08-10 |
| The `cbre` scope holds a real recorded call at tier 3 | `documents(scope: "cbre", include_sources: true)` → `call-2026-08-07-1021-30ea51de`, `conversation`, 2026-08-10 |
| Zero `DocumentImporter` references remain | `grep -rn DocumentImporter Sources Core`, 2026-08-10 |
| The migrated document is retrievable at tier 2 of `cbre` | `browse(vault: "cbre")` → one tier-2 row, 2026-08-10 |
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
> First item: **Doc 4 Phase 6 — retire the Swift retrieval stack.** Phase 5 shipped, and it left
> `Sources/Engine/Retriever.swift` (96 lines) with ZERO callers — the merged Ask retrieves through
> the engine. So the code deletion is trivial and the phase is really its verification: Doc 4 wants
> a live parity number, and Doc 3 §6's Swift-side parity test still does not exist
> (`TransportTests:159` never runs the CLI and compares one answer to its own round trip).
>
> **The comparable surface moved.** Ask no longer returns a result object — it returns a generated
> answer over one — so parity has to be asserted against the `search` call inside `AskModel.run`,
> not against what Ask shows. Decide that before writing the test.
>
> **Do not delete `IndexStore` with it.** The Calls list, the Digest lens, entities, commitments and
> `RelatedItemsPanel` all still read it. Phase 6 is the RETRIEVAL half only.
>
> Read first: `Sources/Engine/Retriever.swift`, `Sources/App/AskModel.swift` (`run`), and
> `Core/Tests/SubstrateKitTests/TransportTests.swift:159`.
>
> Before changing anything: `cd substrate && ./lint.sh` (16 pre-existing errors, not yours),
> `uv run python tools/fixture-signature.py out/substrate.db` (must print `4a560ce34aa6378a`,
> 1811 chunks), `uv run pytest tests/ -q` (587), `cd Core && swift test` (229), and
> `xcodebuild -project Scripta.xcodeproj -scheme Scripta build` (the bare `-scheme` form fails —
> two projects in the root). Discipline is audit → review → implement → verify, `/crosscheck` then
> `/adversary`.
