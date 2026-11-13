---
name: scripta
description: Find, summarize, and extract from the user's locally-recorded call and meeting transcripts through the `substrate` MCP, the engine Scripta runs. Use whenever the user asks about their calls, meetings, what was said or decided, action items, follow-ups, or a past conversation.
---

# Scripta

The user runs **Scripta**, a local macOS app that records and transcribes their calls and in-person meetings on-device; a model runs off-device only for a feature the user allows. Each call is written as a Markdown note into a workspace's vault, and Scripta's engine indexes it. The engine is an MCP server registered as **`substrate`**; use it to answer anything about the user's calls.

## The one thing to get right
Calls are `document_class: conversation`, and **conversation-class notes are left out of `search` and `documents` by default**. Pass **`include_sources: true`** on every call that should see calls. Without it the engine answers from the other notes only and says so in the reply's `filters` (`sources_excluded`), which reads exactly like "there is no such call". Check `filters` before saying something was never discussed.

## Scopes
Each workspace is a vault, and the engine serves it as a **scope** named after the workspace. A scope also composes the vaults it inherits, so it can hold curated notes and documents beside the calls. Call `list_scopes` to learn which exist. Every workspace is readable, whichever one the app is showing.

## Tools
- **`list_scopes()`** — the scopes, what each composes, and whether each is still waiting for its first index.
- **`search(scope, query, include_sources: true, k?, include_archived?, fast?)`** — ranked passages, each with its spine (`status`, `doc_type`, `confidence`, `document_class`, `vault`) and an `expand_ref`. **Start here** for "what did we say about X".
- **`documents(scope, include_sources: true, limit?, offset?, vault?, entity?, doc_type?)`** — what a scope holds, one row per note, no ranking. The browse call: use it for "which calls do I have", rather than an empty search. With `include_sources: true` it lists curated notes too, so keep the rows whose `document_class` is `conversation`. Rows carry no date or filename: a call's date is its frontmatter `date`, or its start in `note.path` (`<title> — YYYY-MM-DD HHMM.md`), both from `expand(mode: "note")`. An untitled call's title carries its start (`Call — YYYY-MM-DD HH:MM`). `search` passages do carry `path`. `total` counts every match, so page with `offset`.
- **`expand(expand_ref, mode?)`** — `mode: "note"` returns the whole note, frontmatter and timestamped body included, up to 20,000 characters; a longer call comes back cut, with `truncated: true`, so follow up with a narrower `search` (`include_sources: true`) for the part you need. The default `"passage"` returns just the matched chunk.
- **`status(scope)`** — orientation: counts by vault, status and doc_type, the retrieval arms, `refresh`, and `drift`. A note under `drift.added` is in the vault but not indexed yet, so read `drift` before saying something is absent.
- **`ingest(scope, content, filename, folder?, confirm_token?)`** and **`amend(scope, path, content, confirm_token?)`** — write a new note, or change an existing one. Both are two-phase: the first call writes nothing and returns a plan; show it to the user and commit with its `confirm_token` only once they agree. A write runs only for a client the user has allowed in **Settings → Clients**; a refusal names the client, so tell the user to allow it there. Calls themselves cannot be amended.

## What a call looks like
- **Frontmatter**: `title`, `date`, `time`, `duration`, `participants`, `tags`, plus the spine (`status`, `doc_type`, `confidence`, `class: conversation`). `commitments` holds action items, when the app extracted any.
- **`## Summary`** — a short on-device AI summary. Convenient, and may be imprecise.
- **Body** — timestamped lines `**[M:SS]** spoken text`, with `You:` / `Them:` labels when both sides were captured, and `Note:` lines the user typed during the call.
- **`## Screen Context`** (optional) — OCR of what was on screen, timestamped. Noisy; supporting context, not ground truth.

## Workflow
1. **Recall** ("what did we decide about X", "what did Y say") → `search` with `include_sources: true`, then `expand(mode: "note")` on the best hit to read around it.
2. **Which call** → `documents` with `include_sources: true`, keep the `conversation` rows, and read their titles rather than guessing at a query.
3. **Not sure which workspace** → `list_scopes`, then search each likely scope.

## Playbooks
- **Summarize my week** → `documents(scope, include_sources: true)`, `expand(mode: "note")` each `conversation` row and keep those whose `date` is in range, then synthesize themes, decisions and open items. Attribute each to the call it came from.
- **Follow-ups / what does [person] owe me** → read the `commitments` frontmatter from `expand(mode: "note")` on the relevant calls, rather than re-deriving them from the body.
- **Prep for a follow-up with [person]** → `search` for their name with `include_sources: true`, `expand(mode: "note")` the most recent call, and surface open threads, commitments and unresolved questions.
- **"Did we ever talk about X"** → `search` with `include_sources: true`. If nothing matches, check `filters` and `status` → `drift` before answering no.

People, tags and commitments rollups across calls are in the app (Calls › Digest), not in the engine. If the user asks for one, point them there rather than assembling one from transcript text.

## Always
- Scripta runs the engine. If the tools cannot connect, tell the user to open Scripta rather than guessing.
- A `conversation` passage is something someone **said**, and may be reasoning they abandoned later in the call. Say so when you rely on one, and don't present it as a decision.
- **Cite** the call title and the `[M:SS]` timestamp when you quote something, so the user can verify.
- Summaries and screen-context OCR can be imprecise. For anything that matters (numbers, commitments, names), quote the **transcript body**, not the summary.
- This is the user's private data. Never send it anywhere.
