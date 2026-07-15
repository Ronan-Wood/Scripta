# Call Transcriber — Spec (living document)

macOS menu bar app for local, private capture + transcription of video calls and in-person
conversations. No login, no cloud, no bots. Transcripts are Markdown files with Obsidian
frontmatter, written to a user-configured folder (typically inside an Obsidian vault).

## Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Deployment floor | macOS 14 | `SCScreenshotManager` + `requestFullAccessToEvents()` are 14+; removes two fallback paths |
| Language / UI | Swift; AppKit menu bar + SwiftUI Settings/Viewer windows | `NSStatusItem`/`NSMenu` battle-tested for dynamic menus; SwiftUI for forms/content |
| Project | XcodeGen (`project.yml` is source of truth, `.xcodeproj` disposable) | Readable diffs, reproducible |
| Mic capture | AVAudioEngine (NOT ScreenCaptureKit) | SCK native mic capture is macOS 15+ |
| System audio | SCStream audio-only, `excludesCurrentProcessAudio = true` | 13+, no virtual driver |
| Audio mixing | Two separate files during session; offline mix to 16 kHz mono after stop | Avoids live two-clock drift/glitch problem |
| Whisper model | `ggml-large-v3-turbo` (~1.6 GB) | Same footprint as medium.en, large-class accuracy, ~5× faster on Apple Silicon |
| Model storage | `~/Library/Application Support/CallTranscriber/models/`, NOT bundled | Keeps .app small, signing fast |
| Raw audio deletion | Only after transcript verified written + non-empty; failures left for launch-time temp sweep | Spec says delete after *successful* transcription |
| OCR dedup | Line-level similarity (Jaccard over normalized lines, ~0.85 threshold), persist changed lines | Exact hash too brittle (live clocks/tickers) |
| Signing | **Apple Development cert** (chosen 2026-07-13; free, via Xcode → Accounts; also enables later notarization) | Stable identity so TCC grants survive rebuilds |
| Sandbox | Off | Screen recording + arbitrary output folder + spawning whisper binary |
| Known cost (accepted) | macOS 15+ re-prompts monthly for screen-recording permission; cannot be disabled | One click/month |

## Non-negotiable invariants

- Raw audio and screenshots are ALWAYS ephemeral (true temp dir; launch-time orphan sweep). No setting changes this.
- Only extracted OCR text is retained, never images.
- No network calls for transcription/OCR. No summarization/LLM features in-app. The app
  never *calls* an LLM; LLM clients may call the app via the bundled MCP server (M8) —
  the app is a passive local data provider only.
- Recording start/stop is fully manual. Calendar visibility (M6) is informational only.
- Retention pruner deletes ONLY app-authored files (frontmatter marker `app: call-transcriber` AND filename pattern match), never recurses — output folder may live inside a real vault.
- No in-app consent/disclosure feature; user discloses verbally.

## Milestones

1. ✅ **Menu bar shell** — LSUIElement, NSStatusItem, start/stop icon state (template mic /
   non-template red `record.circle.fill`), Settings window opens in front via
   `NSApp.activate`. Built + confirmed working 2026-07-13 (red-on-record, Settings in
   front, no Dock/Cmd-Tab presence all verified).
2. ✅ **Audio capture** — SCStream system audio + AVAudioEngine mic → two temp files;
   offline mix to 16 kHz mono WAV on stop. Permission flow (Screen Recording, Microphone).
   `ProcessInfo.beginActivity` to block App Nap during sessions. Launch-time orphan sweep.
   **Verified working 2026-07-13**: both legs confirmed capturing real signal via
   buffer-level meters (mic peak 1.46 — runs hot/clips slightly; system peak 0.75),
   mixed WAV audibly contains both sides. Signed with Apple Development cert (team
   6CTH5M9UWZ). Diagnostic scaffolding removed after verification.
   Headroom/masking follow-up RESOLVED during M3 (AudioMixer level-balances + limits).
