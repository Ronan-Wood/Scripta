"""Rebuild the index from markdown — the property that makes the index disposable.

The claim "markdown is the source of truth, the index is a cache" is only true if it can be
demonstrated. This module is the demonstration: drop the database, run reconcile, and the
index is identical. If that ever stops holding, state has leaked into the DB and the design
is broken, not the migration.

Diff key is (mtime, sha256). ScriptaCore uses mtime alone with a 0.01s tolerance; the hash
is added here because these documents are rebuilt by a pipeline rather than edited by hand,
so a rewrite can produce identical content with a fresh mtime, and re-indexing 1,100 chunks
for an unchanged file is pure waste.
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


def sha256_text(text: str) -> str:
    return hashlib.sha256(text.encode("utf-8")).hexdigest()


def _load_dir(d: Path) -> tuple[Document, list[Chunk], str] | None:
    """Rehydrate one ingested output directory. Returns (doc, chunks, markdown)."""
    md, cj, rj = d / "document.md", d / "chunks.jsonl", d / "run.json"
    if not (md.exists() and cj.exists() and rj.exists()):
        return None

    run = json.loads(rj.read_text("utf-8"))
    cls = run.get("class", {})
    doc = Document(
        doc_id=run["doc_id"],
        source_path=run["source"],
        source_sha256=run["source_sha256"],
        source_pages=run["pages"],
        document_class=cls.get("document_class", "reference-frozen"),
        title=cls.get("title"),
        version=cls.get("version"),
        version_date=cls.get("version_date"),
        extractor=run.get("extract", {}).get("extractor", ""),
        extractor_arm="docling",
        layout_model="docling-layout-heron",
    )

    chunks: list[Chunk] = []
    for line in cj.read_text("utf-8").splitlines():
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
    return doc, chunks, md.read_text("utf-8")


def reconcile(store: IndexStore, out_root: Path) -> Report:
    """Bring the index in line with every ingested document under out_root."""
    rep = Report()
    indexed = store.indexed()
    seen: set[str] = set()

    for d in sorted(p for p in out_root.iterdir() if p.is_dir()):
        loaded = _load_dir(d)
        if loaded is None:
            continue
        doc, chunks, markdown = loaded
        md_path = str((d / "document.md").resolve())
        seen.add(md_path)

        mtime = (d / "document.md").stat().st_mtime
        sha = sha256_text(markdown)
        known = indexed.get(md_path)

        if known and known[1] == sha:
            rep.unchanged.append(doc.doc_id)
            continue

        run = json.loads((d / "run.json").read_text("utf-8"))
        n = store.upsert(
            doc, chunks,
            markdown_path=md_path, markdown_mtime=mtime, markdown_sha256=sha,
            coverage=run.get("coverage"),
        )
        rep.chunks += n
        (rep.updated if known else rep.added).append(doc.doc_id)
        store.record_stage(doc.doc_id, "index", sha, doc.extractor)

    for path in indexed:
        if path not in seen:
            doc_id = next(
                (d["doc_id"] for d in store.documents() if d["markdown_path"] == path), None
            )
            if doc_id:
                store.remove(doc_id)
                rep.removed.append(doc_id)

    if rep.wrote:
        store.checkpoint()
    return rep
