import XCTest
import AVFoundation
import os
@testable import ScriptaCore

/// The regression gate for the audio-path stack overflow.
///
/// WHAT CRASHED. Both capture classes held their per-buffer callback in
/// `OSAllocatedUnfairLock<((Buffer) -> Void)?>` and read it with `withLock { $0 }`. `withLock`
/// takes its state `inout`, and an `inout` argument needing a representation change is passed by
/// copy-in/copy-out — so a body that only reads still writes the value back, reabstracted, one
/// thunk pair deeper. Once per audio buffer. The app died with SIGBUS on the stack guard page after
/// a couple of minutes of recording.
///
/// WHY IT IS A TEST AND NOT A COMMENT. The measurement that justifies `CallbackBox`'s shape used to
/// live only in its doc comment, in a target with no tests, so nothing failed if someone
/// "simplified" it back. Both shapes below are one edit away from being reintroduced and neither
/// fails anything else: the app still builds, still records, still transcribes, and dies minutes in.
///
/// HOW IT MEASURES. ABSOLUTE depth at the leaf after k operations, compared across k. Measuring the
/// delta between two late samples reads zero for every shape — including the broken ones — and
/// passes silently; that mistake was made once while developing this fix and is the reason the
/// helper takes k rather than sampling twice.
final class AudioCallbackBoxTests: XCTestCase {

    /// A real buffer, in the real format the system-audio path captures at.
    private func buffer() -> AVAudioPCMBuffer {
        let format = AVAudioFormat(standardFormatWithSampleRate: 48_000, channels: 2)!
        return AVAudioPCMBuffer(pcmFormat: format, frameCapacity: 512)!
    }

    /// Depth at the leaf, on the call that follows `k` prior operations.
    ///
    /// IT SYMBOLICATES ONCE, on the final call only, and the guard is what makes this suite usable.
    /// Walking the stack costs time proportional to its depth — so a probe that measured on every
    /// call took 20 MINUTES to fail against the broken shape (10,000 frames × 5,000 calls) while
    /// taking eight seconds to pass against the correct one. A regression gate that only becomes
    /// slow when it is about to fail is one that gets disabled by whoever is in a hurry, which is
    /// exactly the person it exists for.
    /// A LIVENESS ANCHOR, because every gate here is a cross-k EQUALITY and equality is satisfied
    /// by a box that never calls the closure at all: `observed` would stay 0 on both sides and
    /// `XCTAssertEqual(0, 0)` would pass for an implementation with no delivery whatsoever. So this
    /// fails outright if the final call does not reach the leaf.
    private func depth(after k: Int, _ operate: (AudioCallbackBox) -> Void,
                       file: StaticString = #filePath, line: UInt = #line) -> Int {
        var measuring = false
        var observed = 0
        let box = AudioCallbackBox()
        box.callback = { _ in if measuring { observed = Thread.callStackSymbols.count } }
        for _ in 0..<k { operate(box) }
        measuring = true
        box.callIfSet(buffer())
        XCTAssertGreaterThan(observed, 0,
                             "the callback never ran, so the depth gates below compare 0 to 0",
                             file: file, line: line)
        return observed
    }

    /// THE CRASH PATH: invoking the callback, with no assignment anywhere in the loop.
    ///
    /// 5,000 is chosen to sit past the 6,619/2 repetitions the crash report recorded while staying
    /// fast; the shape either accumulates from the first call or never does.
    func testInvokingTheCallbackDoesNotDeepenTheStack() {
        let first = depth(after: 0) { $0.callIfSet(buffer()) }
        let later = depth(after: 5_000) { $0.callIfSet(buffer()) }
        XCTAssertEqual(first, later,
                       "the stored closure grew while only being CALLED — \(first) → \(later) "
                       + "frames. This is the shape that crashed the app.")
    }

