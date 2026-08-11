import SwiftUI

/// The render's Assistant drawer: a 400pt panel that slides in from the window's right edge,
/// showing the live Clovis thread — the SAME conversation the Ask pane holds (shared AskModel),
/// so the drawer is a quick peek/continue surface, not a second brain.
struct ClovisDrawerView: View {
    @ObservedObject private var ask = AskModel.shared
    @ObservedObject private var app = AppModel.shared
    let close: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            header
            Rectangle().fill(Carbon.borderSubtle).frame(height: 1)

            ScrollViewReader { proxy in
                ScrollView {
                    VStack(alignment: .leading, spacing: 16) {
                        if ask.messages.isEmpty { intro }
                        ForEach(ask.messages) { bubble($0) }
                        // THE THREE STATES THE MERGE HANDED THIS SURFACE, none of which it could
                        // reach before. Clovis answered a local FTS index in milliseconds and could
                        // not be unbound, down or slow; Ask can be all three. Rendering only
                        // `messages` and `thinking` left a question sitting under a vanished
                        // spinner with no reply and no reason — the Boundary Principle, in the one
                        // surface reachable from the title bar on every screen.
                        // ONE ROW, NAMING THE PHASE IT IS ACTUALLY IN. `running` spans retrieval
                        // AND generation (so Stop stays reachable) and `thinking` overlaps the
                        // second half of it, so drawing both put two spinners under one wait —
                        // and the retrieval row went on saying "Searching…" while the local model
                        // was the thing stalled, pointing the reader at the wrong component.
                        if let running = ask.running { waitingRow(running) }
                        else if ask.thinking { thinkingRow }
                        if case .refused(let refusal) = ask.answer {
                            VaultRefusalCard(refusal: refusal, scope: ask.scope,
                                             retryTitle: "Ask again", retry: ask.rerun)
                        }
                        Color.clear.frame(height: 1).id("drawer-bottom")
                    }
                    .padding(.vertical, 18)
                    .padding(.horizontal, 16)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: ask.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo("drawer-bottom") }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)

            Rectangle().fill(Carbon.borderSubtle).frame(height: 1)
            unboundNote
            composer
        }
        .frame(width: 400)
        .background(Carbon.background)
        .overlay(alignment: .leading) { Rectangle().fill(Carbon.borderSubtle).frame(width: 1) }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("ASSISTANT")
                .font(CarbonFont.label(11)).tracking(0.6)
                .foregroundStyle(Carbon.textSecondary)
            Text("AI")
                .font(CarbonFont.medium(9))
                .padding(.horizontal, 5).padding(.vertical, 1)
                .background(Carbon.blueSoft, in: Capsule())
                .foregroundStyle(Carbon.interactive)
            Spacer()
            Button {
                app.route = .section(.ask)
                close()
            } label: {
                Image(systemName: "arrow.up.left.and.arrow.down.right")
                    .font(.system(size: 11)).foregroundStyle(Carbon.iconSecondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Open in the Ask pane")
            Button(action: close) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .medium)).foregroundStyle(Carbon.iconSecondary)
                    .frame(width: 22, height: 22).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Close")
        }
        .padding(.horizontal, 12)
        .frame(height: 48)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Ask Clovis").font(CarbonFont.semibold(15)).foregroundStyle(Carbon.textPrimary)
            Text("Grounded in this workspace's calls and notes, cited — nothing leaves your Mac.")
                .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    @ViewBuilder private func bubble(_ message: AskMessage) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.fromUser ? "You" : "Clovis")
                .font(CarbonFont.medium(11)).foregroundStyle(Carbon.textHelper)
            Text(message.text)
                .font(CarbonFont.body(14)).foregroundStyle(Carbon.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !message.passages.isEmpty { ClovisCitations(message: message) }
            if !message.fromUser, !message.text.isEmpty {
                ClovisAnswerFooter(message: message)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    private var thinkingRow: some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text("Thinking…").font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
        }
    }

    private var composer: some View {
        HStack(spacing: 8) {
            TextField("Ask about your calls and notes…", text: $ask.query, axis: .vertical)
                .textFieldStyle(.plain)
                .font(CarbonFont.body(13.5))
                .lineLimit(1...4)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 22))
                    .foregroundStyle(canSend ? Carbon.interactive : Carbon.borderStrong)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
    }

    /// Mirrors the pane's, `scope != nil` included — see `VaultComposer.canSend`.
    private var canSend: Bool {
        !ask.thinking && ask.running == nil && ask.scope != nil
            && !ask.query.trimmingCharacters(in: .whitespaces).isEmpty
    }

    /// The wait, named by which half of it is running. They are genuinely different — retrieval is
    /// the engine's, generation is the local model's — and "still searching" over a stalled
    /// generator sends the reader to look at the wrong thing.
    private func waitingRow(_ running: AskModel.Running) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(running.phase == .retrieving
                 ? "Searching \(running.scope)…"
                 : "Answering from \(running.scope)…")
                .font(CarbonFont.body(13)).foregroundStyle(Carbon.textSecondary)
        }
    }

    /// An unbound workspace has no corpus to ask. Said out loud beside a disabled composer, with the
    /// remedy named, rather than left as a button that does nothing.
    @ViewBuilder private var unboundNote: some View {
        if ask.scope == nil {
            Text("This workspace reads no vault yet. Bind it to a scope in Ask.")
                .font(CarbonFont.label(11)).foregroundStyle(Carbon.warning)
                .fixedSize(horizontal: false, vertical: true)
                .padding(.horizontal, 14).padding(.bottom, 6)
        }
    }

    private func submit() {
        guard canSend else { return }
        ask.send()
    }
}

