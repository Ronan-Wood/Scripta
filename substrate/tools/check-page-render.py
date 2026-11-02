#!/usr/bin/env python3
"""Does docling's PDF backend draw a real page in THIS interpreter? 0 if so; 1 if the page came back
undrawn; 2 if the check itself broke before a page could be judged.

    <engine>/.venv/bin/python -B -I tools/check-page-render.py

`-I`, not the shims' `-E -s`: it also keeps this script's own directory off `sys.path`, so nothing
sitting in `tools/` can shadow a module imported here. The shims cannot use `-I` because the engine
package is found from the working directory; this script imports only installed packages.

`build-bundled-engine` runs it with the bundled interpreter after signing, because the signature is
what broke the render. docling-parse draws pages with Blend2D, which JIT-compiles its pipelines.
Under the hardened runtime without `com.apple.security.cs.allow-jit` the JIT is refused, and
Blend2D hands back the page buffer uninitialised rather than failing. Nothing raises: the layout
model reads noise and every PDF converts as loose text blocks. 0.3.0-0.3.2 shipped exactly that,
with every import and signing check green.

NO MODELS NEEDED. The page is drawn by the backend alone, before any model sees it, so this runs
on a machine without the operator's docling models folder.

THE MEASURE IS INK, NOT A HASH. The uninitialised buffer is not reliably different from run to run
(measured: identical twice in a row on 7.24.2), so comparing two renders can pass it. Its ink is:
a clean render of the page below inks 0.8% of its pixels, the undrawn one 91-100%.
"""

from __future__ import annotations

import ctypes
import sys
import tempfile
import traceback
from pathlib import Path

# A clean render of `_PAGE` inks 0.8% of its pixels. Above this, the page is not what was drawn.
MAX_INK = 0.25
# Anything this bright counts as paper; the threshold the uninitialised-buffer measurements used.
PAPER = 250

# Title, one sentence and a three-column table: what the bug cost, in standard fonts, so nothing
# has to be embedded or found on disk.
_PAGE = [("Pricing Review", "Helvetica-Bold", 22, 72, 700),
         ("Renewals moved faster this quarter than the last one did.", "Helvetica", 11, 72, 660)] + [
    (cell, "Helvetica-Bold" if i == 0 else "Helvetica", 11, 72 + 120 * j, 620 - 18 * i)
    for i, row in enumerate([("Region", "Q1", "Q2"), ("North", "120", "135"), ("South", "98", "110")])
    for j, cell in enumerate(row)
]


def ink(gray) -> float:
    """Fraction of pixels darker than paper, for an 8-bit grayscale array."""
    return float((gray < PAPER).mean())


def verdict(gray) -> str | None:
    """None if `gray` looks like the page that was drawn, else why it does not."""
    fraction = ink(gray)
    if fraction == 0:
        return "the page rendered blank: no text was drawn"
    if fraction > MAX_INK:
        return (f"{fraction:.0%} of the page is ink where a clean render inks under 1%: the renderer "
                "returned an undrawn buffer. Under the hardened runtime that means the interpreter "
                "lacks com.apple.security.cs.allow-jit (tools/engine-interpreter.entitlements)")
    return None


def _write_pdf(path: Path) -> None:
    import pypdfium2 as pdfium
    import pypdfium2.raw as raw

    pdf = pdfium.PdfDocument.new()
    page = pdf.new_page(612, 792)
    for text, font, size, x, y in _PAGE:
        obj = raw.FPDFPageObj_CreateTextObj(pdf.raw, raw.FPDFText_LoadStandardFont(pdf.raw, font.encode()), size)
        data = (text + "\0").encode("utf-16-le")
        buffer = ctypes.create_string_buffer(data, len(data))
        if not raw.FPDFText_SetText(obj, ctypes.cast(buffer, raw.FPDF_WIDESTRING)):
            raise RuntimeError(f"pdfium could not set the text {text!r}")
        raw.FPDFPageObj_Transform(obj, 1, 0, 0, 1, x, y)
        raw.FPDFPage_InsertObject(page.raw, obj)
    if not raw.FPDFPage_GenerateContent(page.raw):
        raise RuntimeError("pdfium could not generate the page content")
    pdf.save(str(path))
    pdf.close()


def render(pdf: Path):
    """Page 1 of `pdf` as drawn by docling's DEFAULT PDF backend — the one `docling_arm` converts with."""
    import numpy as np
    from docling.datamodel.base_models import InputFormat
    from docling.datamodel.document import InputDocument
    from docling.document_converter import PdfFormatOption

    doc = InputDocument(path_or_stream=pdf, format=InputFormat.PDF, backend=PdfFormatOption().backend)
    # docling catches a load failure and leaves `valid` False rather than raising.
    if not doc.valid or doc._backend is None:
        raise RuntimeError(f"docling could not load the check page {pdf.name}")
    try:
        page = next(iter(doc._backend.iter_pages()))
        try:
            return np.asarray(page.get_page_image(scale=1).convert("L"))
        finally:
            page.unload()
    finally:
        doc._backend.unload()


def main() -> int:
    # Exit 2 is THE CHECK breaking before it could judge a page: a docling API change, a page that
    # would not load — or an import refused by library validation, which IS the signature. So 2 does
    # not clear the signature; it says only that the page was never judged, and the traceback says why.
    try:
        with tempfile.TemporaryDirectory() as tmp:
            pdf = Path(tmp) / "page.pdf"
            _write_pdf(pdf)
            reason = verdict(render(pdf))
    # `verdict` is inside too: an uncaught exception exits 1, which would read as an undrawn page.
    except Exception as e:  # noqa: BLE001 — every way the check itself can break is exit 2
        traceback.print_exc()
        print(f"check-page-render: the check itself failed, before any page was judged: "
              f"{type(e).__name__}: {e}", file=sys.stderr)
        return 2
    if reason:
        print(f"check-page-render: {reason}", file=sys.stderr)
        return 1
    print("  docling renders a clean page under this signature")
    return 0


if __name__ == "__main__":
    sys.exit(main())
