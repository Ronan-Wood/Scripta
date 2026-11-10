# substrate — project guidance

## Writing standard (load-bearing)

**Every note written into a vault, and every doc/finding written in this repo, follows
[`vaults/demo-core-vault/00-operator/WRITING.md`](vaults/demo-core-vault/00-operator/WRITING.md).**
Read it before authoring or editing vault notes. It is the authority on *how* content is written —
it makes the vault and the RAG over it consistent, predictable, and readable, which is fundamental
to Doc 2.

The vault content is the primary target of the standard, not just Claude Code sessions: notes are
mostly model-written, so the rules are enforced at write time.

**Where the vaults live.** The repo carries only the EXAMPLE pair — `vaults/demo-core-vault` (root)
and `vaults/demo-vault` (project) — synthetic content that doubles as the engine's regression
fixture. The operator's real vaults live outside the repo at `~/vaults/core-vault` and
`~/vaults/scripta-vault`, per Doc 2 §0: the engine has an opinion on shape, none on location. Point
`compose` at a path; it does not care which.

`WRITING.md` therefore exists in two places — here, and in the real core-vault — with no generation
step keeping them in sync. **Edit the real one and copy it here**, or they fork silently.

**They are forked right now, and deliberately.** As of 2026-08-03 the repo copy is AHEAD by the
digest-membership rule (membership is folder position, not `[[links]]`; a digest lives inside the
area it summarises), which also corrects a placement line that had been prescribing the flat
`02-areas/<area>-digest.md` shape — the shape `substrate digests` now reports UNMEASURABLE. The real
core-vault was not touched because a session does not write the operator's vault. Copy this file to
`~/vaults/core-vault/00-operator/WRITING.md` to close the fork; until then the standard the
vaults are actually authored against still names the old shape.

Non-negotiables from that file:
- **Lead with the conclusion; no preamble/postamble.**
- **Structure over prose** for anything enumerable (decisions, tradeoffs, options → tables/lists).
- **Preserve decision history and confidence markers; attach conditions to every number.**
- **One note, one job** — declare a `doc_type` (the vocabulary is `spine.DOC_TYPES`: decision /
  explanation / reference / how-to / digest); if a
  note does two jobs, split it.
- **Glossary:** one word per concept (passage, supersede, vault, tier, engine, retrieval, ingest,
  manifest, domain, capability). **Reserved:** `status` = the note lifecycle only
  (active / complete / archived / superseded); the retrieval-stack state is `capability`.

## Refresh belongs to the engine (`substrate serve`) — there is no launchd agent

**`com.ronanwood.substrate-refresh` was retired 2026-08-12.** No plist is installed and
`launchctl list` shows nothing. This section described it in the present tense for five days after
it was removed, and on 2026-08-17 a session asserted "the deployed-engine agent under launchd runs
today" straight out of this file — having verified the retirement itself hours earlier. **A stale
`CLAUDE.md` is worse than a stale doc: it is loaded into every session before anyone looks at the
machine.**

What refreshes, as of PR C2 (2026-11-06):

- `substrate serve` is the shared socket server plus a refresh loop (`substrate/refresh.py`). It
  runs a pass at bind and every `--every` seconds after, with or without a host app. `substrate
  refresh` runs one pass now; Scripta's "Refresh now" runs it. Its models and period come from
  `~/.substrate/serve.toml` (`hyde_model`, `rerank_model`, `every`) where no flag sets them, read
  once at start (`serve_config.py`). The operator edits it by hand; Scripta never writes it. It has
  no embedder key, by design: `serve --embed-model` moves only the query side, and search then
  matches no vectors.
- **Scripta spawns `substrate serve`** (`SubstrateEngine`), and schedules nothing itself. Its engine
  still dies with it. An engine already answering on the socket is USED when it is read-only,
  refreshing, not agent mode, indexing Scripta's note format, and on Scripta's registry
  (`EngineAttach`); Scripta never stops it, and starts its own if it goes away. Anything else is
  reported. Attached, Scripta writes notes and runs `substrate register` for a new scope, and the
  engine indexes: "Refresh now" sends that engine's `refresh` tool, and its pass composes a pending
  scope and prunes a deleted note's ingest folder.
- `compose` and `embed` take `vaults.lock` (an `flock` beside the registry), whoever runs them:
  the loop, Scripta's Library and recording paths, a terminal, `tools/substrate-deploy`. A caller
  waits up to 60 s, then exits 75 having written nothing; Scripta reads 75 as declined.
- `tools/substrate-refresh` and `~/.substrate/refresh.lock` are gone.

**The consequence to know:** with Scripta's own engine, vaults refresh only while Scripta runs,
because its engine dies with it. Run `substrate serve` yourself to keep them refreshing without it;
Scripta attaches to that engine when it opens.

### The deployment pin still matters, for a different reason

`~/.substrate/engine` is still a real thing: `discover()` tier 2. It is now DEBUG-only (Doc 5), so
a shipped app never reaches it, but a developer build does.

**Editing this repo does not change what that engine serves. Neither does committing.** Only
`tools/substrate-deploy` does — and the pin sitting behind HEAD is the normal state of a repo being
worked in, not a fault. `tools/substrate-deploy --show` says how far behind it is.

The reason for a pinned export rather than running `$REPO` is worth keeping even though the agent
is gone: on 2026-08-03 an uncommitted schema bump reached all six live scopes inside one tick.

Do not "simplify" this back into running `$REPO` directly. `tools/deployment.py` carries the
argument for the pin over the two cheaper guards (refuse-if-dirty, refuse-if-uncommitted) that were
considered and rejected.

## Discipline

`audit → review → implement → verify`. `/crosscheck` right after implementing (auto-applies what
clears its bar), `/adversary` as the last gate before presenting (report-only). Refuse rather than
mislead — the engine hard-fails on an incomplete/silently-narrowed state rather than returning a
plausible-but-wrong result. See `HANDOFF.md`, `PRINCIPLES.md`, `VAULT-SPIKE-READOUT.md`, and `docs/README.md` for where the structural spec lives (core-vault, not here).
