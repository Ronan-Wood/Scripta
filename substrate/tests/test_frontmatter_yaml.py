"""Every frontmatter the engine writes is YAML that YAML 1.2, YAML 1.1 (PyYAML) and the engine's own
line reader read as the same values; and `substrate frontmatter check`/`fix` find and rewrite the
notes written before that held."""

from __future__ import annotations

import io
import os

import pytest
import yaml
from hypothesis import HealthCheck, given, settings
from hypothesis import strategies as st
from ruamel.yaml import YAML

from substrate import blob_lifecycle, cli, notes, scopes
from substrate import frontmatter as fm
from substrate.markdown import yaml_scalar
from substrate.markdown.emit import frontmatter
from substrate.markdown.reader import (
    _parse_frontmatter,
    _parse_list,
    doc_id_list,
    frontmatter_pairs,
    normalized_text,
)
from substrate.models import Document

_R12 = YAML(typ="safe", pure=True)
_SHA = "ab" * 32

# Synthetic titles that the unescaped writers turned into frontmatter YAML rejects, or reads as
# something other than the title: quotes with a colon, backslashes, every YAML indicator, the
# plain words YAML 1.1 or 1.2 resolves to another type, and characters YAML cannot hold on a line.
HOSTILE = ['He said "hi": ok', "Regex: \\d+ and C:\\Users", '"quoted": then more', "*bold* intro",
           "&anchor text", "!important", "> quoted", "| piped", "- dash", "@handle", "`code`",
           "%percent", "? question", "[bracket", "{brace", "#hash", "'single", "trailing \\",
           "tab\there", "ünïcödé: x", "a\u2028b: c", "[WIP] notes", "{draft} notes",
           "[Draft] *bold*", "Proof: $\\alpha$", "Proof of $\\alpha$", "{x} *y*", "'90s \\m/",
           '"C:\\Temp" setup', "C:\\new folder", "yes", "no", "on", "y", "null", "~", "true",
           "2026-11-07", "1:20", "0o17", "012", "1_000", "1e5", ".inf", ".NaN", "<<", "=",
           "a #b", "a: #b", "ends with colon:", "it's fine", "'quoted'", "  padded  ",
           "nbsp\u00a0", "\u00a0lead", "bell\x07", "del\x7f", "c1\x9b", "bom\ufeff", "nel\x85x",
           "ffff\uffff", "line\nbreak", "cr\rhere", "", "x" * 300, "a, b", "[a, b]", "\ud800lone"]


def _yaml_reads(block: str) -> list[object]:
    return [yaml.safe_load(block), _R12.load(io.StringIO(block))]


def _doc(**kw) -> Document:
    base = dict(doc_id="n", source_path="/x/a.pdf", source_sha256=_SHA, source_pages=1,
                document_class="reference-frozen")
    return Document(**(base | kw))


def _block(text: str) -> str:
    return text.split("---\n", 2)[1]


# --- the encoder ---------------------------------------------------------------------------------

@pytest.mark.parametrize("value", HOSTILE)
def test_a_hostile_value_reads_back_alike_everywhere(value):
    want = yaml_scalar.sanitize(value)
    for flow in (False, True):
        enc = yaml_scalar.encode(value, flow=flow)
        line = f"k: [{enc}]" if flow else f"k: {enc}"
        expect = {"k": [want] if flow else want}
        if flow and not want:
            continue  # an empty item is not written: every writer drops one
        assert _yaml_reads(line) == [expect, expect], line
        if not flow:
            assert frontmatter_pairs(f"---\n{line}\n---\n") == [("k", want)], line


@settings(max_examples=3000, deadline=None, suppress_health_check=[HealthCheck.too_slow])
@given(st.text(st.characters(codec=None, exclude_categories=()), max_size=40))
def test_any_unicode_value_reads_back_alike_everywhere(value):
    want = yaml_scalar.sanitize(value)
    line = f"k: {yaml_scalar.encode(value)}"
    assert _yaml_reads(line) == [{"k": want}] * 2
    assert frontmatter_pairs(f"---\n{line}\n---\n") == [("k", want)]
    if want.strip():
        item = f"k: [{yaml_scalar.encode(value, flow=True)}, {yaml_scalar.encode(value, flow=True)}]"
        assert _yaml_reads(item) == [{"k": [want, want]}] * 2
        assert fm.list_items(item[3:]) == [(want, item[4] == "'")] * 2


