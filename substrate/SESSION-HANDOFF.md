# Session handoff — the engine ships inside the app; notarization is the last unknown

**Reconciled against the repo 2026-08-15.** Ten corrections are listed under
*What the last handoff got wrong*; the largest is that Doc 5 was the agenda and is now two commits.

**Earlier header, kept because the sections below still carry its reasoning — reconciled 2026-08-10.** The previous version of this file was 76 commits and
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

Nothing in Doc 4 is left. Phase 6 closed 2026-08-11 and there is one retrieval implementation.

**Doc 5 — packaging — SHIPPED 2026-08-14/15** (`5c9cfac`, `74f4aac`). The engine is built into
`Scripta.app/Contents/Resources/substrate-engine` by a post-build phase, and a relaunched app
spawns it — candidate 1 of `discover()` winning for the first time. Nothing Scripta needs is
hand-installed. What is NOT done is notarization: never attempted, and the only part of the plan
with no evidence behind it.

| Doc 4 phase | state |
|---|---|
| 0 · six live defects | ✅ 2026-08-05 |
| 1 · capture declares the spine | ✅ |
| 2 · §7 vault migration; `transcript_export` + `group:` | ✅ 2026-08-07 / 2026-08-10 |
| 3 · one MCP server | ✅ 2026-08-07 (`adfe04e`) |
| 4 · identity; one document path | ✅ 2026-08-07 / 2026-08-10 |
| 5 · one Ask; four-section shell | ✅ 2026-08-10 |
| 6 · retire the Swift retrieval stack | ✅ 2026-08-11 (`cbdb584`, `efd8254`) |

Doc 4 itself (`~/OneDrive/vaults/scripta-vault/03-references/doc4-engine-first.md`) is the decision
record and was reconciled against the repo in the same pass. Read it before the code.

## Open, in the order I would take them

**1. Notarization. The last unknown, and the only thing that could still invalidate bundling.**
Never attempted. Whether Apple's notary service accepts a 1.4 GB bundle with 366 nested binaries is
untested, and it is the one step with no evidence behind it. Blocked on one interactive command:
`xcrun notarytool store-credentials "notary" --apple-id <id> --team-id 6CTH5M9UWZ`. Everything
around it is verified — Developer ID on the app and all nested binaries, hardened runtime, secure
timestamps throughout, seal valid — so a failure here should be about the submission, not the
contents. `Distribution/RELEASING.md` is the runbook and was rewritten this session.

**2. Point the `substrate` MCP at the bundled helper.** It still runs
`~/.local/bin/substrate-mcp` (verified `claude mcp list`), which execs the working tree. Doc 5 §4.6
wants `Scripta.app/Contents/Resources/substrate-engine/bin/substrate-mcp`, which is spawnable
whether or not the app runs. This got MORE relevant this session: tiers 2 and 3 are now `#if DEBUG`,
so the shim is a developer artifact the shipped app will not use.

**3. Two dead scopes are in the registry and the refresh loop will freeze them every tick.**
`cleantest` and `scripta-default` in `~/.substrate/scopes.toml` point at deleted scratchpads from
earlier sessions; `status` on either FATALs. The loop correctly records `compose_failed`, which is
honest and is also noise in a health signal. Delete the two `[scopes.*]` blocks. Not done here
because the registry is the operator's.

**4. The workspace-creation button has never been clicked.** `AppModel.createWorkspace` builds,
tests pass, and its guards are covered — but whether the menu item creates a vault and whether the
refusal alert RENDERS is unverified. The refusal is the part to distrust: it presents from inside
the dismissing alert, and an adversary reviewer argued `Task { @MainActor }` is not a real runloop
hop and that two stacked `.alert` modifiers on one view can still drop the second. If Create
silently does nothing on the name "Notes", that is what happened and `DispatchQueue.main.async` is
the fix.

**5. `NoteStore` is the last holder of `group:`.** Unchanged and re-verified
(`Sources/Knowledge/NoteStore.swift:10,38,45,80`). Notes are app-local by construction, so location
cannot answer for them until §8's migration moves them into the vault. One change.

