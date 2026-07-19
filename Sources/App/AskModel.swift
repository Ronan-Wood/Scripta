import Foundation
import ScriptaCore
import FoundationModels

/// Clovis — the on-device assistant over your calls: retrieves relevant passages from the index,
/// then answers over them with Apple's Foundation Models (or the opt-in local endpoint) — fully
/// local. Uses the grounding prompt validated to connect related facts while refusing what isn't
/// in the retrieved context. Conversations persist per workspace (the privacy wall applies to
/// chat history too: a workspace's conversations are invisible from any other).
@MainActor
final class AskModel: ObservableObject {
    struct Source: Identifiable, Hashable, Codable {
        var id = UUID()
        let title: String
        let url: URL
        let startMs: Int
    }
    /// Deterministic answer-support rating, derived from retrieval — NOT model self-report
    /// (a 3B's stated confidence is theater). Measures how well-grounded the answer is:
    /// spoken-passage count, call spread, and whether fallback retrieval was needed.
    enum Grounding: String, Codable {
        case strong, moderate, thin

        var label: String {
            switch self {
            case .strong: return "Well grounded"
            case .moderate: return "Partly grounded"
            case .thin: return "Thin grounding — check the sources"
            }
        }
    }

    struct Message: Identifiable, Codable {
        var id = UUID()
        let fromUser: Bool
        var text: String
        var sources: [Source] = []
        /// The engine that produced this answer (badge under the bubble); nil for user messages.
        var engineLabel: String? = nil
        var grounding: Grounding? = nil
    }
    struct Conversation: Identifiable, Codable {
        var id = UUID()
        var title = "New conversation"
        var created = Date()
        /// The workspace this conversation happened in — listed only there.
        var group = ""
        var messages: [Message] = []
    }

    @Published var conversations: [Conversation] = []
    @Published var currentID: UUID?
    @Published var messages: [Message] = []
    @Published var input = ""
    @Published var thinking = false

    /// Bumped whenever `messages` is swapped to another conversation/workspace. An in-flight
    /// `send()` captures it and abandons its writes if it changes, so a mid-stream switch can't
    /// stream into — or persist — the wrong conversation (audit H3).
    private var conversationEpoch = 0

    /// The workspace `messages` currently belong to (nil until the first `activate`). Tracked so a
    /// workspace switch flushes the OUTGOING conversation under its own group — `AppSettings.activeGroup`
    /// has already advanced to the destination by the time `activate` runs (audit H3, invariant 5).
    private var currentGroup: String?

    init() {
        conversations = Self.load()
        pruneExpiredConversations()
    }

    /// Drops conversations older than the user's retention window (Settings). 0 = keep forever.
    /// `nowProvider` is injectable for tests; the app passes the real clock.
    func pruneExpiredConversations(now: Date = Date()) {
        let days = AppSettings.conversationRetentionDays
        guard days > 0 else { return }
        let cutoff = now.addingTimeInterval(-Double(days) * 86_400)
        let before = conversations.count
        conversations.removeAll { $0.created < cutoff }
        if conversations.count != before {
            if !conversations.contains(where: { $0.id == currentID }) {
                // Clear the model session and workspace too, or a later activate(sameGroup) early-returns
                // on the stale currentGroup and keeps the pruned conversation's `chat` context.
                currentID = nil; messages = []; conversationEpoch &+= 1; currentGroup = nil; chat = nil; thinking = false
            }
            Self.save(conversations)
        }
    }

    /// Answering is available if the endpoint is assigned for Ask, or Apple Intelligence is on.
    var available: Bool { EngineRouter.usesEndpoint(for: .ask) || TranscriptEnricher.isAvailable }

    private var chat: ChatConversing?
    private var sizeClass: SizeClass = .compact
    private var engineLabel: String?
    private var usingEndpoint = false

    // MARK: - Conversations (persisted, workspace-scoped)

    /// Conversations belonging to one workspace, newest first.
    func conversations(in group: String) -> [Conversation] {
        conversations.filter { $0.group == group }.sorted { $0.created > $1.created }
    }

    /// Entering a workspace (or first showing the pane): resume its latest conversation.
    func activate(group: String) {
        if currentGroup == group { return }   // already in this workspace — nothing to switch
        conversationEpoch &+= 1
        thinking = false   // any in-flight send for the outgoing conversation is now abandoned
        syncCurrent(into: currentGroup ?? group)   // flush the OUTGOING conversation under ITS group
        if let latest = conversations(in: group).first {
            currentID = latest.id
            messages = latest.messages
        } else {
            currentID = nil
            messages = []
        }
        chat = nil   // fresh model session; the transcript above is display history
        currentGroup = group
    }