/// The citations under a drawer answer, restored through the same refusal the pane uses.
///
/// RESTORED, NOT READ RAW. Rendering `StoredPassage`'s fields directly printed whatever string was
/// on disk — so a token this build has no vocabulary for appeared as itself, and an absent one as a
/// blank, in the one place with no room to explain either. `StoredPassage.passage` is the existing
/// door and it REFUSES rather than guesses, which makes the drawer and the pane give the same
/// answer about the same stored turn: show what can be read, and say how many could not.
private struct ClovisCitations: View {
    let message: AskMessage

    var body: some View {
        VStack(spacing: 4) {
            ForEach(restored.prefix(4)) { ClovisCitation(passage: $0) }
            if withheld > 0 {
                Text("\(withheld) citation\(withheld == 1 ? "" : "s") withheld — this build has no "
                     + "vocabulary for a value stored earlier.")
                    .font(CarbonFont.label(10.5)).foregroundStyle(Carbon.textHelper)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
    }

    private var restored: [Passage] { message.passages.compactMap(\.passage) }
    private var withheld: Int { message.passages.count - restored.count }
}

/// One citation in the drawer: what it was, and how it should be read.
///
/// THE SPINE TRAVELS EVEN HERE, in a 400pt panel where the temptation is to show a title and stop.
/// A title alone is what the old source row showed, and it is the half that cannot distinguish a
/// decision someone verified from a sentence a speaker abandoned four turns later.
///
/// NOT A BUTTON, and that is a change rather than an oversight. The old row opened the call at its
/// timestamp, which it could do because a `ContextChunk` carried a local file path and a `startMs`.
/// A `Passage` carries neither — its path is structural (`"Call > Summary"`) and its expand ref
/// resolves to a file only through a round trip — so a row that still looked clickable would be
/// promising navigation this build cannot perform.
private struct ClovisCitation: View {
    let passage: Passage

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text(passage.citation)
                .font(CarbonFont.medium(11.5)).foregroundStyle(Carbon.textPrimary).lineLimit(2)
            Text(spine).font(CarbonFont.label(10.5)).foregroundStyle(Carbon.textHelper).lineLimit(1)
        }
        .padding(.horizontal, 8).padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Carbon.layer, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
        .overlay {
            RoundedRectangle(cornerRadius: 6, style: .continuous)
                .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
        }
    }

    /// `conversation` first, as `LiveRecallPanel` and the prompt builder both name it first, and
    /// through `.label` so one vocabulary reaches every surface.
    private var spine: String {
        var parts: [String] = []
        if passage.documentClass == .conversation { parts.append("from a call") }
        parts.append(passage.status.label)
        parts.append(passage.confidence.label)
        return parts.joined(separator: " · ")
    }
}

/// Under-answer footer for the drawer: the engine label and deterministic next-step chips — append
/// the answer into a standing note, or copy it.
///
/// THE GROUNDING BADGE IS GONE, deleted rather than ported (Doc 4 §2, and PRINCIPLES' fourth law).
/// It read strong / partly / thin and was computed from `chunks.filter { !$0.isTopic }.count` plus
/// a retrieval-fallback flag — both properties of the LOCAL call index, and neither exists on the
/// engine path. Recomputing something similarly-shaped over passages would have kept a label whose
/// calibration came from a different measurement, which is a claim with nothing behind it. What
/// replaces it is `EngineBar` in the Ask pane: the arms that actually ran and the measured tier for
/// that exact stack, or an honest null.
struct ClovisAnswerFooter: View {
    let message: AskMessage
    @ObservedObject private var app = AppModel.shared
    @State private var copied = false
    @State private var savedTo: String?

    var body: some View {
        HStack(spacing: 10) {
            if let engine = message.engineLabel {
                Text(engine).font(CarbonFont.label(10.5)).foregroundStyle(Carbon.textHelper)
            }
            Spacer(minLength: 0)
            if let savedTo {
                Text("Added to \(savedTo)").font(CarbonFont.label(10.5)).foregroundStyle(Carbon.success)
            } else {
                addToNoteChip
            }
            Button {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(message.text, forType: .string)
                copied = true
            } label: {
                Text(copied ? "Copied" : "Copy").font(CarbonFont.label(10.5))
                    .foregroundStyle(Carbon.textHelper).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
        }
    }

    @ViewBuilder private var addToNoteChip: some View {
        let notes = NoteStore.list(group: app.activeGroup)
        if !notes.isEmpty {
            Menu {
                ForEach(notes) { note in
                    Button(note.title) { append(to: note) }
                }
            } label: {
                HStack(spacing: 3) {
                    Image(systemName: "text.append").font(.system(size: 9, weight: .semibold))
                    Text("Add to note").font(CarbonFont.label(10.5))
                }
                .foregroundStyle(Carbon.textHelper)
                .contentShape(Rectangle())
            }
            .menuStyle(.borderlessButton)
            .menuIndicator(.hidden)
            .fixedSize()
            .help("Append this answer to a standing note, linked to its top source call")
        }
    }

    /// `linkedCall` is nil now. It used to be the top source's local file URL, which a
    /// `ContextChunk` carried and a `Passage` does not — see `ClovisCitation`. The answer still
    /// lands in the note; what it no longer carries is a link back to one call.
    private func append(to note: KnowledgeNote) {
        guard let refreshed = NoteStore.append(message.text, linkedCall: nil, to: note)
        else { return }
        savedTo = refreshed.title
        if let store = AppModel.shared.index {
            let url = refreshed.url
            Task.detached(priority: .utility) { IndexBuilder.indexNote(url, into: store) }
        }
    }
}
