import SwiftUI
import ScriptaCore

/// One block of a document's extracted text (M24) — `#`/`##`/`###` header lines detected and
/// stripped, everything else a paragraph. Trivial to detect (`hasPrefix("#")`), not a real parser:
/// proportionate to what `DocumentImporter`'s own extraction actually emits (its PDF/PPTX paths
/// mark page/slide breaks with literal `"## Page N"`/`"## Slide N"` headers) — not a general
/// CommonMark engine for content this app doesn't produce.
private struct MarkdownBlock: Identifiable {
    let id = UUID()
    let level: Int   // 0 = paragraph, 1...3 = heading level (capped at 3)
    let text: String
}

private func markdownBlocks(_ body: String) -> [MarkdownBlock] {
    body.components(separatedBy: "\n\n").compactMap { raw in
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else { return nil }
        let hashes = trimmed.prefix(while: { $0 == "#" })
        guard !hashes.isEmpty, trimmed.count > hashes.count,
              trimmed[trimmed.index(trimmed.startIndex, offsetBy: hashes.count)] == " " else {
            return MarkdownBlock(level: 0, text: trimmed)
        }
        let text = trimmed.dropFirst(hashes.count).trimmingCharacters(in: .whitespaces)
        return MarkdownBlock(level: min(hashes.count, 3), text: text)
    }
}

/// A document's extracted text, read-only (M24) — the reader modeled on `NoteDetailView` (a
/// sheet, your own artifact, not a call recording) rather than `TranscriptDetail` (tied to Calls'
/// own master/detail pane). Renders Markdown, not plain text — see `markdownBlocks` above for why
/// (Ronan: "make sure it can render the markdown too").
struct DocumentDetailView: View {
    @ObservedObject var model = AppModel.shared
    let doc: DocumentImporter.DocMeta
    let mdURL: URL
    let onClose: () -> Void
    let onDelete: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: Space.x1) {
                    Text(doc.title).font(CarbonFont.semibold(18)).foregroundStyle(Carbon.textPrimary)
                    Text("Imported \(doc.created)").font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
                }
                Spacer()
                Button {
                    // Same resolution EntityDetailView's onOpenDoc uses (verifiedOriginalURL),
                    // checked against the LIVE `model.activeGroup` rather than `doc.group` (the
                    // value captured at sheet-open time) — crosscheck flagged the latter as a
                    // tautological check that can't catch a workspace switch while this sheet is
                    // still open, unlike the sibling call sites that all key off a live model.
                    if let url = DocumentImporter.verifiedOriginalURL(atPath: mdURL.path, group: model.activeGroup) {
                        NSWorkspace.shared.open(url)
                    }
                } label: {
                    HStack(spacing: 4) {
                        CarbonIcon(name: "document", size: 12, color: Carbon.interactive)
                        Text("Open original").font(CarbonFont.label(12)).foregroundStyle(Carbon.interactive)
                    }
                    .contentShape(Rectangle())
                }.buttonStyle(.plain)
                Button(action: onDelete) {
                    Image(systemName: "trash")
                        .font(.system(size: 13)).foregroundStyle(Carbon.danger)
                        .frame(width: 28, height: 28).contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("Delete this document")
                CarbonButton(title: "Done", kind: .secondary, action: onClose)
            }
            .padding(Space.x6)

            Divider().overlay(Carbon.borderSubtle)

            ScrollView {
                VStack(alignment: .leading, spacing: Space.x4) {
                    ForEach(markdownBlocks(doc.body)) { block in
                        blockView(block)
                    }
                }
                .padding(Space.x6)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .frame(width: 560, height: 520)
        .background(Carbon.background)
    }

    private func blockView(_ block: MarkdownBlock) -> some View {
        // Inline-only markdown (bold/italic/code/links) within each block — block-level structure
        // (headings) was already split out by markdownBlocks above, so re-interpreting it here
        // would double-parse. Preserves whitespace: a paragraph's own internal line breaks (e.g.
        // from the source PDF's line wrapping) stay visible rather than collapsing to one run-on
        // line. Falls back to the raw text, unstyled, on a parse failure rather than showing
        // nothing.
        let options = AttributedString.MarkdownParsingOptions(interpretedSyntax: .inlineOnlyPreservingWhitespace)
        let attributed = (try? AttributedString(markdown: block.text, options: options)) ?? AttributedString(block.text)
        return Text(attributed)
            .font(font(for: block.level))
            .foregroundStyle(Carbon.textPrimary)
            .fixedSize(horizontal: false, vertical: true)
            .textSelection(.enabled)
    }

    private func font(for level: Int) -> Font {
        switch level {
        case 1: return CarbonFont.semibold(20)
        case 2: return CarbonFont.semibold(16)
        case 3: return CarbonFont.medium(14)
        default: return CarbonFont.body(14)
        }
    }
}
