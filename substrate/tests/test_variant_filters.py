"""A multi-query paraphrase is held to the same vault and entity filters as the question asked.

The variant LEXICAL search was the one arm that dropped `withheld_vaults=` and `entity=`. The direct
arm, the variant vector arm and the outline search all passed them, and routed passages inherit
them by being pinned to an outline's `doc_id`. So a passage from a guard-withheld vault, or from a
note that does not mention the requested entity, could enter the fused results through a
paraphrase while every other arm correctly refused it.

Latent when found: only `substrate eval` wires a `MultiQuery`, and the MCP server, the only caller
that sets `withheld_vaults`, passes none. The tests pin it before a caller combines the two.

Runnable with plain `python tests/test_variant_filters.py`; discovered by pytest.
"""

from __future__ import annotations

import sys
import tempfile
from pathlib import Path

sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

from substrate.models import Chunk, Document  # noqa: E402
from substrate.retrieve.retriever import retrieve  # noqa: E402
from substrate.store.index_store import IndexStore  # noqa: E402

QUERY = "replication lag"
# Shares no token with QUERY, so only the paraphrase can reach a passage that holds it.
PARAPHRASE = "quokka zebra"


class _MultiQuery:
    def variants(self, query: str) -> list[str]:
        return [PARAPHRASE]


def _put(store: IndexStore, doc_id: str, text: str, *, vault: str) -> str:
    doc = Document(doc_id=doc_id, source_path=f"/{doc_id}.md", source_sha256="s" * 8,
                   source_pages=1, document_class="reference-frozen", title=doc_id,
                   status="active", vault=vault)
    ch = Chunk(chunk_id=f"{doc_id}#c0", doc_id=doc_id, kind="passage", text=text,
               path=["Root", doc_id], level=2, n_chars=len(text),
               document_class="reference-frozen")
    store.upsert(doc, [ch], markdown_path=f"/{doc_id}.md", markdown_mtime=0.0,
                 markdown_sha256="m" * 8)
    return ch.chunk_id


def _ids(store: IndexStore, **filters) -> set[str]:
    res = retrieve(store, QUERY, k=10, multiquery=_MultiQuery(), **filters)
    assert res.trace.variants == 1, "the paraphrase never ran, so nothing here was tested"
    return {h.chunk_id for h in res.passages}


def _store() -> IndexStore:
    return IndexStore(str(Path(tempfile.mkdtemp()) / "index.db"))


def test_a_paraphrase_does_not_reach_a_withheld_vault() -> None:
    with _store() as s:
        allowed = _put(s, "open", f"{QUERY} in the open vault", vault="core")
        withheld = _put(s, "secret", f"{PARAPHRASE} in the guarded vault", vault="acme")
        got = _ids(s, withheld_vaults=frozenset({"acme"}))
        assert allowed in got, got
        assert withheld not in got, "a guarded vault's passage entered through the paraphrase"


def test_a_paraphrase_does_not_reach_a_note_outside_the_entity() -> None:
    with _store() as s:
        mentions = _put(s, "ada-note", f"{QUERY} with Ada", vault="core")
        other = _put(s, "bob-note", f"{PARAPHRASE} with Bob", vault="core")
        s.replace_identity([("ada", "Ada", "person", None), ("bob", "Bob", "person", None)])
        s.set_document_entities("ada-note", [("ada", "Ada")])
        s.set_document_entities("bob-note", [("bob", "Bob")])
        got = _ids(s, entity="ada")
        assert mentions in got, got
        assert other not in got, "a note not mentioning the entity entered through the paraphrase"


def test_a_paraphrase_still_reaches_what_the_filters_allow() -> None:
    """Without this the two tests above pass on a variant arm that returns nothing at all."""
    with _store() as s:
        _put(s, "open", f"{QUERY} in the open vault", vault="core")
        reachable = _put(s, "also-open", f"{PARAPHRASE} in another open vault", vault="research")
        s.replace_identity([("ada", "Ada", "person", None)])
        s.set_document_entities("also-open", [("ada", "Ada")])
        got = _ids(s, withheld_vaults=frozenset({"acme"}))
        assert reachable in got, got
        got = _ids(s, entity="ada", withheld_vaults=frozenset({"acme"}))
        assert reachable in got, got


if __name__ == "__main__":
    for name, fn in list(globals().items()):
        if name.startswith("test_"):
            fn()
            print("ok", name)
