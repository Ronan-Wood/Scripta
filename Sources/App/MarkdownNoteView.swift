import ScriptaShared
import SwiftUI

/// A vault note, rendered as a note rather than as its source.
///
/// IT DRAWS BLOCKS AND LETS THE PLATFORM DRAW INLINE. `MarkdownBlocks` finds the structure SwiftUI
/// has no opinion about — headings, lists, tables, fences — and every leaf goes through
/// `AttributedString(markdown:)`, which already handles `**bold**`, `*italic*`, `` `code` `` and
/// links. Splitting it there means the inline vocabulary grows with the platform rather than with
/// this file.
///
/// THE FRONTMATTER IS NOT CONTENT. It is the spine — `status`, `doc_type`, `confidence`, `domains`
/// — which every other surface in this app draws as a badge row and which was being shown here as
/// three lines of raw YAML above the title. The sheet already knows those values from the browse
/// row, so the body simply starts after the fence.
struct MarkdownNoteView: View {
    let markdown: String
    /// Whether a `[[target]]` names a note this scope holds. Only resolvable ones become links —
    /// see `MarkdownBlocks.linkify`.
    var resolves: (String) -> Bool = { _ in false }
    var openLink: (String) -> Void = { _ in }

    static let linkScheme = "scripta-note"

    var body: some View {
        VStack(alignment: .leading, spacing: Gap.s12) {
            ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                view(for: block)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .textSelection(.enabled)
        // INTERCEPTED, NOT HANDED TO THE SYSTEM. `scripta-note://` has no handler and never should
        // — asking LaunchServices to open it would surface a "no application can open" alert for a
        // link this app is the only possible destination for.
        .environment(\.openURL, OpenURLAction { url in
            guard url.scheme == Self.linkScheme else { return .systemAction }
            let name = (url.host ?? url.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")))
                .removingPercentEncoding ?? ""
            guard !name.isEmpty else { return .handled }
            openLink(name)
            return .handled
        })
    }

    /// The body only. `Frontmatter.split` is the same parser the indexer and the vault reader use,
    /// so "what counts as frontmatter" has one answer in this app.
    private var blocks: [MarkdownBlocks.Block] {
        MarkdownBlocks.parse(Frontmatter.split(markdown)?.body ?? markdown)
    }

    @ViewBuilder private func view(for block: MarkdownBlocks.Block) -> some View {
        switch block {
        case .heading(let level, let text):
            Text(inline(text))
                .typeface(level <= 1 ? Register.title3 : level == 2 ? Register.uiEmphasis : Register.ui,
                          Ink.textPrimary)
                .padding(.top, level <= 2 ? Gap.s8 : 0)

        case .paragraph(let text):
            Text(inline(text))
                .proseText(Register.proseSm, Ink.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)

        case .bullets(let items):
            VStack(alignment: .leading, spacing: Gap.s6) {
                ForEach(Array(items.enumerated()), id: \.offset) { _, item in
                    marker("•", inline(item))
                }
            }

        case .numbered(let items):
            VStack(alignment: .leading, spacing: Gap.s6) {
                ForEach(Array(items.enumerated()), id: \.offset) { index, item in
                    marker("\(index + 1).", inline(item))
                }
            }

        case .table(let headers, let rows):
            MarkdownTable(headers: headers, rows: rows)

        case .code(let text):
            Text(text)
                .typeface(Register.monoMicro, Ink.textSecondary)
                .padding(Metrics.cardPaddingCompact)
                .frame(maxWidth: .infinity, alignment: .leading)
                .surface(Ink.layer)

        case .rule:
            Rectangle().fill(Ink.borderSubtle.color).frame(height: 1)
        }
    }

    private func marker(_ mark: String, _ text: AttributedString) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: Gap.s8) {
            Text(mark).typeface(Register.monoMicro, Ink.textHelper)
                .frame(width: 16, alignment: .trailing)
            Text(text).proseText(Register.proseSm, Ink.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Inline markdown, or the raw text when it will not parse. FALLS BACK RATHER THAN THROWS: a
    /// note with an unbalanced bracket is still a note, and showing its sentence with one stray
    /// character beats showing nothing.
    private func inline(_ text: String) -> AttributedString {
        let linked = MarkdownBlocks.linkify(text, scheme: Self.linkScheme, resolves: resolves)
        return (try? AttributedString(markdown: linked,
                                      options: .init(interpretedSyntax: .inlineOnlyPreservingWhitespace)))
            ?? AttributedString(text)
    }
}

/// A pipe table as an actual grid.
///
/// `Grid` rather than stacked `HStack`s so columns align across rows — a table whose columns do not
/// line up is harder to read than the pipe-separated source it replaced, which at least lined up in
/// a monospace font.
private struct MarkdownTable: View {
    let headers: [String]
    let rows: [[String]]

    var body: some View {
        Grid(alignment: .topLeading, horizontalSpacing: Gap.s12, verticalSpacing: Gap.s6) {
            GridRow {
                ForEach(Array(headers.enumerated()), id: \.offset) { _, cell in
                    Text(cell).typeface(Register.uiEmphasis, Ink.textPrimary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            Rectangle().fill(Ink.borderSubtle.color).frame(height: 1)
                .gridCellColumns(max(1, headers.count))
            ForEach(Array(rows.enumerated()), id: \.offset) { _, row in
                GridRow {
                    // Padded to the header width so a short row does not shift the columns under it.
                    ForEach(0..<max(headers.count, row.count), id: \.self) { column in
                        Text(column < row.count ? row[column] : "")
                            .proseText(Register.proseSm, Ink.textSecondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
            }
        }
        .padding(Metrics.cardPaddingCompact)
        .frame(maxWidth: .infinity, alignment: .leading)
        .surface(Ink.layer)
    }
}
