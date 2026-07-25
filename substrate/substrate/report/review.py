"""The review packet — the Phase 0 gate, built for a human to rule on in ~20 minutes.

Machine assertions can prove coverage and determinism. They cannot tell you whether a chunk
is a coherent concept-unit, which is check 4 and the reason chunking quality fails SILENTLY:
plausible-looking chunks that retrieve the wrong thing. So this renders the evidence for the
five checks and gets out of the way.

Sampling is stratified by position, FORCES the extremes and machine-flagged cases, and is
seeded — a random sample of 15 from 1,152 will show you fifteen unremarkable middles and
hide every failure.
"""

from __future__ import annotations

import json
import random
import re
from pathlib import Path

CHECKS = {
    1: "Each chunk carries its structural path, not floating text.",
    2: "No header/footer/page-number pollution in chunk text.",
    3: "Across-page paragraphs rejoined; code/tables intact, not shredded.",
    4: "Chunks are coherent concept-units, not mid-sentence fixed-size cuts.",
    5: "Section/chapter-level summaries retrievable separately from passages.",
}


def _load(d: Path) -> tuple[dict, list[dict], list[dict], str]:
    run = json.loads((d / "run.json").read_text("utf-8"))
    blocks = [json.loads(x) for x in (d / "blocks.jsonl").read_text("utf-8").splitlines() if x]
    chunks = [json.loads(x) for x in (d / "chunks.jsonl").read_text("utf-8").splitlines() if x]
    body = (d / "document.md").read_text("utf-8")
    return run, blocks, chunks, body


def _fence(text: str, limit: int = 1400) -> str:
    t = text if len(text) <= limit else text[:limit] + f"\n… [+{len(text) - limit} chars]"
    return f"```\n{t}\n```"


def _summary(run: dict, chunks: list[dict], blocks: list[dict]) -> str:
    p = [c for c in chunks if c["kind"] == "passage"]
    o = [c for c in chunks if c["kind"] == "outline"]
    ch, cl, ck = run["chunk"], run["class"], run["extract"]

    reds: list[str] = []
    if run["coverage"] < 0.95:
        reds.append(f"A14 coverage {run['coverage']} < 0.95 — text is being lost.")
    if ch["short_fragments"]:
        reds.append(f"A13 {ch['short_fragments']} fragment chunks.")
    if cl["document_class"] == "reference-versioned" and not cl["version"]:
        reds.append("A12 no version captured on a versioned document.")

    L = [
        f"# {cl['title']}",
        "",
        f"`{run['doc_id']}` · {run['pages']} pages · {run['elapsed_s']}s · "
        f"class **{cl['document_class']}**" + (f" · version **{cl['version']}**" if cl.get("version") else ""),
        "",
    ]
    if reds:
        L += ["## RED", ""] + [f"- **{r}**" for r in reds] + [""]
    else:
        L += ["## All machine assertions green", ""]

    L += [
        "## Numbers",
        "",
        "| | |",
        "|---|---|",
        f"| body chars | {run['emit']['body_chars']:,} |",
        f"| coverage (chunks/body) | **{run['coverage']}** |",
        f"| passages / outlines | {len(p)} / {len(o)} |",
        f"| chunk size p5 / p50 / p95 | {ch['chars_p5']} / **{ch['chars_p50']}** / {ch['chars_p95']} |",
        f"| well-formed | {ch['well_formed_pct']}% (fragments {ch['short_fragments']}) |",
        f"| path depth ≥2 | {ch['path_depth_ge2_pct']}% (max {ch['max_path_depth']}) |",
        f"| oversize (kept whole) | {ch['oversize']} |",
        f"| hyphen glyph | `{run['emit']['hyphen_glyph']}` — {run['emit']['hyphens']} joined |",
        f"| ligatures rejoined | {run['emit']['ligatures']} |",
        f"| furniture claimed / honored / re-admitted | {ck['furniture_claimed']} / {ck['furniture_honored']} / {ck['furniture_readmitted']} |",
        f"| contents blocks excluded | {ck['toc_blocks_marked']} |",
        f"| heading tiers (pt) | {ck['heading_tiers']} |",
        f"| extractor | {run['extract'].get('seconds_per_page', '?')} s/page |",
        f"| internal disk | {run['internal_cache']} |",
        "",
        "## The five checks",
        "",
    ]
    files = {
        1: "01-structure.md, 02-samples.md",
        2: "04-furniture.md",
        3: "03-transitions.md, 05-tables-code.md",
        4: "02-samples.md",
        5: "06-outline-records.md",
    }
    for n, text in CHECKS.items():
        L.append(f"{n}. {text}  \n   → `{files[n]}`")
    return "\n".join(L) + "\n"


