# Call Transcriber

> Private, on-device transcription for your calls and meetings. A macOS menu-bar app — no account, no cloud, nothing ever leaves your Mac.

Built to replace tools like Granola / Jamie / Fathom without the account-gating, visible meeting bots, or cloud dependency: everything runs locally, transcripts are plain Markdown in a folder you choose (ideally an Obsidian vault), and finished transcripts hand off to Claude for anything smart.

## What it does

- **Menu-bar app** — a waveform icon; no Dock icon, no login. Start/Stop is fully manual by design.
- **Captures both sides** — system audio (the other participants) via ScreenCaptureKit + your microphone via AVAudioEngine, as **separate tracks**.
- **Transcribes on-device** — Apple's `SpeechTranscriber` (macOS 26). No model download, no bundled binary.
- **Speaker labels (You / Them)** — the two tracks are transcribed *separately* and interleaved by timestamp, so attribution is physical (mic = You, system = Them), not an ML guess. When only one side has audio (in-person recording), labels are omitted rather than guessed.
- **Cleans + enriches** — deterministic filler-word removal ("um"/"uh"); optional on-device **title + summary + topic tags** via Apple Foundation Models (topics power concept search).
- **Screen context** — periodically OCRs your frontmost window (tables → Markdown via `RecognizeDocumentsRequest`) and interleaves it into the transcript, timestamped. Screenshots are discarded immediately.
- **Markdown output** — YAML frontmatter (date, time, duration, participants, tags, title) + timestamped body, written to a user-chosen folder.
- **Name your calls** — an optional post-record prompt (and an "Edit Details" action in the viewer) sets the title + participants in frontmatter; participants power the MCP's "calls with …" search. When Calendar is enabled, the prompt **pre-fills participants (and the call name) from the meeting you were in** — matched by overlapping time.
- **Calendar visibility** — EventKit shows upcoming Zoom/Teams/Meet events in the menu (informational only, never auto-records), with a proximity badge on the icon (white ≤30 min → yellow ≤15 → green ≤5).
- **In-app viewer** — searchable browser with a purpose-built renderer for the transcript format.
- **Retrieval backend** — a local SQLite/FTS5 index over all transcripts (built behind the scenes, `.md` stays source of truth). Search is **holistic**: one query matches spoken passages *and* transcript topic (title, summary, participants, and Foundation-Models-extracted concept tags), so searching `baseball` finds a call that only ever said "home runs." An in-app **Search** window (⌘F) ranks results with People/Tags index sidebars; the MCP exposes the same index to Claude (`retrieve`, `people`, `tags`). Semantic vectors are a pluggable, deferred slot (on-device embedders measured too weak — the concept-tag path fills the gap instead).
- **Claude integration** — a bundled MCP server + a skill let Claude read, search, and reason over your transcripts (see below).
- **Retention** — optional auto-delete of old transcripts, gated so it only ever touches files this app created.

## Requirements

- **macOS 26** or later, Apple Silicon. (The floor is 26 for the document/table recognizer and Foundation Models — kept deliberately for quality.)
- **Apple Intelligence** enabled is optional — only the title/summary feature needs it; without it, that feature quietly switches off.

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
                     TranscriptEnricher (Foundation Models: title + summary, optional)
                              │
                     TranscriptWriter → Markdown + frontmatter → output folder
                              │
                     raw audio deleted (ephemeral, always)
