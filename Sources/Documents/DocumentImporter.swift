import Foundation
import PDFKit
import ImageIO

/// Imports documents (PDF, PowerPoint, Word, images/screenshots, plain text) into the knowledge
/// base: the original is copied into `Files/` inside the vault, its text is extracted fully
/// on-device, and a companion Markdown lands beside it — indexed as `kind: 'doc'`, so search,
/// Clovis, and the MCP retrieve it while every call surface ignores it. Extraction reuses the
/// app's own machinery: PDFKit text layers, the Screen Context OCR (`DocumentReader`) for images
/// and scanned PDFs, and MiniZip + XMLParser for OOXML.
enum DocumentImporter {
    static let marker = "call-transcriber-doc"

    static var folder: URL {
        AppSettings.outputFolder.appendingPathComponent("Files", isDirectory: true)
    }

    struct Imported {
        let mdURL: URL
        let title: String
        let fileName: String   // the copied original's name inside Files/
    }

    enum ImportError: LocalizedError {
        case unsupportedType(String)
        case emptyExtraction

        var errorDescription: String? {
            switch self {
            case .unsupportedType(let ext):
                return "“.\(ext)” isn't supported yet. PDF, PowerPoint, Word, images, and plain text are. (For Keynote/Pages, export a PDF.)"
            case .emptyExtraction:
                return "No readable text was found in that file."
            }
        }
    }

    static let supportedExtensions: Set<String> = [
        "pdf", "pptx", "docx", "txt", "md", "png", "jpg", "jpeg", "heic", "tiff", "webp",
    ]

    /// Copies the file in, extracts its text, writes the companion doc note. Runs extraction
    /// off the caller's thread (OCR can take seconds for image-heavy input).
    static func importFile(_ source: URL, group: String, linkedCall: URL? = nil) async throws -> Imported {
        let ext = source.pathExtension.lowercased()
        guard supportedExtensions.contains(ext) else { throw ImportError.unsupportedType(ext) }

        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        // A dropped or panel-selected file is security-scoped under the sandbox: open access
        // before reading, or the copy fails silently. Harmless (returns false) for files we
        // already own, e.g. an in-vault path.
        let scoped = source.startAccessingSecurityScopedResource()
        defer { if scoped { source.stopAccessingSecurityScopedResource() } }

        // If the file already lives inside our Files/ folder, index it in place — no redundant copy.
        let copied: URL
        if source.standardizedFileURL.deletingLastPathComponent().path == folder.standardizedFileURL.path {
            copied = source
        } else {
            copied = uniqueURL(for: source.lastPathComponent)
            try FileManager.default.copyItem(at: source, to: copied)
        }

        let text = try await extractText(copied)
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            try? FileManager.default.removeItem(at: copied)
            throw ImportError.emptyExtraction
        }

        let title = source.deletingPathExtension().lastPathComponent
        let stamp = now()
        var frontmatter = """
        ---
        app: \(marker)
        type: document
        title: "\(sanitize(title))"
        file: "\(sanitize(copied.lastPathComponent))"
        group: "\(sanitize(group))"
        created: \(stamp)
        """
        if let linkedCall {
            frontmatter += "\ncall: \"[[\(sanitize(linkedCall.deletingPathExtension().lastPathComponent))]]\""
        }
        frontmatter += "\n---\n\n# \(title)\n\n\(trimmed)\n"