3. **Transcription** — whisper.cpp (`whisper-cli` as Process, off-main): model path,
   `--prompt` domain-vocab biasing, output txt. Transcript writer: Obsidian YAML
   frontmatter (date, time, participants, tags, `app: call-transcriber`) + body →
   configured folder. Success-gated raw-audio deletion. UNUserNotification with
   "Reveal in Finder" action (requires .app bundle).
   **Code written + compiles 2026-07-13** (WhisperRunner via `-oj` JSON→timestamped
   segments, TranscriptWriter with YAML frontmatter + `[M:SS]` body, AppSettings,
   NotificationManager, RecordingSession runs mix→transcribe→write→delete pipeline).
   Deps: whisper-cpp 1.9.1 installed (`/opt/homebrew/bin/whisper-cli`); model
   `ggml-large-v3-turbo.bin` downloading to `~/Library/Application Support/CallTranscriber/models/`.
   Default output folder `~/Documents/CallTranscriber` (M5 makes it user-configurable).
   whisper-cli invoked from Homebrew path for now; bundling the binary+dylibs into the
   .app is a distribution-time task.
   **✅ Verified working in a real call 2026-07-13.** Fixes made during verification:
   (a) whisper `-of` path bug (`deletingPathExtension` → `deletingLastPathComponent`;
   was writing JSON into a nonexistent dir). (b) AudioMixer now level-balances each leg
   (peak-normalize to 0.7 with silence-floor guard) then limits the sum — a loud source
   was burying a quieter one (mic voice lost under loud system audio); this both fixes
   masking and resolves the earlier clipping/headroom follow-up.
   Also done early (M5 polish, pulled forward): 3-state menu icon — `waveform` idle /
   red `record.circle.fill` recording / orange `ellipsis.circle.fill` processing, driven
   by explicit MenuController UIState so the processing icon shows during whisper.
4. **Screen context** — every N s (configurable 5–10): `NSWorkspace.frontmostApplication`
   re-resolved per tick → frontmost window (`CGWindowListCopyWindowInfo` z-order, PID match,
   `windowLayer == 0`, exclude own PID) → `SCScreenshotManager.captureImage` (that window
   only) → Vision `VNRecognizeTextRequest` (.accurate, off-main) → similarity dedup →
   timestamped snippet → "Screen Context" section of transcript. Image discarded post-OCR.
   Accepted limitation: only sees the frontmost window, not second monitors.
5. **Polish / Settings** — output folder picker, retention (indefinite / N days + pruner
   on launch + timer), domain vocabulary list, capture interval, calendar toggles.
   Recent Transcripts menu: click → opens in-app viewer (M7); ⌥-click → reveal in Finder.
   Existence-check entries so pruned files don't show.
6. **Calendar visibility (optional)** — EventKit full access, selected-calendars toggle,
   upcoming events with Zoom/Teams/Meet URL patterns shown in menu, informational only.
   Refresh on `EKEventStoreChanged`. `NSCalendarsFullAccessUsageDescription` in Info.plist.
7. **In-app transcript viewer** — read-only window (SwiftUI):
   - Sidebar list of app-authored transcripts from the output folder (date-sorted,
     searchable — filename + full-text).
   - Detail pane: purpose-built renderer for OUR transcript format, not a generic
     markdown engine — frontmatter parsed into a metadata header (date, participants,
     tags), timestamps styled, Screen Context snippets visually distinct (callout style).
   - "Open in default editor" + "Reveal in Finder" buttons for handoff.
   - Strictly read-only: no editing, no annotation — the vault app owns mutation.
   - Depends on M3 output existing; independent of M4–M6, can be built any time after M3.
   - Entry points: Recent Transcripts click, plus a "Transcripts…" menu item.
