# Scripta

> Private, on-device transcription for your calls and meetings. A macOS menu-bar app — no account, no cloud, nothing ever leaves your Mac.

> [!IMPORTANT]
> **This file is stale below the intro. Read [`ARCHITECTURE.md`](ARCHITECTURE.md) instead.**
> It predates Doc 4 and describes several things that no longer exist: a bundled `scripta-mcp`
> helper (deleted, Phase 3), an app "sandboxed in every configuration" (unsandboxed since Doc 3 §1),
> a seven-pane hub (now five), `DocumentImporter` (deleted, Phase 4b), and a Swift `Retriever` with
> a gated vector slot (the whole Swift retrieval stack went in Phase 6). It also never mentions the
> substrate engine, which is now most of the system. Kept until rewritten, because it still records
> the capture design accurately.

Built to replace tools like Granola / Jamie / Fathom without the account-gating, visible meeting bots, or cloud dependency: everything runs locally, transcripts are plain Markdown in a folder you choose (ideally an Obsidian vault), and finished transcripts hand off to Claude for anything smart.

## What it does

- **Menu-bar app** — a waveform icon plus a full hub window (Home / Calls / Meetings / Ask / Knowledge / Settings / Docs). Start/Stop is fully manual by design — a global hotkey (⌥⌘R by default, rebindable in Settings), pause/resume supported.
- **Captures both sides** — system audio (the other participants) via ScreenCaptureKit + your microphone via AVAudioEngine, as **separate tracks**. A **conference mode** captures a single source unlabeled for hybrid in-room/online meetings where both tracks would hear the same speech.
- **Transcribes on-device** — Apple's `SpeechTranscriber` (macOS 26). No model download, no bundled binary. A **live transcript** streams while you record, with a related-past-calls panel beside it.
- **Speaker labels (You / Them)** — the two tracks are transcribed *separately* and interleaved by timestamp, so attribution is physical (mic = You, system = Them), not an ML guess. When only one side has audio, labels are omitted rather than guessed.
- **Cleans + enriches** — deterministic filler-word removal; optional on-device **title + summary + topic tags** via Apple Foundation Models (topics power concept search).
- **Screen context** — periodically OCRs a window or display you choose at record time (tables → Markdown via `RecognizeDocumentsRequest`) and interleaves it into the transcript, timestamped. Screenshots are discarded immediately; an optional local vision model can caption charts OCR can't read (post-call only).
- **Markdown output** — YAML frontmatter (date, time, duration, participants, tags, group, title) + timestamped body, written to a user-chosen folder. Post-record prompt names the call, pre-filled from the overlapping calendar event.
- **Quick Capture** — a second global hotkey (⌥⌘N by default, also rebindable) opens a floating panel to type or dictate a standalone thought — no formal call, no filing decision — straight into the workspace's Captures note.
- **Workspaces (groups)** — calendars can map to groups (work / personal / a client); retrieval, Ask, and the MCP are **hard-scoped** to the active workspace. Cross-workspace search is an explicit, non-sticky action. The MCP refuses queries when the app isn't running rather than trust a stale scope.
- **Retrieval backend** — SQLite/FTS5 index over all transcripts (`.md` stays source of truth; the DB is a rebuildable cache). Search is **holistic**: one query matches spoken passages *and* call topics, so searching `baseball` finds a call that only ever said "home runs." An entity graph (people, companies, places extracted on-device) powers entity-anchored browsing; an FSEvents watcher keeps the index fresh against external edits.
- **Knowledge dashboard** — a dedicated pane turns the entity graph into something to browse, not just search: at-a-glance counts, an AI-synthesized "what's important" blurb over recent activity, entity pages (every call/note/document mentioning a person or topic, plus who else co-occurs with them), open commitments resolved to a confirmed owner with one-click mark-done, standing notes, and imported documents (PDF/PPTX/DOCX/text/images, extracted on-device) read in-app as rendered Markdown or opened in the original app.
- **Ask** — on-device Q&A over your calls (retrieve → grounded Foundation Models answer with cited sources). Claude via MCP remains the deep-reasoning tier.
- **Local model endpoint (advanced, opt-in)** — an OpenAI-format server on loopback/LAN (Ollama / LM Studio) can take over Ask, enrichment, reranking, or embeddings per task. Public hosts are refused with no override; Apple FM is always the default and fallback.
- **Calendar visibility** — EventKit shows upcoming Zoom/Teams/Meet events (informational only, never auto-records), with the menu bar mark's own color signaling proximity to the next one, and a full Meetings calendar (month/week/day) unifying past calls + upcoming meetings.
- **Claude integration** — a bundled MCP server + a skill let Claude read, search, and reason over your transcripts (see below).
- **Retention** — optional auto-delete of old transcripts, gated by marker AND filename shape so it only ever touches files this app created. Export to PDF/text; optional entity-stub mirror into the vault.

