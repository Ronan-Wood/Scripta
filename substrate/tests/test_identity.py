"""Identity, read from a file the vault declares and cached in the index.

THE PROPERTY EVERY TEST HERE PROTECTS is that the engine does not OWN identity. The rules — who is
one person, which surfaces resolve to them — are authored elsewhere and expensive to remake, and the
index is dropped and rebuilt by every `--clean` compose. So the cache must be re-derivable from the
declared file alone, and a declared file that cannot be read must refuse rather than quietly index
a corpus with nobody in it.
"""

from __future__ import annotations

import json
import sys
from pathlib import Path

import pytest

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))

from substrate import identity  # noqa: E402


def _vault(tmp_path: Path, *, declares: str | None) -> Path:
    vault = tmp_path / "v"
    vault.mkdir(exist_ok=True)
    lines = ['name = "v"', "inherits = []"]
    if declares is not None:
        lines.append(f'identity = "{declares}"')
    (vault / ".substrate.toml").write_text("\n".join(lines) + "\n", encoding="utf-8")
    return vault


def _roster(tmp_path: Path, entities: list[dict]) -> Path:
    path = tmp_path / "identity.json"
    path.write_text(json.dumps({"version": 1, "entities": entities}), encoding="utf-8")
    return path


# ------------------------------------------------------------------ declaring

def test_a_vault_that_declares_nothing_has_no_identity(tmp_path: Path) -> None:
    """Most vaults are notes with no roster behind them, and must stay that way."""
    assert identity.declared_identity(_vault(tmp_path, declares=None)) is None


def test_a_declaration_that_names_no_file_refuses(tmp_path: Path) -> None:
    vault = tmp_path / "v"
    vault.mkdir()
    (vault / ".substrate.toml").write_text('name = "v"\ninherits = []\nidentity = true\n',
                                           encoding="utf-8")
    with pytest.raises(identity.IdentityError):
        identity.declared_identity(vault)


# ------------------------------------------------------------------ loading

def test_the_apps_own_registry_shape_loads_unchanged(tmp_path: Path) -> None:
    """The point of ignoring unknown keys: an application already maintaining a roster for its own
    purposes can be pointed at directly. Scripta's carries `groups`, `confirmed` and a `verdicts`
    block that mean nothing here — reshaping the file for the engine would make the engine's copy
    the one that drifts."""
    path = _roster(tmp_path, [{
        "id": "e1", "name": "Alexandra McGinn", "kind": "person",
        "aliases": ["McGinn, Alexandra @ Philadelphia", "A. McGinn"],
        "groups": ["CBRE"], "confirmed": True, "gloss": None,
    }])
    (entity,) = identity.load(path)
    assert entity.entity_id == "e1"
    assert entity.name == "Alexandra McGinn"
    assert "A. McGinn" in entity.surfaces


def test_an_unreadable_roster_refuses_rather_than_emptying_the_layer(tmp_path: Path) -> None:
    """A half-read roster drops people silently, and a document that stops mentioning someone reads
    exactly like one that never did."""
    path = tmp_path / "identity.json"
    for body in ("not json", "[]", '{"entities": 3}', "{}"):
        path.write_text(body, encoding="utf-8")
        with pytest.raises(identity.IdentityError):
            identity.load(path)
    with pytest.raises(identity.IdentityError):
        identity.load(tmp_path / "absent.json")


def test_rows_without_an_id_or_a_name_are_skipped_not_fatal(tmp_path: Path) -> None:
    """A malformed ROW is one person missing; a malformed FILE is everyone. They refuse differently
    on purpose."""
    path = _roster(tmp_path, [
        {"id": "", "name": "No id"}, {"id": "e", "name": ""}, "not a dict",
        {"id": "good", "name": "Real Person"},
    ])
    assert [e.entity_id for e in identity.load(path)] == ["good"]


def test_a_surface_too_short_to_be_evidence_is_dropped(tmp_path: Path) -> None:
    """"JS" and "Al" match half a transcript by accident. A false mention puts a person's name on a
    conversation they were never in, which is the one error this layer must not make — measured on
    the operator's own registry, where 2 of 55 entities are surfaces this short."""
    path = _roster(tmp_path, [{"id": "e", "name": "JS", "aliases": ["JS"]}])
    assert identity.load(path) == []


# ------------------------------------------------------------------ matching

def test_mentions_are_word_bounded() -> None:
    """Substring matching makes "Ana" a mention inside "analysis" and "Tim" one inside "estimate"."""
    roster = [identity.Entity(entity_id="e", name="Ana", surfaces=("Ana",)),
              identity.Entity(entity_id="t", name="Tim", surfaces=("Tim",))]
    assert identity.mentions("the analysis and the estimate", roster) == {}
    assert set(identity.mentions("Ana ran the numbers", roster)) == {"e"}


def test_matching_is_case_insensitive_and_records_the_surface_that_matched() -> None:
    """The surface is EVIDENCE. An operator auditing a wrong merge needs to see what was written,
    not only what it was resolved to."""
    roster = [identity.Entity(entity_id="e", name="Alexandra McGinn",
                              surfaces=("Alexandra McGinn", "McGinn"))]
    found = identity.mentions("spoke to mcginn, then to Alexandra McGinn again", roster)
    assert found == {"e": {"Alexandra McGinn", "McGinn"}}


def test_an_entity_absent_from_the_text_is_absent_from_the_result() -> None:
    roster = [identity.Entity(entity_id="e", name="Nobody Here", surfaces=("Nobody Here",))]
    assert identity.mentions("a document about something else", roster) == {}
