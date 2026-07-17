import SwiftUI

/// The render's Assistant drawer: a 400pt panel that slides in from the window's right edge,
/// showing the live Clovis thread — the SAME conversation the Ask pane holds (shared AskModel),
/// so the drawer is a quick peek/continue surface, not a second brain.
struct ClovisDrawerView: View {
    @ObservedObject private var ask = AppModel.shared.ask
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
                        if ask.thinking { thinkingRow }
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

    @ViewBuilder private func bubble(_ message: AskModel.Message) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(message.fromUser ? "You" : "Clovis")
                .font(CarbonFont.medium(11)).foregroundStyle(Carbon.textHelper)
            Text(message.text)
                .font(CarbonFont.body(14)).foregroundStyle(Carbon.textPrimary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if !message.sources.isEmpty {
                VStack(spacing: 4) {
                    ForEach(message.sources.prefix(4)) { source in
                        Button {
                            app.route = .call(source.url, ms: source.startMs > 0 ? source.startMs : nil)
                            close()
                        } label: {
                            HStack(spacing: 6) {
                                CarbonIcon(name: "document", size: 11, color: Carbon.iconSecondary)
                                Text(source.title).font(CarbonFont.medium(11.5))
                                    .foregroundStyle(Carbon.textPrimary).lineLimit(1)
                                Spacer(minLength: 0)
                            }
                            .padding(.horizontal, 8).padding(.vertical, 6)
                            .background(Carbon.layer, in: RoundedRectangle(cornerRadius: 6, style: .continuous))
                            .overlay {
                                RoundedRectangle(cornerRadius: 6, style: .continuous)
                                    .strokeBorder(Carbon.borderSubtle, lineWidth: 1)
                            }
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            if !message.fromUser, let engine = message.engineLabel, !message.text.isEmpty {
                Text(engine).font(CarbonFont.label(10.5)).foregroundStyle(Carbon.textHelper)
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
            TextField("Ask about your calls…", text: $ask.input, axis: .vertical)
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

    private var canSend: Bool {
        !ask.thinking && !ask.input.trimmingCharacters(in: .whitespaces).isEmpty
    }

    private func submit() {
        guard canSend else { return }
        Task { await ask.send() }
    }
}
