"""One markdown file → an ingested output directory. The single ingestion implementation.

Extracted so the standalone `ingest-md` CLI command and the manifest-composition path share ONE
body — the A18 silent-loss gate, the spine validation, and the run.json shape must not diverge
between "ingest this file" and "ingest every note in the vault". Same reasoning as the chunker
being shared between the PDF and markdown arms: two copies of a silent-loss guard is one copy too
few.

The reader is a pure parser; this is where the ingest DECISIONS live: enforce the class policy,
validate the spine (strict or lenient per caller), fold in `_meta.md`-supplied class/status/domains
for a reference passage that carries none of its own, run the coverage gate, and write the four
artifacts (document.md, blocks.jsonl, chunks.jsonl, run.json) reconcile later reads.
"""

from __future__ import annotations

import json
import time
from dataclasses import dataclass, field
from pathlib import Path

from substrate import classes, spine
from substrate.chunk.chunker import chunk
from substrate.markdown.emit import emit, frontmatter
from substrate.markdown.reader import content_coverage, read_markdown, uncovered_content_blocks
from substrate.models import Kind

# A18 aggregate floor. Markdown ingestion must not silently drop source content end-to-end.
MD_COVERAGE_GATE = 0.99


class CoverageError(RuntimeError):
    """A18 — the ingest would drop source content; refuse rather than write a lossy artifact."""


@dataclass
class IngestResult:
    doc_id: str
    out_dir: Path
    status: str
    domains: list[str]
    title: str | None
    body_chars: int
    source_coverage: float
    run: dict = field(default_factory=dict)  # passage/outline counts live here under ["chunk"]


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text(
        "\n".join(json.dumps(r, ensure_ascii=False, sort_keys=True) for r in rows) + "\n",
        encoding="utf-8",
    )


def ingest_markdown(
    src: Path,
    out_dir: Path,
    *,
    doc_class: str | None = None,
    require_status: bool = False,
    override_status: str | None = None,
    override_version: str | None = None,
    extra_domains: list[str] | None = None,
    vault: str | None = None,
    tier: int | None = None,
) -> IngestResult:
    """Ingest one markdown file into `out_dir`. Raises on any refusal; never writes a partial set.

    Raises: ``ValueError`` (unreadable source), ``classes.ClassPolicyError`` (class gate),
    ``spine.SpineError`` (status contract), ``CoverageError`` (A18). The caller maps these to exit
    codes or per-note failures — the point is that a silently-lossy or mislabeled note NEVER
    reaches the index.

    `override_status` / `extra_domains` carry a reference source's `_meta.md` context down onto a
    passage file that has no frontmatter of its own: the passage inherits the source's status and
    domain tags. A value the note declares ITSELF always wins — override only fills an absence.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    t0 = time.monotonic()

    doc, body_md, rstats = read_markdown(src, doc_class=doc_class)

    # _meta.md context fills only what the note itself did not declare. `domains` is a UNION (a
    # passage may add its own tags to the source's); status is filled only when absent, so a note
    # that explicitly marks itself superseded is never silently reactivated by its source's 'active'.
    if override_status and doc.status is None:
        doc.status = override_status
    # A reference passage carries no version of its own; a versioned source's `_meta.md` supplies it,
    # so the reference-versioned class gate (which refuses a passage that cannot state its version)
    # is satisfied by the source metadata rather than by scraping the passage body.
    if override_version and doc.version is None:
        doc.version = override_version
    if extra_domains:
        merged = list(doc.domains)
        for d in extra_domains:
            if d not in merged:
                merged.append(d)
        doc.domains = merged
    doc.vault = vault
    doc.tier = tier

    meta = classes.apply(doc)
    status = spine.validate_status(doc, require_present=require_status)

    # repair=False: markdown carries no glyph artifacts, so PDF-tier hyphen/ligature repair could
    # only mutate clean authored text (measured: 8 words welded on one round-trip).
    body, estats = emit(doc, repair=False)
    chunks, cstats = chunk(doc)

    # A18 — end-to-end source→chunks coverage against the SOURCE file (A14's chunk/body ratio can't
    # see a dropped line — it leaves the body too). `captured` is everything the source content
    # should survive INTO: chunk text_with_path (a heading rides along via its path), each
    # fence-language, and every heading block's own text (an empty-section heading forms no chunk).
    captured = (
        [c.text_with_path for c in chunks]
        + [b.lang for b in doc.blocks if b.lang]
        + [b.text for b in doc.blocks if b.kind is Kind.HEADING]
    )
    src_cov, src_missing = content_coverage(body_md, captured)
    drops = uncovered_content_blocks(doc.blocks, captured)
    if src_cov < MD_COVERAGE_GATE or drops:
        raise CoverageError(
            f"A18 markdown coverage: aggregate {src_cov} (gate {MD_COVERAGE_GATE}); "
            f"{len(drops)} content block(s) dropped {drops[:8]}; missing tokens {src_missing}"
        )

    (out_dir / "document.md").write_text(frontmatter(doc, {"version_source": None}) + body, "utf-8")
    _write_jsonl(out_dir / "blocks.jsonl", [b.to_json() for b in doc.blocks])
    _write_jsonl(out_dir / "chunks.jsonl", [c.to_json() for c in chunks])

    run = {
        "doc_id": doc.doc_id,
        "source": str(src),
        "source_sha256": doc.source_sha256,
        "pages": doc.source_pages,
        "source_format": "markdown",
        "elapsed_s": round(time.monotonic() - t0, 1),
        "class": meta,
        "extract": {
            "extractor": doc.extractor, "extractor_arm": doc.extractor_arm,
            "layout_model": doc.layout_model,
            "source_coverage": src_cov, "source_coverage_missing": src_missing,
            "content_block_drops": drops, **rstats,
        },
        "emit": estats,
        "chunk": cstats,
        "coverage": round(cstats["sum_chunk_chars"] / max(len(body), 1), 4),
        # Spine block travels with the ingest so reconcile rebuilds status/domains/supersession into
        # the index; it is folded into reconcile's diff key, so editing a note's status re-indexes.
        "spine": {
            "status": status,
            "domains": list(doc.domains),
            "superseded_by": doc.superseded_by,
            "supersedes": doc.supersedes,
        },
    }
    if vault is not None or tier is not None:
        run["provenance"] = {"vault": vault, "tier": tier}
    (out_dir / "run.json").write_text(json.dumps(run, indent=2, ensure_ascii=False), "utf-8")

    return IngestResult(
        doc_id=doc.doc_id, out_dir=out_dir, status=status, domains=list(doc.domains),
        title=meta.get("title"), body_chars=len(body), source_coverage=src_cov, run=run,
    )
