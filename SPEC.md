# Scripta — Spec (living document)

> Renamed from "Call Transcriber" 2026-07-16 (*verba volant, scripta manent*). Historical
> milestone entries below keep the old name verbatim. On-disk identifiers deliberately kept:
> the `app: call-transcriber` marker, registry filename, entity-mirror markers, App Group ID.

macOS menu bar app for local, private capture + transcription of video calls and in-person
conversations. No login, no cloud, no bots. Transcripts are Markdown files with Obsidian
frontmatter, written to a user-configured folder (typically inside an Obsidian vault).

## Locked decisions

| Decision | Choice | Rationale |
|---|---|---|
| Deployment floor | macOS 26 (raised from 14, 2026-07-13) | `RecognizeDocumentsRequest` tables + Foundation Models + `SpeechTranscriber`; quality over reach |
| Language / UI | Swift; AppKit menu bar + SwiftUI Settings/Viewer windows | `NSStatusItem`/`NSMenu` battle-tested for dynamic menus; SwiftUI for forms/content |
| Project | XcodeGen (`project.yml` is source of truth, `.xcodeproj` disposable) | Readable diffs, reproducible |
| Mic capture | AVAudioEngine (NOT ScreenCaptureKit) | SCK native mic capture is macOS 15+ |
| System audio | SCStream audio-only, `excludesCurrentProcessAudio = true` | 13+, no virtual driver |
| Audio mixing | Two separate files during session; per-track 16 kHz mono WAV after stop (mixdown dropped with You/Them labels, M9) | Avoids live two-clock drift; physical speaker attribution |
| Transcription engine | Apple `SpeechTranscriber` (superseded whisper.cpp + ggml-large-v3-turbo, 2026-07-14) | Parity accuracy, ~3× faster, OS-managed model — no 1.6 GB download, no bundled binary |
| Raw audio deletion | Only after transcript verified written + non-empty; failures left for launch-time temp sweep | Spec says delete after *successful* transcription |
| OCR dedup | Line-level similarity (Jaccard over normalized lines, ~0.85 threshold), persist changed lines | Exact hash too brittle (live clocks/tickers) |
| Signing | **Apple Development cert** (chosen 2026-07-13; free, via Xcode → Accounts; also enables later notarization) | Stable identity so TCC grants survive rebuilds |
| Sandbox | **On, all configs** (flipped 2026-07-16 for App Store; original "Off" rationale obsolete — whisper subprocess gone, SCK capture + screenshots proven sandboxed in a real recording) | Folder via security-scoped bookmark; shared index/state via App Group; MCP helper stays unsandboxed (external spawn) and leaves the MAS bundle at submission |
| Known cost (accepted) | macOS 15+ re-prompts monthly for screen-recording permission; cannot be disabled | One click/month |

## Non-negotiable invariants

- Raw audio and screenshots are ALWAYS ephemeral (true temp dir; launch-time orphan sweep). No setting changes this.
- Only extracted OCR text is retained, never images.
- No network calls for transcription/OCR, and no cloud LLM calls, ever. In-app model use is
  Apple's on-device Foundation Models (default) plus, opt-in, a user-run local server on
  loopback/LAN (Ollama/LM Studio, OpenAI wire format) — public hosts are refused with no
  override, and the app never downloads model weights. LLM clients may additionally call the
  app via the bundled MCP server (M8) — the app stays a passive local data provider there.
- Recording start/stop is fully manual. Calendar visibility (M6) is informational only.
- Retention pruner deletes ONLY app-authored files (frontmatter marker `app: call-transcriber` AND filename pattern match), never recurses — output folder may live inside a real vault.
- Consent stays the user's responsibility; the app discloses nothing to other parties. Amended
  2026-07-16 (App Store prep): a one-time first-launch notice states this and the menu-bar
  indicator always shows recording state — but there is still no per-recording consent UI.
- FM-driven features (digest, notes-merge, commitment extraction (M17), related-items synthesis
  (M18)) are bounded generation only — the model identifies/summarizes/lists, it never acts on
  the world (no messages sent, no events created, nothing pushed to another system). The one
  user-facing mutation among them, marking a commitment done, is a deterministic, user-triggered
  UI action on already-extracted data, not the FM acting agentically.

## Knowledge center + Clovis (2026-07-16, from Ronan's Scripta.dc.html render)

