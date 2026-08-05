"""Any source document → markdown text. The arm that widens ingestion past PDF.

The restriction to PDF was ours, not Docling's: `docling_arm._converter` names
`format_options={InputFormat.PDF: ...}` and Docling refuses everything it was not handed
options for. This module names the rest — and, more importantly, names what it will NOT
accept and why, because a format that imports but cannot convert is worse than one that is
refused: the refusal is a sentence an operator can act on, the empty conversion is a document
that reads as ingested while holding nothing.

**Everything here converts to MARKDOWN and hands off to `markdown.ingest.ingest_markdown`.**
It does not build blocks itself. That is the whole design: `ingest_markdown` is where the class
policy, the spine contract and the A18 coverage gate live, and a second block-builder would be a
second place for those three to be forgotten — the same argument the chunker's PDF/markdown
sharing already carries. A DOCX therefore passes gates the PDF arm does not even run.

## Two gates that are this module's own

A18 measures the markdown against the chunks. It cannot see content that Docling lost on the way
INTO the markdown, because the loss shrinks both sides — the identical blind spot A18 was built to
close one layer down. So:

1. **Non-empty.** A conversion that yields no word at all is refused. This is not hypothetical:
   `blank.png` converts with `status=SUCCESS` and a zero-character body, and every downstream
   gate passes it (coverage over an empty document is 1.0 by construction).
2. **Raw-text coverage.** Where a cheap independent reading of the source exists (the OOXML text
   nodes, the HTML text nodes, the plain bytes of a text-shaped format), the source's word tokens
   must survive into Docling's markdown. Where no such reading exists — an image, an EPUB, a
   LaTeX source — coverage is recorded as `null` with the probe named `unavailable`, NEVER as a
   passing number. Absent evidence is not a clean result; that distinction is `refresh.frozen`'s
   and it is the same one here.

## Doc class

**Absence, for every format this module accepts.** A file extension is evidence about the
CONTAINER, not about the document: `.docx` does not mean "a published edition that will not
change", and defaulting it to one would be the `reference-frozen` incident (classes.py) with a
new trigger. Absence resolves to `unclassified` in `classes.apply`, which is retrieved by default
and drawn as undeclared. `--doc-class` remains available for an operator who knows.

PDF is the ONE exception and it is unchanged rather than chosen: `substrate ingest --pdf` has
always required `--doc-class`, the two reference corpora behind it are exactly where
`reference-versioned`'s version gate earns its keep, and relaxing a live gate is a separate
decision nobody has taken.
"""

from __future__ import annotations

import html as _html
import re
import time
import zipfile
from dataclasses import dataclass, field
from pathlib import Path

from substrate.markdown.reader import _TOKEN, content_coverage

# Word tokens of the source that must survive into the converted markdown, where an independent
# reading of the source exists at all. Deliberately looser than A18's 0.99: the probe and Docling
# are two different readings of the same bytes, so exact parity is not the claim — "the body is
# substantially there" is. A conversion that drops a slide, a sheet or a section falls far below
# this; a rendering difference does not.
RAW_COVERAGE_GATE = 0.95


class UnsupportedFormat(RuntimeError):
    """This engine will not attempt the file. An INPUT problem — nothing was converted."""


class ConversionRefused(RuntimeError):
    """The conversion ran and its result is not trustworthy. A GATE — refuse, do not index."""


@dataclass(frozen=True)
class FormatSpec:
    """One accepted input format: which arm reads it, what it costs, what verifies it."""

    token: str                      # stable name, written to run.json["source_format"]
    extensions: tuple[str, ...]
    arm: str                        # "pdf" | "markdown" | "text" | "docling"
    docling_format: str | None      # InputFormat value; None for the two native arms
    needs_models: bool              # requires the pinned artifacts (paths.configure)
    probe: str | None               # raw-text probe id, or None when none exists
    note: str

    @property
    def doc_class_default(self) -> str:
        return "declared (--doc-class required)" if self.arm == "pdf" else "absence → unclassified"


