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
from substrate.extract.base import doc_id_for, doc_id_from  # stdlib-only; no Docling/torch pulled in
from substrate.markdown.emit import emit, frontmatter
from substrate.markdown import reader
from substrate.markdown.reader import content_coverage, read_markdown, uncovered_content_blocks
from substrate.models import Kind, SourceOrigin

# A18 aggregate floor. Markdown ingestion must not silently drop source content end-to-end.
MD_COVERAGE_GATE = 0.99


class CoverageError(RuntimeError):
    """A18 — the ingest would drop source content; refuse rather than write a lossy artifact."""


class UnretrievableError(RuntimeError):
    """The ingest produced NO retrievable unit — a document that indexes and answers nothing.

    Distinct from A18, which asks whether content survived into the chunks. This asks whether
    there are any chunks. Measured 2026-08-04: a JPEG of a two-line sign OCR'd into two blocks
    that Docling labelled as headings and nothing else, so the chunker — which correctly forms no
    chunk for an empty-section heading — emitted zero. Every gate was green: A18 source coverage
    1.0 with no dropped blocks (heading text rides into `captured` by design), the class policy
    satisfied, the spine valid. The result was a document row with `passages 0 · outlines 0`.

    Nothing was lost — the text is in document.md and blocks.jsonl — and that is exactly why no
    loss gate could see it. What is wrong is retrievability: the document reads as ingested and
    can never be returned.

    ONLY RAISED WHEN AN `origin` IS SET, i.e. on the converted and text arms. The vault path is
    deliberately untouched: a heading-only note is legal markdown, this would refuse it, and the
    refusal would land inside a launchd `compose` that runs unattended every fifteen minutes.
    Widening a gate onto the existing corpus is a separate decision with its own blast radius.
    """


@dataclass
class IngestResult:
    doc_id: str
    out_dir: Path
    status: str
    domains: list[str]
    doc_type: str
    confidence: str
    title: str | None
    body_chars: int
    source_coverage: float
    run: dict = field(default_factory=dict)  # passage/outline counts live here under ["chunk"]


def _write_jsonl(path: Path, rows: list[dict]) -> None:
    path.write_text(
        "\n".join(json.dumps(r, ensure_ascii=False, sort_keys=True) for r in rows) + "\n",
        encoding="utf-8",
    )


def _meta_path_for(note_path: Path) -> Path | None:
    """The `_meta.md` a passage inherits from, for error attribution only. Mirrors vault._source_meta
    (nearest enclosing `passages/` ancestor); None when the note is not under one."""
    parts = note_path.parts
    if "passages" not in parts:
        return None
    return Path(*parts[: len(parts) - 1 - parts[::-1].index("passages")]) / "_meta.md"