- **Living notes (the vault model):** standing documents in `Notes/` you work out of —
  timestamped entries accumulated across calls, each optionally wikilinked to its source
  transcript. Marker `app: call-transcriber-note` (pruner-proof, transcript-surface-invisible).
  v1 is append-only ("comments mostly"). **Indexed since schema v8** (same day): a note's
  entries index as its searchable text with `kind='note'` — Clovis's Ask context and MCP
  `retrieve` surface them labeled as the user's own words; every call-listing surface
  (digest, counts, aggregates, in-app search topic hits) filters `kind='call'`; the privacy
  wall applies to notes identically (9-check probe).
- **Knowledge pane:** notes shelf + day-grouped cross-call digest (index-served, no file reads)
  + workspace-scoped people/topics rail. "Add to note" on every digest card.
- **Clovis** is the Ask assistant's name. Conversations persist per workspace — the privacy
  wall covers chat history: a workspace's conversations are never listed from another.
- Visual language: the app's Carbon tokens as matured in the Prism DS render (wordmark sidebar,
  stat tiles, tinted record card, toolbar: Clovis · appearance · Record).

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
   - **Read-only toolset (v1):** *(corrected 2026-07-20 — this list had drifted from what
     `SourcesMCP/main.swift` actually registers: `get_recording_status` was never built, and
     five tools added since M8 was first written were never added here.)*
     - `overview(limit?, since?, compact?)` → recent calls newest-first with title/date/
       participants/summary — the recommended first call, before `get_transcript`
     - `list_transcripts(limit, since?, participant?, tag?)` → frontmatter metadata + paths
     - `get_transcript(path)` → full markdown (truncated ~24k chars on very long calls, with
       a pointer to `retrieve`/`get_section` for the rest)
     - `search_transcripts(query)` → matches with surrounding context lines
     - `retrieve(query, participant?, tag?, since?, speaker?, limit?)` → BM25-ranked passages
       over the indexed chunks — the same ranking Clovis/Ask uses
     - `get_section(path, start, end?)` → spoken lines within one time window, instead of the
       whole file
     - `people()` / `tags()` → cross-call aggregates (names / topic tags) for filter discovery
   - Serves ONLY app-authored files (frontmatter marker check) — it must not become a
     second door into the rest of a vault the output folder happens to live in.
   - **No start/stop-recording tools in v1** — preserves the manual-trigger invariant.
     If ever added, behind a Settings toggle, default off.
   - Depends on M3 (needs transcripts to serve); independent of M4–M7.

## Build commands