8. **Bundled MCP server** — LLM clients (Claude Code / Desktop / Cowork) call the app;
   the app initiates nothing.
   - Separate small executable target `calltranscriber-mcp`, embedded in the .app bundle
     (`Contents/MacOS/`), built on the official MCP Swift SDK, **stdio transport** —
     no localhost port, no auth token, zero network surface; spawned per-client.
     Works even when the main app isn't running.
   - Client setup is one line:
     `claude mcp add calltranscriber -- /Applications/CallTranscriber.app/Contents/MacOS/calltranscriber-mcp`
   - Resolves the output folder from the app's UserDefaults domain
     (`com.ronanwood.CallTranscriber`); errors cleanly if unconfigured.
   - **Read-only toolset (v1):**
     - `list_transcripts(limit, since?, participant?, tag?)` → frontmatter metadata + paths
     - `get_transcript(path)` → full markdown
     - `search_transcripts(query)` → matches with surrounding context lines
     - `get_recording_status()` → idle / recording + session start (via a state file the
       app maintains)
   - Serves ONLY app-authored files (frontmatter marker check) — it must not become a
     second door into the rest of a vault the output folder happens to live in.
   - **No start/stop-recording tools in v1** — preserves the manual-trigger invariant.
     If ever added, behind a Settings toggle, default off.
   - Depends on M3 (needs transcripts to serve); independent of M4–M7.

## Build commands

```sh
cd CallTranscriber
xcodegen generate           # after any project.yml change
xcodebuild -project CallTranscriber.xcodeproj -target CallTranscriber -configuration Debug build
open build/Debug/CallTranscriber.app
```

Tooling still needed: whisper-cpp (M3), ggml-large-v3-turbo download (M3).
Xcode MCP registered in Claude Code (`xcrun mcpbridge`); needs Xcode restart after
enabling Settings → Intelligence → external agents (blocked on simulator download finishing).

## Roadmap — candidate milestones (post-1.0)

M1–M8 + distribution (`.dmg`) shipped 2026-07-13. Candidates to beef it up, priority-ordered:

9. ✅ **Speaker labels (You / Them)** — *implemented 2026-07-14 (see entry below).* Transcribe
   the mic and system tracks **separately** and interleave by timestamp, labeling mic = "You",
   system = "Them". Attribution is reliable because the split is *physical*, not an ML guess.
   Caveat: the far side is "Them" collectively on a group call, not individual names.

10. ✅ **Participant & call metadata** — *implemented 2026-07-14 (see entry below).* Optional
    post-record prompt to name the call / participants, editable in the viewer. Makes
    `participants` non-empty so the MCP's participant filters and "calls with X" queries actually
    work.

11. ✅ **Menu-bar UX** — *implemented 2026-07-14.* Recording **elapsed timer** (menu-bar icon shows
    `● 2:34`; Home record card shows the running time), live **input-level meter** (segmented, in the
    Home record card, from the mic buffer peak), and a global **⌥⌘R** hotkey to start/stop from any
    app (Carbon `RegisterEventHotKey`, no accessibility permission needed). All toggleable in Settings.

12. ✅ **Transcript actions** — *implemented 2026-07-14.* Reader Share menu: **Export as PDF** (paginated,
    NSPrintOperation → save, no panel) / **Export as text**, **Copy summary** / **Copy transcript**; plus
    **Delete** (done earlier). **Pause/resume** mid-recording: paused intervals are dropped from both
    tracks (mic + system + screen context all skip), so they stay aligned with no silent gap; the elapsed
    clock freezes and resumes (start shifted forward), Home + menu-bar show Paused.

13. **Distribution maturity** — notarization ($99 Developer ID → clean double-click, no
    right-click-Open) + auto-update via Sparkle (push versions without re-sending `.dmg`s).
    Worth it once more than a few people use it.