## Requirements

- **macOS 26** or later, Apple Silicon. (The floor is 26 for the document/table recognizer, Foundation Models, and `SpeechTranscriber`.)
- **Apple Intelligence** enabled is optional — only the title/summary/topics feature needs it; without it, that feature quietly switches off.

## Architecture

Pipeline, on **Stop**:

```
mic (AVAudioEngine) ──→ AudioConverter → you.wav ──→ SpeechEngine ─┐ ("You")
                        (16 kHz mono WAV, per track)                 ├─→ merge by timestamp
system (SCStream) ────→ AudioConverter → them.wav ─→ SpeechEngine ─┘ ("Them")   → [TranscriptSegment]
                                                                        │  (labels omitted if only one side has audio)
                              ┌─────────────────────────────────────────┘
                              ▼
                     FillerCleaner (deterministic um/uh removal)
                              │
                     TranscriptEnricher (title + summary + topics; Apple FM or local endpoint)
                              │
                     TranscriptWriter → Markdown + frontmatter → output folder → index
                              │
                     raw audio deleted (ephemeral, always)
```

In parallel during recording: live transcription (SpeechAnalyzer volatile results) and `ScreenContextCapturer` ticks every N seconds → chosen window/display → `SCScreenshotManager` → `DocumentReader` → `SnippetDeduplicator` → timestamped snippets. Images are discarded after OCR.

### Source layout

| Area | Files |
|---|---|
| Core package | `Core/` (local SwiftPM, statically linked) — **`ScriptaShared`** (macOS 14; the app↔MCP file/query contract) · **`ScriptaCore`** (parsing, indexing/FTS5, transcript store/writer, entities, retention) · `scripta-eval` + the unit tests (`swift test --package-path Core`) |
| App shell | `App/` — `main.swift`, `AppDelegate` (first-run, folder grant, orphan recovery), `MenuController`, `HubView` + panes, `MCPStateFile` |
| Recording | `Recording/` — `SystemAudioCapture` (SCStream), `MicrophoneCapture` (AVAudioEngine), `AudioConverter`, `RecordingSession`, `RecordingMode` (call/conference) |
| Quick Capture | `Capture/` — `CaptureView` (the floating panel), `CaptureSession`, `MicrophoneTap` (no file ever written), `CaptureStore` |
| Transcription | `Transcription/` — `SpeechEngine`, `LiveTranscriber`, `TranscriptEnricher`, `ConceptBackfill` |
| Screen context | `ScreenContext/` — `ScreenContextCapturer`, `FrontmostWindowResolver`, `DocumentReader`, `SnippetDeduplicator` |
| Model engine | `Engine/` — engine protocols, `AppleFMEngine` (default), `EndpointEngine` + `OpenAIWire` (opt-in local server), `EngineRouter`, `Locality`, `Retriever`, `VLMCaptioner` |
| Index orchestration | `Index/` — `IndexBuilder` (stays app-side: it fuses app inputs — notes, docs, embedder — into the core store) + the entity/watcher `+Live` bridges |
| Calls UI | `Calls/` — `CallsView`, `CalendarView`, `RelatedCallsPanel`/`RelatedItemsPanel`, `RelatedSynthesizer` (FM synthesis over related hits), `SnippetHighlight` |
| Calendar | `Calendar/` — `CalendarWatcher` (EventKit) |
| Knowledge | `Knowledge/` — `KnowledgeView` (the dashboard), `EntityDetailView`, `NoteStore` |
| Documents | `Documents/` — `DocumentImporter` (PDF/PPTX/DOCX/text/image import + on-device extraction) |
| Settings | `Settings/` — `AppSettings` (incl. security-scoped folder bookmark), `SettingsView`, `HotKeyRecorder` |
| Viewer | `Viewer/` — `TranscriptDetail`, details/metadata editors, `TranscriptExporter` |
| Theme | `Theme/` — `CarbonTheme`/`CarbonKit`/`CarbonIcon`, the shared design system used across Knowledge/Calls/Viewer |
| Help | `Help/` — `HelpView`, the in-app Docs pane |
| Support | `Support/` — `NotificationManager`, `Permissions`, `RetentionPruner+Live`, `WorkspaceDeleter` |
| MCP server | `SourcesMCP/main.swift` — separate `scripta-mcp` tool target (links `ScriptaShared`), embedded in the app |
| Skill / Eval | `Skill/scripta/SKILL.md` (bundled) · `Eval/` — gold cases + gates for the package's eval executable (`./Eval/run.sh`) |

