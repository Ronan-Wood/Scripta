"""The PDF and image readers that need no model weights, and the optional docling models folder.

Nothing here loads a model or runs Apple's recognizer. The PDFs are generated with pdfium's standard
fonts, the recognizer's output is supplied as JSON, and where the recognizer's ABSENCE is the subject
its binary is pointed at a path that does not exist.
"""

from __future__ import annotations

import ctypes
import json
from pathlib import Path

import pytest

pdfium = pytest.importorskip("pypdfium2")
import pypdfium2.raw as raw  # noqa: E402

from substrate import cli, paths  # noqa: E402
from substrate.markdown.emit import emit  # noqa: E402
from substrate.extract import apple_arm, convert  # noqa: E402
from substrate.extract.pdftext_arm import PdfReadError, TextLayerExtractor  # noqa: E402
from substrate.models import Kind  # noqa: E402

QUIET = {"log": lambda *_: None}

RECOGNIZED = {"source": "image", "pages": [{"page": 1, "width": 1000, "height": 800, "blocks": [
    {"kind": "title", "text": "Quarterly Review", "left": 50, "top": 40, "line_height": 40},
    {"kind": "text", "text": "Renewals", "left": 50, "top": 120, "line_height": 30},
    {"kind": "text", "text": "Renewals moved faster this quarter.", "left": 50, "top": 170,
     "line_height": 20},
    {"kind": "text", "text": "Pricing was the most common question.", "left": 50, "top": 200,
     "line_height": 20},
    {"kind": "list_item", "text": "• Clearer pricing", "left": 60, "top": 240, "line_height": 20},
    {"kind": "table", "text": "| a | b |\n| --- | --- |\n| 1 | 2 |", "left": 50, "top": 300},
]}]}


def _write_pdf(path: Path, pages: list[list[tuple[str, str, float, float, float]]]) -> Path:
    """Each page is a list of (text, standard font, size, x, baseline y) on a US Letter page."""
    pdf = pdfium.PdfDocument.new()
    for runs in pages:
        page = pdf.new_page(612, 792)
        for text, font, size, x, y in runs:
            handle = raw.FPDFText_LoadStandardFont(pdf.raw, font.encode())
            obj = raw.FPDFPageObj_CreateTextObj(pdf.raw, handle, size)
            data = (text + "\0").encode("utf-16-le")
            buffer = ctypes.create_string_buffer(data, len(data))
            assert raw.FPDFText_SetText(obj, ctypes.cast(buffer, raw.FPDF_WIDESTRING))
            raw.FPDFPageObj_Transform(obj, 1, 0, 0, 1, x, y)
            raw.FPDFPage_InsertObject(page.raw, obj)
        assert raw.FPDFPage_GenerateContent(page.raw)
    pdf.save(str(path))
    pdf.close()
    return path


def _report(tmp_path: Path) -> Path:
    pages = []
    for n in (1, 2):
        runs = [("Field Notes Weekly", "Helvetica", 9, 72, 770)]
        if n == 1:
            runs.append(("Quarterly Review", "Helvetica-Bold", 24, 72, 700))
        runs += [
            (f"Section {n}", "Helvetica-Bold", 16, 72, 660),
            ("Renewals moved faster this quarter than the last one did.", "Helvetica", 11, 72, 630),
            ("Most customers asked for clearer pricing and a review.", "Helvetica", 11, 72, 616),
            ("• Clearer pricing tiers", "Helvetica", 11, 72, 590),
            (f"Page {n}", "Helvetica", 9, 300, 30),
        ]
        pages.append(runs)
    return _write_pdf(tmp_path / "report.pdf", pages)


def _scan(tmp_path: Path) -> Path:
    image = pytest.importorskip("PIL.Image")
    path = tmp_path / "scan.pdf"
    image.new("RGB", (300, 400), "white").save(path, "PDF")
    return path


def test_text_layer_reads_headings_lists_paragraphs_and_running_furniture(tmp_path):
    doc = TextLayerExtractor().extract(_report(tmp_path), "reference-frozen", **QUIET)
    body = doc.body_blocks
    assert [(b.text, b.level) for b in body if b.kind is Kind.HEADING] == [
        ("Quarterly Review", 1), ("Section 1", 2), ("Section 2", 2)]
    assert ("Renewals moved faster this quarter than the last one did. Most customers asked for "
            "clearer pricing and a review.") in [b.text for b in body if b.kind is Kind.TEXT]
    # MARKER-FREE, like every other reader's list items: `emit` renders `- {text}` itself.
    assert [b.text for b in body if b.kind is Kind.LIST_ITEM] == ["Clearer pricing tiers"] * 2
    rendered, _ = emit(doc)
    assert "- Clearer pricing tiers" in rendered and "- - " not in rendered
    assert sorted(b.text for b in doc.blocks if b.dropped) == [
        "Field Notes Weekly", "Field Notes Weekly", "Page 1", "Page 2"]
    assert (doc.extractor_arm, doc.layout_model) == ("pdf-text", "")
    assert doc.extract_confidence["text_layer_pages"] == 2
    assert doc.extract_confidence["scanned_pages"] == []


