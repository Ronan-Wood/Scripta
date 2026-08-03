import SwiftUI

/// Clovis — private, on-device chat over the user's calls. Retrieval + Foundation Models,
/// cited to source calls; conversations persist per workspace. Everything stays local.
///
/// TWO BRAINS, PERMANENTLY (Doc 3 §4). Substrate holds zero transcript content — every composed
/// scope is an Obsidian vault — so the vault brain is ADDITIVE and the call brain below it is
/// untouched: the same retrieval, the same conversations, the same workspace privacy wall. The
/// selector above them exists because Doc 3 §6 makes "which corpus am I asking" the one exception
/// to "surface effects, never mechanism"; a reader who cannot tell which brain answered reads a
/// vault's silence as a fact about their calls.
struct AskView: View {
    @ObservedObject private var ask = AppModel.shared.ask
    @ObservedObject private var app = AppModel.shared
    @ObservedObject private var vault = SubstrateAskModel.shared

    var body: some View {
        VStack(spacing: 0) {
            AskBrainBar(brain: $vault.brain)
            Rectangle().fill(Carbon.borderSubtle).frame(height: 1)
            brainContent
        }
        .background(Carbon.background)
        .onAppear { ask.activate(group: app.activeGroup) }
        .onChange(of: app.activeGroup) { _, group in ask.activate(group: group) }
    }

    @ViewBuilder private var brainContent: some View {
        switch vault.brain {
        case .calls: callsColumns
        case .vault: SubstrateAskView(model: vault)
        }
    }

    /// The existing call-search surface, moved down a level and otherwise unchanged.
    private var callsColumns: some View {
        HStack(spacing: 0) {
            conversationSidebar
            Rectangle().fill(Carbon.borderSubtle).frame(width: 1)
            chatColumn
        }
    }

    // MARK: - Conversation list (workspace-scoped, like everything else)

