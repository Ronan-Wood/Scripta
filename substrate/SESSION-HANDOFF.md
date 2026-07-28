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

## Deployed, 2026-07-27 — where the moving parts live

All six scopes are composed, embedded (vector-complete) and registered. None of the following is
in this repo, so it is written down here or it is lost:

| what | where |
|---|---|
| CLI wrapper | `~/.local/bin/substrate` — cds into this repo, `uv run python -m substrate.cli` |
| MCP wrapper | `~/.local/bin/substrate-mcp` — `--quiet` so nothing but JSON-RPC reaches stdout |
| MCP registration | `~/.claude.json` user scope, added via `claude mcp add -s user` |
| Claude Code skill | `~/.claude/skills/substrate/SKILL.md` — the read path, ~20 tokens idle |
| refresh job | `~/.local/bin/substrate-refresh` + `~/Library/LaunchAgents/com.ronanwood.substrate-refresh.plist`, 15-min |
| refresh log | `~/Library/Logs/substrate-refresh.log` (quiet unless something changed or failed) |
| scope registry | `~/.substrate/scopes.toml`, written by `compose` |
| refresh record | `~/.substrate/refresh.json`, written by `substrate refresh-record` (the agent calls it) |

The refresh job checks Ollama FIRST and skips the whole run if it is down. That ordering is
load-bearing: `compose --clean` drops an index and rebuilds it with no vectors, and `embed` puts
them back, so a run that composed and then could not embed would leave a working scope 0-vector.
It also checks drift per scope, so an unchanged vault is never torn down. A quiet tick is ~2.5s.

**Ollama is the unowned dependency.** It is CLI-only here — no brew service, no LaunchAgent, no
Ollama.app — so nothing restarts it at login. Without it the refresh job skips every tick and
every query runs lexical-only, which the capability envelope reports honestly but which is the
0.343 tier. `brew services start ollama` would fix it, but its launchd context will NOT inherit
`OLLAMA_MODELS=/Volumes/ExtremeSSD/ollama-models`, and the weights are on that external volume —
so it needs an explicit `EnvironmentVariables` block, and it is still wrong whenever the SSD is
unmounted. Not done; decide deliberately.

**The retrieval quality on this corpus is measured now**, and it is not 0.698 — see
`eval/gold-vault.json`. Lexical 20/21 (MRR 0.63), paraphrase 9/13 (MRR 0.35). Different cohorts
from the 44-case reference-book tier; not subtractable.

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

## The freeze signal (2026-07-28) — and the producer that lives outside this repo

Every result envelope now carries `refresh`: what the unattended agent last managed on that scope.
`index_version` says what the index was BUILT from and stops there, so a scope whose recompose
refused kept answering from the superseded index in an envelope byte-identical to a healthy run —
`compose` returns before it opens the database, so the old index simply stays. PRINCIPLES.md
predicted this before the agent existed; the agent then made it worse by converting freshness a
human checked into freshness a human assumes.

`refresh_state.py` holds the record and the outcome vocabulary. `render.search_payload` and
`introspect.status_payload` both READ it — not passed in by either adapter, because an adapter that
has to remember to attach it is one that eventually will not. `frozen` is tri-state: `true`
(a recompose refused, results are superseded), `false` (the last pass left index and vault in
agreement), `null` (no basis — nothing recorded, or the tick checked nothing). A freeze is STICKY:
carried across any outcome that cannot disprove it, cleared only by one that can.

**No clock reaches the envelope**, deliberately. Doc 3a §6 compares the two adapters' envelopes as
whole dicts across two processes; a derived age would flake, and the flake would read as the
divergence the shared render layer exists to prevent. `attempted` and `succeeded` cross as recorded
values and nothing ages them — not `render`, not `status`.

**The producer is `~/.local/bin/substrate-refresh`, which git does not track.** It now records on
every path, including the Ollama-down early exit and a genuine failure to acquire its own lock. The
review found the writer had the exact bug the reader exists to catch: its drift probe read
`["drift"].get("stale")`, and an unresolvable vault returns `{"error": …}` with no `stale` key, so
`status` exited 0 and the probe printed `current` — recording `unchanged`, the strongest healthy
claim in the vocabulary, for a scope nobody could check. `checkable: false` fell through the same
hole. Both are `unknown` now, and there is a default arm so an unrecognised probe result cannot be
silent. **A change to `status --json`'s drift shape breaks this producer with nothing in CI to
notice** — a reviewer proposed moving it to `tools/` alongside `embedder-sweep.sh`; not done,
because where the operator's machine config lives is a decision, not a cleanup.

**Adding an envelope field ages out running MCP clients too**, though quietly rather than fatally:
a server started before this change holds the old `render` and emits no `refresh` key at all, so
the freeze signal is invisible there until it is restarted. No `SchemaMismatch`, no error — just
the field silently absent, which is the state it was built to make impossible.

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
2. **Doc 2's text is behind its own implementation — PARTLY CLOSED 2026-07-27.** §6 documented
   `status` and stopped. **§6a is now written** (doc_type, including the fifth value `digest`, its
   placement rule and the boundary that governs adding a sixth) — see `MIGRATION-VOCABULARY.md`.
   Still absent from the body: `confidence` (WRITING.md cites a §6b that does not exist) and the
   conversation class. Doc 3a is also still behind: it describes a `doc_type` filter that refuses,
   and folds archived into `include_sources` where the engine deliberately keeps two axes.
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
- Schema is **v7**, drop-and-rebuild. Read paths refuse a version mismatch rather than rebuilding;
  only `compose`/`index` migrate.
- **A SCHEMA BUMP SILENTLY BREAKS EVERY ALREADY-RUNNING MCP CLIENT.** Python imports at process
  start and an MCP server lives as long as the client session that spawned it, so after a bump the
  running servers hold the old `SCHEMA_VERSION` while every index on disk is new. `IndexStore`
  then raises `SchemaMismatch` on each read — correctly, that guard is what stops a read-only tool
  destroying an index — but the user sees "substrate is broken", not "your client aged out".
  Observed at the v7 bump: fourteen `mcp.server` processes were live, the newest 85 minutes older
  than the change and two of them from the previous day. A fresh spawn worked the whole time.
  **There is no way for the server to tell a client it has aged out, so the bump commit has to say
  it**: restart Claude Code (`/mcp` reconnect or a new session), fully quit-and-relaunch Claude
  Desktop (a window close is not enough), and restart Zed. Applies again at v8.
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
