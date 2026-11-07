"""The vector arm's matrix, held in memory between queries.

`IndexStore.vector_search` used to re-read every vector, and every chunk row with it, on every
query: 22–24 ms per call on atlas (7,206 × 1024), out of a ~140 ms embedder-only search, measured
2026-11-06 on an M2 Max. Holding the matrix brings the call to ~5 ms, most of it the filter query,
which stays in SQL for the reason below.

THE FILTERS ARE NOT RE-IMPLEMENTED HERE. The caller still runs the same WHERE clause the lexical
arm runs, selecting only chunk ids, and this module ranks the vectors of exactly those ids. A
filter written once as SQL and again as a numpy mask is two definitions that agree until someone
edits one of them. `vector_search`'s own docstring exists because a filter that held on one arm
and not the other was a real defect.

THIS MODULE HOLDS NO SQL. `IndexStore` reads the key facts and the vectors inside the one read
transaction its query runs in, and passes a loader; this keeps what was read and hands it back
only to a caller presenting the same facts:

  * The generation: `vector_generation(epoch, n)` plus the file's schema cookie. Triggers move `n`
    on every row written to or removed from `chunk_vectors`, so no write path can forget to;
    `epoch` is drawn when the table is created; and the cookie moves whenever a table or trigger
    is created or dropped, so a rebuild, even one by an engine that predates the triggers and
    leaves the old row behind, cannot repeat a generation held here. Nothing cheaper is sound:
    `index_version` does not cover vectors, `chunk_id` is positional (`{doc_id}#c{seq}`), and a
    deleted max-rowid row gives its rowid to the next insert.
  * The file, (st_dev, st_ino, birth time), as the store recorded it at open. A copy can carry its
    source's generation, and a copy put at the path is a new file.
  * The open mode. An immutable open takes no locks and ignores the WAL; what it reads is not
    handed to a normal one.

Assumed, not checked: nobody overwrites the index IN PLACE with another copy of itself (`cp` onto
the existing file, a backup restored into it). That keeps the file's identity and the epoch while
rewinding `n`, which later writes can bring back to a value held here.

No connection is held between queries. An earlier draft kept one open per entry to watch
`PRAGMA data_version`; that left the WAL's `-shm` alive under the file's name, so a database later
renamed over the path read the old file's uncheckpointed frames (reproduced, 2026-11-06).
"""

from __future__ import annotations

import threading
from collections import OrderedDict
from collections.abc import Callable, Sequence
from dataclasses import dataclass

import numpy as np

# One entry per key. Atlas's matrix is 29.5 MB, and the registry holds seven scopes. The bound
# matters because the model is in the key: without it, every superseded embedder's matrix would
# stay resident in a long-lived server.
MAX_ENTRIES = 8

FileId = tuple[int, int, float | int]
Generation = tuple[str, int, int]    # (epoch, n, schema cookie)
Key = tuple[str, str, int, bool]          # (realpath, model, dim, immutable)
_LOCK = threading.Lock()
_ENTRIES: OrderedDict[Key, Matrix] = OrderedDict()


def stack(blobs: Sequence[bytes], dim: int) -> np.ndarray:
    """Packed float32 vectors as an (n, dim) matrix. Both vector paths build theirs here."""
    return np.frombuffer(b"".join(blobs), dtype=np.float32).reshape(len(blobs), dim)


def cosines(mat: np.ndarray, q: np.ndarray) -> np.ndarray:
    """Each row's dot product with `q`: cosine, since every vector is L2-normalised.

    `einsum`, not `mat @ q`. The BLAS product's result for a row depends on the matrix's shape and
    on the row's position in it (measured on atlas: 245 of 300 filtered subsets differed from the
    same rows taken out of the whole product, and identical rows scored differently from each
    other). So the scan used to score a passage differently depending on which filter set it was
    in, and exact ties were not exact. `einsum`'s own loop scores a row from that row alone, so the
    two vector paths agree to the bit and identical text ties. It costs ~1.4 ms against 0.45 on
    atlas's full matrix.
    """
    return np.einsum("ij,j->i", mat, q, optimize=False)


def top_k(sims: np.ndarray, k: int, tiebreak: Callable[[int], str]) -> list[int]:
    """Positions of the `k` highest scores, highest first, equal scores in `tiebreak` order.

    The ONE ranking rule for both vector paths. It replaced `np.argsort(-sims)[:k]`, which put
    exact ties in an order nobody chose (introsort is not stable). Exact ties are real here:
    identical text embeds to identical vectors, and `cosines` scores those identically. The rule
    matters at the k boundary too, where it decides which tied passage gets in. A NaN ranks last,
    where `argsort` put it.
    """
    n = len(sims)
    if k <= 0 or n == 0:
        return []
    key = np.where(np.isnan(sims), -np.inf, sims)
    if n > k:
        floor = key[np.argpartition(-key, k - 1)[:k]].min()
        cand = np.flatnonzero(key >= floor).tolist()
    else:
        cand = range(n)
    return sorted(cand, key=lambda j: (-float(key[j]), tiebreak(j)))[:k]


@dataclass(eq=False)
class Matrix:
    fid: FileId
    generation: Generation
    ids: list[str]            # row i's chunk_id, in chunk_id order
    rows: dict[str, int]      # chunk_id -> row
    mat: np.ndarray           # (n, dim) float32, read-only

    def rank(self, chunk_ids: Sequence[str], query_vec: Sequence[float],
             k: int) -> list[tuple[str, float]]:
        """The top `k` of `chunk_ids` by cosine, as (chunk_id, score). An id with no row here has
        no vector under this model and dim, which is the scan's join's answer for it too."""
        rows = self.rows
        idx = np.fromiter((rows[c] for c in chunk_ids if c in rows), dtype=np.intp)
        if idx.size == 0:
            return []
        sims = cosines(self.mat, np.asarray(query_vec, dtype=np.float32))[idx]
        ids = self.ids
        return [(ids[idx[j]], float(sims[j])) for j in top_k(sims, k, lambda j: ids[idx[j]])]


def lookup(key: Key, fid: FileId, generation: Generation,
           load: Callable[[], tuple[list[str], np.ndarray]]) -> Matrix:
    """The matrix held under `key` if it was read from this file at this generation, else
    `load()`'s, which then replaces it. `load` must read the same snapshot `generation` came from.
    """
    with _LOCK:
        e = _ENTRIES.get(key)
        if e is not None and e.fid == fid and e.generation == generation:
            _ENTRIES.move_to_end(key)
            return e
    # Loaded outside the lock: a 30 MB read must not stall every other scope's search. Each
    # concurrent loader describes the snapshot it read; the last to finish is kept, and a later
    # caller at another generation simply loads again.
    ids, mat = load()
    e = Matrix(fid=fid, generation=generation, ids=ids,
               rows={c: i for i, c in enumerate(ids)}, mat=mat)
    with _LOCK:
        _ENTRIES[key] = e
        _ENTRIES.move_to_end(key)
        while len(_ENTRIES) > MAX_ENTRIES:
            _ENTRIES.popitem(last=False)
    return e


def clear() -> None:
    with _LOCK:
        _ENTRIES.clear()
