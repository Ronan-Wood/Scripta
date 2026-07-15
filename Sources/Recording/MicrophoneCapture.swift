import AVFoundation
import OSLog

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
    var isPaused = false

    /// Called on the audio thread with each captured buffer (for live transcription).
    var onBuffer: ((AVAudioPCMBuffer) -> Void)?

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

        audioFile = try AVAudioFile(
            forWriting: outputURL,
            settings: format.settings,
            commonFormat: format.commonFormat,
            interleaved: format.isInterleaved
        )

        input.installTap(onBus: 0, bufferSize: 4096, format: format) { [weak self] buffer, _ in
            guard let self, !self.isPaused else { return }
            do {
                try self.audioFile?.write(from: buffer)
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
