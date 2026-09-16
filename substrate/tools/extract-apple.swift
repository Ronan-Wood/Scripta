// extract-apple — document structure from Apple's on-device document recognizer.
//
// The engine's reader for PDFs and images when no docling models folder is configured. Vision's
// RecognizeDocumentsRequest (macOS 26) finds titles, paragraphs, lists and tables on-device, with no
// model weights to ship or download. docling stays the higher-fidelity reader, used when the
// operator points Settings at its models.
//
// Protocol, one document per run:
//   extract-apple [--pages 2,5,9] <pdf or image>
//   --pages reads only those pages of a PDF, numbered from 1: the engine reads a PDF's own text
//   layer first and sends only the pages without one here.
//   stdout: one JSON object, then exit 0
//   stderr and a non-zero exit: the reason nothing was read
//
// GEOMETRY IS IN PDF POINTS for a PDF and pixels for an image, with the origin at the TOP-LEFT, so a
// line height here means what docling's glyph height means and heading inference works on either.
//
//   {"source": "pdf", "pages": [{"page": 1, "width": 612, "height": 792, "blocks": [
//      {"kind": "title" | "text" | "list_item" | "table", "text": "...",
//       "left": 72.0, "top": 90.5, "line_height": 12.1}]}]}

import AppKit
import Foundation
import ImageIO
import PDFKit
import Vision

struct OutBlock: Encodable {
    let kind: String
    let text: String
    let left: Double
    let top: Double
    let lineHeight: Double?
    enum CodingKeys: String, CodingKey { case kind, text, left, top, lineHeight = "line_height" }
}

struct OutPage: Encodable {
    let page: Int
    let width: Double
    let height: Double
    let blocks: [OutBlock]
}

struct Output: Encodable {
    let source: String
    let pages: [OutPage]
}

func fail(_ message: String, code: Int32 = 1) -> Never {
    FileHandle.standardError.write(Data(("extract-apple: " + message + "\n").utf8))
    exit(code)
}

func rounded(_ value: CGFloat) -> Double { (Double(value) * 10).rounded() / 10 }

/// Pages are rendered at twice their point size: Vision reads what it can see, and 72 dpi loses
/// small print.
let renderScale: CGFloat = 2

/// No page renders larger than this on its longest side. A PDF page may legally be 14,400 points
/// across, which at twice its size would ask for about 3 GB of bitmap for one page; such a page is
/// rendered at whatever scale fits instead.
let maxPixels: CGFloat = 8000

@available(macOS 26.0, *)
func rect(_ region: NormalizedRegion, in size: CGSize) -> CGRect {
    region.boundingBox.toImageCoordinates(size, origin: .upperLeft)
}

@available(macOS 26.0, *)
func medianLineHeight(_ text: DocumentObservation.Container.Text, in size: CGSize) -> Double? {
    let heights = text.lines.map { rect($0.boundingRegion, in: size).height }.sorted()
    guard !heights.isEmpty else { return nil }
    return rounded(heights[heights.count / 2])
}

func markdownTable(_ rows: [[String]]) -> String {
    guard let header = rows.first, !header.isEmpty else { return "" }
    let width = rows.map(\.count).max() ?? header.count
    func line(_ cells: [String]) -> String {
        let padded = cells + Array(repeating: "", count: max(0, width - cells.count))
        return "| " + padded.map { $0.replacingOccurrences(of: "|", with: "\\|")
            .replacingOccurrences(of: "\n", with: " ") }.joined(separator: " | ") + " |"
    }
    var out = [line(header), "|" + Array(repeating: " --- |", count: width).joined()]
    out += rows.dropFirst().map(line)
    return out.joined(separator: "\n")
}

/// One recognized page, in reading order.
///
/// PARAGRAPHS KEEP VISION'S ORDER, which is its reading order; tables and lists are placed before the
/// first paragraph that starts below them. Vision also reports the text inside a table or list as
/// paragraphs, so any paragraph whose centre falls inside one of those regions is dropped rather than
/// read twice.
@available(macOS 26.0, *)
func recognize(_ image: CGImage, orientation: CGImagePropertyOrientation?, page: Int,
               size: CGSize) async throws -> OutPage {
    let observations = try await RecognizeDocumentsRequest().perform(on: image, orientation: orientation)
    guard let document = observations.first?.document else {
        return OutPage(page: page, width: rounded(size.width), height: rounded(size.height), blocks: [])
    }

    var placed: [(top: CGFloat, block: OutBlock)] = []
    var claimed: [CGRect] = []

    for table in document.tables {
        let r = rect(table.boundingRegion, in: size)
        let rows = table.rows.map { $0.map { $0.content.text.transcript
            .trimmingCharacters(in: .whitespacesAndNewlines) } }
        let md = markdownTable(rows)
        guard !md.isEmpty else { continue }
        claimed.append(r)
        placed.append((r.minY, OutBlock(kind: "table", text: md, left: rounded(r.minX),
                                        top: rounded(r.minY), lineHeight: nil)))
    }
    for list in document.lists {
        claimed.append(rect(list.boundingRegion, in: size))
        for item in list.items {
            let text = item.itemString.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty else { continue }
            let r = rect(item.content.boundingRegion, in: size)
            placed.append((r.minY, OutBlock(kind: "list_item", text: text, left: rounded(r.minX),
                                            top: rounded(r.minY),
                                            lineHeight: medianLineHeight(item.content.text, in: size))))
        }
    }

    var ordered: [OutBlock] = []
    let titleText = document.title?.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
    if let title = document.title, let text = titleText, !text.isEmpty {
        let r = rect(title.boundingRegion, in: size)
        ordered.append(OutBlock(kind: "title", text: text, left: rounded(r.minX), top: rounded(r.minY),
                                lineHeight: medianLineHeight(title, in: size)))
    }
    var pending = placed.sorted { $0.top < $1.top }
    for paragraph in document.paragraphs {
        let text = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty, text != titleText else { continue }
        let r = rect(paragraph.boundingRegion, in: size)
        if claimed.contains(where: { $0.insetBy(dx: -2, dy: -2).contains(CGPoint(x: r.midX, y: r.midY)) }) {
            continue
        }
        while let next = pending.first, next.top <= r.minY {
            ordered.append(next.block)
            pending.removeFirst()
        }
        ordered.append(OutBlock(kind: "text", text: text, left: rounded(r.minX), top: rounded(r.minY),
                                lineHeight: medianLineHeight(paragraph, in: size)))
    }
    ordered += pending.map(\.block)
    return OutPage(page: page, width: rounded(size.width), height: rounded(size.height), blocks: ordered)
}

