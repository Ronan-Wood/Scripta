"""`substrate ingest` keeps the original it accepted, and only that.

The store is written after every gate and before `document.md`, so a refused file never enters it
and an accepted note never exists without its original. These fail on a build whose ingest does
not store, which is every build before the blob store.
"""

from __future__ import annotations

import contextlib
import ctypes
import hashlib
import io
from pathlib import Path

import pytest

from substrate import blobs, cli

pdfium = pytest.importorskip("pypdfium2")
import pypdfium2.raw as raw  # noqa: E402

NOTE = "# A note handed to ingest\n\nIt has a heading and a body worth keeping as an original.\n"


def _ingest(*argv: str) -> tuple[int, str, str]:
    out, err = io.StringIO(), io.StringIO()
    with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
        rc = cli.main(["ingest", *argv])
    return rc, out.getvalue(), err.getvalue()


def _pdf(path: Path) -> Path:
    pdf = pdfium.PdfDocument.new()
    page = pdf.new_page(612, 792)
    for text, font, size, y in (("Quarterly Review", "Helvetica-Bold", 24, 700),
                                ("Renewals moved faster this quarter than the last one did.",
                                 "Helvetica", 11, 660)):
        obj = raw.FPDFPageObj_CreateTextObj(pdf.raw, raw.FPDFText_LoadStandardFont(
            pdf.raw, font.encode()), size)
        data = (text + "\0").encode("utf-16-le")
        buffer = ctypes.create_string_buffer(data, len(data))
        assert raw.FPDFText_SetText(obj, ctypes.cast(buffer, raw.FPDF_WIDESTRING))
        raw.FPDFPageObj_Transform(obj, 1, 0, 0, 1, 72, y)
        raw.FPDFPage_InsertObject(page.raw, obj)
    assert raw.FPDFPage_GenerateContent(page.raw)
    pdf.save(str(path))
    pdf.close()
    return path


def _sha(p: Path) -> str:
    return hashlib.sha256(p.read_bytes()).hexdigest()


def test_a_markdown_ingest_stores_its_original(tmp_path):
    src = tmp_path / "note.md"
    src.write_text(NOTE, "utf-8")
    rc, out, err = _ingest(str(src), "--out", str(tmp_path / "out"))
    assert rc == 0, err
    assert blobs.state(_sha(src)) == "stored"
    assert blobs.verified(_sha(src)).read_bytes() == src.read_bytes()
    assert "stored in the blob store" in out


def test_a_pdf_ingest_stores_the_pdf(tmp_path):
    pdf = _pdf(tmp_path / "report.pdf")
    rc, _out, err = _ingest("--pdf", str(pdf), "--doc-class", "reference-frozen",
                            "--out", str(tmp_path / "out"))
    assert rc == 0, err
    assert {c: h.size for c, h in blobs.held().items()} == {_sha(pdf): pdf.stat().st_size}


def test_a_refused_file_never_enters_the_store(tmp_path):
    src = tmp_path / "headings.md"
    src.write_text("# Only\n\n# Headings\n", "utf-8")
    rc, _out, _err = _ingest(str(src), "--out", str(tmp_path / "out"))
    assert rc == 3
    assert blobs.held() == {}


def test_a_note_declaring_another_original_is_not_filed_under_its_own_checksum(tmp_path):
    src = tmp_path / "derived.md"
    src.write_text(f"---\nsource_sha256: {'a' * 64}\n---\n\n{NOTE}", "utf-8")
    rc, out, err = _ingest(str(src), "--out", str(tmp_path / "out"))
    assert rc == 0, err
    assert blobs.held() == {}
    assert "declares its original" in out


def test_a_forgotten_original_stays_forgotten(tmp_path):
    src = tmp_path / "note.md"
    src.write_text(NOTE, "utf-8")
    blobs.forget(_sha(src))
    rc, out, err = _ingest(str(src), "--out", str(tmp_path / "out"))
    assert rc == 0, err
    assert blobs.held() == {} and "stays forgotten" in out


def test_a_store_that_cannot_be_written_fails_the_ingest_and_writes_no_note(
        tmp_path, _private_blob_store):
    src = tmp_path / "note.md"
    src.write_text(NOTE, "utf-8")
    (_private_blob_store / "config.toml").write_text('[blobs]\npath = "relative"\n', "utf-8")
    out = tmp_path / "out"
    rc, _out, err = _ingest(str(src), "--out", str(out))
    assert rc == 2
    assert "FATAL (blob store)" in err
    assert not (out / "document.md").exists()


def test_compose_never_writes_the_store(tmp_path, monkeypatch):
    import shutil

    from substrate import scopes

    monkeypatch.setattr(scopes, "engine_home", lambda: tmp_path)

    vaults = Path(__file__).resolve().parent.parent / "vaults"
    shutil.copytree(vaults / "demo-vault", tmp_path / "demo-vault")
    shutil.copytree(vaults / "demo-core-vault", tmp_path / "demo-core-vault")
    with contextlib.redirect_stdout(io.StringIO()):
        rc = cli.main(["compose", str(tmp_path / "demo-vault"), "--db", str(tmp_path / "d.db"),
                       "--index-root", str(tmp_path / "ir"),
                       "--registry", str(tmp_path / "scopes.toml")])
    assert rc == 0
    assert not blobs.root().exists()


def test_a_converted_document_stores_the_original_not_its_markdown(tmp_path, monkeypatch):
    from substrate.extract import convert

    docx = tmp_path / "report.docx"
    docx.write_bytes(b"PK\x03\x04 not really a docx, but these are the original's bytes")
    monkeypatch.setattr(convert, "to_markdown", lambda src, spec, **kw: convert.Conversion(
        markdown=NOTE, pages=1, extractor="test-converter", arm="test"))
    rc, out, err = _ingest(str(docx), "--out", str(tmp_path / "out"))
    assert rc == 0, err
    assert {c for c in blobs.held()} == {_sha(docx)}
    assert "stored in the blob store" in out