Three build targets (via `project.yml` / XcodeGen) over one local package: the **app** (macOS 26, **sandboxed in every configuration**, in two flavors — direct bundles the helper, `Scripta-MAS` must not and scrubs it), **`scripta-mcp`** (macOS 14, unsandboxed — LLM clients spawn it; links `ScriptaShared` so its file/query contract is compiled from the same module as the app's). Rule of thumb: pure data transforms and storage live in `Core/`; anything touching an app-only framework (SwiftUI, AVFoundation/SCKit, EventKit, Vision, FoundationModels) or `AppSettings` stays in `Sources/`, bridged by thin `+Live` extensions living beside their feature area (each in its moved type's former folder). Shared state (`index.db`, `mcp-state.json`) lives in the team App Group container so both processes can reach it across the sandbox boundary; the transcripts folder is accessed through a security-scoped bookmark granted once in Settings.

## Claude integration (MCP + skill)

The app bundles a dependency-free **MCP server** (`scripta-mcp`, JSON-RPC over stdio) that exposes transcripts read-only to Claude Code / Desktop / Cowork:

- `overview` — every call's title + summary + path (bounded pages, `since`/`limit`)
- `list_transcripts(limit, since, participant, tag)`, `get_transcript(path)`, `get_section(path, from, to)`, `search_transcripts(query)`
- `retrieve(query, participant?, tag?, speaker?, since?, limit?)` — BM25-ranked passages with call/timestamp/speaker provenance; `people` and `tags` aggregates.
- `commitments(owner?, limit?)` — open action items extracted from calls, who owes what and from which call. `entity_detail(name)` — one person/topic's page: which calls, notes, and documents mention them and who/what co-occurs, with disambiguation when a name is ambiguous.
- Scoped + guarded: every tool honors the app's active workspace and refuses on a stale heartbeat; path-guarded to app-authored transcripts inside the output folder (symlinks resolved).

Register it: `claude mcp add scripta -- "/Applications/Scripta.app/Contents/MacOS/scripta-mcp"` (the Docs pane shows the exact path for your machine and installs the skill with a one-time `.claude` folder grant). Then the skill teaches Claude the playbooks ("summarize my week", "action items across calls", "what did X say about Y").

**Why this design:** the on-device 3B model can't do reliable semantic retrieval over a call history, but Claude can. So the app doesn't try — it exposes the content well via MCP and lets Claude (a frontier model) do the reasoning. That's the app's whole "capture locally, hand off to Claude" philosophy.

## Building