    /// THE QUIETER TRAP. A `Held` holding a NON-optional closure fixes the call path and still
    /// accumulates here, because lifting a non-optional closure into an `Optional` on the way out
    /// and lowering it back on the way in reabstracts once per round trip. Nothing in the app does
    /// this today — it is one `capture.onBuffer = capture.onBuffer.map { … }` away, which is what
    /// adding a tee or a filter looks like.
    func testReadingAndWritingTheCallbackBackDoesNotDeepenTheStack() {
        let first = depth(after: 0) { box in let held = box.callback; box.callback = held }
        let later = depth(after: 5_000) { box in let held = box.callback; box.callback = held }
        XCTAssertEqual(first, later,
                       "the stored closure grew across read-then-write round trips — \(first) → "
                       + "\(later) frames.")
    }

    /// The depth must not depend on how the callback is reached, or the property getter is a second
    /// accumulating path beside the one `callIfSet` guards.
    func testTheGetterAndTheDirectCallAgreeOnDepth() {
        let viaHelper = depth(after: 2_000) { $0.callIfSet(buffer()) }
        let viaGetter = depth(after: 2_000) { $0.callback?(buffer()) }
        XCTAssertEqual(viaHelper, viaGetter,
                       "calling through the property accumulates where callIfSet does not")
    }

    // MARK: - The mechanism, pinned by reproducing it

    /// THE OLD SHAPE, REBUILT HERE, so the claim "a read that looks pure is a read-modify-write"
    /// is measured rather than asserted. Without this the suite only shows the FIXED box is flat,
    /// which is equally consistent with the bug never having existed — and `AudioCallbackBox`'s doc
    /// comment cites this file as the evidence for the mechanism.
    ///
    /// It also fails if a future Swift makes the reabstraction go away, which is the right way to
    /// learn that: the fix's justification would then be stale and worth revisiting.
    private final class LockHoldingTheClosure {
        private let stored = OSAllocatedUnfairLock<((AVAudioPCMBuffer) -> Void)?>(initialState: nil)
        var callback: ((AVAudioPCMBuffer) -> Void)? {
            get { stored.withLock { $0 } }
            set { stored.withLock { $0 = newValue } }
        }
        func callIfSet(_ b: AVAudioPCMBuffer) { stored.withLock { $0 }?(b) }
    }

    func testTheOldShapeStillAccumulatesOnAPureCall() {
        func depth(after k: Int) -> Int {
            var measuring = false
            var observed = 0
            let box = LockHoldingTheClosure()
            let payload = buffer()
            box.callback = { _ in if measuring { observed = Thread.callStackSymbols.count } }
            for _ in 0..<k { box.callIfSet(payload) }
            measuring = true
            box.callIfSet(payload)
            XCTAssertGreaterThan(observed, 0, "the old shape's closure never ran")
            return observed
        }
        let first = depth(after: 0), later = depth(after: 500)
        XCTAssertGreaterThan(later, first + 500,
                             "the shape that crashed the app no longer accumulates — if Swift "
                             + "changed, AudioCallbackBox's whole justification needs re-reading")
    }

    /// THE MIDDLE ROW OF THE DOC'S TABLE, likewise reproduced: a class box holding a NON-optional
    /// closure fixes the call path and still accumulates on a read-then-write round trip. That is
    /// the shape a reasonable person writes when told "put it in a class", and the reason the
    /// shipped one holds an Optional inside.
    private final class ClassBoxHoldingNonOptional {
        private final class Held: @unchecked Sendable {
            let call: (AVAudioPCMBuffer) -> Void
            init(_ c: @escaping (AVAudioPCMBuffer) -> Void) { call = c }
        }
        private let stored = OSAllocatedUnfairLock<Held?>(initialState: nil)
        var callback: ((AVAudioPCMBuffer) -> Void)? {
            get { stored.withLock { $0 }?.call }
            set { let h = newValue.map(Held.init); stored.withLock { $0 = h } }
        }
        func callIfSet(_ b: AVAudioPCMBuffer) { stored.withLock { $0 }?.call(b) }
    }