**6. Adversary findings 9–22, none blocking.** The slug-collision guard (`caseInsensitiveCompare`
catches case, but the harm is a slug collision: "My Deals" vs "My-Deals"), the uncleared
`newWorkspaceName`, the TOCTOU in the half-written-vault cleanup, and the low-confidence set. Listed
in full in this session's `/adversary` output.

**7. Doc 5's own still-open list** — the unauthenticated loopback reads (three reviewers across two
passes flagged it; the recorded reasoning at `server.py:1522` argues about writes and does not cover
reads), the bundled CLI's relative write defaults, interpreter provenance, universal vs arm64, and
the `scripta` scope rename.

**8. `reference_pins` is still the last unimplemented Doc 2 §2 feature.** Re-verified: `vault.py:143`
VALIDATES the table at parse time and the comment there says both features that would read it are
deferred. Parsed is not implemented.

**9. Ask is a several-second operation.** Unchanged, and **the operator accepted it** (2026-08-10).
Recorded so it is not re-opened as a bug.

**10. Ask lost citation→call navigation.** Unchanged from the last handoff; still a real capability
rather than a rendering detail.

## What shipped — 2026-08-13/15 (`5c9cfac`, `74f4aac`)

**Doc 5, and the doc was rewritten against what was measured rather than the reverse.** Its §2/§3
rested on "ingest is one indivisible 1.2 GB thing", which is false: `docling` is
`docling-slim[standard]` and the weight is in two extras. Three tiers were built and run — core
23 MB, office 160 MB (8 formats, no torch, byte-identical output), full 1.0 GB. Bundling everything
is the operator's decision, taken knowing the alternative.

**Six decisions recorded in Doc 5 with their reasoning**, four of which narrow something an earlier
document argued for: refresh becomes an in-app compose loop; `Scripta-MAS` retired; "New workspace…"
writes the vault; a separate `Distribution` configuration; bytecode stays (294 MB for import speed);
the CLI's relative write defaults left alone (`out/substrate.db` is the pinned eval fixture).

**The build step** (`substrate/tools/build-bundled-engine`) vendors a relocated
python-build-standalone, builds the venv `--no-dev --compile-bytecode`, compiles the three on-device
arms from committed Swift source, writes both shims, and signs and VERIFIES 366 Mach-O — asserting
each carries a valid signature AND the hardened-runtime flag before it will finish.

**The refresh loop replaced an agent that could not run from a bundle.** Between retiring the launchd
job (2026-08-12) and nil-ing tier 1's `refreshAgent`, NOTHING refreshed except a finished recording.
Measured after relaunch: all six live scopes composed into their registered databases, none frozen.

**Four failures a green build does not show, each found by checking a property rather than reading
code:**

| # | failure | mechanism |
|---|---|---|
| 1 | the app broke its own code signature on first launch | `cp -R` reset mtimes, so CPython rewrote `.pyc` INSIDE the sealed bundle; `uv sync` also ships no bytecode, so the first `import docling` writes thousands more |
| 2 | incremental builds shipped a broken seal | the phase ran after `CodeSign` whenever Xcode's own inputs had not moved — a hardened-runtime bundle whose seal does not match does not warn, it refuses to launch |
| 3 | two hardening flags cancelled | `-E` makes CPython ignore every `PYTHON*` variable INCLUDING `PYTHONDONTWRITEBYTECODE`, so adding `-E` to close a `PYTHONPATH` hijack switched the bytecode guard off. `-B` survives `-E`; `-I` breaks the engine outright |
| 4 | Developer-ID-signing unreviewable bytes | `substrate/bin/` is gitignored, so bundling it signed and notarized binaries no diff or clean clone could tie to their sources |

**Three security findings, all from review rather than testing:** `WorkspaceBindings.forget` cleared
two of three stores, missing the one `contextVaults` reads FIRST — so a wiped workspace's private
vault paths survived and the new Create button would have written them back as `inherits`.
`ScriptaVault`'s adoption guard only fired once the colliding directory existed, but `Notes/` is
created lazily, so on a fresh install typing "Notes" claimed that path and a later wipe would have
deleted every knowledge note. And the discovery ladder still reached into `$HOME` in a shipped
build; tiers 2 and 3 are now `#if DEBUG`.