def test_plain_stays_plain_where_it_was_yaml_already():
    """The PDF corpus's emitted bytes do not move where they were already YAML that read alike."""
    for v in ("substrate", "some-doc", "/Users/x/My File.pdf", _SHA, "docling", "0.3.4", "calc"):
        assert yaml_scalar.encode(v) == v


def test_old_double_quoted_values_keep_their_reading():
    """Notes written before keep the line readers' reading: no unescaping, ever."""
    text = '---\ntitle: "C:\\new: x"\nsource_path: "a\\tb"\n---\n'
    assert frontmatter_pairs(text) == [("title", "C:\\new: x"), ("source_path", "a\\tb")]
    assert yaml_scalar.decode("'it''s'") == "it's"
    assert yaml_scalar.decode("'it's'") == "'it's'"  # not one closed scalar: as written


# --- the writers ---------------------------------------------------------------------------------

@pytest.mark.parametrize("title", HOSTILE)
def test_emit_and_the_pin_write_yaml_every_reader_reads_alike(title):
    """Fails on the emitter before: 31 of these titles made a block YAML rejects or misreads."""
    want = yaml_scalar.sanitize(title) or "n"
    emitted = frontmatter(_doc(title=title, domains=["calc", "yes"], supersedes=["old-1", "012"]))
    pinned = notes._pin(emitted.replace("doc_id: n\n", "").encode() + b"# t\n", "n").decode()
    for text in (emitted, pinned):
        for read in _yaml_reads(_block(text)):
            assert read["title"] == want and read["source_sha256"] == _SHA
            assert read["domains"] == ["calc", "yes"] and read["supersedes"] == ["old-1", "012"]
        front, _ = _parse_frontmatter(text)
        assert front["title"] == want
        assert _parse_list(front["domains"]) == ["calc", "yes"]
        assert doc_id_list(front["supersedes"]) == ["old-1", "012"]
        assert fm.assess(text) is None


@settings(max_examples=1500, deadline=None)
@given(title=st.text(st.characters(codec=None, exclude_categories=()), max_size=30),
       path=st.text(st.characters(codec=None, exclude_categories=()), min_size=1, max_size=30))
def test_emit_reads_back_alike_for_any_title_and_path(title, path):
    text = frontmatter(_doc(title=title, source_path=path))
    want = {"title": yaml_scalar.sanitize(title) or "n", "source_path": yaml_scalar.sanitize(path)}
    for read in _yaml_reads(_block(text)):
        assert {k: read[k] for k in want} == want
    front, _ = _parse_frontmatter(text)
    assert {k: front[k] for k in want} == want


# --- check and fix -------------------------------------------------------------------------------

def _old_emit(title: str) -> str:
    """The emitter before: a colon or a leading `[{#` quoted, nothing escaped."""
    v = f'"{title}"' if ":" in title or title.startswith(("[", "{", "#")) else title
    return (f"---\napp: substrate\ndoc_id: n\ntitle: {v}\nsource_sha256: {_SHA}\n"
            f"domains: [calc]\nstatus: active\n---\n\n# t\n\nbody: stays\n")


def _vault(tmp_path, files: dict[str, str | bytes]):
    v = tmp_path / "v"
    v.mkdir()
    (v / ".substrate.toml").write_text('name = "t"\ninherits = []\n', "utf-8")
    for name, content in files.items():
        p = v / name
        p.parent.mkdir(parents=True, exist_ok=True)
        p.write_bytes(content if isinstance(content, bytes) else content.encode())
    return v


@pytest.mark.parametrize("title", ['He said "hi": ok', "*bold* intro", "Regex: \\d+", "'single",
                                   "@handle", "tab\there", "%percent"])
