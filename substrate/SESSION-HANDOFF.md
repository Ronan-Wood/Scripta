# Session handoff — the MCP server is built, deployed, and running against the real vaults

Written 2026-07-27, corrected 2026-07-28 and 2026-07-29. Branch `substrate-engine`, work in
`substrate/`. Read `PRINCIPLES.md` first (four laws), then this.
**Where a line here and a line below disagree, the later dated one wins** — several sections were
written before the deployment they describe, and the contradictions are now marked rather than
left for the reader to adjudicate. `PILOT-READOUT.md` has the
real-content pilot and migration findings; `HANDOFF.md` has the engine's history.

## Bottom line

**Doc 3a phase 1 is built, reviewed, deployed and measured.** Five MCP tools over the engine, a
scope registry, one payload-shaping function both adapters render from, drift detection, a
two-phase write gate, and a freeze signal on every response. Schema **v8**. 412 assertions green.

**It runs against the real vaults and the measured stack executes.** Seven scopes composed,
embedded and vector-complete, refreshed by an unattended launchd agent; the MCP is registered in
Claude Code, Claude Desktop and Zed. The 0.698 path is observed, not constructed — and the vaults'
OWN retrieval is measured separately in `eval/gold-vault.json`, which is a different corpus and a
different cohort from the 44-case reference tier. They are not subtractable.

**The eval fixture was rebuilt at v8 and its signature is now recomputable.** See *Constraints
that bite* — both of those sentences were false a day ago.

## Recovery procedure — NOT a first step (superseded 2026-07-27, kept because it is how you rebuild)

All six scopes are already composed, embedded and registered; see *Deployed* below. Run this only
to rebuild a scope from scratch. Per project scope (six: prism · scripta · cbre · research ·
school · clovis):

```
substrate compose ~/OneDrive/vaults/<x>-vault --clean \
  --index-root out-vault/<x>-index --db out-vault/<x>.db     # also REGISTERS the scope
substrate embed --db out-vault/<x>.db                        # serial, weights on ExtremeSSD
```

Compose writes `~/.substrate/scopes.toml`, which is how a scope name resolves to an index. (The
line that used to sit here — "nothing is registered yet" — was true only on the day it was written;
the registry now holds all six.) Until `embed` runs, every search honestly reports `expected_mrr: null` and names the missing
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

**Ollama was the unowned dependency — OWNED as of 2026-07-29, verified.**
`~/Library/LaunchAgents/com.ronanwood.ollama.plist` exists with `RunAtLoad` and the explicit
`EnvironmentVariables` block carrying `OLLAMA_MODELS=/Volumes/ExtremeSSD/ollama-models`, which is
exactly what this paragraph predicted would be required: a launchd context does NOT inherit it, and
the weights live on that external volume. The process is running. **It is still wrong whenever the
SSD is unmounted** — that has not been solved, only located. Without Ollama the refresh job skips
every tick and every query runs lexical-only, which the capability envelope reports honestly but
which is the 0.343 tier.

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

**Wired into all three clients as of 2026-07-27** — Claude Code (`~/.claude.json`, user scope),
Claude Desktop and Zed; this paragraph previously said "not wired into any client", which was true
when written and false by the end of that same day. Manual launch is still
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

## v8 — `supersedes` is list-valued (2026-07-28)

Same TEXT column, JSON array inside it, exactly as `domains` already worked. One live note can
replace SEVERAL dead ones: `substrate-topology` replaced both `multi-vault-mcp` and
`connections-topology`, the scalar could name only one, so the pair was written in PROSE — "a field,
not prose" is the boundary principle's own rule, broken by the field it was written about.
`superseded_by` stays scalar: a dead note has exactly one live replacement, and a list there would
invent a case that does not exist.

`reader.doc_id_list` is the one parser, and it takes all three shapes the field legitimately
arrives in — a v8 flow list, a pre-v8 frontmatter scalar, and a `run.json` value that is a list or
a string. That last shape is why it takes `object`: a bare `list()` over a v7 run.json explodes
`"old-note"` into eight one-character links, and `reconcile` reads artifacts written by every prior
version. The same normalisation guards `IndexStore.upsert`, so a `Document` built by hand with a
string cannot put the exploded form on disk either.

**Exactly one note had to be rewritten**, and it is the one the bump was made for:
`core-vault/00-operator/patterns/substrate-topology.md` now declares
`supersedes: [multi-vault-mcp, connections-topology]` and the paragraph explaining why it could
not is gone. The two pre-existing scalar declarations in `scripta-vault` were left alone — they
read back as one-entry lists.