**`Distribution/RELEASING.md` drove a deleted scheme, built the shipping channel as `Release`, and
claimed "Sandbox: Yes" for an app unsandboxed since Doc 3 §1.** Rewritten. Its verification block
could not fail — one `grep -E` with alternations exits 0 on any single match.

## What shipped after Doc 4 — 2026-08-11/12

**A legibility pass over the whole shell, and the reason it was needed is the finding**
(`012cf84`). Phase 5 restructured the navigation model and NOTHING HAD BEEN RENDERED. The build
was green and 245 tests passed through every defect below, because none of them is a thing a type
checker or a unit test can see. They were found by the operator opening the app.

**One mistake, eight symptoms: disclosure rendered UNCONDITIONALLY on surfaces that repeat.** The
console it came from showed ONE result, so a full envelope under it was proportionate; a thread
stacks it under every turn and a list under every row. Rule 3 — a healthy engine is quiet —
violated by the code written to serve it. The fix is the same everywhere: collapse what a healthy
default would say, and never collapse a DEVIATION.

**Two capabilities were unreachable, both from deleting `HomeView`** on the strength of Doc 4
calling Home "aggregates over the local index" — which described its dashboard and not the other
half of that file. The recording screen went first (restored by review); then the way IN to it,
because `Record` was gated on the app being busy so the "Ready to record" card could not be
reached at all. `Home` is back as a LANDING and deliberately not the dashboard §2 retired.

**The live transcript was half-deaf.** One transcriber on the mic, so a two-party call showed only
your side — and `LiveRecall` read that same half, asking the vault about your own sentences rather
than the client's. Two transcribers now, labelled You/Them.

**And the app already knew things it was not saying.** The vault list re-read only on first load
while three paths change a vault, each ending in a compose the app watches finish. All three now
invalidate it — `composeAfterRecording` was ALREADY re-listing the roster on that reasoning and
the list simply was not told. The Boundary Principle, in the wiring rather than the logic, for the
third time this session.

**Two dead MCP servers removed from the Claude Code config** (2026-08-12). `scripta` pointed at
`build/Debug/Scripta.app/Contents/MacOS/scripta-mcp` and `calltranscriber` at a `.app` that no
longer exists — both failing `ENOENT`, both corpses of the Swift server Phase 3 deleted
(`adfe04e`). **`substrate` is the only one, and it is correctly named**: the engine is the product,
which is Doc 4's whole thesis. The `scripta` SKILL was rewritten with them — it described eight
tools of that dead server, and Doc 4 §5 records where each went (six have engine equivalents, four
were deleted rather than ported and live only in the app). Its load-bearing correction: calls are
`conversation`-class and therefore WITHHELD from default retrieval, so every call query needs
`include_sources: true` or the engine answers from curated notes and the silence reads as "no such
call".

**`com.ronanwood.substrate-refresh` is retired** (operator, 2026-08-12). Doc 3 §2 decided it and
`SubstrateRefresh.swift` had sequenced removal as the operator's act once the in-app half worked.
Nothing of Scripta's outlives Scripta now — measured: app running → 3 engine processes, quit → 0
orphans, relaunch → engine back on `:8765`. The plist is backed up in the session scratchpad.
CONSEQUENCE TO KNOW: vaults refresh only while the app is open, so a Claude Code session after a
week of not opening Scripta reads a week-old index — and `refresh.frozen` will say `false`,
because nothing failed, nothing ran.

**Two dead MCP servers removed and the `scripta` skill rewritten** — see below. **The engine now
ships `instructions`** (`c61055d`): `initialize` returned a name and a version and nothing about
what the server is FOR, so the rules that span tools lived only in the operator's global CLAUDE.md
and every other client of this engine got none of them. Four rules earned a line, on the bar that
not knowing one produces a WRONG ANSWER rather than a slow one — calls withheld by default is the
one that bites hardest. **NOT DEPLOYED**: the live MCP keeps the pinned commit until
`tools/substrate-deploy` runs.

### The workspace wipe reaches chat history — 2026-08-11 (`4c4c166`)

 `WorkspaceDeleter` had never touched
