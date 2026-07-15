import AVFoundation
import OSLog
import os

/// Captures the microphone via AVAudioEngine and writes it to a CAF file in the
/// input hardware's native format. Used on all supported OS versions because
/// ScreenCaptureKit's own microphone capture is macOS 15+ only.
final class MicrophoneCapture {
    private let outputURL: URL
    private let engine = AVAudioEngine()
    private let log = Logger(subsystem: "com.ronanwood.CallTranscriber", category: "Microphone")

    private var audioFile: AVAudioFile?

    /// Called on the audio thread with the peak amplitude (0–1) of each captured buffer.
    var onLevel: ((Float) -> Void)?

    /// When paused, buffers are dropped (not written) so the track simply omits that interval.
    /// Locked: written from the session (main) and read per-buffer on the audio tap thread.
    var isPaused: Bool {
        get { pausedFlag.withLock { $0 } }
        set { pausedFlag.withLock { $0 = newValue } }
    }
    private let pausedFlag = OSAllocatedUnfairLock(initialState: false)

    /// Called on the audio thread with each captured buffer (for live transcription). Locked:
    /// live transcription attaches this while capture is already running (its setup can include
    /// a model download, so it comes up in the background).
    var onBuffer: ((AVAudioPCMBuffer) -> Void)? {
        get { bufferCallback.withLock { $0 } }
        set { bufferCallback.withLock { $0 = newValue } }
    }
    private let bufferCallback = OSAllocatedUnfairLock<((AVAudioPCMBuffer) -> Void)?>(initialState: nil)

    init(outputURL: URL) {
        self.outputURL = outputURL
    }

    func start() throws {
        let input = engine.inputNode
        let format = input.inputFormat(forBus: 0)
        guard format.sampleRate > 0, format.channelCount > 0 else {
            throw NSError(domain: "CallTranscriber", code: 101,
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
        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, !self.isPaused else { return }
            do {
                try file.write(from: buffer)
            } catch {
                self.log.error("mic write failed: \(error.localizedDescription, privacy: .public)")
            }
            self.onBuffer?(buffer)
            if let onLevel = self.onLevel, let channels = buffer.floatChannelData {
                let frames = Int(buffer.frameLength)
                var peak: Float = 0
                for c in 0..<Int(buffer.format.channelCount) {
                    let data = channels[c]
                    for i in 0..<frames { peak = max(peak, abs(data[i])) }
                }
                onLevel(peak)
            }
        }

        engine.prepare()
        try engine.start()
    }

    func stop() {
        engine.inputNode.removeTap(onBus: 0)
        engine.stop()
        audioFile = nil
    }
}
