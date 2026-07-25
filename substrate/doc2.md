# Document 2 — Knowledge Brain: Structure & Inheritance Spec

The concrete, buildable blueprint. Companion to the Information Substrate Model
(the "what/why") and the engine build spec (the "engine").

**Scope of this document: SHAPE, not storage.** It specifies the structure a vault
must have for the engine to read it, and how inheritance works. It is deliberately
SILENT on where any of it lives. Storage, versioning, and backup are user-determined
— the system defines shape; the user owns location and lifecycle. (See §0.)

Architecture: **Option A** — shared core is its own vault; project vaults are separate
vaults; the engine composes them AT RETRIEVAL by indexing core + the active project
together. Inheritance = "which vaults the engine loads," expressed as a per-vault
manifest. Not submodules (Option C rejected: N copies = structural version-divergence).
The engine is the front door; Obsidian browsing is secondary.

---

## 0. What the system owns vs. what the user owns

| | Owned by | Notes |
|---|---|---|
| **Shape** — folder structure, manifest format, frontmatter schema, status semantics | **System (fixed contract)** | The engine must know these to read a vault. Not user-optional. |
| **Content** — every note, every ingested doc, operator knowledge | **User** | |
| **Storage / versioning / backup** — git? cloud? local? where? | **User** | The engine reads paths from the manifest; it has no opinion on where those paths physically live. |
| **Actors** — which models drive ingestion/retrieval | **User** | Apple FM default; user may point at their own local models. |

The engine operates on **whatever paths the manifest points to**. Git, iCloud, Dropbox,
a NAS, local-only — the system is indifferent. One piece of *guidance* (not a rule): do
not cloud-sync the live index DB (§5) — syncing a live SQLite file across machines
corrupts it. That's a warning to the user, not a system constraint.

---

## 1. The vaults

| Vault | Tier | What it is | Internal structure | Inherits |
|---|---|---|---|---|
| `core-vault` | 1 + 2 | Shared core: operator knowledge + grounded reference | bespoke (§3) | nothing — it's the root |
| `<project>-vault` | 3 | Per-project knowledge (prism, scripta, cbre, school, …) | project skeleton (§4) | core-vault |

Plus, per machine: a derived **index** (SQLite, FTS + vectors) — disposable, rebuilt
from the markdown the manifest points to. Where it lives is the user's choice; the only
guidance is "not on cloud-sync" (§5).

The engine composes at retrieval: aim it at a project vault, it reads that vault's
manifest, loads the vault + everything it inherits, indexes the union, retrieves across
it. That IS inheritance — no copies, no sync.

---

## 2. The manifest (SYSTEM CONTRACT — fixed format, user fills values)

Each project vault has a root `.substrate.toml`. The **format is fixed by the system**
(the engine parses it); the **values are the user's**.

```toml
name = "prism"
inherits = ["core-vault"]              # which vaults to load into scope

[reference_pins]                       # versioned-doc supersession is PER PROJECT
react = "18"                           # this project pins 18 as "current"; 19 treated
go = "1.21"                            #   as superseded-for-this-context
# unpinned versioned docs default to latest available

# OPTIONAL — domain context for this project (§3a). Applied as a SOFT retrieval
# weight, never a hard filter, so cross-domain sources stay reachable. Eval-gated.
reference_domains = ["software-dev", "networking"]
```

- **Per-vault, not central.** A vault is self-describing; adding a project needs no
  central edit.
- **core-vault has no manifest / inherits nothing.** It's the root. Read-only-upward:
  projects read FROM core; nothing auto-writes INTO core. Promoting a project insight to
  operator-tier is a deliberate manual act, never automatic — project churn cannot leak
  into the tier every context inherits. **core-vault is fundamentally unmovable except
  when its own reference docs are superseded** (e.g. React 18→19 within the versioned
  tier).
- **`reference_pins` resolves versioned supersession by context.** Whether React 18 or
  19 is "current" is NOT global — it's what the project pins. Frozen refs (textbooks,
  papers) have no versions and no pins — always current.

---

## 3. core-vault structure (bespoke — grounded knowledge is a different shape)

```
core-vault/
├── 00-operator/              # TIER 1 — how the user works (style, cadence, disciplines)
├── 10-reference/             # TIER 2 — grounded hard knowledge
│   ├── frozen/               #   textbooks, papers — fixed, no versions
│   │   └── <domain>/         #     PRIMARY domain folder (human navigation) — §3a
│   │       └── <source-slug>/#       one folder per source
│   │           ├── _meta.md  #         metadata incl. domains: [...] (the retrieval axis)
│   │           ├── structure.md  #     extracted outline/hierarchy
│   │           └── passages/ #         chunked markdown (the engine's read-target)
│   └── versioned/            #   language/library docs — version-pinned
│       └── <domain>/<name>/<version>/  # domain folder + version folder; manifest pins select version
├── _index/MEMORY.md          # content map — read first on navigation
├── log.md                    # append-only change log
└── 99-templates/
```