def test_fix_rewrites_the_old_dialect_and_keeps_the_engine_reading(tmp_path, title):
    old = _old_emit(title)
    v = _vault(tmp_path, {"n.md": old})
    before = frontmatter_pairs(old)
    rep = fm.check([v], fix=True)
    assert [f.kind for f in rep.findings] == [fm.NOT_YAML]
    assert (v / "n.md").read_text("utf-8") == old  # a dry run writes nothing
    rep = fm.check([v], fix=True, write=True)
    assert rep.written == [v / "n.md"]
    new = (v / "n.md").read_text("utf-8")
    assert frontmatter_pairs(new) == before
    assert _parse_frontmatter(new)[1] == _parse_frontmatter(old)[1]
    assert yaml.safe_load(_block(new))["title"] == dict(before)["title"]
    assert fm.check([v]).findings == []
    # Only the line YAML misread moved.
    assert [ln for ln in new.splitlines() if ln not in old.splitlines()] == [
        f"title: {yaml_scalar.encode(dict(before)['title'])}"]


def test_fix_keeps_crlf_and_the_app_s_lists(tmp_path):
    old = ('---\r\ntitle: "C:\\Users: setup"\r\nparticipants: ["Last, First", "O\\Brien"]\r\n'
           'tags: ["call", "call-transcriber"]\r\napp: call-transcriber\r\n---\r\n\r\n# h\r\n')
    v = _vault(tmp_path, {"t.md": old.encode()})
    rep = fm.check([v], fix=True, write=True)
    assert rep.written == [v / "t.md"], [f.refused for f in rep.findings]
    new = (v / "t.md").read_bytes().decode()
    assert new.count("\r\n") == old.count("\r\n") and "\n" not in new.replace("\r\n", "")
    assert "participants: ['Last, First', 'O\\Brien']" in new
    assert yaml.safe_load(_block(normalized_text(new.encode())))["participants"] == [
        "Last, First", "O\\Brien"]


def test_check_leaves_yaml_that_reads_alike_and_notes_with_no_frontmatter(tmp_path):
    v = _vault(tmp_path, {
        "ok.md": "---\ntitle: 'it''s'\ndate: 2026-11-07\nsource_pages: 3\n---\nbody\n",
        "none.md": "no frontmatter here\n",
        "rule.md": "---\nprose without a colon\n---\n",
        ".hidden/x.md": _old_emit('a "b": c'),
    })
    rep = fm.check([v])
    assert [f.path.name for f in rep.findings] == ["x.md"]  # hidden folders are read too
    assert rep.notes == 4


@pytest.mark.parametrize("block, why", [
    ("title: x\n  nested: \"a: \"b\"\"", "not a first-column"),
    ("- item: \"a: \"b\"\"", "not a first-column"),
    ("title: \"a: \"b\"\"\n---x: y", "closing"),
])
def test_fix_refuses_what_is_not_the_engine_dialect(tmp_path, block, why):
    v = _vault(tmp_path, {"n.md": f"---\n{block}\n---\nbody\n"})
    rep = fm.check([v], fix=True, write=True)
    assert rep.written == [] and why in (rep.findings[0].refused or "")


def test_fix_refuses_a_note_changed_under_it(tmp_path, monkeypatch):
    v = _vault(tmp_path, {"n.md": _old_emit('a "b": c')})
    real = fm.rewrite

    def racing(data):
        out = real(data)
        (v / "n.md").write_text("changed\n", "utf-8")
        return out

    monkeypatch.setattr(fm, "rewrite", racing)
    rep = fm.check([v], fix=True, write=True)
    assert rep.written == [] and "changed" in rep.findings[0].refused
    assert (v / "n.md").read_text("utf-8") == "changed\n"
    assert [p for p in os.listdir(v) if p.endswith(".tmp")] == []


def test_fix_keeps_the_note_s_mode(tmp_path):
    v = _vault(tmp_path, {"n.md": _old_emit('a "b": c')})
    os.chmod(v / "n.md", 0o640)
    assert fm.check([v], fix=True, write=True).written
    assert os.stat(v / "n.md").st_mode & 0o777 == 0o640