    func testTheNonOptionalClassBoxIsFlatOnCallsAndAccumulatesOnRoundTrips() {
        func depth(after k: Int, _ operate: (ClassBoxHoldingNonOptional) -> Void) -> Int {
            var measuring = false
            var observed = 0
            let box = ClassBoxHoldingNonOptional()
            box.callback = { _ in if measuring { observed = Thread.callStackSymbols.count } }
            for _ in 0..<k { operate(box) }
            measuring = true
            box.callIfSet(buffer())
            XCTAssertGreaterThan(observed, 0, "the variant's closure never ran")
            return observed
        }
        XCTAssertEqual(depth(after: 0) { $0.callIfSet(buffer()) },
                       depth(after: 500) { $0.callIfSet(buffer()) },
                       "the non-optional variant should be flat on the CALL path")
        let first = depth(after: 0) { b in let h = b.callback; b.callback = h }
        let later = depth(after: 500) { b in let h = b.callback; b.callback = h }
        XCTAssertGreaterThan(later, first + 500,
                             "the non-optional variant no longer accumulates on round trips — the "
                             + "doc's middle row, and the reason for the Optional, is stale")
    }

    /// THE CAPTURE CLASSES CANNOT BE IMPORTED — they are app-target — so nothing above stops
    /// someone reverting them to the shape that crashed while every test stays green. That is the
    /// regression this suite exists to prevent, so it is checked at the only level available.
    func testTheCaptureClassesStillUseTheBox() throws {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent()
            .deletingLastPathComponent().deletingLastPathComponent()
        for name in ["MicrophoneCapture", "SystemAudioCapture"] {
            let url = root.appendingPathComponent("Sources/Recording/" + name + ".swift")
            guard FileManager.default.fileExists(atPath: url.path) else {
                throw XCTSkip("app source not present at " + url.path)
            }
            let source = try String(contentsOf: url, encoding: .utf8)
            XCTAssertTrue(source.contains("AudioCallbackBox()"),
                          name + " no longer stores its callback in AudioCallbackBox")
            XCTAssertFalse(source.contains("OSAllocatedUnfairLock<((AVAudioPCMBuffer)"),
                           name + " holds a closure in a lock again — the shape that crashed the app")
        }
    }

    // MARK: - The shapes that actually ship

    /// WHAT THE CAPTURE CLASSES DO. Neither exposes the box: each keeps
    /// `var onBuffer: ((AVAudioPCMBuffer) -> Void)?` as a computed property forwarding to it, so the
    /// value crosses one more property boundary than the tests above exercise. That extra hop is
    /// where "it was flat when I measured it" stops being evidence about the thing that ships.
    ///
    /// BOTH ASSERTIONS GO THROUGH `onBuffer`. The first used to drive `box.callIfSet` directly,
    /// which touches the forwarding property exactly never — so it was a copy of
    /// `testInvokingTheCallbackDoesNotDeepenTheStack` wearing a message about forwarding.
    private final class ForwardingCapture {
        var onBuffer: ((AVAudioPCMBuffer) -> Void)? {
            get { box.callback }
            set { box.callback = newValue }
        }
        let box = AudioCallbackBox()
    }

    func testForwardingThroughAComputedPropertyStaysFlat() {
        func depth(after k: Int, _ operate: (ForwardingCapture) -> Void) -> Int {
            var measuring = false
            var observed = 0
            let capture = ForwardingCapture()
            capture.onBuffer = { _ in if measuring { observed = Thread.callStackSymbols.count } }
            for _ in 0..<k { operate(capture) }
            measuring = true
            capture.box.callIfSet(buffer())
            return observed
        }
        XCTAssertEqual(depth(after: 0) { $0.onBuffer?(buffer()) },
                       depth(after: 5_000) { $0.onBuffer?(buffer()) },
                       "calling through the capture classes' forwarding property accumulates")
        XCTAssertEqual(depth(after: 0) { c in let h = c.onBuffer; c.onBuffer = h },
                       depth(after: 5_000) { c in let h = c.onBuffer; c.onBuffer = h },
                       "assigning the forwarding property from itself accumulates")
    }

