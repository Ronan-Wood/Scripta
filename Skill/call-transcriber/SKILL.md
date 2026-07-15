---
name: call-transcriber
description: Find, summarize, and extract from the user's locally-recorded call and meeting transcripts via the calltranscriber MCP. Use whenever the user asks about their calls, meetings, what was said or decided, action items, follow-ups, or a past conversation.
---

# Call Transcriber

The user runs **Call Transcriber**, a local macOS app that records and transcribes their calls and in-person meetings into Markdown files — fully private, on-device. The **`calltranscriber` MCP server** exposes those transcripts read-only. Use it to answer anything about the user's calls.

## What a transcript contains
- **Frontmatter**: `title`, `date`, `time`, `duration`, `participants`, `tags`.
- **`## Summary`** — a short on-device AI summary (convenient, but may be imprecise).
- **Body** — timestamped lines: `**[M:SS]** spoken text` (filler words already stripped).
- **`## Screen Context`** (optional) — OCR of what was on screen, timestamped. Noisy, and tables may be flattened. Treat it as supporting context, not ground truth.

## Tools
- **`overview`** — every call's title, date, participants, summary, and path. **Start here** for "which call…" or "what did we discuss about…" questions: scan the summaries, pick the relevant call(s), then read them.
- **`get_transcript(path)`** — full Markdown of one call.
- **`search_transcripts(query)`** — keyword search; returns snippets with a section label (`transcript`/`screen`/`title`) and path.
- **`list_transcripts(limit, since, participant, tag)`** — browse or filter by date, person, or tag.

## Workflow
1. **Recall / semantic** ("which call was about X", "what did Y say about Z") → call `overview`, reason over the summaries to find the right call, then `get_transcript` for detail. (This is where you shine — the app's on-device model can't do this matching, but you can.)
2. **Exact term / name / number** → `search_transcripts`.
3. **Time or person browse** ("my calls this week", "calls with Sarah") → `list_transcripts` with `since` / `participant`.

## Playbooks
- **Summarize my week** → `list_transcripts(since: <date>)` (or `overview`), read each, synthesize themes, decisions, and open items.
- **Action items across calls** → `overview` to find relevant calls → `get_transcript` each → extract owners + tasks, grouped by call.
- **What did [person] say about [topic]** → `list_transcripts(participant:)` or `search_transcripts` → `get_transcript` → answer **with citations**.
- **Prep for a follow-up with [person]** → find the most recent call with them → `get_transcript` → surface open threads, commitments, and unresolved questions.

## Always
- **Cite** the call title and the `[M:SS]` timestamp when you quote something, so the user can verify.
- Summaries and screen-context OCR can be imprecise — for anything that matters (numbers, commitments, names), quote the **transcript body**, not the summary.
- This is the user's private data. Never send it anywhere.