def test_the_cli_reports_fixes_and_exits_by_what_is_left(tmp_path, capsys):
    v = _vault(tmp_path, {"n.md": _old_emit('a "b": c')})
    reg = tmp_path / "reg.json"
    scopes.record("t", vault=v, db=tmp_path / "t.db", index_root=tmp_path / "idx", registry=reg)
    assert cli.main(["frontmatter", "check", "--registry", str(reg)]) == 1
    assert cli.main(["frontmatter", "fix", "--registry", str(reg)]) == 1
    assert "can be fixed (dry run" in capsys.readouterr().out
    assert cli.main(["frontmatter", "fix", "--write", "--registry", str(reg), "--scope", "t"]) == 0
    assert cli.main(["frontmatter", "check", "--registry", str(reg)]) == 0
    assert "0 not YAML, 0 read differently" in capsys.readouterr().out
    assert cli.main(["frontmatter", "check", "--registry", str(reg), "--scope", "nope"]) == 2


def test_compose_counts_the_notes_check_would_name(tmp_path, capsys):
    class Note:
        def __init__(self, p):
            self.path = p

    v = _vault(tmp_path, {"a.md": _old_emit('a "b": c'), "b.md": _old_emit("plain"),
                          "c.md": _old_emit("'quoted'")})
    cli._report_frontmatter([Note(v / n) for n in ("a.md", "b.md", "c.md")])
    assert "1 note(s) not YAML · 0 read differently" in capsys.readouterr().out
    cli._report_frontmatter([Note(v / "b.md")])
    assert capsys.readouterr().out == ""


# --- the app's writers ---------------------------------------------------------------------------

_SWIFT = (os.path.dirname(os.path.abspath(__file__)) + "/../../Core/Sources/ScriptaShared/"
          "Frontmatter.swift")


def _swift_quoted(value: str) -> str:
    """`Frontmatter.quoted`: every free-text value the app writes, always single-quoted."""
    return "'" + yaml_scalar.sanitize(value).replace("'", "''") + "'"


def test_the_app_keeps_the_engine_s_character_rule():
    """`Frontmatter.yamlSafe`'s ranges, read out of the Swift source, keep exactly the characters
    `yaml_scalar.sanitize` keeps: one rule in two languages, checked rather than trusted."""
    import re

    src = open(_SWIFT, encoding="utf-8").read()
    body = src[src.index("func isYAMLPrintable"):]
    case = body[body.index("case ") + 5:body.index(":\n")]
    ranges = [(int(r.split("...")[0], 16), int(r.split("...")[-1], 16))
              for r in (part.strip() for part in case.split(","))]
    assert len(ranges) >= 5
    for cp in range(0x110000):
        swift = any(lo <= cp <= hi for lo, hi in ranges)
        assert swift == (yaml_scalar.sanitize(chr(cp)) == chr(cp)), hex(cp)
    assert re.search(r'if scalar == "\'" \{ out \+= "\'\'" \}', src)


@pytest.mark.parametrize("value", HOSTILE)
def test_the_app_s_quoted_form_reads_back_alike_everywhere(value):
    want = yaml_scalar.sanitize(value)
    line = f"k: {_swift_quoted(value)}"
    assert _yaml_reads(line) == [{"k": want}] * 2
    assert frontmatter_pairs(f"---\n{line}\n---\n") == [("k", want)]
    if want.strip():
        items = f"k: [{_swift_quoted(value)}, 'b']"
        assert _yaml_reads(items) == [{"k": [want, "b"]}] * 2
        assert fm.list_items(items[3:]) == [(want, True), ("b", True)]


@settings(max_examples=2000, deadline=None)
@given(st.text(st.characters(codec=None, exclude_categories=()), max_size=40))
def test_the_app_s_quoted_form_reads_back_alike_for_any_unicode(value):
    want = yaml_scalar.sanitize(value)
    assert _yaml_reads(f"k: {_swift_quoted(value)}") == [{"k": want}] * 2


# --- what review found ---------------------------------------------------------------------------

def _meta(title_line: str, extra: str = "") -> str:
    """The app's `_meta.md` before: a value with a quote left bare, a colon double-quoted."""
    return (f"---\n{title_line}\nstatus: active\ndoc_type: reference\nconfidence: unstated\n"
            f"domains: [calc]\n{extra}---\n\nbody\n")


