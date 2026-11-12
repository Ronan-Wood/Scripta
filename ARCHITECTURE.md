# Architecture — Scripta and the substrate engine

How Scripta is built: what the app does, how it runs the engine and talks to it, how the engine is
packaged into the app, and what the app deliberately leaves out.

The engine is its own repository, [Ronan-Wood/substrate](https://github.com/Ronan-Wood/substrate),
and documents its own internals: its [architecture](https://github.com/Ronan-Wood/substrate/blob/main/docs/architecture.md),
its [configuration](https://github.com/Ronan-Wood/substrate/blob/main/docs/configuration.md) (vault
manifests, note frontmatter, the registry), its [security model](https://github.com/Ronan-Wood/substrate/blob/main/docs/security.md),
the [client contract](https://github.com/Ronan-Wood/substrate/blob/main/docs/client-contract.md)
the app is held to, and the [principles](https://github.com/Ronan-Wood/substrate/blob/main/docs/principles.md)
both halves follow. Sections 3 to 6 below summarize what the app relies on and link there.

Numbers below carry the date and conditions they were measured under. Where a claim is a decision
rather than a measurement, it says so. Code comments cite design records as "Doc 2" to "Doc 5".
Those are the maintainer's notes and aren't published; the comment beside each citation says what
the decision was.

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
                            └─────── JSON-RPC on a Unix socket ──────────┘
                                                 │
                                        MCP ─────┴───→ Claude Code, other clients
```

The app spawns the engine (`substrate serve`) as a child process; the same engine serves Claude
Code over MCP and refreshes every scope itself, on its own timer, under the one lock every compose
and embed take (`vaults.lock`). An engine already running on the socket is used instead when it is
one that runs no write without a grant, refreshing, not agent mode, indexing Scripta's note format,
and on Scripta's registry (`EngineAttach`). While attached, Scripta writes notes and registers scopes, and that engine does
all the indexing: "Refresh now" asks it for its next pass. Scripta never stops an engine it did not
start, and starts its own if that one goes away.

**The socket.** The engine listens on a Unix socket in a 0700 directory in its own folder,
`~/.substrate/run/substrate.sock`, and both ends refuse a peer running as another user. It used to
listen on loopback TCP, which let every user on the Mac query every scope. The socket path 0.3.4
used, which clients were registered with, is kept as a symlink to it (`LegacyEngineSocket`).

**The wire version.** Both ends state and check a wire version (the `Substrate-Wire` header). The
engine serves a declared range of client versions, every change inside it additive, and refuses an
app outside that range rather than leave it to mis-decode a reply. `engine.lock` records the wire
version this app speaks, and `WireParityTests` holds `SubstrateWire.version` to it.

*Measured 2026-08-12, when the engine still used TCP:* app running → 3 engine processes, quit → 0
orphans, relaunch → back up.

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

**Screen context.** During a call the app can periodically OCR the frontmost window, the whole
screen or a window you pick. Tables become Markdown through `RecognizeDocumentsRequest`, and the
text is interleaved into the transcript, timestamped. Each screenshot is discarded once its text is
read. The one exception: with a local vision model set up, up to 20 frames wait as images for the
post-call captioning pass, and are deleted after it.

---

## 3. The corpus: a vault is a contract

Scripta writes each call as a note into the active workspace's vault, and registers that vault with
the engine. The engine doesn't index arbitrary folders. It composes **scopes**: a project vault plus
the vaults it inherits, as the `.substrate.toml` at the vault's root declares. One scope spans
several folders, which is why a client asks the engine which scopes exist rather than guessing.

Every note declares a **spine**: `status`, `doc_type`, `confidence` and `domains`. Retrieval filters
and ranks on them, and archived or superseded notes are withheld by default. The fields and their
values are in the engine's [configuration](https://github.com/Ronan-Wood/substrate/blob/main/docs/configuration.md).

**Recorded calls are withheld from retrieval by default.** Scripta's notes are
`document_class: conversation`, and a search returns them only when the caller asks with
`include_sources: true`. The reply always says what it excluded, because silence would read as "no
such call". The app's own surfaces ask for calls; a Claude client has to.

---

## 4. Ingestion

The Library hands documents to the engine, which converts each one to Markdown and puts it through
the same ingest path as a note. PDFs read from their own text layer, and scanned pages and images
go through Apple's document recognizer, so nothing needs installing. Office files, HTML, CSV,
subtitles, email and EPUB convert without models. `substrate formats` lists every format the engine
accepts and every one it refuses.

A PDF or an image can instead go through docling's layout and table models, which render tables as
tables, when Settings → Local model → Document models names a folder holding them. The folder is
checked and never created or downloaded into. If it goes missing, for example on an unplugged
drive, the engine reads documents without the models and says so, rather than refusing them.

The engine refuses a conversion that yields no words. Where a cheap independent reading of the
source exists (Office files, HTML, plain text), it also refuses one that loses more than 5% of the
words that reading finds. For PDFs and images no such reading exists, so coverage is recorded as
unmeasured rather than as a pass. The engine's [ingestion findings](https://github.com/Ronan-Wood/substrate/blob/main/docs/ingestion-findings.md) say
why each gate exists.

---

## 5. Retrieval

BM25 over passages via SQLite FTS5, optionally with a vector arm, query expansion (HyDE) and
reranking. The engine measures each stack against a gold set, and quotes a figure only for a stack
it has measured: change one model and it reports `expected_mrr: null` instead.

Apple's on-device models give every arm with nothing installed. A local Ollama with the default
embedder and the cross-encoder reranker answers paraphrased questions noticeably better. Each reply
states which arms ran and, for a measured stack, its tier. The engine's
[experiments log](https://github.com/Ronan-Wood/substrate/blob/main/EXPERIMENTS.md) holds the
measurements and the conditions behind them.

Two findings shaped the defaults. A cross-encoder replaced a listwise chat-model reranker after a
re-measurement on real vaults (2026-08-10): the listwise arm scored below no reranker at all on
paraphrased questions, and was the slowest of the three. And section routing, which fused passages
from a matching section into the results, was built, measured and switched off, because it pushed
exact answers out of the top results more often than it found new ones.

---

## 6. The honesty machinery

> **Information that exists but does not cross the boundary to its consumer reads as absence — and
> absence reads as fine.**

That is the engine's first [principle](https://github.com/Ronan-Wood/substrate/blob/main/docs/principles.md), and the app is the consumer it protects.
So every reply carries its conditions as fields, and the app renders them rather than paraphrasing
them away:

| field | what it prevents |
|---|---|
| `capabilities` | which arms actually ran — `ran` / `skipped` / `off` / `fell_back`. A lexical-only answer cannot pass as full-stack |
| `expected_mrr` | the measured tier for *this exact stack*; an unmeasured config returns `null`, never a guess |
| `index_version` | what the index was built from — converts silent staleness into detectable staleness |
| `refresh.frozen` | tri-state: `true` a rebuild refused and results are superseded, `false` index and vault agreed, `null` no basis |
| `filters.sources_excluded` | that calls were withheld, so silence cannot read as "no such call" |

`TriStateHonestyTests` and `RenderContractTests` hold the app's decoding and rendering of these to
the engine's golden frames. The engine also refuses to compose a scope if any one note fails its
checks, because a partly composed scope is a silently wrong retrieval set. That is why an edited
note with no `status` stops its whole scope refreshing, and the app shows the scope as frozen.

---

## 7. Packaging

The engine ships **inside the app bundle**, built by a post-build phase on the `Scripta` target
(the engine's `tools/build-bundled-engine`). The engine is a release of its own repository,
[Ronan-Wood/substrate](https://github.com/Ronan-Wood/substrate): `engine.lock` pins its tag, commit
and tarball SHA-256, and `Distribution/fetch-engine` unpacks it into `vendor/substrate`, which the
phase builds. The `engine pin` CI job holds the pin to the release. The app runs the bundled CLI as `substrate serve --socket <path> --writes=granted`, from
`Scripta.app/Contents/Resources/substrate-engine/`. An engine that offers no `refresh` falls back to
`substrate-mcp --socket`, which refreshes nothing, and the Library says so.

| component | size | notes |
|---|---|---|
| Python dependencies | 1.1 GB | `uv sync --frozen --no-dev`; the dev group was ~200 MB of editor tooling |
| precompiled bytecode | 228 MB | 11,515 `.pyc`, bought for import speed |
| vendored interpreter | 79 MB | relocated `python-build-standalone` |
| on-device Swift arms | 406 KB | four binaries, compiled from committed source at build time: embeddings, query expansion, reranking, and document recognition |
| **engine total** | **1.2 GB** | 343 Mach-O, each signed and verified for the hardened runtime (measured 2026-09-16) |

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
| extraction | pdfium · Apple's document recognizer · docling | PDFs and images need no model weights; docling converts Office and web formats, and with its optional models reads PDF layout and tables. Every import is lazy, so the runtime path never loads it |
| embeddings | Ollama, or Apple `NLContextualEmbedding` | the on-device arm needs no install and is not gated on Apple Intelligence |
| reranking | cross-encoder | a model trained on the relevance judgment rather than a chat model improvising one |
| transport | JSON-RPC on a Unix socket; MCP over stdio | the app talks to `substrate serve` on the socket, `--writes=granted`; Claude clients run `substrate-mcp`, which connects to the same engine and writes only once allowed in Settings → Clients |
| build | XcodeGen | targets generated from `project.yml`; sources are a directory sweep, not a hand-maintained list |

### Tests and gates

[CONTRIBUTING.md](CONTRIBUTING.md#tests) lists the test bundles and the CI checks. The engine's tests
are in its own repository.

---

## 9. Deliberate absences

- **No cloud, no account, no telemetry.** Two network calls exist and no others: a model server you
  chose, which must be loopback or a private address — public hosts are refused with no override —
  and the update check, which asks GitHub once a day whether a newer release exists and only after
  you allow it (`SUFeedURL`, `Sources/App/Info.plist`).
- **No auto-recording.** The calendar is informational; recording is always deliberate.
- **No semantic diarization.** Two tracks, physical attribution, labels omitted when one side is
  silent.
- **No open-ended on-device reasoning.** Local models get bounded jobs — topics, query expansion,
  grounded answers with citations. Deep reasoning is handed to a frontier model through MCP.
- **No section routing.** Built, measured, switched off (§5).
- **No refresh while no engine runs.** The engine refreshes itself, and Scripta's engine dies with
  Scripta. A machine where neither Scripta nor a `substrate serve` has run for a week reads a
  week-old index — and reports `frozen: false`, because nothing failed; nothing ran.

---

Related: the engine's [principles](https://github.com/Ronan-Wood/substrate/blob/main/docs/principles.md),
[`Distribution/RELEASING.md`](Distribution/RELEASING.md) (the shipping runbook), and
[`docs/history/`](docs/history/README.md) (dated records, such as the July 2026 spec).
