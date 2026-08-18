# Open issues — the note/Add-page work

Written 2026-08-18. Covers commits `4ea07b0..5205adc` on `substrate-engine` (6 commits,
unpushed, working tree clean). Everything below is either **verified** by running something,
or marked **claimed** where it came from a reviewer and was not confirmed.

Two review passes ran over this work: `/crosscheck` (3 reviewers, findings applied) and
`/adversary` (2 reviewers, diff-only, report-only — **nothing from it has been applied**).
This document is mostly the adversary output plus what I found verifying it.

---

## Read this first: what the work is

The app could not write a note. A hand-written Markdown note is refused at compose twice —
`SpineError: no status`, then `no doc_type` — because the engine will not default a note into
the live retrieval set, and nothing in the app named either field. Measured against a blank
vault 2026-08-17.

So: `NoteWriter` (Core) writes notes with the spine; `NoteSpine` declares the vocabulary
checked against `spine.py` at test time; the Add page was restructured around a kind chooser
(document / call transcript / note); notes can be written to a **shared vault** (core-vault)
which recomposes every inheriting scope; `embed` now runs inside `composeVault`; a new
workspace whose name collides with a composed scope stops and offers to connect.

Verification state: **276 Swift tests**, **589 engine tests**, lint 16 (pre-existing),
fixture `4a560ce34aa6378a` / 1811 chunks, all six live scopes fully vectored, app builds
and launches.

---

## 1. BLOCKER — `remove(source:)` can unlink a recorded call

`Sources/App/SubstrateLibraryModel.swift:644`

Fixing "orphan recovery cannot reach uploaded transcripts", the delete guard was widened from
`vault.references` to **both** promotion directories. The second is `_sources/transcripts/`,
which is where **capture writes recorded calls**.

The guard checks only the parent directory and never the target's shape, so
`_sources/transcripts/Call — 2026-08-07 1021.md` passes it and reaches `removeItem` —
permanent unlink, no trash, on what this codebase elsewhere calls *"the artefact that cannot
be recreated"*.

**Verified:** the guard is parent-only (read at :644-650). Both adversary reviewers flagged it
independently.

**Not reachable today**, which is why it is a latent risk rather than an active bug: the two
callers are the browser (gated by `isRemovable`, tier 2 only) and the orphan row (passes a
promoted source directory). But that guard exists *as* defence-in-depth — its own comment says
"a wrong URL deletes their work."

**Do not fix by reverting.** Reverting re-breaks orphan recovery for uploaded transcripts,
which was a real crosscheck finding. Narrow it instead: require the target to be a **directory**
whose name matches the promoted shape `<slug>-<8 hex>`. That is exactly what `promote` creates
and excludes everything capture writes.

### 1a. The related claim about `staleSources` is FALSE — do not act on it

Both adversary reviewers also claimed `staleSources` (`Sources/App/SubstrateLibraryVault.swift`)
can delete recorded calls now that it sweeps both directories. **It cannot.** Verified:

```
'Quarterly sync — 2026-08-17 1150.md'.endswith('-a1b2c3d4')  ->  False
'quarterly-sync-a1b2c3d4'.endswith('-a1b2c3d4')              ->  True
```

Recorded calls are `.md` files, so `lastPathComponent` always ends in `.md` and can never match
the `-<digest>` suffix. Promoted directories have no extension and do match. The sweep is
correctly targeted; leave it alone.

---

## 2. HIGH — the H1 is unescaped while the frontmatter is not

`Core/Sources/ScriptaCore/NoteWriter.swift:194`

`yaml(title)` sanitises the frontmatter value (control bytes → space, `"` → `'`) but the body
is emitted as `# \(title)` from the **raw** title. Verified by running the two paths:

```
title: "Real title doc_id: forged status: archived"    <- frontmatter, sanitised
# Real title                                            <- body, RAW
doc_id: forged
status: archived
```

Two consequences:

- The invariant the file is built around — *"the heading and the `title:` are the same value"* —
  is false for any title containing a quote or a control byte.
- A pasted multi-line title puts its tail in the note **body** as prose. Not a frontmatter
  injection (the block is intact), but it is content the operator did not intend to write.

**My tests enshrined this.** `testAQuotedTitleSurvivesTheReadersRatherThanBeingEscaped` asserts
the frontmatter reads `He said 'no' twice` **and** the H1 reads `# He said "no" twice` — it
encodes the divergence as correct. `testANewlineInATitleCannotForgeAFrontmatterKey` checks only
the frontmatter, so the body leak passes.