PDF = FormatSpec(
    "pdf", (".pdf",), "pdf", "pdf", True, None,
    "The original arm. Batched page conversion, furniture adjudication, inferred heading levels.",
)
MARKDOWN = FormatSpec(
    "markdown", (".md", ".markdown"), "markdown", None, False, None,
    "The vault format. Read by the stdlib reader, not Docling — frontmatter, spine and doc_id "
    "round-trip, and a project vault ingests with nothing installed.",
)
TEXT = FormatSpec(
    "text", (".txt", ".text"), "text", None, False, "text",
    "Read by the markdown reader, which is a superset: every line routes into a block. A `#` or "
    "`-` line is read as structure it may not have meant — content is preserved (A18), hierarchy "
    "may be over-read.",
)

_CONVERTED = (
    FormatSpec("docx", (".docx", ".docm", ".dotx", ".dotm"), "docling", "docx", False, "ooxml-w",
               "Word (Office Open XML)."),
    FormatSpec("pptx", (".pptx", ".pptm", ".potx", ".ppsx", ".potm", ".ppsm"), "docling", "pptx",
               False, "ooxml-p", "PowerPoint; one page per slide."),
    FormatSpec("xlsx", (".xlsx", ".xlsm"), "docling", "xlsx", False, "ooxml-x",
               "Excel; each sheet renders as a markdown table."),
    FormatSpec("html", (".html", ".htm", ".xhtml"), "docling", "html", False, "html",
               "HTML; scripts and styles are not content and are excluded from the probe too."),
    FormatSpec("csv", (".csv",), "docling", "csv", False, "text",
               "Renders as one markdown table."),
    FormatSpec("vtt", (".vtt",), "docling", "vtt", False, "vtt",
               "WebVTT captions — cue text only; timings are not content."),
    FormatSpec("asciidoc", (".adoc", ".asciidoc", ".asc"), "docling", "asciidoc", False, None,
               "AsciiDoc. No probe: its markup and its content share a token space."),
    FormatSpec("latex", (".tex", ".latex"), "docling", "latex", False, None,
               "LaTeX source. No probe, for the same reason as AsciiDoc — `\\section` is markup, "
               "and a probe that counted it would report loss on a faithful conversion."),
    FormatSpec("email", (".eml",), "docling", "email", False, None,
               "RFC-822 message. No probe: Docling rewrites the headers it keeps (dates are "
               "normalised) and drops the ones it does not."),
    FormatSpec("epub", (".epub",), "docling", "epub", False, None,
               "EPUB. No probe: chapter selection is the backend's decision, so a whole-archive "
               "reading would report loss on a correct conversion."),
    FormatSpec("image", (".png", ".jpg", ".jpeg", ".tif", ".tiff", ".bmp", ".webp"), "docling",
               "image", True, None,
               "OCR (RapidOCR, CPU). The pixels are the only reading there is, so there is no "
               "independent probe — the non-empty gate is the whole guarantee."),
)

ACCEPTED: tuple[FormatSpec, ...] = (PDF, MARKDOWN, TEXT) + _CONVERTED

