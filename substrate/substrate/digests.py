"""Is a digest behind the area it summarises — drift for NOTES rather than for the index.

`freshness.drift` asks whether the INDEX still agrees with the vault. `refresh_state` asks whether
the rebuild agent is still succeeding. Both are questions about machinery. This is the same shape of
question asked about CONTENT: Doc 2 §6a defines `digest` as a MAINTAINED per-area summary, so an
area that has gained or changed notes since its digest was written has a digest describing a vault
that no longer exists. Nothing detected that, so reconciling the two fell on whoever read the area
next — and a reconciliation nobody is told to do is one that quietly stops happening.

**Detection only, like every other divergence signal here.** No fold-back, no rewrite, no `--fix`.
A machine deciding that a new observation supersedes an old claim asserts settledness it has not
earned, which is the failure this engine exists to refuse; `notes.ingest` is two-phase with a
confirm token for exactly that reason. This surfaces the divergence, names what it could not check,
and stops.

**Membership is FOLDER POSITION.** A digest's area is its own directory; its members are the atomic
notes in that directory. The obvious alternative — reading the digest's `[[links]]` — is refused.
Links are human relations for navigation, WRITING.md records that a digest's links are titles rather
than resolvable refs, and a check that consumed them would promote an unwritten convention into a
load-bearing contract: the first digest that linked a note by title, or pointed at something outside
its area, would read as permanently stale for a reason its author never agreed to.

**Which directories are areas is answered by DEPTH, not by a list of names.** A digest whose own
directory is a top-level directory of its vault (`02-areas/`) or the vault root has no area to be
measured against: `02-areas` is the vault's ORGANISATION — the drawer everything is filed in — and
its siblings are whatever else happens to be filed there. Research's `02-areas/scoop-watch.md` sits
beside five unrelated synthesis notes; claiming those five as its membership set would report it
stale forever, which is a signal nobody trusts twice. So that digest reports UNMEASURABLE with
`stale: null`, the same posture `refresh.frozen` takes when nothing was checked — absent evidence,
never a guess. Prism already has the shape that resolves: every digest sits INSIDE the area it
summarises (`02-areas/frontend/frontend-digest.md`), so the directory IS the membership set.

Depth rather than a vocabulary of directory names (`02-areas`, `03-references`, …) because the
engine has an opinion on SHAPE and none on naming (Doc 2 §0, and `vault._resolve_inherit` for the
same argument about location). A hard-coded list would silently mismeasure the first vault that
numbered its drawers differently, and mismeasuring is the one outcome worse than declining.

**Staleness is measured in mtimes, and mtime is a filesystem property, not an authored one.** It is
the only "when was this last written" signal every note carries: `last-updated` is on 203 of 685
notes in the operator's vaults (measured 2026-08-03) and on none of prism's five digests, and mixing
a hand-written date on one side with a filesystem stamp on the other would compare two figures from
different conditions — WRITING.md rule 7, on the axis where it is least visible. So both sides are
read with one clock, and what that clock cannot resolve is named rather than hidden.

**mtime does not order two notes a bulk write produced, and pretending it does was a live defect.**
The first version of this module asked `member.mtime > digest.mtime` and reported ALL FIVE prism
digests behind areas nobody had touched. Measured 2026-08-03: the 2026-07-28 migration wrote each of
prism's areas inside 25 MILLISECONDS — infrastructure's 28 notes span 12.8ms, domain's 55 span
22.4ms — in arbitrary order, so whether a digest landed before or after its members is noise from
directory iteration. That is the worse of the two failure modes freshness.py names: a check that
cries wolf on a clean vault trains its reader to ignore it, and a signal nobody trusts twice is
worth less than no signal.

`SAME_WRITE_SECONDS` is the fix, and it is a statement about what the clock resolves: a member
counts as newer only if it is newer by more than one write event. What that costs and what it buys,
in order of how much they matter:

  * a member edited within a minute of its digest is NOT reported. False negative, the safe
    direction — freshness.py orders these two failures the same way.
  * ANY edit to a digest clears its verdict, including one that did not fold anything in. Retyping
    a note's frontmatter is enough. So the first run after touching a digest reports `current` on
    the strength of that touch, and the honest reading of `current` is "nothing in this area has
    been written since the digest file was last saved" — not "the digest covers this area".
  * a note MOVED into an area keeps its old mtime, so a member that predates the digest but joined
    the area yesterday reads as unchanged. Catching it needs a record of the digest's prior
    membership, which is state this check refuses to write into a vault.
  * a fresh cloud re-download rewrites mtimes over minutes or hours in arbitrary order, and no
    threshold short of a day survives that. It cannot be engineered away without the vault state
    above, so it is stated instead: read `behind` as "the filesystem says these were written after
    the digest was", never as "the author changed them".

The threshold is emitted on the payload rather than left implicit, because a verdict computed
against an unstated tolerance is a number without its conditions (WRITING.md rule 7 again).

**Why this is not a field on `substrate status`.** Status reports whether an INDEX can be trusted,
and every one of its fields is answered from a store that opened: `status_payload` takes one, and
`cmd_status` returns 2 on a schema mismatch before it ever builds a payload. This check needs no
index at all — a manifest and a directory walk are its whole input — so hanging it off status would
make a vault question require a composed scope, a registered name, and a matching schema, none of
which it depends on. The responses differ too, and that is the sharper reason: `freshness: STALE`
means run `substrate compose`, a mechanical fix the refresh agent already performs unattended, while
a digest behind its area means a human sits down and rewrites a note. One line that sometimes means
"run a command" and sometimes means "do some thinking" is two conditions in one voice, which is the
conflation `refresh` and `drift` were deliberately kept apart to avoid.
"""