**Live transcription + related-calls (2026-07-14) — implemented.** Validated `SpeechTranscriber`
`.volatileResults` streaming in isolation (partials stream token-by-token, then `isFinal`), incl. the
live **buffer-feed** path (`SpeechAnalyzer.bestAvailableAudioFormat` = 16 kHz mono Int16;
`AsyncStream<AnalyzerInput>` + `analyzer.start(inputSequence:)`). `LiveTranscriber` feeds mic buffers
(via `MicrophoneCapture.onBuffer`) → volatile results → `AppModel.liveFinalized`/`livePartial`. Home
becomes a **recording screen**: live transcript (scrollback, in-progress line faint) + a **"From your
other calls"** panel that searches the index with the recent live text every 5 s and surfaces related
past passages (the payoff of the retrieval backend — instant, local). Runs alongside file capture; the
saved transcript still gets full You/Them on stop. v1 = **mic-only** live (You); live You/Them = v2.
Gated by `AppSettings.liveTranscriptionEnabled` (default on); pauses with the recording.

Explicitly deferred / avoid: **full diarization** (naming individuals on the far side — a
local rabbit hole; You/Them covers most of the value); **auto-record from calendar** (breaks
the deliberate manual-trigger design — calendar stays informational only).

## Transcription engine switch (2026-07-14)

**M3's whisper.cpp was replaced by Apple `SpeechTranscriber`** (macOS 26 Speech framework).
Head-to-head on a jargon-heavy sample showed **parity** (both nailed submarket / SF / NNN /
broker / CBRE / LOI), with Apple cleaner on punctuation and ~3× faster (0.6s). The win is
distribution: the OS manages the speech model, so this **removed the 1.6 GB model download,
the bundled static whisper-cli, `ModelManager`, the Settings model section, and the
record-time model guard** — app dropped to ~4.5 MB, instant first launch.

- API: `SpeechTranscriber` + `SpeechAnalyzer(inputAudioFile:modules:analysisContext:finishAfterFile:)`;
  segments come from `result.range` (CMTimeRange); custom vocab via `AnalysisContext.contextualStrings`;
  model install via `AssetInventory.assetInstallationRequest`. Implemented in `SpeechEngine.swift`
  (moved `TranscriptSegment` there). Added `NSSpeechRecognitionUsageDescription`.
- CLI gotcha (not a real issue): `AVAudioFile.read(into:)` throws `_GenericObjCError.nilError`
  in a bare `swift` script — use `analyzer.analyzeSequence(from:)` / the `inputAudioFile:` init
  which read the file internally. Works fine in the app.
- **✅ Confirmed in a real in-app recording 2026-07-14.** Transcript written; filler cleaning +
  Foundation Models title/summary all landed. No Speech Recognition auth prompt appeared — the
  `SpeechAnalyzer`/`SpeechTranscriber` on-device path does NOT gate on `SFSpeechRecognizer`
  authorization (mic + screen-recording TCC are the only prompts). `NSSpeechRecognitionUsageDescription`
  kept anyway as belt-and-suspenders.
