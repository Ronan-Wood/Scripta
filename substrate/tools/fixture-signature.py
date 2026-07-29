#!/usr/bin/env python3
"""Content signature of an index's chunk text and attribution — recomputable, unlike its predecessor.

    uv run python tools/fixture-signature.py out/substrate.db

The eval fixture has been guarded for months by `4a4f765c9ad75dc9`, quoted in three readouts and
in SESSION-HANDOFF's "EVAL MUST NOT MOVE". That number's derivation was never written down:
MIGRATION-VOCABULARY.md records a session trying seventeen plausible constructions over
`(chunk_id, text_with_path)` and reproducing none of them. So the project's most-cited invariant
could not be checked by anyone, which makes it the same defect as a docstring asserting a property
nobody implemented — a claim the next reader trusts instead of testing.

THE DERIVATION IS THE POINT OF THIS FILE. It is stated here, in code, and it is cheap to re-run:

    sha256 over, for every chunk ordered by chunk_id COLLATE BINARY:
        chunk_id \\x00 path_str \\x00 text \\n
    take the first 16 hex characters

Chosen so the signature is invariant under everything that SHOULD be able to change:

  * schema version — reads three columns that predate every bump this engine has made, so a file
    stamped v2 and a v8 rebuild of the same markdown produce the same value. That is the property
    that makes it a fixture signature rather than a file hash; `out/substrate.db`'s sha256 changed
    on the v8 rebuild while every hashed input stayed identical. `IndexStore.index_version` cannot
    serve here for exactly that reason: it returns `f"v{sv}:{sig}"` over each document's
    `stage_ledger` content_hash, so it embeds the schema version and moves on the lossless rebuild
    this signature exists to survive. The two are opposites, not duplicates.
  * rowid / insertion order — ORDER BY chunk_id, not physical order.
  * vectors, FTS state, page layout, VACUUM — none are hashed; embeddings are a pure function of
    the text and are keyed on its sha elsewhere.

And variant under everything that should NOT change silently: a chunk appearing, disappearing,
being re-chunked, having its text edited, or having its structural path change — the last being
the attribution half of every gold case, and the Phase-0 failure this corpus exists to catch.

**It does NOT cover every retrieval input**, and the title says chunk text and attribution rather
than "retrieval inputs" for that reason. `retrieve()` also filters on `document_class` and
`status` (`index_store.py`), so a change to `classes.py` that excluded a class, or a corpus whose
`status` flipped to `archived`, would collapse eval MRR with this signature unmoved. Both columns
are constant across this fixture today, so the gap is latent rather than live — but `status` and
`doc_type` CANNOT be added without losing the cross-version invariance above, which is the trade
being made deliberately.

ORDER and FRAMING are both pinned rather than inherited. `ORDER BY chunk_id` alone would take the
column's DECLARED collation — a `chunk_id TEXT COLLATE NOCASE` orders a byte-identical corpus
differently — so BINARY is stated, and the remaining columns tie-break so that duplicate chunk_ids
cannot make the value depend on the query plan. The framing is injective only because no field may
carry a delimiter, which is ENFORCED below rather than assumed: with a NUL inside `text`, or a
newline inside `chunk_id`, two different chunk sets serialise to identical bytes and a re-chunk
would leave the signature unmoved. Measured on the fixture: 0 of 1811 chunk_ids and path_strs
contain a newline, 0 texts contain a NUL, 0 of either column is NULL.

Read-only via `immutable=1`, and never through engine code AT ANY SETTING: `migrate=True` is
drop-and-rebuild on a version mismatch, which would destroy the artifact being measured, and
`migrate=False` REFUSES a mismatch outright — so the engine cannot read
`out/substrate.db.v2-frozen-…` at all. A signature that only works at the current schema is a file
hash with extra steps. `mode=ro` is not the answer either: under Python it opens fine, but it
CREATES the `-shm`/`-wal` pair a WAL database wants, dropping process state beside the artifact
being measured — the exact files commit a3c63f0 untracked. (The `sqlite3` CLI instead fails to
open outright when they are absent, which is what `run.sh` observes.) `immutable=1` does neither.
"""

from __future__ import annotations

import hashlib
import sqlite3
import sys
from pathlib import Path

_FIELD_SEP = b"\x00"
_RECORD_SEP = b"\n"

_WAL_MAGIC = (0x377F0682, 0x377F0683)
_JOURNAL_MAGIC = b"\xd9\xd5\x05\xf9\x20\xa1\x63\xd7"
_JOURNAL_INVALIDATED = b"\x00" * 8


