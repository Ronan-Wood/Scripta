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
    /// Set by `cancel()` even after `started` has flipped false (mid-`finish()`), so a save
    /// already in flight can still notice a late Esc and stop short of writing the note.
    private(set) var discarded = false

    init(group: String) {
        self.group = group
    }

    func start() async {
        do {
            let vocab = EntityRegistry.recognitionVocab(group: group)
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
            // `started` is still false here, so cancel()/finish() would no-op — tear the
            // transcriber down ourselves, or a tap.start() failure after a successful
            // transcriber.start() leaks a live speech session for the rest of the app's life.
            // Safe to call unconditionally: stop() is a no-op against an unstarted transcriber.
            await transcriber.stop()
            state = .failed(error.localizedDescription)
        }
    }

    var hasText: Bool { !finalized.isEmpty || !partial.isEmpty }

    /// Stops listening, waits for the tail to finalize, and returns the raw dictated text —
    /// nil when nothing usable was heard, INCLUDING when a late `cancel()` (Esc/panel close)
    /// landed while this was draining the transcriber. Idempotent via `started`.
    func finish() async -> String? {
        guard started else { return nil }
        started = false
        state = .saving
        tap.stop()
        await transcriber.finish()
        guard !discarded else { return nil }
        // A leftover partial is the un-finalized tail (a finalized line clears it), so keep it.
        let text = (finalized + (partial.isEmpty ? [] : [partial]))
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return text.isEmpty ? nil : text
    }

    /// Discards the capture. Safe to call in any state, including mid-`start()` or mid-`finish()`
    /// — `discarded` is unconditional so a save already past the `finish()` gate (into cleanup)
    /// can still be caught by the caller via `discarded` before it writes anything.
    func cancel() {
        cancelled = true
        discarded = true
        guard started else { return }
        started = false
        tap.stop()
        let transcriber = transcriber
        Task.detached { await transcriber.stop() }
    }
}
