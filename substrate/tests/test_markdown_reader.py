"""Tests for the markdown → Document reader (Unit 1) and its A18 silent-loss guard.

Runnable with plain `python tests/test_markdown_reader.py` (no pytest) and discovered by pytest.

The load-bearing test is `test_a18_catches_a_dropped_block`: the whole reason A18 measures
against the SOURCE rather than the re-emitted body is that a parser that silently drops a line
depresses re-emit coverage by ~nothing (the line leaves the body too) while cratering source
coverage. If that test ever passes with a re-emit-style check, the guard has lost its teeth.
"""

from __future__ import annotations

import sys
from pathlib import Path

# `[tool.uv] package = false`, so put the project root on the path (script + pytest, any cwd).
sys.path.insert(0, str(Path(__file__).resolve().parent.parent))

import time  # noqa: E402

from substrate import classes  # noqa: E402
from substrate.chunk.chunker import chunk  # noqa: E402
from substrate.markdown.emit import emit  # noqa: E402
from substrate.markdown.reader import (  # noqa: E402
    _SHA256,
    _atx_text,
    _blocks,
    _parse_frontmatter,
    content_coverage,
    read_markdown,
    uncovered_content_blocks,
)
from substrate.models import Kind  # noqa: E402

GATE = 0.98

SAMPLE = """# Title

Intro prose before any subsection appears here.

## Consensus

Raft decomposes consensus into leader election and log replication.

### Raft Details

- first list item alpha
- second list item bravo

```python
def compact(runs):
    return merge(runs)
```

| Engine | Speed |
| --- | --- |
| LSM | fast |

Closing paragraph with a distinctive sentinel term quokka.
"""


def _write(tmp: Path, text: str, name: str = "note.md") -> Path:
    p = tmp / name
    p.write_text(text, encoding="utf-8")
    return p


def _tmp() -> Path:
    import tempfile

    return Path(tempfile.mkdtemp())


def _captured(chunks, blocks) -> list[str]:
    """The same capture set cmd_ingest_md gates on: chunk text_with_path + fence languages +
    heading block texts (empty-section headings form no chunk but are not a content loss)."""
    return (
        [c.text_with_path for c in chunks]
        + [b.lang for b in blocks if b.lang]
        + [b.text for b in blocks if b.kind is Kind.HEADING]
    )


def _pipeline(md_path: Path):
    doc, body_md, stats = read_markdown(md_path)
    classes.apply(doc)
    emit(doc, repair=False)
    chunks, _ = chunk(doc)
    return doc, body_md, chunks, stats


# ---------------------------------------------------------------- structure honoured

def test_structure_kinds() -> None:
    blocks = _blocks(SAMPLE)
    kinds = {b.kind for b in blocks}
    assert Kind.HEADING in kinds and Kind.CODE in kinds
    assert Kind.LIST_ITEM in kinds and Kind.TABLE in kinds and Kind.TEXT in kinds


def test_heading_levels_map_to_depth() -> None:
    blocks = _blocks(SAMPLE)
    heads = {b.text: b.level for b in blocks if b.kind is Kind.HEADING}
    assert heads["Title"] == 1
    assert heads["Consensus"] == 2
    assert heads["Raft Details"] == 3


def test_heading_path_hierarchy() -> None:
    """The reader's levels must drive leaf_sections' path nesting, verbatim from the markdown."""
    tmp = _tmp()
    doc, _, chunks, _ = _pipeline(_write(tmp, SAMPLE))
    consensus = next(c for c in chunks if c.kind == "passage" and "leader election" in c.text)
    assert consensus.path == ["Title", "Consensus"]
    deep = next(c for c in chunks if c.kind == "passage" and "list item alpha" in c.text)
    assert deep.path == ["Title", "Consensus", "Raft Details"]


def test_code_language_captured() -> None:
    blocks = _blocks(SAMPLE)
    code = next(b for b in blocks if b.kind is Kind.CODE)
    assert code.lang == "python"
    assert "def compact" in code.text and "```" not in code.text


