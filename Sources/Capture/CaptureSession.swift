import Foundation
import ScriptaCore

/// One Quick Capture: mic → live transcription → dictated text. Owns the tap + transcriber
/// lifecycle; the view observes `state`/text and the controller drives finish/cancel.
///
/// Unlike the recording pipeline, the live text here IS the artifact — so the transcriber gets
/// the workspace vocabulary bias (the call pane skips it because its live text is cosmetic and
/// the file pass re-biases), and teardown waits for the final results instead of cancelling.
@MainActor
final class CaptureSession: ObservableObject {
    enum State {
        case starting
        case listening
        case saving
        case failed(String)
    }

    @Published var state: State = .starting
    @Published var finalized: [String] = []
    @Published var partial = ""

    /// Workspace snapshotted at open — the record-time-capture rule: a mid-capture workspace
    /// switch must not split the vocab bias from the note the text lands in.
    let group: String

    private let tap = MicrophoneTap()
    private let transcriber = LiveTranscriber()
    private var started = false
    private var cancelled = false

    init(group: String) {
        self.group = group
    }

    func start() async {
        do {
            // Same confirmed-only bias set the recording path uses (MenuController's start):
            // unreviewed junk never steers recognition. Domain vocabulary rides along because
            // this path bypasses SpeechEngine.transcribe, which normally adds it.
            let vocab = Array(Set(
                (AppSettings.domainVocabulary
                    + EntityRegistry.shared.confirmedAliases(group: group)
                    + EntityRegistry.shared.termVocab(group: group))
                    .map { $0.trimmingCharacters(in: .whitespaces) }
                    .filter { !$0.isEmpty }
            ))
            transcriber.onUpdate = { [weak self] finalized, partial in
                guard let self else { return }
                if let finalized { self.finalized = finalized }
                self.partial = partial
            }
            try await transcriber.start(contextualStrings: vocab)
            // The user may have hit Esc during the (possibly slow) transcriber start.
            guard !cancelled else { await transcriber.stop(); return }
            tap.onBuffer = transcriber.feed
            try tap.start()
            started = true
            state = .listening
        } catch {
            state = .failed(error.localizedDescription)
        }
    }

    var hasText: Bool { !finalized.isEmpty || !partial.isEmpty }

    /// Stops listening, waits for the tail to finalize, and returns the raw dictated text —
    /// nil when nothing usable was heard. Idempotent via `started`.
    func finish() async -> String? {
        guard started else { return nil }
        started = false
        state = .saving
        tap.stop()
        await transcriber.finish()
        // A leftover partial is the un-finalized tail (a finalized line clears it), so keep it.
        let text = (finalized + (partial.isEmpty ? [] : [partial]))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Discards the capture. Safe to call in any state, including mid-`start()`.
    func cancel() {
        cancelled = true
        guard started else { return }
        started = false
        tap.stop()
        let transcriber = transcriber
        Task.detached { await transcriber.stop() }
    }
}