def test_a_heading_claimed_as_furniture_on_one_page_comes_back_a_heading(tmp_path):
    pdf = _write_pdf(tmp_path / "edge.pdf", [[
        ("Opening Chapter", "Helvetica-Bold", 24, 72, 760),
        ("The first paragraph of the chapter is ordinary body text here.", "Helvetica", 11, 72, 700),
        ("It continues onto a second line of the same paragraph body.", "Helvetica", 11, 72, 686),
    ]])
    doc = TextLayerExtractor().extract(pdf, "reference-frozen", **QUIET)
    title = next(b for b in doc.blocks if b.text == "Opening Chapter")
    assert title.furniture_claimed and not title.dropped
    assert (title.kind, title.level) == (Kind.HEADING, 1)


def test_a_bold_line_inside_a_sentence_is_not_a_heading_but_a_title_under_a_header_is(tmp_path):
    pdf = _write_pdf(tmp_path / "flow.pdf", [[
        ("Running Header Text", "Helvetica", 9, 72, 752),
        ("Annual Summary", "Helvetica-Bold", 24, 72, 728),
        ("Customers who renewed early received the discount described in the", "Helvetica", 11, 72, 690),
        ("Eligible Renewal Terms And Conditions", "Helvetica-Bold", 11, 72, 677),
        ("section that follows, once their account was reviewed by the team.", "Helvetica", 11, 72, 664),
    ]])
    doc = TextLayerExtractor().extract(pdf, "reference-frozen", **QUIET)
    assert [b.text for b in doc.body_blocks if b.kind is Kind.HEADING] == ["Annual Summary"]


def test_a_scan_in_an_engine_without_the_recognizer_blames_the_engine(tmp_path, monkeypatch):
    """The ENGINE is incomplete, not the document — the two failures read differently."""
    scan = _scan(tmp_path)
    monkeypatch.setattr(apple_arm, "BINARY", tmp_path / "no-extract-apple")
    with pytest.raises(PdfReadError, match=r"this engine cannot read them"):
        TextLayerExtractor().extract(scan, "reference-frozen", **QUIET)


def test_a_scan_the_recognizer_could_not_read_names_the_pages(tmp_path, monkeypatch):
    scan = _scan(tmp_path)

    def refuses(path, *, pages=None):
        raise apple_arm.AppleReaderError("Vision found nothing")

    monkeypatch.setattr(apple_arm, "read", refuses)
    with pytest.raises(PdfReadError, match=r"page\(s\) 1 have no text layer"):
        TextLayerExtractor().extract(scan, "reference-frozen", **QUIET)


def test_scanned_pages_take_the_recognizers_reading(tmp_path, monkeypatch):
    scan = _scan(tmp_path)
    asked = {}

    def recognized(path, *, pages=None):
        asked["pages"] = pages
        page = dict(RECOGNIZED["pages"][0], height=792)
        return {"source": "pdf", "pages": [page]}

    monkeypatch.setattr(apple_arm, "read", recognized)
    doc = TextLayerExtractor().extract(scan, "reference-frozen", **QUIET)
    assert asked["pages"] == [1]
    assert [(b.kind, b.text) for b in doc.body_blocks] == [
        (Kind.HEADING, "Quarterly Review"),
        (Kind.HEADING, "Renewals"),
        (Kind.TEXT, "Renewals moved faster this quarter."),
        (Kind.TEXT, "Pricing was the most common question."),
        (Kind.LIST_ITEM, "Clearer pricing"),
        (Kind.TABLE, "| a | b |\n| --- | --- |\n| 1 | 2 |"),
    ]
    assert doc.extract_confidence["scanned_pages"] == [1]
    assert apple_arm.EXTRACTOR in doc.extractor


def test_scanned_pages_are_read_in_batches(monkeypatch, tmp_path):
    """One call per batch, so a long scan is not one subprocess holding the whole document."""
    asked: list[list[int]] = []

    def one_batch(path, pages):
        asked.append(pages)
        return {"source": "pdf", "pages": [{"page": p, "width": 612, "height": 792, "blocks": []}
                                           for p in pages]}

    monkeypatch.setattr(apple_arm, "_read_once", one_batch)
    data = apple_arm.read(tmp_path / "scan.pdf", pages=list(range(1, 121)))
    assert [len(batch) for batch in asked] == [apple_arm.BATCH_PAGES, apple_arm.BATCH_PAGES, 20]
    assert [p["page"] for p in data["pages"]] == list(range(1, 121))