@available(macOS 26.0, *)
func renderPage(_ page: PDFPage) -> (CGImage, CGSize)? {
    let box = page.bounds(for: .mediaBox)
    let quarterTurns = ((page.rotation % 360) + 360) % 360 / 90
    let size = quarterTurns % 2 == 1 ? CGSize(width: box.height, height: box.width) : box.size
    // CHECKED BEFORE CONVERTING: `Int(_:)` traps on a value that is not finite or does not fit, so a
    // malformed page box would crash the reader with no page named and no reason given.
    guard size.width.isFinite, size.height.isFinite, size.width > 0, size.height > 0 else {
        return nil
    }
    let scale = min(renderScale, maxPixels / max(size.width, size.height))
    guard scale > 0 else { return nil }
    let pixelWidth = Int((size.width * scale).rounded())
    let pixelHeight = Int((size.height * scale).rounded())
    guard pixelWidth > 0, pixelHeight > 0,
          let context = CGContext(data: nil, width: pixelWidth, height: pixelHeight, bitsPerComponent: 8,
                                  bytesPerRow: 0, space: CGColorSpaceCreateDeviceRGB(),
                                  bitmapInfo: CGImageAlphaInfo.noneSkipLast.rawValue)
    else { return nil }
    context.setFillColor(CGColor(gray: 1, alpha: 1))
    context.fill(CGRect(x: 0, y: 0, width: pixelWidth, height: pixelHeight))
    context.scaleBy(x: scale, y: scale)
    page.draw(with: .mediaBox, to: context)
    guard let image = context.makeImage() else { return nil }
    return (image, size)
}

@available(macOS 26.0, *)
func extract(_ url: URL, pages wanted: [Int]?) async throws -> Output {
    if url.pathExtension.lowercased() == "pdf" {
        guard let document = PDFDocument(url: url) else { fail("not a readable PDF: \(url.path)") }
        if document.isLocked { fail("the PDF is password-protected: \(url.path)") }
        if let bad = wanted?.first(where: { $0 < 1 || $0 > document.pageCount }) {
            fail("page \(bad) is outside \(url.path), which has \(document.pageCount) pages", code: 2)
        }
        var pages: [OutPage] = []
        for index in wanted?.map({ $0 - 1 }) ?? Array(0..<document.pageCount) {
            guard let page = document.page(at: index), let (image, size) = renderPage(page) else {
                fail("could not render page \(index + 1) of \(url.path)")
            }
            pages.append(try await recognize(image, orientation: nil, page: index + 1, size: size))
        }
        return Output(source: "pdf", pages: pages)
    }

    if wanted != nil { fail("--pages applies only to a PDF", code: 2) }
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
          let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else {
        fail("not a readable image: \(url.path)")
    }
    let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any]
    let orientation = (properties?[kCGImagePropertyOrientation] as? UInt32)
        .flatMap(CGImagePropertyOrientation.init(rawValue:))
    let size = CGSize(width: image.width, height: image.height)
    return Output(source: "image", pages: [try await recognize(image, orientation: orientation, page: 1,
                                                                size: size)])
}

guard #available(macOS 26.0, *) else { fail("requires macOS 26", code: 2) }
var arguments = Array(CommandLine.arguments.dropFirst())
var pages: [Int]?
if arguments.first == "--pages" {
    let numbers = arguments.count > 1 ? arguments[1].split(separator: ",").map { Int($0) } : []
    guard !numbers.isEmpty, numbers.allSatisfy({ $0 != nil }) else {
        fail("--pages takes page numbers separated by commas, like 2,5,9", code: 2)
    }
    pages = Set(numbers.compactMap { $0 }).sorted()
    arguments.removeFirst(2)
}
guard arguments.count == 1 else { fail("usage: extract-apple [--pages 2,5,9] <pdf or image>", code: 2) }
do {
    let output = try await extract(URL(fileURLWithPath: arguments[0]), pages: pages)
    let encoder = JSONEncoder()
    // SORTED KEYS, so the same page gives the same bytes: without it Swift emits keys in a per-process
    // order, and every run of one document hashed differently while its content was identical.
    encoder.outputFormatting = [.withoutEscapingSlashes, .sortedKeys]
    FileHandle.standardOutput.write(try encoder.encode(output))
    FileHandle.standardOutput.write(Data("\n".utf8))
} catch {
    fail("\(error)")
}
