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
fixture. The operator's real vaults live outside the repo at `~/OneDrive/vaults/core-vault` and
`~/OneDrive/vaults/scripta-vault`, per Doc 2 §0: the engine has an opinion on shape, none on location. Point
`compose` at a path; it does not care which.

`WRITING.md` therefore exists in two places — here, and in the real core-vault — with no generation
step keeping them in sync. They are byte-identical today. **Edit the real one and copy it here**, or
they fork silently.

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

## The refresh agent runs a DEPLOYED engine, not this tree

`com.ronanwood.substrate-refresh` used to exec this working tree every 900 seconds, and on
2026-08-03 an uncommitted schema bump reached all six live scopes inside one tick. It now runs an
export of one commit at `~/.substrate/engine`, proven file-by-file before it composes anything.

**Editing this repo does not change what the refresh runs. Neither does committing.** Only
`tools/substrate-deploy` does — and the pin sitting behind HEAD is the normal state of a repo being
worked in, not a fault. When the deployment cannot be proven the agent refuses the whole tick and
records `engine_unverified` for every scope; `tools/substrate-deploy --show` says why.

Do not "simplify" this back into running `$REPO` directly. `tools/deployment.py` carries the
argument for the pin over the two cheaper guards (refuse-if-dirty, refuse-if-uncommitted) that were
considered and rejected.

## Discipline

`audit → review → implement → verify`. `/crosscheck` right after implementing (auto-applies what
clears its bar), `/adversary` as the last gate before presenting (report-only). Refuse rather than
mislead — the engine hard-fails on an incomplete/silently-narrowed state rather than returning a
plausible-but-wrong result. See `HANDOFF.md`, `PRINCIPLES.md`, `VAULT-SPIKE-READOUT.md`, and `docs/README.md` for where the structural spec lives (core-vault, not here).