`conversations.json`; Phase 5 made that matter, because a thread now holds verbatim passage
snippets rather than a title and a path. The rule is `ConversationPurge` in SubstrateKit, and the
subtle half is that it sits OUTSIDE the `!group.isEmpty` gate: `""` is the EntityRegistry's global
vocabulary sentinel, which is why that gate exists, and it is ALSO just Ungrouped for conversations
— so gating this the same way leaves Ungrouped's history behind on every wipe of it. Mutating the
rule to read `""` as a wildcard turns "wipe Ungrouped" into "wipe everything", and that is the test
that trips loudest. Orphans from wipes performed BEFORE this shipped are deliberately not swept:
identifying them needs to know which names are still real, and `availableGroups()` omits a
workspace with no calls yet, so a sweep would delete live threads to clean up dead ones.

## What Phase 6 shipped — 2026-08-11

**The parity test Doc 4 named as the blocker now exists** (`MappingParityTests`). It asserts what
Doc 3 §6 wants in the form checkable from Swift — every field the reader sees is the field the
engine sent — and does NOT invoke the CLI: the CLI renders through the same `render.py` the wire
payload came from, so running it tests Python against itself, and `test_entrypoint_parity.py`
already pins arm parity between entry points. **Two fields are allowed to diverge and both are
asserted as RULES rather than equality**, because equality would fail on correct code and pressure
someone into deleting a safety net: `degraded` may only be RAISED, and an `off` arm the health block
calls `unavailable` is PROMOTED.

**Then the stack went, both halves.** `Retriever` · `RRF` · `Embedder` · `EmbeddingEngine` ·
`IndexBuilder.embedPending` · nine `IndexStore` methods · the embeddings picker ·
`AppSettings.embedModel` · `VectorCoverageTests`. `chunk_vectors` is dropped at open rather than by
a schema bump — the table is the largest an installed DB holds, and a bump would re-chunk the whole
corpus to reclaim space nothing uses.

**The framing that decided the second half, and it was the operator's correction.** The question
was posed as delete-vs-keep a feature, and that trade no longer existed: `vectorCandidates` — the
only retrieval read of `chunk_vectors` — had already gone with the read stack, so the capability was
lost one commit earlier and committed. What remained was *stop doing work nothing consumes* versus
*keep doing it*, and the work was live: `embedModel` was set in the operator's defaults, so every
launch walked every indexed path and made an embedding call per chunk to write vectors nothing would
read.

**And the doc could not have decided it.** Doc 4 §2's delete row lists `IndexStore (1,209)` beside
`Embedder`, and `IndexStore` is load-bearing for Calls, the digest, entities and commitments. A row
wrong about one member is not an authority on the others — but it did not need to be, because the
empirical check (zero callers, per method) is decisive and the vector methods are separate from the
ones those surfaces use.

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
across three lenses (15 applied); `/adversary` then read the diff with no reasoning attached and
found 18 more (14 applied, `73f516d`). The one that mattered is under *Failure patterns* below — the
`HomeView` deletion took the in-call recording screen with it, silently.

**The generalisable result is the DIFFERENCE between the two gates.** Crosscheck's reviewers get the
touched files opened for context; adversary's get the diff and nothing else. Six of adversary's
findings were comments asserting properties the code did not have — and crosscheck had read those
same comments, as context, without questioning them. A false claim in a comment is invisible to a
reviewer who is using that comment to understand the code. Run both; the second is not a slower
version of the first.

Three worth carrying as shapes rather than as fixed bugs:

- **A fence that stops the wrong half.** `bind(scope:)` bumped the epoch, which abandons a stale
  REPLY — and left `chat`, which is where the previous scope's expanded context lives. The next
  answer would then be generated from stale MATERIAL, which no epoch guard can see.
- **The only path that forgot.** `pruneExpiredConversations` bumped the epoch without clearing
  `running`. Six sibling methods did it correctly; correctness by repetition fails at the seventh.
- **A control absent from the state it exists for.** `running` was cleared when retrieval returned,
  so Stop — documented as "the answer to a spinner that never resolves" — was unreachable for the
  whole of generation, the phase that actually hangs.

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

Corrections found by reconciling against the repo 2026-08-15, not by being told:

- **"Doc 5 — packaging is the next body of work"** — shipped, `5c9cfac` + `74f4aac`.
- **"Nothing is bundled in the app today"** (Assertions) — false. The engine is in
  `Contents/Resources/substrate-engine` and the app spawns it.
