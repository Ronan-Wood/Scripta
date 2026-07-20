import SwiftUI
import ScriptaCore
import AppKit

/// Reader for one transcript, used inside the hub's Calls pane. (The old standalone viewer window
/// was retired when the hub took over browsing.)
struct TranscriptDetail: View {
    let meta: TranscriptMeta
    /// When set, the reader scrolls to (and briefly flashes) the spoken line at/under this time —
    /// so clicking a search hit or an Ask citation lands on the moment, not the top of the call.
    var scrollToMs: Int? = nil
    let onEdited: () -> Void
    var onDeleted: () -> Void = {}
    @State private var showingEditor = false
    @State private var confirmingDelete = false
    @State private var exportError: String?
    @State private var addingTerm = false
    @State private var termCanonical = ""
    @State private var termAliases = ""
    @State private var termGloss = ""
    @State private var flashIndex: Int?
    // Parsed once per transcript (off the main thread) and cached — re-reading + re-parsing the
    // whole file inside `body` on every invalidation was a large part of the long-transcript lag.
    @State private var blocks: [TranscriptBlock] = []

    var body: some View {
        // In-pane action row (not a native `.toolbar`): the hub draws its own in-window title bar
        // and suppresses the system titlebar, so a native toolbar here would hoist these buttons
        // into that suppressed bar and break the top-bar layout only on this pane. Carbon-styled
        // row keeps Calls consistent with every other section.
        VStack(spacing: 0) {
            actionBar
            ScrollViewReader { proxy in
                ScrollView {
                    // Lazy: only on-screen blocks are realized/laid out. A non-lazy VStack built every
                    // block of an hour-long call up front (and re-laid them on each scroll tick).
                    LazyVStack(alignment: .leading, spacing: 14) {
                        header
                        Divider()
                        ForEach(Array(blocks.enumerated()), id: \.offset) { offset, block in
                            BlockView(block: block, highlighted: offset == flashIndex).id(offset)
                        }
                        // Title + topics as the query: cheap, always-available, and exactly the
                        // holistic-concept surface the index's own topic-fusion search already
                        // leans on (M18) — no need to re-read/parse the body for a summary.
                        RelatedItemsPanel(query: (meta.title + " " + meta.tags.joined(separator: " ")),
                                         excludePath: meta.url.path, group: meta.group)
                    }
                    .padding(20)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .textSelection(.enabled)
                }
                .task(id: meta.url) { await loadBlocks(); scrollToTarget(proxy) }
                .onChange(of: scrollToMs) { _, _ in scrollToTarget(proxy) }
            }
        }
        .alert("Add vocabulary term", isPresented: $addingTerm) {
            TextField("Term (e.g. TIM)", text: $termCanonical)
            TextField("Aliases, comma-separated", text: $termAliases)
            TextField("Meaning (optional)", text: $termGloss)
            Button("Add") {
                let aliases = termAliases.split(separator: ",").map { $0.trimmingCharacters(in: .whitespaces) }
                EntityRegistry.shared.addTerm(canonical: termCanonical, aliases: aliases,
                                              gloss: termGloss.isEmpty ? nil : termGloss,
                                              group: AppModel.shared.activeGroup)
                if let store = IndexStore.shared { IndexBuilder.syncTerms(store: store) }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("Feeds transcription biasing and search — the term and its aliases match each other everywhere.")
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

    /// Scrolls to the last spoken line at/under `scrollToMs` and flashes it briefly.
    @MainActor private func scrollToTarget(_ proxy: ScrollViewProxy) {
        guard let ms = scrollToMs, !blocks.isEmpty else { return }
        var target: Int?
        for (i, block) in blocks.enumerated() {
            if case let .audioLine(stamp, _, _) = block, let bms = Indexing.parseStamp(stamp), bms <= ms {
                target = i
            }
        }
        guard let target else { return }
        withAnimation { proxy.scrollTo(target, anchor: .center) }
        flashIndex = target
        Task {
            try? await Task.sleep(nanoseconds: 1_900_000_000)
            if flashIndex == target { flashIndex = nil }
        }
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
            HStack(spacing: 8) {
                Text(meta.displayTitle).font(.title2).bold()
                if meta.isConference {
                    Text("Conference")
                        .font(.caption2).bold()
                        .padding(.horizontal, 7).padding(.vertical, 2)
                        .background(Color.orange.opacity(0.18), in: Capsule())
                        .foregroundStyle(.orange)
                }
            }
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

    // MARK: - Action row (matches the hub's 40pt in-window bar treatment)

    private var actionBar: some View {
        HStack(spacing: Space.x1) {
            Spacer()
            ReaderBarButton(systemImage: "pencil", help: "Edit details") { showingEditor = true }
            ReaderBarButton(systemImage: "square.and.pencil", help: "Open in external editor") {
                NSWorkspace.shared.open(meta.url)
            }
            ReaderBarButton(systemImage: "folder", help: "Reveal in Finder") {
                NSWorkspace.shared.activateFileViewerSelecting([meta.url])
            }
            shareMenu
            ReaderBarButton(systemImage: "character.book.closed",
                            help: "Add to vocabulary — teach a term once; transcription and search learn it everywhere") {
                termCanonical = ""; termAliases = ""; termGloss = ""
                addingTerm = true
            }
            ReaderBarButton(systemImage: "trash", help: "Delete transcript", tint: Carbon.danger) {
                confirmingDelete = true
            }
        }
        .padding(.horizontal, Space.x4)
        .frame(height: 40)
        .background(Carbon.background)
        .overlay(alignment: .bottom) { Rectangle().fill(Carbon.borderSubtle).frame(height: 1) }
    }

    private var shareMenu: some View {
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
            Divider()
            Button("Attach document to this call…") {
                let panel = NSOpenPanel()
                panel.canChooseFiles = true
                panel.allowsMultipleSelection = true
                panel.prompt = "Attach"
                panel.message = "The file's text is analyzed on-device and linked to this call."
                guard panel.runModal() == .OK else { return }
                for url in panel.urls {
                    Task { await AppModel.shared.importDocument(url, linkedCall: meta.url) }
                }
            }
        } label: {
            Image(systemName: "square.and.arrow.up")
                .font(.system(size: 14))
                .foregroundStyle(Carbon.iconSecondary)
                .frame(width: 28, height: 28)
                .contentShape(Rectangle())
        }
        .menuStyle(.borderlessButton)
        .menuIndicator(.hidden)
        .fixedSize()
        .help("Share, export, or attach a document")
    }
}

/// An icon button for the reader's action row — matches the hub's plain, hover-tinted controls.
private struct ReaderBarButton: View {
    let systemImage: String
    let help: String
    var tint: Color = Carbon.iconSecondary
    let action: () -> Void
    @State private var hovering = false

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: 14))
                .foregroundStyle(tint)
                .frame(width: 28, height: 28)
                .background(hovering ? Carbon.layerHover : Color.clear,
                            in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .onHover { hovering = $0 }
        .help(help)
    }
}

private struct BlockView: View {
    let block: TranscriptBlock
    var highlighted: Bool = false

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
            .padding(.vertical, highlighted ? 4 : 0)
            .padding(.horizontal, highlighted ? 8 : 0)
            .background(highlighted ? Color.accentColor.opacity(0.15) : Color.clear,
                        in: RoundedRectangle(cornerRadius: 6))
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