@pytest.mark.parametrize("line", ["created: 2024-02-30", "x: !!int abc", "x: !!timestamp foo",
                                  "x: !!float abc", "x: " + "[" * 5000])
def test_yaml_a_loader_cannot_read_is_not_yaml_and_never_raises(tmp_path, line, capsys):
    """PyYAML raises ValueError, AttributeError and RecursionError as well as YAMLError. Each took a
    compose down after every gate had passed, freezing the scope, over a count it only reports."""
    text = f"---\ntitle: t\n{line}\n---\nbody\n"
    assert fm.assess(text)[0] == fm.NOT_YAML
    v = _vault(tmp_path, {"n.md": text})

    class Note:
        path = v / "n.md"

    cli._report_frontmatter([Note()])
    assert "1 note(s) not YAML" in capsys.readouterr().out


def test_a_count_that_fails_does_not_fail_the_compose(monkeypatch, capsys, tmp_path):
    v = _vault(tmp_path, {"n.md": "---\ntitle: t\n---\n"})

    class Note:
        path = v / "n.md"

    monkeypatch.setattr(fm, "assess", lambda text, data=None: 1 / 0)
    cli._report_frontmatter([Note()])
    assert "not counted (ZeroDivisionError" in capsys.readouterr().out


def test_an_alias_bomb_is_reported_briefly():
    lines = ["a0: &a0 [x, x, x, x, x, x, x, x, x, x]"]
    lines += [f"a{i}: &a{i} [" + ", ".join([f"*a{i - 1}"] * 10) + "]" for i in range(1, 9)]
    found = fm.assess("---\ntitle: t\n" + "\n".join(lines) + "\n---\n")
    assert found[0] == fm.READS_DIFFERENTLY and sum(map(len, found[1])) < 5000


@pytest.mark.parametrize("block, why", [
    ("app: call-transcriber\napp: other", "more than once"),
    (f"source_sha256: {_SHA}\nsource_sha256: {'cd' * 32}", "more than once"),
    ("title: a\u2028b: c", "NEL, LS or PS"),
    ("title: a\u2029b: c", "NEL, LS or PS"),
])
def test_what_yaml_1_2_refuses_is_not_yaml(block, why):
    kind, reasons = fm.assess(f"---\n{block}\n---\n")
    assert kind == fm.NOT_YAML and why in reasons[0]


@pytest.mark.parametrize("block", [
    "title: !!binary aGVsbG8=", "x: !!set {a, b}", "supersedes: ['victim-note, other-note']",
    "domains: ['calc, ops']", "title: [Draft]", "title: \"C:\\new\"", "title: a #b",
])
def test_what_yaml_reads_otherwise_is_read_differently(block):
    assert fm.assess(f"---\n{block}\n---\n")[0] == fm.READS_DIFFERENTLY


def test_lists_and_text_under_other_keys_agree_as_either():
    assert fm.assess("---\nrelated: [a, b]\nnote: [x] y\n---\n")[0] == fm.NOT_YAML
    assert fm.assess("---\nrelated: [a, b]\ntitle: x\n---\n") is None
    assert fm.assess("---\n\n---\nbody\n") is None


def test_fix_keeps_a_bracketed_title_text(tmp_path):
    """`[WIP] Design [v2]` is a title, not a list: rewritten as one quoted scalar."""
    v = _vault(tmp_path, {"m.md": _meta("title: [WIP] Design [v2]")})
    rep = fm.check([v], fix=True, write=True)
    assert rep.written == [v / "m.md"], [f.refused for f in rep.findings]
    new = (v / "m.md").read_text("utf-8")
    assert "title: '[WIP] Design [v2]'" in new
    assert yaml.safe_load(_block(new))["title"] == "[WIP] Design [v2]"


def test_fix_refuses_a_bracketed_value_under_a_key_it_cannot_place(tmp_path):
    v = _vault(tmp_path, {"m.md": _meta('title: a "b": c', "note: [x] [y]\n")})
    rep = fm.check([v], fix=True, write=True)
    assert rep.written == [] and "list or text" in rep.findings[0].refused