- **"245 Core tests pass (2 skipped)"** — **247** now; two were added for the reserved-name guard.
- **"The deployed engine is `67948ac` or later"** — still exactly `67948ac`, now **29 commits
  behind HEAD**, and its MEANING changed: tier 2 is `#if DEBUG`, so `~/.substrate/engine` is a
  developer artifact the shipped app never reaches, and nothing runs its refresh agent any more.
- **"the DEPLOYED engine is behind HEAD … `c61055d` added MCP `instructions`"** — still true and now
  further behind. Deploying remains a decision rather than a chore.
- **The `substrate` MCP entry** was described as correctly named and is correctly named, but it
  still points at `~/.local/bin/substrate-mcp` — the developer shim, not the bundled helper.
- **"~86 commits ahead of `origin/substrate-engine`"** — verified, still 86 after two commits.
- **Two `.xcodeproj` in the repo root** — re-verified (`CallTranscriber.xcodeproj`,
  `Scripta.xcodeproj`). The `-project` constraint holds.
- **`com.ronanwood.substrate-refresh` retired** — re-verified, `launchctl list` shows nothing.
- **`reference_pins`** — the claim "unimplemented" is right for the wrong reason: it IS validated at
  parse time (`vault.py:143`); what is deferred is anything that reads it.

Carried forward from 2026-08-10, still accurate:

- **"there is no pytest; expect 412 assertions across 27 files"** — false. `uv run pytest tests/ -q`
  works and reports **587 passed**.
- **"14 pre-existing lint errors"** — was 15 at `5855f60` and is **16** now. Two of the delta were
  mine and are fixed; the rest is pre-existing and stays.
- **Phase rows 3 and 4 sat at their pre-`adfe04e` state for three days** while both had shipped.
  Doc 4's own §5 table, not this file — corrected there.
- The doc's mutual-block note for phases 3 and 4 was resolved the same day it was written, by
  DELETING the four entity tools rather than porting them. That closure was never recorded.

## Failure patterns this session earned — 2026-08-13/15

- **Two safety mechanisms, each correct alone, that cancel when combined.** `-E` closed a
  `PYTHONPATH` hijack and silently disabled the `PYTHONDONTWRITEBYTECODE` guard added an hour
  earlier. Both lines read as hardening, which is why three crosscheck reviewers looked straight
  past them; the diff-only adversary pass caught it. **When you add a second guard beside a first,
  test the first still fires.**
- **A number measured through a pipe is not a measurement.** Bytecode was reported as 57 MB from
  `find … | xargs du -ck | tail -1`, where `xargs` batches and `tail -1` takes only the last batch.
  The real figure is 294 MB — the entire 1.1→1.4 GB difference. Same shape as the piped exit code:
  the harness, not the thing.
- **A verification that returns the right answer for the wrong reason.** A perl filter matched every
  line while capturing an EMPTY path, producing 363 blank strings that counted like a correct
  answer — and I reported "exhaustive 363, predicate 363, zero missed" on the strength of comparing
  blank lines. The conclusion happened to be right. **Check that a check can distinguish the two
  worlds before quoting it.**
- **A `str.replace` that does not match reports nothing.** A stale comment survived a fix because
  the replacement string had the wrong indentation, and the adversary pass found the file asserting
  two opposite policies. Every scripted edit now asserts its target was present.
- **Fixing a claim can break the test that encoded the old one, and that is correct.** Giving
  reserved names their own error broke `testAWorkspaceCannotAdoptADirectoryItDidNotCreate`. The fix
  was to expect the right error PER NAME, not to loosen the assertion to "any error" — the two
  refusals are not interchangeable.
- **A fixture must reach the state the assertion objects to.** The first grandfathering test tried
  to create a "Notes" vault through the front door, which the new guard correctly refuses. The state
  being grandfathered can only predate the guard, so the fixture had to build it via the
  initializer. Mutation-checked afterwards, both directions.
- **Reviewers contradict each other, and the tie-break is a measurement.** Two adversary reviewers
  disagreed on whether bash services an EXIT trap on an untrapped SIGTERM. It does — tested. A third
  called `OTHER_CODE_SIGN_FLAGS: --timestamp` a blocker on the reasoning that Xcode appends
  `--timestamp=none` after it; the post-fix build log shows zero occurrences of that flag. **Verify
  before applying on authority; five of this session's findings were refuted with evidence.**