def _structure(chunks: list[dict]) -> str:
    p = [c for c in chunks if c["kind"] == "passage"]
    counts: dict[str, int] = {}
    for c in p:
        counts[c["path_str"]] = counts.get(c["path_str"], 0) + 1

    L = ["# Heading tree", "", "Chunk counts per leaf section. A section with 20+ chunks is",
         "probably an under-segmented wall; a long tail of 1-chunk sections is fine.", ""]
    seen: set[tuple] = set()
    for c in p:
        path = tuple(c["path"])
        for i in range(1, len(path) + 1):
            sub = path[:i]
            if sub in seen:
                continue
            seen.add(sub)
            n = counts.get(" > ".join(sub), 0)
            tail = f"  ({n} chunks)" if n else ""
            L.append(f"{'  ' * (i - 1)}{'#' * i} {sub[-1]}{tail}")
    return "\n".join(L) + "\n"


def _samples(chunks: list[dict], n: int, seed: int) -> str:
    p = [c for c in chunks if c["kind"] == "passage"]
    if not p:
        return "# Samples\n\n(none)\n"

    picked: dict[str, dict] = {}

    def take(label: str, c: dict | None) -> None:
        if c and c["chunk_id"] not in {x["chunk_id"] for x in picked.values()}:
            picked[label] = c

    take("LONGEST", max(p, key=lambda c: c["n_chars"]))
    take("SHORTEST", min(p, key=lambda c: c["n_chars"]))
    take("DEEPEST PATH", max(p, key=lambda c: len(c["path"])))
    take("SHALLOWEST PATH", min(p, key=lambda c: len(c["path"])))
    for label, pred in (
        ("CONTAINS CODE", lambda c: "```" in c["text"]),
        ("CONTAINS TABLE", lambda c: "|" in c["text"] and c["text"].count("|") > 6),
        ("OVERSIZE (kept whole)", lambda c: c.get("oversize")),
        ("SPANS PAGES", lambda c: c.get("page_end") and c.get("page_start") and c["page_end"] > c["page_start"]),
        ("MULTI-PART", lambda c: c.get("part_count")),
    ):
        take(label, next((c for c in p if pred(c)), None))

    rng = random.Random(seed)
    stride = max(len(p) // max(n, 1), 1)
    for i in range(0, len(p), stride):
        window = p[i : i + stride]
        if window and len(picked) < n + 9:
            take(f"position {100 * i // max(len(p), 1)}%", rng.choice(window))

    L = [
        "# Sampled chunks",
        "",
        f"{len(picked)} chunks: every extreme and machine-flagged case, plus a seeded",
        f"(seed={seed}) stratified draw across the document.",
        "",
        "**Read for check 1** — does the path above each chunk actually describe it?  ",
        "**Read for check 4** — does it start and end at a sensible boundary, or mid-thought?",
        "",
    ]
    for label, c in picked.items():
        pages = f"p{c['page_start']}" + (f"–{c['page_end']}" if c.get("page_end") != c.get("page_start") else "")
        part = f" · part {c['part_index']}/{c['part_count']}" if c.get("part_count") else ""
        L += [
            f"## {label} · {c['n_chars']} chars · {pages}{part}",
            "",
            f"**path:** `{c['path_str'] or '(none)'}`",
            "",
            _fence(c["text"]),
            "",
        ]
    return "\n".join(L)


def _transitions(body: str, blocks: list[dict], run: dict) -> str:
    glyph = run["emit"].get("hyphen_glyph")
    L = [
        "# Transitions",
        "",
        "**Check 3.** Left column is what the repair produced; judge whether the join is right.",
        "",
        f"Hyphen glyph discovered: `{glyph}` — {run['emit']['hyphens']} joins, "
        f"{run['emit']['ligatures']} ligature rejoins.",
        "",
        "## Page-boundary joins",
        "",
        "Text spanning a page anchor. A correct join reads as one sentence.",
        "",
    ]
    anchors = list(re.finditer(r"<!-- page:(\d+) -->", body))
    shown = 0
    for m in anchors[1:]:
        before = body[max(0, m.start() - 170) : m.start()].strip().replace("\n", " ")
        after = body[m.end() : m.end() + 170].strip().replace("\n", " ")
        if not before or not after or before.endswith(("#", "|")):
            continue
        joined_mid = not before.endswith((".", ":", "?", "!", '"'))
        L += [
            f"**page {m.group(1)}** {'— mid-sentence, verify' if joined_mid else ''}",
            "",
            f"> …{before}",
            f"> **[page break]** {after}…",
            "",
        ]
        shown += 1
        if shown >= 12:
            break

    # The ACTUAL reassembled words, threaded from dehyphenate()'s samples through emit() into
    # run.json — not a long-word proxy. `.get` tolerates a run.json that predates the field (renders
    # as none rather than raising).
    L += ["## Repaired words", "",
          "Words the dehyphenation pass reassembled from a split, shown as `original -> joined`. "
          "Each joined form must be a real word; flag any that is not (a bad join).", ""]
    samples = run["emit"].get("repaired_samples") or []
    if samples:
        L += [f"- `{s}`" for s in samples]
    else:
        L.append("_(none — no hyphen splits were repaired.)_")
    return "\n".join(L) + "\n"


def _furniture(blocks: list[dict], body: str, run: dict) -> str:
    dropped = [b for b in blocks if b.get("furniture_honored")]
    readmit = [b for b in blocks if b.get("furniture_claimed") and not b.get("furniture_honored")]
    excluded = [b for b in blocks if b.get("kind") == "index"]

    L = [
        "# Furniture and contents",
        "",
        "**Check 2.** Docling was measured DELETING real content, so nothing is dropped on its",
        "label alone — every drop is corroborated by cross-page repetition, and captions are",
        "never dropped. This page proves both directions: what went, and what was rescued.",
        "",
        f"- claimed furniture: **{len(dropped) + len(readmit)}**",
        f"- honored (removed): **{len(dropped)}**",
        f"- re-admitted (rescued): **{len(readmit)}**",
        f"- contents blocks excluded: **{len(excluded)}**",
        "",
        "## Grep-back — did anything removed survive into the body?",
        "",
    ]
    # A recto footer echoes its own section title, so the same string legitimately exists in
    # the body AS A HEADING. Counting that as a leak reports ~11 false positives on DDIA and
    # trains the reader to ignore the assertion, which is worse than not having it.
    heading_text = {
        (b.get("text") or "").strip() for b in blocks if b.get("kind") == "heading"
    }
    leaks, echoes = 0, 0
    for b in dropped[:600]:
        t = (b.get("text") or "").strip()
        if len(t) <= 12 or t not in body:
            continue
        if t in heading_text:
            echoes += 1
            continue
        L.append(f"- **LEAK** `{t[:90]}`")
        leaks += 1
    L.append(
        f"{'No leaks.' if not leaks else f'**{leaks} leaked.**'}"
        f"  \n_{echoes} removed strings also occur as real headings (a recto footer repeating"
        " its section title) — expected, not leaks._"
    )

    L += ["", "## Longest removals (the riskiest — real text looks like this)", ""]
    for b in sorted(dropped, key=lambda b: -len(b.get("text") or ""))[:10]:
        L.append(f"- p{b.get('page')} · {len(b.get('text') or '')} chars · `{(b.get('text') or '')[:110]}`")

    L += ["", "## Rescued from deletion (would have been lost)", ""]
    for b in readmit[:14]:
        L.append(f"- p{b.get('page')} · _{b.get('readmit_reason')}_ · `{(b.get('text') or '')[:100]}`")
    return "\n".join(L) + "\n"


def _tables_code(chunks: list[dict]) -> str:
    p = [c for c in chunks if c["kind"] == "passage"]
    code = [c for c in p if "```" in c["text"]]
    tables = [c for c in p if c["text"].count("|") > 6]
    L = [
        "# Tables and code",
        "",
        "**Check 3.** These are atomic — never split, and bound to their caption.",
        f"Code-bearing chunks: {len(code)} · table-bearing: {len(tables)}",
        "",
        "## Code",
        "",
    ]
    for c in code[:6]:
        L += [f"### `{c['path_str']}` · p{c['page_start']}", "", _fence(c["text"], 900), ""]
    L += ["## Tables", ""]
    for c in tables[:6]:
        L += [f"### `{c['path_str']}` · p{c['page_start']}", "", _fence(c["text"], 900), ""]
    return "\n".join(L)


def _outlines(chunks: list[dict]) -> str:
    o = [c for c in chunks if c["kind"] == "outline"]
    L = [
        "# Outline records",
        "",
        "**Check 5.** One per heading at level ≤3 — path, lede, child headings, and any",
        "verbatim Summary. Built extractively: no model runs in the ingestion path.",
        "",
        "Judge: does this orient you on the section without reading its passages? If these are",
        "useless, the fix is a separate cached summarization stage OUTSIDE the deterministic",
        "path — not an LLM call inside it.",
        "",
        f"{len(o)} records.",
        "",
    ]
    for c in sorted(o, key=lambda c: c["level"])[:22]:
        L += [f"## L{c['level']} · `{c['path_str']}`", "", _fence(c["text"], 1100), ""]
    return "\n".join(L)


def build(d: Path, samples: int = 15, seed: int = 7) -> Path:
    run, blocks, chunks, body = _load(d)
    rev = d / "review"
    rev.mkdir(exist_ok=True)

    for name, text in (
        ("00-summary.md", _summary(run, chunks, blocks)),
        ("01-structure.md", _structure(chunks)),
        ("02-samples.md", _samples(chunks, samples, seed)),
        ("03-transitions.md", _transitions(body, blocks, run)),
        ("04-furniture.md", _furniture(blocks, body, run)),
        ("05-tables-code.md", _tables_code(chunks)),
        ("06-outline-records.md", _outlines(chunks)),
    ):
        (rev / name).write_text(text, encoding="utf-8")
    return rev
