"""Adding a note to a vault — plan first, write only on confirmation.

Doc 3a §2: ingest over MCP is a WRITE. "It requires explicit confirmation from the human in the
loop; it is not a fire-and-forget tool call. Additive-only (new sources); it never edits existing
notes." The server cannot force a human to look — a client may auto-approve tool calls — so the
gate is structural rather than social: `plan()` writes nothing and returns a token derived from
the exact content and destination, and `commit()` refuses any token that does not match a
freshly-recomputed one. A caller that never received a plan cannot produce a token, and a caller
whose source changed after planning gets a refusal rather than a surprise.

**The plan is executed, not guessed.** It runs the real ingestion into a throwaway directory, so
the spine validation, class policy and A18 coverage gate that would refuse this note at compose
refuse it here, before anything is written. What it does NOT run is the per-note A22 sweep, which
lives with the compose command; the plan says so rather than implying it checked everything.

**Never into core.** Doc 2 §2: projects read FROM core, nothing auto-writes INTO it — promoting
something to the tier every context inherits is a deliberate manual act. The destination is
always the scope's own project vault, and a path that escapes it is refused rather than clamped.

**The index is not updated.** Adding a note leaves it in the vault and absent from the index,
which is reported as a field (`index_stale`) and shows up in `status` drift as an unindexed note.
Recomposing as a side effect would run whole-scope gates that can refuse for reasons unrelated to
this note, and the caller could not tell which had happened.
"""

from __future__ import annotations

import hashlib
import shutil
import tempfile
from dataclasses import dataclass
from pathlib import Path

# Doc 2 §4's project skeleton. A note lands in one of these, and `04-synthesis` is the default
# because that is the folder the spec designates for model-entered synthesis notes.
WRITABLE_FOLDERS = ("02-areas", "03-references", "04-synthesis")
DEFAULT_FOLDER = "04-synthesis"


class NoteError(RuntimeError):
    """The note cannot be added: bad destination, a collision, or a gate that would refuse it."""


@dataclass(frozen=True)
class Plan:
    target: Path
    doc_id: str
    status: str
    doc_type: str
    confidence: str
    domains: list[str]
    passages: int
    confirm_token: str
    warnings: list[str]


def _digest(target: Path, content: bytes) -> str:
    """The confirmation token: this exact content, to this exact path. Binding BOTH is the point —
    a token that covered only the content would authorise writing it somewhere else."""
    h = hashlib.sha256()
    h.update(str(target).encode("utf-8"))
    h.update(b"\0")
    h.update(content)
    return h.hexdigest()


def _resolve_target(project_vault: Path, folder: str, filename: str) -> Path:
    if not filename.endswith(".md"):
        raise NoteError(f"{filename!r} is not markdown. Only .md notes are added this way; a PDF "
                        "goes through the supervised reference-ingest path.")
    if folder not in WRITABLE_FOLDERS:
        raise NoteError(
            f"{folder!r} is not a writable project folder. Choose one of "
            f"{list(WRITABLE_FOLDERS)} (Doc 2 §4). Notes are never written into the shared core "
            f"tier — promoting something there is a deliberate manual act."
        )
    if Path(filename).name != filename:
        raise NoteError(f"{filename!r} must be a bare filename, not a path.")

    project_vault = project_vault.expanduser().resolve()
    target = (project_vault / folder / filename).resolve()
    # Belt-and-braces after the component checks above: assert the RESOLVED path is inside the
    # project vault rather than trusting that the checks covered every way out.
    if project_vault not in target.parents:
        raise NoteError(f"{target} resolves outside the project vault {project_vault}.")
    if target.exists():
        raise NoteError(
            f"{target} already exists. This path is additive-only: editing an existing note goes "
            f"through diff review, not through here."
        )
    return target


def plan(
    *, project_vault: Path, content: bytes, filename: str, folder: str = DEFAULT_FOLDER,
) -> Plan:
    """Validate a note against the real ingestion gates without writing anything.

    Raises NoteError with the gate's own message when the note would be refused — the same
    refusal compose would give, delivered before the vault is touched rather than after.
    """
    from substrate import classes
    from substrate.markdown.ingest import CoverageError, ingest_markdown
    from substrate.spine import SpineError

    target = _resolve_target(project_vault, folder, filename)

    tmp = Path(tempfile.mkdtemp())
    try:
        staged = tmp / filename
        staged.write_bytes(content)
        try:
            # require_status=True is what the VAULT path uses: a note entering a vault must
            # declare its status and doc_type, so a note that would be refused at compose is
            # refused here instead of landing in the vault and refusing the whole scope later.
            result = ingest_markdown(staged, tmp / "out", require_status=True)
        except (ValueError, classes.ClassPolicyError, SpineError, CoverageError) as e:
            raise NoteError(f"{type(e).__name__}: {e}") from e

        return Plan(
            target=target,
            doc_id=result.doc_id,
            status=result.status,
            doc_type=result.doc_type,
            confidence=result.confidence,
            domains=list(result.domains),
            passages=int((result.run.get("chunk") or {}).get("passages", 0)),
            confirm_token=_digest(target, content),
            # Named, not implied: the per-note A22 sweep runs at compose, not here, so this plan
            # does not promise the note will pass it.
            warnings=["the per-note A22 assertion sweep runs at compose, not in this plan"],
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def commit(
    *, project_vault: Path, content: bytes, filename: str, folder: str = DEFAULT_FOLDER,
    confirm_token: str,
) -> Path:
    """Write the note, but only for a token matching a freshly-recomputed plan.

    Re-planning rather than trusting the token is the whole mechanism: it re-runs every gate
    against the content being written NOW, so a source edited between plan and commit is refused
    instead of written unvalidated.
    """
    fresh = plan(project_vault=project_vault, content=content, filename=filename, folder=folder)
    if confirm_token != fresh.confirm_token:
        raise NoteError(
            "confirm_token does not match this note and destination. Call again without a token "
            "to get a current plan, confirm it with the human, and pass THAT token — a stale "
            "token means the content or the target changed after the plan was reviewed."
        )
    fresh.target.parent.mkdir(parents=True, exist_ok=True)
    tmp = fresh.target.with_name(fresh.target.name + ".tmp")
    tmp.write_bytes(content)
    tmp.replace(fresh.target)
    return fresh.target