```

In parallel during recording: `ScreenContextCapturer` ticks every N seconds → resolves the frontmost window → `SCScreenshotManager` → `DocumentReader` (`RecognizeDocumentsRequest`) → `SnippetDeduplicator` (Jaccard similarity) → timestamped snippets, folded into the transcript. Images are discarded after OCR.

### Source layout

| Area | Files |
|---|---|
| App shell | `App/` — `main.swift`, `AppDelegate.swift`, `MenuController.swift` (3-state icon + proximity badge) |
| Capture | `Recording/` — `SystemAudioCapture` (SCStream), `MicrophoneCapture` (AVAudioEngine), `AudioConverter` (per-track → 16 kHz mono WAV), `RecordingSession` (orchestration + ephemeral temp) |
| Transcription | `Transcription/` — `SpeechEngine` (SpeechTranscriber), `FillerCleaner`, `TranscriptEnricher` (Foundation Models), `TranscriptWriter` |
| Screen context | `ScreenContext/` — `ScreenContextCapturer`, `FrontmostWindowResolver`, `DocumentReader`, `SnippetDeduplicator` |
| Settings | `Settings/` — `AppSettings` (UserDefaults), `SettingsView` |
| Viewer | `Viewer/` — `TranscriptStore`, `TranscriptParser`, `TranscriptViewer`, `TranscriptDetailsEditor` + `TranscriptMetadataEditor` (edit title/participants in frontmatter) |
| Retrieval | `Index/` — `IndexStore` (SQLite + FTS5, search/people/tags), `IndexBuilder` (parse `.md` → speaker-turn chunks; reconcile), `SearchView` (in-app search + index sidebars) |
| Calendar | `Calendar/` — `CalendarWatcher` (EventKit) |
| Help | `Help/` — `HelpView` (setup docs, one-click MCP command + skill install) |
| Support | `Support/` — `RetentionPruner`, `NotificationManager`, `Permissions` |
| MCP server | `SourcesMCP/main.swift` — separate `calltranscriber-mcp` tool target, embedded in the app |
| Skill | `Skill/call-transcriber/SKILL.md` — bundled + installable to `~/.claude/skills` |

Two build targets (via `project.yml` / XcodeGen): the **app** (macOS 26) and **`calltranscriber-mcp`** (macOS 14, pure Foundation), the latter copied into `Contents/MacOS/`.

## Claude integration (MCP + skill)

The app bundles a dependency-free **MCP server** (`calltranscriber-mcp`, JSON-RPC over stdio) that exposes transcripts read-only to Claude Code / Desktop / Cowork:

- `overview` — every call's title + summary + path (a compact map for Claude to find the right call semantically)
- `list_transcripts(limit, since, participant, tag)`, `get_transcript(path)`, `search_transcripts(query)`
- `retrieve(query, participant?, tag?, since?, limit?)` — BM25-ranked passages from the SQLite index, with call/timestamp/speaker; `people` and `tags` — aggregate indexes (name → call count).
- Path-guarded: it can only read app-authored transcripts inside the output folder, never arbitrary files. The index tools read the app's SQLite index read-only.

Register it: `claude mcp add calltranscriber -- "/Applications/CallTranscriber.app/Contents/MacOS/calltranscriber-mcp"` (the Help window shows the exact path for your machine). Then the bundled skill teaches Claude the playbooks ("summarize my week", "action items across calls", "what did X say about Y").

**Why this design:** the on-device 3B model can't do reliable semantic retrieval over a call history, but Claude can. So the app doesn't try — it exposes the content well via MCP and lets Claude (a frontier model) do the reasoning. That's the app's whole "capture locally, hand off to Claude" philosophy.

## Building

```sh
brew install xcodegen                       # once
cd CallTranscriber
xcodegen generate                           # after any project.yml change
xcodebuild -project CallTranscriber.xcodeproj -target CallTranscriber -configuration Debug -allowProvisioningUpdates build
open build/Debug/CallTranscriber.app
```

Signing uses an Apple Development cert (team `6CTH5M9UWZ`) via automatic signing.

## Distribution

Free route (personal cert, not notarized): build Release, stage app + an `/Applications` symlink + `README.txt`, package with `hdiutil` → `dist/CallTranscriber.dmg`. Recipients drag to Applications and **right-click → Open** once (Gatekeeper, since it's not notarized). See `dist/` for the current build.

Optional maturity: notarization ($99 Developer ID → clean double-click) and Sparkle auto-update. **Not** TestFlight — it requires the App Sandbox, which breaks screen capture and the arbitrary output folder.

## Design principles

- **Everything local.** No login, no cloud, no servers. Raw audio and screenshots are always ephemeral (deleted right after processing); only text is kept.
- **Manual trigger only.** No auto-record. Calendar is informational; recording is always a deliberate click.
- **Hand off to Claude, don't reinvent it.** No heavy in-app LLM reasoning — the app captures and structures; Claude (via MCP) does semantic search, synthesis, and Q&A.
- **Never touch files we didn't create.** The output folder may live inside a real Obsidian vault, so retention/listing key on an `app: call-transcriber` frontmatter marker.
- **Quality over reach** on the OS floor: macOS 26 unlocks the table recognizer + Foundation Models + `SpeechTranscriber`; we kept the floor there rather than water the features down.

## Roadmap

See `SPEC.md` for the full log. Next candidates:

- **Semantic retrieval (Phase B)** — the vector slot in the index, once an on-device embedder (or local reranker) beats keyword on a real eval. Today's `NLContextualEmbedding` measured too weak to trust; the hybrid pipeline is ready for a drop-in.
- **Live transcription** — SpeechAnalyzer streams volatile results, so a live transcript view during recording is now possible (whisper couldn't).
- **Richer AI** — auto action-items / topics / tags via Foundation Models.
- Menu-bar UX (timer, level meter, hotkey), transcript export, notarization + auto-update.

## Status

v1.0 built and packaged (`dist/CallTranscriber.dmg`). Transcription engine switched from bundled whisper.cpp to Apple `SpeechTranscriber` — **confirmed working in a real in-app recording (2026-07-14)**, including a locale-resolution fix (`SpeechEngine.resolvedLocale()`; supported locales are region-qualified BCP-47, so bare `en` had to be matched to `en-US`). **Speaker labels (You/Them)**, **call details (M10)** with calendar pre-fill, and a **local retrieval backend** (SQLite/FTS5 index + in-app Search + MCP `retrieve`/`people`/`tags`) all implemented and verified over real transcripts; the details/label features are pending confirmation on a fresh recording. Semantic vectors deferred (on-device embedders measured too weak).
