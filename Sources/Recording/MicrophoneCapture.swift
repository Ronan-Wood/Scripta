import AVFoundation
import ScriptaCore
import OSLog
import os

/// Captures the microphone via AVAudioEngine and writes it to a CAF file in the
/// input hardware's native format. Used on all supported OS versions because
/// ScreenCaptureKit's own microphone capture is macOS 15+ only.
final class MicrophoneCapture {
    private let outputURL: URL
    private let engine = AVAudioEngine()
    private let log = Logger(subsystem: "com.ronanwood.Scripta", category: "Microphone")

    /// The file write, live-transcription feed, and level metering all happen here — off the tap
    /// delivery thread.
    ///
    /// WHY IT IS HERE, AND A CORRECTION. This queue was added (`3ed6763`, 2026-07-21) to fix a stack
    /// overflow after ~7 minutes of recording, blamed then on AVAudioEngine's real-time messenger
    /// sharing a buffer allocator with AVAudioConverter and recursing one frame per buffer. That
    /// explanation is almost certainly WRONG, and the correction matters because the same bug went
    /// on to crash the system-audio path: the real mechanism was `onBuffer` being stored in a
    /// generic lock, where a read is a copy-in/copy-out that re-stores the closure one
    /// reabstraction-thunk pair deeper — see `AudioCallbackBox`, which measures exactly this growth
    /// with no converter, no engine and an empty closure.
    ///
    /// The dates settle the ordering: the locked `onBuffer` landed 2026-07-15, six days BEFORE that
    /// crash, so the reabstraction was already present in the overflow the queue hop was written to
    /// fix. And the hop cannot have stopped the accumulation — `onBuffer` was still read once per
    /// buffer afterwards, just from here rather than the tap thread.
    ///
    /// WHAT IT CHANGED IS UNMEASURED, and saying otherwise would repeat the mistake being
    /// corrected. The plausible reading is that moving off the tap thread raised the ceiling
    /// (a dispatch queue's stack is not the audio thread's), pushing the crash out far enough that
    /// nobody hit it again on this path — the ~7 minutes belongs to the crash BEFORE the hop, and
    /// nothing here has measured what the interval became after it. `AudioCallbackBox` removes the
    /// growth rather than delaying it, which is why that question stopped mattering.
    ///
    /// THE QUEUE STAYS, on its own merits rather than that story: a file write and a format
    /// conversion do not belong on an audio delivery thread, and nothing below may create or drive
    /// an AVAudioConverter/AVAudioEngine on the tap thread itself. That prohibition is real-time
    /// safety, and it holds whatever caused the 2026-07 overflow.
    private let processingQueue = DispatchQueue(label: "com.ronanwood.Scripta.MicrophoneCapture.processing")

    /// Tracks every tap invocation from entry to the completion of its processingQueue work, so
    /// `stop()` can wait for all of it to drain. Entering synchronously on the tap thread (before
    /// any async hop) means the count reflects invocations that have started, not just work
    /// that's already been handed to processingQueue — draining `processingQueue` alone can't make
    /// that same distinction.
    private let inFlight = DispatchGroup()

    private var audioFile: AVAudioFile?

    /// Called on `processingQueue`, not the tap/audio thread — see that property's comment. Must
    /// not call `stop()` synchronously: `stop()` waits on `inFlight`, which this closure's own
    /// invocation holds open, and a synchronous call back in would deadlock.
    var onLevel: ((Float) -> Void)?

    /// When paused, buffers are dropped (not written) so the track simply omits that interval.
    /// Locked: written from the session (main) and read per-buffer on the audio tap thread.
    var isPaused: Bool {
        get { pausedFlag.withLock { $0 } }
        set { pausedFlag.withLock { $0 = newValue } }
    }
    private let pausedFlag = OSAllocatedUnfairLock(initialState: false)