    private var conversationSidebar: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Button {
                ask.newConversation(group: app.activeGroup)
            } label: {
                HStack(spacing: 8) {
                    CarbonIcon(name: "edit", size: 14, color: Carbon.textOnColor)
                    Text("New conversation")
                        .font(CarbonFont.medium(13)).foregroundStyle(Carbon.textOnColor).lineLimit(1)
                }
                .frame(maxWidth: .infinity)
                .frame(height: 34)
                .background(Carbon.interactive, in: RoundedRectangle(cornerRadius: 7, style: .continuous))
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            ScrollView {
                VStack(spacing: Space.x2) {
                    ForEach(ask.conversations(in: app.activeGroup)) { conversation in
                        conversationRow(conversation)
                    }
                }
            }
            Spacer(minLength: 0)
        }
        .padding(Space.x4)
        .frame(width: 220)
    }

    private func conversationRow(_ conversation: AskModel.Conversation) -> some View {
        let selected = conversation.id == ask.currentID
        return Button {
            ask.select(conversation.id, group: app.activeGroup)
        } label: {
            VStack(alignment: .leading, spacing: Space.x1) {
                Text(conversation.title)
                    .font(CarbonFont.medium(13))
                    .foregroundStyle(Carbon.textPrimary).lineLimit(1)
                Text(relative(conversation.created))
                    .font(CarbonFont.label(11)).foregroundStyle(Carbon.textHelper)
            }
            .padding(Space.x3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(selected ? Carbon.interactive.opacity(0.12) : Color.clear,
                        in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu {
            Button("Delete conversation", role: .destructive) {
                ask.delete(conversation.id, group: app.activeGroup)
            }
        }
    }

    private func relative(_ date: Date) -> String {
        let fmt = RelativeDateTimeFormatter()
        fmt.unitsStyle = .short
        return fmt.localizedString(for: date, relativeTo: Date())
    }

    // MARK: - Chat

    private var chatColumn: some View {
        VStack(spacing: 0) {
            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: Space.x5) {
                        if ask.messages.isEmpty { intro }
                        ForEach(ask.messages) { bubble($0) }
                        if ask.thinking { thinkingRow }
                        Color.clear.frame(height: 1).id("bottom")
                    }
                    .padding(Space.x7)
                    .frame(maxWidth: 720, alignment: .leading)
                    .frame(maxWidth: .infinity)
                }
                .onChange(of: ask.messages.count) { _, _ in
                    withAnimation { proxy.scrollTo("bottom") }
                }
            }
            composer
        }
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack(spacing: Space.x3) {
                clovisBadge
                Text("Ask Clovis").font(CarbonFont.semibold(20)).foregroundStyle(Carbon.textPrimary)
            }
            Text("Answers are grounded in your \(workspaceName) transcripts and cited — nothing leaves your Mac.")
                .font(CarbonFont.body(14)).foregroundStyle(Carbon.textSecondary)
            if !ask.available {
                Text("Enable Apple Intelligence to use this (System Settings › Apple Intelligence & Siri).")
                    .font(CarbonFont.label(13)).foregroundStyle(Carbon.warning)
            }
        }
        .padding(.bottom, Space.x3)
    }

    private var workspaceName: String {
        app.activeGroup.isEmpty ? "Ungrouped" : app.activeGroup
    }

    private var clovisBadge: some View {
        Image(systemName: "sparkles")
            .font(.system(size: 11, weight: .semibold))
            .foregroundStyle(Carbon.interactive)
            .frame(width: 22, height: 22)
            .background(Carbon.interactive.opacity(0.14), in: Circle())
    }

    @ViewBuilder private func bubble(_ message: AskModel.Message) -> some View {
        if message.fromUser {
            HStack {
                Spacer(minLength: Space.x8)
                Text(message.text)
                    .font(CarbonFont.body(15)).foregroundStyle(Carbon.textPrimary)
                    .textSelection(.enabled)
                    .padding(.horizontal, Space.x5).padding(.vertical, Space.x3)
                    .background(Carbon.layerSelected, in: RoundedRectangle(cornerRadius: 14, style: .continuous))
            }
        } else {
            VStack(alignment: .leading, spacing: Space.x3) {
                HStack(alignment: .top, spacing: Space.x4) {
                    clovisBadge
                    VStack(alignment: .leading, spacing: Space.x2) {
                        Text("Clovis").font(CarbonFont.medium(12)).foregroundStyle(Carbon.textSecondary)
                        Text(message.text)
                            .font(CarbonFont.body(15)).foregroundStyle(Carbon.textPrimary)
                            .textSelection(.enabled)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                }
                if !message.sources.isEmpty {
                    VStack(spacing: Space.x2) {
                        ForEach(message.sources) { source in
                            Button {
                                app.route = .call(source.url, ms: source.startMs > 0 ? source.startMs : nil)
                            } label: {
                                HStack(spacing: Space.x3) {
                                    CarbonIcon(name: "document", size: 13, color: Carbon.iconSecondary)
                                    Text(source.title).font(CarbonFont.medium(12)).foregroundStyle(Carbon.textPrimary).lineLimit(1)
                                    Spacer()
                                    Image(systemName: "chevron.right")
                                        .font(.system(size: 9, weight: .semibold)).foregroundStyle(Carbon.textHelper)
                                }
                                .padding(Space.x3)
                                .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.control, style: .continuous))
                                .overlay {
                                    RoundedRectangle(cornerRadius: Radius.control, style: .continuous)
                                        .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
                                }
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                        }
                    }
                    .padding(.leading, 34)
                    .frame(maxWidth: 460, alignment: .leading)
                }
                if !message.text.isEmpty {
                    ClovisAnswerFooter(message: message)
                        .padding(.leading, 34)
                        .frame(maxWidth: 560, alignment: .leading)
                }
            }
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: Space.x4) {
            clovisBadge
            ProgressView().controlSize(.small)
            Text("Thinking…").font(CarbonFont.body(14)).foregroundStyle(Carbon.textSecondary)
        }
    }

    private var composer: some View {
        HStack(spacing: Space.x3) {
            TextField("Ask Clovis about your calls…", text: $ask.input, axis: .vertical)
                .textFieldStyle(.plain)
                .font(CarbonFont.body(15))
                .lineLimit(1...5)
                .onSubmit(submit)
            Button(action: submit) {
                Image(systemName: "arrow.up.circle.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(canSend ? Carbon.interactive : Carbon.borderStrong)
            }
            .buttonStyle(.plain)
            .disabled(!canSend)
        }
        .padding(.horizontal, Space.x5).padding(.vertical, Space.x4)
        .background(Carbon.layer, in: RoundedRectangle(cornerRadius: Radius.field, style: .continuous))
        .overlay { RoundedRectangle(cornerRadius: Radius.field, style: .continuous).strokeBorder(Carbon.borderSubtle, lineWidth: 1) }
        .padding(Space.x5)
    }

    private var canSend: Bool {
        !ask.thinking && !ask.input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        guard canSend else { return }
        Task { await ask.send() }
    }
}

/// Which corpus is being asked. Two chips rather than a mode nobody can see: the two stores hold
/// disjoint content — calls on the local index, notes in the composed scopes — so an answer from
/// one says nothing at all about the other, and a reader who mistakes which one they asked will
/// take a silence for a fact.
private struct AskBrainBar: View {
    @Binding var brain: SubstrateAskModel.Brain

    var body: some View {
        HStack(spacing: Gap.s6) {
            EnvelopeMarkerLabel(name: "asking")
            chip("Calls", .waveform, .calls)
            chip("Vault notes", .book, .vault)
            Spacer(minLength: Gap.s8)
        }
        // `Gap`, not `Space`, and the mix is only at this seam: the bar's contents are Record &
        // Register components, so the box around them is measured in that layer's tokens. The
        // values match the Carbon chrome it abuts (16 / 8) rather than coincidentally landing there.
        .padding(.horizontal, Gap.s16)
        .padding(.vertical, Gap.s8)
    }

    private func chip(_ title: String, _ glyph: Glyph, _ value: SubstrateAskModel.Brain) -> some View {
        Pill(text: title,
             glyph: glyph,
             style: brain == value ? .selected : .neutral,
             action: { brain = value })
    }
}