def test_list_markers_stripped() -> None:
    blocks = _blocks(SAMPLE)
    items = [b.text for b in blocks if b.kind is Kind.LIST_ITEM]
    assert "first list item alpha" in items
    assert not any(t.startswith("- ") for t in items)


def test_ordered_and_star_lists() -> None:
    blocks = _blocks("1. first\n2. second\n\n* star one\n+ plus two\n")
    items = [b.text for b in blocks if b.kind is Kind.LIST_ITEM]
    assert items == ["first", "second", "star one", "plus two"]


# ---------------------------------------------------------------- document shape

def test_document_shape_feeds_chunker() -> None:
    tmp = _tmp()
    doc, _, chunks, stats = _pipeline(_write(tmp, SAMPLE))
    assert doc.extractor_arm == "markdown"
    passages = [c for c in chunks if c.kind == "passage"]
    body, _ = emit(doc, repair=False)
    # Offsets are in-range and ordered for every passage (what the store's char columns need).
    assert passages
    for c in passages:
        assert 0 <= c.char_start <= c.char_end <= len(body)
    # A bare-TEXT passage reconstructs byte-exactly from the emitted body — the offset map is
    # load-bearing. (Passages carrying list/code markup legitimately don't: body[start:end]
    # includes the "- "/fence markup the packed text omits, same as on the PDF path.)
    intro = next(c for c in passages if "Intro prose" in c.text)
    assert body[intro.char_start:intro.char_end] == intro.text


def test_no_docling_or_torch_imported() -> None:
    """The vault path must run on a fresh download with nothing installed. Assert the reader
    pulled in no heavy extractor dependency when it parsed."""
    _pipeline(_write(_tmp(), SAMPLE))
    assert "docling" not in sys.modules
    assert "torch" not in sys.modules


# ---------------------------------------------------------------- frontmatter

def test_frontmatter_recovers_spine() -> None:
    md = (
        "---\n"
        "doc_id: my-fixed-id-deadbeef\n"
        "title: Fixed Title\n"
        "document_class: reference-versioned\n"
        f"source_sha256: {'a1' * 32}\n"
        "source_pages: 42\n"
        "version: go1.26\n"
        "---\n\n"
        "# Body\n\nGo version go1.26 body content here.\n"
    )
    doc, _, _ = read_markdown(_write(_tmp(), md))
    assert doc.doc_id == "my-fixed-id-deadbeef"
    assert doc.title == "Fixed Title"
    assert doc.document_class == "reference-versioned"
    assert doc.source_sha256 == "a1" * 32  # valid 64-hex kept
    assert doc.source_pages == 42
    assert doc.version == "go1.26"


def test_no_frontmatter_synthesises_id_and_default_class() -> None:
    doc, _, _ = read_markdown(_write(_tmp(), SAMPLE))
    assert doc.document_class == "reference-frozen"  # default
    assert doc.doc_id.startswith("note-") and len(doc.doc_id) > len("note-")
    assert doc.source_sha256  # derived from file bytes


def test_cli_doc_class_overrides_frontmatter() -> None:
    md = "---\ndocument_class: reference-frozen\n---\n\n# H\n\ntext\n"
    doc, _, _ = read_markdown(_write(_tmp(), md), doc_class="reference-versioned")
    assert doc.document_class == "reference-versioned"


def test_page_anchors_parsed() -> None:
    md = "<!-- page:5 -->\n\n# H\n\nfirst\n\n<!-- page:6 -->\n\nsecond\n"
    blocks = _blocks(md)
    pages = {b.text: b.page for b in blocks if b.kind is Kind.TEXT}
    assert pages["first"] == 5 and pages["second"] == 6


# ---------------------------------------------------------------- A18 coverage guard