**The envelope contract changed**: `supersedes` went from `"doc-id"`/`null` to `["doc-id"]`/`[]`.
Updated in the same pass — `~/.claude/skills/substrate/SKILL.md`, `~/.claude/CLAUDE.md`, and the
`search` tool description. Claude Desktop and Zed configs only launch the binary and describe no
fields, so they needed nothing beyond the restart.

All seven scopes recomposed and re-embedded at v8 by hand rather than left to the agent: a schema
bump does not move a vault, so drift reports `current` and the agent would not have rebuilt on that
signal. It would have self-healed anyway — `status` refuses on a version mismatch, the probe reads
no JSON, and the `unknown` arm recomposes — but only after up to fifteen minutes of every scope
refusing every read.

**`out/substrate.db` is untouched** (`7311ffbf…`), and it was already at `user_version 2` before
this change — the eval fixture rebuilds from markdown via `substrate index` whenever it is next
run, and v8 adds no column and no indexed text, so the signature is unmoved.

## Two failure patterns this session earned

Both were found by review, not by testing. **PROMOTED 2026-07-29** — they are instances (1) and (2)
of `PRINCIPLES.md`'s fourth law, *a claim that reads as verification, with nothing behind it, is
worse than silence*, alongside three more the fixture-signature work earned. The two-place edit was
made in the required order: the vault copy
(`core-vault/00-operator/patterns/boundary-principle.md`) first, then copied here, byte-identical
below the frontmatter and verified mechanically. Kept below because the specifics are the evidence.

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

**Verified 2026-07-29, not taken on trust — three items below were already closed and had been
sitting here as open work.** That is the same failure mode as a guard constant nobody recomputes:
this file is what the next session reads, so a stale line here spends a session redoing finished
work. Check before adding to this list, and date what you checked.

1. ~~**Run it.**~~ **CLOSED.** Six scopes registered, all reporting `unchanged`, none frozen; the
   launchd refresh agent ran within the hour. ~~Ollama is the unowned dependency~~ — also CLOSED,
   and correctly: `~/Library/LaunchAgents/com.ronanwood.ollama.plist` exists, is running, and
   carries the explicit `OLLAMA_MODELS=/Volumes/ExtremeSSD/ollama-models` block that the constraint
   below predicted it would need. It is still wrong whenever the SSD is unmounted.
2. **Doc 2's text is behind its own implementation — the §6 family is CLOSED 2026-07-29.** §6
   documented `status` and stopped; §6a added `doc_type` (2026-07-27). Now written, in the vault
   copy only — Doc 2 lives in `core-vault/00-operator/specs/` and `docs/README.md` is a pointer,
   never a copy:
   - **§6b `confidence`** — the vocabulary table, the independence from `status` that stops
     confidence laundering, and the declarable/absence asymmetry (`unstated` is written,
     `unjudged` is what an absent key becomes and can never be declared). It also states the rule
     §6a already deferred to and which did not exist: an invented marker is worse than an absent
     one. WRITING.md:64 had cited this section for months.
   - **§6c `document_class` and the conversation exclusion** — the SECOND exclusion axis, and why
     it must not be folded into `status`: superseded content is excluded because it was replaced,
     a conversation because per-passage retrieval misrepresents a document still wanted whole.
     They disagree about embedding, which is the proof they cannot be merged.

   Both were verified against the code rather than written from memory — the §6b table is
   `spine.DECLARABLE_CONFIDENCES` and the §6c table is `classes.POLICIES`, both checked
   mechanically. That check caught a wrong sentence: the first draft claimed agreement with
   `spine.CONFIDENCES`, which is the four-value set and excludes `unstated`.

   **Still behind: Doc 3a.** It describes a `doc_type` filter that refuses, and folds archived into
   `include_sources` where the engine deliberately keeps the two axes §6c now specifies.
3. **`reference_pins` is the last unimplemented §2 feature.** Prerequisite unchanged: only one
   versioned source exists, so there is nothing to pin against.
4. ~~**The cutover.**~~ **CLOSED.** `~/.claude/CLAUDE.md` is now substrate-first throughout: it
   routes every scope through the skill and MCP, names `~/vaults/ClaudeVault/` the retired
   predecessor, and tells sessions not to read or write it. The migrated vaults are what a session
   actually reads.