from __future__ import annotations

from pathlib import Path

from substrate.markdown.reader import _parse_frontmatter
from substrate.spine import DIGEST_DOC_TYPE
from substrate.vault import Scope, VaultError, _read_capped

# How many path parts a note's vault-relative directory needs before that directory NAMES AN AREA.
# `02-areas/frontend` is 2 and is an area; `02-areas` is 1 and is the vault's filing structure; the
# vault root is 0. See the module docstring for why this is depth and not a list of directory names.
MIN_AREA_DEPTH = 2

# How much later than its digest a member must be before that ordering means anything. Chosen with
# a margin at both ends rather than tuned: three orders of magnitude above the 25ms a bulk write of
# one area actually took (measured on prism, 2026-08-03), and orders of magnitude below the interval
# at which a person returns to a vault — the smallest genuine gap in the same corpus is the 6.4
# hours between prism's cross-cutting digest and the four notes written after it. Anything from a
# second to an hour would work here; a minute is the value that reads as "one sitting" to a human
# being told what the check does.
SAME_WRITE_SECONDS = 60.0

MTIME_NOTE = (
    f"measured from file mtimes: a member note written more than {SAME_WRITE_SECONDS:.0f}s after "
    f"its digest. Below that they are one write event and the order is noise. A note MOVED into an "
    f"area keeps its old mtime and is not seen; a bulk restore rewrites every mtime and makes "
    f"everything look newer."
)


def _roots(scope: Scope) -> tuple[tuple[Path, str], ...]:
    """The scope's vault roots, longest path first.

    Longest-first so a vault nested inside another places its notes in ITSELF. Matching on
    `NoteRef.vault` (the directory NAME) would have been shorter and is what the store keys on, but
    two composed vaults may legitimately be different directories with the same basename, and that
    collision would silently merge two vaults' areas into one membership set.
    """
    return tuple(sorted(((v.path.resolve(), v.name) for v in scope.vaults),
                        key=lambda rv: len(rv[0].parts), reverse=True))


def _area_of(path: Path, roots: tuple[tuple[Path, str], ...]) -> tuple[Path, str, Path]:
    """(resolved note path, vault name, vault-relative directory) for one note.

    Resolved here and reused everywhere below, exactly as `freshness.drift` resolves both sides
    through one call: on macOS a temp dir alone differs (`/var/...` vs `/private/var/...`), so a
    path compared against a resolved vault root without this lies under no root at all.
    """
    resolved = path.resolve()
    for root, name in roots:
        if resolved.is_relative_to(root):
            return resolved, name, resolved.parent.relative_to(root)
    raise VaultError(
        f"{path} lies under none of the scope's vault roots {[str(r) for r, _ in roots]}. Refusing "
        "to place it in an area — a note assigned to the wrong area is a membership set that "
        "reports staleness about notes it has nothing to do with."
    )


def _declared_doc_type(note) -> str | None:
    """The doc_type `compose` would store for this note: its own declaration, else the `_meta.md`
    override its source supplies. Mirrors `markdown.ingest` (`if override and doc.doc_type is None`)
    rather than re-deriving the rule — a second precedence order here would disagree with the index
    about which notes are digests, on the one axis this whole check is keyed to."""
    front, _ = _parse_frontmatter(_read_capped(note.path))
    return front.get("doc_type") or note.override_doc_type or None


