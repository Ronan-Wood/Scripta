# Architecture — Scripta and the substrate engine

The whole system, in one document: what each half does, the stack, the retrieval techniques and
what they measured, and the machinery that makes the engine refuse rather than mislead.

**Read this before `README.md`.** That file describes the app as it was before Doc 4 — a bundled
`scripta-mcp` helper (deleted, Phase 3), an app "sandboxed in every configuration" (unsandboxed
since Doc 3 §1), a seven-pane hub (now five), `DocumentImporter` (deleted, Phase 4b), a Swift
`Retriever` with a gated vector slot (the entire Swift retrieval stack went in Phase 6) — and it
never mentions the substrate engine, which is now most of the system.

Numbers below carry the conditions they were measured under. Where a claim is a decision rather
than a measurement, it says so.

---

## 1. Two systems, one corpus

Scripta records calls and writes Markdown. Substrate reads Markdown vaults and answers over them.
Separate programs, separate languages, separate test suites, meeting at exactly one place: **a
folder of Markdown files.**

That boundary is the design. The app never queries an index directly; the engine never knows what a
microphone is. Either can be replaced without touching the other, and the corpus outlives both — the
files are readable in any editor and the index is a rebuildable cache that can be deleted at will.

```
Scripta (Swift/SwiftUI, macOS 26)          Substrate (Python 3.14)
  capture → transcribe → write ──→  *.md  ──→ ingest → chunk → index → retrieve
                            ▲                                            │
                            └────────── JSON-RPC on loopback ────────────┘
                                                 │
                                        MCP ─────┴───→ Claude Code, other clients
```

The app spawns the engine as a child process. The same engine serves Claude Code over MCP.
*Measured 2026-08-12:* app running → 3 engine processes, quit → 0 orphans, relaunch → back on
`:8765`.

---

## 2. Capture

**Attribution is physical, not inferred.** Two separate tracks — microphone via `AVAudioEngine`,
system audio via `ScreenCaptureKit` — transcribed independently. Mic is You, system is Them. No
diarization model, no guess. When only one side has audio the labels are *omitted* rather than
guessed; conference mode captures one unlabelled source, because in a hybrid room both tracks hear
the same speech and would double every line.

| # | stage | notes |
|---|---|---|
| 1 | capture | two tracks → 16 kHz mono WAV. Raw audio is ephemeral and always deleted after transcription |
| 2 | transcribe | Apple `SpeechTranscriber`, on device. No model download. Live transcript streams from volatile results, both sides labelled |
| 3 | clean + enrich | deterministic filler removal, then optional title/summary/topics from Apple Foundation Models — deterministic first, so the model is never trusted with what a rule can do |
| 4 | write | YAML frontmatter + timestamped body into the workspace's vault. From here the file is the artefact; everything downstream is derived |

**Screen context.** During a call the app can periodically OCR a chosen window — tables become
Markdown through `RecognizeDocumentsRequest` — and interleave it into the transcript, timestamped.
Screenshots are discarded immediately after extraction.

---

## 3. The corpus — a vault is a contract

Substrate does not index arbitrary directories. It composes **scopes**: a project vault plus the
vaults it inherits, resolved from a `.substrate.toml` manifest at the project vault's root. One
scope spans several directories, which is why `list_scopes` is the only reliable way to learn what
exists.

### Three tiers

| tier | holds | reuse |
|---|---|---|
| 1 | operator knowledge — who you are, how you work, patterns outliving projects | every scope |
| 2 | shared references — concepts useful to more than one project | several scopes |
| 3 | project-local material — decisions, notes, recorded calls | one scope |

### The spine

Four declared fields. Retrieval filters and ranks on them, so a note without them answers badly.

| field | vocabulary | effect |
|---|---|---|
| `status` | `active` · `complete` · `archived` · `superseded` | the first two are retrieved by default; the others withheld |
| `doc_type` | `decision` · `explanation` · `reference` · `how-to` · `digest` | one note, one job — a note doing two gets split |
| `confidence` | `proposed` · `inferred` · `stated` · `verified` | how settled the claims are. `unstated` means *not yet judged*, never *uncertain* |
| `domains` | free list | subject filtering across scopes |