def ingest_markdown(
    src: Path,
    out_dir: Path,
    *,
    doc_class: str | None = None,
    require_status: bool = False,
    require_confidence: bool = False,
    override_status: str | None = None,
    override_doc_type: str | None = None,
    override_confidence: str | None = None,
    raw: str | None = None,
    raw_sha256: str | None = None,
    raw_location: str | None = None,
    override_version: str | None = None,
    extra_domains: list[str] | None = None,
    vault: str | None = None,
    tier: int | None = None,
    origin: SourceOrigin | None = None,
) -> IngestResult:
    """Ingest one markdown file into `out_dir`. Raises on any refusal; never writes a partial set.

    Raises: ``ValueError`` (unreadable source), ``classes.ClassPolicyError`` (class gate),
    ``spine.SpineError`` (status contract), ``CoverageError`` (A18). The caller maps these to exit
    codes or per-note failures — the point is that a silently-lossy or mislabeled note NEVER
    reaches the index.

    `override_status` / `extra_domains` carry a reference source's `_meta.md` context down onto a
    passage file that has no frontmatter of its own: the passage inherits the source's status and
    domain tags. A value the note declares ITSELF always wins — override only fills an absence.

    `origin` is set when `src` is not the real source — a DOCX/PPTX/HTML/image converted to a
    temporary markdown file by `extract.convert`. It is why the converted formats reach the SAME
    three gates as a vault note rather than getting a second ingest body of their own: this
    function is where the class policy, the spine contract and A18 live, and a parallel
    implementation would be a second place to forget one. See models.SourceOrigin.
    """
    out_dir.mkdir(parents=True, exist_ok=True)
    t0 = time.monotonic()

    doc, body_md, rstats = read_markdown(src, doc_class=doc_class)

    # Identity moves to the REAL artifact before anything reads it. Done here rather than after
    # the gates because `classes.apply` enforces `source_sha256` as a required field and
    # `emit.frontmatter` writes all four of these into document.md — a document that named a
    # deleted temp file would pass every gate while being unreproducible.
    if origin is not None:
        doc.source_path = origin.path or doc.source_path
        doc.source_sha256 = origin.sha256 or doc.source_sha256
        doc.extractor = origin.extractor or doc.extractor
        doc.extractor_arm = origin.extractor_arm or doc.extractor_arm
        doc.source_pages = origin.pages or doc.source_pages

        # THE SPINE IS NOT A FOREIGN DOCUMENT'S TO DECLARE, and `origin is not None` is exactly the
        # test for "foreign": `compose` — the vault path, where a note's frontmatter IS authoritative
        # because the operator wrote it — calls this function with no origin at all.
        #
        # Without this, a file handed to `ingest` set its own `status`, `doc_type`, `confidence`,
        # `document_class`, `doc_id` and supersession, because `read_markdown` reads all of them from
        # frontmatter and nothing downstream disagreed. A `.txt` or `.md` opening with
        #
        #     ---
        #     status: active
        #     doc_type: decision
        #     confidence: verified
        #     document_class: reference-frozen
        #     domains: [prism, security]
        #     ---
        #
        # was promoted, composed and registered into `~/.substrate/scopes.toml` — the registry Claude
        # Code and Zed read — and served back to the operator's agents as a settled, verified,
        # frozen decision. That is the persistent prompt-injection and false-decision primitive Doc 3
        # §3 keeps off the loopback port, reached by dropping a file on the Library instead.
        #
        # `doc_id` is the sharper half and was the easier one to miss: `reconcile` keys its
        # delete-then-insert on it, so a crafted id does not add a document, it REPLACES a real one's
        # index row. Derived from the real artifact here rather than left to `origin.doc_id or ...`,
        # because the text arm sets no `doc_id` on its origin and the old expression then fell
        # through to the document's own.
        #
        # Cleared to ABSENCE, not to a safe-looking value: absence is what `classes.apply` and the
        # upsert defaults are built to resolve (→ `unclassified` / `active` / `reference` /
        # `unjudged`), and writing a real value here would be this function inventing a claim on the
        # operator's behalf — the thing it is refusing to let the document do.
        # Three ways to reach the same shape, cheapest first, and none of them the document's own:
        # the converted arm already computed one; a caller that named the real artifact and its
        # fingerprint gets it without touching disk (the artifact may be gone, and re-hashing a file
        # to recover a value already in hand is waste); otherwise `src` IS the real file — the
        # markdown and text arms read it directly — so hashing it is correct rather than a fallback.
        if origin.doc_id:
            doc.doc_id = origin.doc_id
        elif origin.path and origin.sha256:
            doc.doc_id = doc_id_from(Path(origin.path).stem, origin.sha256)
        else:
            doc.doc_id = doc_id_for(Path(src))
        if not doc_class:
            doc.document_class = ""
        doc.status = None
        doc.doc_type = None
        doc.confidence = None
        doc.supersedes = []
        doc.superseded_by = None
        # `domains` too, and it is the one that looks harmless. It is not a claim about how settled
        # the document is — it is what retrieval FILTERS on, so a file that tags itself
        # `[prism, security]` chooses which questions it surfaces for. That is the delivery half of
        # the same primitive: the other fields decide whether a passage is believed, this one decides
        # whether it is reached. The operator's own tags are unaffected — `extra_domains` merges as a
        # UNION below and carries the `_meta.md` the app writes, which is the channel a domain is
        # supposed to arrive on.
        doc.domains = []

    # _meta.md context fills only what the note itself did not declare. `domains` is a UNION (a
    # passage may add its own tags to the source's); status is filled only when absent, so a note
    # that explicitly marks itself superseded is never silently reactivated by its source's 'active'.
    # Track which spine values came from the SOURCE rather than the note, so a refusal can name the
    # file the operator must actually edit. An error naming the wrong component with total
    # confidence is a failure this project has already paid for (the AppleFM cache_key bug logged
    # against the embedder), and here it is the EXPECTED migration failure: the real source vaults
    # write `confidence: high`, so a book-sized source would otherwise print one refusal per
    # passage, each blaming a passage file that contains no such value.
    inherited: dict[str, Path | None] = {}
    if override_status and doc.status is None:
        doc.status = override_status
        inherited["status"] = _meta_path_for(src)
    # doc_type inherits the same way: a reference passage carries no frontmatter, so its source's
    # `_meta.md` doc_type (reference) fills the absence; a note that declares its own job always wins.
    if override_doc_type and doc.doc_type is None:
        doc.doc_type = override_doc_type
        inherited["doc_type"] = _meta_path_for(src)
    # confidence inherits identically: a reference source states once, in its `_meta.md`, how
    # settled its passages are; a passage that declares its own always wins.
    if override_confidence and doc.confidence is None:
        doc.confidence = override_confidence
        inherited["confidence"] = _meta_path_for(src)
    # §3b: a passage inherits its source's raw pointer. This is the mechanism by which a chunk can
    # name the artifact it ultimately came from — the passage file itself has no idea.
    doc.raw = doc.raw or raw
    doc.raw_sha256 = doc.raw_sha256 or raw_sha256
    doc.raw_location = doc.raw_location or raw_location
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

    # Last-resort title for a converted document with no heading and no declared title — a
    # one-slide deck, a bare spreadsheet. `classes.apply` would otherwise refuse it for a missing
    # required field, which is the right answer for a vault note (a note that cannot name itself
    # is unfindable) and the wrong one for a file the operator named themselves. Ordered so the
    # document's own heading always wins, and `title_source` records which of the three it was.
    title_source = "declared" if doc.title else ("heading" if classes.extract_title(doc) else None)
    if origin is not None and not doc.title:
        doc.title = classes.extract_title(doc) or origin.title
        title_source = title_source or ("filename" if doc.title else None)

    meta = classes.apply(doc)
    try:
        status = spine.validate_status(doc, require_present=require_status)
        doc_type = spine.validate_doc_type(doc, require_present=require_status)
        # Confidence rides its OWN flag, not require_status, because the two gates have different
        # blast radii. require_status is safe to demand everywhere: the migration authored a status
        # for every note. Demanding confidence on the same flag would refuse 530 of 657 indexed
        # notes at the next compose — run unattended every 15 minutes by a launchd agent, and
        # silent, because compose returns before opening the IndexStore, so each scope keeps
        # answering queries from its last good DB while frozen. So `notes.py` (a human is writing
        # this note now) passes True and `compose` does not. See spine.validate_confidence.
        confidence = spine.validate_confidence(doc, require_present=require_confidence)
    except spine.SpineError as e:
        # Attach the ORIGIN of the offending value. Which field failed is in the message already;
        # what the operator cannot see is that the value came from a `_meta.md` one directory up.
        for field, meta_path in inherited.items():
            if meta_path is not None and f"{field} " in str(e):
                raise spine.SpineError(f"{e} (inherited from {meta_path})") from e
        raise

    # repair=False: markdown carries no glyph artifacts, so PDF-tier hyphen/ligature repair could
    # only mutate clean authored text (measured: 8 words welded on one round-trip).
    body, estats = emit(doc, repair=False)
    chunks, cstats = chunk(doc)

    # Zero retrievable units. Checked BEFORE A18, because A18 would pass — see UnretrievableError:
    # no content was lost, there is simply nothing to return. Origin-scoped so the vault corpus,
    # where a heading-only note is legal, is untouched.
    if origin is not None and not chunks:
        # The REAL artifact's name, not `src` — on the converted arm `src` is the throwaway
        # markdown, and an error naming a temp file the operator never saw sends them after the
        # wrong component. Same reasoning as the `_meta.md` attribution a few lines up.
        name = Path(origin.path).name if origin.path else src.name
        raise UnretrievableError(
            f"{origin.source_format}: {name} produced 0 chunks from {len(doc.blocks)} block(s) "
            f"and {len(body)} characters of body — the document would index and answer nothing. "
            "Every other gate passes: nothing was lost, there is nothing retrievable. Usual cause "
            "is a source whose every block came through as a heading (an OCR'd sign, a title-only "
            "slide), which forms no passage because an empty-section heading has no body."
        )

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
        "source": doc.source_path,
        "source_sha256": doc.source_sha256,
        "pages": doc.source_pages,
        # The ORIGINAL format — "markdown" for a note, "docx"/"image"/… for a converted document.
        # `ingest_arm` is the separate fact and the two must not be conflated: checks.py picks the
        # applicable assertion set (A18/A19 on, A1/A1b off) by which ARM ran, not by what the file
        # started as, and a converted DOCX runs the markdown arm end to end. Conflating them would
        # have silently dropped A18 from every converted document the moment `source_format`
        # stopped saying "markdown".
        "source_format": origin.source_format if origin else "markdown",
        "ingest_arm": "markdown",
        "elapsed_s": round(time.monotonic() - t0, 1),
        "class": meta,
        "extract": {
            "extractor": doc.extractor, "extractor_arm": doc.extractor_arm,
            "layout_model": doc.layout_model,
            "source_coverage": src_cov, "source_coverage_missing": src_missing,
            "content_block_drops": drops, "title_source": title_source, **rstats,
            **(origin.stats if origin else {}),
        },
        "emit": estats,
        "chunk": cstats,
        "coverage": round(cstats["sum_chunk_chars"] / max(len(body), 1), 4),
        # Spine block travels with the ingest so reconcile rebuilds status/domains/supersession into
        # the index; it is folded into reconcile's diff key, so editing a note's status re-indexes.
        "spine": {
            "status": status,
            "domains": list(doc.domains),
            "doc_type": doc_type,
            "confidence": confidence,
            "raw": doc.raw,
            "raw_sha256": doc.raw_sha256,
            "raw_location": doc.raw_location,
            "superseded_by": doc.superseded_by,
            # Normalised on the way OUT as well as in. `reconcile` normalises on the way back, so
            # this is not what stops a bad shape reaching the store — it is what stops the ARTIFACT
            # itself being wrong. run.json is read by more than one consumer and is what a person
            # inspects when a note looks wrong; an artifact that disagrees with the note it
            # describes sends the next reader after the wrong component.
            "supersedes": reader.doc_id_list(doc.supersedes),
        },
    }
    if vault is not None or tier is not None:
        run["provenance"] = {"vault": vault, "tier": tier}
    (out_dir / "run.json").write_text(json.dumps(run, indent=2, ensure_ascii=False), "utf-8")

    return IngestResult(
        doc_id=doc.doc_id, out_dir=out_dir, status=status, domains=list(doc.domains),
        doc_type=doc_type, confidence=confidence, title=meta.get("title"),
        body_chars=len(body),
        source_coverage=src_cov, run=run,
    )