Fix: sanitise once, use the same value in both places. Then correct both tests — they will fail,
and they should.

---

## 3. HIGH — 48-character truncation collides distinct titles

`Core/Sources/ScriptaCore/ScriptaVault.swift:637` (`slug(_:limit:)` truncates at 48)

Two different titles sharing a 48-character slug prefix produce one filename. The second is
refused with *"This vault already has a note called <truncated>.md — open that note and edit
it"*, naming a note the operator never wrote.

The refuse-rather-than-uniquify decision (`NoteWriter.swift`, `write`'s doc comment) is argued
entirely on the same-title case and never considers truncation. Both behaviours are defensible;
the message is not, because it asserts sameness that is not there.

**Claimed by a reviewer, mechanism verified** (the truncation is real and documented in
`ScriptaVaultTests.swift`). Not reproduced end to end.

---

## 4. MEDIUM — `embed` holds the compose lock

`Sources/App/SubstrateLibraryModel.swift:1071-1075`

The embed subprocess is awaited inside `composeVault`, before `defer { composeInFlight = false }`
releases it. So every other compose — a recording's, a refresh tick's — is **declined** for the
embed's duration.

Both adversary reviewers flagged it. Mitigating measurements, both taken 2026-08-18:

- no-op embed on a fully vectored scope: **0.175 s** (`index already fully embedded`)
- embed with the model unreachable: **0.38 s**, fails fast

So the realistic cost is small, and a declined compose is handled (`SubstrateRefresh` skips and
records nothing). But a large first embed of a big scope would hold the lock for as long as it
takes, and a hung embedder would hold it indefinitely.

---

## 5. MEDIUM — two of three callers discard the embed result

`ComposeOutcome.embed` is only turned into a `Step` by the two note paths. `performAdd`
(`:509`) and `SubstrateRefresh.swift:175` take `.run` and drop `.embed` on the floor.

The comment at `:1066` says the embed is *"non-fatal … this reports"*. For a document add, a
transcript upload, or any refresh tick, it reports nothing — a failing embedder is silent and
every step shows green while the passages are lexical-only. **That is the exact failure moving
the embed into `composeVault` was meant to end**, still live on two paths.

Related: `ComposeOutcome.database` (`:1018`) is now **written and never read** — it was the fix
for a stale-roster lookup that no longer happens. Delete it or use it.

---

## 6. MEDIUM — `createNote` regenerates the manifest and can strip hand-added `inherits`

`Sources/App/SubstrateLibraryModel.swift`, `createNote` calls
`ScriptaVault.vault(forScope:under:inherits:)` + `write()` with `inherits` from the app's
binding. `ScriptaVault.write()` early-returns only when `inherits.isEmpty`, so a non-empty
binding **rewrites the manifest**, dropping any `inherits` entry the operator added by hand.

Self-contradicting: `SettingsView.sharedVaultStatus` tells the operator to *"Add it to a vault's
`inherits` and compose that scope"* when nothing inherits the shared vault. Writing a note then
destroys that edit.

**Claimed, mechanism verified** by reading `write()`'s early-return condition. Not reproduced.

---

## 7. MEDIUM — the shared vault is matched by bare directory name

`Sources/App/SubstrateLibraryModel.swift:787` and `Sources/Settings/SettingsView.swift:858`

Both identify the shared vault by `lastPathComponent` and test `row.sources?.contains(name)`.

**This machine has more than one directory named `core-vault`** — the live one under
`OneDrive-Personal/vaults/` and stale duplicates in the iCloud Obsidian tree (documented in the
user's global CLAUDE.md). So the match can bind to the wrong one: the job card reports success
for scopes the note is not in, and Settings asserts an inheritance that does not exist.

Fix: match on the resolved path, not the basename.

---

## 8. MEDIUM — Settings' inheritance line never updates

`Sources/Settings/SettingsView.swift:858`

`sharedVaultStatus` reads `SubstrateScopes.shared.rows` from a computed property, but
`SettingsView` does not observe `SubstrateScopes`. Nothing invalidates the body when the roster
arrives, so the deliberately-silent "roster not listed yet" state becomes **permanently** silent
for anyone who opens Settings before the engine finishes listing.

---

## 9. MEDIUM — New note is offered when the browser shows another vault

`Sources/App/VaultBrowseView.swift:163`

The affordance is gated on `model.scopeOverride == nil`, but the browsed scope is
`scopeOverride ?? WorkspaceBindings.active.readsScope` — and `readsScope` is a stored binding
Ask's picker can point anywhere. With no override but a rebind made in Ask, Create writes into
the workspace's own vault while the list shows a different one. That is precisely what the
`newNote: nil` guard's comment claims to prevent.

Fix: gate on the browsed scope actually being the workspace's own.

---

## 10. LOW — smaller, all in-scope

| where | issue |
|---|---|
|  `NoteWriter.swift:220` | `asciiValue.map { $0 < 0x20 }` misses **U+007F** and the **C1 range** (U+0080–U+009F). The comment claims "control bytes to spaces". |
| `NoteWriter.swift` `yaml()` | Backslashes are not escaped inside a double-quoted scalar. Fine for the two in-house line parsers; **these files land in Obsidian vaults**, and a spec YAML reader rejects `title: "C:\path\"`. |
| `NoteWriter.swift:190` | Slugged domains are not deduped — `R&D, R D` writes `domains: [r-d, r-d]`. |
| `SubstrateLibraryView.swift:167` | `case .noCLI(let engine)` binds a payload the rewritten message no longer uses — a warning, and a failure under `-warnings-as-errors`. |
| `ScriptaVault.swift` `conflictingScope` | Compares `standardizedFileURL`, which does **not** resolve symlinks, while the engine's registry paths come from Python's `Path.resolve()`, which does. On a symlinked output folder a workspace's own vault could be reported as a conflict. |
| `SubstrateLibraryView.swift` `LibraryScopeLine` | The `expanded` flag is per-view-position `@State` over a re-fetched roster, so a membership change can leave "Why" open on a different scope. |
| `AppModel.swift` / `SubstrateLibraryVault.swift` | New declarations were inserted **between** a doc comment and the function it documents, so `vaultAlreadyNamed` now carries `createWorkspace`'s rationale and `PromotionTier` carries `promote`'s `- Parameter tier:` line. |
| `HubView.swift`, `SettingsView.swift` | Two more copies of home-directory abbreviation, both using `replacingOccurrences` (mangles a path embedding the home string mid-way) instead of the prefix-anchored `SubstrateCLI.abbreviated`. |
| `NoteWriterTests.swift` `engineSource` | Every `spine.py` parity gate degrades to `XCTSkip` when the Python tree is absent — silently a no-op in any checkout that does not vendor it. |

---

## 11. Dismissed — verified NOT bugs, do not re-open

- **`createNote` with an empty workspace writing into the output folder root.** Claimed by a
  reviewer. `ScriptaVault.vault(forScope:)` throws `unnameableScope` on an empty name
  (`ScriptaVault.swift:63`), so the destructive path is unreachable.
- **`staleSources` deleting recorded calls.** See §1a — structurally impossible.

---

## 12. Known gaps deliberately left open

- **An uploaded transcript cannot be removed from the browser.** `isRemovable` is tier 2 only.
  Widening it to tier 3 was tried and **reverted**: `_tier_for` puts `02-areas` *and*
  `_sources/transcripts` both at tier 3, so it drew a delete control on every hand-written note
  and recorded call, with `remove(source:)` then refusing for the notes. Telling an uploaded
  transcript from a recorded call needs the source path, which `VaultDocument` deliberately does
  not carry. `remove(source:)` does accept it, so orphan recovery works; only the affordance is
  missing.
- **Document → shared vault is not wired.** The Add page states the destination rather than
  offering it. This is the in-app "textbook into core-vault" path. `promote` takes a whole
  `ScriptaVault`; doing this needs a destination vault threaded through the extraction path,
  and care not to stamp the app's ownership key on core-vault.
- **No way to retire a note.** Superseding is a **three-field** edit and `ingest` can do only
  one of them:

  | field | where | can `ingest` do it? |
  |---|---|---|
  | `supersedes: [old-id]` | the new note | yes |
  | `status: superseded` | the old note | no |
  | `superseded_by: <new-id>` | the old note | no |

  Measured: doing only the part `ingest` can do leaves **both notes answering** with
  `A20 status PASS`. Doing half the manual edit (`status` without `superseded_by`) **refuses the
  whole scope**. Both parts done → `included 2 · excluded 2`, correct. `notes.py:141` refuses an
  existing target and there is no CLI verb, so this is Obsidian-only today.

---

## 13. Out of scope but serious — "Create separately" is wrong about what it does

`Sources/App/HubView.swift`, the workspace-collision alert.

The message says the two vaults *"share a name without sharing anything else"*. A reviewer
traced that `composeVault` resolves the database via `registeredDatabase(named:)`, keyed on
**scope name only** — so a workspace named "School" created beside a registered curated `school`
composes as scope `school`, is handed the curated vault's database, and `--clean` paths wipe the
index root and rebuild it from the new vault's notes.

The db-selection predates this work, but **the new alert is what presents this as a supported,
explained choice**, and the explanation is wrong.

**Claimed, not reproduced.** Worth reproducing against a copy of the registry before acting —
the same technique used earlier in the session (copy `~/.substrate/scopes.toml` to a scratch
path, point `SUBSTRATE_REGISTRY` at it) makes this safe to test.

---

## 14. Live-system state a next session should know

- **All six scopes fully vectored** as of 2026-08-18: prism 6899, scripta 1172, cbre 1381,
  research 2387, school 3918, clovis 606.
- **School was repointed by hand this session.** `school` now resolves to
  `OneDrive-Personal/Scripta/school` (the app vault) which inherits `vaults/school-vault`. This
  matches the working `cbre` shape. Backups of the registry, the manifest and the 26 MB database
  are in the session scratchpad under `school-fix-backup/`.
- **Two dead scopes were purged** from `~/.substrate/scopes.toml` (`cleantest`,
  `scripta-default`) — both pointed at deleted scratchpad directories, verified gone before
  removal.
- **The external SSD holding the Ollama models fails intermittently.** It dropped twice on
  2026-08-17/18 (`fts_read: Input/output error`, `OLLAMA_MODELS=/Volumes/ExtremeSSD/ollama-models`).
  It is currently connected and all 16 models resolve. While it is down, `embed` refuses in
  0.38 s **before consulting the vector cache**, so a `--clean` compose during an outage would
  drop vectors that cannot be restored. The 194 MB cache itself is on the internal disk and is
  content-addressed, so it survives.
- **`SubstrateRefresh` never embedded** before this session; that is why `cbre` was found
  serving 1341/1381. Fixed by moving the embed into `composeVault` — but see §5, two callers
  still discard the result.

---

## 15. Failure patterns this session earned

Worth reading before trusting anything above.

1. **The strongest counter-argument was already in the codebase, three times.** The
   frontmatter escaping had **three** correct implementations (`TranscriptWriter.sanitizeScalar`,
   `SubstrateLibraryVault.scalar`, `ScriptaVault.tomlString`) and a fourth was written that
   diverged. Search for an existing helper before writing one.
2. **A test can pass for the wrong reason.** The write-race test placed a real file, which the
   `fileExists` pre-check caught before the write — so the test never reached the code it named,
   and restoring the bug failed nothing. Mutation-checking is what caught it. A dangling symlink
   passes `fileExists` and fails `O_EXCL`, which is the only deterministic way in.
3. **A fixture that cannot reach the state.** Happened twice: the byte-identity test (the helper
   interpolates the filename, so two names can never produce identical bytes) and the race test
   above.
4. **Verification can be wrong.** `strings` on `Scripta.app/Contents/MacOS/Scripta` found
   nothing because the code lives in `Scripta.debug.dylib`; a "the changes did not ship"
   conclusion was drawn and was false. Validate a check against a known-present control before
   trusting a negative.
5. **A guard widened to fix one thing can sanction another.** §1 and the reverted tier-3
   affordance in §12 are both this shape.
6. **A comment goes stale the moment the code moves.** Two comments in this session asserted the
   opposite of the code within an hour of being written (`"Nothing below this rail moved"`,
   and one naming `listMaxWidth` after the code moved to `formMaxWidth`).
7. **Do not take a reviewer at face value.** Of the adversary findings, one was structurally
   impossible (§1a) and one was already guarded (§11). Both were flagged confidently.

---

## 16. Suggested order

1. §1 — narrow `remove(source:)` to `<slug>-<8 hex>` **directories**. Do not revert; do not
   touch `staleSources`.
2. §2 — one sanitised title for both frontmatter and H1, then fix the two tests that encode the
   divergence.
3. §5 — make `performAdd` and `SubstrateRefresh` surface the embed result; delete or use
   `ComposeOutcome.database`.
4. §3, §6, §7, §8, §9 — in any order.
5. §13 — reproduce against a copied registry before deciding.
6. §10 — sweep the low items together.

Everything in §1–§10 is **unfixed**. Nothing from the adversary pass has been applied.