# Formats Docling NAMES but this venv cannot honour, each with the specific missing piece. Listed
# rather than left to fall through as "unknown", because "we cannot read .doc" and "we have never
# heard of .doc" are different facts and only one of them tells the operator what to do next.
REFUSED: dict[str, str] = {
    **dict.fromkeys(
        (".doc", ".dot", ".ppt", ".pot", ".pps", ".xls", ".xlt"),
        "legacy Office binary. Docling converts it by shelling out to LibreOffice, which is not on "
        "PATH here. Re-save as .docx / .pptx / .xlsx and ingest that.",
    ),
    **dict.fromkeys(
        (".odt", ".ott", ".ods", ".ots", ".odp", ".otp"),
        "OpenDocument. Docling's backend imports, then raises at open time — it needs the `odfdo` "
        "package, which is not installed in this venv.",
    ),
    **dict.fromkeys(
        (".wav", ".mp3", ".m4a", ".aac", ".ogg", ".flac"),
        "audio. Docling's ASR pipeline needs a speech-recognition model (whisper / "
        "faster-whisper) and ffmpeg; none of them are installed here.",
    ),
    **dict.fromkeys(
        (".mp4", ".avi", ".mov", ".mkv", ".webm"),
        "video. Same missing ASR stack as audio, plus frame extraction.",
    ),
    **dict.fromkeys(
        (".xml", ".nxml"),
        "ambiguous: Docling maps .xml to three unrelated backends (JATS, XBRL, USPTO patents) and "
        "picks between them by sniffing content. None is verified in this engine, so a wrong pick "
        "would produce a plausible document from the wrong reader.",
    ),
    ".json": "Docling's .json is its OWN serialization of an already-converted document, not a "
             "general JSON reader. An arbitrary .json is not a document.",
    ".tar.gz": "METS/Google-Books archive. Not verified in this engine.",
    ".dclx": "Docling archive format. Not verified in this engine.",
    ".boxnote": "Box Notes. Not verified in this engine.",
}

_BY_EXT: dict[str, FormatSpec] = {e: s for s in ACCEPTED for e in s.extensions}


def spec_for(path: Path) -> FormatSpec:
    """The format this engine will read `path` as, from its extension. Raises UnsupportedFormat.

    Extension, not content sniffing, and the reason is that the refusal has to be legible: Docling
    guesses format from magic bytes and falls back to an extension map, which is right for a
    library and wrong for a gate — "we will not read .doc without LibreOffice" is a sentence, and
    "the backend could not parse the input" is not. Docling still sniffs afterwards, and the
    converter is built with `allowed_formats` restricted to the ONE format decided here, so a file
    whose bytes disagree with its extension is refused rather than silently read as something else.
    """
    name = path.name.lower()
    if name.endswith(".tar.gz"):
        raise UnsupportedFormat(f"{path.name}: {REFUSED['.tar.gz']}")
    ext = path.suffix.lower()
    spec = _BY_EXT.get(ext)
    if spec is not None:
        return spec
    if ext in REFUSED:
        raise UnsupportedFormat(f"{path.name}: {REFUSED[ext]}")
    raise UnsupportedFormat(
        f"{path.name}: unknown extension {ext or '(none)'}. Accepted: "
        f"{' '.join(sorted(_BY_EXT))}. Use --md to read it as markdown anyway."
    )


@dataclass
class Conversion:
    """Docling's markdown for one source document, plus the evidence that it is trustworthy."""

    markdown: str
    pages: int | None
    extractor: str
    stats: dict = field(default_factory=dict)


# ---------------------------------------------------------------------------
# Raw-text probes — an independent reading of the source, used only to measure.
#
# Independent of DOCLING, which is the axis that matters: the failure being hunted is Docling
# dropping a slide, a sheet or a section, and a reading that does not go through Docling sees that.
# The OOXML probes take the text NODES only (`w:t`, `a:t`, shared strings) rather than stripping
# all tags, because a field instruction (`HYPERLINK "…"`) and a tracked deletion (`w:delText`) are
# markup that Docling correctly omits — counting them would report loss on a faithful conversion.
# ---------------------------------------------------------------------------

_XML_TEXT = {"ooxml-w": r"<w:t\b[^>]*>(.*?)</w:t>", "ooxml-p": r"<a:t\b[^>]*>(.*?)</a:t>"}
# `head` joins script/style, and it is not a nicety: `<head><title>X</title>` repeats the page's
# own H1 in a region Docling correctly treats as metadata rather than body. Counting it made the
# probe demand the title TWICE in the markdown, and a correct conversion of a four-line page was
# refused at 0.9231 with `Missing: ['Boundary', 'Principle']` — a false refusal caused entirely by
# the measuring instrument. The multiset diff is what exposed it; a presence test would have hidden
# it until a page whose head held content the body did not.
_SCRIPT = re.compile(r"<(script|style|head)\b.*?</\1\s*>", re.I | re.S)
_TAG = re.compile(r"<[^>]*>")
_VTT_SKIP = re.compile(r"^(WEBVTT|NOTE\b|STYLE$|REGION$|\d+$|.*-->.*)")


