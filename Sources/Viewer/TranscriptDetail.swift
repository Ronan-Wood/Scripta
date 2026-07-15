import SwiftUI
import AppKit

/// Reader for one transcript, used inside the hub's Calls pane. (The old standalone viewer window
/// was retired when the hub took over browsing.)
struct TranscriptDetail: View {
    let meta: TranscriptMeta
    let onEdited: () -> Void
    var onDeleted: () -> Void = {}
    @State private var showingEditor = false
    @State private var confirmingDelete = false
    @State private var exportError: String?
    // Parsed once per transcript (off the main thread) and cached — re-reading + re-parsing the
    // whole file inside `body` on every invalidation was a large part of the long-transcript lag.
    @State private var blocks: [TranscriptBlock] = []

    var body: some View {
        ScrollView {
            // Lazy: only on-screen blocks are realized/laid out. A non-lazy VStack built every
            // block of an hour-long call up front (and re-laid them on each scroll tick).
            LazyVStack(alignment: .leading, spacing: 14) {
                header
                Divider()
                ForEach(Array(blocks.enumerated()), id: \.offset) { _, block in
                    BlockView(block: block)
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            .textSelection(.enabled)
        }
        .task(id: meta.url) { await loadBlocks() }
        .toolbar {
            ToolbarItemGroup {
                Button {
                    showingEditor = true
                } label: { Label("Edit Details", systemImage: "pencil") }
                Button {
                    NSWorkspace.shared.open(meta.url)
                } label: { Label("Open in Editor", systemImage: "square.and.pencil") }
                Button {
                    NSWorkspace.shared.activateFileViewerSelecting([meta.url])
                } label: { Label("Reveal in Finder", systemImage: "folder") }
                Menu {
                    Button("Copy summary") { copy(TranscriptExporter.summary(of: meta.url)) }
                    Button("Copy transcript") { copy(TranscriptExporter.plainText(of: meta.url)) }
                    Divider()
                    Button("Export as PDF…") {
                        TranscriptExporter.savePanel(suggestedName: fileName, ext: "pdf") { url in
                            do { try TranscriptExporter.exportPDF(meta, to: url) }
                            catch { exportError = error.localizedDescription }
                        }
                    }
                    Button("Export as text…") {
                        TranscriptExporter.savePanel(suggestedName: fileName, ext: "txt") { url in
                            do { try TranscriptExporter.exportText(meta, to: url) }
                            catch { exportError = error.localizedDescription }
                        }
                    }
                } label: { Label("Share", systemImage: "square.and.arrow.up") }
                Button(role: .destructive) {
                    confirmingDelete = true
                } label: { Label("Delete", systemImage: "trash") }
            }
        }
        .sheet(isPresented: $showingEditor) {
            TranscriptDetailsEditor(url: meta.url, title: meta.title, participants: meta.participants, tags: meta.tags) { saved in
                showingEditor = false
                if saved {
                    if let store = IndexStore.shared { IndexBuilder.index(meta.url, into: store) }
                    onEdited()
                }
            }
        }
        .alert("Export Failed", isPresented: Binding(
            get: { exportError != nil },
            set: { if !$0 { exportError = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(exportError ?? "")
        }
        .confirmationDialog("Delete “\(meta.displayTitle)”?", isPresented: $confirmingDelete, titleVisibility: .visible) {
            Button("Delete transcript", role: .destructive, action: performDelete)
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("This permanently deletes the transcript file. This can't be undone.")
        }
    }

    /// Reads + parses the transcript off the main thread, then swaps the cached blocks in. Runs
    /// on first appearance and whenever the selected call changes (`.task(id:)`).
    private func loadBlocks() async {
        let url = meta.url
        blocks = await Task.detached(priority: .userInitiated) {
            TranscriptParser.parse(TranscriptStore.body(of: url))
        }.value
    }

    private var fileName: String {
        meta.displayTitle.components(separatedBy: CharacterSet(charactersIn: "/\\:*?\"<>|")).joined(separator: "-")
    }

    private func copy(_ text: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(text.isEmpty ? "(none)" : text, forType: .string)
    }

    /// Deletes the transcript file, removes it from the index, and refreshes the call list.
    private func performDelete() {
        try? FileManager.default.removeItem(at: meta.url)
        IndexStore.shared?.remove(path: meta.url.path)
        AppModel.shared.reloadCalls()
        onDeleted()
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(meta.displayTitle).font(.title2).bold()
            HStack(spacing: 10) {
                if !meta.duration.isEmpty { label("clock", meta.duration) }
                if !meta.participants.isEmpty { label("person.2", meta.participants.joined(separator: ", ")) }
            }
            if !meta.tags.isEmpty {
                HStack(spacing: 6) {
                    ForEach(meta.tags, id: \.self) { tag in
                        Text(tag)
                            .font(.caption2)
                            .padding(.horizontal, 7).padding(.vertical, 2)
                            .background(.quaternary, in: Capsule())
                    }
                }
            }
        }
    }

    private func label(_ symbol: String, _ text: String) -> some View {
        Label(text, systemImage: symbol).font(.caption).foregroundStyle(.secondary)
    }
}

private struct BlockView: View {
    let block: TranscriptBlock

    var body: some View {
        switch block {
        case .section(let title):
            Text(title).font(.headline).padding(.top, 8)
        case .audioLine(let stamp, let speaker, let text):
            HStack(alignment: .firstTextBaseline, spacing: 8) {
                Text(stamp).font(.system(.caption, design: .monospaced))
                    .foregroundStyle(.secondary).frame(width: 52, alignment: .trailing)
                if let speaker {
                    Text(speaker)
                        .font(.caption).bold()
                        .foregroundStyle(speaker == "You" ? Color.accentColor : Color.orange)
                        .frame(width: 40, alignment: .leading)
                }
                Text(text)
            }
        case .screenMarker(let stamp):
            Text(stamp).font(.system(.caption, design: .monospaced))
                .foregroundStyle(.tertiary).padding(.top, 4)
        case .table(let rows):
            Text(rows.joined(separator: "\n"))
                .font(.system(.caption, design: .monospaced))
                .padding(10)
                .frame(maxWidth: .infinity, alignment: .leading)
                .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
        case .paragraph(let text):
            Text(text).foregroundStyle(.secondary)
        case .divider:
            Divider()
        }
    }
}
