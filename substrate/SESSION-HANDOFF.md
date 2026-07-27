# Session handoff — the MCP server is built; it has never run against real content

Written 2026-07-27. Branch `substrate-engine`, work in `substrate/`. Read `PRINCIPLES.md` first
(three laws, plus two failure patterns this session added), then this. `PILOT-READOUT.md` has the
real-content pilot and migration findings; `HANDOFF.md` has the engine's history.

## Bottom line

**Doc 3a phase 1 is built and reviewed.** Five MCP tools over the engine, a scope registry, one
payload-shaping function both adapters render from, drift detection, and a two-phase write gate.
309 assertions green, schema still **v6**, eval signature `4a4f765c9ad75dc9` untouched — nothing
in this work opens `out/substrate.db`.

**It has never been pointed at the real vaults, and the measured stack has never executed.** Ollama
was down for the whole session, so every capability envelope produced so far reads lexical-only.
That is the contract working, not a fault — but the 0.698 path is covered by construction, not by
observation. See *Do this first*.

## Do this first

Per project scope (six of them: prism · scripta · cbre · research · school · clovis):

```
substrate compose ~/OneDrive/vaults/<x>-vault --clean \
  --index-root out-vault/<x>-index --db out-vault/<x>.db     # also REGISTERS the scope
substrate embed --db out-vault/<x>.db                        # serial, weights on ExtremeSSD
```

Compose now writes `~/.substrate/scopes.toml`, which is how a scope name resolves to an index.
Nothing is registered yet — the registry did not exist when those seven vaults were composed.
Until `embed` runs, every search honestly reports `expected_mrr: null` and names the missing
vectors; core-vault notes repeat across scopes and the vector cache is content-addressed, so the
unique embedding work is far less than 6 × the chunk count.

Then verify with `substrate status --scope prism` — it reports counts, vector completeness, and
whether the vault has changed since the index was built.

## What the MCP surface is

One server, `substrate-mcp`, stdio JSON-RPC 2.0, stdlib only. **Scope is a parameter**, not server
config: one server serves every composed scope and the caller names the one it wants.

| tool | does | refuses |
|---|---|---|
| `search` | snippet-first passages + outline records + capability + filters + `index_version` | unknown scope · empty index · `doc_type` (engine gap, see below) · non-integer `k` |
| `expand` | full passage, or the whole note (`mode=note`) with a staleness verdict | malformed/unknown ref |
| `list_scopes` | every registered scope and the vault chain its manifest resolves to | — (a broken scope is listed WITH its fault) |
| `status` | counts by vault/tier/status/doc_type/confidence, vector coverage, drift | — (this is the tool that reports rather than refuses) |
| `ingest` | two-phase plan → confirm write of a new markdown note | PDFs · core-vault · overwrites · paths outside the project vault · unissued tokens |

**Not wired into any client.** I did not touch `~/.claude.json` or Zed config. Launch is
`python -m substrate.mcp.server` with `SUBSTRATE_REGISTRY` set, or `--registry`. Doc 3a §4's own
judgement stands: for Claude Code specifically, skill+CLI is the better fit (~20 tokens until
invoked); MCP earns its place on surfaces with no shell.

## The property that was the point

Every passage carries `status` / `doc_type` / `confidence` / `domains` / `vault` / `citation` /
`supersedes`, unconditionally — `unstated`, `null` and `[]` emitted like any other value. Every
response carries the capability envelope, the filters that were applied (including what was
EXCLUDED), and `index_version`. `substrate query --json` and an MCP `search` emit the same
envelope, compared as whole dicts in `tests/test_mcp_server.py`.

Where the engine cannot honour something, the tool refuses rather than pretending: `doc_type`
filtering is in Doc 2 §6a as a shipped axis with the filter deferred, so `search` refuses that
argument instead of returning unfiltered results under a filtered label.

## New engine modules (all consumed by BOTH adapters)

| module | job |
|---|---|
| `scopes.py` | scope name → (vault, composed index). Written by `compose`, so a listed scope always has an index behind it |
| `render.py` | the result payload. Snippet-first, `expand_ref`, capability, applied filters |
| `stack.py` | wires embedder/HyDE/reranker once, so the two adapters cannot drift |
| `freshness.py` | vault-vs-index drift, honest about what it cannot check |
| `introspect.py` | the `status` / `list_scopes` payloads |
| `notes.py` | the vault write path: plan, unforgeable token, `O_EXCL\|O_NOFOLLOW` |

## Two failure patterns this session earned

Both were found by review, not by testing. **Neither has been promoted into `PRINCIPLES.md` yet** —
that file is byte-identical to the `boundary-principle` note in core-vault, so promoting them is a
deliberate two-place edit (edit the vault copy, then copy it here). Recorded here until then.

**A docstring asserting a property nobody implemented.** Four times: "a caller that never received
a plan cannot produce a token" (the token was a derivable digest); "ONE definition both adapters
call" (only one called it); "the same envelope the MCP server returns" (each adapter bolted on its
own field); "same envelope … so a consumer never has to reconcile two passage shapes" (two key
sets). In every case the prose was written last and nothing checked it against the code. **A
docstring is a claim, and an unchecked claim is worse than silence — the next reader trusts it
instead of looking.**