def _zip_text(src: Path, members: str, pattern: str) -> str:
    rx = re.compile(pattern, re.S)
    out: list[str] = []
    member_rx = re.compile(members)
    with zipfile.ZipFile(src) as z:
        for name in sorted(z.namelist()):
            if not member_rx.fullmatch(name):
                continue
            xml = z.read(name).decode("utf-8", errors="replace")
            out.extend(_html.unescape(m) for m in rx.findall(xml))
    return "\n".join(out)


def _xlsx_text(src: Path) -> str:
    """Cell VALUES via openpyxl — the one probe that shares a library with Docling's backend.

    Stated rather than hidden: this cannot catch openpyxl misreading the workbook. It catches what
    it is here for — Docling reading the workbook and then not RENDERING a sheet or a row into the
    markdown, which is the loss an operator would never see.
    """
    import openpyxl

    wb = openpyxl.load_workbook(src, read_only=True, data_only=True)
    try:
        return "\n".join(
            " ".join("" if v is None else str(v) for v in row)
            for ws in wb.worksheets
            for row in ws.iter_rows(values_only=True)
        )
    finally:
        wb.close()


def _vtt_text(src: Path) -> str:
    return "\n".join(
        ln for ln in src.read_text("utf-8", errors="replace").splitlines()
        if ln.strip() and not _VTT_SKIP.match(ln.strip())
    )


def raw_text(src: Path, spec: FormatSpec) -> str | None:
    """An independent reading of the source, or None when no cheap faithful one exists.

    None is a real answer and is carried as one — `raw_coverage: null`, probe `unavailable`. It
    must never be rendered as 1.0: a format nobody measured and a format measured clean are
    different states, and collapsing them is how a green gate comes to mean nothing.
    """
    try:
        if spec.probe in _XML_TEXT:
            members = r"word/document\d*\.xml" if spec.probe == "ooxml-w" else r"ppt/slides/slide\d+\.xml"
            return _zip_text(src, members, _XML_TEXT[spec.probe])
        if spec.probe == "ooxml-x":
            return _xlsx_text(src)
        if spec.probe == "html":
            raw = src.read_text("utf-8", errors="replace")
            return _html.unescape(_TAG.sub(" ", _SCRIPT.sub(" ", raw)))
        if spec.probe == "vtt":
            return _vtt_text(src)
        if spec.probe == "text":
            return src.read_text("utf-8", errors="replace")
    except Exception:
        # A probe that cannot read the file measures nothing; it does not get to REFUSE the file.
        # The conversion's own success or failure is the verdict, and an unmeasured conversion is
        # recorded as unmeasured.
        return None
    return None


def verify_conversion(src: Path, spec: FormatSpec, md: str) -> tuple[float | None, list[str]]:
    """The two gates this module owns, over an already-converted body. Raises ConversionRefused.

    Returns `(raw_coverage, missing_tokens)`; coverage is None when nothing could measure it.

    Split out of `to_markdown` so it is reachable WITHOUT Docling. These two decisions are the
    reason this module exists, and a gate exercised only through a five-second torch import and a
    seven-second OCR pass is a gate that gets tested once and then never again.
    """
    if not _TOKEN.findall(md):
        raise ConversionRefused(
            f"{spec.token}: {src.name} converted to {len(md)} characters with no word in them. "
            "Docling reported success, so nothing downstream would have refused this — an empty "
            "document passes every coverage gate by construction. Refusing here instead."
            + (" An image with no legible text is the usual cause." if spec.token == "image" else "")
        )

    probe_text = raw_text(src, spec)
    if probe_text is None or not _TOKEN.findall(probe_text):
        return None, []

    cov, missing = content_coverage(probe_text, [md])
    if cov < RAW_COVERAGE_GATE:
        raise ConversionRefused(
            f"{spec.token}: {src.name} lost content in conversion — {cov} of the source's "
            f"word tokens survive into the markdown (gate {RAW_COVERAGE_GATE}), measured "
            f"against the {spec.probe} probe. Missing: {missing}"
        )
    return cov, missing