- **Closing a hole can open another, in the same file, the same day.** Nil-ing tier 1's
  `refreshAgent` was right — the agent trusted a user-writable record for its exec paths — and it
  left the machine with no periodic refresh at all, because the launchd job had already gone. The
  gap existed for the length of one commit and was only noticed by asking "what is next".

## Failure patterns from 2026-08-10, kept

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
- **I defended a leftover as a design, then reversed inside two turns.** Asked whether everything
  was internal to the app, I answered with four categories and framed the launchd refresh agent as
  a FEATURE serving another consumer — arguing the operator should keep it because Claude Code
  depended on it. It was not a feature; it was the second half of a migration Doc 3 §2 had already
  decided and `SubstrateRefresh.swift` had explicitly sequenced as the operator's act. One push
  back later I removed it. **An accurate description of a half-migrated state, given without saying
  it is half-migrated, reads as an architecture** — and the operator then has to argue against a
  design that nobody chose.
- **Answering the narrow question when the broad one was asked.** "Should the MCP be renamed",
  "should reading require the app" — I answered both, twice, while the actual question was *why is
  this spread across my filesystem instead of being an app*. The answer was available the whole
  time and is now Doc 5: `discover()` prefers a bundled engine, nothing bundles one, and everything
  confusing on that machine is pre-packaging scaffolding. **When an operator asks the same shape of
  question three times, the question being answered is the wrong one.**
- **A green build is not a rendered screen, and this cost more than everything else combined.**
  Phase 5 restructured the navigation model; the build passed and 245 tests passed and the app was
  not looked at once. What that hid: the entire in-call recording screen deleted, then the way into
  it; the live transcript hearing one side of a two-party call; note sheets showing raw YAML and
  literal `**bold**`; a disclosure block taller than the answer it qualified, under every turn.
  Every one was found by opening the app, and each took minutes to fix. **Open the app after a
  change to a view. The suite cannot see layout, reachability, or a control that does nothing.**
- **A test written to enforce the discipline broke the discipline.** The first `MappingParityTests`
  COULD NOT FAIL: both golden captures carry `degraded: false` and `filters.vaults: null`, so one
  assertion was a branch that never ran and the other was `nil == nil`. Measured, not suspected —
  inverting the `degraded` mapping and deleting `vaults` from the filter mapping BOTH went green.
  PRINCIPLES already names this exact shape (the A17 fixture that passed with the fix and without
  it), and it reappeared inside the test written to enforce it. **A fixture has to reach the state
  the assertion objects to, and the only way to know it does is to break the code and watch.**
  `patchedSearch` now moves the real frame into those states; the same mutations trip 2 and 1
  assertions, and dropping the arm promotion trips 6.
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

- **The engine is now BUILT BY THE APP, so `xcodebuild` is no longer a Swift-only step.** A change
  under `substrate/substrate/` or to the three `tools/*.swift` arms invalidates the build
  fingerprint and re-runs a multi-minute 1.4 GB rebuild. Unchanged inputs skip in ~3s.
- **`Release` must never ship.** It signs with an Apple Development certificate and Xcode gives the
  app `--timestamp=none`. `Distribution` is the shipping configuration and had to be declared at
  PROJECT level — xcodegen synthesises only Debug and Release, and a `Distribution:` block under a
  target's `configs:` without that declaration is silently inert.
- **`~/.substrate/engine` is now developer-only.** Tiers 2 and 3 are `#if DEBUG`. A Release or
  Distribution build resolves the bundled engine or reports `notInstalled`; it will not fall back.