```sh
brew install xcodegen                       # once
cd Scripta
xcodegen generate                           # after any project.yml change
xcodebuild -project Scripta.xcodeproj -scheme Scripta -configuration Debug -allowProvisioningUpdates build SYMROOT="$(pwd)/build"
open build/Debug/Scripta.app
```

Signing uses an Apple Development cert (team `6CTH5M9UWZ`) via automatic signing. Entitlements: `Sources/App/Scripta.entitlements` (sandbox + mic + calendars + user-selected files + network client) and `SourcesMCP/scripta-mcp.entitlements` (App Group only). Run `./Eval/run.sh` before shipping retrieval changes — it gates recall/MRR and the workspace privacy wall.

## Distribution

**Dual-channel, in progress (2026-07-16):**

- **Mac App Store** — the app is sandboxed and passed a real sandboxed recording (system audio + screen context confirmed). The bundled MCP helper cannot ship in a MAS bundle (embedded executables must inherit the app's sandbox, which breaks external spawning), so the store build will offer it as a separate Developer ID download — packaged as a Claude Code plugin + `.mcpb` bundle that also carries the skill.
- **Direct `.dmg`** — bundles the helper exactly as today; notarization (Developer ID) once the Apple Developer Program enrollment lands. `dist/Scripta.dmg` is a stale pre-hub build; rebuild before sharing.

Both channels remain blocked on the $99 Apple Developer Program membership (store record, Distribution/Developer ID certs, TestFlight).

## Design principles

- **Everything local.** No login, no cloud, no servers. Raw audio and screenshots are always ephemeral; only text is kept. The opt-in model endpoint is loopback/LAN only — public hosts are refused with no override, and the app never downloads model weights.
- **Manual trigger only.** No auto-record. Calendar is informational; recording is always a deliberate click.
- **Hand off to Claude, don't reinvent it.** The app captures and structures; Claude (via MCP) does semantic search, synthesis, and Q&A. On-device models get bounded jobs (topics, grounded Ask), never open-ended reasoning.
- **Never touch files we didn't create.** The output folder may live inside a real Obsidian vault, so retention keys on the `app: call-transcriber` marker AND the app's filename pattern.
- **The privacy wall is total.** Workspace scoping applies inside every query — app, Ask, and MCP alike — and the eval's leak check enforces it.
- **Quality over reach** on the OS floor: macOS 26 unlocks the table recognizer + Foundation Models + `SpeechTranscriber`.

## Roadmap

See `SPEC.md` for the full log. Next:

- **App Store submission** — enrollment, store collateral, MAS build config (helper excluded), review.
- **Claude plugin + `.mcpb` packaging** — one-command install for the MCP server + skill, replacing manual registration.
- **Semantic retrieval (Phase B)** — vector slot + fusion are built and gated; enable only when a local embedder beats keyword on the eval (`NLContextualEmbedding` measured too weak; `nomic-embed-text` untested end-to-end).
- **iPad/iPhone companion (exploratory)** — same Markdown corpus via a synced folder; in-person recording + viewer/Ask; each device rebuilds its own index.

## Status

All planned milestones through the knowledge layer are built: two-track You/Them transcription (Apple `SpeechTranscriber`), live transcription, conference mode, hub UI, holistic retrieval + entity graph, workspaces with a hard privacy wall, model-engine layer (Apple FM default, opt-in local endpoint), eval harness (retrieval gates + leak check). **The knowledge layer was substantially expanded 2026-07-20** (the "brain roadmap"): Quick Capture, a commitments lifecycle (extraction, owner resolution against confirmed identities, mark-done), notes and documents joining the entity graph, entity pages, a Knowledge dashboard (recent-activity synthesis plus commitments/people/topics/vocabulary browsing), an in-app Markdown document reader, and rebindable hotkeys. **App Store prep phase 1 landed 2026-07-16**: sandboxed in all configs, security-scoped folder bookmark, first-launch consent notice + folder choice, App Group for shared index/state, grant-based skill install. Pending a runtime pass on a fresh recording: first-run flow, bookmark persistence across relaunch, MCP against the group container with the app running.
