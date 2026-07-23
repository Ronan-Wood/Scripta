"""Rebuild the index from the ingested output directories — what makes the DB disposable.

The claim "the ingested artifacts in out/ are the source of truth, the index is a cache" is
only true if it can be demonstrated. This module is the demonstration: drop the database, run
reconcile, and the index is identical. If that ever stops holding, state has leaked into the
DB and the design is broken, not the migration.

Change detection reuses the per-(doc, stage) `stage_ledger` (ScriptaCore's enrichment_ledger),
which reconcile already writes: the "index" stage's content_hash is a sha256 over the INDEXED
disk state — chunks.jsonl + run.json's `class` block. It must cover the chunks and class, not
the markdown: a `rechunk` rewrites chunks.jsonl while leaving document.md byte-identical, so
keying on the markdown alone silently kept the OLD chunks. Only the stable `class` block of
run.json is folded in, never its timing fields (elapsed_s / internal_cache), so a re-run of
unchanged artifacts does not spuriously re-index.
"""

from __future__ import annotations

import hashlib
import json
from dataclasses import dataclass, field
from pathlib import Path

from substrate.models import Chunk, Document
from substrate.store.index_store import IndexStore


@dataclass
class Report:
    added: list[str] = field(default_factory=list)
    updated: list[str] = field(default_factory=list)
    unchanged: list[str] = field(default_factory=list)
    removed: list[str] = field(default_factory=list)
    chunks: int = 0

    @property
    def wrote(self) -> bool:
        return bool(self.added or self.updated or self.removed)


def _load_dir(d: Path) -> tuple[Document, list[Chunk], dict, bytes, str] | None:
    """Rehydrate one ingested output directory.

    Returns (doc, chunks, run, chunks_bytes, markdown_sha256). The raw chunks.jsonl bytes and
    the parsed run.json are handed back so the caller hashes the EXACT bytes it just parsed —
    one read per file, and no window for a file to change between building the chunks and
    hashing them. markdown_sha256 is provenance for the documents row, NOT the diff key.
    """
    md, cj, rj = d / "document.md", d / "chunks.jsonl", d / "run.json"
    if not (md.exists() and cj.exists() and rj.exists()):
        return None

    run = json.loads(rj.read_text("utf-8"))
    cls = run.get("class", {})
    extract = run.get("extract", {})
    # Provenance comes from run.json, not a hardcoded "docling": the markdown arm is the first
    # non-docling producer, and stamping every ingest docling was the Boundary-Principle failure
    # in miniature (the producer knew the arm; the consumer overwrote it). Default preserves the
    # existing PDF corpus, whose run.json predates these keys.
    doc = Document(
        doc_id=run["doc_id"],
        source_path=run["source"],
        source_sha256=run["source_sha256"],
        source_pages=run["pages"],
        document_class=cls.get("document_class", "reference-frozen"),
        title=cls.get("title"),
        version=cls.get("version"),
        version_date=cls.get("version_date"),
        extractor=extract.get("extractor", ""),
        extractor_arm=extract.get("extractor_arm", "docling"),
        layout_model=extract.get("layout_model", "docling-layout-heron"),
    )

    markdown_sha256 = hashlib.sha256(md.read_bytes()).hexdigest()
    chunks_bytes = cj.read_bytes()
    chunks: list[Chunk] = []
    for line in chunks_bytes.decode("utf-8").splitlines():
        if not line.strip():
            continue
        r = json.loads(line)
        c = Chunk(
            chunk_id=r["chunk_id"], doc_id=r["doc_id"], kind=r["kind"], text=r["text"],
            path=r["path"], level=r["level"], block_ids=r["block_ids"],
            char_start=r["char_start"], char_end=r["char_end"],
            page_start=r["page_start"], page_end=r["page_end"], n_chars=r["n_chars"],
            part_index=r["part_index"], part_count=r["part_count"],
            oversize=r["oversize"], prev_id=r["prev_id"], next_id=r["next_id"],
            document_class=r["document_class"], version=r["version"],
            source_sha256=r["source_sha256"], page_label_offset=r["page_label_offset"],
        )
        chunks.append(c)
    return doc, chunks, run, chunks_bytes, markdown_sha256


def reconcile(store: IndexStore, out_root: Path) -> Report:
    """Bring the index in line with every ingested document under out_root."""
    rep = Report()
    seen: set[str] = set()

    for d in sorted(p for p in out_root.iterdir() if p.is_dir()):
        loaded = _load_dir(d)
        if loaded is None:
            continue
        doc, chunks, run, chunks_bytes, markdown_sha256 = loaded
        md_path = str((d / "document.md").resolve())
        # Track by doc_id, the same key the diff-check and removal sweep use. Keying `seen` on
        # markdown_path instead would let a renamed out/ dir (same doc_id, identical content)
        # report `unchanged` and then be swept as `removed` in the same pass — the stored
        # markdown_path still points at the old dir, which is no longer `seen`.
        seen.add(doc.doc_id)

        # Diff key over the INDEXED disk state: the chunks and the class block. A rechunk (new
        # chunks.jsonl, identical markdown) or a hand-edit of run.json's class (correcting a
        # misdetected title/version) changes it; a re-run of unchanged artifacts does not. Only
        # the stable class block is hashed, never run.json's timing fields. The key lives in
        # stage_ledger — the ledger reconcile already writes, keyed by doc_id.
        content_sha = hashlib.sha256(
            b"\x00".join((
                chunks_bytes,
                json.dumps(run.get("class", {}), sort_keys=True).encode("utf-8"),
            ))
        ).hexdigest()
        known = store.stage_hash(doc.doc_id, "index")
        if known == content_sha:
            rep.unchanged.append(doc.doc_id)
            continue

        mtime = (d / "document.md").stat().st_mtime
        n = store.upsert(
            doc, chunks,
            markdown_path=md_path, markdown_mtime=mtime, markdown_sha256=markdown_sha256,
            coverage=run.get("coverage"),
        )
        rep.chunks += n
        # upsert commits the chunks BEFORE record_stage writes the ledger, so the ledger can
        # never claim a doc is indexed when its chunks are not (a crash between the two just
        # re-indexes next time — safe).
        store.record_stage(doc.doc_id, "index", content_sha, doc.extractor)
        (rep.updated if known is not None else rep.added).append(doc.doc_id)

    # Removed on disk -> removed from the index, keyed on doc_id (NOT markdown_path — see the
    # `seen` note above). documents() returns a materialized snapshot, so removing during
    # iteration is safe; remove() also clears the doc's stage_ledger rows, keeping the diff key
    # and the index consistent.
    for d_row in store.documents():
        if d_row["doc_id"] not in seen:
            store.remove(d_row["doc_id"])
            rep.removed.append(d_row["doc_id"])

    if rep.wrote:
        store.checkpoint()
    return rep