def test_fix_rewrites_a_line_with_no_space_and_keeps_a_spaced_key(tmp_path):
    v = _vault(tmp_path, {"m.md": _meta('title: a "b": c', "kind:active\nlabel : x\n")})
    rep = fm.check([v], fix=True, write=True)
    assert rep.written == [v / "m.md"], [f.refused for f in rep.findings]
    new = (v / "m.md").read_text("utf-8")
    assert "\nkind: active\n" in new and "\nlabel : x\n" in new


def test_fix_leaves_yaml_that_reads_differently_for_a_person(tmp_path):
    old = _old_emit("C:\\new")  # `"C:\new"`: YAML reads a newline, the engine a backslash
    v = _vault(tmp_path, {"n.md": old})
    rep = fm.check([v], fix=True, write=True)
    assert [f.kind for f in rep.findings] == [fm.READS_DIFFERENTLY] and rep.written == []
    assert (v / "n.md").read_text("utf-8") == old


def test_fix_refuses_a_line_yaml_reads_otherwise_inside_a_broken_note(tmp_path):
    v = _vault(tmp_path, {"n.md": _meta('title: a "b": c', 'path: "C:\\new"\n')})
    rep = fm.check([v], fix=True, write=True)
    assert rep.written == [] and "for a person to decide" in rep.findings[0].refused


def test_fix_does_not_write_through_a_link(tmp_path):
    outside = tmp_path / "outside"
    outside.mkdir()
    (outside / "o.md").write_text(_old_emit('a "b": c'), "utf-8")
    v = _vault(tmp_path, {"real.md": _old_emit('a "b": c')})
    os.symlink(outside, v / "linked")
    os.symlink(v / "real.md", v / "alias.md")
    rep = fm.check([v], fix=True, write=True)
    assert rep.written == [v / "real.md"]
    assert (outside / "o.md").read_text("utf-8") == _old_emit('a "b": c')
    assert os.path.islink(v / "alias.md")
    assert all("symlink" in f.refused for f in rep.findings if f.path != v / "real.md")


def test_fix_writes_inherited_vaults_only_when_asked(tmp_path):
    v = _vault(tmp_path, {"n.md": _old_emit('a "b": c')})
    rep = fm.check([v], fix=True, write=True, writable=set())
    assert rep.written == [] and "inherited" in rep.findings[0].refused


def test_fix_refuses_a_read_only_note(tmp_path):
    v = _vault(tmp_path, {"n.md": _old_emit('a "b": c')})
    os.chmod(v / "n.md", 0o444)
    rep = fm.check([v], fix=True, write=True)
    assert rep.written == [] and "read-only" in rep.findings[0].refused


def test_check_does_not_hang_on_a_fifo(tmp_path):
    v = _vault(tmp_path, {})
    os.mkfifo(v / "pipe.md")
    rep = fm.check([v])
    assert rep.notes == 0 and any("pipe.md" in e for e in rep.errors)


def test_the_cli_refuses_to_report_clean_over_nothing(tmp_path, capsys):
    assert cli.main(["frontmatter", "check", "--registry", str(tmp_path / "none.json")]) == 2
    assert "nothing to check" in capsys.readouterr().err


def test_no_short_number_like_value_is_left_plain_for_a_reader_to_resolve():
    """Every value of up to three characters over the characters YAML numbers, dates and booleans
    are spelled with: plain only if both readers read it back as the same string."""
    import itertools

    alphabet = "019_+-.eE:xobyYnN~"
    for n in range(1, 4):
        for chars in itertools.product(alphabet, repeat=n):
            v = "".join(chars)
            line = f"k: {yaml_scalar.encode(v)}"
            assert _yaml_reads(line) == [{"k": v}] * 2, line


# --- what the adversarial review found -----------------------------------------------------------

@pytest.mark.parametrize("line", ["doc_id: 0123", "doc_id: 0x1F", "version: 1.10", "title: no",
                                  "title: null", "title: ~", "start: 10:30", "supersedes: [0123]",
                                  "title: 1_000", "flag: yes"])
