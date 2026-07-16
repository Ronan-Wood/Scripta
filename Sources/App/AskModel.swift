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
        let previousUser = messages.last(where: { $0.fromUser })?.text
        messages.append(Message(fromUser: true, text: question))

        if let unavailable = TranscriptEnricher.availabilityMessage {
            messages.append(Message(fromUser: false, text: unavailable))
            return
        }

        // Retrieve. If the question alone finds nothing — a pronoun-laden follow-up like "what
        // else did she say about it?" — fall back to including the previous turn's terms.
        var chunks = IndexStore.shared?.context(for: question, limit: 6) ?? []
        if chunks.isEmpty, let previousUser {
            chunks = IndexStore.shared?.context(for: previousUser + " " + question, limit: 6) ?? []
        }

        // Short-circuit empty retrieval: answer deterministically instead of spending an inference
        // on "(nothing found)" and risking a source-less hallucination. Session untouched.
        guard !chunks.isEmpty else {
            messages.append(Message(fromUser: false,
                text: "I couldn’t find anything about that in your calls — try different words, or a person’s name."))
            return
        }

        let sources = distinctSources(chunks)
        let context = chunks.map(Self.label).joined(separator: "\n\n")

        thinking = true
        if session == nil { session = LanguageModelSession(instructions: instructions) }
        let index = messages.count
        messages.append(Message(fromUser: false, text: ""))
        do {
            try await streamWithRecovery(context: context, question: question, into: index)
            messages[index].sources = sources
        } catch let error as LanguageModelSession.GenerationError {
            messages[index].text = Self.message(for: error)
        } catch {
            messages[index].text = "Something went wrong — try again."
        }
        thinking = false
    }

    /// Streams the answer into `messages[index]`; on context-window overflow rebuilds the session
    /// once, discards the partial text, and retries — a fresh context block always fits. Without
    /// this the chat throws after a handful of turns and then fails every later turn.
    private func streamWithRecovery(context: String, question: String, into index: Int) async throws {
        let prompt = "Context:\n\(context)\n\nQuestion: \(question)"
        do {
            try await stream(prompt, into: index)
        } catch let error as LanguageModelSession.GenerationError {
            guard case .exceededContextWindowSize = error else { throw error }
            session = LanguageModelSession(instructions: instructions)
            messages[index].text = ""
            try await stream(prompt, into: index)
        }
    }

    /// Streams snapshots into the placeholder message so tokens appear as they generate.
    private func stream(_ prompt: String, into index: Int) async throws {
        for try await snapshot in session!.streamResponse(to: prompt) {
            guard index < messages.count else { return }
            messages[index].text = snapshot.content
            thinking = false   // first token has arrived
        }
    }

    private static func message(for error: LanguageModelSession.GenerationError) -> String {
        if case .guardrailViolation = error { return "I can’t answer that one." }
        return "Something went wrong — try again."
    }

    /// Context label — includes the call date so temporal questions ("when did I last…") can be
    /// grounded, and marks topic-fusion passages so a summary isn't cited as spoken at [0:00].
    private static func label(_ c: ContextChunk) -> String {
        let title = c.title.isEmpty ? "Untitled" : c.title
        let date = c.date.isEmpty ? "" : ", \(c.date)"
        if c.isTopic { return "[\(title)\(date), topic] \(c.text)" }
        let speaker = c.speaker.isEmpty ? "" : ", \(c.speaker)"
        return "[\(title)\(date), \(clock(c.startMs))\(speaker)] \(c.text)"
    }

    private static func clock(_ ms: Int) -> String {
        let t = ms / 1000
        return String(format: "%d:%02d", t / 60, t % 60)
    }

    private func distinctSources(_ chunks: [ContextChunk]) -> [Source] {
        var seen = Set<String>()
        return chunks.compactMap { chunk in
            guard seen.insert(chunk.path).inserted else { return nil }
            return Source(title: chunk.title.isEmpty ? "Untitled call" : chunk.title,
                          url: URL(fileURLWithPath: chunk.path))
        }
    }
}
