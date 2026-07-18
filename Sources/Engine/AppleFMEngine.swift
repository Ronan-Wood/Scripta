import Foundation
import FoundationModels

/// The zero-setup default engine: Apple's on-device Foundation Models. `sizeClass` is `.compact`
/// today and flips to `.capable` for free on newer silicon (AFM Core Advanced) — same type, same
/// API, so no new engine is needed when the Apple tier grows.
final class AppleFMEngine: ChatEngine, EnrichEngine {
    var sizeClass: SizeClass { AppSettings.appleFMSizeClass }
    var label: String { "Apple Intelligence" }

    func makeChat(instructions: String) -> ChatConversing {
        AppleFMChat(instructions: instructions)
    }

    func digest(transcript: String, sizeClass: SizeClass) async -> TranscriptDigest? {
        guard TranscriptEnricher.isAvailable else { return nil }
        let prompt = PromptCatalog.enrichPrompt(transcript, sizeClass: sizeClass)
        guard prompt.count > 20 else { return nil }
        do {
            let session = LanguageModelSession()
            let digest = try await session.respond(to: prompt, generating: TranscriptDigest.self).content
            return TranscriptEnricher.normalize(digest)
        } catch {
            return nil
        }
    }
}

/// One Apple FM conversation. Streams cumulative snapshots and recovers from a context-window
/// overflow by rebuilding the session once (a fresh context block always fits).
private final class AppleFMChat: ChatConversing {
    private let instructions: String
    private var session: LanguageModelSession?

    init(instructions: String) { self.instructions = instructions }

    func stream(_ prompt: String) -> AsyncThrowingStream<String, Error> {
        AsyncThrowingStream { continuation in
            let task = Task {
                if session == nil { session = LanguageModelSession(instructions: instructions) }
                do {
                    try await run(prompt, into: continuation)
                    continuation.finish()
                } catch let error as LanguageModelSession.GenerationError {
                    if case .exceededContextWindowSize = error {
                        session = LanguageModelSession(instructions: instructions)
                        do { try await run(prompt, into: continuation); continuation.finish() }
                        catch { continuation.finish(throwing: error) }
                    } else {
                        continuation.finish(throwing: error)
                    }
                } catch {
                    continuation.finish(throwing: error)
                }
            }
            continuation.onTermination = { @Sendable _ in task.cancel() }   // cancel FM gen on stop (audit L10)
        }
    }

    private func run(_ prompt: String, into continuation: AsyncThrowingStream<String, Error>.Continuation) async throws {
        for try await snapshot in session!.streamResponse(to: prompt) {
            continuation.yield(snapshot.content)
        }
    }
}