def test_a_value_yaml_resolves_to_something_else_reads_differently(line):
    assert fm.assess(f"---\n{line}\n---\n")[0] == fm.READS_DIFFERENTLY, line


@pytest.mark.parametrize("line", ["source_pages: 3", "date: 2026-11-07", "ratio: 1.5",
                                  "draft: true", "draft: True", "empty:", "when: 2001-12-14 21:59:43"])
def test_a_value_yaml_resolves_to_the_same_spelling_agrees(line):
    assert fm.assess(f"---\n{line}\n---\n") is None, line


def test_emit_drops_a_blank_list_item_as_every_list_reader_does():
    text = frontmatter(_doc(domains=["calc", "", " ", "\n"]))
    assert "domains: [calc]" in text and fm.assess(text) is None


def test_list_items_trims_only_what_the_app_trims():
    """`Frontmatter.parseList` trims tab and the space separators, not controls."""
    assert fm.list_items("[ 'a, b'\t]") == [("a, b", True)]
    assert fm.list_items("[\x1f'a, b']") == [("\x1f'a", False), ("b'", False)]


def test_a_dry_run_says_what_an_inherited_vault_needs(tmp_path, capsys):
    core = _vault(tmp_path, {"n.md": _old_emit('a "b": c')})
    rep = fm.check([core], fix=True, writable=set())
    assert rep.findings[0].inherited and rep.findings[0].fixed is not None


def test_a_note_that_is_not_utf8_is_named_not_silently_skipped(tmp_path):
    v = _vault(tmp_path, {"bad.md": b"---\ntitle: \xff\n---\n"})
    rep = fm.check([v])
    assert rep.not_utf8 == [v / "bad.md"] and rep.notes == 0


# --- the gate is gc's own reading ----------------------------------------------------------------

@pytest.mark.parametrize("text", [
    f'---\n# a comment\ntitle: a "b": c\nsource_sha256: {_SHA}\n---\nbody\n',
    f'---\ntitle: a "b": c\nsource_sha256: {_SHA}\n...\nbody\n',
])
def test_a_note_gc_admits_only_through_its_allowance_is_counted(tmp_path, text):
    """gc finds the block by its own fences (`...` closes one, a `#` line is a comment), where the
    engine reads no frontmatter at all. Deleting the allowance would refuse these notes, so `check`
    must not call them clean, and `fix` refuses them rather than guessing."""
    assert blob_lifecycle.admitted_only_by_dialect(text.encode())
    assert fm.assess(text) == (fm.NOT_YAML, [fm._GC_ONLY])
    v = _vault(tmp_path, {"n.md": text})
    rep = fm.check([v], fix=True, write=True)
    assert rep.written == [] and rep.findings[0].refused


def test_an_old_note_gc_admits_only_through_its_allowance_is_fixed_off_it(tmp_path):
    old = _old_emit('a "b": c')
    assert blob_lifecycle.admitted_only_by_dialect(old.encode())
    assert fm._GC_ONLY in fm.assess(old)[1]
    v = _vault(tmp_path, {"n.md": old})
    assert fm.check([v], fix=True, write=True).written == [v / "n.md"]
    assert not blob_lifecycle.admitted_only_by_dialect((v / "n.md").read_bytes())


# --- the gate reads what gc reads ----------------------------------------------------------------

_DIALECT = f'---\ntitle: He said "hi": ok\nsource_sha256: {_SHA}\n---\n\nbody\n'


@pytest.mark.parametrize("data", [
    b"\xef\xbb\xbf" + _DIALECT.encode(),                    # a UTF-8 BOM
    b"\xef\xbb\xbf\xef\xbb\xbf" + _DIALECT.encode(),        # two
    _DIALECT.encode("utf-16"),                              # UTF-16 with its BOM
    _DIALECT.encode("utf-16-le"),                           # UTF-16 without one: valid UTF-8 too
    _DIALECT.replace("body", "caf\xe9").encode("latin-1"),  # one byte that is not UTF-8
], ids=["bom", "two-boms", "utf-16", "utf-16-le", "latin-1"])
def test_a_note_gc_reads_in_another_decoding_keeps_check_failing(tmp_path, data):
    """gc reads a note every way it could be decoded, a BOM stripped and bad bytes replaced. A
    note `check` read only as strict UTF-8 passed it while gc still needed the allowance."""
    assert blob_lifecycle.admitted_only_by_dialect(data)
    v = _vault(tmp_path, {"n.md": data})
    rep = fm.check([v], fix=True, write=True)
    assert [f.kind for f in rep.findings] == [fm.NOT_YAML] and fm._GC_ONLY in rep.findings[0].reasons
    assert rep.written == [] and (v / "n.md").read_bytes() == data


