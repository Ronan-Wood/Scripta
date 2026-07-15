import Foundation
import FoundationModels

/// The on-device "Ask your calls" chat: retrieves relevant passages from the index, then answers
/// over them with Apple's Foundation Models — fully local. Uses the grounding prompt validated to
/// connect related facts while refusing what isn't in the retrieved context (no hallucination).
@MainActor
final class AskModel: ObservableObject {
    struct Source: Identifiable, Hashable { let id = UUID(); let title: String; let url: URL }
    struct Message: Identifiable {
        let id = UUID()
        let fromUser: Bool
        var text: String
        var sources: [Source] = []
    }

    @Published var messages: [Message] = []
    @Published var input = ""
    @Published var thinking = false

    var available: Bool { TranscriptEnricher.isAvailable }

    private var session: LanguageModelSession?
    private let instructions = """
    You answer questions about the user's own recorded calls, using ONLY the provided context \
    passages. You may make reasonable connections between related facts in the context. Cite the \
    call by name when you answer. If the answer is genuinely not in the context, say you don't \
    have it in these calls. Be concise and specific.
    """

    func send() async {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !thinking else { return }
        input = ""
        messages.append(Message(fromUser: true, text: question))
        thinking = true
        defer { thinking = false }

        guard available else {
            messages.append(Message(fromUser: false,
                text: "On-device answering needs Apple Intelligence enabled (System Settings › Apple Intelligence & Siri)."))
            return
        }

        let chunks = IndexStore.shared?.context(for: question, limit: 6) ?? []
        let sources = distinctSources(chunks)
        let context = chunks.isEmpty
            ? "(no matching passages found)"
            : chunks.map { "[\($0.title.isEmpty ? "Untitled" : $0.title) — \(clock($0.startMs))\($0.speaker.isEmpty ? "" : ", \($0.speaker)")] \($0.text)" }
                .joined(separator: "\n\n")

        if session == nil { session = LanguageModelSession(instructions: instructions) }
        do {
            let response = try await session!.respond(to: "Context:\n\(context)\n\nQuestion: \(question)")
            messages.append(Message(fromUser: false, text: response.content, sources: sources))
        } catch {
            messages.append(Message(fromUser: false, text: "I couldn't answer that one."))
        }
    }

    private func distinctSources(_ chunks: [ContextChunk]) -> [Source] {
        var seen = Set<String>()
        return chunks.compactMap { chunk in
            guard seen.insert(chunk.path).inserted else { return nil }
            return Source(title: chunk.title.isEmpty ? "Untitled call" : chunk.title,
                          url: URL(fileURLWithPath: chunk.path))
        }
    }

    private func clock(_ ms: Int) -> String {
        let t = ms / 1000
        return String(format: "%d:%02d", t / 60, t % 60)
    }
}