        let mdURL = uniqueURL(for: "\(title) — extracted.md")
        try frontmatter.write(to: mdURL, atomically: true, encoding: .utf8)
        return Imported(mdURL: mdURL, title: title, fileName: copied.lastPathComponent)
    }

    /// Deletes an imported document: the copied original in Files/ AND its companion note. The
    /// user's own original (wherever they imported it from) is never touched — we only copied it.
    /// The index row is cleared by the caller.
    static func delete(mdURL: URL) {
        if let meta = parse(mdURL), !meta.file.isEmpty {
            try? FileManager.default.removeItem(at: folder.appendingPathComponent(meta.file))
        }
        try? FileManager.default.removeItem(at: mdURL)
    }

    /// Renames a document (its display title in the companion note). The copied file keeps its name.
    static func rename(mdURL: URL, to newTitle: String) {
        NoteStore.retitle(fileAt: mdURL, to: newTitle)
    }

    /// Doc notes in one workspace, newest first — for the Documents shelf.
    static func list(group: String) -> [(mdURL: URL, title: String, created: String, file: String)] {
        guard let entries = try? FileManager.default.contentsOfDirectory(
            at: folder, includingPropertiesForKeys: nil, options: [.skipsHiddenFiles]
        ) else { return [] }
        return entries
            .filter { $0.pathExtension == "md" }
            .compactMap { url in
                guard let parsed = parse(url), parsed.group == group else { return nil }
                return (url, parsed.title, parsed.created, parsed.file)
            }
            .sorted { $0.created > $1.created }
    }

    struct DocMeta {
        let title: String
        let group: String
        let created: String
        let file: String
        let body: String
    }

    /// Parses a companion doc note; nil unless it carries our marker.
    static func parse(_ url: URL) -> DocMeta? {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let split = Frontmatter.split(content) else { return nil }
        let lines = split.frontmatter.components(separatedBy: "\n")
        func field(_ key: String) -> String {
            for line in lines {
                let t = line.trimmingCharacters(in: .whitespaces)
                if t.hasPrefix("\(key):") {
                    return String(t.dropFirst(key.count + 1))
                        .trimmingCharacters(in: CharacterSet(charactersIn: " \"'"))
                }
            }
            return ""
        }
        guard field("app") == marker else { return nil }
        return DocMeta(title: field("title"), group: field("group"),
                       created: field("created"), file: field("file"), body: split.body)
    }

    // MARK: - Extraction (all on-device)

    static func extractText(_ url: URL) async throws -> String {
        switch url.pathExtension.lowercased() {
        case "pdf": return try await pdfText(url)
        case "pptx": return try pptxText(url)
        case "docx": return try docxText(url)
        case "txt", "md": return (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        default: return await imageText(url) ?? ""
        }
    }

    /// PDF: the text layer via PDFKit; pages with (near-)empty layers fall back to a render +
    /// the Screen Context document recognizer — which also rescues fully scanned PDFs.
    private static func pdfText(_ url: URL) async throws -> String {
        guard let doc = PDFDocument(url: url) else { throw ImportError.emptyExtraction }
        var pages: [String] = []
        for i in 0..<min(doc.pageCount, 200) {
            guard let page = doc.page(at: i) else { continue }
            let layer = page.string?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            if layer.count >= 40 {
                pages.append(layer)
                continue
            }
            // Thin/no text layer → OCR the render.
            let image = page.thumbnail(of: CGSize(width: 1600, height: 2070), for: .mediaBox)
            if let cg = image.cgImage(forProposedRect: nil, context: nil, hints: nil),
               let ocr = await DocumentReader.read(cg, focus: .everything),
               !ocr.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                pages.append(ocr)
            } else if !layer.isEmpty {
                pages.append(layer)
            }
        }
        return pages.enumerated()
            .map { "## Page \($0.offset + 1)\n\n\($0.element)" }
            .joined(separator: "\n\n")
    }

    /// PPTX: slides are `ppt/slides/slideN.xml`; visible text lives in `<a:t>` runs.
    private static func pptxText(_ url: URL) throws -> String {
        let slides = try MiniZip.entries(of: url)
            .filter { $0.hasPrefix("ppt/slides/slide") && $0.hasSuffix(".xml") }
            .sorted { slideNumber($0) < slideNumber($1) }
        var out: [String] = []
        for (i, name) in slides.enumerated() {
            let xml = try MiniZip.read(name, from: url)
            let runs = textRuns(in: xml, elements: ["a:t"])
            if !runs.isEmpty {
                out.append("## Slide \(i + 1)\n\n\(runs.joined(separator: "\n"))")
            }
        }
        return out.joined(separator: "\n\n")
    }

    private static func slideNumber(_ name: String) -> Int {
        Int(name.dropFirst("ppt/slides/slide".count).dropLast(".xml".count)) ?? 0
    }

    /// DOCX: `word/document.xml`; text in `<w:t>` runs, paragraphs on `</w:p>`.
    private static func docxText(_ url: URL) throws -> String {
        let xml = try MiniZip.read("word/document.xml", from: url)
        return textRuns(in: xml, elements: ["w:t"], paragraphElement: "w:p")
            .joined(separator: "\n")
    }

    /// Screenshots and other images: straight through the Screen Context recognizer.
    private static func imageText(_ url: URL) async -> String? {
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return nil }
        return await DocumentReader.read(image, focus: .everything)
    }

    /// Collects the character data of the given elements; when `paragraphElement` is set, each
    /// closing paragraph flushes a line (DOCX); otherwise each run is its own line (PPTX).
    private static func textRuns(in xml: Data, elements: Set<String>,
                                 paragraphElement: String? = nil) -> [String] {
        final class Collector: NSObject, XMLParserDelegate {
            let elements: Set<String>
            let paragraphElement: String?
            var lines: [String] = []
            var current = ""
            var inRun = false

            init(elements: Set<String>, paragraphElement: String?) {
                self.elements = elements
                self.paragraphElement = paragraphElement
            }

            func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?,
                        qualifiedName qName: String?, attributes: [String: String] = [:]) {
                if elements.contains(name) { inRun = true }
            }
            func parser(_ parser: XMLParser, foundCharacters string: String) {
                if inRun { current += string }
            }
            func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?,
                        qualifiedName qName: String?) {
                if elements.contains(name) {
                    inRun = false
                    if paragraphElement == nil {
                        flush()
                    }
                } else if name == paragraphElement {
                    flush()
                }
            }
            private func flush() {
                let line = current.trimmingCharacters(in: .whitespacesAndNewlines)
                if !line.isEmpty { lines.append(line) }
                current = ""
            }
        }
        let collector = Collector(elements: elements, paragraphElement: paragraphElement)
        let parser = XMLParser(data: xml)
        parser.delegate = collector
        parser.parse()
        return collector.lines
    }

    // MARK: - Helpers

    private static func now() -> String {
        let fmt = DateFormatter()
        fmt.locale = Locale(identifier: "en_US_POSIX")
        fmt.dateFormat = "yyyy-MM-dd HH:mm"
        return fmt.string(from: Date())
    }

    private static func sanitize(_ value: String) -> String {
        value.replacingOccurrences(of: "\"", with: "'")
            .replacingOccurrences(of: "---", with: "—")
            .replacingOccurrences(of: "\n", with: " ")
    }

    private static func uniqueURL(for name: String) -> URL {
        var candidate = folder.appendingPathComponent(name)
        let base = candidate.deletingPathExtension().lastPathComponent
        let ext = candidate.pathExtension
        var n = 2
        while FileManager.default.fileExists(atPath: candidate.path) {
            candidate = folder.appendingPathComponent(ext.isEmpty ? "\(base) \(n)" : "\(base) \(n).\(ext)")
            n += 1
        }
        return candidate
    }
}