class SignatureRefused(RuntimeError):
    """The database cannot be signed as named. Refuse rather than describe the wrong thing."""


class MissingFile(SignatureRefused):
    """The named path does not exist — and `immutable=1` would CREATE it."""


class HotSidecar(SignatureRefused):
    """A `-wal`/`-journal` may hold rows the `immutable=1` read cannot see."""


class EmptyCorpus(SignatureRefused):
    """No chunks. `sha256(b"")` is a well-formed signature for nothing at all."""


class ForeignShape(SignatureRefused):
    """A column is NULL or not text — this is not a substrate index."""


class UnframeableField(SignatureRefused):
    """A field carries a delimiter byte, so the hashed stream is not injective."""


def _wal_reason(side: Path, size: int) -> str | None:
    """Why this `-wal` cannot be ignored, or None when it provably holds no applicable frames.

    PROVE SAFE, ELSE REFUSE. Anything unparseable returns a reason, so a bug in this reader fails
    toward refusal — a false refusal costs a checkpoint, a false accept costs the invariant.

    `st_size > 0` was the previous predicate and it was wrong in the annoying direction: a WAL is
    routinely non-empty after a checkpoint, so the guard blocked databases it could read perfectly.
    A frame counts here when its salts match the header's, which makes a WAL from a previous
    generation — the state a reset leaves, header salt bumped and older frames stranded — read as
    the inert log it is.

    THE SALT TEST IS DELIBERATELY BROADER THAN SQLITE'S REPLAY RULE, not identical to it. SQLite
    additionally requires a valid checksum chain and a commit record, so frames this refuses are a
    SUPERSET of the frames it would actually apply: a salt-matching frame with a zero commit field
    is inert, and this still refuses it. That asymmetry is the safe direction and is the point —
    reproducing SQLite's full rule would mean reimplementing its checksum algorithm here, and a
    subtle bug in that reimplementation would fail by declaring a hot log empty.
    """
    if size == 0:
        return None
    with side.open("rb") as fh:
        hdr = fh.read(32)
        if len(hdr) < 32:
            return "its header is truncated"
        if int.from_bytes(hdr[0:4], "big") not in _WAL_MAGIC:
            return "its header magic is unrecognised"
        page_size = int.from_bytes(hdr[8:12], "big")
        if not (512 <= page_size <= 65536) or page_size & (page_size - 1):
            return f"its header declares an implausible page size ({page_size})"
        salt = hdr[16:24]
        live = 0
        while True:
            frame = fh.read(24)
            if len(frame) < 24 or frame[8:16] != salt:
                break
            if len(fh.read(page_size)) < page_size:
                break
            live += 1
    return f"it holds {live} frame(s) SQLite would replay" if live else None


def _journal_reason(side: Path, size: int) -> str | None:
    """Why this `-journal` cannot be ignored, or None when it is provably not hot.

    A PERSIST/TRUNCATE journal survives a clean commit with its header ZEROED, which is SQLite's
    own marker for "nothing to roll back". Refusing on size alone permanently blocked such a
    database while the `immutable=1` read was correct all along, and the remedy printed for it —
    a WAL checkpoint — is a no-op on a rollback journal.
    """
    if size == 0:
        return None
    with side.open("rb") as fh:
        hdr = fh.read(8)
    if len(hdr) < 8:
        return "its header is truncated"
    if hdr == _JOURNAL_INVALIDATED:
        return None
    if hdr == _JOURNAL_MAGIC:
        return "it is a HOT rollback journal that SQLite would replay"
    return "its header is neither a valid journal nor an invalidated one"


_SIDECARS = (("-wal", _wal_reason, "PRAGMA wal_checkpoint(TRUNCATE);"),
             ("-journal", _journal_reason, "SELECT 1;  -- opening read-write rolls it back"))


def _check_sidecars(p: Path) -> None:
    """Refuse when a sidecar may hold rows the `immutable=1` read will not see."""
    for suffix, reason_of, repair in _SIDECARS:
        side = p.with_name(p.name + suffix)
        try:
            size = side.stat().st_size
        except FileNotFoundError:
            continue
        reason = reason_of(side, size)
        if reason is None:
            continue
        raise HotSidecar(
            f"{side.name} ({size} bytes): {reason}. immutable=1 does not read it, so the "
            "signature would cover only what is already in the main database.\n"
            "  If a writer is open, close it — SQLite repairs the sidecar on the last close.\n"
            "  If nothing holds it open, the sidecar is orphaned (a killed process, or a checkout "
            "of a commit from before they were untracked). Repair a COPY, never this file:\n"
            f"    cp {p.name}{suffix} /tmp/  &&  cp {p.name} /tmp/  &&  \\\n"
            f"      sqlite3 /tmp/{p.name} '{repair}'  &&  {Path(sys.argv[0]).name} /tmp/{p.name}\n"
            "  The signature is content, so the copy signs identically — and the artifact this "
            "guards is never written to. Repairing it in place is a WRITE open on the file whose "
            "whole point is that it has not moved."
        )


