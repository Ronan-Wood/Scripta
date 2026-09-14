import AVFoundation
import Foundation
import os

/// A per-buffer audio callback, held so it can be swapped while capture is running WITHOUT the
/// stored closure growing every time it is read.
///
/// THIS TYPE EXISTS BECAUSE A LOCK CANNOT HOLD A CLOSURE. Both capture classes stored their
/// `onBuffer` directly in `OSAllocatedUnfairLock<((AVAudioPCMBuffer) -> Void)?>` and read it back
/// with `withLock { $0 }`.
///
/// THE BODY ASSIGNS NOTHING, AND THAT IS NOT ENOUGH. `withLock` takes `(inout State) -> R`, and an
/// `inout` argument that needs a representation change is passed by COPY-IN/COPY-OUT: the callee
/// gets a reabstracted temporary and the temporary is written back on return, whether or not the
/// body touched it. The box is generic over a FUNCTION type, so the copy out reabstracts through
/// `@in_guaranteed -> @out` and the write-back reabstracts through `@guaranteed -> ()` — and the
/// value now in the box is one thunk pair deeper than the one that went in. A read that looks pure
/// is a read-modify-write, permanently. Worth stating precisely, because "a getter cannot
/// accumulate" is the obvious objection and it is wrong: the accumulation is MEASURED on the
/// pure-call path, with no assignment anywhere in the loop (`AudioCallbackBoxTests`).
///
/// It crashed the app for real: SIGBUS on the stack guard page of the system-audio queue, the crash
/// report's `recursionInfoArray` recording `depth: 6619` with a keyFrame that is exactly the
/// `@in_guaranteed AVAudioPCMBuffer -> @out ()` thunk. `depth` COUNTS REPETITIONS, NOT FRAMES,
/// which the report's own numbers settle: `hottestElided: 26` and `coldestElided: 13251` means
/// 13,225 frames across 6,619 repetitions — 1.998 each, matching the measured two-frames-per-call
/// rate. One repetition is one buffer, so 6,619 buffers is a couple of minutes of recording, not a
/// slow leak over hours.
///
/// THE CLOSURE IS STORED AS AN OPTIONAL INSIDE A CLASS, and both halves are load-bearing. The class
/// is what the lock stores, so the lock only ever round-trips a REFERENCE, which has nothing to
/// reabstract. Holding the OPTIONAL inside it (rather than a non-optional `call` and a nil `Held`)
/// is what keeps the getter flat too: returning `Optional<fn>` read straight out of a stored
/// `Optional<fn>` needs no bridging, whereas lifting a non-optional closure into an Optional on the
/// way out and lowering it back on the way in reabstracts once per round trip. That middle shape
/// fixes the crash and leaves a second, quieter version of the same trap for whoever first writes
/// `capture.onBuffer = capture.onBuffer.map { … }` to add a tee or a filter.
///
/// IT IS NOT GENERIC, AND THAT IS THE THIRD LOAD-BEARING CHOICE. This was first written as
/// `CallbackBox<Payload>` so it could live in the Foundation-only shared target — and being generic
/// puts `Held.call` back at maximal abstraction, so reading it out to a concrete function type
/// reabstracts and the ROUND-TRIP PATH ACCUMULATES AGAIN. Measured, and caught by the round-trip
/// test the moment it was generalised: 72 → 10,072 frames over 5,000 round trips. Concrete over
/// `AVAudioPCMBuffer`, in this target rather than the shared one, is what keeps both paths flat.
/// The shared target stays Foundation-only, which is its whole point.
///
/// IT LIVES IN CORE SO IT CAN BE TESTED. Written beside the capture classes first, in the app
/// target, which has no test target — so the measurement that justifies its shape lived only in
/// this comment and nothing failed if someone "simplified" it back.
public final class AudioCallbackBox: @unchecked Sendable {
    /// `@unchecked` rather than `Sendable`-checked away: the closure genuinely crosses threads —
    /// the capture queue invokes it while a background task attaches it — which is what the lock is
    /// for. Safety is the lock, not the type system, and every access below goes through it.
    private final class Held: @unchecked Sendable {
        let call: ((AVAudioPCMBuffer) -> Void)?
        init(_ call: ((AVAudioPCMBuffer) -> Void)?) { self.call = call }
    }

    private let stored = OSAllocatedUnfairLock<Held>(initialState: Held(nil))

    public init() {}

    public var callback: ((AVAudioPCMBuffer) -> Void)? {
        get { stored.withLock { $0 }.call }
        // ALLOCATED BEFORE THE LOCK, AND THE OLD ONE RELEASED AFTER IT. Both halves keep the
        // critical section to a pointer store, and only the first is obvious: `Held(newValue)` is a
        // malloc, so building it inside would put the allocator on the audio path's contention.
        // The second is the one an earlier version got wrong — `withLock { $0 = held }` RELEASES the
        // previous `Held` as part of the assignment, so the old closure's context and everything it
        // captured (a converter, a stream continuation) ran their deinit chain while holding the
        // lock the capture queue takes on every buffer. Handing the old value out of the closure
        // keeps it alive past the unlock; it dies at the end of this setter, off the lock.
        set {
            let held = Held(newValue)
            let previous = stored.withLock { state -> Held in
                let previous = state
                state = held
                return previous
            }
            withExtendedLifetime(previous) {}
        }
    }

    /// Reads once, then calls OUTSIDE the lock. The callback runs live transcription — a format
    /// conversion and a stream yield — so holding the lock across it would make a live-transcription
    /// attach wait for the whole feed call rather than for a pointer store. The attach is the side
    /// that would pay: it runs on a background `Task` while the capture queue is invoking this.
    public func callIfSet(_ buffer: AVAudioPCMBuffer) {
        stored.withLock { $0 }.call?(buffer)
    }
}
