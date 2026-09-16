# Getting started with Scripta

This guide takes you from download to your first transcript, then through the features you'll reach for next. Everything happens on your Mac, and there is no account to create.

## 1. Install

- You need **macOS 26 or later on Apple Silicon**. Apple Intelligence is optional; titles and summaries use it when it's on.
- Download `Scripta.dmg` from the [latest release](../../releases/latest), open it, and drag **Scripta** into **Applications**. The app is signed and notarized, so it opens normally.
- On first launch Scripta asks where to save transcripts. **Use Default** saves them to `Documents/Scripta`. **Choose Folder…** lets you pick another place, such as an Obsidian vault. You can change it later in **Settings → Output**.

Scripta opens its main window, the Hub, and adds an icon to the menu bar. If you'd rather it lived only in the menu bar, turn off **Show in Dock** in **Settings → General**.

## 2. Grant permissions when asked

Scripta asks for each permission the first time it needs it, not all at once.

| Permission | What it's for | Without it |
|---|---|---|
| **Microphone** | your side of a call | only the other participants are transcribed |
| **Screen Recording** | macOS requires it to capture system audio, which is how the other participants are recorded | only your voice is transcribed |
| **Calendar** (optional) | shows upcoming meetings and pre-fills a call's name | nothing else changes |

Screen Recording surprises people. Scripta isn't recording your screen: macOS puts system-audio capture behind that permission. If you turn on screen context, screenshots are discarded as soon as their text is read.

## 3. Record your first call

1. Join your call as usual.
2. Press **⌥⌘R** from any app, or click **Start recording** on the Hub's Home screen. The menu-bar icon shows the running time while you record.
3. Press **⌥⌘N** during the call to add a timestamped note. Pause and resume from the menu-bar menu.
4. Press **⌥⌘R** again, or choose **Stop Recording** from the menu-bar menu.

Scripta transcribes on-device and writes the transcript as Markdown into your output folder. It then asks for the call's title and participants. You can skip that and edit the details later, or turn the prompt off with **Name the call after recording** in **Settings → General**.

Recording always starts with you. The calendar is informational, and nothing records on its own.

### Choosing a mode

| Mode | Use it when |
|---|---|
| **Call** | you're on a call from this Mac. Your microphone and the call's audio are recorded as separate tracks and labelled You and Them. |
| **Conference · Microphone** | you're in the room, possibly also joined online. Only your microphone is recorded, unlabelled, so the meeting isn't transcribed twice. |
| **Conference · System audio** | you only need what plays through the Mac. Only system audio is recorded, unlabelled, and your microphone is ignored. |

Set the default in **Settings → Recording → Default mode**. Turn on **Choose mode & screen before each recording** to be asked every time.

## 4. Find your transcripts

- **Calls** in the Hub lists your recordings. Open one to read it and edit its details.
- The files are Markdown with YAML frontmatter, in your output folder. Scripta only ever changes files it created, so it's safe to point at a vault you already use.
- Raw audio is deleted after transcription. Only text is kept.

## 5. Organise with workspaces

Workspaces keep unrelated work apart, for example Deals and Personal. In **Settings → Calendar**, assign each calendar to a workspace, and calls from its meetings land there. Search, Ask and Claude only see the active workspace; searching across workspaces is an explicit, one-off action.

## 6. Add documents and notes

Open **Library** and go to its **Add** section, where you choose what you're adding:

- **A document**: PDF, Word, PowerPoint, Excel, a web page, plain text, subtitles, email, or an image;
- **A call transcript** you already have;
- **A note** you write yourself.

Everything is extracted on-device and filed into the active workspace, so it answers alongside your calls. Nothing needs installing: a PDF is read from its own text, and Apple's on-device text recognition reads scanned pages and images. A document that can't be read cleanly is refused with the reason, rather than filed half-extracted.

If you already have docling's layout and table models, choose their folder in **Settings → Local model → Document models**, and tables read better. Scripta never downloads them. If the folder goes missing, for example on an unplugged drive, documents are read without them.

## 7. Ask questions

Open **Ask** and type a question in your own words. Answers come from the calls, notes and documents in the active workspace, with citations to what was used. If part of the search was unavailable, the answer says so instead of quietly being weaker.

Everything works with Apple's on-device models. For better answers to loosely worded questions, run a local model server such as [Ollama](https://ollama.com) and point Scripta at it in **Settings → Local model**. Only servers on your Mac or your local network are accepted.

## 8. Connect Claude (optional)

Scripta's engine is an MCP server, so Claude can search your calls and documents. The steps are in the Hub under **Docs → Claude & MCP**.

- **Claude Code:** copy the command shown there and run it in Terminal. For an app installed in Applications it reads:

  ```sh
  claude mcp add -s user substrate -- "/Applications/Scripta.app/Contents/Resources/substrate-engine/bin/substrate-mcp"
  ```

- **Claude Desktop:** click **Add to Claude Desktop**, pick Claude's settings folder when asked, then quit Claude Desktop with ⌘Q and reopen it.
- **The Scripta skill** (Claude Code only): click **Install Claude skill** and pick your `.claude` folder. It teaches Claude playbooks such as "summarize my week".

Claude can read the active workspace only while Scripta is running. Calls are withheld from Claude until it asks for them, and its replies say what was left out.

## 9. Updates

On its second launch, Scripta asks whether it may check for updates. If you agree, it checks GitHub once a day and offers new versions. **Check for Updates…** in the Scripta menu or the menu-bar menu checks on demand, and **Settings → General** turns the daily check on or off. An update waits for any recording to finish, and your transcripts, settings and permissions carry over.

Versions before in-app updates can't update themselves. Quit Scripta, download the new version once, and drag it over the old copy in Applications.

## 10. If something looks wrong

- **Only your voice was transcribed.** Check that Scripta has Screen Recording permission in **System Settings → Privacy & Security**, and that you recorded in **Call** mode.
- **Search or Ask is missing something recent.** The index updates while Scripta is open. Notes edited while it was closed are picked up the next time it runs.
- **The engine didn't start.** Settings shows the engine's state, with the reason and a **Restart** control.
- **Still stuck?** [Open an issue](../../issues) with what you did and what you saw.

For what Scripta does and doesn't send anywhere, see [Privacy](README.md#privacy) in the README.
