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
    /// The capture buffer: freely editable (type, speak, or both — Save takes this verbatim).
    /// Newly finalized dictation is appended at the END, never splicing into wherever the user
    /// is editing, so a live update can't clobber an in-progress edit or cursor position.
    @Published var text = ""
    /// The in-progress (not-yet-finalized) recognition preview — shown separately from `text`,
    /// never merged into it until it finalizes (or `finish()` folds a genuine trailing tail).
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
    /// How many of LiveTranscriber's (wholesale-replaced) finalized lines have already been
    /// merged into `text`, so each update appends only the delta.
    private var mergedFinalizedCount = 0

    init(group: String) {
        self.group = group
    }

    func start() async {
        do {
            let vocab = EntityRegistry.recognitionVocab(group: group)
            transcriber.onUpdate = { [weak self] finalized, partial in
                guard let self else { return }
                if let finalized, finalized.count > self.mergedFinalizedCount {
                    let addition = finalized[self.mergedFinalizedCount...].joined(separator: " ")
                    self.text += (self.text.isEmpty ? "" : " ") + addition
                    self.mergedFinalizedCount = finalized.count
                }
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

    var hasText: Bool { !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty || !partial.isEmpty }

    /// Stops listening, waits for the tail to finalize, and returns the capture text (typed +
    /// dictated) — nil when nothing usable was heard/typed, INCLUDING when a late `cancel()`
    /// (Esc/panel close) landed while this was draining the transcriber. Idempotent via `started`.
    func finish() async -> String? {
        guard started else { return nil }
        started = false
        state = .saving
        tap.stop()
        await transcriber.finish()
        guard !discarded else { return nil }
        // A leftover partial is the un-finalized tail (finalizing normally clears it via
        // onUpdate before transcriber.finish() returns) — fold it in rather than lose it.
        if !partial.isEmpty {
            text += (text.isEmpty ? "" : " ") + partial
            partial = ""
        }
        let result = text.trimmingCharacters(in: .whitespacesAndNewlines)
        return result.isEmpty ? nil : result
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