- **The refresh loop is the app's, and only runs while the app is open.** No launchd job, no agent.
  A machine that has not opened Scripta for a week reads a week-old index — and `refresh.frozen`
  will say `false`, because nothing failed, nothing ran.
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
| 587 engine tests pass | `uv run pytest tests/ -q`, 2026-08-15 |
| 247 Core tests pass | `cd Core && swift test`, 2026-08-15 |
| The app spawns its OWN bundled engine | relaunch → `…/Scripta.app/Contents/Resources/substrate-engine/.venv/bin/python -B -E -s -m substrate.mcp.server`, 2026-08-15 |
| 366 nested Mach-O signed, hardened, timestamped; seal valid | Distribution build + `codesign -dv`, 2026-08-15 |
| Running the engine writes NOTHING into the bundle | marker file + `find -newer` → 0 files; seal still valid, 2026-08-15 |
| A relocated tree runs (moved twice, stale `pyvenv.cfg` `home`) | `status --scope scripta` from both, 2026-08-14 |
| The whole runtime works with NO Ollama | scratch registry, `OLLAMA_HOST=127.0.0.1:1`: compose all gates PASS; query returns passages declaring `embedder=lexical-only … DEGRADED`; `embed --model apple-nlcontextual` 26/26 in 1.0s, 2026-08-14 |
| `compose_failed` freezes a scope and `refreshed` clears it | `refresh-record` both ways on a scratch scope, 2026-08-15 |
| The loop composes the REGISTERED databases | all six db mtimes + `scopes.toml` `composed` at 01:20 UTC, 2026-08-15 |
| torch imports under hardened runtime; `ctypes` closures work | signed Distribution bundle, 3.1s, returns 42 — **no `allow-jit` entitlement needed**, 2026-08-14 |
| The Apple arms compile from committed source | `swiftc -O` each, ~1.4s, 2026-08-14 |
| Every field the reader sees is the engine's, with `degraded` and arm-promotion pinned as rules | `MappingParityTests`, mutation-verified (3 mutations → 1/2/6 assertions) |
| Nothing reads or writes `chunk_vectors` | `grep -rn` over `Sources Core/Sources`, 2026-08-11 |
| The whole RUNTIME path runs on a 22 MB venv (numpy only) | built one, ran `search` on live `scripta` (2 passages, `v10:b3d2d4d6d333`) and composed `demo-vault`, all gates PASS — 2026-08-12 |
| The deployed engine's venv is 1.2 GB, 508 MB of it `torch` | `du -sh ~/.substrate/engine/.venv`, 2026-08-12 |
| Every `docling` import is lazy (inside a function) | `cli.py:96`, `extract/convert.py:429-436`, `extract/docling_arm.py:24-26`, 2026-08-12 |
| ~~Nothing is bundled in the app today~~ | **SUPERSEDED 2026-08-15** by the row above — this was the state Doc 5 existed to change, kept because it dates when it was true |
| Reading works with the app CLOSED; only refresh is tied to it | quit the app, ran `status` on `prism` through `substrate-mcp` → 321 documents, 2026-08-12 |
| The engine dies with the app, no orphans | app running → 3 engine processes, quit → 0, relaunch → back on `:8765`, 2026-08-12 |
| No vault declares `guard_state` — the privacy wall is OFF | `grep -rln guard_state` over every manifest, 2026-08-12 |
| `substrate` is the only MCP server, and it answers | `claude mcp list` → `substrate ✔ connected`, 2026-08-15 — still pointing at `~/.local/bin/substrate-mcp`, NOT the bundled helper (open item 2) |
| The server ships `instructions` | real `initialize` handshake → 2093 chars present, 2026-08-12 |
| Stop keeps partial text and removes an empty placeholder | `AskConversationTests`, mutation-verified |
| Endpoint history is bounded, oldest-first, system + current turn kept | `ChatHistoryBudgetTests`, mutation-verified |
| The app builds after Phase 5 | `xcodebuild -project Scripta.xcodeproj -scheme Scripta build`, 2026-08-10 |
| The stored-passage spine survives JSON for EVERY value of all four axes | `AskConversationTests`, mutation-verified: nil→`unclassified` fails 3 of them, restored passes |
| Pre-merge `conversations.json` still decodes, `group` included | `testPreMergeConversationsStillDecode` |
| `Retriever.context` has zero callers | `grep -rn "Retriever.context" Sources Core`, 2026-08-10 |
| The `cbre` scope holds a real recorded call at tier 3 | `documents(scope: "cbre", include_sources: true)` → `call-2026-08-07-1021-30ea51de`, `conversation`, 2026-08-10 |
| Zero `DocumentImporter` references remain | `grep -rn DocumentImporter Sources Core`, 2026-08-10 |
| The migrated document is retrievable at tier 2 of `cbre` | `browse(vault: "cbre")` → one tier-2 row, 2026-08-10 |
| All six live scopes composed and none frozen | per-scope `status` after the first in-app loop pass, 2026-08-15 |
| The deployed engine is pinned at `67948ac`, 29 commits behind HEAD | `tools/substrate-deploy --show`, 2026-08-15 — and it is now DEVELOPER-ONLY: tier 2 is `#if DEBUG` and nothing runs its refresh agent |
| No Swift MCP server exists | `SourcesMCP/` is empty; only `MCPStateFile.swift` remains, feeding `guard_state` |
| The shipped default rerank stack has a measured number (0.708) | `test_the_shipped_default_stack_has_a_number` |

