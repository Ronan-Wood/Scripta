# Substrate Engine — Findings

> **Scope:** ingestion and document-structure findings from Phase 0–1.
> Retrieval experiments (embedders, query expansion, fusion, reranking) and their verdicts
> live in **[EXPERIMENTS.md](EXPERIMENTS.md)**, which is the running log and the place to
> look for "what have we tried and what did we learn".

Empirical results from building Phase 0–1 (2026-07-20/21). Everything here was **measured**
on real files, not reasoned about. Git history says what changed; this says what we learned,
so the next person (or the next model) does not re-derive it.

Corpus: **DDIA 2nd ed** (673pp, Quartz re-save of AH Formatter), **Go spec** (61pp, Skia /
Chrome print), **"Hybrid Approaches for Moral Value Alignment"** (34pp, two-column academic
paper). Extractor: docling 2.114.0 + docling-layout-heron.

---

## 1. The methodological finding — the one that matters most

**Three separate all-green states were semantically wrong.**

Every machine gate passed — coverage 0.978, path depth 99.9%, zero fragments, determinism
byte-identical — while 11 of 14 DDIA chapter titles were being silently discarded. Page 328
(Transactions) carried the path `CHAPTER 2 Defining Nonfunctional Requirements`. The paths
were well **formed** and merely **wrong**.

Nothing automated caught it. It surfaced only by running three real orientation queries and
reading the output.

**Consequences for how this engine is verified, permanently:**

- Structural metrics (coverage, recall@k, MRR, depth) catch *malformation*. They cannot
  catch *wrongness*. They are necessary and never sufficient.
- A recall@k harness scored on gold **paths** would have gone green on all three broken
  states, because every returned chunk had a well-formed depth-≥2 path — with the wrong
  chapter in it.
- **Phase 4 gold cases must assert a known correct ANSWER**, not retrieval shape.
- Real queries, read by a human, are the final gate for every phase. Not a Phase-0 ritual.

**Corollary — assertions must be calibrated or they lie:**

- The `oversize` gate budgeted `passages // 50`, so the *same 2 tables* passed on
  1,152-passage DDIA and failed on a 78-passage paper. Retargeting it to "no oversized
  **prose**" (prose always has sentence boundaries; tables and code do not) immediately
  exposed a real defect the loose version had been hiding — DDIA's back index sitting in
  the substrate.
- The furniture grep-back reported 11 false "leaks" on DDIA, because a recto footer repeats
  its own section title, so the identical string legitimately exists in the body **as a
  heading**. An assertion that cries wolf trains you to ignore it — worse than absent.

**Corollary — a heuristic tuned on document N breaks document M silently.** The left-edge
rule that correctly excluded the Go spec's TOC column (l=177 vs body l=44) destroyed DDIA's
chapter titles, which are set decoratively with left edges scattered 105→357. Every new
heuristic needs a second corpus before it is trusted.

---

## 2. Docling: what it solves, and where it lies

Adopted as primary extractor after a measured bake-off. It won on the things that matter and
it is **deterministic** (byte-identical output across runs, same sha256 — verified three
times, including under batching). But it is a **source of labels to VERIFY, not an oracle.**

### Solves well
| | |
|---|---|
| DDIA parity recto/verso footers | 29/29 `PAGE_FOOTER`, both parities — the most fragile thing we would have hand-rolled |
| Go spec headings with ZERO embedded outline | 66 found on 20pp |
| Two-column academic reading order | correct, unmodified, first try |
| Table structure | TableFormer; tables arrive as usable markdown |