    /// THE OTHER PER-BUFFER CALLBACKS ARE PLAIN STORED PROPERTIES — `onLevel` on both capture
    /// classes, and `MicrophoneTap.onBuffer`. They were never at risk, and this records WHY rather
    /// than leaving "we looked at them" as the argument: a stored property on a concrete class needs
    /// no reabstraction, so it is the control the whole diagnosis is measured against.
    func testAPlainStoredPropertyIsTheFlatControl() {
        final class PlainSink { var onLevel: ((Float) -> Void)? }
        // SAME METHODOLOGY AS THE GATES IT ANCHORS — one measurement site, varying k. Sampling two
        // different call sites instead would let a one-frame difference in the surrounding code read
        // as accumulation, or hide it.
        func depth(after k: Int) -> Int {
            var measuring = false
            var observed = 0
            let sink = PlainSink()
            sink.onLevel = { _ in if measuring { observed = Thread.callStackSymbols.count } }
            for _ in 0..<k { sink.onLevel?(0) }
            measuring = true
            sink.onLevel?(0)
            XCTAssertGreaterThan(observed, 0, "the control's closure never ran")
            return observed
        }
        XCTAssertEqual(depth(after: 0), depth(after: 5_000),
                       "a plain stored property accumulated — the control is not flat, so every "
                       + "other measurement in this suite is suspect")
    }

    /// AT THE SCALE THAT CRASHED, AND PAST IT. The report recorded 6,619 repetitions; a long call is
    /// far more. 200,000 buffers is roughly 70 minutes of 48 kHz audio at 512 frames a buffer, and twice that at a typical 1,024.
    func testTheBoxIsFlatAtRecordingScale() {
        XCTAssertEqual(depth(after: 0) { $0.callIfSet(buffer()) },
                       depth(after: 200_000) { $0.callIfSet(buffer()) },
                       "grew over 200,000 buffers")
    }

    // MARK: - Behaviour, so the depth gates cannot be satisfied by a box that does nothing

    func testTheCallbackReceivesThePayloadItWasGiven() {
        let box = AudioCallbackBox()
        let sent = buffer()
        var received: AVAudioPCMBuffer?
        box.callback = { received = $0 }
        box.callIfSet(sent)
        XCTAssertTrue(received === sent)
    }

    func testAnUnsetBoxIsANoOp() {
        let box = AudioCallbackBox()
        box.callIfSet(buffer())          // must not trap
        XCTAssertNil(box.callback)
    }

    func testTheCallbackCanBeReplacedAndCleared() {
        let box = AudioCallbackBox()
        var calls = ""
        box.callback = { _ in calls += "a" }
        box.callIfSet(buffer())
        box.callback = { _ in calls += "b" }
        box.callIfSet(buffer())
        box.callback = nil
        box.callIfSet(buffer())
        XCTAssertEqual(calls, "ab")
        XCTAssertNil(box.callback)
    }

    /// The reason the lock is there at all: the callback is attached from one thread while another
    /// is invoking it. This does not prove thread-safety — it is a smoke test that the box does not
    /// trap, and that it keeps DELIVERING under contention.
    ///
    /// THE DELIVERY COUNT IS THE ASSERTION. This used to end on `XCTAssertNotNil(box.callback)`,
    /// which cannot fail: the writer only ever stores non-nil closures, so the last write is
    /// non-nil whatever the box does. A `callIfSet` that silently degraded to a no-op passed it.
    func testConcurrentAttachAndInvokeKeepsDelivering() {
        let delivered = OSAllocatedUnfairLock(initialState: 0)
        let box = AudioCallbackBox()
        box.callback = { _ in delivered.withLock { $0 += 1 } }
        let deadline = Date().addingTimeInterval(0.5)
        let done = expectation(description: "readers and writers finished")
        done.expectedFulfillmentCount = 2

        let payload = buffer()
        DispatchQueue.global().async {
            while Date() < deadline { box.callIfSet(payload) }
            done.fulfill()
        }
        DispatchQueue.global().async {
            while Date() < deadline { box.callback = { _ in delivered.withLock { $0 += 1 } } }
            done.fulfill()
        }
        wait(for: [done], timeout: 10)
        XCTAssertGreaterThan(delivered.withLock { $0 }, 0,
                             "the box stopped delivering under contention")
    }
}