A fifth field decides visibility. **Recorded calls are `document_class: conversation` and are
withheld from retrieval by default** — a question about something said on a call returns curated
notes unless the caller passes `include_sources: true`. The reply always states what was excluded,
because silence would read as "no such call".

---

## 4. Ingestion

A chunker that splits on token count destroys the one thing that makes a document navigable:
position. Substrate chunks along document structure and **denormalizes position onto every
passage** — heading path, page label, `document_class`, version, `source_sha256` — so a retrieved
passage can state whether it is current without a join.

### Formats

Markdown and text are read by the engine's own reader; everything else converts to Markdown first
and enters the same ingest path, so a DOCX passes the gates the native path also runs.

| arm | formats | needs models |
|---|---|---|
| native | `md` `txt` | no |
| converted | `docx` `pptx` `xlsx` `html` `csv` `vtt` `eml` `adoc` `tex` `epub` | no |
| model-backed | `pdf`, images (OCR) | yes — layout model, ~1 GB |

### Two gates that are ingestion's own

- **Non-empty.** A conversion yielding no word is refused. Not hypothetical: a blank image converts
  with `status=SUCCESS` and a zero-character body, and every downstream check passes it, because
  coverage over an empty document is 1.0 by construction.
- **Raw-text coverage.** Where a cheap independent reading of the source exists (OOXML text nodes,
  HTML text nodes, plain bytes), 95% of its word tokens must survive into the Markdown. Where no
  such reading exists, coverage is recorded as `null` with the probe named `unavailable` — never as
  a passing number. Absent evidence is not a clean result.

---

## 5. Retrieval

BM25 over passages via SQLite FTS5, optionally plus a vector arm, optionally query expansion,
optionally reranking. Every arm is measured against a gold set, and the shipped configuration is a
*measured* configuration: change one model and the engine returns `expected_mrr: null` rather than
quoting a number that no longer applies.

### Measured stacks

Mean reciprocal rank, same 44-case cohort, model-specific. Quoting a figure from a different cohort
beside these would be the cross-cohort subtraction this project forbids.

| stack | MRR | requires |
|---|---|---|
| full Ollama + cross-encoder rerank — **shipped default** | 0.708 | Ollama running |
| full Ollama, listwise rerank | 0.698 | Ollama running |
| **full Apple — on-device, nothing installed** | 0.593 | nothing |
| Apple embedder alone | 0.343 | nothing |

### The reranker reversed on the real corpus

On reference books the two arms tied (0.698 vs 0.708, "total spread under two cases") and the
listwise arm shipped because it was ~10× faster. Re-measured 2026-08-10 on the operator's own
vaults (34-case gold set, only the rerank arm varying), **both halves of that argument reversed**:

| arm | semantic MRR | overall MRR | p50 (uncached) |
|---|---|---|---|
| none | 0.494 | 0.613 | 161 ms |
| listwise `qwen2.5:7b` (was default) | 0.426 | 0.671 | 4,050 ms |
| **cross-encoder (now default)** | 0.679 | 0.683 | 586 ms |

The shipped arm scored *below no reranker at all* on paraphrased queries and was the slowest of the
three. The latency reversal is structural, not incidental: the listwise arm asks a 6.4 GB chat model
to generate an ordering over 20 candidates, while the cross-encoder runs 20 short scoring passes
through a 2.5 GB model trained on the relevance judgment the other one improvises.

### A technique measured and switched OFF

Section routing — match the query against outline records, then pull passages beneath the winning
section — is a sound idea: a plain-language question often shares no vocabulary with any passage but
matches a section's orientation record well. It was built, fused with Reciprocal Rank Fusion
(k=60, parameter-free and scale-free, which matters because BM25 over passages and BM25 over outline
records are not on the same scale), and **turned off, because it did not pay.**

| config | lexical | semantic MRR |
|---|---|---|
| direct only | 28/28 | 0.207 |
| RRF fusion, equal weight | 27/28 ✗ | 0.219 |
| RRF fusion, routed ×0.45 | 27/28 ✗ | 0.250 |
| backfill (cannot displace) | 28/28 | 0.207 (no-op) |