### Lies, all verified
1. **It silently deletes body text.** A real Go-spec sentence (p8, *"produces the same slice
   as allocating an array…"*) was classified `page_footer` → `FURNITURE` → dropped, on a
   document with **no running furniture at all**. Present in the PDF, absent from output.
2. **It deletes captions.** Three DDIA captions (`Example 3-4`, `5-3`, `8-1`) labelled
   furniture. Each appears on exactly one page, so repetition alone can never rescue them —
   hence the structural `CAPTION` rule, which outranks every other signal.
3. **It provides NO heading hierarchy.** Every heading returns `level=1` with
   `parent='#/body'`. The document tree is flat. This was the single biggest wrong
   assumption in the spec — the font-ladder classifier we thought Docling made redundant is
   required, not for *finding* headings but for *ranking* them.
4. **It labels chapter-opening pages `DOCUMENT_INDEX`.** DDIA chapter titles arrived as
   index content and were dropped before any heading logic ran.
5. **It joins real compounds.** `self-contained` → `selfcontained`, 3× in 673pp. Low volume,
   not fixable without a dictionary, noted as residual.

### Known upstream issues that bit us
- Setting `artifacts_path` **disables auto-download** — prefetch is a prerequisite, not an
  optimization, and the failure is a `FileNotFoundError` for `model.safetensors`.
- `artifacts_path` must point at the **parent** directory holding the `docling-project--*`
  folders. One level too deep silently re-downloads.
- Issue #3015: `page_header`/`page_footer` can retain `content_layer=body` inside container
  groups — so the furniture grep-back assertion stays even with Docling.

---

## 3. Text corruption that survives a perfect layout model

Both are **glyph-mapping artifacts, not layout questions**, so no extractor fixes them.

### Soft hyphen — DDIA's is `!` (0x21)
Byte-verified, 1,094 occurrences. Never assume `-`; the glyph is discovered by voting.

Docling emits it **spaced**: `determin ! istic`, not `determin!istic`. That is *worse* than
raw, because it defeats the obvious `[a-z]![a-z]` check — which returns a **false clean**.
The correct probe is `[a-z]\s*!\s*[a-z]`.

**Calibration must score fragment validity, not frequency.** A frequency vote picks `-` on a
673-page book (2,670 occurrences vs 1,092) and welds 743 legitimate compounds
(`read-optimized` → `readoptimized`) — a net-negative change to the substrate. The
discriminator: does joining across the glyph produce a word that exists elsewhere in the
document? `representa`+`tion` → yes. `read`+`optimized` → no. DDIA scores `!` 0.637 vs `-`
0.163.

The score is **corpus-size dependent** (0.64 over 673pp, 0.43 over 23pp — a smaller
vocabulary corroborates less often), so selection is **relative**, not against a fixed
threshold. Separation is stable at either size (3.9× and 25×).

### Ligatures split into standalone tokens
`Bloom fi lter`, `partition fi le`, `as fl ow`, `Schema fl exibility`. 32 in DDIA.

Low count, high impact: it corrupts exactly the **technical terms retrieval depends on**. A
search for "Bloom filter" cannot match "Bloom fi lter", so the passage is unreachable while
looking perfectly fine to a reader. The orphaned ligature always binds to the **following**
fragment. `ff` is excluded — it is a real abbreviation ("ff." = following) and measured 0.

---

## 4. Geometry is the only hierarchy signal

Since Docling reports no levels, heading rank comes from `prov.bbox`.

**`bbox` height is BLOCK height, not glyph height.** It approximates font size only for
single-line blocks — a multi-line `list_item` measured 63.0pt. Fine for headings (nearly
always one line), wrong if used generally.

Measured ladders:
```
Go spec  19.3pt ×1 (title) | 12.0 ×10 (sections) | 9.7 ×39 (subsections)
DDIA     188.9 (cover) | 49.7 (chapters) | 20.1 | 16.8 | 12.3 (237 subsections)
```

**Cluster by RELATIVE tolerance.** 0.6pt is 5% at 12pt but 1% at 50pt; an absolute tolerance
left 12.1/12.3/12.7pt as three separate rungs for one visual style.

**Level must be a pure function of style.** A sequence-dependent monotonicity repair (a
heading may not sit more than one level below its predecessor) split a single 12.3pt style
across L5 (70) and L6 (167) purely on what preceded it, putting book siblings on different
rungs. Rank the tiers actually *used* and map them onto consecutive levels instead.

**Left edge separates TOC columns — but only for SMALL text.** Contents entries are the
smallest text in a narrow column; chapter titles are the largest glyphs in the document and
are often positioned decoratively. Gating off-column exclusion on size is what makes the
rule safe.

---

## 5. Back matter is not content

- **The back index** leaked in as a 2,669-char block (`column families (Bigtable), 82, 140
  …`). No sentence splitter can break it up because it contains no sentences, and it is
  worthless to retrieve — the page numbers point into a book the reader does not have open.
  Detected structurally (dense `term, page` refs + no sentences), so it also catches
  per-part indexes. 129 blocks / 67,886 chars in DDIA.
- **Contents lists arrive in two shapes** needing different tests: one run-on block of
  concatenated section names (structural — a block whose text is mostly the document's own
  heading vocabulary), and many short one-entry blocks (region — from a "Table of Contents"
  heading until the first real prose block). A length-gated structural test cannot see the
  second shape.
- Verify **both directions**: DDIA's per-chapter References are dense with numbers and must
  survive (150 ACM citations retained).

---

## 6. Performance: batching is structural, not an optimization

| mode | wall | per page |
|---|---|---|
| whole document, 673pp | 7,270 s (121 min) | 10.80 s |
| 100-page batch | 22.5 s | **0.22 s** |

**~49×**, at identical work density (10.2 vs 9.8 items/page — verified not a no-op). Only
258 s of CPU across those 121 minutes (3.5% utilization, 2.5M page reclaims): it was
stalling on accumulated state, not compute. Peak RSS 2.2 GB.

Reuse one converter across batches to amortize model load. **Furniture adjudication and
heading-ladder inference must run document-wide after all batches** — both depend on global
signals (cross-page repetition; the full height distribution).

---

## 7. Environment

- Model weights: `/Volumes/ExtremeSSD/docling-models` (651 MB, layout + tableformer only).
- **Three internal-disk leak paths**, not one: `~/.cache/huggingface` (`HF_HOME`),
  `~/.cache/docling` (docling's own default — easy to miss), and `~/.cache/torch`.
- **Mount-check and hard-fail.** If the volume is absent, macOS creates `/Volumes/ExtremeSSD`
  as a plain directory *on the boot volume* and silently fills it.
- HF is a **download channel, not a dependency**: prefetch once, then `HF_HUB_OFFLINE=1`.
  Weights live inside `docling-models/.hf` so they survive wiping the main HF cache.
- The drive is **exFAT**: no symlinks, so the HF cache falls back to copying (~2× footprint,
  expected) and file modes are meaningless.
- Python 3.14 works (docling supports it since 2.59.0). torch 2.13, transformers 5.8.

---

## 8. Design decisions worth not relitigating

- **Paths outrank size uniformity.** Sections are never merged across a boundary to hit a
  size target — a genuinely 192-char section yields a 192-char chunk with its true path.
  Runt tails *are* absorbed, but only **within** one section, where the path is identical by
  construction.
- **Overlap is zero.** Disjoint chunks make the markdown exactly reconstructible (the
  coverage assertion), which is how we prove nothing was lost. Overlap is a retrieval knob
  for Phase 3 — `prev_id`/`next_id` make it one hop, not a re-index.
- **Two speeds, clean boundary.** Outline records = coarse orientation
  (chapter → major section → named subsection, depth ≤5). Passages = fine retrieval. Do NOT
  deepen outline extraction to chase a single query: DDIA has no "quorum"-specific outline
  record at any sane depth, and that is correct — orienting to that granularity is the
  passage layer's job, and the passage layer hits it. Blurring the tiers to fix one case is
  the wrong fix.
- **Offsets are load-bearing.** Every block records `char_start`/`char_end` into the emitted
  body, so the document can be re-chunked without re-parsing the PDF (milliseconds vs 2.5
  minutes and a pinned model). This is what makes "markdown is truth" practical rather than
  a slogan. It requires calibrating globally but repairing **per block** — repairing after
  assembly shifts every subsequent offset and silently rots the map.