def test_a_huge_frontmatter_is_judged_without_loading_it():
    import time

    text = "---\n" + "".join(f"k{i}: v\n" for i in range(150_000)) + "---\n"
    start = time.monotonic()
    found = fm.assess(text)
    assert found[0] == fm.NOT_YAML and "KiB" in found[1][0]
    assert time.monotonic() - start < 5


def test_many_keys_are_counted_in_linear_time():
    import time

    text = "---\n" + "".join(f"k{i}: v\n" for i in range(30_000)) + "---\n"
    start = time.monotonic()
    assert fm.assess(text) is None
    assert time.monotonic() - start < 10


@pytest.mark.parametrize("claim", [f"source_sha256: \"{_SHA}\"'", f"raw_sha256: ,'{_SHA}'"])
def test_fix_refuses_a_rewrite_gc_would_read_otherwise(tmp_path, claim):
    """gc's line scan strips every surrounding quote from a claim; YAML would read the rewritten
    value as one string that is not a checksum, and gc would refuse the note."""
    v = _vault(tmp_path, {"n.md": f'---\ntitle: a "b": c\n{claim}\n---\nbody\n'})
    rep = fm.check([v], fix=True, write=True)
    assert rep.written == [] and "`blobs gc`" in (rep.findings[0].refused or "")


@pytest.mark.parametrize("line", ["version: 1e5", "x: 0o17", "x: +.5"])
def test_a_value_only_yaml_1_2_resolves_reads_differently(line):
    assert fm.assess(f"---\n{line}\n---\n")[0] == fm.READS_DIFFERENTLY, line


def test_a_vault_inside_another_owns_its_notes_and_is_read_once(tmp_path):
    outer = _vault(tmp_path, {"p.md": _old_emit('a "b": c')})
    inner = outer / "core"
    inner.mkdir()
    (inner / "c.md").write_text(_old_emit('d "e": f'), "utf-8")
    rep = fm.check([outer, inner], fix=True, write=True, writable={outer})
    assert sorted(f.path.name for f in rep.findings) == ["c.md", "p.md"]
    assert rep.written == [outer / "p.md"]
    assert "inherited" in next(f.refused for f in rep.findings if f.path.name == "c.md")


@pytest.mark.parametrize("line", ["x: -0o17", "x: +0o17", "x: 0o_7", "x: 1_0e5", "x: 1_000e3"])
def test_a_spelling_only_ruamel_resolves_reads_differently(line):
    assert fm.assess(f"---\n{line}\n---\n")[0] == fm.READS_DIFFERENTLY, line


def test_every_short_value_pyyaml_and_yaml_1_2_read_apart_is_caught():
    """Plain values PyYAML reads as text and a YAML 1.2 reader as something else: the checker must
    not call any of them agreeing."""
    import itertools

    for n in range(1, 4):
        for chars in itertools.product("019_+-.eEoxb", repeat=n):
            v = "".join(chars)
            try:
                a, b = _yaml_reads(f"k: {v}")
            except Exception:  # noqa: BLE001 — a reader that rejects it is not agreement either
                continue
            if isinstance(a["k"], str) and a["k"] == v and not isinstance(b["k"], str):
                assert fm.assess(f"---\nk: {v}\n---\n") is not None, v


@pytest.mark.parametrize("block", ['title: a\n"title": b', "title: a\n'title': b"])
def test_a_key_repeated_under_quotes_is_not_yaml(block):
    assert fm.assess(f"---\n{block}\n---\n")[0] == fm.NOT_YAML
