"""Adding a note to a vault — plan first, write only on confirmation.

Doc 3a §2: ingest over MCP is a WRITE. "It requires explicit confirmation from the human in the
loop; it is not a fire-and-forget tool call. Additive-only (new sources); it never edits existing
notes."

The gate is two-phase and the token is UNFORGEABLE: `plan()` writes nothing, mints a random
single-use nonce, and records it in a `PlanBook` held by the running process. `commit()` redeems
it — a token this process never issued is refused, and a redeemed one cannot be replayed.

An earlier version derived the token as `sha256(target + content)`. That was worthless as a gate:
both inputs come from the caller, so anyone could compute a valid token without ever calling
`plan()`, and a first-call write with a self-computed digest succeeded. The docstring claimed a
guarantee the code did not provide, which is the failure PRINCIPLES.md names directly — a stamp
implying a condition was handled is worse than no stamp, because the next reader trusts it.

Be precise about what this DOES buy, because overstating it once already happened here. It makes
a write impossible without a plan having been issued and returned for someone to read, and it
binds that plan to exact bytes at an exact path. It cannot force a human to actually read it —
that is the client's approval UI, and no server-side mechanism can reach it.

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
import os
import secrets
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


def _binding(target: Path, content: bytes) -> str:
    """What a plan is FOR: this exact content, at this exact path. Binding both is the point — a
    binding over content alone would let a redeemed plan write it somewhere else."""
    h = hashlib.sha256()
    h.update(str(target).encode("utf-8"))
    h.update(b"\0")
    h.update(content)
    return h.hexdigest()


class PlanBook:
    """The plans this process has issued and not yet had redeemed.

    Process-local by design. A token is a random nonce, so it cannot be derived from anything the
    caller knows; it is checked against the binding it was issued for, so it cannot be carried to
    a different note or destination; and it is popped on redemption, so a plan authorises exactly
    one write. Held by the running server rather than persisted: a token surviving a restart would
    authorise a write against a plan nobody in this session ever saw.
    """

    def __init__(self) -> None:
        self._issued: dict[str, str] = {}

    def issue(self, binding: str) -> str:
        token = secrets.token_urlsafe(32)
        self._issued[token] = binding
        return token

    def redeem(self, token: str, binding: str) -> bool:
        """True only for a token this process issued FOR THIS binding. Single-use either way — a
        token presented against the wrong binding is burned, not left available to retry."""
        issued = self._issued.pop(token, None)
        return issued is not None and secrets.compare_digest(issued, binding)


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
    book: PlanBook,
) -> Plan:
    """Validate a note against the real ingestion gates without writing anything, and issue a
    single-use token for it.

    Raises NoteError with the gate's own message when the note would be refused — the same
    refusal compose would give, delivered before the vault is touched rather than after. A refused
    plan issues no token, so nothing that failed a gate is ever redeemable.
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
            confirm_token=book.issue(_binding(target, content)),
            # Named, not implied: the per-note A22 sweep runs at compose, not here, so this plan
            # does not promise the note will pass it.
            warnings=["the per-note A22 assertion sweep runs at compose, not in this plan"],
        )
    finally:
        shutil.rmtree(tmp, ignore_errors=True)


def commit(
    *, project_vault: Path, content: bytes, filename: str, folder: str = DEFAULT_FOLDER,
    confirm_token: str, book: PlanBook,
) -> Path:
    """Write the note, but only for a token this process issued for exactly these bytes and path.

    Two independent checks, guarding two different failures. Re-planning re-runs every gate
    against the content being written NOW, so a source edited between plan and commit is refused
    rather than written unvalidated. Redeeming the token proves a plan was issued and returned for
    someone to read — which re-planning alone cannot establish, since the caller supplies both of
    its inputs.
    """
    fresh = plan(project_vault=project_vault, content=content, filename=filename, folder=folder,
                 book=book)
    if not book.redeem(confirm_token, _binding(fresh.target, content)):
        raise NoteError(
            "confirm_token was not issued by this server for this note and destination, or has "
            "already been used. Call again without a token to get a current plan, confirm it with "
            "the human, and pass THAT token."
        )

    fresh.target.parent.mkdir(parents=True, exist_ok=True)
    # The additive-only and stay-inside-the-vault guarantees are enforced by the SYSCALL, not by
    # the earlier `target.exists()` check — that check is a check-then-act pair with a window, and
    # a staging file at a fixed sibling name (`<note>.md.tmp`) was itself an unguarded write: a
    # symlink planted there redirected the content outside the vault entirely, which is exactly
    # what the containment checks above exist to refuse. O_EXCL makes "never overwrite" atomic;
    # O_NOFOLLOW refuses a symlinked target outright.
    try:
        fd = os.open(fresh.target, os.O_WRONLY | os.O_CREAT | os.O_EXCL | os.O_NOFOLLOW, 0o644)
    except FileExistsError as e:
        raise NoteError(
            f"{fresh.target} appeared between the plan and the write. This path is additive-only; "
            f"refusing to overwrite it."
        ) from e
    except OSError as e:
        raise NoteError(f"cannot create {fresh.target}: {e}") from e
    try:
        with os.fdopen(fd, "wb") as fh:
            fh.write(content)
    except OSError as e:
        # A partial note in the vault would compose as a truncated one. Remove it and refuse.
        fresh.target.unlink(missing_ok=True)
        raise NoteError(f"failed writing {fresh.target}: {e}") from e
    return fresh.target
