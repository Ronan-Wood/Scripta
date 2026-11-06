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

What refreshes, as of PR C1 (2026-11-05):

- `substrate serve` is the shared socket server plus a refresh loop (`substrate/refresh.py`). It
  runs a pass at bind and every `--every` seconds after, with no host app. `substrate refresh` runs
  one pass now.
- `compose` and `embed` take `vaults.lock` (an `flock` beside the registry), whoever runs them.
  Interactive callers wait up to 60 s, then exit 75 having written nothing. The loop's compose
  declines at once and records nothing.
- **Scripta still drives its own loop** (`SubstrateRefresh`) and still spawns `substrate-mcp
  --socket`, which refreshes nothing, until PR C2 moves it onto `substrate serve`. Its composes now
  wait on the lock like any caller. One that loses the 60 s wait exits 75 and the app reads that as
  declined (`ComposeOutcome.declined`), recording nothing. An embed that loses it is still recorded
  `embed_failed`, which is true: that scope is unvectored until the next pass.
- `~/.substrate/refresh.lock` is still taken by `tools/substrate-deploy` and the retired
  `tools/substrate-refresh`. It guards against nothing until C2 moves the deploy onto
  `vaults.lock`.

**The consequence to know, until C2 lands:** with only Scripta running, vaults refresh only while
the app is open. A week without it means a week-old index, and `refresh.frozen` reads `false`,
because nothing failed; nothing ran. Run `substrate serve` to have them refresh without it.

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