Reference markdown = the reviewed, corrected ingest output; it's the engine's
read-target (re-ingesting is slow + non-deterministic across Docling versions, so the
reviewed output is what the engine reads). Whether the user commits it, where they keep
the original PDFs, whether any of it is versioned or backed up — **user's choice, not
specified here.**

### 3a. Domains (folder-for-humans, tag-for-the-engine)

Tier 2 is the unboundedly-growing tier — eventually many sources across software-dev,
networking, data/ML, etc. Domains organize it, but domains **blur** (a network-protocol
design source is "networking" when debugging a socket and "software-dev" when
architecting a service). So a rigid one-folder-per-source taxonomy would file a source
under one angle and HIDE it from the other angle that needed it.

Resolution — same primitive already used for archive-status and versioned-docs (physical
structure for humans, frontmatter for the engine):

- **Primary-domain folder** = human navigation. A source physically lives in ONE domain
  folder (its primary domain), so you can browse `software-dev/` and see your CS books.
- **`domains: [...]` in `_meta.md`** = the real retrieval axis, **multi-valued**. The
  engine reads the tags, not the folder. A source in `data-ml/` can tag
  `[data-ml, networking, distributed-systems]` and a networking-scoped query still finds
  it. Overlap never hides a source.

```yaml
# core-vault/10-reference/frozen/software-dev/ddia-2e/_meta.md
domains: [software-dev, distributed-systems, databases]
class: reference-frozen
```

**Domain as active-context bias (soft weight, NOT a hard filter) — eval-gated, deferred.**
Beyond passive labels, the *query's context* can carry a domain hint that **weights**
matching-domain sources higher — so the same query surfaces different top results
depending on which domain you're working in (the point of "you need something in a
particular context"). Critical: this is a **soft boost, never a hard exclude** — a hard
domain filter would re-introduce the hiding problem (a software-dev query with a
networking-exclude would miss the network-protocols source that was *also* the right
software-dev answer). Soft bias keeps the blur available while tilting toward the active
context.

This is another retrieval config axis, measured like HyDE/rerank: sweep domain-weight
off vs. on against the gold set, keep only if MRR clears the resolution floor. **Requires
cross-domain near-miss gold cases** (right answer in domain A, plausible-wrong answer in
domain B) or it can't be honestly measured. Deferred until Tier 2 has enough sources and
the gold set has those cases.

**Don't pre-build the taxonomy.** Add the `domains: [...]` field now (it's the right
primitive and it's cheap), use a handful of broad domain folders, and let sub-domains
emerge as tags when a domain gets crowded — a source tagged
`[software-dev, distributed-systems]` already gives both levels without a rigid tree.
Designing a deep domain hierarchy for content that doesn't exist yet is the
work-on-the-system-instead-of-in-it trap.

### 3b. Three-layer lineage — raw is kept

Ingestion is not a one-way door. The full lineage of a reference source is **three
layers**, each regenerating the one to its right:

```
raw source (PDF)   →   reviewed markdown   →   derived index
  IMMUTABLE              source-of-truth         disposable
  ground truth           for retrieval           (SQLite, §5)
  the only               regenerate index
  irreplaceable layer    from markdown
  ↑ regenerate markdown from raw when the pipeline improves
```

**Raw is kept by default.** Reasons, all load-bearing given this system:
- **Re-ingestion is non-deterministic and the pipeline improves.** Docling output varies
  across versions; chunking/structure-extraction will get better (the figure-merge
  artifact, the oversize-gate fix — the pipeline is young). Every improvement is
  worthless on already-ingested content unless it can be re-run against the raw.
  Discarding the PDF freezes that source on today's chunking forever.
- **Markdown is a lossy derivative.** PDF→markdown drops figures, table formatting,
  layout, images. If a future need wants what extraction lost, raw is the only recourse.
- **Provenance completeness.** "Where a chunk came from" is a page of a PDF. If the PDF
  is gone, the grounding chain dead-ends at the markdown — you can cite "DDIA p347" but
  not produce it. A system selling grounded, verifiable knowledge must be able to show
  the source.

Raw is the ONLY irreplaceable layer — index rebuilds from markdown, markdown regenerates
from raw. So raw is the only truly precious artifact; everything downstream is
reconstructible.

**System-design vs. user-storage split (per §0):**
- **Retention is system-design:** keep raw by default. *Discarding* raw is a deliberate
  per-source opt-out (for a source you're certain you'll never re-ingest, or where
  size/copyright makes retention undesirable — user's call, but the exception, not the
  default).
- **Location is user-storage:** raw must be *retained and findable*, not necessarily
  co-located. Vault, cloud drive, NAS, a `raw/` folder beside the markdown — user's
  choice, unspecified here.
- **The markdown→raw pointer IS system-contract provenance.** Each source's `_meta.md`
  records a pointer to its raw origin, so the regeneration path can't be lost:

```yaml
# _meta.md
domains: [software-dev, distributed-systems, databases]
class: reference-frozen
raw: { ref: "ddia-2e.pdf", sha256: "…", location: "user-defined" }  # pointer is contract; location is user's
```