## Ready-to-paste next-session prompt

> Working on Scripta (branch `substrate-engine`, repo `~/CodeHome/CallTranscriber`; the engine is in
> `substrate/`). Read `substrate/PRINCIPLES.md` (four laws), then `substrate/SESSION-HANDOFF.md`.
> Doc 4 and Doc 5 are both CLOSED decision records — read them for why the code looks like this, not
> for what to do next.
>
> **Packaging shipped** (`5c9cfac`, `74f4aac`). The engine is built into
> `Scripta.app/Contents/Resources/substrate-engine` by a post-build phase on the `Scripta` target,
> and a relaunched app spawns it — `discover()` candidate 1 wins. Tiers 2 and 3 (`~/.substrate/engine`
> and `~/.local/bin`) are now `#if DEBUG`, so on this machine they still resolve and in a shipped
> build they do not.
>
> **First item: notarization. It is the only part of the plan with no evidence behind it**, and the
> only thing that could still invalidate bundling a 1.4 GB app with 366 nested binaries. It is
> blocked on one interactive command the OPERATOR must run:
> `xcrun notarytool store-credentials "notary" --apple-id <id> --team-id 6CTH5M9UWZ`. Ask before
> assuming it exists. Everything around it is verified — Developer ID on the app and every nested
> binary, hardened runtime, secure timestamps, seal valid. `Distribution/RELEASING.md` is the
> runbook; build `-configuration Distribution`, never `Release`.
>
> Read first: `substrate/tools/build-bundled-engine` (the whole file — it is the packaging), the
> `Scripta` target in `project.yml`, and `Sources/App/SubstrateEngine.swift` (`discover()`). Doc 2
> (the structural spec) lives in `~/OneDrive/vaults/core-vault/00-operator/specs/`; Doc 5 is
> `~/OneDrive/vaults/scripta-vault/03-references/doc5-packaging.md`.
>
> **Three states that look like faults and are not.** The branch is 86 commits ahead of
> `origin/substrate-engine` and unpushed — deliberate, do not push without being asked. The DEPLOYED
> engine at `~/.substrate/engine` is pinned 29 commits behind HEAD, which is now a developer
> artifact rather than a problem. And `refresh.frozen: false` on a stale index is honest: the loop
> only runs while the app is open, so nothing failed because nothing ran.
>
> **One real fault worth clearing early:** `~/.substrate/scopes.toml` holds two dead scopes
> (`cleantest`, `scripta-default`) pointing at deleted scratchpads. The refresh loop composes them
> every tick and correctly freezes them. Deleting those two `[scopes.*]` blocks is the fix; it was
> left because the registry is the operator's.
>
> Before changing anything: `cd substrate && ./lint.sh` (16 pre-existing errors, not yours),
> `uv run python tools/fixture-signature.py out/substrate.db` (must print `4a560ce34aa6378a`,
> 1811 chunks), `uv run pytest tests/ -q` (587), `cd Core && swift test` (247), and
> `xcodebuild -project Scripta.xcodeproj -scheme Scripta build` — the bare `-scheme` form still
> fails, two `.xcodeproj` in the root, and adding or deleting a file needs `xcodegen generate` first.
>
> Discipline is audit → review → implement → verify, `/crosscheck` then `/adversary`. Three rules
> this project earned the hard way: **a new test must be mutation-checked before you trust it**;
> **open the app after any change to a view** — a green build says nothing about layout or
> reachability; and **verify a reviewer's claim before applying it** — five of last session's
> findings were refuted with evidence, including two reviewers who contradicted each other.