def audit(scope: Scope) -> dict:
    """Every digest in the composed scope, and whether its area has moved under it.

    Returns per-digest records plus scope-level counts, shaped like `freshness.drift`:
    `stale` means something DEFINITELY differs, and `checkable` is the separate statement that the
    sweep was complete. A caller must read both — `stale: false, checkable: false` is "no digest was
    found behind its area, and some notes were never examined".

    A digest whose directory does not name an area (see MIN_AREA_DEPTH) reports `measurable: false`
    with `stale: null` AND `members: null`. The member count is withheld deliberately: printing
    "16 members" for a digest whose membership this function refuses to claim would state the wrong
    answer numerically while the verdict beside it declined to state it at all.
    """
    roots = _roots(scope)
    unreadable: list[str] = []
    # (vault name, vault-relative area dir) -> {"digests": [(path, mtime)], "members": [(path, mtime)]}
    areas: dict[tuple[str, Path], dict[str, list[tuple[Path, float]]]] = {}

    for n in scope.notes:
        note_path, vault_name, area_dir = _area_of(n.path, roots)
        try:
            # Both reads under one guard: a note that cannot be read has an unknown doc_type, so it
            # is neither confirmed a member nor ruled out as a digest. Counting it as an ordinary
            # member would let an unreadable file silently decide a staleness verdict.
            mtime = note_path.stat().st_mtime
            doc_type = _declared_doc_type(n)
        except (OSError, VaultError):
            unreadable.append(str(note_path))
            continue
        bucket = areas.setdefault((vault_name, area_dir), {"digests": [], "members": []})
        bucket["digests" if doc_type == DIGEST_DOC_TYPE else "members"].append((note_path, mtime))

    records: list[dict] = []
    for (vault_name, area_dir), bucket in areas.items():
        measurable = len(area_dir.parts) >= MIN_AREA_DEPTH
        for path, digest_mtime in sorted(bucket["digests"]):
            if not measurable:
                records.append(_record(path, vault_name, area_dir, measurable=False,
                                       reason=_not_an_area(vault_name, area_dir)))
                continue
            # Other digests in the same directory are NOT members. A digest points at ATOMIC notes,
            # so a sibling digest being newer says nothing about whether this one is behind — and
            # excluding every digest is what makes "two digests in one area" need no special case.
            newer = sorted(str(p) for p, m in bucket["members"]
                           if m > digest_mtime + SAME_WRITE_SECONDS)
            records.append(_record(path, vault_name, area_dir, measurable=True,
                                   members=len(bucket["members"]), newer=newer))

    records.sort(key=lambda r: (r["vault"], r["area"], r["path"]))
    return {
        "stale": any(r["stale"] for r in records),
        # Separate from `stale` for the reason drift keeps them separate: an unreadable note is not
        # a detected change, it is the absence of a check, and folding the two makes an incomplete
        # sweep indistinguishable from a clean one.
        "checkable": not unreadable,
        "digests": records,
        "measured": sum(1 for r in records if r["measurable"]),
        "unmeasurable": sum(1 for r in records if not r["measurable"]),
        "behind": sum(1 for r in records if r["stale"]),
        "unreadable": unreadable,
        # The tolerance every `stale` above was computed against, carried WITH the verdicts rather
        # than left to the docstring — a reader comparing two runs has to be able to see that the
        # condition did not move under them.
        "same_write_seconds": SAME_WRITE_SECONDS,
        "note": MTIME_NOTE,
    }


def _not_an_area(vault_name: str, area_dir: Path) -> str:
    where = (f"sits at the root of {vault_name}" if not area_dir.parts
             else f"sits directly in {area_dir}/, a top-level directory of {vault_name}")
    return (
        f"UNMEASURABLE — this digest {where}, which is the vault's filing structure rather than an "
        f"area, so the notes beside it are not its membership set. Move the digest and the notes it "
        f"summarises into their own directory (prism's shape: 02-areas/<area>/<area>-digest.md) and "
        f"folder position resolves."
    )


def _record(path: Path, vault_name: str, area_dir: Path, *, measurable: bool,
            reason: str | None = None, members: int | None = None,
            newer: list[str] | None = None) -> dict:
    """One key set for every digest — present in both states, `null` included, so a consumer never
    has to tell a missing key from a negative verdict."""
    return {
        "path": str(path),
        "vault": vault_name,
        "area": str(area_dir),
        "measurable": measurable,
        "reason": reason,
        # null, not 0, when unmeasurable: this function declines to name the membership set, and a
        # count is a claim about it.
        "members": members,
        "newer": newer or [],
        # Tri-state, exactly as `refresh.frozen` is: true = measurably behind, false = the area
        # holds nothing newer, null = no basis for either.
        "stale": bool(newer) if measurable else None,
    }