def test_an_empty_page_is_recorded_as_blank_and_needs_no_recognizer(tmp_path, monkeypatch):
    monkeypatch.setattr(apple_arm, "BINARY", tmp_path / "no-extract-apple")
    pdf = _write_pdf(tmp_path / "blank.pdf", [[
        ("Only Page With Words", "Helvetica-Bold", 20, 72, 700),
        ("Some ordinary body text sits under the heading on this page.", "Helvetica", 11, 72, 660),
    ], []])
    doc = TextLayerExtractor().extract(pdf, "reference-frozen", **QUIET)
    assert doc.extract_confidence["blank_pages"] == [2]


def test_recognized_list_markers_are_not_doubled():
    """Numbered and lettered markers go too, not just bullets: `to_markdown` adds its own `- `."""
    data = {"source": "image", "pages": [{"page": 1, "width": 800, "height": 600, "blocks": [
        {"kind": "list_item", "text": "1. Numbered item one", "left": 50, "top": 40},
        {"kind": "list_item", "text": "(a) Lettered item two", "left": 50, "top": 70},
        {"kind": "list_item", "text": "• Bulleted item three", "left": 50, "top": 100},
    ]}]}
    assert apple_arm.to_markdown(data) == (
        "- Numbered item one\n\n- Lettered item two\n\n- Bulleted item three\n"
    )


def test_recognized_image_becomes_markdown_with_inferred_headings():
    assert apple_arm.to_markdown(RECOGNIZED) == (
        "# Quarterly Review\n\n## Renewals\n\nRenewals moved faster this quarter.\n\n"
        "Pricing was the most common question.\n\n- Clearer pricing\n\n"
        "| a | b |\n| --- | --- |\n| 1 | 2 |\n"
    )


def test_the_recognizer_missing_from_the_engine_is_unavailable_not_a_failed_read(tmp_path, monkeypatch):
    monkeypatch.setattr(apple_arm, "BINARY", tmp_path / "no-extract-apple")
    with pytest.raises(apple_arm.AppleReaderUnavailable):
        apple_arm.read(tmp_path / "sign.png")


def test_an_image_without_models_is_read_by_the_recognizer(tmp_path, monkeypatch):
    src = tmp_path / "sign.png"
    src.write_bytes(b"")
    monkeypatch.setattr(apple_arm, "read", lambda path, pages=None: RECOGNIZED)
    conv = convert.to_markdown(src, convert.spec_for(src), **QUIET)
    assert (conv.arm, conv.stats["reader"], conv.pages) == ("apple-image", "apple-vision", 1)
    assert conv.markdown.startswith("# Quarterly Review\n\n## Renewals\n\n")


def test_a_missing_models_folder_is_refused_and_never_created(tmp_path):
    missing = tmp_path / "models"
    with pytest.raises(paths.ModelsFolderError, match="is not there"):
        paths.models_folder(missing)
    assert not missing.exists()


def test_a_folder_without_both_model_repositories_is_refused_by_name(tmp_path):
    (tmp_path / paths.LAYOUT_MODELS).mkdir()
    with pytest.raises(paths.ModelsFolderError, match=paths.TABLE_MODELS):
        paths.models_folder(tmp_path)


def test_a_folder_with_both_model_repositories_is_accepted(tmp_path):
    (tmp_path / paths.LAYOUT_MODELS).mkdir()
    (tmp_path / paths.TABLE_MODELS).mkdir()
    assert paths.models_folder(tmp_path) == tmp_path.resolve()


def test_cli_warns_and_reads_without_models_when_the_folder_is_missing(tmp_path, capsys):
    """The folder is a PREFERENCE: an unplugged drive must not refuse the import."""
    missing = tmp_path / "models"
    out = tmp_path / "out"
    argv = ["ingest", str(_report(tmp_path)), "--out", str(out),
            "--doc-class", "reference-frozen", "--docling-models", str(missing)]
    assert cli.main(argv) == 0
    assert not missing.exists()
    assert "WARNING (models)" in capsys.readouterr().err
    run = json.loads((out / "run.json").read_text("utf-8"))
    assert run["extract"]["extractor_arm"] == "pdf-text"


def test_cli_ingests_a_text_pdf_with_no_models_and_records_the_reader(tmp_path):
    out = tmp_path / "out"
    argv = ["ingest", str(_report(tmp_path)), "--out", str(out), "--doc-class", "reference-frozen"]
    assert cli.main(argv) == 0
    run = json.loads((out / "run.json").read_text("utf-8"))
    assert (run["extract"]["extractor_arm"], run["extract"]["layout_model"]) == ("pdf-text", "")
