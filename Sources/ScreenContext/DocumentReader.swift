import Vision
import CoreGraphics

/// How aggressively to filter recognized screen text down to what matters.
/// Tables are always kept (they're structured, high-value); the level only governs how
/// much of the free-floating text around them survives.
enum ScreenFocus: String, CaseIterable, Identifiable {
    case everything      // all text
    case trimChrome      // drop short labels (toolbar/sidebar chrome)
    case mainContent     // keep only prose-length text

    var id: String { rawValue }

    var label: String {
        switch self {
        case .everything: return "Everything"
        case .trimChrome: return "Trim chrome"
        case .mainContent: return "Main content only"
        }
    }

    /// Minimum word count for a non-table paragraph to be kept.
    var minParagraphWords: Int {
        switch self {
        case .everything: return 1
        case .trimChrome: return 3
        case .mainContent: return 6
        }
    }
}

/// Reads structured text from a screenshot using Apple's on-device document recognizer
/// (`RecognizeDocumentsRequest`, macOS 26+). Tables come back as Markdown; other text as
/// paragraphs. Fully local — no network, no external model.
enum DocumentReader {

    static func read(_ image: CGImage, focus: ScreenFocus) async -> String? {
        let request = RecognizeDocumentsRequest()
        guard let observations = try? await request.perform(on: image),
              let document = observations.first?.document else { return nil }

        var blocks: [String] = []
        var tableCellText = Set<String>()

        // Tables first — structured content.
        for table in document.tables {
            for row in table.rows {
                for cell in row { tableCellText.insert(cell.content.text.transcript) }
            }
            let table = markdown(for: table)
            if !table.isEmpty { blocks.append(table) }
        }

        // Free paragraphs that aren't already captured in a table, filtered by focus level.
        let minWords = focus.minParagraphWords
        for paragraph in document.paragraphs {
            let text = paragraph.transcript.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !text.isEmpty, !tableCellText.contains(paragraph.transcript) else { continue }
            guard wordCount(text) >= minWords else { continue }
            blocks.append(text)
        }

        let combined = blocks.joined(separator: "\n\n").trimmingCharacters(in: .whitespacesAndNewlines)
        return combined.isEmpty ? nil : combined
    }

    // MARK: - Helpers

    private static func markdown(for table: DocumentObservation.Container.Table) -> String {
        let rows = table.rows
        guard !rows.isEmpty else { return "" }
        let columnCount = max(table.columns.count, rows.map(\.count).max() ?? 0)
        guard columnCount > 0 else { return "" }

        var lines: [String] = []
        for (index, row) in rows.enumerated() {
            var cells = row.map { clean($0.content.text.transcript) }
            while cells.count < columnCount { cells.append("") }
            lines.append("| " + cells.joined(separator: " | ") + " |")
            if index == 0 {
                lines.append("| " + Array(repeating: "---", count: columnCount).joined(separator: " | ") + " |")
            }
        }
        return lines.joined(separator: "\n")
    }

    private static func clean(_ text: String) -> String {
        text.replacingOccurrences(of: "\n", with: " ")
            .replacingOccurrences(of: "|", with: "\\|")
            .trimmingCharacters(in: .whitespaces)
    }

    private static func wordCount(_ text: String) -> Int {
        text.split(whereSeparator: { $0 == " " || $0 == "\n" }).count
    }
}
