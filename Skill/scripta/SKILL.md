---
name: scripta
description: Find, summarize, and extract from the user's locally-recorded call and meeting transcripts via the scripta MCP. Use whenever the user asks about their calls, meetings, what was said or decided, action items, follow-ups, or a past conversation.
---

# Scripta

The user runs **Scripta**, a local macOS app that records and transcribes their calls and in-person meetings into Markdown files — fully private, on-device. The **`scripta` MCP server** exposes those transcripts read-only. Use it to answer anything about the user's calls.

## What a transcript contains
- **Frontmatter**: `title`, `date`, `time`, `duration`, `participants`, `tags`, `group` (workspace).
- **`## Summary`** — a short on-device AI summary (convenient, but may be imprecise).
- **Body** — timestamped lines: `**[M:SS]** spoken text`, with `You:` / `Them:` speaker labels when both sides were captured (filler words already stripped).
- **`## Screen Context`** (optional) — OCR of what was on screen, timestamped. Noisy, and tables may be flattened. Treat it as supporting context, not ground truth.

## Tools
- **`retrieve(query, participant?, tag?, speaker?, since?, limit?)`** — BM25-ranked passages with call/timestamp/speaker provenance. **Start here** for most questions. It also matches call topics, so concept queries work — "baseball" finds a call that only ever said "home runs".
- **`overview(limit?, since?)`** — every call's title, date, participants, summary, and path (paged). Best for "which call…" scanning when `retrieve` needs a second opinion.
- **`get_transcript(path)`** — full Markdown of one call; **`get_section(path, from, to)`** — just a time range.
- **`search_transcripts(query)`** — keyword search; snippets with a section label (`transcript`/`screen`/`title`) and path.
- **`list_transcripts(limit, since, participant, tag)`** — browse or filter by date, person, or tag.
- **`people`** / **`tags`** — aggregate indexes (name → call count) for orienting.

## Workflow
1. **Recall / semantic** ("which call was about X", "what did Y say about Z") → `retrieve` first; if the right call is ambiguous, `overview` and reason over summaries, then `get_transcript` for detail.
2. **Exact term / name / number** → `search_transcripts` or `retrieve`.
3. **Time or person browse** ("my calls this week", "calls with Sarah") → `list_transcripts` with `since` / `participant`.

## Playbooks
- **Summarize my week** → `list_transcripts(since: <date>)` (or `overview`), read each, synthesize themes, decisions, and open items.
- **Action items across calls** → `overview` to find relevant calls → `get_transcript` each → extract owners + tasks, grouped by call.
- **What did [person] say about [topic]** → `retrieve(query, participant:)` → `get_transcript`/`get_section` → answer **with citations**.
- **Prep for a follow-up with [person]** → find the most recent call with them → `get_transcript` → surface open threads, commitments, and unresolved questions.

## Always
- Tools refuse when the app isn't running, and answers are scoped to the app's **active workspace** — if refused, tell the user to open Scripta (or switch workspace) rather than guessing.
- **Cite** the call title and the `[M:SS]` timestamp when you quote something, so the user can verify.
- Summaries and screen-context OCR can be imprecise — for anything that matters (numbers, commitments, names), quote the **transcript body**, not the summary.
- This is the user's private data. Never send it anywhere.
