# Privacy Policy — Scripta

**Effective date:** November 10, 2026
**Contact:** scripta.app@outlook.com

<!-- Host this page publicly (GitHub Pages or any static host) and put its URL in the App
     Store Connect "Privacy Policy URL" field. On rename: find/replace the app name. -->

## The short version

Scripta collects no data. Everything the app does — recording, transcription,
search, and AI features — happens on your Mac. There are no accounts, no analytics, no
tracking, no crash reporting, and no servers of ours. The one internet connection the app
makes is checking GitHub for updates, and only if you allow it.

## What the app accesses, and why

- **Microphone** — records your side of a call. Requested the first time you record.
- **Screen & System Audio Recording** — records the other participants' audio, and (if you
  enable Screen Context) periodically reads text from a window you choose. Requested the
  first time you record.
- **Calendars (optional)** — shows your upcoming video-call events and pre-fills call
  details. Only if you turn the calendar feature on. Never modified.
- **A folder you choose** — where your transcripts are saved, as plain Markdown files you
  own and can move, edit, or delete at any time.

## What is stored, and where

- **Transcripts** are files in the folder you chose. They stay on your Mac (or in your own
  cloud/sync service if you chose a synced folder — that service's terms are between you
  and them).
- **A local search index** derived from your transcripts is stored on your Mac so search
  and Ask work. Deleting a transcript removes it from the index.
- **Raw audio and screenshots are always temporary.** They are deleted automatically as
  soon as transcription/text extraction finishes — only text is kept, ever.

## What leaves your Mac

Nothing, by default. Specifically:

- No transcript, audio, or usage data is ever sent to us — we run no servers and receive
  nothing.
- **Optional local AI server:** in Settings you can connect the app to an AI server you run
  yourself (for example Ollama) on your own machine or private network. If you do, the text
  being processed goes to that server of yours, and addresses on the public internet are
  refused outright. Some servers also offer models that run in their own cloud, which the app
  marks "(cloud)" in Settings. Choosing one for a feature sends nothing until you also turn on
  that feature's "Allow this cloud model" switch, which is off by default and says what would be
  sent. Once you do, what that feature processes is sent to the company that runs the model (for
  an Ollama cloud model, Ollama) under its own terms. Allowing one covers that model on that
  server only. A model counts as local only when Ollama's description of it confirms that, so a
  model your server only names (any server but Ollama, or Ollama when it can't say) needs the same
  opt-in before it is used. The app never picks a cloud or unconfirmed model on its own, and
  search never uses a cloud one. A server of yours that forwards requests to another service while
  describing its models as Ollama does looks local to the app, and what it receives goes wherever
  that server sends it.
- **Optional AI assistant connection:** if you connect an AI assistant such as Claude, the
  assistant can read your transcripts when you ask it questions — that data is then handled
  by the assistant under its own privacy policy, using your own account with that provider.
  This only happens if you set the connection up, and only while the app's engine is running.
  The assistant can read every workspace, not only the one the app is showing.
- **Apple on-device intelligence:** transcription and the optional titles/summaries use
  Apple frameworks that run on-device. No audio or text is sent to Apple by this app.
- **Update checks (optional):** on its second launch the app asks whether it may check for
  updates. If you agree, once a day it downloads a small file from the app's public GitHub
  releases page to see whether a newer version exists. Like any web request, this tells GitHub
  your IP address, and the request names the app and its version. Nothing else is sent, and
  nothing about your recordings or transcripts. You can turn it off in Settings → General;
  Check for Updates… makes the same request on demand.

## Recording consent

Recording laws vary by location; some require consent from everyone on a call. The app
shows a recording indicator in the menu bar at all times while recording, and obtaining any
required consent is your responsibility.

## Children

The app is not directed at children under 13 and collects no data from anyone.

## Changes

If this policy changes, the updated version will be posted at this page with a new
effective date. Since the app collects nothing, changes would only ever describe new
optional features.
