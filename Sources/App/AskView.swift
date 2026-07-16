import SwiftUI

/// Private, on-device chat over the user's calls. Retrieval + Foundation Models, cited to source
/// calls. Everything stays local.
struct AskView: View {
    @ObservedObject private var ask = AppModel.shared.ask
    @ObservedObject private var app = AppModel.shared

    var body: some View {
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
        .background(Carbon.background)
    }

    private var intro: some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            Text("Ask your calls").font(CarbonFont.semibold(20)).foregroundStyle(Carbon.textPrimary)
            Text("A private, on-device assistant over your transcripts. It answers from your calls and cites them — nothing leaves your Mac.")
                .font(CarbonFont.body(14)).foregroundStyle(Carbon.textSecondary)
            if !ask.available {
                Text("Enable Apple Intelligence to use this (System Settings › Apple Intelligence & Siri).")
                    .font(CarbonFont.label(13)).foregroundStyle(Carbon.warning)
            }
        }
        .padding(.bottom, Space.x3)
    }

    private func bubble(_ message: AskModel.Message) -> some View {
        VStack(alignment: .leading, spacing: Space.x3) {
            HStack(alignment: .top, spacing: Space.x4) {
                Image(systemName: message.fromUser ? "person.circle.fill" : "sparkles")
                    .font(.system(size: 16))
                    .foregroundStyle(message.fromUser ? Carbon.textSecondary : Carbon.interactive)
                    .frame(width: 20)
                Text(message.text)
                    .font(CarbonFont.body(15)).foregroundStyle(Carbon.textPrimary)
                    .textSelection(.enabled)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
            if !message.sources.isEmpty {
                FlexWrap(spacing: Space.x2) {
                    ForEach(message.sources) { source in
                        Button { app.route = .call(source.url, ms: source.startMs > 0 ? source.startMs : nil) } label: {
                            HStack(spacing: Space.x2) {
                                Image(systemName: "doc.text").font(.system(size: 11))
                                Text(source.title).font(CarbonFont.label(12))
                            }
                            .foregroundStyle(Carbon.textSecondary)
                            .padding(.horizontal, Space.x3).padding(.vertical, Space.x2)
                            .background(Carbon.layerSelected, in: Capsule())
                        }.buttonStyle(.plain)
                    }
                }
                .padding(.leading, Space.x6)
            }
        }
    }

    private var thinkingRow: some View {
        HStack(spacing: Space.x4) {
            Image(systemName: "sparkles").font(.system(size: 16)).foregroundStyle(Carbon.interactive).frame(width: 20)
            ProgressView().controlSize(.small)
            Text("Thinking…").font(CarbonFont.body(14)).foregroundStyle(Carbon.textSecondary)
        }
    }

    private var composer: some View {
        HStack(spacing: Space.x3) {
            TextField("Ask about your calls…", text: $ask.input, axis: .vertical)
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
