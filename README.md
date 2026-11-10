# Scripta

[![tests](https://github.com/Ronan-Wood/Scripta/actions/workflows/tests.yml/badge.svg?branch=main)](https://github.com/Ronan-Wood/Scripta/actions/workflows/tests.yml)
[![code scanning](https://github.com/Ronan-Wood/Scripta/actions/workflows/codeql.yml/badge.svg?branch=main)](https://github.com/Ronan-Wood/Scripta/actions/workflows/codeql.yml)
[![release](https://img.shields.io/github/v/release/Ronan-Wood/Scripta?sort=semver)](https://github.com/Ronan-Wood/Scripta/releases/latest)
[![licence: GPL-3.0-or-later](https://img.shields.io/badge/licence-GPL--3.0--or--later-blue)](LICENSE)
![macOS 26+, Apple silicon](https://img.shields.io/badge/macOS-26%2B%20·%20Apple%20silicon-lightgrey)

**A macOS app that records and transcribes your calls and meetings into Markdown, on your Mac.**
No account, no cloud service of ours, and no meeting bot joining your call. Transcripts are plain Markdown in a
folder you choose, such as an Obsidian vault, and you can ask questions over them, your notes and
your documents, from the app or from Claude.

Scripta is the interface. The search underneath is
[**substrate**](https://github.com/Ronan-Wood/substrate), an open-source engine for Markdown vaults
that lives in its own repository. Scripta bundles a pinned release of it, runs it while the app is
open, and shares it with Claude over MCP.

It's built as a local alternative to Granola, Jamie and Fathom. Nothing is uploaded unless you
choose a service that does, there is nothing to sign into, and the output is yours in a format that
outlives the app.

<!-- Screenshots, made from the synthetic calls in Eval/corpus, never real ones:
![The Hub's Home pane, ready to record](docs/screenshots/home.png)
![A call transcript with You and Them labels](docs/screenshots/transcript.png)
![Ask answering with citations](docs/screenshots/ask.png)
-->

## Install

1. You need **macOS 26 or later on Apple silicon**. Apple Intelligence is optional: titles and
   summaries use it when it's on, and everything else works without it.
2. Download `Scripta-<version>.dmg` from the
   [**latest release**](https://github.com/Ronan-Wood/Scripta/releases/latest).
3. Open it and drag **Scripta** into **Applications**. The app is signed with a Developer ID and
   notarized by Apple, so it opens normally.

**Updates arrive inside the app**, through [Sparkle](https://sparkle-project.org). On its second
launch Scripta asks whether it may check for updates. If you agree, it checks GitHub once a day.
Every update is signed, and the app refuses one that isn't. **Check for Updates…** in the menu-bar
menu checks on demand.

## Quickstart

1. **Choose where transcripts go.** On first launch, **Use Default** saves them to
   `Documents/Scripta`. **Choose Folder…** picks another, such as a folder in your Obsidian vault.
2. **Record a call.** Press **⌥⌘R** from any app, or **Start recording** on the Home pane. Allow the
   microphone and Screen Recording when asked: macOS puts system audio behind Screen Recording, and
   that's how the other side of the call is captured. Press **⌥⌘R** again to stop.
3. **Read it.** The transcript is in **Calls**, and as a Markdown file in your folder, with You and
   Them labelled from separate tracks.
4. **Ask about it.** Open **Ask** and type a question in your own words. The answer cites the calls,
   notes and documents it used.
5. **Connect Claude (optional).** The Docs pane, under **Claude & MCP**, has the command for Claude
   Code and a button for Claude Desktop.

[**Getting started**](docs/getting-started.md) walks through each step, recording modes, workspaces,
adding documents and fixing common problems.

## What it does

**Records both sides properly.** Your microphone and system audio are captured as *separate tracks*
and transcribed independently, so You/Them attribution is a physical fact rather than a diarization
model's guess. When only one side has audio, labels are omitted instead of invented. Conference mode
records a single unlabelled source for hybrid rooms, where two tracks would otherwise hear the same
speech twice.

**Keeps text, not audio.** Raw audio is deleted after transcription. If you use screen context,
screenshots are discarded once their text has been read, or after the call's captioning pass if
you set up a vision model.

**Writes Markdown you own.** YAML frontmatter plus a timestamped body, into a folder you pick.
Retention cleanup only deletes transcripts Scripta wrote, identified by a marker inside the file
*and* its filename shape. Deleting a workspace removes the folder Scripta made for it, including
anything you added inside, and the confirmation says how many other files that is.

**Answers questions over your own material.** Ask retrieves from your calls, notes and documents and
cites what it used. Every answer records what actually ran, so a degraded answer says so rather than
quietly being worse.

**Takes your documents too.** The Library takes PDF, Word, PowerPoint, Excel, HTML, Markdown, CSV,
subtitles, email, EPUB and images, and files them alongside your calls so they answer together.
Extraction is on-device with nothing to install: a PDF is read from its own text, and Apple's text
recognition reads scans and images. If you keep docling's layout and table models, point Settings
at their folder and tables read better.

**Talks to Claude.** The bundled engine is an MCP server, so Claude Code and Claude Desktop can
search and reason over your corpus. Small local models do bounded jobs; a frontier model does the
deep reasoning, and only when you ask it to.

## Privacy

This is the point of the project, so it is specific rather than a slogan:

- **No network calls except to a model server you chose, and the update check if you allow it.**
  Model servers are loopback and LAN only — public hosts are refused with no override. The update
  check asks GitHub once a day whether a newer release exists; it sends your IP address and
  Scripta's version, and Scripta asks before the first one.
- **Two choices send content off your Mac, and both are yours to make.** A model your local server
  runs in its cloud, marked *(cloud)* in Settings, receives what it processes. Auto never picks one,
  and Search never uses one. Claude, once you connect it, sends the passages it retrieves to
  Anthropic under your own account.
- **No account, no telemetry, no analytics.** There is no server of ours to talk to.
- **Raw audio and screenshots are always ephemeral.** They are deleted after the call. Only text is
  kept.
- **Recording is always manual.** The calendar is informational; nothing auto-records.
- **Workspaces are a real boundary.** Retrieval, Ask and the MCP server are scoped to the active
  workspace and the vaults it inherits, and a reply states what was withheld rather than silently
  omitting it.

The [privacy policy](Distribution/privacy-policy.md) is the full statement, and
[SECURITY.md](SECURITY.md) says what the app defends and how to report a problem.

## How it works

Two programs meeting at one place — a folder of Markdown:

```
Scripta (Swift/SwiftUI)              substrate (Python)
  capture → transcribe → write ──→ *.md ──→ ingest → chunk → index → retrieve
                          ▲                                            │
                          └────── JSON-RPC on a Unix socket ───────────┘
                                              │
                                     MCP ─────┴───→ Claude
```

The app never queries an index directly and the engine never knows what a microphone is, so either
can be replaced without touching the other. The index is a rebuildable cache; the Markdown is the
source of truth.

Retrieval is BM25 over SQLite FTS5, with optional embeddings, query expansion and cross-encoder
reranking. Which arms run is measured rather than assumed — change a model and the engine reports
the configuration as unmeasured instead of quoting a number that no longer applies.

Everything works with Apple's on-device models. Point Scripta at a local model server such as
[Ollama](https://ollama.com) and answers to loosely worded questions improve noticeably.

[`ARCHITECTURE.md`](ARCHITECTURE.md) is the technical document: the engine boundary, capture, the
vault contract, retrieval, and the packaging. [`docs/`](docs/README.md) lists every document.

## The engine pin

The engine is a release of [Ronan-Wood/substrate](https://github.com/Ronan-Wood/substrate). Its
source is never copied into this repository; only its contract is, for the wire tests.
`engine.lock` names the release: its tag, commit, tarball,
the tarball's SHA-256, and the wire version this app speaks. `Distribution/fetch-engine` downloads
that tarball, checks it against the lock and unpacks it into `vendor/`, which git ignores; the Xcode
build never downloads. The `engine pin` CI job holds the lock to the signed release tag, and
`fetch-engine --bump vX.Y.Z` moves it. [`Distribution/RELEASING.md`](Distribution/RELEASING.md#the-engine-is-a-pinned-release)
has every check. Each Scripta release attaches its own source and the engine tarball it was built
from.

## Building from source

On a Mac with macOS 26 and Xcode:

```sh
brew install xcodegen uv
```
```sh
Distribution/fetch-engine
```
```sh
xcodegen generate
```
```sh
xcodebuild -project Scripta.xcodeproj -scheme Scripta -configuration Debug build
```
```sh
cd Core && swift test
```

Debug builds sign with the maintainer's team, so on your own Mac read
[CONTRIBUTING.md](CONTRIBUTING.md#build-and-run) first. The first build is slow, because it builds
the engine into the app bundle. The app itself downloads
nothing at runtime apart from the optional update check. [CONTRIBUTING.md](CONTRIBUTING.md) covers
the build, the two test bundles, CI and how a change lands, and
[`Distribution/RELEASING.md`](Distribution/RELEASING.md) covers signing, notarization and
publishing.

## Repository layout

| path | what's in it |
|---|---|
| `Sources/` | the macOS app: capture, transcription, the Hub, Ask, the Library, settings, and running the engine |
| `Core/` | a local SwiftPM package. `ScriptaCore` (parsing, vault layout, retention), `ScriptaShared`, and `SubstrateKit` (the engine's wire types), with their tests |
| `Core/Tests/EngineContract/` | a copy of the pinned engine release's contract, which the wire tests decode |
| `Resources/` | fonts, icons and the licences of what the app bundles |
| `Skill/` | the Claude skill the app can install |
| `Eval/` | the retrieval eval and its synthetic corpus |
| `Distribution/` | the release scripts, `fetch-engine`, the release runbook and the privacy policy |
| `docs/` | the [documentation index](docs/README.md), the [user guide](docs/getting-started.md) and [dated records](docs/history/README.md) |
| `engine.lock` | the engine release the app is built from |
| `project.yml` | the Xcode project, which `xcodegen generate` writes |

## Status

Working, and in daily use by its author. [CHANGELOG.md](CHANGELOG.md) lists what each release
changed.

Known limits, stated rather than left to be discovered:

- The search index updates while Scripta is **open**. Notes edited elsewhere while it is closed are
  picked up on the next run.
- Apple Silicon only; there is no Intel build.
- The app bundles its engine, so the download is a few hundred megabytes and the installed app is
  over 1 GB. That is a deliberate trade against fetching anything at runtime.

## Contributing

Bug reports, ideas and pull requests are welcome. Start with [CONTRIBUTING.md](CONTRIBUTING.md), and
use the [issue forms](https://github.com/Ronan-Wood/Scripta/issues/new/choose). Problems with search
itself may belong to [the engine](https://github.com/Ronan-Wood/substrate/issues). Security
problems go privately, as [SECURITY.md](SECURITY.md) says.

## How it is built

Built with help from Claude (Anthropic) via Claude Code; every change is reviewed and signed by the
author.

## License

Scripta is free software, licensed under the [GNU General Public License, version 3](LICENSE) or, at
your option, any later version. You may use, study, share and modify it. If you distribute it, or a
modified version of it, you must do so under the same license and make the corresponding source
available.

Third-party components bundled in the app remain under their own licenses. They include Sparkle
(MIT), IBM Plex (SIL Open Font License), the Carbon icons (Apache 2.0), the Python runtime (PSF
License), and the engine's Python dependencies.