    func select(_ id: UUID, group: String) {
        guard id != currentID else { return }
        syncCurrent(into: group)
        guard let conversation = conversations.first(where: { $0.id == id }) else { return }
        conversationEpoch &+= 1   // only after we know we're actually reassigning `messages`
        thinking = false
        currentID = conversation.id
        messages = conversation.messages
        currentGroup = group
        chat = nil
    }

    func newConversation(group: String) {
        conversationEpoch &+= 1
        thinking = false
        syncCurrent(into: group)
        currentID = nil
        messages = []
        currentGroup = group
        input = ""
        chat = nil
    }

    func delete(_ id: UUID, group: String) {
        conversations.removeAll { $0.id == id }
        if currentID == id {
            conversationEpoch &+= 1
            thinking = false
            currentID = conversations(in: group).first?.id
            messages = conversations.first(where: { $0.id == currentID })?.messages ?? []
            currentGroup = group
            chat = nil
        }
        Self.save(conversations)
    }

    /// Writes the working transcript back into its conversation (creating one on first use)
    /// and persists. Cheap: called on send completion and conversation switches.
    private func syncCurrent(into group: String) {
        defer { Self.save(conversations) }
        guard !messages.isEmpty else { return }
        if let idx = conversations.firstIndex(where: { $0.id == currentID }) {
            conversations[idx].messages = messages
            return
        }
        var conversation = Conversation(group: group, messages: messages)
        if let first = messages.first(where: { $0.fromUser })?.text {
            conversation.title = String(first.prefix(44))
        }
        conversations.insert(conversation, at: 0)
        currentID = conversation.id
    }