    /// Called on `processingQueue`, not the tap/audio thread — see that property's comment, and
    /// `onLevel`'s for why this must not call `stop()` synchronously. Locked: live transcription
    /// attaches this while capture is already running (its setup can include a model download,
    /// so it comes up in the background).
    /// See `AudioCallbackBox` for why the lock cannot hold the closure itself.
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { bufferCallback.callback }
        set { bufferCallback.callback = newValue }
    }
    private let bufferCallback = AudioCallbackBox()

    /// Diagnostic only — logs when processingQueue falls behind capture instead of throttling it,
    /// since blocking the tap thread to apply backpressure is the exact pattern that caused the
    /// crash this queue exists to avoid.
    private let pendingCount = OSAllocatedUnfairLock(initialState: 0)

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "Scripta", code: 101,
                          userInfo: [NSLocalizedDescriptionKey: "No microphone input is available."])
        }

        let file = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )
        audioFile = file

        // The tap captures the file immutably — no shared mutable var between the audio
        // thread and stop() (which would be a torn read the moment they raced).
        //
        // The tap block itself only copies the buffer (the original is only valid for the
        // duration of this call) and hops to processingQueue — see that property's comment for
        // why nothing heavier can run here. inFlight.enter() happens before anything else so
        // stop() can't finish waiting until this invocation is accounted for, however far it gets.
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self else { return }
            self.inFlight.enter()
            guard !self.isPaused, let copy = Self.copy(buffer) else {
                self.inFlight.leave()
                return
            }
            let depth = self.pendingCount.withLock { $0 += 1; return $0 }
            if depth == 200 || (depth > 200 && depth.isMultiple(of: 200)) {
                self.log.warning("mic processingQueue backlog at \(depth, privacy: .public) buffers — disk or live-transcription feed is falling behind capture")
            }
            self.processingQueue.async {
                defer { self.pendingCount.withLock { $0 -= 1 }; self.inFlight.leave() }
                do {
                    try file.write(from: copy)
                } catch {
                    self.log.error("mic write failed: \(error.localizedDescription, privacy: .public)")
                }
                self.bufferCallback.callIfSet(copy)
                if let onLevel = self.onLevel, let channels = copy.floatChannelData {
                    let frames = Int(copy.frameLength)
                    var peak: Float = 0
                    for c in 0..<Int(copy.format.channelCount) {
                        let data = channels[c]
                        for i in 0..<frames { peak = max(peak, abs(data[i])) }
                    }
                    onLevel(peak)
                }
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        // Waits for every tap invocation entered so far — including one still on its synchronous
        // portion when removeTap() was called above — to finish its processingQueue work, so the
        // file is guaranteed complete once this returns.
        inFlight.wait()
        audioFile = nil
    }

    /// Deep-copies a tap buffer so it can outlive the tap callback (Apple's docs: the buffer is
    /// only valid for the duration of the block). Copies via the raw AudioBufferList rather than
    /// the typed (float/int16/int32) channel-data accessors so it's correct for interleaved
    /// formats too — those accessors return one pointer regardless of channel count, so indexing
    /// per-channel against them for an interleaved buffer reads/writes out of bounds.
    private static func copy(_ buffer: AVAudioPCMBuffer) -> AVAudioPCMBuffer? {
        guard let copy = AVAudioPCMBuffer(pcmFormat: buffer.format, frameCapacity: buffer.frameCapacity) else { return nil }
        copy.frameLength = buffer.frameLength
        let src = UnsafeMutableAudioBufferListPointer(buffer.mutableAudioBufferList)
        let dst = UnsafeMutableAudioBufferListPointer(copy.mutableAudioBufferList)
        guard src.count == dst.count else { return nil }
        for i in 0..<src.count {
            guard let srcData = src[i].mData, let dstData = dst[i].mData else { return nil }
            dstData.copyMemory(from: srcData, byteCount: Int(min(src[i].mDataByteSize, dst[i].mDataByteSize)))
        }
        return copy
    }
}