- **Locale bug found + fixed during verification.** `SpeechTranscriber.supportedLocales` are all
  region-qualified BCP-47 (`en-US`, `en-GB`, … 30 locales; bare `en` is NOT in the list). The engine
  was passing the raw `AppSettings.language` default (`"en"`) straight in → the model couldn't be
  reserved → runtime alert *"Unable to reserve unsupported locale"* on Stop (looks auth-ish, isn't).
  Fix: `SpeechEngine.resolvedLocale()` matches the setting against `supportedLocales` — exact BCP-47
  first (honors explicit `en-GB`), else best same-language variant (current region → installed → any),
  else a clear error listing supported locales. Validated in isolation (`en→en-US`, `auto→en-US`,
  `en-GB→en-GB`, `fr→fr-FR`, unknown→error) before wiring in.
- Full project docs now in `README.md`.

## Speaker labels — You / Them (2026-07-14)

**M9 implemented.** The mixdown is gone: each captured track is converted to its own 16 kHz mono
WAV and transcribed separately, then the two segment lists are interleaved by `startMs` (both share
the session's t=0). mic → "You", system → "Them".

- **`AudioMixer` renamed → `AudioConverter`** — it no longer sums two tracks into one; it converts
  one track to the transcription WAV (`prepareTrack(inputURL:outputURL:) -> Float`, returning the
  source peak) and peak-normalizes it. The old level-balance-and-limit summing logic is deleted.
- **Pipeline** (`RecordingSession.stop`): `prepareTrack` ×2 → transcribe each non-silent track →
  merge. Sequential transcription (avoids double locale reservation; trivial cost at turbo speed).
- **In-person / one-sided guard:** labels are applied **only when both tracks have speech**. If just
  one side has audio (in-person recording, or a call where one party is silent) the transcript is
  left **unlabeled** — mislabeling everything "You" when the mic caught the whole room would be worse
  than no label. Detected from each track's peak + non-empty segment list. Both silent → same
  "no audio to transcribe" error as before.
- **Format:** labeled line `**[0:05] You:** text`; unlabeled fallback unchanged (`**[0:05]** text`).
  `TranscriptSegment` gained `speaker: Speaker?` (`enum Speaker { you, them }`). `TranscriptParser`
  extracts the speaker (parses the bold run, splits on `]`); `.audioLine` carries it; the viewer
  renders it as a colored label (You = accent, Them = orange). Old transcripts still parse
  (speaker = nil). Parser verified in isolation across labeled/legacy/H:MM:SS/screen-marker lines.
- **Enricher** now sees `You:`/`Them:` prefixes for better title/summary context.
- **Pending:** confirm on a real 2-person recording (labels land on the right sides, timestamps
  interleave sensibly).

## Call details — participants + title (2026-07-14)

**M10 implemented.** Title + participants are now editable, driving the MCP's `participant` filter
and `search_transcripts` (which already read frontmatter `participants` — they just never matched
because the field was always empty).

- **`TranscriptMetadataEditor.update(url:title:participants:)`** patches the frontmatter **in place**
  and rewrites the `# heading` — **no file rename** (every display surface reads the title from
  frontmatter, not the filename, so a rename would only risk breaking vault backlinks). Body is never
  touched. Verified in isolation, including a transcript with `---` dividers in its Screen Context
  section and a re-edit (no field duplication).
- **`TranscriptDetailsEditor`** (SwiftUI form: title + comma-separated participants) is shared by two
  entry points: an optional **post-record prompt** (modal, no close button so the modal session can't
  strand — Save/Cancel only; gated by `AppSettings.promptForDetails`, default on) and an **"Edit
  Details"** button in the viewer (metadata only — the M7 read-only-body invariant still holds; M10
  explicitly sanctioned metadata editing here). Viewer reloads its list on save.
- **Calendar pre-fill:** when Calendar (M6) is enabled + authorized, the post-record prompt pre-fills
  **participants** (and the title, when there's no AI title) from the calendar event overlapping the
  recording window. `CalendarWatcher.callContext(from:to:)` picks the best-overlapping non-all-day
  event (video-link events preferred, then largest overlap), returning organizer-first attendee names
  with the current user excluded and email fallback when a provider carries no display name. The
  recording window is captured in `MenuController` (start on record, end on stop) and passed to the
  prompt. It's a *pre-fill you confirm/edit*, not a silent write — reflects who was invited, not who
  actually attended. No effect when Calendar is off.
- **Pending:** confirm the round-trip on a real recording (name in the prompt → shows in viewer/Recent
  → `mcp calltranscriber list_transcripts participant:"…"` returns it), and calendar pre-fill against
  a real meeting.

## Local retrieval backend — Phase A + in-app search (2026-07-14)

**Decision to build a custom local RAG backend, phased.** On-device embedders evaluated and found too
weak to trust (see vault "on-device embeddings EVALUATED" — related/unrelated cosine gap ~0.01–0.04,
compressed band; usable as coarse recall only, never as the answer layer). So the backend is a
**hybrid** where the deterministic half carries the load now and the vector half is a pluggable,
deferred slot. Reasoning stays with Claude via MCP.

- **Store:** SQLite (system SQLite 3.51, **FTS5** confirmed compiled in) at
  `~/Library/Application Support/CallTranscriber/index.db`. Tables: `transcripts`, `chunks`,
  `chunks_fts` (external-content FTS5 kept in sync by insert/delete triggers), and an empty
  `chunk_vectors` reserved for Phase B. The `.md` files stay source of truth; the DB is a rebuildable
  cache (nuke + reconcile any time) — never risks the vault.
- **`IndexStore`** (`Sources/Index/`, SQLite via `import SQLite3`): upsert/remove, `search` (OR-of-
  prefix-terms FTS + BM25 + `snippet()`, filtered by participant/tag/date/speaker), `people`/`tags`
  aggregates. Internal lock; WAL for cross-process reads.
- **`IndexBuilder`:** parses `.md` (reuses `TranscriptParser`/`TranscriptStore`) into speaker-turn
  chunks with size (500 char) + time (45 s) budgets so unlabeled/monologue calls don't collapse into
  one chunk. `reconcile()` on launch (mtime diff: add/update/remove). Index-on-write (after the
  details prompt) and index-on-metadata-edit.
- **In-app `SearchView`** (menu **Search…**, ⌘F): two-pane — People/Tags **index** sidebars (click to
  filter) + keyword search with BM25-ranked hits (call, timestamp, speaker chip, highlighted snippet);
  clicking a hit opens the transcript. This is the "make people/tags into indexes" ask, realized.
- **MCP tools** (`retrieve`, `people`, `tags`) read the same DB read-only (`SQLITE_OPEN_READONLY`,
  self-contained SQLite in `SourcesMCP/main.swift`, no shared code with the app). Graceful message if
  the DB isn't built yet.
- **Verified over the 8 real transcripts:** reconcile built 8 transcripts / 23 chunks; FTS search,
  `retrieve`, `people`, `tags` all return correct results via the MCP stdio harness. FTS5 gotcha:
  multi-term MATCH defaults to AND → build queries as OR-of-prefix-terms.
- **Phase B (deferred, gated):** populate `chunk_vectors` + fusion + local reranker only once an
  on-device embedder passes a real eval. In-app UI verification (clicking through Search) pending.

## Holistic concept search — using the local FM for retrieval (2026-07-14)

**Problem (Ronan):** keyword search for "baseball" misses a call that only says "home runs / pitching"
— the FTS blind spot. **On-device fix, validated:** the local FM is weak at ranking/reasoning but
strong at *bounded generation* — "name the topics in this text." Isolated test: given a transcript
that never says "baseball", the FM returned `baseball, sports, inning, bullpen, batting order…`.
(Query *expansion* was tested too and rejected — expanding the word "baseball" gave generic filler
matching none of the real words.)

**Built — holistic fused search** (one query matches every useful signal; the disproven one excluded):
- **Transcript-level FTS** (`transcripts_fts` over title/summary/tags/participants) merged with the
  chunk-level passage FTS in `IndexStore.search` — passage hits rank first, topic-only calls append.
  Immediate win with zero new FM work: "baseball" matches the existing call's *title/summary*
  (verified: chunk search → 0 hits, topic search → the Baseball call).
- **FM concept tags:** `TranscriptDigest` gained `topics: [String]`; new recordings write them into
  frontmatter `tags:`, which the index picks up → concept search + a real tag index. Editable: the
  details editor gained a **Tags** field; `TranscriptMetadataEditor.update` now patches tags too
  (owner marker always preserved; verified in isolation).
- **MCP `retrieve` parity:** same topic-level fusion added to the bundled server (verified:
  `retrieve "baseball"` returns the call via summary match).
- **Deliberately NOT built:** query expansion (measured as noise); vectors (still the deferred slot).
- **Follow-up:** backfill concept tags onto pre-existing transcripts (a one-time FM re-tag pass);
  today they rely on title/summary fusion, which already covers the baseball case.
