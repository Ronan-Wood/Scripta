# App Store listing draft

<!-- Everything here is copy-paste-ready for App Store Connect except the name (pending
     Ronan's rename — find/replace throughout) and screenshots (pending the UI/UX redo). -->

## Identity

- **Name** (30 chars max): `Call Transcriber` ← RENAME PENDING; check availability in ASC early
- **Subtitle** (30 chars max): `Private, on-device call notes`
- **Bundle ID:** `com.ronanwood.CallTranscriber` ← LOCKED FOREVER at first upload; decide with the rename
- **Category:** Productivity (secondary: Business)
- **Price:** Free
- **EU trader status:** Non-trader (free app, no monetization → no address/phone published)

## Privacy section (ASC questionnaire)

- **Privacy label:** Data Not Collected (truthfully — no data leaves the device, no
  accounts, no analytics, no third-party SDKs)
- **Privacy policy URL:** host `Distribution/privacy-policy.md` and paste the URL
- **Encryption:** `ITSAppUsesNonExemptEncryption = false` already in Info.plist (standard
  TLS only, exempt)

## Description

> Call Transcriber records and transcribes your calls and meetings entirely on your Mac.
> No account, no cloud, no meeting bots — nothing ever leaves your machine.
>
> Press record during any call (Zoom, Teams, Meet, phone audio through your Mac — anything
> your Mac can play) and get a clean, speaker-labeled transcript: your side from the
> microphone, everyone else from system audio. A live transcript streams while you talk.
>
> WHAT YOU GET
> • Speaker-labeled transcripts (You / Them) — attribution is physical, not guessed
> • Automatic titles, summaries, and topic tags, generated on-device (Apple Intelligence)
> • Screen context: optionally capture text from a window you choose, woven into the
>   transcript's timeline
> • A searchable library — search finds meaning, not just words ("baseball" finds the call
>   that only said "home runs")
> • Ask: question-answering across your whole call history, on-device, with cited sources
> • Workspaces: keep clients, projects, or work/personal hard-separated
> • Calendar awareness: see upcoming video calls and pre-fill meeting details — recording
>   is always your click, never automatic
> • Plain Markdown files in a folder you choose — your notes app or vault picks them up
>   automatically. Your data is just files, forever yours.
>
> PRIVATE BY ARCHITECTURE
> Transcription runs on-device with Apple's speech engine. Raw audio and screenshots are
> deleted the moment processing finishes — only text is kept. The app has no servers, no
> login, no analytics. The App Store privacy label says "Data Not Collected" because there
> is nothing to collect.
>
> FOR AI POWER USERS
> Connect Claude (Code, Desktop, or Cowork) through the free companion connector and ask
> anything across your calls — "summarize my week", "what did we promise the client?".
> Prefer your own models? Point the app at a local server like Ollama on your own machine.
> Nothing public, ever.
>
> Requires macOS 26 on Apple silicon. Titles/summaries need Apple Intelligence enabled;
> everything else works without it.

## Keywords (100 chars max, comma-separated, no spaces)

`transcribe,meeting,notes,recorder,transcript,minutes,markdown,obsidian,private,offline,summary`

(97 chars. "call" and the app name are matched automatically from the title; don't waste
keyword budget on them.)

## What's New (v1.0)

> Initial release.

## Review notes (Notes for App Review box)

> Call Transcriber is a fully on-device call transcription tool — no account or server;
> the privacy label is "Data Not Collected".
>
> To test: launch the app (menu-bar waveform icon), click the icon → Start Recording.
> Grant Microphone and Screen & System Audio Recording when prompted. Play any audio
> (e.g. a YouTube video) and speak, then Stop after ~30 seconds. A transcript with You/Them
> speaker labels opens in the app's hub window within seconds.
>
> Recording consent: a first-launch notice tells users that recording laws vary and consent
> is their responsibility; a menu-bar indicator is always visible while recording.
>
> The "local AI server" setting is optional and off by default; it accepts only
> loopback/private-LAN addresses the user runs themselves (e.g. Ollama) and refuses public
> hosts. The app itself makes no network connections.
>
> The Claude connector mentioned in the Docs pane is a separate, free, optional download
> signed with the same Team ID; this app bundle contains no embedded helper executables.

## Screenshots — TODO after the UI/UX redo

Need 1280×800 or 2560×1600 (or 2880×1800). Suggested set:
1. Hub Home while recording — live transcript + level meter + timer
2. A finished transcript with You/Them labels + summary/topics
3. Search finding a concept match ("baseball" → home-runs call)
4. Ask answering with cited sources
5. Meetings calendar view
6. Settings folder choice (the "your data is files" story)

## Submission-day checklist (ASC side)

1. App Store Connect → New App → name / bundle ID / SKU (SKU: `calltranscriber-mac-001`)
2. Paste description, subtitle, keywords, review notes from this file
3. Privacy: questionnaire → Data Not Collected; paste policy URL
4. EU DSA: declare non-trader
5. Upload screenshots + 1024 icon (already in the app; ASC pulls from the build)
6. Archive `CallTranscriber-MAS` (Release) in Xcode → Distribute → App Store Connect
7. TestFlight it yourself first, then Submit for Review