def test_coverage_perfect_on_clean_parse() -> None:
    tmp = _tmp()
    _, body_md, chunks, _ = _pipeline(_write(tmp, SAMPLE))
    doc, _, _ = read_markdown(tmp / "note.md")
    cov, missing = content_coverage(body_md, _captured(chunks, doc.blocks))
    assert cov >= GATE, (cov, missing)


def test_a18_catches_a_dropped_block() -> None:
    """THE load-bearing test. Drop a block after parsing (simulating a parser hole) and prove
    source-coverage craters — while re-emit coverage would barely move, which is the whole
    reason A18 measures against the source."""
    tmp = _tmp()
    doc, body_md, stats = read_markdown(_write(tmp, SAMPLE))
    # Excise the closing paragraph — its sentinel word 'quokka' appears nowhere else.
    kept = [b for b in doc.blocks if "quokka" not in b.text]
    assert len(kept) == len(doc.blocks) - 1
    doc.blocks = kept
    classes.apply(doc)
    emit(doc, repair=False)
    chunks, _ = chunk(doc)
    cov, missing = content_coverage(body_md, _captured(chunks, doc.blocks))
    assert cov < GATE, cov
    assert "quokka" in missing


def test_coverage_multiset_catches_recurring_word_drop() -> None:
    """A dropped paragraph is caught even when its words recur — the COUNT falls short, so a
    set-based check (which the multiset supersedes) would miss it."""
    body = "alpha beta alpha beta gamma\n\nalpha beta\n"
    # 'captured' has only one alpha/beta pair though the source has two — a whole line vanished.
    cov, missing = content_coverage(body, ["alpha beta gamma"])
    assert cov < 1.0
    assert "alpha" in missing and "beta" in missing


def test_frontmatter_excluded_from_coverage() -> None:
    """Frontmatter keys are not body content — they must not count as 'dropped'."""
    md = "---\ntitle: Some Frontmatter Title Words\n---\n\n# H\n\nbody words here\n"
    _, body_md = _parse_frontmatter(md)
    cov, missing = content_coverage(body_md, ["H", "body words here"])
    assert cov == 1.0, missing


# ---------------------------------------------------------------- hardening (crosscheck fixes)

def test_atx_closing_hash_preserves_csharp() -> None:
    """ATX closing-hash trimming requires a preceding space, so `## C#` keeps its `#`."""
    assert _atx_text("C#") == "C#"
    assert _atx_text("F#") == "F#"
    assert _atx_text("Foo ##") == "Foo"
    assert _atx_text("Foo #") == "Foo"
    assert _atx_text("Bar") == "Bar"
    blocks = _blocks("## C# for Beginners\n\ntext\n")
    assert next(b for b in blocks if b.kind is Kind.HEADING).text == "C# for Beginners"


def test_heading_no_redos() -> None:
    """A heading line ending in a long whitespace run must not hang (the old regex was ~cubic)."""
    md = "# a" + " " * 20000 + "x\n\nbody\n"
    t0 = time.monotonic()
    _blocks(md)
    assert time.monotonic() - t0 < 2.0


def test_fence_info_string_line_does_not_close() -> None:
    """An inner fence line carrying an info string (```python) must NOT close the block — a
    closing fence has no info string (CommonMark). The old `startswith` closed on it, leaking
    the block body as loose prose. A BARE ``` still closes (correct)."""
    md = "```markdown\n```python\nx = 1\n```\n\nafter\n"
    blocks = _blocks(md)
    codes = [b for b in blocks if b.kind is Kind.CODE]
    assert len(codes) == 1
    assert "```python" in codes[0].text and "x = 1" in codes[0].text
    assert any(b.kind is Kind.TEXT and "after" in b.text for b in blocks)


def test_tilde_fence() -> None:
    blocks = _blocks("~~~\ncode line\n~~~\n")
    codes = [b for b in blocks if b.kind is Kind.CODE]
    assert len(codes) == 1 and codes[0].text == "code line"