def to_markdown(src: Path, spec: FormatSpec, *, log=print) -> Conversion:
    """Convert one non-PDF, non-markdown source to markdown. Raises ConversionRefused.

    Every refusal names the format, the file and the specific reason. Nothing partial is returned:
    the caller either gets markdown that cleared both gates, or an exception.
    """
    if spec.arm != "docling":
        raise ValueError(f"{spec.token} is read by the {spec.arm} arm, not converted")

    from substrate.paths import ARTIFACTS, configure

    # Only the model-backed formats require the pinned artifacts. A .docx needs no weights, so
    # demanding the drive be mounted to read one would be a cost with no cause — and `configure`
    # exits the process rather than raising.
    if spec.needs_models:
        configure()

    from docling.datamodel.base_models import ConversionStatus, InputFormat
    from docling.document_converter import DocumentConverter

    fmt = InputFormat(spec.docling_format)
    options: dict = {}
    if spec.needs_models:
        from docling.datamodel.pipeline_options import PdfPipelineOptions
        from docling.document_converter import ImageFormatOption

        opts = PdfPipelineOptions(artifacts_path=str(ARTIFACTS))
        opts.do_ocr = True  # an image has no text layer to prefer; OCR is the only reading
        opts.do_table_structure = True
        options = {InputFormat.IMAGE: ImageFormatOption(pipeline_options=opts)}

    t0 = time.monotonic()
    log(f"converting: {src.name}  format={spec.token}"
        + ("  (OCR — first run loads models)" if spec.needs_models else ""))
    conv = DocumentConverter(allowed_formats=[fmt], format_options=options)
    try:
        result = conv.convert(str(src))
    except Exception as e:  # noqa: BLE001 — every docling failure mode becomes one refusal
        raise ConversionRefused(
            f"{spec.token}: docling could not convert {src.name} — {e}"
        ) from e

    # PARTIAL_SUCCESS is refused with the failures. It is precisely "some of the document is
    # missing and the rest looks fine", which is the state this engine exists to not produce.
    if result.status is not ConversionStatus.SUCCESS:
        raise ConversionRefused(
            f"{spec.token}: docling returned {result.status} for {src.name} — refusing a "
            f"conversion that is not whole. Errors: {getattr(result, 'errors', None)}"
        )

    md = result.document.export_to_markdown()
    elapsed = round(time.monotonic() - t0, 1)
    cov, missing = verify_conversion(src, spec, md)

    pages = None
    try:
        n = result.document.num_pages()
        pages = n if n and n > 0 else None
    except Exception:  # noqa: BLE001 — a page count is provenance, never a gate
        pages = None

    from importlib.metadata import version as pkg_version

    return Conversion(
        markdown=md,
        pages=pages,
        extractor=f"docling {pkg_version('docling')}",
        stats={
            "converted_chars": len(md),
            "converted_seconds": elapsed,
            "docling_status": str(result.status),
            "ocr": spec.needs_models,
            # `null` when nothing could measure it. See raw_text: absent evidence, not a pass.
            "raw_coverage": cov,
            "raw_coverage_probe": spec.probe or "unavailable",
            "raw_coverage_missing": missing,
        },
    )


def table() -> list[tuple[str, str, str, str]]:
    """(format, extensions, doc-class default, note) for every accepted format, then the refusals."""
    rows = [(s.token, " ".join(s.extensions), s.doc_class_default, s.note) for s in ACCEPTED]
    seen: dict[str, list[str]] = {}
    for ext, why in REFUSED.items():
        seen.setdefault(why, []).append(ext)
    rows += [("REFUSED", " ".join(exts), "—", why) for why, exts in seen.items()]
    return rows