Two mutually exclusive failure modes. **Fusion displaces:** routed passages were retrieved because
their *section* matched, so interleaving them floods top-k with section-mates and pushes the exact
answer out. **Backfill is inert:** restricting routed results to slots direct retrieval did not earn
is safe by construction, but BM25 always returns k results, so there is never a free slot. The gain
was one case improving while two regressed — variance, not a technique. Kept with its measurement so
it is not re-litigated from scratch.

---

## 6. The honesty machinery

> **Information that exists but does not cross the boundary to its consumer reads as absence — and
> absence reads as fine.**

The dominant failure shape of this project: five incidents, different subsystems, one structure. In
every case the missing information already existed; the failure was attaching it to the thing that
crossed. An output missing its conditions is indistinguishable from one that had none — a heading
path naming the wrong chapter is well-formed, an MRR over zero vectors is a valid float, degraded
results are still results.

The cure is structural: **attach the condition to the output as a field** — not prose, which a
summary paraphrases away; on the output, not beside it; quantified where possible.

| field | what it prevents |
|---|---|
| `capabilities` | which arms actually ran — `ran` / `skipped` / `off` / `fell_back`. A lexical-only answer cannot pass as full-stack |
| `expected_mrr` | the measured tier for *this exact stack*; an unmeasured config returns `null`, never a guess |
| `index_version` | what the index was built from — converts silent staleness into detectable staleness |
| `refresh.frozen` | tri-state: `true` a rebuild refused and results are superseded, `false` index and vault agreed, `null` no basis |
| `filters.sources_excluded` | that calls were withheld, so silence cannot read as "no such call" |

**The sixth incident was predicted before its cause existed.** The document describing this pattern
once ended: *"a version stamp that implied staleness was handled would be the sixth occurrence."*
What produced it was the fix for the manual half — an unattended agent making refresh automatic. A
scope whose rebuild *refused* kept its old index and answered in an envelope byte-identical to a
healthy run. The cure was the cure: `refresh` became a field on the envelope, tri-state, read by the
shared render layer rather than attached by each adapter — because an adapter that has to remember
to attach it is one that eventually will not.

### Composition gates

Composing a scope runs a lettered assertion series and **refuses the entire scope if any single note
fails**, because a partially composed scope is a silently-wrong retrieval set. A18 measures the
Markdown against the resulting chunks; A20 status membership; A21 doc types; A22 a per-note sweep;
A23 confidence.

> Promoting a check suite to a gate is an audit of every check in it, executed in one step — and the
> correct expectation is a crop of false rejects.

Observed exactly that way: wiring the per-document series into `compose` immediately exposed two
checks wrong since Markdown ingestion existed. One counted ordinary exclamation marks as hyphen
residue; the other computed a stale-ancestor ratio against a denominator that only made sense for a
whole book. Both were invisible precisely because nothing gated on them.

---

## 7. Packaging

The engine ships **inside the app bundle**, built by a post-build phase on the `Scripta` target
(`substrate/tools/build-bundled-engine`). *Verified 2026-08-15:* a relaunched app spawns
`Scripta.app/Contents/Resources/substrate-engine/.venv/bin/python -B -E -s -m substrate.mcp.server`.

| component | size | notes |
|---|---|---|
| Python dependencies | 1.0 GB | `uv sync --frozen --no-dev`; the dev group was ~200 MB of editor tooling |
| precompiled bytecode | 294 MB | 14,403 `.pyc`, bought for import speed |
| vendored interpreter | 75 MB | relocated `python-build-standalone` |
| on-device model arms | 172 KB | three Swift binaries, compiled from committed source at build time |
| **engine total** | **1.4 GB** | 366 Mach-O, each signed and verified for the hardened runtime |

Most of that weight is one dependency. The entire *runtime* path — compose, search, expand, status,
the MCP server — runs on numpy alone, about 23 MB; the rest exists for document conversion. Three
tiers (23 MB / 160 MB / 1.0 GB) were built and run before **deciding** to bundle everything: these
corpora are PDF-heavy, so any split would have triggered the large download almost immediately.