def test_coverage_catches_non_latin_drop() -> None:
    """Coverage must see a dropped non-Latin paragraph — an ASCII-only tokenizer was blind."""
    body = "α β γ δ concept\n\nこれは 重要 な 段落 です\n"
    # 'captured' omits the CJK line entirely.
    cov, missing = content_coverage(body, ["α β γ δ concept"])
    assert cov < 1.0
    assert any("重要" in m or "これは" in m or "段落" in m for m in missing)


def test_accented_words_tokenised_whole() -> None:
    cov, _ = content_coverage("café naïve résumé", ["café naïve résumé"])
    assert cov == 1.0


def test_versioned_frontmatter_survives_nonmatching_body() -> None:
    """A reference-versioned doc whose frontmatter carries the version but whose BODY has no
    re-matchable version string must ingest (apply() must not clobber the frontmatter version)."""
    md = (
        "---\ndocument_class: reference-versioned\nversion: go1.26\n---\n\n"
        "# Heading\n\nBody with no matchable version string at all.\n"
    )
    doc, _, _ = read_markdown(_write(_tmp(), md))
    assert doc.version == "go1.26"
    meta = classes.apply(doc)  # must NOT raise ClassPolicyError
    assert meta["version"] == "go1.26"


def test_bad_numeric_frontmatter_does_not_crash() -> None:
    for bad in ("²", "--5", "---7", "12x", "9" * 40):
        md = f"---\nsource_pages: {bad}\npage_label_offset: {bad}\n---\n\n# H\n\ntext\n"
        doc, _, _ = read_markdown(_write(_tmp(), md, name=f"n{abs(hash(bad))}.md"))
        assert isinstance(doc.source_pages, int) and 1 <= doc.source_pages < 2**63
        assert doc.page_label_offset is None


def test_invalid_doc_id_is_derived_not_trusted() -> None:
    """A frontmatter doc_id outside the slug charset is rejected (index is keyed on doc_id)."""
    for bad in ("../../etc/passwd", "UPPER", "has space", "a" * 100):
        md = f"---\ndoc_id: {bad}\n---\n\n# H\n\ntext\n"
        doc, _, _ = read_markdown(_write(_tmp(), md, name=f"d{abs(hash(bad))}.md"))
        assert doc.doc_id != bad and doc.doc_id.startswith("d")


def test_valid_frontmatter_doc_id_kept() -> None:
    md = "---\ndoc_id: my-doc-deadbeef\n---\n\n# H\n\ntext\n"
    doc, _, _ = read_markdown(_write(_tmp(), md))
    assert doc.doc_id == "my-doc-deadbeef"


def test_non_utf8_raises_clean() -> None:
    tmp = _tmp()
    p = tmp / "bad.md"
    p.write_bytes(b"# H\n\n\xff\xfe not utf-8\n")
    try:
        read_markdown(p)
        assert False, "expected ValueError"
    except ValueError:
        pass


def test_per_block_drop_flagged_at_scale() -> None:
    """The per-block guard flags a single dropped content block regardless of doc size — the
    aggregate ratio would hide it in a large corpus."""
    blocks = _blocks(SAMPLE)
    captured = [b.text for b in blocks]
    assert uncovered_content_blocks(blocks, captured) == []
    # Drop the closing paragraph's text from the captured set → its block is flagged.
    para = next(b for b in blocks if "quokka" in b.text)
    captured_missing = [b.text for b in blocks if "quokka" not in b.text]
    assert para.id in uncovered_content_blocks(blocks, captured_missing)


def test_per_block_ignores_headings() -> None:
    """Headings are excluded (empty-section headings are dropped by design; A17 covers them)."""
    blocks = _blocks("# Orphan Heading\n\n## Another\n")
    # Nothing captured at all, yet no CONTENT block exists to flag.
    assert uncovered_content_blocks(blocks, []) == []


# ------------------------------------------------------------ adversary-pass fixes

