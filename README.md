# Scripta

**Private, on-device transcription and recall for your calls and meetings.** No account, no cloud, no meeting bot joining your call. Everything runs on your Mac, and your transcripts are plain Markdown in a folder you choose.

Built as a local alternative to Granola, Jamie and Fathom — the difference is that nothing is uploaded, there is nothing to sign into, and the output is yours in a format that outlives the app.

[**Download the latest release →**](../../releases/latest)

New here? [**Getting started**](GETTING-STARTED.md) walks through installing, your first recording, adding documents, and connecting Claude.

---

## Requirements

- **macOS 26 or later, Apple Silicon.** Not negotiable: Scripta is built on Apple's `SpeechTranscriber`, Foundation Models and document recognizer, which arrive in macOS 26.
- **Apple Intelligence is optional.** Titles and summaries use it when enabled; everything else works without it.

Open the `.dmg` and drag Scripta to Applications. It is signed and notarized, so it opens normally — no right-click, no "unidentified developer" warning. Updates then arrive inside the app, and Scripta asks before its first check.

## What it does

**Records both sides properly.** Your microphone and system audio are captured as *separate tracks* and transcribed independently, so You/Them attribution is a physical fact rather than a diarization model's guess. When only one side has audio, labels are omitted instead of invented. Conference mode records a single unlabelled source for hybrid rooms, where two tracks would otherwise hear the same speech twice.

**Keeps text, not audio.** Raw audio is deleted after transcription. If you use screen context, screenshots are discarded the moment their text has been read.

**Writes Markdown you own.** YAML frontmatter plus a timestamped body, into a folder you pick — point it at an Obsidian vault if you keep one. Scripta only ever touches files it created, identified by a marker inside the file *and* its filename shape.

**Answers questions over your own material.** Ask retrieves from your calls, notes and documents and cites what it used. Every answer records what actually ran, so a degraded answer says so rather than quietly being worse.

**Takes your documents too.** The Library ingests PDF, Word, PowerPoint, Excel, HTML, CSV, subtitles, email, plain text and images, and files them alongside your calls so they answer together. Extraction is on-device with nothing to install: a PDF is read from its own text, and Apple's text recognition reads scans and images. If you keep docling's layout and table models, point Settings at their folder and tables read better.

**Talks to Claude.** The bundled engine is an MCP server, so Claude Code and Claude Desktop can search and reason over your corpus. Small local models do bounded jobs; a frontier model does the deep reasoning, and only when you ask it to.

## Privacy

This is the point of the project, so it is specific rather than a slogan:

- **No network calls except to a model server you chose, and the update check if you allow it.** Model servers are loopback and LAN only — public hosts are refused with no override. The update check asks GitHub once a day whether a newer release exists; it sends your IP address and Scripta's version, and Scripta asks before the first one.
- **No account, no telemetry, no analytics.** There is no server of ours to talk to.
- **Raw audio and screenshots are always ephemeral.** Only text is kept.
- **Recording is always manual.** The calendar is informational; nothing auto-records.
- **Workspaces are a real boundary.** Retrieval, Ask and the MCP server are scoped to the active workspace, and a reply states what was withheld rather than silently omitting it.

## How it works

Two programs meeting at one place — a folder of Markdown:

```
Scripta (Swift/SwiftUI)              substrate (Python)
  capture → transcribe → write ──→ *.md ──→ ingest → chunk → index → retrieve
                          ▲                                            │
                          └───────── JSON-RPC on loopback ─────────────┘
                                              │
                                     MCP ─────┴───→ Claude
```

The app never queries an index directly and the engine never knows what a microphone is, so either can be replaced without touching the other. The index is a rebuildable cache; the Markdown is the source of truth.

Retrieval is BM25 over SQLite FTS5, with optional embeddings, query expansion and cross-encoder reranking. Which arms run is measured rather than assumed — change a model and the engine reports the configuration as unmeasured instead of quoting a number that no longer applies.

**[`ARCHITECTURE.md`](ARCHITECTURE.md) is the full technical document**: the vault contract, the ingestion gates, the retrieval measurements, and the packaging.

## Optional: better answers

Everything works with nothing installed, using Apple's on-device models. Point Scripta at a local model server such as [Ollama](https://ollama.com) and answers to paraphrased questions improve noticeably — the gain is largest when your words do not match the words in the note. It stays local either way.

## Building from source

```sh
brew install xcodegen uv
xcodegen generate
xcodebuild -project Scripta.xcodeproj -scheme Scripta build
```

The build vendors a Python runtime and the engine's dependencies into the app bundle, so the first build is slow and later ones skip in seconds unless the engine changed. The first build also compiles OpenCV from source with FFmpeg switched off, because every prebuilt macOS OpenCV bundles a GPL-licensed FFmpeg; uv caches the result, so that happens once per machine. The app itself downloads nothing at runtime apart from the optional update check.

Tests:

```sh
cd Core && swift test                 # app + shared core
cd substrate && uv run pytest tests/  # engine
```

Signing, notarization and stapling are documented in [`Distribution/RELEASING.md`](Distribution/RELEASING.md).

## Project layout

| path | what's in it |
|---|---|
| `Sources/` | the macOS app — capture, transcription, UI, engine supervision |
| `Core/` | local SwiftPM package: parsing, indexing, vault layout, the engine's wire types |
| `substrate/` | the Python engine — ingest, chunking, index, retrieval, MCP server |
| `Distribution/` | release runbook, release scripts, and collateral |

## Status

Working, and in daily use by its author. The newest build is always on the [releases page](../../releases/latest).

Known limits, stated rather than left to be discovered:

- The search index updates while Scripta is **open**. Notes edited elsewhere while it is closed are picked up on the next run.
- Apple Silicon only; there is no Intel build.
- The app bundles its engine, which makes the download large (~600 MB). That is a deliberate trade against fetching anything at runtime.

## License

Scripta is free software, licensed under the [GNU General Public License, version 3](LICENSE). You may use, study, share and modify it. If you distribute it, or a modified version of it, you must do so under the same license and make the corresponding source available.

Third-party components bundled in the app remain under their own licenses. They include Sparkle (MIT), IBM Plex (SIL Open Font License), the Carbon icons (Apache 2.0), the Python runtime (PSF License), and the engine's Python dependencies.