5. ~~**Promote this session's patterns into `PRINCIPLES.md`.**~~ **CLOSED 2026-07-29.** Done as
   the required two-place edit — vault copy first, then copied here, byte-identical below the
   frontmatter and verified mechanically rather than by eye. All five landed as the **fourth law**:
   *a claim that reads as verification, with nothing behind it, is worse than silence.* They are
   one shape, not five, which is why they went in as one law rather than five bullets:

   - **A guard nobody runs.** `4a560ce34aa6378a` was recomputable from its first commit and
     recomputed by nothing — `out/` is gitignored, no test asserted it, and the tool's only caller
     in the repo was its own test. Recomputable-in-principle is the same defect as unrecomputable,
     one level down, and it is invisible precisely because the mechanism looks finished. The cure
     is a caller in the path someone already runs (`run.sh`), not a better number.
   - **A conservative predicate whose remedy does not work.** Refusing safely is half an answer: the
     first sidecar guard refused a `journal_mode=PERSIST` database it could read perfectly and told
     the operator to run a WAL checkpoint, verified a no-op on a rollback journal. "Refuse rather
     than mislead" becomes "refuse AND mislead" the moment the printed instruction cannot clear the
     condition. A refusal is only complete when its remedy is tested too.
   - **`user_version` does not describe a file's column shape.** `out/substrate.db.v2-frozen-…` is
     stamped 2 and carries 26 columns including `confidence`. The stamp is a claim about migration
     history, not about what a SELECT will find — trusting it produced a wrong sentence in this
     file and nearly a wrong reading of the mutation evidence that justified the signature.

6. **Deferred, with reasons:** don't-embed-superseded (cost, not correctness); domain
   soft-weighting (eval-gated, needs cross-domain gold cases); the index watcher; the weekly lint.
7. **Housekeeping:** `cmd_eval` keeps two hand-rolled copies of the vector guard that
   `IndexStore.vector_coverage` now supersedes — deliberately untouched, it guards the number that
   must not move. The A21/A23 "duplication" is **closed as won't-fix, and the earlier reason for
   that was wrong**: it is not that the two are merely parallel, it is that the duplication is
   THREE-way — `assert_status_partition`'s first two checks are the same unknown-value-then-drift
   scan — so collapsing A21 into A23 would leave the third copy and make the family less uniform
   than it is now. Either unify all three behind one `_assert_axis_valid(column, vocabulary, error,
   …)` or leave them; a two-way merge is the one move that makes things worse. Evidence the
   duplication does cost something: the `NULL NOT IN (...)` subtlety was corrected in A21's
   docstring and independently re-derived in A23's.

   Small and named so they are not rediscovered: **`run.sh:23`** repeats the `mode=ro` reason that
   was corrected elsewhere on 2026-07-29 — the CLI failure is real (verified, error 14 on a fresh
   copy) but "SQLite cannot create the `-shm` under a read-only open" is false as stated, since
   Python's sqlite3 does create it; `MIGRATION-VOCABULARY.md:390` and `PILOT-READOUT.md:509` carry
   related wording. **`python -O` strips every assertion in all 27 test files** and the hand-rolled
   runners then print a full green while checking nothing — repo-wide, pre-existing, and worth one
   shared fix rather than 27. **`.zed/settings.json` is untracked and unignored** — a decision about
   what belongs in the repo, not a cleanup.

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