def test_thematic_break_is_not_frontmatter() -> None:
    """A note opening with a `---` divider (prose between two rules) must NOT be eaten as
    frontmatter — that silently dropped the prose where A18 (post-frontmatter) couldn't see it."""
    md = "---\n\nMeeting notes. Discussed the quokka migration.\n\n---\n\nAction items.\n"
    front, body_md = _parse_frontmatter(md)
    assert front == {} and "quokka" in body_md
    blocks = _blocks(body_md)
    assert any("quokka" in b.text for b in blocks)


def test_real_frontmatter_still_parsed() -> None:
    front, body = _parse_frontmatter("---\ntitle: A Real Title\nversion: 1.0\n---\n\nbody\n")
    assert front["title"] == "A Real Title" and front["version"] == "1.0"
    assert body.strip() == "body"


def test_coverage_catches_numeric_block_drop() -> None:
    """A dropped all-numeric block (numeric table/list) must be visible — a letters-only
    tokenizer scored it 1.0."""
    body = "prose alpha\n\n| 1234 | 5678 |\n\n- 4242\n"
    cov, missing = content_coverage(body, ["prose alpha"])
    assert cov < 1.0
    assert any(m in ("1234", "5678", "4242") for m in missing)


def test_per_block_flags_numeric_block() -> None:
    blocks = _blocks("| 1234 | 5678 |\n\ntext body here\n")
    table = next(b for b in blocks if b.kind is Kind.TABLE)
    assert table.id in uncovered_content_blocks(blocks, ["text body here"])


def test_empty_section_outline_doc_not_falsely_refused() -> None:
    """An outline/TOC note (headings with empty sections) must ingest with coverage ≈ 1.0 once
    heading texts are in the captured set."""
    md = "# Overview\n\n## Alpha\n\n## Bravo\n\n## Charlie\n\nBody under Charlie.\n"
    tmp = _tmp()
    doc, body_md, _ = read_markdown(_write(tmp, md))
    classes.apply(doc)
    emit(doc, repair=False)
    chunks, _ = chunk(doc)
    cov, missing = content_coverage(body_md, _captured(chunks, doc.blocks))
    assert cov >= GATE, (cov, missing)


def test_bignum_page_anchor_bounded() -> None:
    """A crafted page anchor must not set source_pages to a >int64 bignum (SQLite OverflowError)."""
    md = "<!-- page:" + "9" * 40 + " -->\n\n# H\n\ntext\n"
    doc, _, _ = read_markdown(_write(_tmp(), md))
    assert 1 <= doc.source_pages < 2**63
    assert all(b.page is None or b.page < 2**63 for b in doc.blocks)


def test_crlf_frontmatter_recognised() -> None:
    md = "---\r\ndoc_id: crlf-doc-deadbeef\r\ntitle: CRLF\r\n---\r\n\r\n# H\r\n\r\nbody\r\n"
    doc, _, _ = read_markdown(_write(_tmp(), md, name="crlf.md"))
    assert doc.doc_id == "crlf-doc-deadbeef" and doc.title == "CRLF"


def test_bad_source_sha256_derived() -> None:
    md = "---\nsource_sha256: not-a-real-digest\n---\n\n# H\n\ntext\n"
    doc, _, _ = read_markdown(_write(_tmp(), md))
    assert _SHA256.fullmatch(doc.source_sha256)  # derived from file bytes, 64 hex


if __name__ == "__main__":
    _tests = [v for k, v in sorted(globals().items()) if k.startswith("test_") and callable(v)]
    _failed = 0
    for _t in _tests:
        try:
            _t()
            print(f"  PASS  {_t.__name__}")
        except Exception as e:  # noqa: BLE001
            _failed += 1
            print(f"  FAIL  {_t.__name__}: {type(e).__name__}: {e}")
    print(f"\n{len(_tests) - _failed}/{len(_tests)} passed")
    raise SystemExit(1 if _failed else 0)