Without the pointer, "keep the raw" degrades into "have some PDFs somewhere with no idea
which markdown came from which." The pointer is shape (system-owned); what it points at
is storage (user-owned).

---

## 4. Project vault skeleton (shared across ALL project vaults)

Every project vault uses the same structure, so the engine and the user know where
anything is in any project, and a new project scaffolds from one template.

```
<project>-vault/
├── .substrate.toml           # manifest (§2)
├── 00-index/MEMORY.md        # project content map
├── 02-areas/                 # active work threads
├── 03-references/            # project-LOCAL references (scope-of-reuse decides:
│                             #   everyone → core-vault/10-reference; one project → here)
├── 04-synthesis/             # LLM-entry synthesis notes
├── _archive/                 # complete threads, moved out of active surface (§ status)
├── log.md                    # append-only change log
└── 99-templates/
```

Project-specific folders may be added, but the skeleton is constant. A reference's tier
is decided by **scope of reuse**, not doc type.

---

## 5. The derived index & freshness (interim — watcher deferred)

- SQLite (FTS5 + sqlite-vec). The rightmost layer of the §3b lineage — rebuilt from the
  markdown the manifest points to: `substrate index`. (Markdown in turn regenerates from
  raw when the pipeline improves — §3b.)
- **Guidance (not a system rule): do not cloud-sync the live DB** — live-SQLite over
  file-sync corrupts. Keep it on the machine that queries it; rebuild per machine.
- **Freshness is DETECTABLE, not automatic.** No watcher yet. The index carries
  `index_version`; results carry it, so a stale index is *detectable* (a caller can
  notice missing docs) rather than silently omitting. Converts silent-omission →
  detectable-omission. Manual `substrate index` after ingesting is still required.
  Watcher/daemon: explicitly deferred.

---

## 6. Archive & supersession — the status field the engine enforces

Every note carries a `status` in frontmatter. The engine's default retrieval set depends
on it:

| status | meaning | default retrieval |
|---|---|---|
| `active` | live, current | included |
| `complete` | done, correct, finished | included |
| `archived` | complete + moved out of active surface | **excluded** unless explicitly queried |
| `superseded` | replaced by newer content | **excluded** directly, but its supersession *link* surfaces when the superseding note is retrieved |

- **complete ≠ superseded.** Complete = done and correct (archive freely). Superseded =
  replaced, but the history is why you'd never re-litigate it (keep in place, linked).
  Archiving both identically destroys decision history — the flattening the spine exists
  to prevent.
- **You never retrieve a dead fact directly**, but pulling the live one surfaces "this
  replaced X."
- **Archive is a folder AND a field.** `_archive/` is the human view; `status:` is what
  the engine reads. They must agree (a lint check).

---

## 7. Result contract (one envelope; CLI, MCP, future GUI are thin adapters)

```
{
  passages: [ { snippet, path, provenance, timestamp, expand_ref } ],  # snippet-first
  outline_records: [ ... ],          # two-speed: chapter/area orientation
  retrieval_mode: {                  # graduated degradation, MEASURED cost
    embedder: <name> | null,         #   null → ~0.21 MRR (catastrophic)
    generator: "up" | null,          #   null → ~0.375 MRR (no HyDE/rerank)
    degraded: <bool>,
    expected_mrr: <float>            #   empirical, from the eval — un-smoothable
  },
  index_version: <hash/timestamp>    # detectable staleness
}
```

Degradation is graduated and quantified (what's missing AND how much worse, from the
eval's own numbers) — fields, not prose, so it can't be smoothed into false confidence.
Snippet-first payload (~5× cheaper than full chunks), expand on demand.

---

## 8. Migration (one-time, supervised — NOT automated)

Overhauling existing vaults into this structure is a one-time, high-judgment, supervised
job — full of "superseded vs. deliberately preserved" calls on every old note. Do it by
hand, with Claude in-session, NOT via an unsupervised pass. Only AFTER migration does a
weekly report-only lint make sense (no defined correct-state to audit against until the
vaults are in this structure).

Order: (1) finalize this structure → (2) scaffold empty vaults + template → (3) migrate
old vaults supervised, note-by-note → (4) then schedule report-only lint.

---

## Open threads (deferred, named so they're not silent)

- **Index watcher/daemon** — freshness detectable but manual.
- **Weekly lint automation** — report-only, post-migration only; scope (flag vs.
  propose-diff vs. write) TBD, default flag-only.
- **Reference-tier ingestion at scale** — one book validated (Phase 0); a shelf is a
  batch effort not yet run.
- **Domain active-context weighting (§3a)** — soft retrieval bias by domain; needs
  cross-domain near-miss gold cases to measure. `domains: [...]` tags shipped now;
  the weighting feature deferred until content + gold cases exist.
- **Doc 3 (UI)** — how the user SEES/manages the brain (folded "Ask" vs. surfaced
  "Library"), and reconciling the shipped model-assignment defaults to the eval winners.

## Related
- Information Substrate Model spec (Doc 1)
- substrate-engine build spec
- LLM-Wiki Pattern Adoption spec (log.md, /lint-vault, /ingest)