def signature(db_path: str | Path) -> tuple[str, int]:
    """Return (signature, n_chunks) for an index, without opening it for write.

    Refuses rather than returning a well-formed value it cannot stand behind: a path that does not
    exist (SQLite would CREATE it), a sidecar that may hold unread rows, an empty chunks table, a
    NULL or non-text column value, and any field carrying a delimiter byte.
    """
    p = Path(db_path).resolve()
    if not p.is_file():
        # immutable=1 does NOT imply "will not create": verified, a typo'd path materialises a
        # zero-byte database and then reports "no such table: chunks", which reads as "your
        # fixture is the wrong shape" rather than "I read a file you did not mean". IndexStore
        # carries an explicit guard against the same incident.
        raise MissingFile(f"{p} does not exist. Refusing to create it on a read.")

    _check_sidecars(p)

    con = sqlite3.connect(p.as_uri() + "?immutable=1", uri=True)  # as_uri percent-encodes # ? %
    try:
        rows = con.execute(
            "SELECT chunk_id, path_str, text FROM chunks "
            "ORDER BY chunk_id COLLATE BINARY, path_str COLLATE BINARY, text COLLATE BINARY"
        ).fetchall()
    finally:
        con.close()

    # Re-checked AFTER the read, not only before: the first check and the fetch are separate
    # syscalls, and a writer committing between them yields a perfectly well-formed undercount —
    # the exact outcome the guard exists to prevent, arrived at through the guard's own blind spot.
    _check_sidecars(p)

    if not rows:
        raise EmptyCorpus(
            f"{p} has no chunks. Refusing to sign an empty corpus — sha256 of the empty stream is "
            "a well-formed signature that means nothing."
        )

    h = hashlib.sha256()
    for chunk_id, path_str, text in rows:
        for name, value, forbidden in (
            ("chunk_id", chunk_id, (_FIELD_SEP, _RECORD_SEP)),
            ("path_str", path_str, (_FIELD_SEP, _RECORD_SEP)),
            ("text", text, (_FIELD_SEP,)),
        ):
            # NULL is refused rather than COALESCEd: folding it to '' would make a corpus that
            # nulled a field sign identically to one that emptied it, which is a silent
            # non-injectivity in the opposite direction from the delimiter one.
            if not isinstance(value, str):
                raise ForeignShape(
                    f"chunk {chunk_id!r}: {name} is {type(value).__name__}, not text. This is not "
                    "a substrate index, or its chunks table has a foreign shape."
                )
            for bad in forbidden:
                if bad.decode("latin-1") in value:
                    raise UnframeableField(
                        f"chunk {chunk_id!r}: {name} contains {bad!r}, which frames the hashed "
                        "stream. Two different chunk sets could serialise identically, so this "
                        "corpus cannot be signed by this construction."
                    )
        h.update(chunk_id.encode("utf-8"))
        h.update(_FIELD_SEP)
        h.update(path_str.encode("utf-8"))
        h.update(_FIELD_SEP)
        h.update(text.encode("utf-8"))
        h.update(_RECORD_SEP)
    return h.hexdigest()[:16], len(rows)


if __name__ == "__main__":
    if len(sys.argv) < 2:
        print("usage: fixture-signature.py <index.db> [<index.db> ...]", file=sys.stderr)
        raise SystemExit(2)
    failed = 0
    for arg in sys.argv[1:]:
        # Every failure prints in one form and the loop continues: the documented use is comparing
        # two files, and aborting on the first would leave the comparison half-done with a lone
        # signature already on stdout reading like a clean pass. The RESOLVED path is printed, so
        # two arguments naming the same file cannot read as independent corroboration.
        try:
            sig, n = signature(arg)
        except (sqlite3.Error, SignatureRefused, OSError) as e:
            failed += 1
            print(f"{arg}: cannot sign — {e}", file=sys.stderr)
            continue
        print(f"{sig}  {n:>6} chunks  {Path(arg).resolve()}")
    if failed:
        print(f"{failed} of {len(sys.argv) - 1} could not be signed", file=sys.stderr)
        raise SystemExit(1)