**Two failures worth knowing, because neither shows in a green build:**

- **The app broke its own code signature on first launch.** Copying the interpreter without
  preserving mtimes made every shipped `.pyc` read as stale, so CPython rewrote bytecode *inside the
  sealed bundle*. A notarized app that rewrites itself on first launch is no longer the app that was
  notarized. Cure: `cp -Rp`, `--compile-bytecode`, `compileall`, and `-B` at runtime.
- **Two hardening flags cancelled.** `-E` was added to stop `PYTHONPATH` redirecting imports inside
  a signed process. It also makes CPython ignore every `PYTHON*` variable — including the
  `PYTHONDONTWRITEBYTECODE` guard added an hour earlier. Both lines read as hardening, which is why
  reviewers looked past them. `-B` is the form that survives `-E`; `-I` breaks the engine outright,
  because `substrate` runs from the tree rather than site-packages.

---

## 8. The stack

| layer | choice | reasoning |
|---|---|---|
| app | Swift · SwiftUI · macOS 26 | the OS floor buys `SpeechTranscriber`, Foundation Models and the document/table recognizer — no bundled ML runtime for capture |
| audio | ScreenCaptureKit + AVAudioEngine | two independent tracks; attribution becomes physical rather than a model's guess |
| shared Swift | local SwiftPM package | `ScriptaCore` (parsing, index, entities), `SubstrateKit` (the engine's wire vocabulary), `ScriptaShared`. Statically linked, testable without the app |
| engine | Python 3.14 | where the document-extraction and retrieval ecosystems actually live |
| index | SQLite + FTS5 | BM25 without a server; a rebuildable cache, never the source of truth |
| extraction | docling (`docling-slim[standard]`) | layout-aware conversion; every import is lazy, so the runtime path never loads it |
| embeddings | Ollama, or Apple `NLContextualEmbedding` | the on-device arm needs no install and is not gated on Apple Intelligence |
| reranking | cross-encoder | a model trained on the relevance judgment rather than a chat model improvising one |
| transport | JSON-RPC — stdio and loopback HTTP | one server for the app and for Claude Code; `--read-only` on the socket |
| build | XcodeGen | targets generated from `project.yml`; sources are a directory sweep, not a hand-maintained list |

### Tests and gates

| suite | count | covers |
|---|---|---|
| engine, `uv run pytest tests/ -q` | 587 | ingest, chunking, spine, gates, retrieval, refusals |
| Core, `cd Core && swift test` | 247 | vault layout, parsing, index, wire mapping, conversation storage |
| eval fixture | 1,811 chunks | pinned by signature `4a560ce34aa6378a`; a run refuses to report MRR if the fixture moved |

Two rules the project runs on, both learned expensively: **a new test is mutation-checked before it
is trusted** — break the code, watch it fail, restore it — and **a view change is not done until the
app has been opened**, because a green build says nothing about layout, reachability, or a control
that does nothing.

---

## 9. Deliberate absences

- **No cloud, no account, no telemetry.** The only network calls are to a model server you chose;
  public hosts are refused with no override.
- **No auto-recording.** The calendar is informational; recording is always deliberate.
- **No semantic diarization.** Two tracks, physical attribution, labels omitted when one side is
  silent.
- **No open-ended on-device reasoning.** Local models get bounded jobs — topics, query expansion,
  grounded answers with citations. Deep reasoning is handed to a frontier model through MCP.
- **No section routing.** Built, measured, switched off (§5).
- **No periodic refresh outside the app.** Indexes refresh while Scripta is open. A machine that has
  not opened it for a week reads a week-old index — and reports `frozen: false`, because nothing
  failed; nothing ran.
- **No notarization yet.** The one part of the packaging plan with no evidence behind it.

---

Related: `substrate/PRINCIPLES.md` (the four laws), `substrate/SESSION-HANDOFF.md` (current state
and open items), `Distribution/RELEASING.md` (the shipping runbook). The structural spec is Doc 2 in
`~/OneDrive/vaults/core-vault/00-operator/specs/`; the decision records are Doc 3–5 in
`~/OneDrive/vaults/scripta-vault/03-references/`.