- **EVAL MUST NOT MOVE** — content signature **`4a560ce34aa6378a`**, 1811 chunks, complete vectors
  under `qwen3-embedding:0.6b#raw`, schema **v8**. Check it, do not take it on trust:

      uv run python tools/fixture-signature.py out/substrate.db

  **And `./run.sh` now checks it for you**, which is the half that was missing: the expected value
  is tracked in `eval/fixture.sig` (the database is gitignored, so the constant has to live in a
  file that is not), and the eval REFUSES to run when the two disagree rather than reporting an
  MRR over one corpus against a baseline measured on another. Until that gate existed the tool had
  exactly one caller in the repo — its own test — which is the same shape of defect as the number
  it replaced: recomputable in principle, recomputed by nobody.

  Read with an `immutable=1` URI, NEVER through engine code **at any setting** — `migrate=True` is
  drop-and-rebuild on a mismatch and would destroy the artifact, and `migrate=False` REFUSES a
  mismatch, so the engine cannot read the v2-frozen file at all. `mode=ro` is not the alternative
  either, and the earlier claim here that it "now fails on a perfectly readable file" was **only
  true of the `sqlite3` CLI** (which is what `run.sh` observes, and it does still fail). Measured
  under Python: `mode=ro` opens the fixture fine and returns all 1811 rows — while CREATING the
  `-shm`/`-wal` pair beside it, which is the process state commit `a3c63f0` untracked. That is the
  real objection, and it is the stronger one. `immutable=1` does neither.

  **This replaces `4a4f765c9ad75dc9`, which was never checkable.** That number guarded the fixture
  in three readouts and in this line, and its derivation was recorded nowhere —
  MIGRATION-VOCABULARY.md has a session trying seventeen constructions over `(chunk_id,
  text_with_path)` and reproducing none. The replacement states its derivation in
  `tools/fixture-signature.py` and pins the properties it is chosen for in
  `tests/test_fixture_signature.py`: invariant under schema version, insertion order and vectors;
  variant under an edited text, a changed structural path, or a chunk appearing or disappearing.

  Schema invariance is really pinned **once**, and the first draft of this paragraph said twice.
  Stamping the version backwards proves only that the STAMP is not hashed — `PRAGMA user_version`
  is a header field no SELECT can reach, so that test cannot fail for the reason that matters. The
  load-bearing one signs a hand-built table carrying ONLY the three hashed columns: widening the
  SELECT to `confidence` makes the two fixture files disagree (`d2115b18…` vs `4a560ce3…`), and
  before that test existed the entire suite stayed green through it.

  **`out/substrate.db.v2-frozen-…` is not v2-SHAPED**, which matters for reading that comparison
  honestly. Measured: it is stamped `user_version=2` but its `chunks` table carries 26 columns
  including `confidence` (all NULL) and `section_kind`, while v8 carries 27 including `status` and
  `doc_type`. So `user_version` does not describe that file's column shape, and the pair spans a
  real but NARROWER schema difference than "a v2 file and a v8 rebuild" implies. The two do sign
  identically, and the widened-SELECT mutation does split them — because `COALESCE(NULL,'')` and
  `'unjudged'` differ, not because the column is absent.

  It **refuses** rather than returning a number it cannot stand behind: a sidecar that may hold
  unread rows, a path that does not exist (`immutable=1` does NOT imply "will not create" —
  it materialises a zero-byte database, the same incident `IndexStore` already guards), an empty
  chunks table (`sha256(b"")` is a well-formed signature for nothing), a non-text column, and any
  field carrying a delimiter byte. That last one is what keeps the framing injective: with a NUL
  in `text` or a newline in `chunk_id`, two different chunk sets serialise identically and a
  re-chunk would leave the signature unmoved. Measured on the fixture: 0 of 1811 violate it, so
  the constant is unchanged — the precondition is now enforced instead of assumed.

  The sidecar rule is **prove safe, else refuse**, and it reads the sidecars rather than their
  size. The salt test is deliberately BROADER than SQLite's replay rule — that also wants a valid
  checksum chain and a commit record — so the frames refused are a superset of the frames SQLite
  would apply. Narrowing to the exact rule means reimplementing its checksum algorithm, where a bug
  fails by calling a hot log empty. `st_size > 0` was the first predicate and it was wrong in both directions of usefulness: it
  refused a header-only `-wal` (32 bytes, nothing replayable) and it refused a `journal_mode=PERSIST`
  `-journal`, whose header SQLite ZEROES on a clean commit to mean "nothing to roll back" — and for
  that second case the remedy printed was a WAL checkpoint, verified to be a no-op on a rollback
  journal, so the operator was refused permanently with no working instruction. Both now read as
  the empty logs they are.

  What it still refuses, deliberately: a `-wal` whose frames carry the header's salts, **even after
  a checkpoint has copied them into the main database**. Measured — after `wal_checkpoint(RESTART)`
  the salts are unchanged (SQLite bumps them on the next WRITE) and whether a frame has been
  checkpointed lives in the `-shm` wal-index, not the log. Anything the reader cannot parse is also
  refused, so a bug in it fails toward refusal. A false
  refusal costs a checkpoint; a false accept costs the invariant. The message names remedies for
  both the live-writer and orphaned-sidecar shapes.

- **The fixture was rebuilt at v8 on 2026-07-28**, deliberately, and the rebuild is lossless for
  everything measured — note that the signature covers chunk text and attribution, NOT
  `document_class` or `status`, the two columns `retrieve()` also filters on, so "lossless" here
  rests on the eval result as much as on the hash: identical 1811 chunks, all 1811 vectors
  restored FROM CACHE (0 re-embedded, so
  bit-identical rather than merely equivalent), eval MRR 0.698 at delta −0.000, and every one of
  the 38 passing semantic cases at its exact baseline rank — 25 at 1, 10 at 2, one at 3, two at 5,
  zero moved. The same signature reads off the pre-rebuild file, which is kept at
  `out/substrate.db.v2-frozen-4a4f765c9ad75dc9` (file sha `7311ffbf3180…`). The FILE hash changed
  and is not the invariant; the content signature is.
- Schema is **v8**, drop-and-rebuild. Read paths refuse a version mismatch rather than rebuilding.
  `compose` migrates unflagged (it re-ingests before opening the store); `index` needs an explicit
  `--migrate`, deliberately separate from `--rebuild`.
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
