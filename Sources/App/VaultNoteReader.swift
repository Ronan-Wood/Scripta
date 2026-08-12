import AppKit
import SubstrateKit
import SwiftUI

/// Reading one vault note, in whichever frame the reader asked for.
///
/// THREE PRESENTATIONS, ONE VIEW. A note opened as a modal sheet: it covered the list it came from,
/// so comparing two notes meant closing one, and it could be neither widened nor set aside. Reading
/// is not a modal act — it is the thing this surface is FOR — so the base is now a panel beside the
/// list, with the two escapes a reader actually wants: fill the pane, or put it in its own window
/// and keep browsing.
///
/// The frame is the caller's; everything inside it is this view, so the three modes cannot drift
/// into three renderings of one note.
struct VaultNoteReader: View {
    let document: VaultDocument
    @ObservedObject var model: VaultBrowseModel
    /// Drawn at the top right. The panel offers all three; a window offers none (it IS the escape).
    var controls: AnyView?
    /// Following a `[[link]]`. `nil` in a torn-off window, where a link opens ANOTHER window rather
    /// than replacing the note somebody deliberately set aside.
    var follow: ((VaultDocument) -> Void)?

    @State private var outcome: VaultBrowseModel.Reading?

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Rectangle().fill(Ink.borderSubtle.color).frame(height: 1)
            content
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .background(Ink.background)
        // KEYED ON THE DOCUMENT. Selecting another note while this one is open has to re-read;
        // a plain `.task` would fire once and leave the first note's text under the second's title.
        .task(id: document.id) {
            outcome = nil
            outcome = await model.read(document)
        }
    }

    private var header: some View {
        HStack(alignment: .top, spacing: Gap.s8) {
            VStack(alignment: .leading, spacing: Gap.s6) {
                Text(document.title ?? document.id)
                    .typeface(Register.title3, Ink.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                // THE SPINE, where the raw YAML used to be — the same badge row every other surface
                // draws, rather than `status: active` printed as prose.
                PassageSpine(passage: document.spine)
                if !document.vault.isEmpty {
                    Text(document.tier.map { "\(document.vault) · tier \($0)" } ?? document.vault)
                        .typeface(Register.monoMicro, Ink.textHelper)
                }
            }
            Spacer(minLength: Gap.s8)
            if let controls { controls }
        }
        .padding(Metrics.cardPaddingCompact)
    }

    @ViewBuilder private var content: some View {
        switch outcome {
        case nil:
            VaultProbe()
        case .refused(let refusal):
            ScrollView {
                VaultRefusalCard(refusal: refusal, retryTitle: nil, retry: nil)
                    .padding(Metrics.pageGutter)
            }
        case .note(let note):
            ScrollView {
                VStack(alignment: .leading, spacing: Gap.s12) {
                    if let line = freshness(note) {
                        EngineNoteRow(note: line)
                            .padding(Metrics.cardPaddingCompact)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .surface(Ink.layer)
                    }
                    MarkdownNoteView(markdown: note.text,
                                     resolves: { model.note(named: $0) != nil },
                                     openLink: { name in
                                         guard let target = model.note(named: name) else { return }
                                         if let follow { follow(target) }
                                         else { VaultNoteWindows.show(target, model: model) }
                                     })
                    Rectangle().fill(Ink.borderSubtle.color).frame(height: 1)
                    Text(note.path).typeface(Register.monoMicro, Ink.textHelper)
                        .textSelection(.enabled)
                }
                .padding(Metrics.pageGutter)
                .frame(maxWidth: Metrics.listMaxWidth, alignment: .leading)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    /// Only when there is something to say. A note that matches the index is the healthy state and
    /// rule 3 keeps it quiet; the other two verdicts are not the same as each other and neither is
    /// the same as silence.
    private func freshness(_ note: WireNote) -> EngineNote? {
        switch note.stale {
        case .matches:
            return nil
        case .stale:
            return EngineNote(id: "stale", marker: "changed", tone: Ink.warning,
                              text: "This note has been edited since the index was built. You are "
                                  + "reading the vault's current text; a search would still answer "
                                  + "from the older one until the scope is recomposed.")
        case .uncheckable:
            return EngineNote(id: "unverifiable", marker: "unverified", tone: Ink.textHelper,
                              text: "Whether this note has changed cannot be told from the index — "
                                  + "its stored checksum names a source file rather than the note "
                                  + "itself. This is the vault's current text either way.")
        }
    }
}

/// Notes the reader has torn off into their own windows.
///
/// AppKit rather than a SwiftUI `Window` scene: this app has no `App` scene to declare one in — it
/// is `AppDelegate`-driven — and the Help window already takes this shape. Controllers are retained
/// here and dropped on close, because an `NSWindow` nobody holds closes itself immediately.
@MainActor
enum VaultNoteWindows {
    private static var open: [String: NSWindowController] = [:]

    static func show(_ document: VaultDocument, model: VaultBrowseModel) {
        // ONE WINDOW PER NOTE. Tearing the same note off twice should raise the window that already
        // has it rather than stack a second copy that can drift from the first.
        if let existing = open[document.id] {
            existing.window?.makeKeyAndOrderFront(nil)
            NSApp.activate(ignoringOtherApps: true)
            return
        }
        let reader = VaultNoteReader(document: document, model: model)
        let window = NSWindow(contentViewController: NSHostingController(rootView: reader))
        window.title = document.title ?? document.id
        window.styleMask = [.titled, .closable, .miniaturizable, .resizable]
        window.setContentSize(NSSize(width: 720, height: 720))
        window.isReleasedWhenClosed = false
        window.center()

        let controller = NSWindowController(window: window)
        open[document.id] = controller
        NotificationCenter.default.addObserver(forName: NSWindow.willCloseNotification,
                                               object: window, queue: .main) { _ in
            MainActor.assumeIsolated { open[document.id] = nil }
        }
        NSApp.activate(ignoringOtherApps: true)
        controller.showWindow(nil)
    }
}