```sh
cd CallTranscriber
xcodegen generate           # after any project.yml change
xcodebuild -project Scripta.xcodeproj -scheme Scripta -configuration Debug build SYMROOT="$(pwd)/build"
open build/Debug/Scripta.app
# unit tests + retrieval eval live in the Core package:
swift test --package-path Core && ./Eval/run.sh
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

14. **Quick Capture — standalone voice + typed notes** *(ratified 2026-07-19; the brain's
    missing organ — every note path today is call-anchored, and idle ⌥⌘N is a documented silent
    no-op. Full context: vault "Brain Roadmap Candidates").* When idle, ⌥⌘N opens a floating HUD
    panel that is already listening: mic → `MicrophoneTap` (tap-only AVAudioEngine — **no audio
    file; raw audio never touches disk on this path**, stronger than the transcript invariant) →
    `LiveTranscriber` biased with the workspace vocab (domain vocabulary + confirmed aliases +
    term vocab; unlike the live call pane, here the live text IS the artifact) → an **editable**
    text buffer in the panel — type, speak, or both. Newly finalized dictation appends at the
    end of the buffer only, never splicing into an in-progress edit or moving the cursor; the
    in-progress (unfinalized) recognition preview renders separately below the buffer so a live
    update can never clobber a keystroke. **⌘Return saves, Esc discards** — zero filing
    decisions (plain Return is left free to insert a newline). On save:
    `FillerCleaner` (deterministic, always) → FM intent cleanup (apply self-corrections, single
    paragraph — legitimate because a capture is intent, not record; transcripts stay verbatim)
    with fallback to cleaned raw when FM is unavailable → timestamped entry appended to the
    workspace's rolling **"Captures"** note (find-or-create, `call-transcriber-note` marker) →
    `IndexBuilder.indexNote` immediately (`kind='note'`: Clovis/search/MCP see it in seconds).
    During recording, ⌥⌘N keeps its call-note meaning — the two panels are state-gated
    complements; **idle-only** (`.processing` blocked too, not just `.recording`) so it can never
    run a second on-device Speech session alongside the just-stopped call's sequential transcribe
    pass. Menu shows "Quick Capture" only when idle. Mic TCC is the only permission touched.
    **Disclosure:** the menu-bar icon shows a distinct listening state for the duration the
    panel is open (SPEC's "indicator always shows recording state" invariant applies to capture,
    not just call recording).

15. ✅ **Correction → vocabulary loop** *(ratified 2026-07-19 — found already implemented,
    predating this branch: the Knowledge redesign's "Vocabulary (the correction loop's front
    door)" section, `KnowledgeView.swift`, plus a matching "Add to vocabulary" action in the
    transcript reader, `TranscriptDetail.swift`. Both call the same `EntityRegistry.addTerm`,
    confirmed by definition. `KnowledgeView` additionally mines deterministic acronym
    suggestions from the workspace's own calls — frequent ALL-CAPS tokens the registry doesn't
    know yet — as one-tap "teach this" chips, going beyond what this entry originally specced.
    No transcript-body mutation, group-scoped, `syncTerms` refreshes the index cache — matches
    the Wispr "correct once, saved forever" idea point for point.* The one actually-missing
    piece — captures didn't exist before M14, so nothing fed them this bias — closed as a side
    effect of M14's own crosscheck fix, not new work here: `EntityRegistry.recognitionVocab`
    (extracted to kill a 3-way vocab-assembly duplication) is what both `MenuController`'s
    recording path and `CaptureSession` call, so a term taught via either existing UI now biases
    calls AND captures identically. Nothing left to build.

16. **Notes-merge** *(ratified 2026-07-20; vault "Brain Roadmap Candidates" pick #3).* When a
    call had CallNote fragments (the `session.addNote` skeleton typed mid-call — `RecordingSession`
    already threads `notes: [CallNote]` into `produceTranscript`/`TranscriptWriter`), the post-record
    pipeline gains a second FM pass alongside the existing digest generation: transcript body + the
    user's own fragments → a structured note that expands what the user flagged, grounded in the
    transcript (same "don't invent details" discipline as the enrich prompt). **Written as a new,
    auto-created note linked to the call** (`NoteStore.create` + `IndexBuilder.indexNote`,
    `kind='note'`) — never into the transcript itself (verbatim invariant untouched) and distinct
    from Quick Capture's rolling **Captures** note (this is per-call structured output, not a
    miscellaneous-thoughts stream). Skipped entirely when a call has no CallNote fragments — this
    is not "summarize the transcript," which the existing summary field already covers. Reuses:
    the `TranscriptEnricher`/`EngineRouter` FM-call shape, `NoteStore`, index-on-write. New: one
    `PromptCatalog` prompt, one hook beside `TranscriptEnricher.enrich` in
    `RecordingSession.produceTranscript`. Effort M.

17. **Commitments extraction + per-person rollup** *(ratified 2026-07-20; pick #4).* Post-record,
    alongside digest generation: FM bounded generation ("name the commitments/action items and
    who owns each") over the transcript. **Storage is already reserved and unpopulated** —
    `IndexStore`'s `action_items` table (`path, owner_id, text, status`) has existed in the schema
    since it was scaffolded but nothing writes or reads it yet; this milestone is the first to use
    it, so no schema/version bump is needed, only population + queries. Owner resolution is the
    real sub-problem: match the FM's named owner against `EntityRegistry`'s confirmed people to
    get a stable `owner_id` (ties commitments to the same identity People-rail/entity-page surfaces
    already use); when no confirmed entity resolves, fall back to storing the bare surface string
    rather than blocking the whole extraction on a match. Rollup surfaces in the People rail
    (per-person: what's owed to you / what you owe) and a digest card. **Extraction only — no
    agentic follow-through, ever** (deterministic-first rule,
    [[CallTranscriber/2026-07-14 - Decisions - Model Strategy]] in the vault). Effort M, mostly in
    the owner-resolution matching, not the schema (already there).

    **Follow-up (2026-07-20, from a review pass over M14-M19 as a whole):** three real gaps
    closed. (1) A commitment could never be marked resolved — `action_items.status` was written
    once as `"open"` and never changed anywhere; `commitments(group:)` also had no `LIMIT`, unlike
    every sibling query. Fixed with a genuine resolve path: a `" [done]"` suffix round-trips
    through the SAME frontmatter `commitments:` field the text itself lives in (not a DB-only
    status flip — `IndexBuilder` rebuilds `action_items` from that frontmatter on every re-index,
    so a DB-only status would silently revert on the next reconcile or metadata edit), surfaced as
    a checkmark button in both the Commitments rail and the entity page. (2) `EntityDetailView`
    never showed the commitments a person actually owes — an obvious connection between two
    already-shipped features that wasn't made when either landed; wired in by filtering the same
    `commitments(group:)` data by `ownerID`. (3) The SAME unscoped cross-group entity lookup M19's
    own crosscheck found and fixed in `EntityDetailView` was still sitting in `KnowledgeView`'s
    commitment-owner name resolution — closed with the same `EntityRegistry.entity(id:group:)`.
    Also: `summarizeEnabled`'s footer no longer claimed only title/summary are AI-generated (it
    silently governs commitment extraction too), and Home gained an "Open commitments" stat tile,
    closing the "digest card" this entry always said it wanted.

18. **Related-items everywhere, with FM synthesis** *(ratified 2026-07-20; pick #5, expanded from
    the original "generalize the live panel" scope after discussion — Ronan wanted the connection
    itself explained, not just a list of raw hits).* `RelatedCallsPanel` today only exists during
    live recording, querying the index with the in-progress speech every 5s. Generalized: the same
    retrieval (`IndexStore.search`) becomes available on any open transcript/note/doc, querying
    with that item's own content (title + summary/topics, or a body excerpt) instead of live
    speech. **New layer on top:** when retrieval returns ≥2 hits, one additional FM call —
    identical shape to Clovis's own retrieve-then-synthesize pipeline (`EngineRouter`/
    `AppleFMEngine`, a new `PromptCatalog` prompt) — turns the raw hits into 2–3 sentences of
    connective prose ("this connects to two earlier calls about X, where Y was raised and never
    resolved"). **Progressive, not blocking:** raw snippets render immediately from retrieval (as
    today); the synthesized line fills in a beat later once the FM call resolves — opening a
    transcript must never wait on an LLM call. **Grounded, not just asserted:** the raw source
    snippets stay visible beneath the synthesized line, same as Clovis's answer-plus-sources
    pattern (`ClovisDrawer`) — an FM connecting three calls must stay traceable back to them, the
    same discipline the enrich/digest prompts already hold to. Effectively Clovis's synthesis step
    running proactively instead of only on a typed question. Effort S–M.
    **Implemented (2026-07-20), v1 scope:** the reusable pieces (`RelatedHit`, `RelatedItemsPanel`,
    `RelatedSynthesizer`) are query-string-in/hits-out — pluggable anywhere — but only wired into
    the transcript reader (`TranscriptDetail`, query = title + topics) for this pass; notes/docs
    are a same-component fast-follow, not built here (disclosed scope cut, not a silent gap).
    Synthesis reuses `EngineRouter.chatEngine(for: .ask)` (Clovis's own dispatch, one-shot off the
    streaming API) rather than a 4th `EnrichEngine` method — that protocol already picked up a
    grab-bag critique in M17's crosscheck; a related-but-distinct task didn't need to deepen it.

19. **Entity pages** *(ratified 2026-07-20; pick #6 — **corrected 2026-07-20**, see below).* Click
    a person/topic anywhere one appears today (People rail, Tags rail, Vocabulary chips) → a
    detail view: canonical name + aliases + gloss (`EntityRegistry.Entity`, already the trust
    layer — merge verdicts, privacy walls, provenance — Mem's version of this pattern lacked), a
    mention timeline across calls, and co-occurring people/topics. Read-only, no new mutation path
    (brain ≠ editor holds — same invariant as everything else on this list).

    **Correction:** this entry originally claimed `entity_mentions` was reserved-but-unpopulated,
    "like `action_items`." That was wrong — checked before implementing (the M15 lesson: grep
    first) and found the OPPOSITE of M15's surprise. `IndexBuilder.extractEntities` already writes
    `entity_mentions` on every call reconcile (`IndexStore.setEntities`, landed pre-branch via "P4a:
    entity graph"), and two of three query functions already exist and are already used —
    `entities(group:)` and `callsMentioning(entityID:group:)` back `CallsView`'s entity filter
    (comment: "mode 3"). What's genuinely missing, confirmed by search: a detail PAGE (the filter
    only narrows the call list, shows no aliases/gloss/co-occurrence), a co-occurrence query (no
    backend exists for this piece at all), and every stated entry point except the filter menu —
    People/Vocabulary/Commitments rows aren't clickable today. `entityIDs(forPath:)` exists,
    reads correctly, and has zero callers anywhere in the repo — dead code its own doc comment
    promised for transcript entity chips that were never built. Effort scoped down to what's
    actually missing: the view + co-occurrence query + entry points, not full-stack population.

    **Implemented (2026-07-20):** `EntityDetailView` (aliases, gloss, mention timeline via
    `callsMentioning`, co-occurrence via a new `IndexStore.coOccurring(entityID:group:)`), wired
    as a sheet from three real entry points — People rail, Vocabulary chips, the Commitments
    rail's "X owes you" rows (M17) — each now clickable for the first time. Read-only throughout.
    **Disclosed scope cut:** `entityIDs(forPath:)` stays unwired — a 4th entry point (transcript
    entity chips, its own doc comment's original promise) is a natural, small follow-up using
    the same sheet pattern, not built in this pass.

20. **Notes and docs join the entity graph** *(ratified 2026-07-20 — Ronan's "growing brain"
    framing: notes and calls should land on the same person's page, not live in two disconnected
    halves).* `IndexBuilder.indexNote`/`indexDoc` never call entity extraction — only `index()`
    (calls) does. A Quick Capture note that says "talked to Bob about the CPA deal" is fully
    searchable but never appears on Bob's page, and his page never surfaces it. Fix: build
    `[IndexedChunk]` from a note's timestamped entries (one chunk per entry — real per-entry
    timestamps, the same "every mention carries a jump-to-passage timestamp" principle
    `EntityExtractor` already holds calls to) or a doc's body (one chunk), then run the exact
    `EntityExtractor.mentions` → `registry.resolve` → `store.setEntities` path calls already use,
    ledger-gated the same way. `EntityExtractor.mentions(chunks:attendees:)` has no call-specific
    dependency (just `.text`/`.startMs`) — this is a new call site, not new extraction logic.
    `entity_mentions`/`callsMentioning` already carry no `kind='call'` filter, so once populated,
    notes/docs surface in "Mentioned in" without a query change — only the click target needs to
    become kind-aware (`.route = .call(...)` unconditionally is wrong for a note/doc hit). Effort M.

21. **Close the graph's dead ends** *(ratified 2026-07-20; same thread as M20 — a connected graph
    nobody can click through isn't connected).* Three gaps, one theme:
    - **Co-occurring chips are dead ends.** `EntityDetailView`'s "Appears alongside" section renders
      plain `CarbonChip(text:)` — the one part of the entity page that doesn't lead anywhere.
      Wiring it means the sheet retargets in place rather than closing and reopening: M19's
      "mentioned call" click already closes the sheet for a one-hop jump to a transcript, fine
      once, but exploring several connections in a row via close/reopen animations defeats this
      milestone's point. `entityID` becomes `@State` instead of `let`, a small back-stack drives a
      back affordance in the header, a `jumpTo(id:fallbackName:)` re-runs `load()` in place.
    - **TranscriptDetail's participants are plain text.** Reading a call, you can't click a name to
      open their page — the single most expected click target in a transcript reader doesn't work.
      This is the exact gap M19 itself disclosed and deferred (see above). Participants are already
      registry-confirmed at index time (`extractEntities`'s `registry.confirm`), so name→id at
      click time is a lookup, not new inference. Same `EntitySheetTarget`/`.sheet(item:)` pattern
      KnowledgeView already uses.
    - **Tag chips are inconsistent.** KnowledgeView's own rail tags already navigate (`.route =
      .tag(name)`, filtering CallsView) — TranscriptDetail's header tags and DigestCard's per-call
      tags don't. Wiring the same existing action onto both closes the inconsistency. Tags stay
      OUT of the entity/registry system on purpose — this milestone's actual navigational
      principle: clicking an IDENTITY (person/org/term) opens their page; clicking a TAG filters
      the list. Different actions for different concepts, not an oversight.

    **Explicitly out of scope:** a literal node/edge graph-visualization widget — once M20+M21
    land, "see how things connect" is served by fast click-through navigation, a better fit for
    this app's dense/text-forward design than a force-directed graph that looks impressive at 20
    nodes and unreadable at 200; worth reconsidering only if click-through turns out not to be
    enough, not before. Unifying M18's content-similarity "related items" with entity
    co-occurrence — they answer different questions (what's similar vs. who's connected); forcing
    them into one panel would blur both. `linkedCall`'s note→call link staying one-directional (no
    "notes that mention this call" surfaced on the call side) — a real enhancement, but a separate,
    smaller follow-up. CallsView's existing entity filter staying a filter (bulk narrowing), not
    merged into opening a detail page (deep dive) — two legitimate, different actions on the same
    data, matching the tag-vs-identity principle above.

22. **Knowledge dashboard shell** *(ratified 2026-07-20; Ronan: "you need like a dashboard sorta
    see like all that then also like a related to recent / a whats important").* KnowledgeView's
    `body` (confirmed by re-reading it, not assumed) is one flat vertical stack in build order, not
    priority order: `header, notesShelf, documentsSection, (digestColumn | rail), vocabularySection`
    — with `identityCheck` (the collision-review queue) buried as the LAST child inside
    `vocabularySection`, not its own section. Six distinct concerns — your own recent notes,
    imported files, the call log, cross-cutting rollups (commitments/people/topics), the
    vocabulary/correction loop, and a maintenance queue — stacked with no visual hierarchy between
    "here's what happened" and "here's what needs you." Regrouped by purpose instead of shipping
    order:
    - **At-a-glance row**: `StatTile` (already a shared component, `Sources/Theme/CarbonKit.swift`
      — reused as-is, not reimplemented; `HomeView` already proves the pattern with 4 tiles).
      Knowledge's own tiles: open commitments, people tracked, notes count, documents count —
      Knowledge-specific numbers, not a duplicate of Home's calls/hours tiles.
    - **Recent** (the primary content): `digestColumn`, unchanged internally, just no longer
      competing for top billing with notes/documents above it.
    - **Browse**: People + Topics + Vocabulary consolidated — three "look something up by facet"
      surfaces that were previously split across the side rail and a separate bottom section.
    - **Needs attention**: Commitments + Identity check consolidated — both are "only you can
      resolve this," previously scattered (commitments mid-rail, collisions buried at the very
      bottom under Vocabulary where nothing suggested they were related).
    - Notes/Documents become their own area rather than sitting above the actual content.

    **Deliberately staying a single scrollable view, not sub-tabs.** Considered tabs under
    Knowledge (mirroring the hub's own top-level Home/Calls/Knowledge/Settings sections one layer
    down) and rejected for now — this app's dense/scannable single-scroll idiom (Home, Calls) is
    already the established pattern, and a second navigational layer inside one hub section risks
    solving "too much stuff" by hiding it rather than organizing it. Reconsider only if the
    regrouped single scroll still feels overwhelming once it's actually built and used. Effort M —
    structural (grouping existing sections under clearer headers, minimal new visual chrome) plus
    wiring the stat-tile data, not new capability.

23. **"What's important" — recent-activity synthesis** *(ratified 2026-07-20; the other half of
    Ronan's dashboard ask — M22 organizes what's already there, this surfaces what the FM notices
    connecting across it).* `RelatedSynthesizer.synthesize(current: String, hits: [(title: String,
    snippet: String)]) async -> String?` (confirmed: zero view dependency, already used exactly
    once, by `TranscriptDetail` for one open transcript's connections) generalizes directly: build
    `current` from several recent `IndexStore.digest(group:)` rows' `title + " " + tags` (the same
    string-concatenation `TranscriptDetail` already does for one call, just over N), retrieve hits
    for that combined query the normal way, exclude the source paths from the hit set (plain Swift
    filtering against a `Set<String>` in the caller — `RelatedItemsPanel`'s own `excludePath` is a
    single String and isn't touched or extended, since this doesn't go through `RelatedItemsPanel`
    at all, just the bare synthesis function it already calls), then render the resulting sentence
    as a short blurb — no `RelatedHitCard` list, no panel chrome, since `synthesize` has no view
    dependency to drag in. One or two sentences: "The CPA deal came up in 3 of your last 5 calls,"
    not a wall of cards — the digest log right below already IS the detailed view.
    Same discipline M18 already committed to: **progressive, not blocking** (the dashboard's other
    sections render immediately; this fills in a beat later), and **grounded, not just asserted**
    (the FM never invents a connection — `synthesize` only ever describes hits it was actually
    handed, and returns nil below 2 hits rather than force a sentence out of nothing, so a quiet
    workspace shows nothing here instead of an awkward "nothing important" placeholder).
    Deliberately NOT extending `digest(group:)` to cover notes/docs in this pass — it's hard-filtered
    to `kind = 'call'` today; folding notes/docs into "recent activity" is a real fast-follow, not
    built here (same disclosed-cut pattern M18 used for its own notes/docs deferral). Deliberately
    keeping this separate from the at-a-glance stat tiles (M22) rather than one combined FM call —
    exact counts (open commitments, etc.) are deterministic reads, and asking an FM to also produce
    numbers risks it inventing slightly-wrong ones for something that was never actually ambiguous.
    Effort S–M — the synthesis primitive and its FM plumbing already exist; the new work is the
    query-building, hit-fetching, and a small rendering spot on the dashboard.

24. **In-app document reader** *(ratified 2026-07-20; Ronan: "we should probably expand docs a
    bit no?" — clicking an imported document always kicks out to an external app; notes and calls
    both already have real in-app readers, docs is the one content type that doesn't. Follow-up:
    "make sure it can render the markdown too" — see below, this changed the rendering design
    before any of it was built.)* `DocumentImporter.DocMeta.body` is already the full, UNBOUNDED
    extracted text (confirmed — the 60k-char cap only exists on the SQLite index's `summary`
    preview, `IndexBuilder.indexDoc`; entity extraction already runs on the full body, not the
    truncated one) — the same text search/Clovis/MCP already treat as the document's canonical
    content. A new `DocumentDetailView`, modeled on `NoteDetailView` (the closer sibling — your own
    artifact, not a call recording — confirmed a `.sheet`, 560×520) rather than `TranscriptDetail`
    (a full hub-section pane tied to Calls' own master/detail split via `AppModel.route` — doesn't
    fit how documents are reached today, from inside Knowledge).

    **Rendering — Markdown, not plain text (revised).** `DocumentImporter`'s own extraction already
    emits real Markdown structure — `"## Page \(i)"`/`"## Slide \(i)"` section headers
    (`DocumentImporter.swift` pdf/pptx extraction) — so plain `Text(meta.body)` would show literal
    `"## Page 1"` instead of a heading. `NoteDetailView`'s plain-text choice was right for freeform
    entries; wrong for extracted document prose. Design: a lightweight block-level split (blank-line-
    or heading-prefix-delimited paragraphs — headers are trivially `hasPrefix("#")` to detect, no
    real parser needed), each block rendered via `Text(AttributedString(markdown:))` for INLINE
    formatting (bold/italic/code-span/links — Foundation-native, zero new dependencies) at a font
    size keyed to the detected block type (H1/H2/paragraph). Not a full CommonMark renderer — no
    table layout, no nested-list indentation beyond what falls out of rendering each line as its own
    block — proportionate to what this app's own extraction actually produces (headers + prose),
    not a speculative general-purpose Markdown engine. `AttributedString(markdown:)` alone (without
    the block split) was considered and rejected: its `.full` parsing mode tags header structure via
    `PresentationIntent`, but plain `Text` doesn't vary font size from that automatically — you still
    have to do the block-level work yourself to get headers that visually look like headers.

    Header: title, created date, Rename/Delete (matching `NoteDetailView`'s), an explicit "Open
    original" action (external, reusing the same `DocumentImporter.verifiedOriginalURL(...)`
    resolution M21's entity-page doc-mention click already uses) for when the real PDF/PPTX/DOCX is
    actually what's wanted. `documentsSection`'s row tap changes from always-external-open to
    presenting this sheet — consistent with tapping a note or a call already meaning "view it
    in-app," not "hand it to another app."

    **Explicitly out of scope:** a true native renderer (real PDF pages via PDFKit's `PDFView`,
    real PPTX slides) — PDFKit is already a dependency but only for TEXT EXTRACTION
    (`PDFDocument`); `PDFView` (the actual page-rendering view) is entirely unused today, confirmed
    by search. Building one is a real, format-specific undertaking — worth reconsidering only if
    extracted-text-as-prose turns out to lose too much (tables, layout, images) for real use, not
    before. A third-party Markdown package (swift-markdown-ui or similar) — would render tables/
    nested lists properly, but this project has zero remote package dependencies today (confirmed —
    `project.yml`/`Core/Package.swift`), and the hand-rolled block-split covers what this app's own
    extraction actually emits; revisit only if the gap between "what we render" and "what documents
    actually contain" turns out to matter in practice. Surfacing a document's `call:` frontmatter
    link (written at import time when linked from a call, but not currently read back into `DocMeta`
    at all — confirmed, the struct has no field for it) — real, but a separate, small follow-up.
    Effort S–M (was S before the Markdown revision) — reuses `NoteDetailView`'s sheet/header/action
    pattern and `DocumentImporter`'s already-unbounded `body`; the new work is the view, the
    block-split renderer, and retargeting one tap gesture.

25. **Rebindable hotkeys** *(ratified 2026-07-20; Ronan: "the hot keys should be rebindable no?"
    — confirmed first, not assumed: both ⌥⌘R and ⌥⌘N are 100% hardcoded today, Carbon literal
    constants in `HotKeyManager.swift`. `AppSettings.globalHotkeyEnabled` is on/off only, not the
    combo; Settings' one control is a toggle plus static footer text printing the fixed combos; no
    key-recorder UI or third-party package (KeyboardShortcuts/Sauce/HotKey/MASShortcut) exists
    anywhere in the project).* The dispatch layer is already decoupled from the physical key — an
    ID→closure indirection (`onTrigger`/`onNote`) — so rebinding is purely a registration-side
    change; the action-dispatch side needs nothing.
    - A `HotKeyCombo(keyCode: UInt32, modifiers: UInt32)` value type. `AppSettings` gains
      `recordHotkeyCombo`/`quickCaptureHotkeyCombo`, each backed by two new UserDefaults keys
      (keyCode + modifiers as `Int` — matching this file's existing primitive-storage convention,
      no JSON/Codable machinery for something this simple), defaulting to the CURRENT hardcoded
      combos so nobody's shortcut silently changes on upgrade.
    - `HotKeyManager.register()` reads from `AppSettings` instead of literal constants; a new
      `reregister()` (unregister then register — `register()`'s own `handlerRef == nil` guard
      means calling it twice today is a no-op) fires whenever either combo changes in Settings.
    - A new key-combo recorder control — click to enter a "press keys…" state, capture the next
      keyDown via a small first-responder `NSViewRepresentable` overriding `keyDown(with:)`,
      translate AppKit's `NSEvent.ModifierFlags` to Carbon's modifier constants. Used twice, one
      per hotkey.
    - **Validation, enforced before saving:** at least one modifier required (an unmodified letter
      key would hijack ordinary typing system-wide); the two app hotkeys can't be set to the same
      combo as each other (ambiguous, and `RegisterEventHotKey`'s behavior for a duplicate
      registration isn't well-defined). Escape alone, while recording, cancels back to the
      previous value rather than being captured as a binding — the same convention macOS's own
      System Settings shortcut recorder uses.
    - A "Reset to default" action per hotkey, back to ⌥⌘R/⌥⌘N.

    **Explicitly out of scope:** proper keyboard-layout-aware key-name display via
    `UCKeyTranslate`/Text Input Source Services — v1 uses a static keyCode→label dictionary
    (letters/digits/common special keys), layout-independent for CAPTURE (`RegisterEventHotKey`
    already operates on physical keycodes) but could show the wrong LETTER label on a non-QWERTY
    layout; worth revisiting only if that turns out to matter. Detecting conflicts with OS-level or
    other apps' shortcuts — genuinely hard to enumerate from inside a sandboxed app; a failed
    `RegisterEventHotKey` call is the practical signal a conflict exists, not something to
    pre-empt. A general-purpose "any future hotkey gets this for free" registry — only these two
    existing hotkeys need it today, scoped to them, not a speculative framework. Effort M — the
    registration-side change is small; `NSViewRepresentable` itself isn't new here (`VisualEffectView`
    already wraps `NSVisualEffectView` for sidebar vibrancy), but every existing use wraps a passive
    AppKit view — this is the first one that makes itself first responder and captures keyboard
    events, genuinely new territory even though the wrapping technique isn't.

26. **Documentation refresh — README + skill catch up to M14–M25** *(ratified 2026-07-20;
    Ronan: "ok lets do it make sure it can render the markdown too then we will expand
    documentation so it covers the full capabilities of the app" — the second half of that
    instruction, deferred until the M23→M25 queue finished. Confirmed stale, not assumed:
    `HubView.swift:322` has a real Knowledge pane (7 panes total: Home/Calls/Meetings/Ask/
    Knowledge/Settings/Docs) that `README.md:9` doesn't list; `SourcesMCP/main.swift:700,711`
    register real `commitments`/`entity_detail` MCP tools that neither `README.md`'s tool list
    (`README.md:74-77`) nor `Skill/scripta/SKILL.md`'s mentions. Both docs predate this
    session's entire M14–M25 arc — Quick Capture, notes, the commitments lifecycle, the
    entity graph, the Knowledge dashboard, the in-app document reader, and rebindable
    hotkeys are all unmentioned in either file.)*
    - `README.md`: add Knowledge to the pane list; new/expanded feature bullets for Quick
      Capture (standalone voice capture, plus a timestamped note during one), the
      commitments lifecycle (extraction, owner disambiguation, mark-done), the entity graph
      + Knowledge dashboard (entity pages, recent-activity synthesis, in-app document
      reader), and rebindable hotkeys (⌥⌘N alongside ⌥⌘R, both now user-configurable in
      Settings rather than fixed); extend the MCP tool list with `commitments`/
      `entity_detail`; bring the Status section current.
    - `Skill/scripta/SKILL.md`: add `commitments`/`entity_detail` to the tools list, same
      one-line style as the existing seven; one new playbook exercising them (e.g. "what
      does X still owe me" / "who's connected to Y").
    - Scope: prose only, no code changes. SPEC.md itself already tracks the implementation
      history in detail — README/SKILL are the user/agent-facing surfaces that had drifted.

    **Explicitly out of scope:** a from-scratch rewrite of either file — both are
    fundamentally sound, this is a catch-up pass on what's now stale, not a redesign. The
    in-app Docs pane's own content (separate from these two files) — not audited here, a
    follow-up if it's also found stale. Effort S.

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
