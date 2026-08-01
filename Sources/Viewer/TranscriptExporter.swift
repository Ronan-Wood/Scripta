import AppKit
import ScriptaCore
import ScriptaShared

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

    // MARK: - The print scale
    //
    // `Register`'s roles are SCREEN measures — 15pt prose sets a column on a 27" display, and a
    // column no one would choose on US Letter — so the export names its own sizes and takes only
    // the FACES from the register. Reaching for `Register.Face` rather than a role is the honest
    // spelling of a gap: the type layer has one medium, and this is a second one.
    //
    // Everything else the register decides still holds. A stamp is mono because it is machine-
    // measured; speech is Plex Sans *Text* because it is human language; a speaker's identity is
    // weight for the self party and hue for the others, exactly as on screen. `Typeface` is what
    // carries all of that across — it resolves the `NSFont` (falling back to a MONOSPACED system
    // font for the mono register, so a column survives a missing face) and derives the prose
    // leading from `Metrics.lineHeightProse`.

    private enum PrintFace {
        static let title = Typeface(face: Register.Face.sansSemiBold, size: 20, kind: .ui)
        static let section = Typeface(face: Register.Face.sansSemiBold, size: 13, kind: .ui)
        /// The date · time · duration line: three machine-measured values.
        static let meta = Typeface(face: Register.Face.mono, size: 9, kind: .mono)
        static let names = Typeface(face: Register.Face.sans, size: 9, kind: .ui)
        static let stamp = Typeface(face: Register.Face.mono, size: 9, kind: .mono)
        static let speaker = Typeface(face: Register.Face.sans, size: 10, kind: .ui)
        /// The self party. Weight is the identity signal, matching `Register.uiEmphasis` on screen.
        static let speakerSelf = Typeface(face: Register.Face.sansMedium, size: 10, kind: .ui)
        static let body = Typeface(face: Register.Face.sansText, size: 11, kind: .prose)
        static let table = Typeface(face: Register.Face.mono, size: 9, kind: .mono)
    }

    // MARK: - Attributed rendering (for PDF)

    /// A printed page is a light surface in every appearance, so the export takes the LIGHT half of
    /// each token rather than `Tone.ns`, which resolves against whatever appearance happens to be
    /// current. The system colours this replaces (`.textColor`, `.secondaryLabelColor`) are dynamic
    /// in exactly that way, which is how a PDF exported in dark mode came out near-white on white.
    private static func attributed(_ meta: TranscriptMeta) -> NSAttributedString {
        let blocks = TranscriptParser.parse(TranscriptStore.body(of: meta.url))
        let cast = SpeakerCast(blocks)
        let result = NSMutableAttributedString()

        func append(_ text: String, _ face: Typeface,
                    _ tone: Tone = Ink.textPrimary, spacingAfter: CGFloat = Gap.s6) {
            let style = NSMutableParagraphStyle()
            style.paragraphSpacing = spacingAfter
            style.lineSpacing = face.lineSpacing
            result.append(NSAttributedString(string: text + "\n", attributes: [
                .font: face.nsFont, .foregroundColor: tone.light, .paragraphStyle: style
            ]))
        }

        append(meta.displayTitle, PrintFace.title, spacingAfter: Gap.s2)
        let sub = [meta.date, meta.time, meta.duration].filter { !$0.isEmpty }.joined(separator: " · ")
        if !sub.isEmpty { append(sub, PrintFace.meta, Ink.textHelper, spacingAfter: Gap.s4) }
        if !meta.participants.isEmpty {
            append(meta.participants.joined(separator: ", "), PrintFace.names, Ink.textSecondary)
        }

        for block in blocks {
            switch block {
            case .section(let title): append(title, PrintFace.section, spacingAfter: Gap.s4)
            case .audioLine(let stamp, let speaker, let text):
                result.append(spokenLine(stamp: stamp, speaker: speaker, text: text, cast: cast))
            case .paragraph(let text): append(text, PrintFace.body, Ink.textSecondary)
            case .table(let rows): append(rows.joined(separator: "\n"), PrintFace.table, Ink.textSecondary)
            case .screenMarker(let stamp): append(stamp, PrintFace.stamp, Ink.textHelper)
            case .divider: append("", PrintFace.stamp, spacingAfter: Gap.s6)
            }
        }
        return result
    }

    /// The same three registers the reader draws on one line, in print: mono stamp, UI name in the
    /// speaker's own tone, prose words.
    private static func spokenLine(stamp: String, speaker: String?, text: String,
                                   cast: SpeakerCast) -> NSAttributedString {
        let line = NSMutableAttributedString()
        line.append(run("\(stamp) ", PrintFace.stamp, Ink.textHelper))
        if let speaker {
            let face = cast.isSelf(speaker) ? PrintFace.speakerSelf : PrintFace.speaker
            line.append(run("\(speaker): ", face, cast.tone(for: speaker)))
        }
        line.append(run(text + "\n", PrintFace.body, Ink.textPrimary))
        // One paragraph, so the turn takes the PROSE leading even though its first two runs are
        // not prose. A paragraph style is per-paragraph; leaving it unset is what gave the printed
        // transcript system-default leading while every other block carried the register's.
        let style = NSMutableParagraphStyle()
        style.paragraphSpacing = Gap.s6
        style.lineSpacing = PrintFace.body.lineSpacing
        line.addAttribute(.paragraphStyle, value: style, range: NSRange(location: 0, length: line.length))
        return line
    }

    private static func run(_ text: String, _ face: Typeface, _ tone: Tone) -> NSAttributedString {
        NSAttributedString(string: text, attributes: [
            .font: face.nsFont, .foregroundColor: tone.light
        ])
    }

    // MARK: - Writers

    static func exportText(_ meta: TranscriptMeta, to url: URL) throws {
        let header = "\(meta.displayTitle)\n\n"
        try (header + plainText(of: meta.url)).write(to: url, atomically: true, encoding: .utf8)
    }

    /// Renders the transcript to a paginated PDF (US Letter) with no print panel.
    ///
    /// The numbers below are the page, not the design system: 612 x 792 and a 54pt margin are US
    /// Letter in PostScript points. `Metrics` has nothing to say about paper.
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
            throw NSError(domain: "Scripta", code: 400,
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
