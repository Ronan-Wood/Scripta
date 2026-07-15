import AppKit

/// Exports a transcript to PDF or plain text, and pulls its summary — for the reader's actions.
enum TranscriptExporter {

    // MARK: - Summary

    /// The "## Summary" section text, or "" if the transcript has none.
    static func summary(of url: URL) -> String {
        guard let content = try? String(contentsOf: url, encoding: .utf8),
              let start = content.range(of: "## Summary") else { return "" }
        var section = String(content[start.upperBound...])
        var cut = section.endIndex
        for marker in ["\n**[", "\n## ", "\n# "] {
            if let r = section.range(of: marker), r.lowerBound < cut { cut = r.lowerBound }
        }
        section = String(section[..<cut])
        return section.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Plain text

    /// The transcript body without YAML frontmatter, as plain text.
    static func plainText(of url: URL) -> String {
        let content = (try? String(contentsOf: url, encoding: .utf8)) ?? ""
        guard let split = Frontmatter.split(content) else { return content }
        return split.body.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    // MARK: - Attributed rendering (for PDF)

    private static func attributed(_ meta: TranscriptMeta) -> NSAttributedString {
        let result = NSMutableAttributedString()
        func append(_ text: String, size: CGFloat, weight: NSFont.Weight = .regular,
                    color: NSColor = .textColor, mono: Bool = false, spacingAfter: CGFloat = 6) {
            let style = NSMutableParagraphStyle(); style.paragraphSpacing = spacingAfter; style.lineSpacing = 2
            let font = mono ? NSFont.monospacedSystemFont(ofSize: size, weight: weight)
                            : NSFont.systemFont(ofSize: size, weight: weight)
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: font, .foregroundColor: color, .paragraphStyle: style
            ]))
        }

        append(meta.displayTitle, size: 22, weight: .bold, spacingAfter: 2)
        let sub = [meta.date, meta.time, meta.duration].filter { !$0.isEmpty }.joined(separator: " · ")
        if !sub.isEmpty { append(sub, size: 11, color: .secondaryLabelColor, spacingAfter: 4) }
        if !meta.participants.isEmpty { append(meta.participants.joined(separator: ", "), size: 11, color: .secondaryLabelColor) }

        for block in TranscriptParser.parse(TranscriptStore.body(of: meta.url)) {
            switch block {
            case .section(let title): append(title, size: 15, weight: .semibold, spacingAfter: 4)
            case .audioLine(let stamp, let speaker, let text):
                let prefix = speaker.map { "\(stamp) \($0): " } ?? "\(stamp) "
                let line = NSMutableAttributedString(string: prefix, attributes: [
                    .font: NSFont.monospacedDigitSystemFont(ofSize: 11, weight: .medium),
                    .foregroundColor: NSColor.secondaryLabelColor])
                line.append(NSAttributedString(string: text + "\n", attributes: [
                    .font: NSFont.systemFont(ofSize: 12), .foregroundColor: NSColor.textColor]))
                result.append(line)
            case .paragraph(let text): append(text, size: 12)
            case .table(let rows): append(rows.joined(separator: "\n"), size: 10, mono: true)
            case .screenMarker(let stamp): append(stamp, size: 10, color: .tertiaryLabelColor)
            case .divider: append("", size: 6)
            }
        }
        return result
    }

    // MARK: - Writers

    static func exportText(_ meta: TranscriptMeta, to url: URL) throws {
        let header = "\(meta.displayTitle)\n\n"
        try (header + plainText(of: meta.url)).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Renders the transcript to a paginated PDF (US Letter) with no print panel.
    static func exportPDF(_ meta: TranscriptMeta, to url: URL) throws {
        let attr = attributed(meta)
        let margin: CGFloat = 54
        let pageWidth: CGFloat = 612, pageHeight: CGFloat = 792
        let contentWidth = pageWidth - margin * 2

        let container = NSTextContainer(size: NSSize(width: contentWidth, height: .greatestFiniteMagnitude))
        container.widthTracksTextView = false
        let layout = NSLayoutManager(); layout.addTextContainer(container)
        let storage = NSTextStorage(attributedString: attr); storage.addLayoutManager(layout)
        layout.ensureLayout(for: container)
        let height = ceil(layout.usedRect(for: container).height) + 4

        let textView = NSTextView(frame: NSRect(x: 0, y: 0, width: contentWidth, height: max(height, 10)))
        textView.textStorage?.setAttributedString(attr)
        textView.isVerticallyResizable = true

        let info = NSPrintInfo()
        info.paperSize = NSSize(width: pageWidth, height: pageHeight)
        info.leftMargin = margin; info.rightMargin = margin; info.topMargin = margin; info.bottomMargin = margin
        info.jobDisposition = .save
        info.dictionary()[NSPrintInfo.AttributeKey.jobSavingURL] = url

        let op = NSPrintOperation(view: textView, printInfo: info)
        op.showsPrintPanel = false
        op.showsProgressPanel = false
        guard op.run() else {
            throw NSError(domain: "CallTranscriber", code: 400,
                          userInfo: [NSLocalizedDescriptionKey: "The PDF could not be written to \(url.lastPathComponent)."])
        }
    }

    // MARK: - Save panel helper

    static func savePanel(suggestedName: String, ext: String, completion: @escaping (URL) -> Void) {
        let panel = NSSavePanel()
        panel.nameFieldStringValue = "\(suggestedName).\(ext)"
        panel.canCreateDirectories = true
        if panel.runModal() == .OK, let url = panel.url { completion(url) }
    }
}