**A test comparing a named subset rather than the whole object.** The §6 equivalence test asserted
five keys and passed while both adapters emitted structurally different envelopes; it also ran both
sides lexical-only, so it compared two identically-empty stacks and could not see the divergence it
existed to catch. Proven, not assumed: reinstating the old hand-wired CLI branch leaves that test
green. **Assert the whole object, and assert agreement rather than a value** — the second is what
makes a test independent of whether a daemon happens to be running.

## Assertions

A1/A1b (PDF path only) · A12 · A13 · A14 · A17 · A18 loss gate · A19 per-doc spine · **A20** status
partition · **A21** doc_type · **A22** per-note sweep at compose · **A23** confidence · A-compose.
A22 splits fatal from reported, defaulting to FATAL.

New guards this session, all mutation-verified:

- **vector coverage** — a wired embedder over an index with no (or partial, or zero-chunk) vectors
  degrades honestly instead of stamping a measured tier on a lexical-only run. This was live: all
  seven composed indexes are 0-vector, so the measured stack would have reported 0.698 on every
  query. PRINCIPLES.md incident #2, reproduced at the new boundary.
- **read opens do not migrate** — `schema.migrate` is drop-and-rebuild, so a read-only tool used to
  destroy an old-schema index by opening it and then truthfully report it empty.
- **empty-index refusal** keyed on emptiness, not the one-shot `rebuilt` flag.

## Open, in the order I would take them

1. **Run it.** Compose + embed the six scopes, wire one client, use it for a week. Everything below
   is speculation until the surface has met real content.
2. **Doc 2's text is behind its own implementation.** §6 documents `status` and stops; `doc_type`,
   `confidence` and the conversation class appear nowhere in the body. Doc 3a is now also behind:
   it describes a `doc_type` filter that refuses, and folds archived into `include_sources` where
   the engine deliberately keeps two axes.
3. **`reference_pins` is the last unimplemented §2 feature.** Prerequisite unchanged: only one
   versioned source exists, so there is nothing to pin against.
4. **The cutover.** `~/.claude/CLAUDE.md` still points every session at ClaudeVault, so the migrated
   vaults are read by nothing while ClaudeVault accrues. The MCP unblocks this; (1) is the gate.
5. **Deferred, with reasons:** don't-embed-superseded (cost, not correctness); domain
   soft-weighting (eval-gated, needs cross-domain gold cases); the index watcher; the weekly lint.
6. **Housekeeping:** `cmd_eval` keeps two hand-rolled copies of the vector guard that
   `IndexStore.vector_coverage` now supersedes — deliberately untouched, it guards the number that
   must not move. The A21/A23 "duplication" is **closed as won't-fix, and the earlier reason for
   that was wrong**: it is not that the two are merely parallel, it is that the duplication is
   THREE-way — `assert_status_partition`'s first two checks are the same unknown-value-then-drift
   scan — so collapsing A21 into A23 would leave the third copy and make the family less uniform
   than it is now. Either unify all three behind one `_assert_axis_valid(column, vocabulary, error,
   …)` or leave them; a two-way merge is the one move that makes things worse. Evidence the
   duplication does cost something: the `NULL NOT IN (...)` subtlety was corrected in A21's
   docstring and independently re-derived in A23's.

   Done: `introspect._group`, three `IndexStore` count methods and a fifth copy in
   `vault.assert_composed` now share `IndexStore.counts_by` — keys stay native, so `compose` and
   `status` finally print `by tier` the same way and the JSON payload is unchanged;
   `has_vectors` deleted; `document_checks` moved to `substrate/checks.py`.

   Two user-visible changes rode along and are NOT housekeeping, so they are named here rather
   than left to a bisect: `substrate status`'s human read-out now prints `by doc_type` (the
   payload always carried it; only the rendering dropped it), and the §6 equivalence test's
   liveness guard admits a third capability state — a reachable, wired embedder that the
   vector-coverage guard degrades over a vectorless index. That test could only ever pass with
   the daemon DOWN; it went red the moment Ollama came up.

## Constraints that bite

- **EVAL MUST NOT MOVE** — `4a4f765c9ad75dc9`, 1811 chunks, complete vectors under
  `qwen3-embedding:0.6b#raw`. Open `out/substrate.db` read-only with `sqlite3` and a `mode=ro` URI,
  NEVER through engine code.
- Schema is **v6**, drop-and-rebuild. Read paths now refuse a version mismatch rather than
  rebuilding; only `compose`/`index` migrate.
- **14 pre-existing lint errors** at HEAD. Not mine, not to be fixed opportunistically.
- Serial model work only; weights on `/Volumes/ExtremeSSD`.
- Discipline: audit → review → implement → verify. `/crosscheck` after implementing (auto-applies
  what clears its bar), `/adversary` last before presenting (report-only). **Refuse rather than
  mislead.**
- **Do not `git add -A` over the tree.** Stage explicit paths.
- **`~/vaults/ClaudeVault/` is untouched and still live.**

## What this session shipped

Fourteen commits on `substrate-engine`, nothing pushed: the vector-coverage guard; the scope
registry; the render layer; `search` + `expand`; `list_scopes` + `status`; `ingest`; then seven
commits of review findings — one crosscheck pass (3 reviewers, found the write gate was not a gate)
and one adversary pass (2 reviewers, diff-only, 31 findings, all closed) — and this handoff.

Three of the adversary's shared claims were **verified false** rather than relayed: `embed` does
cover outline chunks, `_read_manifest` already refuses a missing `name`, and `store_vectors`
exists. Checking is cheap; passing on a wrong finding is not.