    private static var storeURL: URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Scripta", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent("conversations.json")
    }

    private static func load() -> [Conversation] {
        guard let data = try? Data(contentsOf: storeURL) else { return [] }
        return (try? JSONDecoder().decode([Conversation].self, from: data)) ?? []
    }

    private static func save(_ conversations: [Conversation]) {
        if let data = try? JSONEncoder().encode(conversations) {
            try? data.write(to: storeURL, options: .atomic)
        }
    }

    // MARK: - Asking

    func send() async {
        let question = input.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !question.isEmpty, !thinking else { return }
        input = ""
        let previousUser = messages.last(where: { $0.fromUser })?.text
        messages.append(Message(fromUser: true, text: question))
        let epoch = conversationEpoch

        // Only require Apple Intelligence when we're not using the local endpoint.
        if !EngineRouter.usesEndpoint(for: .ask), let unavailable = TranscriptEnricher.availabilityMessage {
            messages.append(Message(fromUser: false, text: unavailable))
            syncCurrent(into: AppSettings.activeGroup)
            return
        }

        ensureChat()

        // Retrieve. If the question alone finds nothing — a pronoun-laden follow-up like "what
        // else did she say about it?" — fall back to including the previous turn's terms.
        let limit = PromptCatalog.askContextChunks(sizeClass)
        let group = AppSettings.activeGroup   // hard-scoped to the active workspace (the privacy wall)
        var usedFallback = false
        var chunks = await Retriever.context(for: question, group: group, limit: limit)
        if chunks.isEmpty, let previousUser {
            chunks = await Retriever.context(for: previousUser + " " + question, group: group, limit: limit)
            usedFallback = true
        }

        // If the visible conversation was swapped out during retrieval, abandon rather than append
        // or stream into the wrong conversation (audit H3).
        guard epoch == conversationEpoch else { return }

        // Short-circuit empty retrieval: answer deterministically instead of spending an inference
        // on "(nothing found)" and risking a source-less hallucination.
        guard !chunks.isEmpty else {
            // Scoped + truthful: never claim "nothing in your calls" (false across the partition).
            // Blind: offer to widen without asserting other workspaces actually contain a match.
            let ws = group.isEmpty ? "the Ungrouped workspace" : "the \(group) workspace"
            var text = "I couldn’t find anything about that in \(ws) — try different words, or a person’s name."
            if !AppModel.shared.availableGroups().isEmpty {
                text += " You can switch workspaces, or use Calls → “Search all workspaces” to look across them."
            }
            messages.append(Message(fromUser: false, text: text))
            syncCurrent(into: group)
            return
        }

        let sources = distinctSources(chunks)
        let passages = chunks.filter { !$0.isTopic }.count
        let grounding: Grounding = (usedFallback || passages == 0) ? .thin
                                 : passages >= 3 ? .strong : .moderate
        let context = chunks.map(Self.label).joined(separator: "\n\n")
        // Vocabulary glosses ride along when their term appears in the question or the retrieved
        // text — the user's own definitions, so the model stops fumbling domain jargon.
        let glossary = Self.glossary(question: question, chunks: chunks, group: group)
        let prompt = (glossary.isEmpty ? "" : "Glossary (the user's own definitions):\n\(glossary)\n\n")
            + "Context:\n\(context)\n\nQuestion: \(question)"

        thinking = true
        let firstAnswer = !messages.contains { !$0.fromUser && !$0.text.isEmpty }
        let index = messages.count
        messages.append(Message(fromUser: false, text: "", engineLabel: engineLabel))
        // After every await below, re-check the epoch before touching messages[index]: a mid-stream
        // conversation/workspace switch reassigns `messages`, so a stale index write would corrupt
        // (and persist into) the wrong conversation — or crash out of bounds (audit H3).
        do {
            try await run(prompt, into: index, epoch: epoch)
            guard epoch == conversationEpoch, index < messages.count else { return }   // switcher owns the thinking flag now
            messages[index].sources = sources
            messages[index].grounding = grounding
        } catch {
            guard epoch == conversationEpoch, index < messages.count else { return }   // switcher owns the thinking flag now
            // Ask, first message → auto-fall back to Apple FM with a notice, and the answer still
            // arrives. Mid-conversation → no silent swap: keep the partial text, hint at retry.
            if firstAnswer && usingEndpoint {
                resetToAppleFM()
                messages[index].text = ""
                messages[index].engineLabel = engineLabel
                do {
                    try await run(prompt, into: index, epoch: epoch)
                    guard epoch == conversationEpoch, index < messages.count else { return }   // switcher owns the thinking flag now
                    messages[index].sources = sources
                    messages[index].grounding = grounding
                }
                catch {
                    guard epoch == conversationEpoch, index < messages.count else { return }   // switcher owns the thinking flag now
                    messages[index].text = Self.errorText(error)
                }
            } else if messages[index].text.isEmpty {
                messages[index].text = Self.errorText(error)
            } else {
                messages[index].text += "\n\n_(Interrupted — send again to retry.)_"
            }
        }
        thinking = false
        syncCurrent(into: group)
    }

    /// Resolves the Ask engine once per conversation (multi-turn history lives inside the chat).
    private func ensureChat() {
        guard chat == nil else { return }
        let engine = EngineRouter.chatEngine(for: .ask)
        sizeClass = engine.sizeClass
        engineLabel = engine.label
        usingEndpoint = EngineRouter.usesEndpoint(for: .ask)
        chat = engine.makeChat(instructions: PromptCatalog.askInstructions(sizeClass))
    }

    private func resetToAppleFM() {
        let engine = AppleFMEngine()
        sizeClass = engine.sizeClass
        engineLabel = "\(engine.label) (fallback)"
        usingEndpoint = false
        chat = engine.makeChat(instructions: PromptCatalog.askInstructions(sizeClass))
    }

    /// Streams cumulative snapshots into the placeholder message so tokens appear as they generate.
    private func run(_ prompt: String, into index: Int, epoch: Int) async throws {
        for try await snapshot in chat!.stream(prompt) {
            guard epoch == conversationEpoch, index < messages.count else { return }
            messages[index].text = snapshot
            thinking = false   // first token has arrived
        }
    }

    private static func errorText(_ error: Error) -> String {
        (error as? EngineError)?.errorDescription ?? "Something went wrong — try again."
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

    /// Gloss lines for vocabulary terms present in the question or retrieved text (capped at 6).
    private static func glossary(question: String, chunks: [ContextChunk], group: String) -> String {
        guard let store = IndexStore.shared else { return "" }
        let glosses = store.termGlosses(group: group)
        guard !glosses.isEmpty else { return "" }
        let haystack = (question + " " + chunks.map(\.text).joined(separator: " ")).lowercased()
        return glosses
            .filter { haystack.contains($0.term.lowercased()) }
            .prefix(6)
            .map { "\($0.term) — \($0.gloss)" }
            .joined(separator: "\n")
    }

    private func distinctSources(_ chunks: [ContextChunk]) -> [Source] {
        var seen = Set<String>()
        return chunks.compactMap { chunk in
            guard seen.insert(chunk.path).inserted else { return nil }
            return Source(title: chunk.title.isEmpty ? "Untitled call" : chunk.title,
                          url: URL(fileURLWithPath: chunk.path), startMs: chunk.startMs)
        }
    }
}
